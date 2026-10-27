# OIDC Deploy Roles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every GitHub Actions job in this repository that talks to AWS gets short-lived credentials from GitHub OIDC by assuming a repo-scoped IAM role. After that, the two static key secrets `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are deleted.

**Architecture:** One plain CloudFormation template, `activity-oidc/template.yaml`, defines four IAM roles, each trusting exactly one OIDC subject of this repository:

- a stage deploy role;
- a prod deploy role;
- an infrastructure role for the environment and bootstrap stacks;
- a read-only integration-test role.

A new `workflow_dispatch` workflow deploys that template as stack `FederatedActivityPublisher-oidc`. It authenticates by assuming the org's existing OIDC bootstrap role, so creating the roles never uses the static keys. Workflows then move to `role-to-assume` in this order: integration tests, stage, prod, infrastructure. The secrets are deleted last.

**Tech Stack:** GitHub Actions, `aws-actions/configure-aws-credentials@v6`, AWS SAM CLI (already used here, through `./.github/actions/setup-sam-portable`), CloudFormation, IAM.

**Spec:** None separate. The requirements were settled 2026-10-27 and are restated under Global Constraints. This plan argues each decision under "Decisions".

## Global Constraints

- **Trust.** Each role trusts the GitHub OIDC provider already in the account (`token.actions.githubusercontent.com`), with `aud` = `sts.amazonaws.com` and `sub` matched with `StringEquals` against this repository only. No wildcards in `sub`.
- **Both subject forms.** Each trust lists the previous subject form `repo:happitec-inc/FederatedActivityPublisher:<suffix>` and the immutable form `repo:happitec-inc@174214171/FederatedActivityPublisher@1193951865:<suffix>`. The IDs were read from the GitHub API on 2026-10-27: repo `id` 1193951865, `owner.id` 174214171.
- **No AdministratorAccess**, no AWS managed policy on any of the four roles, and no reuse of another project's role.
- **Role names** contain `-github-`. This is required: the org bootstrap role can only manage roles matching `role/*-github-*`. The names are:
  - `FederatedActivityPublisher-github-actions-deploy-stage`
  - `FederatedActivityPublisher-github-actions-deploy-prod`
  - `FederatedActivityPublisher-github-actions-infra`
  - `FederatedActivityPublisher-github-actions-integration-read`

  All four are within IAM's 64-character limit.
- **Stack name** `FederatedActivityPublisher-oidc`. It must match the bootstrap role's `*-oidc*` stack pattern.
- **The template has no `Transform:`.** The org bootstrap role has no permission on any transform ARN.
- **Template size.** The template is at most 51,200 bytes, the CloudFormation limit for a template body passed inline. The bootstrap role has no S3 permission, so the template cannot be staged in S3.
- **Policy size.** Each role's inline policy totals at most 10,240 characters, excluding whitespace (IAM's aggregate role-policy limit). The bootstrap role cannot attach managed policies, so inline policies are the only option.
- **Account ID.** The account ID appears only in the new repository secret `AWS_ACCOUNT_ID`, never in a committed file or a variable. In this public repository, Actions logs print each step's resolved inputs, and a secret value is masked in them.
- **AWS calls run only in GitHub Actions.** Nothing in this plan runs `aws` or `sam` against the account from a workstation. Workflow changes are validated by PR CI and by real runs. No runner VM is used, cloned or entered by hand.
- **Explicit go required.** Each of these needs an explicit go from a maintainer, recorded on the PR or run that carries it:
  - creating the `AWS_ACCOUNT_ID` secret;
  - changing environment settings;
  - running a `workflow_dispatch` workflow that mutates AWS;
  - deleting secrets.
- **Commits** follow this repository's public-commit style: short, with no internal process.

## Review Focus

- **Environment-bound jobs present `environment:<name>`, not `ref:`.** GitHub docs, "OpenID Connect reference": "The subject claim includes the environment name when the job references an environment." So `deploy-stage`'s `fast-deploy` and `build` jobs (both `environment: stage`) cannot use a `ref:refs/heads/main` trust. Task 1's `oidc-trust-check.yml` pins each role to the one subject it trusts.
- **Job-level `permissions` sets every unlisted scope to `none`.** GitHub docs, workflow syntax: "If you specify the access for any of these permissions, all of those that are not specified are set to `none`." The three AWS jobs in `deploy-stage.yml` need `contents: read`, `actions: read` and `id-token: write` restated. Task 4 checks the run, not just the YAML.
- **The SAM artifact bucket is shared between stage and prod.** `sam package` skips uploading an object whose key already exists. A stage role that could write anywhere in the bucket could therefore plant an artifact that a later prod package reuses. Task 4 and Task 5 add `--s3-prefix activity-app-<stage>`, and each deploy role can write only under its own prefix. The trust check exercises this.
- **Some grants are account-wide by resource type, so a stage role can reach a prod object.** CloudFront cache policies, origin request policies and origin access controls have generated IDs, and so do API Gateway REST APIs and Lambda event source mappings. Their grants are scoped by type, not by stage. This is a known gap, recorded in "Least-privilege limits", and is not claimed as least privilege.
- **The first CDN template change after cutover is the first real exercise of the CloudFront distribution and Route 53 record grants.** No validation run in this plan changes those resources. Such a change runs on stage before prod, so a missing grant fails on stage first.

---

## Current state (read on `origin/main` at `6386a77`, 2026-10-27)

Seven steps authenticate with the static secrets, all through `aws-actions/configure-aws-credentials@v6` with `aws-access-key-id` and `aws-secret-access-key`:

| Workflow | Job | Lines | Trigger | `environment:` | AWS calls after the step |
|---|---|---|---|---|---|
| `bootstrap.yml` | `deploy` | 31–36 | `workflow_dispatch` | none | `sam deploy` stack `activity-bootstrap`; `describe-stacks` |
| `environment.yml` | `deploy` | 28–33 | `workflow_dispatch` | none | `sam deploy` stack `activity-environment-<stage>`; `describe-stacks` |
| `deploy-stage.yml` | `fast-deploy` | 197–202 | push to `main` | `stage` | `describe-stack-resource`, `list-stack-resources`, `lambda update-function-code` |
| `deploy-stage.yml` | `build` | 309–314 | push to `main`, dispatch | `stage` | `sam package --resolve-s3`, `sam deploy` stack `activity-app-stage`, `describe-stacks`, `s3 sync` |
| `deploy-stage.yml` | `integration-tests` | 422–427 | after the above | none | `describe-stacks activity-app-stage` |
| `deploy-prod.yml` | `build-and-deploy` | 83–88 | release published, dispatch | `production` | same as `build`, for `prod` |
| `run-integration-tests.yml` | `test` | 32–37 | `workflow_dispatch` | none | `describe-stacks activity-app-<env>`; prod only: `ssm get-parameter /activity/prod/keys/client-token --with-decryption` |

The other workflows do not reference an AWS secret. A grep of `.github/` for `secrets.AWS` and `aws ` matched only the five files above. `deploy-docc.yml` holds `id-token: write` for Pages.

Facts this plan depends on, measured 2026-10-27:

- Environments `stage` and `production` exist with no protection rules and `deployment_branch_policy: null`. Any branch can run a job bound to them. Measured with `GET /repos/{owner}/{repo}/environments`.
- The repository was created 2026-03-27. GitHub docs, "OpenID Connect reference": repositories created after July 15, 2026 use the immutable subject; older ones "keep the previous format unless they opt in."
- The SAM managed artifact bucket exists. Its name starts with `aws-sam-cli-managed-default-samclisourcebucket-`, measured from the `Managed S3 bucket:` line of `deploy-prod` run 39721690715.
- `sam package` has `--s3-prefix TEXT`, measured with `sam package --help` on SAM CLI 1.166.2.
- `sam deploy` in this repository runs without a service role (`--role-arn` is absent). CloudFormation therefore acts with the caller's credentials for every resource, including nested stacks. The deploy role needs the resource permissions, not just CloudFormation ones.

## Decisions

### D1: Where the roles are created (open question Q1; recommendation: option c)

**The crux, with receipts.** `shared-actions` is private, and this repository is public (both measured with `GET /repos`, 2026-10-27). GitHub docs, "Managing GitHub Actions settings for a repository" → "Allowing access to components in a private repository", give the two sharing options for a private repository's actions and reusable workflows. Both say: "Access is allowed only from private repositories." A public repository therefore cannot call `happitec-inc/shared-actions/.github/workflows/bootstrap-oidc-role.yml`.

That reusable workflow also uses `happitec-inc/shared-actions/setup-sam-portable@main` and checks out the private repository, so neither piece would work from here either.

What that workflow does is small. It assumes the org role `shared-actions-github-bootstrap`. It generates a CloudFormation template with one `AWS::IAM::Role`, whose base CloudFormation and SAM-artifact statements are scoped to `stack/<repo>*`. Then it runs `sam deploy --capabilities CAPABILITY_NAMED_IAM`.

The org role's trust admits `repo:happitec-inc/*:*` and `repo:happitec-inc@174214171/*:*` with `StringLike`. That matches this repository's subjects. The role may create, update and put inline policies on `role/*-github-*`, and drive stacks named `*-bootstrap*`, `*-prereqs*`, `*-github-*` or `*-oidc*`. It cannot attach managed policies.

| Option | What changes | Smallest mechanism | Correct locus | Cost |
|---|---|---|---|---|
| (a) Add the roles to `activity-bootstrap` and deploy them with `bootstrap.yml` | One template gains four roles | Reuses an existing stack and workflow | **No.** The DNS-zone-and-certificate stack takes on a second job: CI identity. `bootstrap.yml` requires `domain-name` and `dns-mode` inputs, so every role edit risks the hosted zone. The first run needs the static admin keys, and later runs need a role allowed to rewrite its own policy. | Admin keys in CI once; a self-escalating role afterwards |
| (b) Publish an equivalent reusable workflow in `happitec-inc/public-actions`, opt-in, existing defaults kept | A second copy of the org workflow in another repository | Adds a component in a repository this one does not own | The generator belongs to the org, so it is the right locus for a shared tool. But it duplicates `shared-actions` and needs that repository's owner to make the change. | A cross-repo PR, a review, and two copies to keep in step |
| **(c) This repository assumes the org bootstrap role directly and deploys its own role template** | One template and one small workflow here | **Yes.** Uses the existing org role as designed ("Allows any repo in the org to self-provision its own scoped OIDC deploy role via CloudFormation", from its template description). No new component elsewhere. | **Yes.** The roles live with their only consumer. The org role keeps its one job. | Diverges from the generator: this repository writes its template by hand instead of passing `extra-policy-json` |

**Recommendation: (c).** It is the same mechanism `bucket-cache` used, minus the private wrapper, and it needs no admin keys at any point.

Its divergence from the org generator is deliberate. This repository needs four roles, each with a different trust, and needs CloudFormation scoped to `activity-*` stacks. The generator emits one role per call, with base CloudFormation scoped to `stack/<repo>*`, which does not match `activity-*`. Using it would take four calls and a generator change anyway.

If the org later narrows the bootstrap role's trust to exclude public repositories, (b) is the fallback.

### D2: How many roles (open question Q2)

Four roles. The fewest that do the job would be three: stage deploy, prod deploy, integration read. The IAM limit made that impossible.

A draft of the three-role design put the environment-stack and bootstrap-stack grants on the deploy roles. It measured 9,559 characters for stage and 10,311 for prod, minified, with real-length ARNs. Prod is over the 10,240 limit, and stage leaves no headroom.

Splitting the rarely-run data and DNS stacks onto an `infra` role brings both deploy roles to about 6,300 characters and infra to about 5,300. It also means the role used on every merge and release cannot reconfigure the table, bucket, queues, hosted zone or certificate.

| Role | Trusted subject suffix | Used by |
|---|---|---|
| `...-deploy-stage` | `environment:stage` | `deploy-stage.yml` jobs `fast-deploy`, `build` |
| `...-deploy-prod` | `environment:production` | `deploy-prod.yml` job `build-and-deploy` |
| `...-infra` | `environment:infrastructure` (new environment) | `environment.yml`, `bootstrap.yml` |
| `...-integration-read` | `ref:refs/heads/main` | `deploy-stage.yml` job `integration-tests`; `run-integration-tests.yml` |

**Why integration gets its own role.** `run-integration-tests.yml` configures credentials, then compiles and runs `swift test`, which runs third-party package code. The credentials stay in the job environment for every later step, so that job must hold read-only credentials.

**Why prod stays separate from stage.** The environment boundary costs nothing: the jobs are already environment-bound. Task 2 adds deployment branch rules so the environment boundary also restricts refs:

- `stage` and `infrastructure`: `main` only;
- `production`: `main` and tags `v*`.

Without those rules, any branch dispatching `deploy-prod.yml` would present `environment:production`.

### D3: How the permissions were derived

1. **Every AWS call each workflow step makes** is listed in the current-state table above.
2. **For every resource type the three templates create**, the CloudFormation registry schema lists the permissions its create, update, read and delete handlers call. These are `handlers.<op>.permissions` and `tagging.permissions` in `CloudformationSchema.zip`, downloaded 2026-10-27 from `https://schema.cloudformation.us-east-1.amazonaws.com/CloudformationSchema.zip`. The SAM transform of `activity-app/functions/template.yaml` yields these types:
   - `AWS::Lambda::Function`, `AWS::IAM::Role`, `AWS::Lambda::Permission` and `AWS::Lambda::EventSourceMapping`;
   - `AWS::ApiGateway::RestApi`, `Deployment` and `Stage`.

   `activity-app/cdn/template.yaml` declares these types:
   - `AWS::CloudFront::CachePolicy`, `OriginRequestPolicy`, `OriginAccessControl`, `Function` and `Distribution`;
   - `AWS::S3::BucketPolicy` and `AWS::Route53::RecordSet`.

   `activity-environment` declares `S3::Bucket`, `DynamoDB::Table`, `SQS::Queue` (twice), `SNS::Topic` and `CloudWatch::Alarm`. `activity-bootstrap` declares `Route53::HostedZone` and `CertificateManager::Certificate`.
3. **The rule.** Grant the handler actions of the resource's own service, scoped to this repository's resource names. Grant cross-service handler actions only for features the templates use: `iam:PassRole` to Lambda, and `s3:GetObject` and `s3:GetObjectVersion` on the code artifacts. Actions for features the templates do not use are left out. For example:
   - VPC (`ec2:*`), EFS, KMS customer keys, code-signing writes, layers and capacity providers;
   - S3 Tables and Kinesis;
   - DynamoDB item operations, which would let the role read or rewrite the live table.
4. **Retained data resources get no create or delete.** The table, media bucket and queues have `DeletionPolicy: Retain`. If a template change ever asks CloudFormation to replace one, it must fail rather than create an empty twin.
5. **Name check.** All 205 distinct action names in Appendix A appear in the AWS Policy Generator's action catalog, `https://awspolicygen.s3.amazonaws.com/js/policies.js`, fetched 2026-10-27. So do the condition keys `iam:PassedToService`, `iam:PolicyARN`, `route53:ChangeResourceRecordSetsNormalizedRecordNames` and `kms:ViaService`.

   As a negative control, two invented names (`s3:BogusNegativeControl`, `lambda:NotARealAction`) were flagged as missing in the same run. The same check found nine names in the S3 bucket handler list that are API operation names, not IAM actions; for example, `s3:DeleteBucketCors`, whose IAM action is `s3:PutBucketCORS`. Those nine are excluded.

   The catalog confirms that a name exists. It does not confirm resource-level support for it; that is listed under Unverified.

### D4: The chicken-and-egg step

The four roles are created by a role that already exists, `shared-actions-github-bootstrap`, assumed over OIDC. Neither the static keys nor any admin credential are involved.

That org role was itself created once from a workstation. The header of its own update workflow says "One-time initial deploy must be done via CLI". Every org repository since has used it over OIDC.

`bucket-cache`'s first bootstrap shows the pattern. Run 35872013678 (2026-09-23, `workflow_dispatch` on `main`) failed at "Configure AWS credentials (org bootstrap role)". The org role's trust was then extended to the immutable subject form. The retry, run 35876368059, assumed the role and deployed `bucket-cache-oidc`.

For this repository, the one-time step is Task 2. With an explicit go, a maintainer dispatches `oidc-roles.yml` once from `main`. It does not run on push or pull request, and it never uses the static keys.

### D5: Least-privilege limits (stated, not hidden)

- **The deploy roles can create and modify IAM roles named `activity-app-<stage>-*`, write their inline policies, and pass them to Lambda.** That is inherent to deploying SAM functions whose policies live in the template. Together with `lambda:UpdateFunctionCode`, it lets the deploy role reach any permission it can write into a function role.

  Closing that needs a permissions boundary on the function roles: SAM `Globals.Function.PermissionsBoundary`, plus an `iam:PermissionsBoundary` condition on the deploy role's IAM grants. That is a change to `activity-app/functions/template.yaml` and is outside this plan (Q5).
- **Resources with generated IDs are scoped by type, not by stage.** These are API Gateway (`/restapis/*`), CloudFront cache policies, origin request policies and origin access controls, and Lambda event source mappings.

  The CloudFront distribution is scoped by ID, taken from the repository variables `ACTIVITY_DISTRIBUTION_ID_STAGE` and `ACTIVITY_DISTRIBUTION_ID_PROD`. The Route 53 record write is scoped to the one record name of each stage.
- **Neither deploy role can create or delete a CloudFront distribution.** Replacing a distribution is a deliberate event. It needs the role stack redeployed with the new ID first.
- **`route53:ListHostedZones`, `route53:GetChange` and `cloudwatch:DescribeAlarms` are granted on `*`.** All three are read-only.

---

## File structure

| File | Change | Responsibility |
|---|---|---|
| `activity-oidc/template.yaml` | Create | The four roles: trust, inline policies, outputs (role names only) |
| `.github/workflows/oidc-roles.yml` | Create | `workflow_dispatch` on `main`: assume the org bootstrap role, deploy `FederatedActivityPublisher-oidc` |
| `.github/workflows/oidc-trust-check.yml` | Create | `workflow_dispatch`: positive and negative assume checks per role, scope checks, and an inventory of function role names and managed policies |
| `.github/workflows/run-integration-tests.yml` | Modify `32–37` | Integration role |
| `.github/workflows/deploy-stage.yml` | Modify `197–202`, `309–314`, `316–322`, `422–427`, job `permissions` | Stage role and integration role; `--s3-prefix activity-app-stage` |
| `.github/workflows/deploy-prod.yml` | Modify `9–10`, `83–88`, `92–96` | Prod role; `--s3-prefix activity-app-prod` |
| `.github/workflows/environment.yml` | Modify `4–5`, `19–20`, `28–33` | `environment: infrastructure`; infra role |
| `.github/workflows/bootstrap.yml` | Modify `3–4`, `22–23`, `31–36` | `environment: infrastructure`; infra role; refuse a domain change on an existing stack |

There are no Swift changes, so `swift test` (`test.yml`) is unaffected. The workflows are validated by PR CI and by the runs named in each task.

---

### Task 1: Role template and the two dispatch workflows

**Files:**
- Create: `activity-oidc/template.yaml`
- Create: `.github/workflows/oidc-roles.yml`
- Create: `.github/workflows/oidc-trust-check.yml`

**Interfaces:**
- Produces: the stack `FederatedActivityPublisher-oidc`, with outputs `StageDeployRoleName`, `ProdDeployRoleName`, `InfraRoleName` and `IntegrationReadRoleName`. Each output's value is the role name.
- Produces: the ARN form every later task uses, `arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/<role name>`.

- [ ] **Step 1: Write `activity-oidc/template.yaml`**

  The template has no `Transform`.

  `Parameters`:
  - `GitHubOrg` (default `happitec-inc`), `GitHubRepo` (default `FederatedActivityPublisher`);
  - `GitHubOrgId` (default `"174214171"`), `GitHubRepoId` (default `"1193951865"`), both with `AllowedPattern: "^[0-9]+$"`;
  - `BootstrapStackName` (default `activity-bootstrap`);
  - `StageDistributionId` and `ProdDistributionId`, no default.

  `Resources` are `StageDeployRole`, `ProdDeployRole`, `InfraRole` and `IntegrationReadRole`, each an `AWS::IAM::Role` with:
  - `RoleName: !Sub ${GitHubRepo}-github-actions-<suffix>`;
  - `MaxSessionDuration: 3600`;
  - one inline policy named `deploy` (`read` for `IntegrationReadRole`) holding the statements in Appendix A;
  - `Tags: [{Key: Project, Value: !Ref GitHubRepo}]`.

  Use `Fn::ImportValue` to read these exports of `${BootstrapStackName}`:
  - `-HostedZoneId` for the hosted zone ARN;
  - `-DomainName` for record names;
  - `-CertificateArn` for the certificate ARN.

  Each role's trust policy is exactly this, with only `<suffix>` varying per role (D2 table):

  ```yaml
  AssumeRolePolicyDocument:
    Version: "2012-10-17"
    Statement:
      - Effect: Allow
        Principal:
          Federated: !Sub arn:aws:iam::${AWS::AccountId}:oidc-provider/token.actions.githubusercontent.com
        Action: sts:AssumeRoleWithWebIdentity
        Condition:
          StringEquals:
            token.actions.githubusercontent.com:aud: sts.amazonaws.com
            token.actions.githubusercontent.com:sub:
              - !Sub repo:${GitHubOrg}/${GitHubRepo}:<suffix>
              - !Sub repo:${GitHubOrg}@${GitHubOrgId}/${GitHubRepo}@${GitHubRepoId}:<suffix>
  ```

- [ ] **Step 2: Check the template offline**

  Run: `wc -c activity-oidc/template.yaml`
  Expected: under 51,200.

  Then run the action-name check. Extract every `service:Action` token from the template and confirm each one is a key in the `serviceMap[*].Actions` of `https://awspolicygen.s3.amazonaws.com/js/policies.js`, or in its `conditionKeys`. Run it once with a deliberately misspelled action added, and expect that name reported. Then remove it, and expect zero missing.

  For each role, minify its inline policy with `!Sub` values replaced by real-length placeholders: a 12-digit account ID, a 21-character zone ID, a 14-character distribution ID and a UUID certificate ID.
  Expected: under 10,240 characters per role.

- [ ] **Step 3: Write `.github/workflows/oidc-roles.yml`**

  - Trigger: `workflow_dispatch` only.
  - `permissions: {contents: read, id-token: write}`.
  - `concurrency: {group: oidc-roles, cancel-in-progress: false}`.
  - One job, `if: github.ref == 'refs/heads/main'`, with `runs-on` the same expression the other workflows use: `${{ vars.RUNNER_LABELS_LINUX && fromJSON(vars.RUNNER_LABELS_LINUX) || 'ubuntu-latest' }}`.

  Steps:
  1. `actions/checkout@v6`.
  2. `./.github/actions/setup-sam-portable`.
  3. `aws-actions/configure-aws-credentials@v6` with:
     - `role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/shared-actions-github-bootstrap`;
     - `aws-region: ${{ vars.AWS_REGION || 'us-east-1' }}`.
  4. Deploy:

     ```
     sam deploy --template-file activity-oidc/template.yaml --stack-name FederatedActivityPublisher-oidc --capabilities CAPABILITY_NAMED_IAM --no-confirm-changeset --no-fail-on-empty-changeset --region <region> --parameter-overrides StageDistributionId=${{ vars.ACTIVITY_DISTRIBUTION_ID_STAGE }} ProdDistributionId=${{ vars.ACTIVITY_DISTRIBUTION_ID_PROD }}
     ```

  5. `aws cloudformation describe-stacks --stack-name FederatedActivityPublisher-oidc --query "Stacks[0].Outputs" --output table`, appended to `$GITHUB_STEP_SUMMARY`.

  The input names `role-to-assume` and `aws-region` on `@v6` match the org workflow that `bucket-cache` run 35876368059 completed with.

- [ ] **Step 4: Write `.github/workflows/oidc-trust-check.yml`**

  Trigger: `workflow_dispatch`. Workflow `permissions: {contents: read, id-token: write}`. Four jobs, one per subject.

  **Expected-failure pattern.** Each expected-failure assume is a `configure-aws-credentials` step with `continue-on-error: true` and an `id`, followed by `if: steps.<id>.outcome != 'failure'` → `run: exit 1`. Expected failures come before the expected success in each job, so no earlier credentials are in the environment when they run. Every AWS command run as a scope check sends output to `/dev/null` and asserts on the exit code only.

  | Job | `environment:` | Must fail to assume | Must assume | Scope check, must fail |
  |---|---|---|---|---|
  | `no-environment` | none | stage, prod, infra | integration-read | `describe-stacks --stack-name activity-environment-prod` |
  | `stage` | `stage` | prod, infra, integration-read | deploy-stage | `describe-stacks --stack-name activity-app-prod` |
  | `production` | `production` | stage, infra | deploy-prod | `describe-stacks --stack-name activity-app-stage` |
  | `infrastructure` | `infrastructure` | prod, stage | infra | `describe-stacks --stack-name activity-app-prod` |

  After its assume, each job runs `aws sts get-caller-identity --query Arn --output text`. The account ID in the output is masked as a secret.

  The `stage` job also prints an inventory, which measures two unverified premises (U3, U4):
  - the `PhysicalResourceId` of every `AWS::IAM::Role` in the FunctionsStack (from `describe-stack-resource --logical-resource-id FunctionsStack` on `activity-app-stage`, then `list-stack-resources` on that stack);
  - the distinct `arn:aws:iam::aws:policy/...` strings in `aws cloudformation get-template --stack-name <FunctionsStack> --template-stage Processed`.

- [ ] **Step 5: Open the PR and let CI run**

  Expected: `test.yml` green. The three files are workflow and template only, so `lambda-build` and `swift test` do not exercise them. After merge, the push to `main` changes `.github/`, so `deploy-stage` takes its full path, still on the static keys. Expected: green.

- [ ] **Step 6: Commit**

  ```bash
  git add activity-oidc/template.yaml .github/workflows/oidc-roles.yml .github/workflows/oidc-trust-check.yml
  git commit -m "ci: add OIDC deploy role stack and trust check"
  ```

### Task 2: One-time provisioning (maintainer, explicit go per bullet)

There is no code in this task. Each step is a single action with an observable result, recorded on the merged Task 1 PR.

- [ ] **Step 1: Add the repository secret `AWS_ACCOUNT_ID`**

  Value: the 12-digit account ID.
  Check: `gh secret list --repo happitec-inc/FederatedActivityPublisher` shows `AWS_ACCOUNT_ID`.

- [ ] **Step 2: Restrict the environments**

  Use `PUT /repos/happitec-inc/FederatedActivityPublisher/environments/<name>` with `{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}` for `stage`, `production` and `infrastructure`. The last one is created by this call. Then add the rules with `POST /repos/happitec-inc/FederatedActivityPublisher/environments/<name>/deployment-branch-policies`:
  - `stage`: `{"name": "main", "type": "branch"}`
  - `production`: `{"name": "main", "type": "branch"}` and `{"name": "v*", "type": "tag"}`
  - `infrastructure`: `{"name": "main", "type": "branch"}`

  GitHub docs, "REST API endpoints for deployment branch policies": `custom_branch_policies` "must be set to `true` to use these endpoints", and `type` takes `branch` or `tag`. `stage` and `production` currently have no protection rules, so the `PUT` has nothing to overwrite.

  Check: `GET .../environments` shows the three environments with `custom_branch_policies: true`.

- [ ] **Step 3: Run `oidc-roles.yml` from `main`**

  Expected: green. The step summary lists the four role names. If it fails, do not widen anything: stop and bring the failure to the maintainers. U2 and U14 are the likely causes.

- [ ] **Step 4: Run `oidc-trust-check.yml` from `main`**

  Expected: green. Every expected failure failed and every expected success assumed the named role. The `stage` job's inventory shows:
  - every function role name beginning `activity-app-stage-` (U3);
  - managed policy ARNs that are exactly `arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole` and `arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole` (U4).

  If either differs, revise Appendix A and repeat Steps 3–4 before Task 3.

- [ ] **Step 5: Negative control for the environment rules**

  Push a throwaway branch `oidc-negative-control` from `main` and dispatch `oidc-trust-check.yml` on it.

  Expected:
  - the three environment-bound jobs are refused by the deployment branch rules before any step runs;
  - `no-environment` fails at its integration-read assume, because the subject is `ref:refs/heads/oidc-negative-control`.

  A green run here means the rules or the trust did not take effect: stop. Delete the branch afterwards.

### Task 3: `run-integration-tests.yml` on the integration role

**Files:**
- Modify: `.github/workflows/run-integration-tests.yml:32-37`

**Interfaces:**
- Consumes: role `FederatedActivityPublisher-github-actions-integration-read` (Task 1). Workflow-level `id-token: write` is already at lines 14–16.

- [ ] **Step 1: Replace the credentials step**

  Replace lines 32–37 with a step that has `role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/FederatedActivityPublisher-github-actions-integration-read` and the existing `aws-region` expression. Add a following step, "Show assumed role", that runs `aws sts get-caller-identity --query Arn --output text`.

  Check: `grep -n "AWS_ACCESS_KEY_ID\|AWS_SECRET_ACCESS_KEY" .github/workflows/run-integration-tests.yml` prints nothing.

- [ ] **Step 2: Open the PR; after merge, dispatch from `main` with `environment: stage`, then `environment: prod`**

  Expected:
  - Both runs are green.
  - "Show assumed role" prints `assumed-role/FederatedActivityPublisher-github-actions-integration-read/...` both times.
  - The prod run reads `/activity/prod/keys/client-token`. That run measures U6.

- [ ] **Step 3: Negative control**

  Dispatch with `environment: stage` from a non-`main` branch.
  Expected: fails at "Configure AWS credentials". This also confirms the change in Q3.

- [ ] **Step 4: Commit**

  ```bash
  git add .github/workflows/run-integration-tests.yml
  git commit -m "ci: integration tests assume a read-only OIDC role"
  ```

### Task 4: `deploy-stage.yml` on the stage and integration roles

**Files:**
- Modify: `.github/workflows/deploy-stage.yml`, in jobs `fast-deploy` (197–202), `build` (309–314 and 316–322) and `integration-tests` (422–427)

**Interfaces:**
- Consumes: roles `...-deploy-stage` and `...-integration-read`.

- [ ] **Step 1: Add job-level permissions**

  Give `fast-deploy`, `build` and `integration-tests` each `permissions: {contents: read, actions: read, id-token: write}`. Leave the workflow-level block (lines 10–12) as it is, so `detect` keeps its current scopes.

- [ ] **Step 2: Swap the credentials**

  - `fast-deploy` and `build`: `role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/FederatedActivityPublisher-github-actions-deploy-stage`.
  - `integration-tests`: the integration-read ARN.
  - Keep each step's existing `aws-region` expression.
  - Add the "Show assumed role" step after each.

- [ ] **Step 3: Prefix the SAM artifacts**

  In `build`'s "Package with SAM", add `--s3-prefix activity-app-stage` to `sam package`.

  This changes every artifact's S3 key. So the first deploy updates the code location of all 19 functions and both nested templates. That makes this deploy a real exercise of the Lambda, `s3:GetObject` and nested-stack grants, not a no-op.

- [ ] **Step 4: Check**

  Run: `grep -n "AWS_ACCESS_KEY_ID\|AWS_SECRET_ACCESS_KEY" .github/workflows/deploy-stage.yml`
  Expected: nothing.

- [ ] **Step 5: Open the PR; after merge, observe the push run**

  The merge changes `.github/`, so `detect` picks the full path. Expected:
  - `build` and `integration-tests` are green;
  - "Show assumed role" names `...-deploy-stage` in `build` and `...-integration-read` in `integration-tests`;
  - the package step uploads under `activity-app-stage/`.

  Check the fast path on the next merge that touches only `Sources/`. Expected: `fast-deploy` green, naming the stage role.

- [ ] **Step 6: Negative control**

  Task 2 Step 4 already measured that the stage role cannot read `activity-app-prod`, and that only the `stage` environment can assume it. For this run, the evidence is Step 4's empty grep plus the role named by "Show assumed role". Static keys would show as `assumed-role` being absent: an IAM user ARN instead. The final control is Task 6, where the secrets no longer exist.

- [ ] **Step 7: Commit**

  ```bash
  git add .github/workflows/deploy-stage.yml
  git commit -m "ci: deploy stage with an OIDC role"
  ```

### Task 5: `deploy-prod.yml`, `environment.yml` and `bootstrap.yml`

**Files:**
- Modify: `.github/workflows/deploy-prod.yml:9-10`, `:83-88` and `:92-96`
- Modify: `.github/workflows/environment.yml:4-5`, `:19-20` and `:28-33`
- Modify: `.github/workflows/bootstrap.yml:3-4`, `:22-23` and `:31-36`

**Interfaces:**
- Consumes: roles `...-deploy-prod` and `...-infra`, and the `infrastructure` environment (Task 2).

- [ ] **Step 1: `deploy-prod.yml`**

  - Workflow `permissions` become `{contents: read, id-token: write}`.
  - The credentials step uses `...-deploy-prod`, followed by "Show assumed role".
  - `sam package` gains `--s3-prefix activity-app-prod`.

- [ ] **Step 2: `environment.yml`**

  - Workflow `permissions` become `{contents: read, id-token: write}`.
  - Job `deploy` gains `environment: infrastructure`.
  - The credentials step uses `...-infra`, followed by "Show assumed role".

- [ ] **Step 3: `bootstrap.yml`**

  Apply the same three changes as Step 2. Then add, before "SAM build", a step named "Refuse a domain change on an existing stack". It runs:

  ```
  aws cloudformation describe-stacks --stack-name activity-bootstrap --query "Stacks[0].Parameters[?ParameterKey=='DomainName'].ParameterValue" --output text
  ```

  It fails if the stack exists and the value differs from `inputs.domain-name`. If the stack does not exist, the step passes. A changed `DomainName` would replace the retained hosted zone and certificate. The infra role holds no create permission for them, so the deploy would fail midway rather than cleanly.

- [ ] **Step 4: Check**

  Run: `grep -rn "AWS_ACCESS_KEY_ID\|AWS_SECRET_ACCESS_KEY" .github/`
  Expected: nothing.

- [ ] **Step 5: Open the PR; after merge, validate with explicit go per run**

  1. Dispatch `environment.yml` with `stage`.
     Expected: green; "No changes to deploy" (an empty changeset); assumed role `...-infra`.
  2. Dispatch `environment.yml` with `prod`. Same expectations.
  3. On the next published `v*` release, `deploy-prod` runs.
     Expected: green, with assumed role `...-deploy-prod`. The package uploads under `activity-app-prod/`, so all prod functions are updated, as stage's were in Task 4.

  Deciding the release timing is not part of this plan.

- [ ] **Step 6: Commit**

  ```bash
  git add .github/workflows/deploy-prod.yml .github/workflows/environment.yml .github/workflows/bootstrap.yml
  git commit -m "ci: prod and infrastructure stacks use OIDC roles"
  ```

### Task 6: Delete the static secrets (explicit approval required)

- [ ] **Step 1: Preconditions**

  All of the following must hold:
  - `grep -rn "AWS_ACCESS_KEY_ID\|AWS_SECRET_ACCESS_KEY" .github/` on `main` prints nothing.
  - There is a green OIDC run of each of the following:
    - `run-integration-tests` (stage and prod);
    - `deploy-stage` (full path, and fast path);
    - `deploy-prod` (release);
    - `environment.yml` (stage and prod).
  - `bootstrap.yml` either has a green OIDC run or is accepted without one (Q4).

- [ ] **Step 2: Delete the secrets**

  ```bash
  gh secret delete AWS_ACCESS_KEY_ID --repo happitec-inc/FederatedActivityPublisher
  gh secret delete AWS_SECRET_ACCESS_KEY --repo happitec-inc/FederatedActivityPublisher
  ```

  Check: `gh secret list` shows neither.

- [ ] **Step 3: Positive control after deletion**

  The next `deploy-stage` push run is green. Re-dispatch `run-integration-tests` with `stage`. Expected: green.

**Not in this plan:** rotating or deactivating the IAM user access key that the deleted secrets held. That is an IAM write with its own blast radius. CloudTrail timing suggests the key belongs to the account's admin IAM user [inferred], so other consumers may still use it. It is a separate decision (Q7).

---

## Open questions

- **Q1: Locus of the role definitions.** The options are (a), (b) and (c), compared in D1. Recommendation: (c), this repository deploying its own template through the org bootstrap role. (b) is the fallback if that role stops trusting public repositories.
- **Q2: Four roles, or three with wildcard-compressed policies.** The four roles are stage deploy, prod deploy, infra and integration read. Three roles exceed the 10,240-character limit for prod (D2). Recommendation: four.
- **Q3: Integration tests from branches.** `run-integration-tests.yml` was last dispatched from a non-`main` branch on 2026-06-16 (`test/media-upload-integration`). With the integration role trusting `ref:refs/heads/main` only, that stops working.

  Widening the trust to `ref:refs/heads/*` lets any writer's branch read the prod client token. Today any writer's branch can read the static keys, so the wider trust would still be no worse than today. Recommendation: `main` only.
- **Q4: `bootstrap.yml` validation.** Should someone dispatch a no-op `bootstrap.yml` run before Task 6, or accept it untested until the stack next needs a change? A no-op run needs the existing `domain-name` and `dns-mode` values, and the Task 5 guard refuses a mismatched domain.
- **Q5: Permissions boundary for the Lambda execution roles.** Add one to close the create-a-role-and-pass-it path described in D5, as a follow-up change to `activity-app/functions/template.yaml`.
- **Q6: `oidc-trust-check.yml` after cutover.** Keep it, as a dispatchable regression check for any change to the role template, or delete it after Task 6. Recommendation: keep.
- **Q7: The IAM user access key behind the deleted secrets.** Rotate, deactivate or leave it. This is a separate IAM-write decision, not part of this plan.
- **Q8: Role naming.** The org convention is one `<repo>-github-actions-deploy` role per repository. This plan uses four roles with suffixes. Do the suffixes need to be approved as part of the convention?

## Unverified premises, and what measures each

| # | Premise | Measured by |
|---|---|---|
| U1 | This repository presents the previous subject form, based on its creation date; both forms are trusted anyway. | Task 2 Step 4: the assume succeeds |
| U2 | The org bootstrap role's permissions suffice to create four named roles with inline policies in one stack. Its template grants `iam:CreateRole`, `iam:PutRolePolicy` and `iam:TagRole` on `role/*-github-*`, and the stack actions on `*-oidc*`. | Task 2 Step 3 |
| U3 | SAM-generated function role names begin `activity-app-<stage>-`. | Task 2 Step 4 inventory |
| U4 | SAM attaches exactly `AWSLambdaBasicExecutionRole` and `AWSLambdaSQSQueueExecutionRole` to the function roles. | Task 2 Step 4 inventory |
| U5 | `route53:ChangeResourceRecordSetsNormalizedRecordNames` compares against the record name as written in Appendix A: lowercase, no trailing dot. | Only measured when the CDN record changes. It fails closed on stage first. |
| U6 | `ssm:GetParameter --with-decryption` on the prod client token succeeds with the `kms:Decrypt` grant conditioned on `kms:ViaService`. | Task 3 Step 2 (prod run) |
| U7 | The SAM managed bucket's default encryption needs no KMS permission for `PutObject`. | Task 4 Step 5 |
| U8 | The CloudFormation handlers call nothing outside Appendix A for these templates. For example, the distribution update handler lists `cloudfront:CreateConnectionGroup` and `cloudfront:GetVpcOrigin`, which are omitted because neither feature is used. | Each validation run; for CloudFront, the first CDN change |
| U9 | Every action in Appendix A supports the resource-level ARN it is granted on. The catalog confirms that names exist, not their resource types; the Service Authorization Reference pages did not render for the tools used. | AccessDenied in the validation runs names the action and ARN |
| U10 | `Fn::ImportValue` in the role stack needs no extra permission on the caller (the org bootstrap role). | Task 2 Step 3 |
| U11 | `configure-aws-credentials@v6` uses OIDC when given only `role-to-assume`. | Task 2 Step 4 and every "Show assumed role" step |

---

## Appendix A: Inline policy statements

`<S>` is `stage` or `prod`, and `<A>` is `${AWS::AccountId}`. All regional ARNs use `${AWS::Region}`. `<Zone>` is the import of `${BootstrapStackName}-HostedZoneId`, and `<Domain>` is the import of `${BootstrapStackName}-DomainName`. `<DistId>` is `StageDistributionId` or `ProdDistributionId`.

### Deploy roles (`...-deploy-stage`, `...-deploy-prod`)

| Sid | Actions | Resource | Condition |
|---|---|---|---|
| `Stacks` | `cloudformation:` `CreateChangeSet`, `DescribeChangeSet`, `ExecuteChangeSet`, `DeleteChangeSet`, `ListChangeSets`, `DescribeStacks`, `DescribeStackEvents`, `DescribeStackResource`, `ListStackResources`, `GetTemplate`, `GetTemplateSummary`, `CreateStack`, `UpdateStack`, `DeleteStack`, `SetStackPolicy`, `GetStackPolicy`, `UpdateTerminationProtection` | `stack/activity-app-<S>/*`, `stack/activity-app-<S>-*/*` | |
| `EnvironmentOutputs` | `cloudformation:DescribeStacks` | `stack/activity-environment-<S>/*` | |
| `SamTransform` | `cloudformation:CreateChangeSet` | `arn:aws:cloudformation:<region>:aws:transform/Serverless-2016-10-31` | |
| `SamManagedStack` | `cloudformation:DescribeStacks` | `stack/aws-sam-cli-managed-default/*` | |
| `SamArtifactsBucket` | `s3:ListBucket`, `s3:GetBucketLocation` | `arn:aws:s3:::aws-sam-cli-managed-default-samclisourcebucket-*` | |
| `SamArtifactsObjects` | `s3:PutObject`, `s3:GetObject`, `s3:GetObjectVersion` | `arn:aws:s3:::aws-sam-cli-managed-default-samclisourcebucket-*/activity-app-<S>/*` | |
| `LambdaFunctions` | `lambda:` `CreateFunction`, `DeleteFunction`, `GetFunction`, `UpdateFunctionCode`, `UpdateFunctionConfiguration`, `PublishVersion`, `PutFunctionConcurrency`, `DeleteFunctionConcurrency`, `GetFunctionCodeSigningConfig`, `GetFunctionRecursionConfig`, `PutFunctionRecursionConfig`, `GetFunctionScalingConfig`, `PutFunctionScalingConfig`, `GetRuntimeManagementConfig`, `PutRuntimeManagementConfig`, `AddPermission`, `RemovePermission`, `GetPolicy`, `TagResource`, `UntagResource`, `ListTags` | `function:activity-app-*-<S>` | |
| `LambdaEventSourceMappings` | `lambda:` `CreateEventSourceMapping`, `GetEventSourceMapping`, `UpdateEventSourceMapping`, `DeleteEventSourceMapping`, `TagResource`, `UntagResource`, `ListTags` | `function:activity-app-*-<S>`, `event-source-mapping:*` | |
| `FunctionRoles` | `iam:` `CreateRole`, `GetRole`, `DeleteRole`, `UpdateRole`, `UpdateRoleDescription`, `UpdateAssumeRolePolicy`, `PutRolePolicy`, `GetRolePolicy`, `DeleteRolePolicy`, `ListRolePolicies`, `ListAttachedRolePolicies`, `TagRole`, `UntagRole`, `ListRoleTags` | `arn:aws:iam::<A>:role/activity-app-<S>-*` | |
| `FunctionRoleManagedPolicies` | `iam:AttachRolePolicy`, `iam:DetachRolePolicy` | `arn:aws:iam::<A>:role/activity-app-<S>-*` | `ArnEquals` `iam:PolicyARN`: `arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole`, `arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole` |
| `PassFunctionRoles` | `iam:PassRole` | `arn:aws:iam::<A>:role/activity-app-<S>-*` | `StringEquals` `iam:PassedToService`: `lambda.amazonaws.com` |
| `ApiGateway` | `apigateway:` `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `UpdateRestApiPolicy` | `arn:aws:apigateway:<region>::/restapis`, `.../restapis/*`, `.../tags/*` | |
| `CloudFrontDistribution` | `cloudfront:` `GetDistribution`, `GetDistributionConfig`, `UpdateDistribution`, `UpdateDistributionWithStagingConfig`, `TagResource`, `UntagResource`, `ListTagsForResource` | `arn:aws:cloudfront::<A>:distribution/<DistId>` | |
| `CloudFrontPolicies` | `cloudfront:` `Create`, `Get`, `Update` and `Delete` of each of `CachePolicy`, `OriginRequestPolicy` and `OriginAccessControl`: 12 actions | `arn:aws:cloudfront::<A>:cache-policy/*`, `...:origin-request-policy/*`, `...:origin-access-control/*` | |
| `CloudFrontFunction` | `cloudfront:` `CreateFunction`, `DescribeFunction`, `GetFunction`, `PublishFunction`, `UpdateFunction`, `DeleteFunction`, `TagResource`, `UntagResource`, `ListTagsForResource` | `arn:aws:cloudfront::<A>:function/activity-profile-rewrite-<S>` | |
| `DnsRecord` | `route53:ChangeResourceRecordSets` | `arn:aws:route53:::hostedzone/<Zone>` | `ForAllValues:StringEquals` `route53:ChangeResourceRecordSetsNormalizedRecordNames`: stage `stage.<Domain>`, prod `<Domain>` |
| `DnsRead` | `route53:GetHostedZone`, `route53:ListResourceRecordSets` | `arn:aws:route53:::hostedzone/<Zone>` | |
| `DnsLookups` | `route53:GetChange`, `route53:ListHostedZones` | `*` | |
| `MediaBucketPolicy` | `s3:GetBucketPolicy`, `s3:PutBucketPolicy`, `s3:DeleteBucketPolicy`, `s3:ListBucket` | `arn:aws:s3:::activity-media-<S>` | |
| `FrontendAssets` | `s3:PutObject` | `arn:aws:s3:::activity-media-<S>/media/frontend/*` | |

The two deploy roles differ only in `<S>`, `<DistId>` and the `DnsRecord` name.

### Infra role (`...-infra`)

| Sid | Actions | Resource |
|---|---|---|
| `Stacks` | `cloudformation:` `CreateChangeSet`, `DescribeChangeSet`, `ExecuteChangeSet`, `DeleteChangeSet`, `DescribeStacks`, `DescribeStackEvents`, `GetTemplate`, `GetTemplateSummary` | `stack/activity-environment-stage/*`, `stack/activity-environment-prod/*`, `stack/activity-bootstrap/*` |
| `SamTransform` | `cloudformation:CreateChangeSet` | `arn:aws:cloudformation:<region>:aws:transform/Serverless-2016-10-31` |
| `MediaBucketConfig` | `s3:` `CreateBucketMetadataTableConfiguration`, `DeleteBucketMetadataTableConfiguration`, `DeleteBucketWebsite`, `GetAccelerateConfiguration`, `GetAnalyticsConfiguration`, `GetBucketAbac`, `GetBucketCORS`, `GetBucketLogging`, `GetBucketMetadataTableConfiguration`, `GetBucketNotification`, `GetBucketObjectLockConfiguration`, `GetBucketOwnershipControls`, `GetBucketPublicAccessBlock`, `GetBucketTagging`, `GetBucketVersioning`, `GetBucketWebsite`, `GetEncryptionConfiguration`, `GetIntelligentTieringConfiguration`, `GetInventoryConfiguration`, `GetLifecycleConfiguration`, `GetMetricsConfiguration`, `GetReplicationConfiguration`, `ListBucket`, `ListTagsForResource`, `PutAccelerateConfiguration`, `PutAnalyticsConfiguration`, `PutBucketAbac`, `PutBucketAcl`, `PutBucketCORS`, `PutBucketLogging`, `PutBucketNotification`, `PutBucketObjectLockConfiguration`, `PutBucketOwnershipControls`, `PutBucketPublicAccessBlock`, `PutBucketTagging`, `PutBucketVersioning`, `PutBucketWebsite`, `PutEncryptionConfiguration`, `PutIntelligentTieringConfiguration`, `PutInventoryConfiguration`, `PutLifecycleConfiguration`, `PutMetricsConfiguration`, `PutReplicationConfiguration`, `TagResource`, `UntagResource`, `UpdateBucketMetadataAnnotationTableConfiguration`, `UpdateBucketMetadataInventoryTableConfiguration`, `UpdateBucketMetadataJournalTableConfiguration` | `arn:aws:s3:::activity-media-stage`, `arn:aws:s3:::activity-media-prod` |
| `Table` | `dynamodb:` `DescribeTable`, `UpdateTable`, `DescribeTimeToLive`, `UpdateTimeToLive`, `DescribeContinuousBackups`, `UpdateContinuousBackups`, `DescribeContributorInsights`, `UpdateContributorInsights`, `DescribeKinesisStreamingDestination`, `EnableKinesisStreamingDestination`, `DisableKinesisStreamingDestination`, `UpdateKinesisStreamingDestination`, `GetResourcePolicy`, `PutResourcePolicy`, `DeleteResourcePolicy`, `TagResource`, `UntagResource`, `ListTagsOfResource` | `table/activity-stage`, `table/activity-stage/index/*`, `table/activity-prod`, `table/activity-prod/index/*` |
| `Queues` | `sqs:` `GetQueueAttributes`, `SetQueueAttributes`, `ListQueueTags`, `TagQueue`, `UntagQueue` | `activity-delivery-<stage\|prod>`, `activity-delivery-dlq-<stage\|prod>` (four ARNs) |
| `AlarmTopic` | `sns:` `CreateTopic`, `DeleteTopic`, `GetTopicAttributes`, `SetTopicAttributes`, `Subscribe`, `Unsubscribe`, `ListSubscriptionsByTopic`, `GetDataProtectionPolicy`, `PutDataProtectionPolicy`, `TagResource`, `UntagResource`, `ListTagsForResource` | `activity-dlq-alarm-stage`, `activity-dlq-alarm-prod` |
| `Alarm` | `cloudwatch:` `PutMetricAlarm`, `DeleteAlarms`, `TagResource`, `UntagResource`, `ListTagsForResource` | `alarm:activity-dlq-depth-stage`, `alarm:activity-dlq-depth-prod` |
| `AlarmRead` | `cloudwatch:DescribeAlarms` | `*` |
| `BootstrapZone` | `route53:` `GetHostedZone`, `GetChange`, `ListTagsForResource`, `ChangeTagsForResource`, `UpdateHostedZoneComment`, `UpdateHostedZoneFeatures`, `CreateQueryLoggingConfig`, `DeleteQueryLoggingConfig`, `ListQueryLoggingConfigs` | `arn:aws:route53:::hostedzone/<Zone>` (and `change/*` for `GetChange`) |
| `BootstrapCertificate` | `acm:` `DescribeCertificate`, `ListTagsForCertificate`, `AddTagsToCertificate`, `RemoveTagsFromCertificate`, `UpdateCertificateOptions` | the import of `${BootstrapStackName}-CertificateArn` |

The SNS topic and the alarm are not retained, so they keep create and delete. The table, bucket and queues are retained and get neither.

### Integration-read role (`...-integration-read`)

| Sid | Actions | Resource | Condition |
|---|---|---|---|
| `AppOutputs` | `cloudformation:DescribeStacks` | `stack/activity-app-stage/*`, `stack/activity-app-prod/*` | |
| `ProdClientToken` | `ssm:GetParameter` | `arn:aws:ssm:<region>:<A>:parameter/activity/prod/keys/client-token` | |
| `DecryptViaSsm` | `kms:Decrypt` | `arn:aws:kms:<region>:<A>:key/*` | `StringEquals` `kms:ViaService`: `ssm.<region>.amazonaws.com` |
