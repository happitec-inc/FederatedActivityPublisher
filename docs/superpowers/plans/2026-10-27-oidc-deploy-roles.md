# OIDC Deploy Roles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every GitHub Actions job here that talks to AWS assumes a repo-scoped IAM role through GitHub OIDC. After that, the static key secrets `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are deleted.

**Architecture:** One plain CloudFormation template, `activity-oidc/template.yaml`, defines everything in this repo's role stack:

- **Five IAM roles**, each trusting exactly one OIDC subject of this repository: stage deploy, prod deploy, infrastructure, integration read, and a read-only trust-check role.
- **Two permissions-boundary managed policies**, one per stage. Every Lambda execution role the deploy roles create or change must carry its stage's boundary.

A PR check keeps the functions template inside both boundaries. A manually dispatched workflow, bound to its own environment, deploys the role stack. It authenticates through an existing org-level bootstrap role that can create this repo's role stack; self-hosters use credentials of their own.

These changes land first, on the current credentials:

- the function-role boundary;
- per-stage SAM artifact prefixes with forced uploads;
- SHA-pinned third-party actions;
- a distribution-ID guard.

Then the workflows move to `role-to-assume` in this order: integration tests, stage, prod and infrastructure. The push-triggered stage test job stops holding AWS credentials altogether. Docs follow, and the static secrets are deleted last.

**Tech Stack:** GitHub Actions, `aws-actions/configure-aws-credentials` (pinned by SHA), AWS SAM CLI through `./.github/actions/setup-sam-portable`, CloudFormation, IAM, and Python 3 with the distro `python3-yaml` package for the offline boundary check.

**Spec:** None separate. Moving to OIDC was settled 2026-10-27. The requirements are restated under Global Constraints, and "Decisions" argues each choice.

## Global Constraints

- **Trust.** Each role trusts the account's GitHub OIDC provider (`token.actions.githubusercontent.com`) with `StringEquals` on two claims:
  - `aud` = `sts.amazonaws.com`;
  - `sub` = this repository's subject for that role, in both the previous form `repo:<org>/<repo>:<suffix>` and the immutable form `repo:<org>@<org-id>/<repo>@<repo-id>:<suffix>`.

  No wildcards. The org, repo and IDs are template parameters. Their defaults are this repository's values: `happitec-inc`, `FederatedActivityPublisher`, owner ID `174214171` and repo ID `1193951865`, read from `GET /repos/happitec-inc/FederatedActivityPublisher` on 2026-10-27.
- **No AWS managed policy** is attached to any of the five roles, and no role is shared with another project.
- **Every IAM role-write action of the deploy roles is conditioned on `iam:PermissionsBoundary`** equal to that stage's boundary policy. `iam:UpdateAssumeRolePolicy` is not granted. `iam:DeleteRolePermissionsBoundary` is explicitly denied.
- **Names.**
  - Roles: `FederatedActivityPublisher-github-actions-deploy-stage`, `FederatedActivityPublisher-github-actions-deploy-prod`, `FederatedActivityPublisher-github-actions-infra`, `FederatedActivityPublisher-github-actions-integration-read` and `FederatedActivityPublisher-github-actions-trust-check`.
  - Boundaries: `activity-app-stage-function-boundary` and `activity-app-prod-function-boundary`.
  - Stack: `FederatedActivityPublisher-oidc`.
- **The template has no `Transform:`** and stays under 51,200 bytes, the CloudFormation limit for an inline template body. That way it can be deployed from the console, the CLI or the dispatch workflow without an artifact bucket.
- **Size limits.** Each role's inline policies total at most 10,240 characters, and each managed policy at most 6,144 characters, whitespace excluded. Both limits are from the IAM quotas page.
- **Identifiers stay out of the repository and out of public logs.**
  - The account ID is the repository secret `AWS_ACCOUNT_ID`.
  - The bootstrap role ARN is `OIDC_BOOTSTRAP_ROLE_ARN`, a secret of the `oidc-bootstrap` environment.
  - Both are secrets, not variables, because Actions logs print each step's resolved `with:` inputs: secrets as `***`, variables in clear text. In this repository's `deploy-prod` run 39721690715, the step header shows `aws-access-key-id: ***` and `aws-region: us-east-1`.
  - No job output carries a value derived from a secret. The runner drops such outputs.
- **AWS from a workstation.** Nothing in this plan runs `aws` or `sam` against the account from a maintainer workstation. All maintainer-side AWS changes are workflow runs. How the one-time role-stack credential is provided is decided outside this plan (Q12).
- **Validation.** Workflow changes are validated by PR CI and by real runs. Runner VMs are never used, cloned or entered by hand.
- **Explicit go required.** Each of these needs an explicit go from a maintainer, recorded on the PR or run that carries it:
  - creating a secret or environment;
  - changing environment or ruleset settings;
  - dispatching a workflow that mutates AWS;
  - deleting secrets.
- **Commits** are short and describe the change only.

## Review Focus

- **Jobs bound to an environment present `environment:<name>`, not `ref:`.** GitHub docs, "OpenID Connect reference": "The subject claim includes the environment name when the job references an environment." Task 5's trust check pins each role to its one subject.
- **Every function role carries the boundary before a deploy role first touches it.** The deploy roles can write to a role only if it already carries the right boundary. Tasks 7 and 8 check that it is in place first. If one of them runs too early, the deploy fails on the first role change. That failure is safe, but it is a failure.
- **A permission outside the boundary deploys green and fails at runtime.** `iam:PutRolePolicy` is conditioned on the boundary, not on what the policy says. The PR check from Task 1 Step 3 catches this in the template, once against each stage's boundary. The docs rule in Task 9 covers ordering: widen the boundary and redeploy the role stack before merging the function change.
- **Rollback must read the previous artifacts.** The deploy roles can read only `activity-app-<stage>/*` in the SAM bucket. Task 4 ships the prefix on the current credentials, so the template a failed OIDC deploy rolls back to already points at prefixed keys.
- **A job holding `id-token: write` can mint a token in any of its steps.**
  - The actions in those jobs are pinned to commit SHAs (Task 4).
  - The Swift build runs in a container that receives only `HOME` (`scripts/in-build-image.sh` passes `-e HOME=/tmp` and no other environment).
  - The stage integration-test job no longer holds `id-token: write` at all (Task 7).

---

## Current state (read on `origin/main` at `6386a77`, 2026-10-27)

Seven steps authenticate with the static secrets, through `aws-actions/configure-aws-credentials@v6` with `aws-access-key-id` and `aws-secret-access-key`:

| Workflow | Job | Lines | Trigger | `environment:` | AWS calls after the step |
|---|---|---|---|---|---|
| `bootstrap.yml` | `deploy` | 31–36 | `workflow_dispatch` | none | `sam deploy` stack `activity-bootstrap`; `describe-stacks` |
| `environment.yml` | `deploy` | 28–33 | `workflow_dispatch` | none | `sam deploy` stack `activity-environment-<stage>`; `describe-stacks` |
| `deploy-stage.yml` | `fast-deploy` | 197–202 | push to `main` | `stage` | `describe-stack-resource`, `list-stack-resources`, `lambda update-function-code` |
| `deploy-stage.yml` | `build` | 309–314 | push to `main`, dispatch | `stage` | `sam package --resolve-s3`, `sam deploy` stack `activity-app-stage`, `describe-stacks`, `s3 sync` |
| `deploy-stage.yml` | `integration-tests` | 422–427 | after the above | none | `describe-stacks activity-app-stage` (lines 429–441) for `ApiEndpoint` and `ClientApiUrl` only |
| `deploy-prod.yml` | `build-and-deploy` | 83–88 | release published, dispatch | `production` | same as `build`, for `prod` |
| `run-integration-tests.yml` | `test` | 32–37 | `workflow_dispatch` | none | `describe-stacks activity-app-<env>`; prod only: `ssm get-parameter /activity/prod/keys/client-token --with-decryption` |

No other workflow references an AWS secret: a grep of `.github/` for `secrets.AWS` and `aws ` matched only these five files.

Docs that name the static secrets:

- `README.md:151–152`;
- `Sources/ActivityPubCore/Documentation.docc/DeployYourOwn.md:20–29`;
- `Sources/ActivityPubCore/Documentation.docc/BuildingAndDeploying.md:25–27`, `:54–56`, `:94–96` and `:113–115`.

`AGENTS.md:48` shows static keys for the local `ActivityProvisioner` CLI. That runs on an operator's machine, not in CI, and is not in scope.

Other measured facts:

- **Environments.** `stage` and `production` exist with no protection rules and `deployment_branch_policy: null` (`GET /repos/{owner}/{repo}/environments`).
- **Subject form.** The repository was created 2026-03-27. GitHub docs, "OpenID Connect reference": repositories created after July 15, 2026 use the immutable subject; older ones "keep the previous format unless they opt in."
- **Run 39721690715** (this repository's `deploy-prod`):
  - The SAM managed artifact bucket's name starts with `aws-sam-cli-managed-default-samclisourcebucket-`, from its `Managed S3 bucket:` line.
  - Actions resolved to these SHAs: `aws-actions/configure-aws-credentials@v6` to `e1253824e5c10ff9df46874f81ed3ec929e19cfd`, and `aws-actions/setup-sam@v3` to `341eee193f458fa5aae5d52c94b0c5cf3a1c5a52`. The latter is the fallback inside `./.github/actions/setup-sam-portable/action.yml:59`.
  - The runner already had SAM CLI 1.166.2 installed.
- **SAM CLI 1.166.2** (`--help`):
  - `sam package` has `--s3-prefix` and `--force-upload` ("override existing files in the S3 bucket").
  - `sam deploy` has `--force-upload` with the same wording. It only matters when `sam deploy` uploads artifacts or a template.
  - This repository runs `sam deploy` on the already-packaged `packaged.yaml`, with no `--s3-bucket`, and those runs succeed. So `sam deploy` uploads nothing here [inferred from the successful runs], and `--force-upload` goes on `sam package` only.
- **SAM docs.**
  - `PermissionsBoundary` is a supported `Globals.Function` property ("Globals section").
  - On a function it "works only if the role is generated for you" and "is passed directly to the `PermissionsBoundary` property of an `AWS::IAM::Role`" (`AWS::Serverless::Function`).
  - Every function in `activity-app/functions/template.yaml` uses a generated role: `Policies:`, no `Role:`.
- **No service role.** `sam deploy` here runs without `--role-arn`, so CloudFormation acts with the caller's credentials for every resource, nested stacks included.

## Decisions

### D1: Where the roles are defined (Q1; recommendation c)

This repository is public. GitHub docs, "Managing GitHub Actions settings for a repository" → "Allowing access to components in a private repository", give both sharing options for a private repository's actions and reusable workflows the same rule: "Access is allowed only from private repositories." So any reusable workflow this repository calls must live in a public repository.

| Option | What changes | Smallest mechanism | Correct locus | Cost |
|---|---|---|---|---|
| (a) Add the roles to `activity-bootstrap` and deploy them with `bootstrap.yml` | One template gains roles | Reuses a stack and workflow | **No.** The DNS-and-certificate stack takes on a second job, CI identity. `bootstrap.yml`'s `domain-name` and `dns-mode` inputs put the hosted zone at risk on every role edit. The roles would need a broad credential to create them and could later rewrite their own policies. | A broad credential in CI once; a role that can change itself afterwards |
| (b) Publish a generic, opt-in reusable role workflow in `happitec-inc/public-actions`, keeping its existing defaults | A new shared component in another repository | Adds a component | Right for a tool many public repos share | A cross-repo change and review; still has to emit five roles and two boundaries |
| **(c) This repository owns `activity-oidc/template.yaml` and deploys it with `oidc-roles.yml`** | One template and one small workflow here | **Yes.** No new component elsewhere | **Yes.** The roles and boundaries live with their only consumer, and the template is plain CloudFormation that self-hosters can deploy with their own credentials | Hand-written IAM to review |

**Recommendation: (c).** `oidc-roles.yml` authenticates through an existing org-level bootstrap role that can create this repo's role stack, held in `OIDC_BOOTSTRAP_ROLE_ARN`. Task 2 Step 4 is its first run.

Options (a), (b) and (c) differ in where the roles are defined and which workflow deploys them. None of them changes what the deploying credential is allowed to do; that is Q12.

### D2: Five roles (Q2)

| Role | Trusted `sub` suffix | Used by |
|---|---|---|
| `...-deploy-stage` | `environment:stage` | `deploy-stage.yml` jobs `fast-deploy` and `build` |
| `...-deploy-prod` | `environment:production` | `deploy-prod.yml` job `build-and-deploy` |
| `...-infra` | `environment:infrastructure` | `environment.yml` and `bootstrap.yml` |
| `...-integration-read` | `environment:integration` | `run-integration-tests.yml` (stage and prod) |
| `...-trust-check` | `environment:trust-check` | `oidc-trust-check.yml` job `inventory` only |

- **Stage and prod are separated by environment**, which costs nothing: the deploy jobs are already environment-bound. Task 2 adds deployment branch rules so the environment boundary also restricts refs:
  - `stage`, `infrastructure`, `integration`, `trust-check` and `oidc-bootstrap`: `main` only;
  - `production`: `main` and tags `v*`.

  The tag rule limits which refs can deploy, not who can create them, so Task 2 also restricts creating `v*` tags with a ruleset (Q9).
- **`infra` is split from the deploy roles.** The data and DNS stacks change rarely and by hand. With their grants off the deploy roles, the roles used on every merge and release cannot reconfigure the table, bucket, queues, hosted zone or certificate. The split also keeps each deploy role's inline policy well under the size limit; Task 1 Step 2 measures all five roles and both boundaries from the committed template.
- **The push-triggered stage test job holds no AWS credential.** It used AWS only to read `ApiEndpoint` and `ClientApiUrl`. In Task 7, `build` and `fast-deploy`, which already hold the stage role, publish those two URLs as job outputs, and `integration-tests` reads them from `needs`. The URLs contain no secret-derived value, so the runner keeps the outputs.
- **The prod client token is readable only from jobs bound to the `integration` environment.** Today that means `run-integration-tests.yml` alone.
- **`trust-check` is a separate, read-only role.** It holds `iam:ListRoles`, so the inventory can scan every `activity-app-<S>-*` role in the account, not only the ones in the functions stack. Keeping it off the deploy roles means no merge-time role can enumerate the account's roles.

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
5. **Event source mappings.**
   - `lambda:CreateEventSourceMapping` is granted on `*` with `ArnLike` on `lambda:FunctionArn`, the form in Lambda docs, "Granting users access to an Event Function", statement `DevelopEventSourceMappings`.
   - `lambda:UpdateEventSourceMapping` and `lambda:DeleteEventSourceMapping` are granted on `*` with **no** condition. CloudFormation's delete and rollback paths can call them for a mapping identified only by UUID. Such a call carries no function ARN, so a `lambda:FunctionArn` condition cannot match, and the stack fails to finish deleting or rolling back `DeliverFunction`'s SQS mapping.
   - `lambda:GetEventSourceMapping` and `lambda:ListEventSourceMappings` are on `*`. The same Lambda docs list them among actions that "don't support resource patterns or conditions".

   D5 states what the unconditioned grants leave open.
6. **The boundary content is the union of what the function roles hold today.**
   - The SAM policy templates `DynamoDBCrudPolicy`, `DynamoDBReadPolicy`, `SQSSendMessagePolicy` (`sqs:SendMessage*`) and `SSMParameterReadPolicy`, as listed in SAM docs, "AWS SAM policy template list".
   - The inline `s3:PutObject` and `kms:Decrypt` statements in `activity-app/functions/template.yaml`.
   - The managed policies SAM attaches: `AWSLambdaBasicExecutionRole` (`logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`) and `AWSLambdaSQSQueueExecutionRole` (adds `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`), as documented in the AWS Managed Policy Reference.

   Each boundary narrows that union to its own stage's resources. The PR check (Task 1 Step 3) keeps the template inside both.
7. **Name check.** Every action and condition key in Appendix A is in the AWS Policy Generator catalog, `https://awspolicygen.s3.amazonaws.com/js/policies.js`, fetched 2026-10-27. Task 1 Step 2 reruns the check against the committed template, with a misspelled-name negative control.

   The registry lists some API operation names that are not IAM actions, and they are excluded: for example `s3:DeleteBucketCors`, whose IAM action is `s3:PutBucketCORS`, and `cloudfront:CreateDistributionWithTags`.

### D4: The first creation of the role stack

The role stack is created by a dispatch of `oidc-roles.yml` from `main`, in a job bound to the `oidc-bootstrap` environment, with an explicit go. The static keys are never used for it.

The job assumes `OIDC_BOOTSTRAP_ROLE_ARN` with the pinned `configure-aws-credentials`; the ARN is a secret, so it is masked in the log. It writes the `sam deploy` output to a file under `$RUNNER_TEMP` and prints only `ok` or `failed`. Failure detail is read in the CloudFormation console by a maintainer with account access.

### D5: Least-privilege limits (stated, not hidden)

- **A deploy role can still create a function role with any trust policy.** `iam:CreateRole` has no condition key for the trust document.
  - The boundary caps what such a role can do to its own stage's table, queue, parameters, media objects and log groups.
  - The trust check's `inventory` job lists every role whose name begins `activity-app-<S>-`, using `iam:ListRoles` on the read-only trust-check role. It fails if any of them trusts anything other than `lambda.amazonaws.com`.
  - The deploy roles can create roles only under that prefix, so this detective control covers every role they can create.
- **Update and delete of event source mappings apply to every mapping in the account.** That is the price of a form that works on delete and rollback (D3.5).
  - What a mapping can invoke stays limited. Creating one requires a function under the stage prefix, and the deploy role can update and pass only functions and roles under that prefix, which run under the stage boundary.
  - A mapping retargeted to a stage function polls with that function's role. The boundary limits SQS to `activity-delivery-<S>`, so another project's queue cannot be read that way.
  - What the grant leaves open is disabling, deleting or retargeting another project's mapping in the same account. That is an availability risk, not an access one.
- **Resources with generated IDs are scoped by type, not by stage.** These are API Gateway `/restapis/*` and CloudFront cache policies, origin request policies and origin access controls.
  - The CloudFront distribution is scoped by ID, taken from `ACTIVITY_DISTRIBUTION_ID_STAGE` or `_PROD`. The template refuses an empty ID unless `AllowDistributionCreate` is `true`.
  - The Route 53 record write is scoped to each stage's one record name.
- **Read-only grants on `*`:** `route53:ListHostedZones`, `route53:GetChange`, `cloudwatch:DescribeAlarms`, `ssm:DescribeParameters` and the event-source-mapping reads.
- **The first CDN-template change after cutover is the first exercise of the CloudFront distribution and Route 53 record grants.** It runs on stage before prod.

---

## File structure

| File | Change | Responsibility |
|---|---|---|
| `activity-oidc/template.yaml` | Create | Five roles, two boundary policies, outputs (role names only) |
| `scripts/check-function-boundary.py` | Create | Offline check: every function permission in `activity-app/functions/template.yaml` falls inside the chosen stage's boundary in `activity-oidc/template.yaml` |
| `scripts/test-check-function-boundary.sh` | Create | Negative controls for that check, in the style of `scripts/test-detect-changed-targets.sh` |
| `.github/workflows/test.yml` | Modify | New job `function-boundary` on every PR |
| `.github/workflows/oidc-roles.yml` | Create | Dispatch-only, `environment: oidc-bootstrap`: deploy `FederatedActivityPublisher-oidc` with quiet output |
| `.github/workflows/oidc-trust-check.yml` | Create | Dispatch-only: per-role positive and negative assumes, scope checks, boundary checks; an `inventory` job for role trust, boundaries and distribution IDs. It deliberately spans every environment in one run, because a cross-environment refusal check cannot work otherwise. |
| `activity-app/functions/template.yaml` | Modify `Globals.Function` (75–107) | `PermissionsBoundary` |
| `.github/actions/setup-sam-portable/action.yml` | Modify `:59` | Pin `aws-actions/setup-sam` by SHA |
| `.github/workflows/deploy-stage.yml` | Modify | `--s3-prefix`, `--force-upload`, SHA pins, distribution guard; later the stage role, job outputs, and an `integration-tests` job without AWS |
| `.github/workflows/deploy-prod.yml` | Modify | Same, for prod |
| `.github/workflows/run-integration-tests.yml` | Modify `14–37` | `environment: integration`; integration role |
| `.github/workflows/environment.yml` | Modify `4–5`, `19–33` | `environment: infrastructure`; infra role |
| `.github/workflows/bootstrap.yml` | Modify `3–4`, `22–36` | `environment: infrastructure`; infra role; domain-change guard |
| `README.md`, `DeployYourOwn.md`, `BuildingAndDeploying.md`, `AWSPermissions.md` | Modify | The OIDC setup for this repository and for forks; the widen-the-boundary-first rule |

---

## Execution order

Task numbers group the work by subject. The real dependency order differs:

1. **Task 1.** Merge the template, the checker and the two dispatch workflows.
2. **Task 2 Steps 1–3.** Environments, secrets and the tag ruleset.
3. **Task 4.** Pins, prefixes and the distribution guard. `oidc-roles.yml` uses `setup-sam-portable`, whose fallback this task pins.
4. **Task 2 Steps 4–6.** The first role-stack deploy, which needs the Q12 credential, then the trust checks.
5. **Task 3.** The function-role boundary. It needs the boundary policies from Task 2 Step 4.
6. **Task 5.** The full trust check, once Task 3 has deployed to stage.
7. **Task 6.** Integration tests on OIDC.
8. **Task 7.** `deploy-stage` on OIDC. It needs Tasks 3 and 4 deployed to stage.
9. **Task 8.** Prod and infrastructure on OIDC. It needs a release carrying Tasks 3 and 4.
10. **Task 9.** Docs.
11. **Task 10.** Delete the static secrets.

### Task 1: Role template, boundary check and the two dispatch workflows

**Files:**
- Create: `activity-oidc/template.yaml`, `scripts/check-function-boundary.py`, `scripts/test-check-function-boundary.sh`, `.github/workflows/oidc-roles.yml` and `.github/workflows/oidc-trust-check.yml`
- Modify: `.github/workflows/test.yml`

**Interfaces:**
- Produces:
  - stack `FederatedActivityPublisher-oidc`, with outputs `StageDeployRoleName`, `ProdDeployRoleName`, `InfraRoleName`, `IntegrationReadRoleName` and `TrustCheckRoleName`;
  - managed policies `activity-app-<stage>-function-boundary`;
  - the role ARN form `arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/<role name>`;
  - `python3 scripts/check-function-boundary.py --stage {stage|prod} [--functions PATH] [--roles PATH]`. It exits 0 and prints `within <stage> boundary` when the functions template is within that stage's boundary. Otherwise it exits 1 and names each offending action or resource.

- [ ] **Step 1: Write `activity-oidc/template.yaml`**

  The template has no `Transform`.

  `Parameters`:
  - `GitHubOrg` (default `happitec-inc`) and `GitHubRepo` (default `FederatedActivityPublisher`);
  - `GitHubOrgId` (default `"174214171"`) and `GitHubRepoId` (default `"1193951865"`), both with `AllowedPattern: "^[0-9]+$"`;
  - `BootstrapStackName` (default `activity-bootstrap`);
  - `StageDistributionId` and `ProdDistributionId` (default `""`);
  - `AllowDistributionCreate`, with `AllowedValues: ["false", "true"]` and default `"false"`.

  `Conditions`: `DistributionCreate`, which is `AllowDistributionCreate` = `true`.

  `Rules`: an empty distribution variable fails the deploy instead of widening the grant.

  ```yaml
  Rules:
    DistributionIdsRequired:
      RuleCondition: !Equals [!Ref AllowDistributionCreate, "false"]
      Assertions:
        - Assert: !And
            - !Not [!Equals [!Ref StageDistributionId, ""]]
            - !Not [!Equals [!Ref ProdDistributionId, ""]]
          AssertDescription: Set ACTIVITY_DISTRIBUTION_ID_STAGE and _PROD, or deploy with AllowDistributionCreate=true for a first deployment
  ```

  The receipt is CloudFormation docs, "CloudFormation template Rules syntax", `https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/rules-section-structure.html`:
  - `RuleCondition`, `Assertions`, `Assert` and `AssertDescription` are the rule fields;
  - `Fn::And`, `Fn::Equals` and `Fn::Not` are listed rule functions;
  - "If a parameter value is invalid, CloudFormation does not create or update the stack."

  `Resources`:
  - **`StageFunctionBoundary` and `ProdFunctionBoundary`**: `AWS::IAM::ManagedPolicy`, with `ManagedPolicyName: activity-app-<stage>-function-boundary` and documents from Appendix A.5.
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
  3. **Policy size.** For each of the five roles and both boundaries, minify the policy with every `!Sub` and import replaced by a real-length placeholder:
     - a 12-digit account ID;
     - a 21-character zone ID;
     - a 14-character distribution ID;
     - a UUID certificate ID;
     - a 30-character domain.

     Expected: each role under 10,240 characters, each boundary under 6,144. Record the measured numbers in the PR body.

- [ ] **Step 3: Write the boundary check and its negative controls**

  **`scripts/check-function-boundary.py`** uses only Python 3 and `yaml`, from the distro package `python3-yaml`. It loads both templates with a `yaml.SafeLoader` subclass that turns every `!Tag` node into `{"Tag": value}`, so CloudFormation tags parse without being evaluated.

  1. **Boundary.** `--stage stage` reads `StageFunctionBoundary`, and `--stage prod` reads `ProdFunctionBoundary`, from `activity-oidc/template.yaml`. Its `Allow` statements give the allowed action and resource patterns. Any boundary pattern containing `?` or `[` fails with "unsupported pattern character": `fnmatch` gives those characters meanings IAM does not.
  2. **Function permissions.** For every `AWS::Serverless::Function` in `activity-app/functions/template.yaml`, collect:
     - **Each SAM policy template in `Policies:`**, expanded from a table in the script holding the four templates in D3.6, with actions and resource forms copied from SAM docs.
       - An unknown template name fails with "unknown SAM policy template <name>".
       - A bare string entry, meaning a managed-policy name or ARN, fails with "unsupported Policies entry <value>".
     - **Each inline `Statement` with `Effect: Allow`**: its actions and resources. `Deny` statements only narrow, so they are skipped.
     - **The managed policies SAM attaches**: `AWSLambdaBasicExecutionRole` for every function, and `AWSLambdaSQSQueueExecutionRole` for a function with an `SQS` event.
       - These are checked for actions only: their resource is `*`, and the boundary caps it by design.
       - Any `Events` type other than `Api` or `SQS` fails with "unsupported event type <type>", because other types attach managed policies the script does not model.
  3. **Resolve resources** to strings with `${Stage}` set to the `--stage` value, a fixed placeholder account ID and region `us-east-1`, by these exact forms:

     | Form in the template | Resolves to |
     |---|---|
     | `TableName` = import of `${EnvironmentStackName}-TableName` | `table/activity-${Stage}` and `.../index/*` |
     | `QueueName` = `!Select [4, !Split ["/", import of ...-QueueUrl]]` | `activity-delivery-${Stage}` |
     | `ParameterName: !Sub "activity/${Stage}/..."` | `parameter/activity/${Stage}/...` |
     | `!Sub "...alias/aws/ssm"` | that ARN |
     | `!Sub ["${BucketArn}/*", {BucketArn: import of ...-MediaBucketArn}]` | `arn:aws:s3:::activity-media-${Stage}/*` |

     Any other form fails with "cannot resolve resource <form>", so the check fails closed.
  4. **Match.**
     - An action is covered when its lowercased form `fnmatch.fnmatchcase`-matches a lowercased boundary action pattern. IAM action names are case-insensitive. `sqs:SendMessage*` is covered by the identical boundary pattern.
     - A resource is covered when it `fnmatch.fnmatchcase`-matches a boundary resource pattern rendered the same way. ARNs are case-sensitive.
     - Conditions are not compared (Task 9 Step 4 documents what that misses).
  5. **Report.** Print every uncovered `function / action / resource` and exit 1, or print `within <stage> boundary` and exit 0.

  **`scripts/test-check-function-boundary.sh`** copies both templates to a temp directory, applies one mutation per case, runs the check with `--functions` and `--roles` pointing at the copies, and asserts both the exit code and a token in the output. A YAML parse error or traceback carries none of the expected tokens, so it fails every case.

  | Case | Mutation | Run | Expected exit | Output must contain |
  |---|---|---|---|---|
  | (a) | None | `--stage stage` and `--stage prod` | 0, 0 | `within stage boundary`, `within prod boundary` |
  | (b) | Functions: the first inline `Action: s3:PutObject` becomes `Action: [s3:PutObject, s3:DeleteObject]` | `--stage stage` | 1 | `s3:DeleteObject` |
  | (c) | Functions: the first `DynamoDBCrudPolicy:` becomes `S3CrudPolicy:` | `--stage stage` | 1 | `unknown SAM policy template S3CrudPolicy` |
  | (d) | Functions: the first `alias/aws/ssm` becomes `alias/other` | `--stage stage` | 1 | `alias/other` |
  | (e) | As (b), and `s3:DeleteObject` added to the `Media` statement of `StageFunctionBoundary` only | `--stage stage`, then `--stage prod` | 0, then 1 | `within stage boundary`, then `s3:DeleteObject` |
  | (f) | `s3:PutObject` removed from the `Media` statement of `ProdFunctionBoundary` only | `--stage prod`, then `--stage stage` | 1, then 0 | `s3:PutObject`, then `within stage boundary` |
  | (g) | Functions: a bare string `- AmazonS3FullAccess` appended to the first `Policies:` list | `--stage stage` | 1 | `unsupported Policies entry` |
  | (h) | Functions: the first `Type: Api` event becomes `Type: S3` | `--stage stage` | 1 | `unsupported event type S3` |

  - Case (e) is a stage-only widening: it must pass for stage and fail for prod.
  - Case (f) narrows a boundary below what the functions use, so the boundary side of the comparison is exercised too.

  The script prints each case's result and exits non-zero if any case differs on exit code or token.

  **`.github/workflows/test.yml`** gains a job `function-boundary` with the same `runs-on` expression. Its steps:
  1. `actions/checkout@v6`;
  2. `sudo apt-get update && sudo apt-get install -y python3 python3-yaml`;
  3. `bash scripts/test-check-function-boundary.sh`;
  4. `python3 scripts/check-function-boundary.py --stage stage`;
  5. `python3 scripts/check-function-boundary.py --stage prod`.

  Expected on this PR: green. The receipt that today's functions template is within both boundaries is that job's own output on the PR, `within stage boundary` and `within prod boundary`. Record the run link in the PR body.

- [ ] **Step 4: Write `.github/workflows/oidc-roles.yml`**

  - Trigger: `workflow_dispatch`, with a boolean input `allow-distribution-create` defaulting to `false`.
  - `permissions: {contents: read, id-token: write}`.
  - `concurrency: {group: oidc-roles, cancel-in-progress: false}`.
  - One job with `if: github.ref == 'refs/heads/main'`, `environment: oidc-bootstrap`, and the usual `runs-on` expression: `${{ vars.RUNNER_LABELS_LINUX && fromJSON(vars.RUNNER_LABELS_LINUX) || 'ubuntu-latest' }}`.

  Steps:
  1. `actions/checkout@v6`.
  2. `./.github/actions/setup-sam-portable`, with its fallback pinned in Task 4. Until then, this job runs only after Task 4 merges; see Task 2 Step 4.
  3. `aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd` (v6), with `role-to-assume: ${{ secrets.OIDC_BOOTSTRAP_ROLE_ARN }}` and `aws-region: ${{ vars.AWS_REGION || 'us-east-1' }}`.
  4. **Deploy.** Run:

     ```
     sam deploy --template-file activity-oidc/template.yaml --stack-name FederatedActivityPublisher-oidc --capabilities CAPABILITY_NAMED_IAM --no-confirm-changeset --no-fail-on-empty-changeset --region <region> --parameter-overrides StageDistributionId=${{ vars.ACTIVITY_DISTRIBUTION_ID_STAGE }} ProdDistributionId=${{ vars.ACTIVITY_DISTRIBUTION_ID_PROD }} AllowDistributionCreate=${{ inputs.allow-distribution-create }}
     ```

     Redirect its output to `$RUNNER_TEMP/deploy.log`. Print `role stack: ok` or `role stack: failed (see the stack events in the CloudFormation console)`.
  5. **Outputs.** On success only, append `describe-stacks --stack-name FederatedActivityPublisher-oidc --query "Stacks[0].Outputs"` to `$GITHUB_STEP_SUMMARY`. These are role names.

  No step uploads `$RUNNER_TEMP`.

- [ ] **Step 5: Write `.github/workflows/oidc-trust-check.yml`**

  Trigger: `workflow_dispatch`. Workflow `permissions: {contents: read, id-token: write}`. One job per subject.

  The workflow deliberately binds jobs to every environment in one run. A check that each role refuses every other environment's subject cannot work otherwise. Record this as a deliberate exception to keeping one environment per workflow.

  **Negative assumes.**
  - Each one requests a token with `curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com"`. Both variables are in GitHub docs, "OpenID Connect reference".
  - It then calls `aws sts assume-role-with-web-identity` for the target role and passes only if stderr contains `AccessDenied`.
  - These calls are hand-rolled rather than made through the action because the check must tell `AccessDenied` apart from any other failure. The action reports every failure the same way.

  **Positive assumes** use the pinned `configure-aws-credentials` and run after the negatives.

  **Scope checks** send stdout to `/dev/null` and pass only on an `AccessDenied` or `AccessDeniedException` error.

  | Job | `environment:` | Must be denied | Must assume | Scope checks (must be denied) |
  |---|---|---|---|---|
  | `no-environment` | none | all five roles | none | none |
  | `stage` | `stage` | prod, infra, integration-read, trust-check | deploy-stage | `describe-stacks activity-app-prod`; `ssm get-parameter /activity/prod/keys/client-token`; `iam list-roles`; boundary checks |
  | `production` | `production` | stage, infra, integration-read, trust-check | deploy-prod | `describe-stacks activity-app-stage`; `iam list-roles` |
  | `infrastructure` | `infrastructure` | stage, prod, integration-read, trust-check | infra | `describe-stacks activity-app-prod` |
  | `integration` | `integration` | stage, prod, infra, trust-check | integration-read | `describe-stacks activity-environment-prod` |
  | `inventory` | `trust-check` | stage, prod, infra, integration-read | trust-check | `iam create-role` for `activity-app-stage-oidc-check-inventory`; `describe-stacks activity-environment-prod` |

  **Boundary checks** in `stage`, all against role names beginning `activity-app-stage-oidc-check-`, with the Lambda trust document:
  - `iam create-role` with no boundary: denied.
  - `iam create-role` with `--permissions-boundary` set to the prod boundary: denied.
  - `iam create-role --role-name FederatedActivityPublisher-github-actions-oidc-check`: denied (outside the prefix).
  - **Positive control:** `iam create-role` with the stage boundary succeeds.
    - On that role, `iam delete-role-permissions-boundary` is denied.
    - `iam delete-role` then succeeds.

    A step with `if: always()` deletes the role if it still exists.

  **Inventory**, in `inventory`, for each `<S>` in `stage` and `prod`:
  - **Role list.** List every role whose name begins `activity-app-<S>-`, with `iam list-roles --query "Roles[?starts_with(RoleName, 'activity-app-<S>-')].RoleName"`. The filter runs in the CLI. Print only the matching names.
  - **Trust.** For each listed role, fail if `AssumeRolePolicyDocument` has any statement whose principal is anything other than exactly `{"Service": "lambda.amazonaws.com"}` (Q5).
  - **Boundary.** For each listed role, `iam get-role` reports `PermissionsBoundary.PermissionsBoundaryArn`. Print only whether it ends `activity-app-<S>-function-boundary`, as `yes` or `no`.
  - **Stack roles.** Find the FunctionsStack with `describe-stack-resource --logical-resource-id FunctionsStack` on `activity-app-<S>`, then `list-stack-resources`. Every `AWS::IAM::Role` it lists must appear in the role list.
  - **Managed policies.** Print the distinct `arn:aws:iam::aws:policy/...` strings in `cloudformation get-template --template-stage Processed` of the FunctionsStack.
  - **Distribution.** The `CloudFrontDistributionId` output of `activity-app-<S>` must equal `vars.ACTIVITY_DISTRIBUTION_ID_<S>`. If it does not, fail and print both values; distribution IDs are not secrets.

- [ ] **Step 6: Open the PR**

  Expected: `test` and `function-boundary` green. After merge, the push changes `.github/`, so `deploy-stage` runs its full path on the static keys. Expected: green.

- [ ] **Step 7: Commit**

  ```bash
  git add activity-oidc/template.yaml scripts/check-function-boundary.py scripts/test-check-function-boundary.sh .github/workflows/test.yml .github/workflows/oidc-roles.yml .github/workflows/oidc-trust-check.yml
  git commit -m "ci: add OIDC role stack, boundary check and trust check"
  ```

### Task 2: One-time setup (maintainer, explicit go per step)

There is no code in this task. Record each result on the merged Task 1 PR.

- [ ] **Step 1: Environments**

  Use `PUT /repos/happitec-inc/FederatedActivityPublisher/environments/<name>` with `{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}` for `stage`, `production`, `infrastructure`, `integration`, `trust-check` and `oidc-bootstrap`. The last four are created by this call.

  Then add rules with `POST .../environments/<name>/deployment-branch-policies`:
  - `production`: `{"name": "main", "type": "branch"}` and `{"name": "v*", "type": "tag"}`;
  - all others: `{"name": "main", "type": "branch"}`.

  GitHub docs, "REST API endpoints for deployment branch policies": `custom_branch_policies` "must be set to `true` to use these endpoints", and `type` is `branch` or `tag`.

  Check: `GET .../environments` shows the six environments with `custom_branch_policies: true`.

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

  Negative control: a collaborator outside the bypass list pushes tag `v0.0.0-ruleset-check`. Expected: rejected. If it was created anyway, a bypass actor deletes it.

- [ ] **Step 4: Run `oidc-roles.yml` from `main`**

  **Preconditions:** the Q12 credential is in place, and Task 4 has merged so the SAM fallback is pinned.

  Expected: `role stack: ok`, with the step summary listing five role names. Nothing depends on the role stack before this run.

  On `failed`, a maintainer reads the stack events in the console, then stops and decides. Do not widen anything from the log.

- [ ] **Step 5: Positive-path trust check from `main`**

  Run `oidc-trust-check.yml` from `main`. At this point the function roles do not yet carry the boundary, so the inventory's boundary column shows `no`, which is expected here.

  Expected:
  - the assume, scope, boundary-create, trust and distribution checks pass;
  - every function role name begins `activity-app-stage-` (U2);
  - the managed policy ARNs are exactly `arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole` and `.../AWSLambdaSQSQueueExecutionRole` (U3).

  If the role prefix or the managed policies differ, revise Appendix A and repeat Steps 4–5.

- [ ] **Step 6: Negative control for the environment rules**

  Dispatch `oidc-trust-check.yml` on a throwaway branch `oidc-negative-control`. Expected:
  - the five environment-bound jobs are refused by the deployment branch rules before any step runs;
  - `no-environment` still passes, because every role refuses it.

  If any environment-bound job runs, stop. Delete the branch afterwards.

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

  Then run `python3 scripts/check-function-boundary.py --stage stage` and `--stage prod`. Expected: `within stage boundary` and `within prod boundary`.

- [ ] **Step 2: Open the PR; after merge, observe `deploy-stage`**

  The run is on the static keys. Expected:
  - green, including the integration tests, which exercise the SSM, KMS, DynamoDB and S3 paths under the boundary;
  - the trust check's inventory shows `yes` for every stage function role.

  Watch the stage functions' error counts in the Lambda console for one hour after the deploy. Expected: no new `AccessDenied` (U9).

- [ ] **Step 3: Prod**

  The boundary reaches prod with the next release, still on the static keys. Task 8 requires that release first.

- [ ] **Step 4: Reversibility**

  Until Task 10, reverting this PR removes the boundary, because the static keys can do so. After Task 10, the deploy roles are denied `iam:DeleteRolePermissionsBoundary` by design. Removing or replacing the boundary then needs a role-stack change through `oidc-roles.yml`: either widen the boundary, or temporarily change the deploy roles' grant. Record this in `AWSPermissions.md` (Task 9).

- [ ] **Step 5: Commit**

  ```bash
  git add activity-app/functions/template.yaml
  git commit -m "infra: permissions boundary on function roles"
  ```

### Task 4: Artifact prefixes, forced uploads, action pins and the distribution guard (current credentials)

**Files:**
- Modify: `.github/workflows/deploy-stage.yml`:
  - `sam package` (316–322);
  - the action references at 137, 156, 198, 290, 302, 310 and 423;
  - a new step after "Print stack outputs" (361–367).
- Modify: `.github/workflows/deploy-prod.yml`:
  - `sam package` (lines 92–96, inside the "Package and deploy with SAM" step);
  - the action references at 64, 76 and 84;
  - a new step after "Print stack outputs" (133–139).
- Modify: `.github/actions/setup-sam-portable/action.yml:59`

- [ ] **Step 1: Prefixes and forced uploads**

  `sam package` gains `--s3-prefix activity-app-stage` (or `activity-app-prod`) and `--force-upload`. `--force-upload` overrides existing objects with the same key, so `sam package` never reuses an artifact another writer placed in the shared bucket. `sam deploy` is unchanged: it deploys the packaged template and uploads nothing.

- [ ] **Step 2: Pin actions by SHA**

  - `aws-actions/configure-aws-credentials@v6` becomes `@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6`.
  - `aws-actions/setup-sam@v3` in `setup-sam-portable/action.yml:59` becomes `@341eee193f458fa5aae5d52c94b0c5cf3a1c5a52 # v3`.
  - `happitec-inc/public-actions/swift-build-cache-restore@main` and `/swift-build-cache-save@main` become the `main` SHA read with `gh api repos/happitec-inc/public-actions/commits/main --jq .sha` on the day of the change, recorded in the PR body.
  - `actions/*` stay on their major tags.

- [ ] **Step 3: Distribution guard**

  Add a step named "Check ACTIVITY_DISTRIBUTION_ID". It reads the `CloudFrontDistributionId` output of `activity-app-<stage>`.
  - **Variable set:** it fails if the variable and the output differ.
  - **Variable empty:** it reads the `AllowDistributionCreate` parameter of the role stack, with `describe-stacks --stack-name FederatedActivityPublisher-oidc` (granted in Appendix A.1, `RoleStackParameters`).
    - If that parameter is `true`, which means a fork's first deploy, it passes with a notice giving the ID to set.
    - Otherwise it fails and prints the ID to set.
  - **Until Task 7, while the job runs on the static keys,** the lookup has no role-stack restriction to honor. If `describe-stacks` on the role stack fails, the guard treats the parameter as `false`.

- [ ] **Step 4: Open the PR; after merge, observe `deploy-stage`; prod follows on the next release**

  Expected:
  - green;
  - every artifact uploaded under `activity-app-stage/`, which changes every function's code location;
  - the guard passes.

  Once each stage has one deploy on the prefix, its current template references only prefixed keys. Only then is the prefix-scoped `s3:GetObject` safe for rollback.

- [ ] **Step 5: Commit**

  ```bash
  git add .github/workflows/deploy-stage.yml .github/workflows/deploy-prod.yml .github/actions/setup-sam-portable/action.yml
  git commit -m "ci: per-stage artifact prefix, forced uploads, pinned actions"
  ```

### Task 5: Full trust check

- [ ] **Step 1: Run `oidc-trust-check.yml` from `main`**

  Expected: green. The inventory shows `yes` for every `activity-app-stage-*` role, and no non-Lambda trust in either stage. The `stage` job's boundary checks are the negative control for the IAM conditions:
  - creating a role without the stage boundary is denied;
  - creating one with the prod boundary is denied;
  - creating one outside the prefix is denied;
  - removing a boundary is denied.

### Task 6: `run-integration-tests.yml` on the integration role

**Files:**
- Modify: `.github/workflows/run-integration-tests.yml:18-37`

- [ ] **Step 1: Bind the job and switch the role**

  - The job gains `environment: integration`. Workflow-level `id-token: write` is already at lines 14–16.
  - Lines 32–37 become the pinned `configure-aws-credentials`, with `role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/FederatedActivityPublisher-github-actions-integration-read` and the existing `aws-region`.
  - Add a "Show assumed role" step: `aws sts get-caller-identity --query Arn --output text`.

  Check: `grep -n "AWS_ACCESS_KEY_ID\|AWS_SECRET_ACCESS_KEY" .github/workflows/run-integration-tests.yml` prints nothing.

- [ ] **Step 2: Open the PR; after merge, dispatch from `main` with `stage`, then `prod`**

  Expected:
  - both runs green;
  - "Show assumed role" names `...-integration-read`;
  - the prod run reads the client token (U5).

- [ ] **Step 3: Negative control**

  Dispatch with `stage` from a non-`main` branch. Expected: the environment's branch rule refuses the job (Q3).

- [ ] **Step 4: Commit**

  ```bash
  git add .github/workflows/run-integration-tests.yml
  git commit -m "ci: integration tests assume an OIDC role"
  ```

### Task 7: `deploy-stage.yml` on the stage role; integration tests without AWS

**Files:**
- Modify: `.github/workflows/deploy-stage.yml`, in jobs `fast-deploy`, `build` and `integration-tests`

**Precondition:** Tasks 3 and 4 are deployed to stage. The Task 5 inventory shows `yes` for every stage function role.

- [ ] **Step 1: Job permissions and role**

  - `fast-deploy` and `build` each get `permissions: {contents: read, actions: read, id-token: write}`. The workflow-level block (10–12) stays as it is for `detect` and `integration-tests`.
  - Their credentials steps use `role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/FederatedActivityPublisher-github-actions-deploy-stage`.
  - Add a "Show assumed role" step after each.

- [ ] **Step 2: Publish the stage URLs from the deploy jobs**

  In both `build` (after "Deploy with SAM") and `fast-deploy` (after "Update Lambda functions directly"), add a step with `id: urls`. It reads `ApiEndpoint` and `ClientApiUrl` from `activity-app-stage`, the same `describe-stacks` queries as lines 432–439, and writes `api_url` and `client_api_url` to `$GITHUB_OUTPUT`.

  Each job declares:

  ```yaml
  outputs:
    api_url: ${{ steps.urls.outputs.api_url }}
    client_api_url: ${{ steps.urls.outputs.client_api_url }}
  ```

- [ ] **Step 3: Remove AWS from `integration-tests`**

  Delete "Install AWS CLI" (407–420), "Configure AWS credentials" (422–427) and "Get stack outputs" (429–441). In "Run integration tests in Docker", set:

  ```yaml
  TEST_API_URL: ${{ needs.build.outputs.api_url || needs.fast-deploy.outputs.api_url }}
  TEST_CLIENT_API_URL: ${{ needs.build.outputs.client_api_url || needs.fast-deploy.outputs.client_api_url }}
  ```

  The job keeps the workflow-level permissions, `contents: read` and `actions: read`, and holds no `id-token`.

  Check: `grep -n "AWS_ACCESS_KEY_ID\|AWS_SECRET_ACCESS_KEY\|configure-aws-credentials" .github/workflows/deploy-stage.yml` shows only the two pinned `configure-aws-credentials` lines in `fast-deploy` and `build`.

- [ ] **Step 4: Open the PR; after merge, observe the push run**

  The merge changes `.github/`, so `detect` takes the full path. Expected:
  - `build` green, with "Show assumed role" naming `...-deploy-stage`;
  - the distribution guard passes;
  - `integration-tests` green, with both URLs non-empty in its environment.

  Check the fast path on the next merge that touches only `Sources/`. Expected: `fast-deploy` and `integration-tests` green.

- [ ] **Step 5: Negative control**

  Task 5 already measured the role side: the stage role is refused outside the `stage` environment and cannot read prod. For this run, the evidence is the grep from Step 3 plus the role "Show assumed role" names. Static keys would show a non-role principal there.

- [ ] **Step 6: Commit**

  ```bash
  git add .github/workflows/deploy-stage.yml
  git commit -m "ci: deploy stage with an OIDC role"
  ```

### Task 8: `deploy-prod.yml`, `environment.yml` and `bootstrap.yml`

**Files:**
- Modify: `.github/workflows/deploy-prod.yml:9-10` and `:83-88`
- Modify: `.github/workflows/environment.yml:4-5`, `:19-20` and `:28-33`
- Modify: `.github/workflows/bootstrap.yml:3-4`, `:22-23` and `:31-36`

**Precondition:** a release containing Tasks 3 and 4 has deployed to prod. The Task 5 inventory, rerun, shows `yes` for every prod function role.

- [ ] **Step 1: `deploy-prod.yml`**

  Workflow `permissions: {contents: read, id-token: write}`. The credentials step uses `...-deploy-prod`, followed by "Show assumed role".

- [ ] **Step 2: `environment.yml` and `bootstrap.yml`**

  - Workflow `permissions: {contents: read, id-token: write}`.
  - The job gains `environment: infrastructure`.
  - The credentials step uses `...-infra`, pinned as in Task 4, followed by "Show assumed role".

  `bootstrap.yml` also gains, before "SAM build", a step named "Refuse a domain change on an existing stack". It reads the `DomainName` parameter of `activity-bootstrap` with `describe-stacks` and fails if the stack exists and the value differs from `inputs.domain-name`.

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

### Task 9: Docs, including the self-hosted path and the boundary rule

**Files:**
- Modify: `README.md:146-153`
- Modify: `Sources/ActivityPubCore/Documentation.docc/DeployYourOwn.md:5-30`
- Modify: `Sources/ActivityPubCore/Documentation.docc/BuildingAndDeploying.md:18-27`, `:54-56`, `:94-96`, `:113-115` and `:154`
- Modify: `Sources/ActivityPubCore/Documentation.docc/AWSPermissions.md`

- [ ] **Step 1: `README.md`**

  The "Required GitHub Secrets" table drops the two key rows. It adds:
  - `AWS_ACCOUNT_ID`;
  - `OIDC_BOOTSTRAP_ROLE_ARN`, in the `oidc-bootstrap` environment, used only by `oidc-roles.yml`.

  The variables table notes that `ACTIVITY_DISTRIBUTION_ID_STAGE` and `_PROD` are required once the first deploy has run, because they scope the deploy roles. Add an "Environments" table listing the six environments and their branch rules.

- [ ] **Step 2: `DeployYourOwn.md`**

  Replace Step 2 (lines 20–29) with an OIDC setup that needs no role from this project's org:
  1. Create the account's GitHub OIDC identity provider, `token.actions.githubusercontent.com` with audience `sts.amazonaws.com`.
  2. With administrator credentials of your own, deploy once, from your machine or the CloudFormation console:
     - `activity-bootstrap`;
     - `activity-environment-stage` and `activity-environment-prod`;
     - `activity-oidc/template.yaml`, with `GitHubOrg`, `GitHubRepo`, `GitHubOrgId` and `GitHubRepoId` set to your fork's values and `AllowDistributionCreate=true`.

     Give the exact `sam deploy` commands the workflows use. Retained data stores are created once this way; the CI roles never create them.
  3. Add the secret `AWS_ACCOUNT_ID` and the six environments with their branch rules. Optionally, set `OIDC_BOOTSTRAP_ROLE_ARN` to a role you control, so later role-stack updates run through `oidc-roles.yml`.
  4. Run the first app deploy. With `AllowDistributionCreate=true`, the distribution guard passes and prints the distribution ID to set.
  5. Set `ACTIVITY_DISTRIBUTION_ID_STAGE` and `_PROD` from the guard's notice, and redeploy the role stack with `AllowDistributionCreate=false`.

  Lines 7 and 29 change to say the CI roles are scoped by construction and that no long-lived key is stored in GitHub.

- [ ] **Step 3: `BuildingAndDeploying.md`**

  - Each "Required secrets" block names the role the workflow assumes, its environment, and `AWS_ACCOUNT_ID`.
  - The `deploy-stage` section says `integration-tests` takes the stage URLs from the deploy job's outputs and holds no AWS credential.
  - Line 154 notes that the prod token read requires the `integration` environment.
  - Add a section on `oidc-roles.yml`, `oidc-trust-check.yml` and the `function-boundary` PR check.

- [ ] **Step 4: `AWSPermissions.md`**

  Add a "CI roles and the function boundary" section. It states:
  - `activity-oidc/template.yaml` is the authoritative list.
  - **Widen the boundary first.** To give a function a new permission, change `StageFunctionBoundary` and `ProdFunctionBoundary` in `activity-oidc/template.yaml`, merge, and run `oidc-roles.yml`. Only then merge the change to `activity-app/functions/template.yaml`.
    - A function permission outside the boundary deploys green and fails with `AccessDenied` at runtime, on stage first and in prod after the next release.
    - The `function-boundary` PR check compares against both boundaries as committed, not as deployed, so the order of merges and the `oidc-roles.yml` run is what protects production.
    - The check does not compare conditions. For example, the boundary allows `kms:Decrypt` only through SSM (`kms:ViaService`). A function that calls KMS directly would pass the check and fail at runtime.
  - Removing the boundary after the static keys are gone needs a role-stack change (Task 3 Step 4).

  The existing per-service lists remain the guide for an administrator's one-time deploy.

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

  The next `deploy-stage` push run is green, and a `run-integration-tests` dispatch with `stage` is green.

**Not in this plan:** the access key the deleted secrets held. Rotating or deactivating it is an IAM write and a separate decision (Q7).

---

## Open questions

- **Q1: Where the roles are defined.** Options (a), (b) and (c) are compared in D1. Recommendation: (c). None of them changes the deploying credential's permissions; that is Q12.
- **Q2: Five roles.** Stage deploy, prod deploy, infra, integration read, and the read-only trust-check role that holds `iam:ListRoles`. The stage test job's credential is removed, not just narrowed (D2).
- **Q3: Integration tests from branches.** `run-integration-tests.yml` was last dispatched from a non-`main` branch on 2026-06-16. The `integration` environment's `main` rule ends that. Recommendation: keep `main` only.
- **Q4: `bootstrap.yml`.** Run a no-op dispatch before Task 10, which needs the existing `domain-name` and `dns-mode` values? Or accept it untested until it is next needed?
- **Q5: Function-role trust.** A deploy role can create a stage function role with an arbitrary trust (D5). The plan adds a detective control: the trust check fails on any non-Lambda principal in any `activity-app-<S>-*` role in the account. It runs on dispatch, not continuously. Is that sufficient?
- **Q6: `oidc-trust-check.yml` after cutover.** Keep it as a regression check for template changes, or delete it after Task 10? Recommendation: keep.
- **Q7: The access key behind the deleted secrets.** Rotate, deactivate or leave it? This is a separate IAM-write decision.
- **Q8: Role names.** Are the five names acceptable?
- **Q9: `v*` tag ruleset bypass list.** Who may create, move and delete release tags? Recommendation: the repository admin role only.
- **Q10: Required reviewers.** Add required reviewers to `production`, `infrastructure` and `oidc-bootstrap`? Recommendation: yes for `oidc-bootstrap` and `infrastructure`; for `production`, it is a release-flow decision.
- **Q11: Split build and deploy jobs.** Splitting would mean the jobs that hold `id-token: write` run no build steps at all; artifacts would pass between jobs. With SHA pins and a token-free build container, the remaining exposure is GitHub-owned actions. Recommendation: not now.
- **Q12: The one-time role-stack credential.** The one-time role-stack deploy needs a credential that can create the two stage boundary managed policies. How that credential is provided is decided outside this plan.
- **Q13: `python3-yaml` in PR CI.** The boundary check installs the distro package `python3-yaml` (PyYAML) with `apt-get`, the same package manager `test.yml` already uses. It is not on a security path: the job parses this repository's own templates and holds no secrets. It still needs an explicit maintainer decision before Task 1. Accept it, or write the check against a YAML parser already in the build?

## Unverified premises, and what measures each

| # | Premise | Measured by |
|---|---|---|
| U1 | This repository presents the previous subject form, based on its creation date. Both forms are trusted. | Task 2 Step 5 |
| U2 | SAM-generated function role names begin `activity-app-<stage>-`. | Task 2 Step 5 inventory |
| U3 | SAM attaches exactly `AWSLambdaBasicExecutionRole` and `AWSLambdaSQSQueueExecutionRole`. | Task 2 Step 5 inventory |
| U4 | `route53:ChangeResourceRecordSetsNormalizedRecordNames` compares against the lowercase name with no trailing dot. | The first record change. It fails closed on stage first. |
| U5 | The integration role's `kms:Decrypt` with `kms:ViaService` suffices for `--with-decryption` on the prod token. | Task 6 Step 2 |
| U6 | The SAM managed bucket's encryption needs no KMS permission for `PutObject`. | Task 7 Step 4 |
| U7 | The CloudFormation handlers call nothing outside Appendix A for these templates. That includes the event-source-mapping delete and rollback path, which calls update and delete for a mapping that may already be gone. | Each validation run; for CloudFront, the first CDN change; for the mapping delete path, the first stack rollback or mapping removal |
| U8 | Each action in Appendix A supports the resource ARN it is granted on. The catalog confirms names, not resource types. | `AccessDenied` in a validation run names the action and ARN |
| U9 | The boundary, including `kms:Decrypt` conditioned on `kms:ViaService`, keeps every function working. | Task 3 Step 2: integration tests and one hour of Lambda error counts |
| U10 | `--force-upload` on `sam package` with `--s3-prefix` re-uploads every artifact each time. | Task 4 Step 4 log |
| U11 | CloudFormation needs no `lambda:TagResource` on an event source mapping when the template sets no tags. | Task 7 Step 4 |
| U12 | The runner images used by `test.yml` can install `python3` and `python3-yaml` with `apt-get`. | Task 1 Step 6 |

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
| `CreateEventSourceMappings` | Allow | `lambda:CreateEventSourceMapping` | `*` | `ArnLike` `lambda:FunctionArn`: `<Fn>` |
| `ChangeEventSourceMappings` | Allow | `lambda:UpdateEventSourceMapping`, `lambda:DeleteEventSourceMapping` | `*` | |
| `ReadEventSourceMappings` | Allow | `lambda:GetEventSourceMapping`, `lambda:ListEventSourceMappings` | `*` | |
| `FunctionRolesBounded` | Allow | `iam:CreateRole`, `iam:PutRolePolicy`, `iam:DeleteRolePolicy`, `iam:PutRolePermissionsBoundary` | `arn:aws:iam::<A>:role/activity-app-<S>-*` | `StringEquals` `iam:PermissionsBoundary`: `<B>` |
| `FunctionRoleManagedPolicies` | Allow | `iam:AttachRolePolicy`, `iam:DetachRolePolicy` | `arn:aws:iam::<A>:role/activity-app-<S>-*` | `StringEquals` `iam:PermissionsBoundary`: `<B>` and `ArnEquals` `iam:PolicyARN`: `arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole`, `arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole` |
| `FunctionRolesOther` | Allow | `iam:` `GetRole`, `GetRolePolicy`, `ListRolePolicies`, `ListAttachedRolePolicies`, `DeleteRole`, `UpdateRole`, `UpdateRoleDescription`, `TagRole`, `UntagRole`, `ListRoleTags` | `arn:aws:iam::<A>:role/activity-app-<S>-*` | |
| `NoBoundaryRemoval` | Deny | `iam:DeleteRolePermissionsBoundary` | `*` | |
| `PassFunctionRoles` | Allow | `iam:PassRole` | `arn:aws:iam::<A>:role/activity-app-<S>-*` | `StringEquals` `iam:PassedToService`: `lambda.amazonaws.com` |
| `ApiGateway` | Allow | `apigateway:` `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `UpdateRestApiPolicy` | `arn:aws:apigateway:<region>::/restapis`, `.../restapis/*`, `.../tags/*` | |
| `CloudFrontDistribution` | Allow | `cloudfront:` `GetDistribution`, `GetDistributionConfig`, `UpdateDistribution`, `UpdateDistributionWithStagingConfig`, `TagResource`, `UntagResource`, `ListTagsForResource` | `arn:aws:cloudfront::<A>:distribution/<DistId>`, or `distribution/*` under `DistributionCreate` (`Fn::If`) | |
| `CloudFrontDistributionCreate` | Allow | `cloudfront:CreateDistribution` | `arn:aws:cloudfront::<A>:distribution/*` | Present only under `DistributionCreate` (`Fn::If` … `AWS::NoValue`) |
| `CloudFrontPolicies` | Allow | `cloudfront:` `Create`, `Get`, `Update` and `Delete` of each of `CachePolicy`, `OriginRequestPolicy` and `OriginAccessControl`: 12 actions | `arn:aws:cloudfront::<A>:cache-policy/*`, `...:origin-request-policy/*`, `...:origin-access-control/*` | |
| `CloudFrontFunction` | Allow | `cloudfront:` `CreateFunction`, `DescribeFunction`, `GetFunction`, `PublishFunction`, `UpdateFunction`, `DeleteFunction`, `TagResource`, `UntagResource`, `ListTagsForResource` | `arn:aws:cloudfront::<A>:function/activity-profile-rewrite-<S>` | |
| `DnsRecord` | Allow | `route53:ChangeResourceRecordSets` | `arn:aws:route53:::hostedzone/<Zone>` | `ForAllValues:StringEquals` `route53:ChangeResourceRecordSetsNormalizedRecordNames`: stage `stage.<Domain>`, prod `<Domain>` |
| `DnsRead` | Allow | `route53:GetHostedZone`, `route53:ListResourceRecordSets` | `arn:aws:route53:::hostedzone/<Zone>` | |
| `DnsLookups` | Allow | `route53:GetChange`, `route53:ListHostedZones` | `*` | |
| `MediaBucketPolicy` | Allow | `s3:GetBucketPolicy`, `s3:PutBucketPolicy`, `s3:DeleteBucketPolicy`, `s3:ListBucket` | `arn:aws:s3:::activity-media-<S>` | |
| `FrontendAssets` | Allow | `s3:PutObject` | `arn:aws:s3:::activity-media-<S>/media/frontend/*` | |
| `RoleStackParameters` | Allow | `cloudformation:DescribeStacks` | `stack/${GitHubRepo}-oidc/*` | |

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

The SNS topic and the alarm are not retained, so they keep create and delete. The table, bucket and queues get neither.

### A.3 Integration role (`...-integration-read`)

| Sid | Actions | Resource | Condition |
|---|---|---|---|
| `AppOutputs` | `cloudformation:DescribeStacks` | `stack/activity-app-stage/*`, `stack/activity-app-prod/*` | |
| `ProdClientToken` | `ssm:GetParameter` | `arn:aws:ssm:<region>:<A>:parameter/activity/prod/keys/client-token` | |
| `DecryptViaSsm` | `kms:Decrypt` | `arn:aws:kms:<region>:<A>:key/*` | `StringEquals` `kms:ViaService`: `ssm.<region>.amazonaws.com` |

### A.4 Trust-check role (`...-trust-check`)

The role is read-only. It is used only by `oidc-trust-check.yml`'s `inventory` job.

| Sid | Actions | Resource |
|---|---|---|
| `ListRoles` | `iam:ListRoles` | `arn:aws:iam::<A>:role/*` |
| `ReadAppRoles` | `iam:GetRole` | `arn:aws:iam::<A>:role/activity-app-stage-*`, `arn:aws:iam::<A>:role/activity-app-prod-*` |
| `AppStacks` | `cloudformation:` `DescribeStacks`, `DescribeStackResource`, `ListStackResources`, `GetTemplate` | `stack/activity-app-stage/*`, `stack/activity-app-stage-*/*`, `stack/activity-app-prod/*`, `stack/activity-app-prod-*/*` |

### A.5 Function boundaries (`activity-app-<S>-function-boundary`)

| Sid | Actions | Resource | Condition |
|---|---|---|---|
| `Logs` | `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` | `arn:aws:logs:<region>:<A>:log-group:/aws/lambda/activity-app-*-<S>`, `...:log-group:/aws/lambda/activity-app-*-<S>:*` | |
| `Table` | `dynamodb:` `GetItem`, `DeleteItem`, `PutItem`, `Scan`, `Query`, `UpdateItem`, `BatchWriteItem`, `BatchGetItem`, `DescribeTable`, `ConditionCheckItem` | `table/activity-<S>`, `table/activity-<S>/index/*` | |
| `Queue` | `sqs:SendMessage*`, `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` | `arn:aws:sqs:<region>:<A>:activity-delivery-<S>` | |
| `Parameters` | `ssm:GetParameter`, `ssm:GetParameters`, `ssm:GetParametersByPath` | `arn:aws:ssm:<region>:<A>:parameter/activity/<S>/*` | |
| `ParameterList` | `ssm:DescribeParameters` | `*` | |
| `DecryptViaSsm` | `kms:Decrypt` | `arn:aws:kms:<region>:<A>:key/*`, `arn:aws:kms:<region>:<A>:alias/aws/ssm` | `StringEquals` `kms:ViaService`: `ssm.<region>.amazonaws.com` |
| `Media` | `s3:PutObject` | `arn:aws:s3:::activity-media-<S>/*` | |

`sqs:SendMessage*` mirrors the SAM template's form. In the action catalog it matches `sqs:SendMessage` only.

The boundary grants nothing on its own: a function's effective permissions are the intersection of its role's policies and this boundary. The explicit `Deny` statements in `InboxFunction`'s policy keep applying.
