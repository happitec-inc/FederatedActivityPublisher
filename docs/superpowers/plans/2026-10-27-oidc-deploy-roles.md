# OIDC Deploy Roles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every GitHub Actions job here that talks to AWS assumes a repo-scoped IAM role through GitHub OIDC. After that, the static key secrets `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are deleted.

**Architecture:** One plain CloudFormation template, `activity-oidc/template.yaml`, defines everything in this repo's role stack:

- Five IAM roles, each trusting exactly one OIDC subject of this repository: stage deploy, prod deploy, infrastructure, stage integration read, and integration read.
- Two permissions-boundary managed policies, one per stage. Every Lambda execution role the deploy roles create or change must carry its stage's boundary.

A manually dispatched workflow, bound to its own environment, deploys the role stack. It runs either through an existing org-level bootstrap role that can create this repo's role stack, or, for self-hosters, through credentials of their own.

These changes land first, on the current credentials:

- the function-role boundary;
- per-stage SAM artifact prefixes with forced uploads;
- SHA-pinned third-party actions.

Then workflows move to `role-to-assume` in this order: integration tests, stage, prod and infrastructure. Docs follow, and the static secrets are deleted last.

**Tech Stack:** GitHub Actions, `aws-actions/configure-aws-credentials` (pinned by SHA), AWS SAM CLI through `./.github/actions/setup-sam-portable`, CloudFormation and IAM.

**Spec:** None separate. Moving to OIDC was settled 2026-10-27, and the requirements are restated under Global Constraints. "Decisions" argues each choice.

## Global Constraints

- **Trust.** Each role trusts the account's GitHub OIDC provider (`token.actions.githubusercontent.com`) with `StringEquals` on two claims:
  - `aud` = `sts.amazonaws.com`;
  - `sub` = this repository's subject for that role, in both the previous form `repo:<org>/<repo>:<suffix>` and the immutable form `repo:<org>@<org-id>/<repo>@<repo-id>:<suffix>`.

  No wildcards. The org, repo and IDs are template parameters. Their defaults are this repository's values: `happitec-inc`, `FederatedActivityPublisher`, owner ID `174214171` and repo ID `1193951865`, read from `GET /repos/happitec-inc/FederatedActivityPublisher` on 2026-10-27.
- **No AWS managed policy** is attached to any of the five roles, and no role is shared with another project.
- **Every IAM role-write action of the deploy roles is conditioned on `iam:PermissionsBoundary`** equal to that stage's boundary policy. `iam:UpdateAssumeRolePolicy` is not granted. `iam:DeleteRolePermissionsBoundary` is explicitly denied.
- **Names** follow the org's per-repo OIDC role pattern, `<repo>-github-actions-<purpose>`:
  - roles: `FederatedActivityPublisher-github-actions-deploy-stage`, `...-deploy-prod`, `...-infra`, `...-integration-stage-read` and `...-integration-read`;
  - boundaries: `activity-app-stage-function-boundary` and `activity-app-prod-function-boundary`;
  - stack: `FederatedActivityPublisher-oidc`.
- **The template has no `Transform:`** and stays under 51,200 bytes, the CloudFormation limit for an inline template body. It can then be deployed from the console, the CLI or the dispatch workflow without an artifact bucket.
- **Each role's inline policies total at most 10,240 characters, whitespace excluded.** That is IAM's aggregate role-policy limit, from the IAM quotas page.
- **Identifiers stay out of the repository and out of public logs.**
  - The account ID is the repository secret `AWS_ACCOUNT_ID`.
  - The bootstrap role ARN is `OIDC_BOOTSTRAP_ROLE_ARN`, a secret of the `oidc-bootstrap` environment.
  - Both are secrets, not variables, because Actions logs print each step's resolved `with:` inputs. Secrets appear as `***`, variables in clear text. In this repository's `deploy-prod` run 39721690715, the step header shows `aws-access-key-id: ***` and `aws-region: us-east-1`.
- **Nothing runs `aws` or `sam` against the account from a maintainer workstation.** All maintainer-side AWS changes are workflow runs. Workflow changes are validated by PR CI and by real runs. Runner VMs are never used, cloned or entered by hand.
- **Explicit go required.** Each of these needs an explicit go from a maintainer, recorded on the PR or run that carries it:
  - creating a secret or environment;
  - changing environment or ruleset settings;
  - dispatching a workflow that mutates AWS;
  - deleting secrets.
- **Commits** are short and describe the change only.

## Review Focus

- **Jobs bound to an environment present `environment:<name>`, not `ref:`.** GitHub docs, "OpenID Connect reference": "The subject claim includes the environment name when the job references an environment." `deploy-stage`'s `fast-deploy` and `build` jobs and `deploy-prod`'s job are environment-bound. Task 5's trust check pins each role to its one subject.
- **Every function role carries the boundary before a deploy role first touches it.** The deploy roles can write to a role only if it already carries the right boundary. If Task 3 has not reached a stage, the first OIDC deploy there fails on the first role change. That failure is safe, but it is a failure. Task 7 and Task 8 check that the boundary is in place first.
- **Rollback must be able to read the previous artifacts.** The deploy roles can read only `activity-app-<stage>/*` in the SAM bucket. Task 4 ships the prefix on the current credentials, so the template a failed OIDC deploy rolls back to already points at prefixed keys.
- **A job holding `id-token: write` can mint a token in any of its steps.**
  - Actions used in those jobs are pinned to commit SHAs: `happitec-inc/public-actions/*@main` and `aws-actions/configure-aws-credentials@v6` today (Task 4).
  - The Swift build runs in a container that receives only `HOME`. `scripts/in-build-image.sh` passes `-e HOME=/tmp` and no other environment, so the token request variables don't reach package code.
- **Job-level `permissions` sets every unlisted scope to `none`.** GitHub docs, workflow syntax: "If you specify the access for any of these permissions, all of those that are not specified are set to `none`." The three AWS jobs in `deploy-stage.yml` restate `contents: read` and `actions: read`.

---

## Current state (read on `origin/main` at `6386a77`, 2026-10-27)

Seven steps authenticate with the static secrets, through `aws-actions/configure-aws-credentials@v6` with `aws-access-key-id` and `aws-secret-access-key`:

| Workflow | Job | Lines | Trigger | `environment:` | AWS calls after the step |
|---|---|---|---|---|---|
| `bootstrap.yml` | `deploy` | 31–36 | `workflow_dispatch` | none | `sam deploy` stack `activity-bootstrap`; `describe-stacks` |
| `environment.yml` | `deploy` | 28–33 | `workflow_dispatch` | none | `sam deploy` stack `activity-environment-<stage>`; `describe-stacks` |
| `deploy-stage.yml` | `fast-deploy` | 197–202 | push to `main` | `stage` | `describe-stack-resource`, `list-stack-resources`, `lambda update-function-code` |
| `deploy-stage.yml` | `build` | 309–314 | push to `main`, dispatch | `stage` | `sam package --resolve-s3`, `sam deploy` stack `activity-app-stage`, `describe-stacks`, `s3 sync` |
| `deploy-stage.yml` | `integration-tests` | 422–427 | after the above | none | `describe-stacks activity-app-stage` |
| `deploy-prod.yml` | `build-and-deploy` | 83–88 | release published, dispatch | `production` | same as `build`, for `prod` |
| `run-integration-tests.yml` | `test` | 32–37 | `workflow_dispatch` | none | `describe-stacks activity-app-<env>`; prod only: `ssm get-parameter /activity/prod/keys/client-token --with-decryption` |

No other workflow references an AWS secret: a grep of `.github/` for `secrets.AWS` and `aws ` matched only these five files.

Docs that name the static secrets:

- `README.md:151–152`, the "Required GitHub Secrets" table;
- `Sources/ActivityPubCore/Documentation.docc/DeployYourOwn.md:20–29`;
- `Sources/ActivityPubCore/Documentation.docc/BuildingAndDeploying.md:25–27`, `:54–56`, `:94–96` and `:113–115`.

`AWSPermissions.md` describes a deploying principal in general terms. `AGENTS.md:48` shows static keys for the local `ActivityProvisioner` CLI, which runs on an operator's machine, not in CI, and is not in scope.

Other measured facts:

- **Environments.** `stage` and `production` exist with no protection rules and `deployment_branch_policy: null` (`GET /repos/{owner}/{repo}/environments`).
- **Subject form.** The repository was created 2026-03-27. GitHub docs, "OpenID Connect reference": repositories created after July 15, 2026 use the immutable subject; older ones "keep the previous format unless they opt in."
- **SAM bucket.** The managed artifact bucket's name starts with `aws-sam-cli-managed-default-samclisourcebucket-`, from the `Managed S3 bucket:` line of this repository's `deploy-prod` run 39721690715. In the same run, `aws-actions/configure-aws-credentials@v6` resolved to SHA `e1253824e5c10ff9df46874f81ed3ec929e19cfd`.
- **SAM CLI flags.** SAM CLI 1.166.2 has `--s3-prefix` and `--force-upload` on both `sam package` and `sam deploy` (measured with `--help`).
- **SAM properties.**
  - `PermissionsBoundary` is a supported `Globals.Function` property (SAM docs, "Globals section").
  - On a function it "works only if the role is generated for you" and "is passed directly to the `PermissionsBoundary` property of an `AWS::IAM::Role`" (SAM docs, `AWS::Serverless::Function`).
  - Every function in `activity-app/functions/template.yaml` uses generated roles: `Policies:`, no `Role:`.
- **No service role.** `sam deploy` here runs without `--role-arn`, so CloudFormation acts with the caller's credentials for every resource, nested stacks included.

## Decisions

### D1: Where the roles are defined (Q1; recommendation c)

This repository is public. GitHub docs, "Managing GitHub Actions settings for a repository" → "Allowing access to components in a private repository", give both sharing options for a private repository's actions and reusable workflows the same rule: "Access is allowed only from private repositories." So any reusable workflow this repository calls must live in a public repository.

| Option | What changes | Smallest mechanism | Correct locus | Cost |
|---|---|---|---|---|
| (a) Add the roles to `activity-bootstrap` and deploy them with `bootstrap.yml` | One template gains roles | Reuses a stack and workflow | **No.** The DNS-and-certificate stack takes on a second job, CI identity. `bootstrap.yml`'s `domain-name` and `dns-mode` inputs put the hosted zone at risk on every role edit. The roles would need a broad credential to create them and could later rewrite their own policies. | A broad credential in CI once; a role that can change itself afterwards |
| (b) Publish a generic, opt-in reusable role workflow in `happitec-inc/public-actions`, keeping its existing defaults | A new shared component in another repository | Adds a component | Right for a tool many public repos share | A cross-repo change and review; still has to emit five roles and two boundaries |
| **(c) This repository owns `activity-oidc/template.yaml` and deploys it with `oidc-roles.yml`** | One template and one small workflow here | **Yes.** No new component elsewhere | **Yes.** The roles and boundaries live with their only consumer, and the template is plain CloudFormation that self-hosters can deploy with their own credentials | Hand-written IAM to review |

**Recommendation: (c).** For this repository, `oidc-roles.yml` authenticates through an existing org-level bootstrap role that can create this repo's role stack. Its ARN is in the environment secret `OIDC_BOOTSTRAP_ROLE_ARN`. Self-hosters set that secret to a role of their own or deploy the template once by hand (Task 9).

Whether this bootstrap path covers everything the template contains is measured in Task 2. Its output is kept out of the public log, not predicted here. If it does not cover the template, stop and bring it to the maintainers; (b) is the fallback.

### D2: Five roles (Q2)

| Role | Trusted `sub` suffix | Used by |
|---|---|---|
| `...-deploy-stage` | `environment:stage` | `deploy-stage.yml` jobs `fast-deploy` and `build` |
| `...-deploy-prod` | `environment:production` | `deploy-prod.yml` job `build-and-deploy` |
| `...-infra` | `environment:infrastructure` | `environment.yml` and `bootstrap.yml` |
| `...-integration-stage-read` | `ref:refs/heads/main` | `deploy-stage.yml` job `integration-tests` |
| `...-integration-read` | `environment:integration` | `run-integration-tests.yml` (stage and prod) |

- **Stage and prod deploy roles are split** because the environment boundary costs nothing: the jobs are already environment-bound. Task 2 adds deployment branch rules so the boundary also restricts refs:
  - `stage`, `infrastructure`, `integration` and `oidc-bootstrap`: `main` only;
  - `production`: `main` and tags `v*`.

  The tag rule limits which refs can deploy, not who can create them, so Task 2 also restricts creation of `v*` tags with a ruleset (Q9).
- **`infra` is split from the deploy roles.** The data and DNS stacks change rarely and by hand. Keeping their grants off the deploy roles means the roles used on every merge and release cannot reconfigure the table, bucket, queues, hosted zone or certificate. It also keeps each deploy role's inline policy well under the IAM limit, which Task 1 Step 2 measures from the committed template.
- **There are two integration roles.** That way the prod client token is readable only from jobs bound to the `integration` environment, not from every job that runs on `main`. The push-triggered stage test job runs third-party test code with its credentials in the environment, so it gets a role that can read only `activity-app-stage`'s outputs.

### D3: Permission derivation

1. **The AWS calls every workflow step makes** are listed in the current-state table.
2. **For every resource type the templates create**, the CloudFormation registry schema lists the permissions its handlers call. These are `handlers.<op>.permissions` and `tagging.permissions` in `CloudformationSchema.zip`, from `https://schema.cloudformation.us-east-1.amazonaws.com/CloudformationSchema.zip`, downloaded 2026-10-27.

   The functions stack yields `AWS::Lambda::Function`, `AWS::IAM::Role`, `AWS::Lambda::Permission`, `AWS::Lambda::EventSourceMapping` and `AWS::ApiGateway::RestApi`, `Deployment` and `Stage`.

   The CDN stack declares CloudFront `CachePolicy`, `OriginRequestPolicy`, `OriginAccessControl`, `Function` and `Distribution`, plus `S3::BucketPolicy` and `Route53::RecordSet`.

   The environment stack declares `S3::Bucket`, `DynamoDB::Table`, `SQS::Queue`, `SNS::Topic` and `CloudWatch::Alarm`. The bootstrap stack declares `Route53::HostedZone` and `CertificateManager::Certificate`.
3. **The rule.**
   - Grant the handler actions of the resource's own service, scoped to this repository's resource names.
   - Grant cross-service actions only for features the templates use: `iam:PassRole` to Lambda, and `s3:GetObject` and `s3:GetObjectVersion` on the code artifacts.
   - Leave out actions for unused features: VPC, EFS, KMS customer keys, code-signing writes, layers, capacity providers, S3 Tables, Kinesis, and DynamoDB item operations.
4. **Retained data resources get no create or delete.** The table, media bucket, queues, hosted zone and certificate all have `DeletionPolicy: Retain`. A replacement must fail rather than create an empty twin.
5. **Event source mappings use the form AWS documents.** Lambda docs, "Granting users access to an Event Function", statement `DevelopEventSourceMappings`:
   - `lambda:CreateEventSourceMapping`, `lambda:UpdateEventSourceMapping` and `lambda:DeleteEventSourceMapping` are granted on `"Resource": "*"`, with a `lambda:FunctionArn` condition.
   - `lambda:GetEventSourceMapping` and `lambda:ListEventSourceMappings` are among the actions that "don't support resource patterns or conditions", so they are granted on `*`.
6. **The boundary content is the union of what the function roles hold today.**
   - SAM policy templates `DynamoDBCrudPolicy`, `DynamoDBReadPolicy`, `SQSSendMessagePolicy` and `SSMParameterReadPolicy`, with actions as listed in SAM docs, "AWS SAM policy template list".
   - The inline `s3:PutObject` and `kms:Decrypt` statements in `activity-app/functions/template.yaml`.
   - The managed policies SAM attaches, `AWSLambdaBasicExecutionRole` (`logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`) and `AWSLambdaSQSQueueExecutionRole` (adds `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`), with documents from the AWS Managed Policy Reference.

   Each boundary narrows these to its stage's resources. The boundary only caps permissions, so it removes nothing a function uses today if it covers that union.
7. **Name check.** Every action and condition key in Appendix A is in the AWS Policy Generator catalog, `https://awspolicygen.s3.amazonaws.com/js/policies.js`, fetched 2026-10-27. Task 1 Step 2 reruns the check against the committed template, with a misspelled-name negative control.

   The registry lists a few API operation names that are not IAM actions, and they are excluded. Examples: `s3:DeleteBucketCors`, whose IAM action is `s3:PutBucketCORS`, and `cloudfront:CreateDistributionWithTags`. `sqs:SendMessageBatch` is also absent from the catalog, so the boundary grants `sqs:SendMessage`.

### D4: The first creation of the role stack

The role stack is created by a dispatch of `oidc-roles.yml` from `main`, in a job bound to the `oidc-bootstrap` environment, with an explicit go. That job reads `OIDC_BOOTSTRAP_ROLE_ARN` and assumes it over OIDC. The static keys are never used for it.

The job writes the assume and deploy output to files under `$RUNNER_TEMP` and prints only `ok` or `failed`. Failure detail is read in the CloudFormation console by a maintainer with account access. Nothing about the bootstrap credential's scope reaches this public repository's logs.

### D5: Least-privilege limits (stated, not hidden)

- **A deploy role can still create a function role with any trust policy.** `iam:CreateRole` has no condition key for the trust document. The boundary caps what such a role can do to its stage's table, queue, parameters, media objects and log groups.
- **Resources with generated IDs are scoped by type, not by stage.** These are API Gateway `/restapis/*` and CloudFront cache policies, origin request policies and origin access controls. The CloudFront distribution is scoped by ID from `ACTIVITY_DISTRIBUTION_ID_STAGE` or `_PROD`, which Task 4 checks against the CDN stack's output on every deploy. The Route 53 record write is scoped to the one record name of each stage.
- **`route53:ListHostedZones`, `route53:GetChange`, `cloudwatch:DescribeAlarms`, `ssm:DescribeParameters` and the event-source-mapping reads are on `*`.** All are read-only.
- **The first CDN-template change after cutover is the first exercise of the CloudFront distribution and Route 53 record grants.** It runs on stage before prod.

---

## File structure

| File | Change | Responsibility |
|---|---|---|
| `activity-oidc/template.yaml` | Create | Five roles, two boundary policies, outputs (role names only) |
| `.github/workflows/oidc-roles.yml` | Create | Dispatch-only, `environment: oidc-bootstrap`: deploy `FederatedActivityPublisher-oidc` with quiet output |
| `.github/workflows/oidc-trust-check.yml` | Create | Dispatch-only: per-role positive and negative assumes, scope checks, boundary checks, distribution check, inventory |
| `activity-app/functions/template.yaml` | Modify `Globals.Function` (75–107) | `PermissionsBoundary` |
| `.github/workflows/deploy-stage.yml` | Modify | `--s3-prefix`, `--force-upload`, SHA pins, distribution guard; later the roles and job permissions |
| `.github/workflows/deploy-prod.yml` | Modify | Same, for prod |
| `.github/workflows/run-integration-tests.yml` | Modify `14–37` | `environment: integration`; integration role |
| `.github/workflows/environment.yml` | Modify `4–5`, `19–33` | `environment: infrastructure`; infra role |
| `.github/workflows/bootstrap.yml` | Modify `3–4`, `22–36` | `environment: infrastructure`; infra role; domain-change guard |
| `README.md`, `DeployYourOwn.md`, `BuildingAndDeploying.md`, `AWSPermissions.md` | Modify | The OIDC setup, for this repository and for forks |

---

### Task 1: Role template and the two dispatch workflows

**Files:**
- Create: `activity-oidc/template.yaml`
- Create: `.github/workflows/oidc-roles.yml`
- Create: `.github/workflows/oidc-trust-check.yml`

**Interfaces:**
- Produces:
  - stack `FederatedActivityPublisher-oidc`, with outputs `StageDeployRoleName`, `ProdDeployRoleName`, `InfraRoleName`, `IntegrationStageReadRoleName` and `IntegrationReadRoleName` (values are role names);
  - managed policies `arn:aws:iam::<account>:policy/activity-app-<stage>-function-boundary`;
  - the role ARN form `arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/<role name>`.

- [ ] **Step 1: Write `activity-oidc/template.yaml`**

  The template has no `Transform`.

  `Parameters`:
  - `GitHubOrg` (default `happitec-inc`) and `GitHubRepo` (default `FederatedActivityPublisher`);
  - `GitHubOrgId` (default `"174214171"`) and `GitHubRepoId` (default `"1193951865"`), both with `AllowedPattern: "^[0-9]+$"`;
  - `BootstrapStackName` (default `activity-bootstrap`);
  - `StageDistributionId` and `ProdDistributionId`, each with default `""`.

  `Conditions`: `HasStageDistribution` and `HasProdDistribution`, true when the parameter is not empty.

  `Resources`:
  - **Two `AWS::IAM::ManagedPolicy` resources**, `StageFunctionBoundary` and `ProdFunctionBoundary`, with `ManagedPolicyName: activity-app-<stage>-function-boundary` and documents from Appendix A.4.
  - **Five `AWS::IAM::Role` resources**:
    - `RoleName: !Sub ${GitHubRepo}-github-actions-<suffix>` and `MaxSessionDuration: 3600`;
    - one inline policy with the statements in Appendix A;
    - `Tags: [{Key: Project, Value: !Ref GitHubRepo}]`.
  - **Imports.** `Fn::ImportValue` of `${BootstrapStackName}-HostedZoneId`, `-DomainName` and `-CertificateArn` feeds the zone ARN, the record names and the certificate ARN.

  Each role's trust policy is this, with only `<suffix>` varying (D2):

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

  1. **Template size.** Run `wc -c activity-oidc/template.yaml`. Expected: under 51,200.
  2. **Action names.** Extract every `service:Action` token from the template and check each against `serviceMap[*].Actions` and `conditionKeys` in `https://awspolicygen.s3.amazonaws.com/js/policies.js`.
     - Run it once with a misspelled action added. Expected: that name is reported.
     - Remove it and run again. Expected: zero missing.
  3. **Policy size.** For each role, minify its inline policy with every `!Sub` and import replaced by a real-length placeholder:
     - a 12-digit account ID;
     - a 21-character zone ID;
     - a 14-character distribution ID;
     - a UUID certificate ID;
     - a 30-character domain.

     Expected: under 10,240 characters per role. Each boundary is a managed policy, so check it against the 6,144-character managed-policy limit, also from the IAM quotas page.

- [ ] **Step 3: Write `.github/workflows/oidc-roles.yml`**

  - Trigger: `workflow_dispatch` only.
  - `permissions: {contents: read, id-token: write}`.
  - `concurrency: {group: oidc-roles, cancel-in-progress: false}`.
  - One job with `if: github.ref == 'refs/heads/main'`, `environment: oidc-bootstrap`, and the usual `runs-on` expression: `${{ vars.RUNNER_LABELS_LINUX && fromJSON(vars.RUNNER_LABELS_LINUX) || 'ubuntu-latest' }}`.

  Steps:
  1. `actions/checkout@v6`.
  2. `./.github/actions/setup-sam-portable`.
  3. **Assume.**
     - Request a token: `curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com"`. Both variables are listed in GitHub docs, "OpenID Connect reference".
     - Run `aws sts assume-role-with-web-identity --role-arn "$OIDC_BOOTSTRAP_ROLE_ARN" --role-session-name oidc-roles --web-identity-token <token>`, with stdout and stderr sent to files in `$RUNNER_TEMP`.
     - Pass each returned credential value to `::add-mask::`, then write it to `$GITHUB_ENV`.
     - Print `bootstrap assume: ok` or `bootstrap assume: failed` and exit accordingly.
  4. **Deploy.** Run:

     ```
     sam deploy --template-file activity-oidc/template.yaml --stack-name FederatedActivityPublisher-oidc --capabilities CAPABILITY_NAMED_IAM --no-confirm-changeset --no-fail-on-empty-changeset --region ${{ vars.AWS_REGION || 'us-east-1' }} --parameter-overrides StageDistributionId=${{ vars.ACTIVITY_DISTRIBUTION_ID_STAGE }} ProdDistributionId=${{ vars.ACTIVITY_DISTRIBUTION_ID_PROD }}
     ```

     Redirect its output to `$RUNNER_TEMP/deploy.log`. Print `role stack: ok` or `role stack: failed (see the stack events in the CloudFormation console)`.
  5. **Outputs.** On success only, append `describe-stacks --stack-name FederatedActivityPublisher-oidc --query "Stacks[0].Outputs"` to `$GITHUB_STEP_SUMMARY`. These are role names.

  No step uploads `$RUNNER_TEMP`.

- [ ] **Step 4: Write `.github/workflows/oidc-trust-check.yml`**

  Trigger: `workflow_dispatch`. Workflow `permissions: {contents: read, id-token: write}`. One job per subject.

  **Negative assumes.** Each one requests a token with the same `curl` as Step 3, calls `aws sts assume-role-with-web-identity` for the target role, and passes only if stderr contains `AccessDenied`. Any other error fails the job, so a typo or network fault cannot count as a pass.

  **Positive assume.** It uses the pinned `configure-aws-credentials` and runs after the negatives.

  **Scope checks.** Each sends stdout to `/dev/null` and passes only on an `AccessDenied` or `AccessDeniedException` error.

  | Job | `environment:` | Must be denied | Must assume | Scope checks (must be denied) |
  |---|---|---|---|---|
  | `no-environment` | none | stage, prod, infra, integration-read | integration-stage-read | `describe-stacks activity-app-prod`; `ssm get-parameter /activity/prod/keys/client-token` |
  | `stage` | `stage` | prod, infra, both integration roles | deploy-stage | `describe-stacks activity-app-prod`; the boundary checks below |
  | `production` | `production` | stage, infra, both integration roles | deploy-prod | `describe-stacks activity-app-stage` |
  | `infrastructure` | `infrastructure` | stage, prod, both integration roles | infra | `describe-stacks activity-app-prod` |
  | `integration` | `integration` | stage, prod, infra, integration-stage-read | integration-read | `describe-stacks activity-environment-prod` |

  **Boundary checks** in `stage`, all against role names beginning `activity-app-stage-oidc-check-`, with the Lambda trust document:
  - `iam create-role` with no boundary: denied.
  - `iam create-role` with `--permissions-boundary` set to the prod boundary: denied.
  - `iam create-role --role-name FederatedActivityPublisher-github-actions-oidc-check`: denied (outside the prefix).
  - **Positive control:** `iam create-role` with the stage boundary succeeds.
    - On that role, `iam delete-role-permissions-boundary` is denied.
    - `iam delete-role` then succeeds.

    A step with `if: always()` deletes the role if it still exists.

  **Distribution check** in `stage` and `production`: the `CloudFrontDistributionId` output of `activity-app-<stage>` equals `vars.ACTIVITY_DISTRIBUTION_ID_<STAGE>`. If it does not, fail with both values; distribution IDs are not secrets.

  **Inventory** in `stage`, printed:
  - the `PhysicalResourceId` of every `AWS::IAM::Role` in the FunctionsStack, found with `describe-stack-resource --logical-resource-id FunctionsStack` on `activity-app-stage`, then `list-stack-resources`;
  - each role's `PermissionsBoundary.PermissionsBoundaryArn`, from `iam get-role`, with the account ID masked;
  - the distinct `arn:aws:iam::aws:policy/...` strings in `cloudformation get-template --template-stage Processed` of the FunctionsStack.

- [ ] **Step 5: Open the PR**

  Expected: `test.yml` green. After merge, the push changes `.github/`, so `deploy-stage` runs its full path on the static keys. Expected: green.

- [ ] **Step 6: Commit**

  ```bash
  git add activity-oidc/template.yaml .github/workflows/oidc-roles.yml .github/workflows/oidc-trust-check.yml
  git commit -m "ci: add OIDC role stack and trust check"
  ```

### Task 2: One-time setup (maintainer, explicit go per step)

There is no code in this task. Record each result on the merged Task 1 PR.

- [ ] **Step 1: Environments**

  Use `PUT /repos/happitec-inc/FederatedActivityPublisher/environments/<name>` with `{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}` for `stage`, `production`, `infrastructure`, `integration` and `oidc-bootstrap`. The last three are created by this call.

  Then add rules with `POST .../environments/<name>/deployment-branch-policies`:
  - `production`: `{"name": "main", "type": "branch"}` and `{"name": "v*", "type": "tag"}`;
  - all others: `{"name": "main", "type": "branch"}`.

  GitHub docs, "REST API endpoints for deployment branch policies": `custom_branch_policies` "must be set to `true` to use these endpoints", and `type` is `branch` or `tag`.

  Check: `GET .../environments` shows the five environments with `custom_branch_policies: true`.

- [ ] **Step 2: Secrets**

  - Repository secret `AWS_ACCOUNT_ID`.
  - `oidc-bootstrap` environment secret `OIDC_BOOTSTRAP_ROLE_ARN`.

  Check: `gh secret list` and `gh secret list --env oidc-bootstrap` show the names.

- [ ] **Step 3: Restrict `v*` tags**

  Use `POST /repos/happitec-inc/FederatedActivityPublisher/rulesets` with:
  - `target: "tag"`, `enforcement: "active"`;
  - `conditions.ref_name.include: ["refs/tags/v*"]`;
  - rules `creation`, `update` (with `update_allows_fetch_and_merge: false`) and `deletion`;
  - `bypass_actors` as decided in Q9.

  Field names are from GitHub docs, "REST API endpoints for rules".

  Negative control: a collaborator outside the bypass list pushes tag `v0.0.0-ruleset-check`. Expected: rejected. A bypass actor deletes it if it was created.

- [ ] **Step 4: Run `oidc-roles.yml` from `main`**

  Expected: `bootstrap assume: ok` and `role stack: ok`, and the step summary lists five role names. On `failed`, a maintainer reads the stack events in the console. Do not widen anything from the log; stop and decide.

- [ ] **Step 5: Positive-path trust check from `main`**

  Run `oidc-trust-check.yml` from `main`. At this point the function roles do not yet carry the boundary.

  Expected:
  - the assume, scope, boundary-create and distribution checks pass;
  - the inventory shows every function role name beginning `activity-app-stage-` (U2);
  - the managed policy ARNs are exactly `arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole` and `.../AWSLambdaSQSQueueExecutionRole` (U3);
  - the roles have no boundary yet.

  If the role prefix or the managed policies differ, revise Appendix A and repeat Steps 4–5.

- [ ] **Step 6: Negative control for the environment rules**

  Dispatch `oidc-trust-check.yml` on a throwaway branch `oidc-negative-control`. Expected:
  - the four environment-bound jobs are refused by the deployment branch rules before any step runs;
  - `no-environment` fails at its integration-stage-read assume, because the subject is `ref:refs/heads/oidc-negative-control`.

  A green run means the rules or the trust did not take effect: stop. Delete the branch afterwards.

### Task 3: Put the boundary on the function roles (current credentials)

**Files:**
- Modify: `activity-app/functions/template.yaml`, `Globals.Function` (lines 75–107)

**Interfaces:**
- Consumes: the managed policies `activity-app-<stage>-function-boundary` (Task 2 Step 4).

- [ ] **Step 1: Add the boundary**

  Under `Globals.Function`, add:

  ```yaml
  PermissionsBoundary: !Sub arn:aws:iam::${AWS::AccountId}:policy/activity-app-${Stage}-function-boundary
  ```

- [ ] **Step 2: Open the PR; after merge, observe `deploy-stage`**

  The run is on the static keys, because no workflow has switched yet. Expected:
  - green, including the integration tests, which exercise the SSM, KMS, DynamoDB and S3 paths under the boundary;
  - a rerun of the trust check's inventory shows every stage function role with `PermissionsBoundaryArn` ending `activity-app-stage-function-boundary`.

  Watch the stage functions' error counts in the Lambda console for one hour after the deploy. Expected: no new `AccessDenied` (U11).

- [ ] **Step 3: Prod**

  The boundary reaches prod with the next release, still on the static keys. Task 8 requires that release first.

- [ ] **Step 4: Commit**

  ```bash
  git add activity-app/functions/template.yaml
  git commit -m "infra: permissions boundary on function roles"
  ```

### Task 4: Artifact prefixes, forced uploads, action pins and the distribution guard (current credentials)

**Files:**
- Modify: `.github/workflows/deploy-stage.yml`: `sam package` (316–322), `sam deploy` (324–344), the action references at 137, 156, 198, 290, 302, 310 and 423, and a new step after "Print stack outputs" (361–367).
- Modify: `.github/workflows/deploy-prod.yml`: `sam package` and `sam deploy` (90–116), the action references at 64, 76 and 84, and a new step after "Print stack outputs" (133–139).

- [ ] **Step 1: Prefixes and forced uploads**

  - `sam package` gains `--s3-prefix activity-app-stage` (or `activity-app-prod`) and `--force-upload`.
  - `sam deploy` gains `--force-upload`.

  `--force-upload` overrides objects that already exist under the same key, so `sam package` never reuses an artifact that another writer to the shared bucket placed.

- [ ] **Step 2: Pin actions by SHA in the jobs that will hold `id-token: write`**

  - `aws-actions/configure-aws-credentials@v6` becomes `@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6`.
  - `happitec-inc/public-actions/swift-build-cache-restore@main` and `/swift-build-cache-save@main` become the `main` SHA read with `gh api repos/happitec-inc/public-actions/commits/main --jq .sha` on the day of the change, recorded in the PR body.
  - `actions/*` stay on their major tags.

- [ ] **Step 3: Distribution guard**

  Add a step named "Check ACTIVITY_DISTRIBUTION_ID". It reads the `CloudFrontDistributionId` output of `activity-app-<stage>`.
  - If `vars.ACTIVITY_DISTRIBUTION_ID_<STAGE>` is empty, it prints a notice with the ID to set.
  - Otherwise it fails if the two differ.

- [ ] **Step 4: Open the PR; after merge, observe `deploy-stage`; prod follows on the next release**

  Expected: green. The package step uploads every artifact under `activity-app-stage/`, and every function's code location changes. The guard passes.

  Once stage and then prod have one deploy on the prefix, each stack's current template references only prefixed keys. That is what makes the prefix-scoped `s3:GetObject` safe for rollback.

- [ ] **Step 5: Commit**

  ```bash
  git add .github/workflows/deploy-stage.yml .github/workflows/deploy-prod.yml
  git commit -m "ci: per-stage artifact prefix, forced uploads, pinned actions"
  ```

### Task 5: Full trust check

- [ ] **Step 1: Run `oidc-trust-check.yml` from `main`**

  Expected: green. The inventory shows the stage boundary on every stage function role.

  The `stage` job's boundary checks are the negative control for the IAM conditions:
  - creating a role without the stage boundary is denied;
  - creating one with the prod boundary is denied;
  - removing a boundary is denied;
  - creating a role outside the prefix is denied.

### Task 6: `run-integration-tests.yml` on the integration role

**Files:**
- Modify: `.github/workflows/run-integration-tests.yml:18-37`

- [ ] **Step 1: Bind the job and switch the role**

  - The job gains `environment: integration`. Workflow-level `id-token: write` is already at lines 14–16.
  - Lines 32–37 become the pinned `configure-aws-credentials` with `role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/FederatedActivityPublisher-github-actions-integration-read` and the existing `aws-region`.
  - Add a "Show assumed role" step: `aws sts get-caller-identity --query Arn --output text`.

  Check: `grep -n "AWS_ACCESS_KEY_ID\|AWS_SECRET_ACCESS_KEY" .github/workflows/run-integration-tests.yml` prints nothing.

- [ ] **Step 2: Open the PR; after merge, dispatch from `main` with `stage`, then `prod`**

  Expected:
  - both runs are green;
  - "Show assumed role" names `...-integration-read`;
  - the prod run reads the client token (U5).

- [ ] **Step 3: Negative control**

  Dispatch with `stage` from a non-`main` branch. Expected: the environment's branch rule refuses the job (Q3).

- [ ] **Step 4: Commit**

  ```bash
  git add .github/workflows/run-integration-tests.yml
  git commit -m "ci: integration tests assume an OIDC role"
  ```

### Task 7: `deploy-stage.yml` on the stage roles

**Files:**
- Modify: `.github/workflows/deploy-stage.yml`, in jobs `fast-deploy`, `build` and `integration-tests`

**Precondition:** Task 3 is deployed to stage (Task 5 inventory), and Task 4 is deployed to stage.

- [ ] **Step 1: Job permissions**

  Give `fast-deploy`, `build` and `integration-tests` each `permissions: {contents: read, actions: read, id-token: write}`. The workflow-level block (10–12) stays as it is for `detect`.

- [ ] **Step 2: Roles**

  - `fast-deploy` and `build`: `role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/FederatedActivityPublisher-github-actions-deploy-stage`.
  - `integration-tests`: `...-integration-stage-read`.
  - Add a "Show assumed role" step after each.

  Check: grep for the two static secret names in the file prints nothing.

- [ ] **Step 3: Open the PR; after merge, observe the push run**

  The merge changes `.github/`, so `detect` takes the full path. Expected:
  - `build` and `integration-tests` green;
  - "Show assumed role" names `...-deploy-stage` and `...-integration-stage-read`;
  - the distribution guard passes.

  Check the fast path on the next merge that touches only `Sources/`. Expected: `fast-deploy` green, naming the stage role.

- [ ] **Step 4: Negative control**

  It was measured in Task 5: the stage role is refused outside the `stage` environment and cannot read prod. For this run, the evidence is the empty grep plus the role that "Show assumed role" names. Static keys would show an IAM user ARN instead of `assumed-role/...`.

- [ ] **Step 5: Commit**

  ```bash
  git add .github/workflows/deploy-stage.yml
  git commit -m "ci: deploy stage with an OIDC role"
  ```

### Task 8: `deploy-prod.yml`, `environment.yml` and `bootstrap.yml`

**Files:**
- Modify: `.github/workflows/deploy-prod.yml:9-10` and `:83-88`
- Modify: `.github/workflows/environment.yml:4-5`, `:19-20` and `:28-33`
- Modify: `.github/workflows/bootstrap.yml:3-4`, `:22-23` and `:31-36`

**Precondition:** a release containing Tasks 3 and 4 has deployed to prod. Check: the Task 5 inventory, rerun with the `production` job extended to list prod function role boundaries, shows the prod boundary.

- [ ] **Step 1: `deploy-prod.yml`**

  Workflow `permissions: {contents: read, id-token: write}`. The credentials step uses `...-deploy-prod`, followed by "Show assumed role".

- [ ] **Step 2: `environment.yml` and `bootstrap.yml`**

  - Workflow `permissions: {contents: read, id-token: write}`.
  - Job gains `environment: infrastructure`.
  - Credentials step uses `...-infra`, followed by "Show assumed role".
  - The configure action is pinned as in Task 4.

  `bootstrap.yml` also gains, before "SAM build", a step named "Refuse a domain change on an existing stack". It reads the `DomainName` parameter of `activity-bootstrap` with `describe-stacks` and fails if the stack exists and the value differs from `inputs.domain-name`. Without that guard, a changed domain would try to replace the retained hosted zone and certificate. The infra role has no create permission for them, so that deploy would fail midway.

- [ ] **Step 3: Check**

  `grep -rn "AWS_ACCESS_KEY_ID\|AWS_SECRET_ACCESS_KEY" .github/` prints nothing.

- [ ] **Step 4: Open the PR; after merge, validate with explicit go per run**

  1. `environment.yml` with `stage`, then with `prod`. Expected: green, with "No changes to deploy", naming `...-infra`.
  2. The next published `v*` release runs `deploy-prod`. Expected: green, naming `...-deploy-prod`, with the distribution guard passing.

  Release timing is not part of this plan.

- [ ] **Step 5: Commit**

  ```bash
  git add .github/workflows/deploy-prod.yml .github/workflows/environment.yml .github/workflows/bootstrap.yml
  git commit -m "ci: prod and infrastructure stacks use OIDC roles"
  ```

### Task 9: Docs, including the self-hosted path

**Files:**
- Modify: `README.md:146-153`
- Modify: `Sources/ActivityPubCore/Documentation.docc/DeployYourOwn.md:5-30`
- Modify: `Sources/ActivityPubCore/Documentation.docc/BuildingAndDeploying.md:25-27`, `:54-56`, `:94-96`, `:113-115` and `:154`
- Modify: `Sources/ActivityPubCore/Documentation.docc/AWSPermissions.md`

- [ ] **Step 1: `README.md`**

  The "Required GitHub Secrets" table drops the two key rows. It adds:
  - `AWS_ACCOUNT_ID`;
  - `OIDC_BOOTSTRAP_ROLE_ARN`, in the `oidc-bootstrap` environment, used only by `oidc-roles.yml`.

  The variables table notes that `ACTIVITY_DISTRIBUTION_ID_STAGE` and `_PROD` also scope the deploy roles. Add a short "Environments" table listing the five environments and their branch rules.

- [ ] **Step 2: `DeployYourOwn.md`**

  Replace Step 2 (lines 20–29) with an OIDC setup that works without any role of this project's org:
  1. In the AWS account, create the GitHub OIDC identity provider, `token.actions.githubusercontent.com` with audience `sts.amazonaws.com`.
  2. With administrator credentials of your own, deploy once from your machine or the CloudFormation console:
     - `activity-bootstrap`;
     - `activity-environment-stage` and `activity-environment-prod`;
     - `activity-oidc/template.yaml`, with `GitHubOrg`, `GitHubRepo`, `GitHubOrgId` and `GitHubRepoId` set to your fork's values.

     Give the exact `sam deploy` commands the workflows use. Retained data stores are created once this way; the CI roles never create them.
  3. Add the secret `AWS_ACCOUNT_ID` and the five environments with their branch rules. Optionally, set `OIDC_BOOTSTRAP_ROLE_ARN` to a role you control so that later role-stack updates run through `oidc-roles.yml`.
  4. Leave `ACTIVITY_DISTRIBUTION_ID_*` empty for the first app deploy. With them empty, the deploy roles may create the distribution.
  5. After that deploy, set them from the guard's notice and redeploy the role stack to narrow the grant.

  Lines 7 and 29 change to say the roles are least-privilege by construction and that no long-lived key is stored in GitHub.

- [ ] **Step 3: `BuildingAndDeploying.md`**

  - Each "Required secrets" block names the role the workflow assumes, its environment, and `AWS_ACCOUNT_ID`.
  - Line 154 notes that the prod token read requires the `integration` environment.
  - Add a section on `oidc-roles.yml` and `oidc-trust-check.yml`.

- [ ] **Step 4: `AWSPermissions.md`**

  Add a "CI roles" section that points to `activity-oidc/template.yaml` as the authoritative list and explains the function-role boundary. The existing per-service lists remain the guide for an administrator's one-time deploy.

- [ ] **Step 5: Open the PR**

  Expected: CI green, including the DocC build where `ENABLE_DOCC_DEPLOY` is set.

- [ ] **Step 6: Commit**

  ```bash
  git add README.md Sources/ActivityPubCore/Documentation.docc/DeployYourOwn.md Sources/ActivityPubCore/Documentation.docc/BuildingAndDeploying.md Sources/ActivityPubCore/Documentation.docc/AWSPermissions.md
  git commit -m "docs: OIDC deployment setup"
  ```

### Task 10: Delete the static secrets (explicit approval required)

- [ ] **Step 1: Preconditions**

  All of the following must hold:
  - `grep -rn "AWS_ACCESS_KEY_ID\|AWS_SECRET_ACCESS_KEY" .github/` on `main` prints nothing;
  - the docs from Task 9 are merged;
  - there is a green OIDC run of each of these:
    - `run-integration-tests` (stage and prod);
    - `deploy-stage` (full path and fast path);
    - `deploy-prod` (release);
    - `environment.yml` (stage and prod);
  - `bootstrap.yml` has a green OIDC run, or is accepted without one (Q4).

- [ ] **Step 2: Delete the secrets**

  ```bash
  gh secret delete AWS_ACCESS_KEY_ID --repo happitec-inc/FederatedActivityPublisher
  gh secret delete AWS_SECRET_ACCESS_KEY --repo happitec-inc/FederatedActivityPublisher
  ```

  Check: `gh secret list` shows neither.

- [ ] **Step 3: Positive control after deletion**

  The next `deploy-stage` push run is green. A `run-integration-tests` dispatch with `stage` is green.

**Not in this plan:** the access key the deleted secrets held. Rotating or deactivating it is an IAM write and a separate decision (Q7).

---

## Open questions

- **Q1: Locus.** Options (a), (b) and (c) are compared in D1. Recommendation: (c). (b) is the fallback if the bootstrap path cannot create the stack.
- **Q2: Five roles.** Could the two integration roles be folded into one? That would let every push-triggered test job read the prod client token. Recommendation: keep five.
- **Q3: Integration tests from branches.** `run-integration-tests.yml` was last dispatched from a non-`main` branch on 2026-06-16. The `integration` environment's `main` rule ends that. Recommendation: keep `main` only.
- **Q4: `bootstrap.yml`.** Run a no-op dispatch before Task 10, which needs the existing `domain-name` and `dns-mode` values, or accept it untested until it is next needed?
- **Q5: Function-role trust.** A deploy role can still create a stage function role with an arbitrary trust policy (D5). Is the boundary cap sufficient, or should function roles move to a dedicated `RolePath`, a supported `Globals.Function` property, behind an explicit allow-list of trust shapes in review?
- **Q6: `oidc-trust-check.yml` after cutover.** Keep it as a regression check for template changes, or delete it after Task 10? Recommendation: keep.
- **Q7: The access key behind the deleted secrets.** Rotate, deactivate or leave it? This is a separate IAM-write decision.
- **Q8: Role names.** Are the five suffixed names acceptable under the per-repo pattern?
- **Q9: `v*` tag ruleset bypass list.** Who may create, move and delete release tags? Recommendation: the repository admin role only.
- **Q10: Required reviewers.** Add required reviewers to `production`, `infrastructure` and `oidc-bootstrap`? Recommendation: yes for `oidc-bootstrap` and `infrastructure`; for `production`, it is a release-flow decision.
- **Q11: Split build and deploy jobs.** Splitting would mean the jobs that hold `id-token: write` run no build steps at all; artifacts would pass between jobs. With SHA pins and a container that receives no token variables, the remaining exposure is first-party and GitHub-owned actions. Recommendation: not now.

## Unverified premises, and what measures each

| # | Premise | Measured by |
|---|---|---|
| U1 | This repository presents the previous subject form, based on its creation date. Both forms are trusted. | Task 2 Step 5 |
| U2 | SAM-generated function role names begin `activity-app-<stage>-`. | Task 2 Step 5 inventory |
| U3 | SAM attaches exactly `AWSLambdaBasicExecutionRole` and `AWSLambdaSQSQueueExecutionRole`. | Task 2 Step 5 inventory |
| U4 | `route53:ChangeResourceRecordSetsNormalizedRecordNames` compares against the lowercase name with no trailing dot. | The first record change. It fails closed on stage first. |
| U5 | The integration role's `kms:Decrypt` with `kms:ViaService` suffices for `--with-decryption` on the prod token. | Task 6 Step 2 |
| U6 | The SAM managed bucket's encryption needs no KMS permission for `PutObject`. | Task 7 Step 3 |
| U7 | The CloudFormation handlers call nothing outside Appendix A for these templates. | Each validation run; for CloudFront, the first CDN change |
| U8 | Each action in Appendix A supports the resource ARN it is granted on. The catalog confirms that names exist, not resource types. | `AccessDenied` in a validation run names the action and ARN |
| U9 | `configure-aws-credentials` uses OIDC when given only `role-to-assume`. | Every "Show assumed role" step |
| U10 | `--force-upload` with `--s3-prefix` re-uploads every artifact on each package. | Task 4 Step 4 log |
| U11 | The boundary, including `kms:Decrypt` conditioned on `kms:ViaService`, keeps every function working. | Task 3 Step 2: integration tests and one hour of Lambda error counts |
| U12 | CloudFormation needs no `lambda:TagResource` on event source mappings when the template sets no tags. | Task 7 Step 3, where the mapping is updated with the code location |

---

## Appendix A: Policies

Placeholders:

- `<S>` is `stage` or `prod`, and `<A>` is `${AWS::AccountId}`. Regional ARNs use `${AWS::Region}`.
- `<Zone>` and `<Domain>` are the imports of `${BootstrapStackName}-HostedZoneId` and `-DomainName`.
- `<DistId>` is `StageDistributionId` or `ProdDistributionId`.
- `<B>` is `arn:aws:iam::<A>:policy/activity-app-<S>-function-boundary`.
- `<Fn>` is `arn:aws:lambda:<region>:<A>:function:activity-app-*-<S>`.

### A.1 Deploy roles (`...-deploy-stage`, `...-deploy-prod`)

| Sid | Effect | Actions | Resource | Condition |
|---|---|---|---|---|
| `Stacks` | Allow | `cloudformation:` `CreateChangeSet`, `DescribeChangeSet`, `ExecuteChangeSet`, `DeleteChangeSet`, `ListChangeSets`, `DescribeStacks`, `DescribeStackEvents`, `DescribeStackResource`, `ListStackResources`, `GetTemplate`, `GetTemplateSummary`, `CreateStack`, `UpdateStack`, `DeleteStack`, `SetStackPolicy`, `GetStackPolicy`, `UpdateTerminationProtection` | `stack/activity-app-<S>/*`, `stack/activity-app-<S>-*/*` | |
| `EnvironmentOutputs` | Allow | `cloudformation:DescribeStacks` | `stack/activity-environment-<S>/*` | |
| `SamTransform` | Allow | `cloudformation:CreateChangeSet` | `arn:aws:cloudformation:<region>:aws:transform/Serverless-2016-10-31` | |
| `SamManagedStack` | Allow | `cloudformation:DescribeStacks` | `stack/aws-sam-cli-managed-default/*` | |
| `SamArtifactsBucket` | Allow | `s3:ListBucket`, `s3:GetBucketLocation` | `arn:aws:s3:::aws-sam-cli-managed-default-samclisourcebucket-*` | |
| `SamArtifactsObjects` | Allow | `s3:PutObject`, `s3:GetObject`, `s3:GetObjectVersion` | `arn:aws:s3:::aws-sam-cli-managed-default-samclisourcebucket-*/activity-app-<S>/*` | |
| `LambdaFunctions` | Allow | `lambda:` `CreateFunction`, `DeleteFunction`, `GetFunction`, `UpdateFunctionCode`, `UpdateFunctionConfiguration`, `PublishVersion`, `PutFunctionConcurrency`, `DeleteFunctionConcurrency`, `GetFunctionCodeSigningConfig`, `GetFunctionRecursionConfig`, `PutFunctionRecursionConfig`, `GetFunctionScalingConfig`, `PutFunctionScalingConfig`, `GetRuntimeManagementConfig`, `PutRuntimeManagementConfig`, `AddPermission`, `RemovePermission`, `GetPolicy`, `TagResource`, `UntagResource`, `ListTags` | `<Fn>` | |
| `ManageEventSourceMappings` | Allow | `lambda:CreateEventSourceMapping`, `lambda:UpdateEventSourceMapping`, `lambda:DeleteEventSourceMapping` | `*` | `ArnLike` `lambda:FunctionArn`: `<Fn>` |
| `ReadEventSourceMappings` | Allow | `lambda:GetEventSourceMapping`, `lambda:ListEventSourceMappings` | `*` | |
| `FunctionRolesBounded` | Allow | `iam:CreateRole`, `iam:PutRolePolicy`, `iam:DeleteRolePolicy`, `iam:PutRolePermissionsBoundary` | `arn:aws:iam::<A>:role/activity-app-<S>-*` | `StringEquals` `iam:PermissionsBoundary`: `<B>` |
| `FunctionRoleManagedPolicies` | Allow | `iam:AttachRolePolicy`, `iam:DetachRolePolicy` | `arn:aws:iam::<A>:role/activity-app-<S>-*` | `StringEquals` `iam:PermissionsBoundary`: `<B>` and `ArnEquals` `iam:PolicyARN`: `arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole`, `arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole` |
| `FunctionRolesOther` | Allow | `iam:` `GetRole`, `GetRolePolicy`, `ListRolePolicies`, `ListAttachedRolePolicies`, `DeleteRole`, `UpdateRole`, `UpdateRoleDescription`, `TagRole`, `UntagRole`, `ListRoleTags` | `arn:aws:iam::<A>:role/activity-app-<S>-*` | |
| `NoBoundaryRemoval` | Deny | `iam:DeleteRolePermissionsBoundary` | `*` | |
| `PassFunctionRoles` | Allow | `iam:PassRole` | `arn:aws:iam::<A>:role/activity-app-<S>-*` | `StringEquals` `iam:PassedToService`: `lambda.amazonaws.com` |
| `ApiGateway` | Allow | `apigateway:` `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `UpdateRestApiPolicy` | `arn:aws:apigateway:<region>::/restapis`, `.../restapis/*`, `.../tags/*` | |
| `CloudFrontDistribution` | Allow | `cloudfront:` `GetDistribution`, `GetDistributionConfig`, `UpdateDistribution`, `UpdateDistributionWithStagingConfig`, `TagResource`, `UntagResource`, `ListTagsForResource`, plus `CreateDistribution` only when `<DistId>` is empty | `arn:aws:cloudfront::<A>:distribution/<DistId>`, or `distribution/*` when `<DistId>` is empty (`Fn::If` on `Has<S>Distribution`) | |
| `CloudFrontPolicies` | Allow | `cloudfront:` `Create`, `Get`, `Update` and `Delete` of each of `CachePolicy`, `OriginRequestPolicy` and `OriginAccessControl`: 12 actions | `arn:aws:cloudfront::<A>:cache-policy/*`, `...:origin-request-policy/*`, `...:origin-access-control/*` | |
| `CloudFrontFunction` | Allow | `cloudfront:` `CreateFunction`, `DescribeFunction`, `GetFunction`, `PublishFunction`, `UpdateFunction`, `DeleteFunction`, `TagResource`, `UntagResource`, `ListTagsForResource` | `arn:aws:cloudfront::<A>:function/activity-profile-rewrite-<S>` | |
| `DnsRecord` | Allow | `route53:ChangeResourceRecordSets` | `arn:aws:route53:::hostedzone/<Zone>` | `ForAllValues:StringEquals` `route53:ChangeResourceRecordSetsNormalizedRecordNames`: stage `stage.<Domain>`, prod `<Domain>` |
| `DnsRead` | Allow | `route53:GetHostedZone`, `route53:ListResourceRecordSets` | `arn:aws:route53:::hostedzone/<Zone>` | |
| `DnsLookups` | Allow | `route53:GetChange`, `route53:ListHostedZones` | `*` | |
| `MediaBucketPolicy` | Allow | `s3:GetBucketPolicy`, `s3:PutBucketPolicy`, `s3:DeleteBucketPolicy`, `s3:ListBucket` | `arn:aws:s3:::activity-media-<S>` | |
| `FrontendAssets` | Allow | `s3:PutObject` | `arn:aws:s3:::activity-media-<S>/media/frontend/*` | |

### A.2 Infra role (`...-infra`)

| Sid | Actions | Resource |
|---|---|---|
| `Stacks` | `cloudformation:` `CreateChangeSet`, `DescribeChangeSet`, `ExecuteChangeSet`, `DeleteChangeSet`, `DescribeStacks`, `DescribeStackEvents`, `GetTemplate`, `GetTemplateSummary` | `stack/activity-environment-stage/*`, `stack/activity-environment-prod/*`, `stack/activity-bootstrap/*` |
| `SamTransform` | `cloudformation:CreateChangeSet` | `arn:aws:cloudformation:<region>:aws:transform/Serverless-2016-10-31` |
| `MediaBucketConfig` | `s3:` `CreateBucketMetadataTableConfiguration`, `DeleteBucketMetadataTableConfiguration`, `DeleteBucketWebsite`, `GetAccelerateConfiguration`, `GetAnalyticsConfiguration`, `GetBucketAbac`, `GetBucketCORS`, `GetBucketLogging`, `GetBucketMetadataTableConfiguration`, `GetBucketNotification`, `GetBucketObjectLockConfiguration`, `GetBucketOwnershipControls`, `GetBucketPublicAccessBlock`, `GetBucketTagging`, `GetBucketVersioning`, `GetBucketWebsite`, `GetEncryptionConfiguration`, `GetIntelligentTieringConfiguration`, `GetInventoryConfiguration`, `GetLifecycleConfiguration`, `GetMetricsConfiguration`, `GetReplicationConfiguration`, `ListBucket`, `ListTagsForResource`, `PutAccelerateConfiguration`, `PutAnalyticsConfiguration`, `PutBucketAbac`, `PutBucketAcl`, `PutBucketCORS`, `PutBucketLogging`, `PutBucketNotification`, `PutBucketObjectLockConfiguration`, `PutBucketOwnershipControls`, `PutBucketPublicAccessBlock`, `PutBucketTagging`, `PutBucketVersioning`, `PutBucketWebsite`, `PutEncryptionConfiguration`, `PutIntelligentTieringConfiguration`, `PutInventoryConfiguration`, `PutLifecycleConfiguration`, `PutMetricsConfiguration`, `PutReplicationConfiguration`, `TagResource`, `UntagResource`, `UpdateBucketMetadataAnnotationTableConfiguration`, `UpdateBucketMetadataInventoryTableConfiguration`, `UpdateBucketMetadataJournalTableConfiguration` | `arn:aws:s3:::activity-media-stage`, `arn:aws:s3:::activity-media-prod` |
| `Table` | `dynamodb:` `DescribeTable`, `UpdateTable`, `DescribeTimeToLive`, `UpdateTimeToLive`, `DescribeContinuousBackups`, `UpdateContinuousBackups`, `DescribeContributorInsights`, `UpdateContributorInsights`, `DescribeKinesisStreamingDestination`, `EnableKinesisStreamingDestination`, `DisableKinesisStreamingDestination`, `UpdateKinesisStreamingDestination`, `GetResourcePolicy`, `PutResourcePolicy`, `DeleteResourcePolicy`, `TagResource`, `UntagResource`, `ListTagsOfResource` | `table/activity-stage`, `table/activity-stage/index/*`, `table/activity-prod`, `table/activity-prod/index/*` |
| `Queues` | `sqs:` `GetQueueAttributes`, `SetQueueAttributes`, `ListQueueTags`, `TagQueue`, `UntagQueue` | `activity-delivery-stage`, `activity-delivery-prod`, `activity-delivery-dlq-stage`, `activity-delivery-dlq-prod` |
| `AlarmTopic` | `sns:` `CreateTopic`, `DeleteTopic`, `GetTopicAttributes`, `SetTopicAttributes`, `Subscribe`, `Unsubscribe`, `ListSubscriptionsByTopic`, `GetDataProtectionPolicy`, `PutDataProtectionPolicy`, `TagResource`, `UntagResource`, `ListTagsForResource` | `activity-dlq-alarm-stage`, `activity-dlq-alarm-prod` |
| `Alarm` | `cloudwatch:` `PutMetricAlarm`, `DeleteAlarms`, `TagResource`, `UntagResource`, `ListTagsForResource` | `alarm:activity-dlq-depth-stage`, `alarm:activity-dlq-depth-prod` |
| `AlarmRead` | `cloudwatch:DescribeAlarms` | `*` |
| `BootstrapZone` | `route53:` `GetHostedZone`, `GetChange`, `ListTagsForResource`, `ChangeTagsForResource`, `UpdateHostedZoneComment`, `UpdateHostedZoneFeatures`, `CreateQueryLoggingConfig`, `DeleteQueryLoggingConfig`, `ListQueryLoggingConfigs` | `arn:aws:route53:::hostedzone/<Zone>`, and `change/*` for `GetChange` |
| `BootstrapCertificate` | `acm:` `DescribeCertificate`, `ListTagsForCertificate`, `AddTagsToCertificate`, `RemoveTagsFromCertificate`, `UpdateCertificateOptions` | the import of `${BootstrapStackName}-CertificateArn` |

The SNS topic and alarm are not retained, so they keep create and delete. The table, bucket and queues get neither.

### A.3 Integration roles

| Role | Sid | Actions | Resource | Condition |
|---|---|---|---|---|
| `...-integration-stage-read` | `StageOutputs` | `cloudformation:DescribeStacks` | `stack/activity-app-stage/*` | |
| `...-integration-read` | `AppOutputs` | `cloudformation:DescribeStacks` | `stack/activity-app-stage/*`, `stack/activity-app-prod/*` | |
| `...-integration-read` | `ProdClientToken` | `ssm:GetParameter` | `arn:aws:ssm:<region>:<A>:parameter/activity/prod/keys/client-token` | |
| `...-integration-read` | `DecryptViaSsm` | `kms:Decrypt` | `arn:aws:kms:<region>:<A>:key/*` | `StringEquals` `kms:ViaService`: `ssm.<region>.amazonaws.com` |

### A.4 Function boundaries (`activity-app-<S>-function-boundary`)

| Sid | Actions | Resource | Condition |
|---|---|---|---|
| `Logs` | `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` | `arn:aws:logs:<region>:<A>:log-group:/aws/lambda/activity-app-*-<S>`, `...:log-group:/aws/lambda/activity-app-*-<S>:*` | |
| `Table` | `dynamodb:` `GetItem`, `DeleteItem`, `PutItem`, `Scan`, `Query`, `UpdateItem`, `BatchWriteItem`, `BatchGetItem`, `DescribeTable`, `ConditionCheckItem` | `table/activity-<S>`, `table/activity-<S>/index/*` | |
| `Queue` | `sqs:SendMessage`, `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` | `arn:aws:sqs:<region>:<A>:activity-delivery-<S>` | |
| `Parameters` | `ssm:GetParameter`, `ssm:GetParameters`, `ssm:GetParametersByPath` | `arn:aws:ssm:<region>:<A>:parameter/activity/<S>/*` | |
| `ParameterList` | `ssm:DescribeParameters` | `*` | |
| `DecryptViaSsm` | `kms:Decrypt` | `arn:aws:kms:<region>:<A>:key/*`, `arn:aws:kms:<region>:<A>:alias/aws/ssm` | `StringEquals` `kms:ViaService`: `ssm.<region>.amazonaws.com` |
| `Media` | `s3:PutObject` | `arn:aws:s3:::activity-media-<S>/*` | |

The boundary grants nothing on its own. A function's effective permissions are the intersection of its role's policies and this boundary. The explicit `Deny` statements in `InboxFunction`'s policy keep applying.
