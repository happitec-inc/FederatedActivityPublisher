# OIDC Deploy Roles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every GitHub Actions job here that talks to AWS assumes a repo-scoped IAM role through GitHub OIDC. After that, the static key secrets `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are deleted.

**Architecture:**

- **The role stack.** One plain CloudFormation template, `activity-oidc/template.yaml`, defines **five IAM roles with inline policies** and nothing else. Each role trusts exactly one OIDC subject of this repository: stage deploy, prod deploy, infrastructure, integration read, and a read-only trust-check role. A manually dispatched workflow, bound to its own environment, deploys it. It authenticates with the credential in `OIDC_BOOTSTRAP_ROLE_ARN` (Q12). Self-hosters use credentials of their own.
- **The function boundaries.** Each `activity-environment-<stage>` stack gains one permissions-boundary managed policy, `activity-app-<stage>-function-boundary`. `environment.yml` deploys it on the infra role (Task 11). Every Lambda execution role the deploy roles create or change must carry its stage's boundary. The deploy roles hold no managed-policy write action, so neither can loosen its own boundary.
- **Detection.** A function permission outside the boundary deploys green and fails with `AccessDenied` when the handler runs. Stage's post-deploy integration tests run the handlers after every stage deploy that changes function permissions, before any release reaches prod (D5).

These changes land first, on the current credentials:

- per-stage SAM artifact prefixes with forced uploads;
- SHA-pinned third-party actions;
- a distribution-ID guard.

Then `environment.yml` moves to the infra role and deploys the two boundaries, and the function roles take the boundary. After that the remaining workflows move to `role-to-assume` in this order: integration tests, stage, prod and bootstrap. The push-triggered stage test job stops holding AWS credentials altogether. Docs follow, and the static secrets are deleted last.

**Tech Stack:** GitHub Actions, `aws-actions/configure-aws-credentials` (pinned by SHA), AWS SAM CLI through `./.github/actions/setup-sam-portable`, CloudFormation and IAM.

**Spec:** None separate. Moving to OIDC was settled 2026-10-27. The requirements are restated under Global Constraints, and "Decisions" argues each choice.

## Global Constraints

- **Trust.** Each role trusts the account's GitHub OIDC provider (`token.actions.githubusercontent.com`) with `StringEquals` on two claims:
  - `aud` = `sts.amazonaws.com`;
  - `sub` = this repository's subject for that role, in both the previous form `repo:<org>/<repo>:<suffix>` and the immutable form `repo:<org>@<org-id>/<repo>@<repo-id>:<suffix>`.

  No wildcards. The org, repo and IDs are template parameters. Their defaults are this repository's values: `happitec-inc`, `FederatedActivityPublisher`, owner ID `174214171` and repo ID `1193951865`, read from `GET /repos/happitec-inc/FederatedActivityPublisher` on 2026-10-27.
- **No AWS managed policy** is attached to any of the five roles, and no role is shared with another project.
- **Every IAM role-write action of the deploy roles is conditioned on `iam:PermissionsBoundary`** equal to that stage's boundary policy. `iam:UpdateAssumeRolePolicy` is not granted. `iam:DeleteRolePermissionsBoundary` is explicitly denied.
- **Only the infra role writes the boundary policies.** It holds `iam:CreatePolicy`, `iam:CreatePolicyVersion`, `iam:DeletePolicyVersion`, `iam:DeletePolicy`, `iam:GetPolicy`, `iam:GetPolicyVersion`, `iam:ListPolicyVersions` and `iam:ListEntitiesForPolicy`, on exactly the two boundary ARNs (D3.2). The deploy roles hold none of those actions.
- **The role stack contains only `AWS::IAM::Role` resources with inline policies.** No managed policy is defined in it.
- **Names.**
  - Roles: `FederatedActivityPublisher-github-actions-deploy-stage`, `FederatedActivityPublisher-github-actions-deploy-prod`, `FederatedActivityPublisher-github-actions-infra`, `FederatedActivityPublisher-github-actions-integration-read` and `FederatedActivityPublisher-github-actions-trust-check`.
  - Boundaries: `activity-app-stage-function-boundary` in stack `activity-environment-stage`, and `activity-app-prod-function-boundary` in stack `activity-environment-prod`.
  - Role stack: `FederatedActivityPublisher-oidc`.
- **The template has no `Transform:`** and stays under 51,200 bytes, the CloudFormation limit for an inline template body. That way it can be deployed from the console, the CLI or the dispatch workflow without an artifact bucket.
- **Size limits.** Each role's inline policies total at most 10,240 characters, and each managed policy at most 6,144 characters, whitespace excluded. Both limits are from the IAM quotas page.
- **Identifiers stay out of the repository and out of public logs.**
  - The account ID is the repository secret `AWS_ACCOUNT_ID`.
  - The role-stack credential's ARN is `OIDC_BOOTSTRAP_ROLE_ARN`, a secret of the `oidc-bootstrap` environment.
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
- **A permission outside the boundary deploys green and fails at runtime.** `iam:PutRolePolicy` is conditioned on the boundary, not on what the policy says. Stage's post-deploy integration tests detect it: the handler's AWS call returns `AccessDenied`, the request fails, and the test fails, before any release reaches prod. They detect it only in the handlers and code paths the tests exercise; D5 lists the handlers they don't call.
- **The deploy roles cannot loosen their own boundary.** They hold no managed-policy write action. Only the infra role can change the boundary policies, and only those two (A.2 `FunctionBoundaries`). Task 1 Step 4's trust check measures both sides.
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
| (b) Publish a generic, opt-in reusable role workflow in a shared public actions repository | A new shared component in another repository | Adds a component | Right for a tool many public repos share | A cross-repo change and review; still has to emit five roles |
| **(c) This repository owns `activity-oidc/template.yaml` and deploys it with `oidc-roles.yml`** | One template and one small workflow here | **Yes.** No new component elsewhere | **Yes.** The roles and boundaries live with their only consumer, and the template is plain CloudFormation that self-hosters can deploy with their own credentials | Hand-written IAM to review |

**Recommendation: (c).** `oidc-roles.yml` authenticates with the credential in `OIDC_BOOTSTRAP_ROLE_ARN` (Q12). Task 2 Step 4 is its first run.

Options (a), (b) and (c) differ in where the roles are defined and which workflow deploys them. The credential that deploys the role stack is a separate question, Q12.

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
- **`infra` is split from the deploy roles.** The data and DNS stacks change rarely and by hand. With their grants off the deploy roles, the roles used on every merge and release cannot reconfigure the table, bucket, queues, hosted zone or certificate. The split also keeps each deploy role's inline policy well under the size limit; Task 1 Step 2 measures all five roles from the committed template.
- **The push-triggered stage test job holds no AWS credential.** It used AWS only to read `ApiEndpoint` and `ClientApiUrl`. In Task 7, `build` and `fast-deploy`, which already hold the stage role, publish those two URLs as job outputs, and `integration-tests` reads them from `needs`. The URLs contain no secret-derived value, so the runner keeps the outputs.
- **The prod client token is readable only from jobs bound to the `integration` environment.** Today that means `run-integration-tests.yml` alone.
- **`trust-check` is a separate, read-only role.** It holds `iam:ListRoles`, so the inventory can scan every `activity-app-<S>-*` role in the account, not only the ones in the functions stack. Keeping it off the deploy roles means no merge-time role can enumerate the account's roles.

### D3: Permission derivation

1. **The AWS calls every workflow step makes** are listed in the current-state table.
2. **For every resource type the templates create**, the CloudFormation registry schema lists the permissions its handlers call. These are `handlers.<op>.permissions` and `tagging.permissions` in `CloudformationSchema.zip`, from `https://schema.cloudformation.us-east-1.amazonaws.com/CloudformationSchema.zip`, downloaded 2026-10-27.

   The functions stack yields `AWS::Lambda::Function`, `AWS::IAM::Role`, `AWS::Lambda::Permission`, `AWS::Lambda::EventSourceMapping` and `AWS::ApiGateway::RestApi`, `Deployment` and `Stage`.

   The CDN stack declares CloudFront `CachePolicy`, `OriginRequestPolicy`, `OriginAccessControl`, `Function` and `Distribution`, plus `S3::BucketPolicy` and `Route53::RecordSet`.

   The environment stack declares `S3::Bucket`, `DynamoDB::Table`, `SQS::Queue`, `SNS::Topic` and `CloudWatch::Alarm`, and after Task 11 one `IAM::ManagedPolicy`, the stage's function boundary. The bootstrap stack declares `Route53::HostedZone` and `CertificateManager::Certificate`.

   For `AWS::IAM::ManagedPolicy`, the infra role's grant follows the same rule (A.2 `FunctionBoundaries`). The registry schema `aws-iam-managedpolicy.json`, read 2026-10-27, lists these handler permissions:
   - `create`: `iam:CreatePolicy`;
   - `read`: `iam:GetPolicy`, `iam:GetPolicyVersion`, `iam:ListEntitiesForPolicy`;
   - `update`: `iam:GetPolicy`, `iam:ListPolicyVersions`, `iam:CreatePolicyVersion`, `iam:DeletePolicyVersion`;
   - `delete`: `iam:GetPolicy`, `iam:ListPolicyVersions`, `iam:DeletePolicyVersion`, `iam:DeletePolicy`, `iam:ListEntitiesForPolicy`.

   Each handler also lists `Attach*` and `Detach*` actions for groups, users and roles. Those apply only when the policy names `Roles`, `Groups` or `Users`, and the boundary names none, so they are left out. The schema's `tagging` block says `"taggable": false`, so no tagging action is granted. The `list` handler's `iam:ListPolicies` is left out too, because stack create, update and delete use the other four handlers [inferred].
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

   Each boundary narrows that union to its own stage's resources. A function permission outside it is detected by stage's post-deploy integration tests, within the limits D5 states.
7. **Name check.** Every action and condition key in Appendix A is in the AWS Policy Generator catalog, `https://awspolicygen.s3.amazonaws.com/js/policies.js`, fetched 2026-10-27. Task 1 Step 2 reruns the check against the committed template, with a misspelled-name negative control.

   The registry lists some API operation names that are not IAM actions, and they are excluded: for example `s3:DeleteBucketCors`, whose IAM action is `s3:PutBucketCORS`, and `cloudfront:CreateDistributionWithTags`.

### D4: The first creation of the role stack

The role stack is created by a dispatch of `oidc-roles.yml` from `main`, in a job bound to the `oidc-bootstrap` environment, with an explicit go. The static keys are never used for it. The stack contains only IAM roles with inline policies; the boundaries it refers to by ARN come from the infra role's deploy of the environment stacks (D6).

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
- **Read-only grants on `*`:** `route53:ListHostedZones`, `route53:GetChange`, `cloudwatch:DescribeAlarms`, `ssm:DescribeParameters`, the event-source-mapping reads, and the trust-check role's `iam:ListRoles`.
- **The first CDN-template change after cutover is the first exercise of the CloudFront distribution and Route 53 record grants.** It runs on stage before prod.
- **The infra role can rewrite both boundaries.** That is where the boundary is meant to change. Its policy writes are limited to the two boundary ARNs. The role is bound to the `infrastructure` environment, which allows `main` only (Q10 covers required reviewers). The deploy roles hold no managed-policy write action, so a stage or prod deploy role cannot loosen the boundary it is held to.
- **A function permission outside the boundary deploys green.** CloudFormation accepts the role policy, because `iam:PutRolePolicy` is conditioned on the boundary ARN, not on the document. The permission fails with `AccessDenied` when the handler makes the call.

  **Detection is stage's post-deploy integration tests.** They run the handlers against stage, and an `AccessDenied` there fails the request and the test before any release reaches prod. A function permission changes in one of two ways, and both are followed by those tests:
  - **The functions template.** Any change under `activity-app/` sends `deploy-stage.yml` down the full path (line 57). So does a dispatch (lines 36–39). The full path is job `build` (lines 245–247), and job `integration-tests` runs after it (`needs: [detect, fast-deploy, build]`, lines 370–375, at `origin/main`).
  - **The boundary itself.** `environment.yml` deploys it. On `main` today, nothing runs the tests after that workflow. That was a gap, and Task 11 closes it: `environment.yml` gains an `integration-tests` job that calls `run-integration-tests.yml` for `stage` after `deploy` succeeds.

  No other check is added.

  **What the tests don't cover.** The tests exercise only the handlers and code paths they call. Every function carries the same boundary, so one tested call proves its action and resource for every function. A gap remains wherever only an untested handler or path makes a call. Per `integration-tests/Tests/IntegrationTests/` at `origin/main`, the stage tests make no request to these handlers:
  - `InstanceFunction` (`/api/v1/instance`, `/api/v2/instance`);
  - `ObjectFunction` (`/users/{username}/statuses/{id}`);
  - `ProfileFunction` (`/profile/{proxy+}`). `actorContentNegotiationHTML` stops at the 302 to `/@randomforms` and does not follow it;
  - `InboxFunction` (`POST /users/{username}/inbox`). `ActorIntegrationTests` only checks the inbox URL in the actor document;
  - `DeliverFunction`, the SQS consumer. A posted status can enqueue a delivery, but no test waits for or asserts on it. It is the only function with an `SQS` event, so it is the only role holding `AWSLambdaSQSQueueExecutionRole`'s `sqs:ReceiveMessage`, `sqs:DeleteMessage` and `sqs:GetQueueAttributes`. A boundary gap there fails no test.

  Some handlers the tests do call are covered only in part:
  - `AuthFunction`: only `/api/internal/auth/challenge` and `/api/internal/passkeys/register-challenge`.
  - `ComposeFunction`: only the no-session redirect.

  **What that means.** A boundary gap that only those handlers or paths reach passes stage's tests. It then reaches prod with the next release. It shows up only as `AccessDenied` in that function's logs and error count when real traffic reaches it, on stage if stage gets such traffic, otherwise in prod. Task 3 Step 2's one-hour watch of the stage functions' error counts sees only the traffic that arrives in that hour.
- **A prod boundary change is gated on stage.** `environment.yml` with `prod` refuses to deploy unless the latest `stage` run of `environment.yml` at the same commit succeeded, including its `integration-tests` job (Task 11 Step 3). The two boundaries come from one resource definition, substituted by `Stage`, so the stage run tests the same document shape first. The gate checks that a stage run succeeded. It does not check what that run's tests reached.
- **A release cut after a red stage run carries the failure to prod.** This plan does not change the release flow.

### D6: Where the boundary policies live

- **The role stack holds only IAM roles with inline policies.** `FederatedActivityPublisher-oidc` defines the five roles and no managed policy.
- **The boundaries live in the environment stacks.** `FunctionBoundary` in `activity-environment/template.yaml` yields `activity-app-stage-function-boundary` in `activity-environment-stage` and `activity-app-prod-function-boundary` in `activity-environment-prod`. Task 11 explains why that stack is the smallest change.
- **The infra role deploys them**, through `environment.yml`. Its grant on the two boundary ARNs follows the registry handlers (D3.2, A.2 `FunctionBoundaries`). The deploy roles hold no managed-policy write action.
- **Sizes.** The role inline policies are computed in Task 1 Step 2 and the boundaries in Task 11 Step 5.

---

## File structure

| File | Change | Responsibility |
|---|---|---|
| `activity-oidc/template.yaml` | Create | Five roles with inline policies, outputs (role names only) |
| `activity-environment/template.yaml` | Modify: new resource after `DLQAlarm` (101–120), before `Outputs` (122) | `FunctionBoundary`, the stage's `activity-app-<stage>-function-boundary` |
| `activity-environment/samconfig.toml` | Modify `:7` | `CAPABILITY_NAMED_IAM`, for a self-hoster's local deploy |
| `.github/workflows/oidc-roles.yml` | Create | Dispatch-only, `environment: oidc-bootstrap`: deploy `FederatedActivityPublisher-oidc` with quiet output |
| `scripts/oidc/` | Create | The two workflows' steps, one script per step, with shared helpers in `lib.sh` (B10) |
| `.github/workflows/oidc-trust-check.yml` | Create | Dispatch-only: per-role positive and negative assumes, scope checks, boundary checks; an `inventory` job for role trust, boundaries and distribution IDs. It deliberately spans every environment in one run, because a cross-environment refusal check cannot work otherwise. |
| `activity-app/functions/template.yaml` | Modify `Globals.Function` (75–107) | `PermissionsBoundary` |
| `.github/actions/setup-sam-portable/action.yml` | Modify `:59` | Pin `aws-actions/setup-sam` by SHA |
| `.github/workflows/deploy-stage.yml` | Modify | `--s3-prefix`, `--force-upload`, SHA pins, distribution guard; later the stage role, job outputs, and an `integration-tests` job without AWS |
| `.github/workflows/deploy-prod.yml` | Modify | Same, for prod |
| `.github/workflows/run-integration-tests.yml` | Modify `3–12`, later `14–37` | A `workflow_call` trigger (Task 11); later `environment: integration` and the integration role (Task 6) |
| `.github/workflows/environment.yml` | Modify `4–5`, `19–33`, `43`; new job | `environment: infrastructure`; infra role; `CAPABILITY_NAMED_IAM`; a stage gate for `prod`; the `function-boundary` concurrency group; job `integration-tests` calling `run-integration-tests.yml` for `stage` (Task 11) |
| `.github/workflows/bootstrap.yml` | Modify `3–4`, `22–36` | `environment: infrastructure`; infra role; domain-change guard |
| `README.md`, `DeployYourOwn.md`, `BuildingAndDeploying.md`, `AWSPermissions.md` | Modify | The OIDC setup for this repository and for forks; where the boundary lives and what detects a permission outside it |

---

## Execution order

Task numbers group the work by subject. The real dependency order differs:

1. **Task 1.** Merge the role template and the two dispatch workflows.
2. **Task 2 Steps 1–3.** Environments, secrets and the tag ruleset.
3. **Task 4.** Pins, prefixes and the distribution guard. `oidc-roles.yml` uses `setup-sam-portable`, whose fallback this task pins.
4. **Task 2 Steps 4–6.** The first role-stack deploy, which needs the Q12 credential, then the trust checks.
5. **Task 11.** `environment.yml` on the infra role, which deploys both boundary policies. **It must precede Task 3**, because the function roles cannot take a boundary that does not exist yet.
6. **Task 3.** The function-role boundary. It needs both boundary policies from Task 11.
7. **Task 5.** The full trust check, once Task 3 has deployed to stage.
8. **Task 6.** Integration tests on OIDC.
9. **Task 7.** `deploy-stage` on OIDC. It needs Tasks 3 and 4 deployed to stage.
10. **Task 8.** Prod and bootstrap on OIDC. It needs a release carrying Tasks 3 and 4.
11. **Task 9.** Docs.
12. **Task 10.** Delete the static secrets.

### Task 1: Role template and the two dispatch workflows

**Files:**
- Create: `activity-oidc/template.yaml`, `.github/workflows/oidc-roles.yml` and `.github/workflows/oidc-trust-check.yml`

**Interfaces:**
- Produces:
  - stack `FederatedActivityPublisher-oidc`, with outputs `StageDeployRoleName`, `ProdDeployRoleName`, `InfraRoleName`, `IntegrationReadRoleName` and `TrustCheckRoleName`;
  - the role ARN form `arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/<role name>`.
- Refers to, by ARN only: the boundary policies `activity-app-<stage>-function-boundary`, which Task 11 creates. The role stack does not define them.

- [ ] **Step 1: Write `activity-oidc/template.yaml`**

  The template has no `Transform`.

  `Parameters`:
  - `GitHubOrg` (default `happitec-inc`) and `GitHubRepo` (default `FederatedActivityPublisher`);
  - `GitHubOrgId` (default `"174214171"`) and `GitHubRepoId` (default `"1193951865"`), both with `AllowedPattern: "^[0-9]+$"`;
  - `BootstrapStackName` (default `activity-bootstrap`);
  - `StageDistributionId` and `ProdDistributionId` (default `""`);
  - `AllowDistributionCreate`, with `AllowedValues: ["false", "true"]` and default `"false"`.

  `Conditions`: `DistributionCreate`, which is `AllowDistributionCreate` = `true`.

  `Rules`: an empty distribution variable fails the deploy instead of granting every distribution.

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
  - **Five `AWS::IAM::Role` resources**, and no other resource type:
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
  3. **Policy size.** For each of the five roles, minify the inline policy with every `!Sub` and import replaced by a real-length placeholder:
     - a 12-digit account ID;
     - a 21-character zone ID;
     - a 14-character distribution ID;
     - a UUID certificate ID;
     - a 30-character domain.

     Expected: each role under 10,240 characters. Record the measured numbers in the PR body.

     Computed from Appendix A on 2026-10-27, with these placeholders, region `us-east-1`, `Sid`s included, and the distribution scoped by ID:

     | Role | Characters |
     |---|---|
     | `...-deploy-stage` | 7,234 |
     | `...-deploy-prod` | 7,213 |
     | `...-infra` | 5,704 (5,309 before `FunctionBoundaries`) |
     | `...-integration-read` | 636 |
     | `...-trust-check` | 797 |

     The committed template is the receipt; these figures predict it. The boundaries are measured in Task 11.

- [ ] **Step 3: Write `.github/workflows/oidc-roles.yml`**

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
     sam deploy --template-file activity-oidc/template.yaml --stack-name <repo>-oidc --capabilities CAPABILITY_NAMED_IAM --no-confirm-changeset --no-fail-on-empty-changeset --region <region> --parameter-overrides GitHubOrg=<owner> GitHubRepo=<repo> GitHubOrgId=<owner id> GitHubRepoId=<repo id> StageDistributionId=${{ vars.ACTIVITY_DISTRIBUTION_ID_STAGE }} ProdDistributionId=${{ vars.ACTIVITY_DISTRIBUTION_ID_PROD }} AllowDistributionCreate=${{ inputs.allow-distribution-create }}
     ```

     `<owner>`, `<repo>`, `<owner id>` and `<repo id>` come from the run: `github.repository_owner`, `github.event.repository.name`, `github.repository_owner_id` and `github.repository_id`, so a fork's dispatch creates roles that trust the fork. Each value is passed quoted (`Key="value"`): SAM CLI 1.166.2's override parser drops an unquoted empty `Key=`. The workflows derive the stack name and every role name from the repository name too.

     Redirect its output to `$RUNNER_TEMP/deploy.log`. Print `role stack: ok` or `role stack: failed (see the stack events in the CloudFormation console)`.
  5. **Outputs.** On success only, append `describe-stacks --stack-name FederatedActivityPublisher-oidc --query "Stacks[0].Outputs"` to `$GITHUB_STEP_SUMMARY`. These are role names.

  No step uploads `$RUNNER_TEMP`.

- [ ] **Step 4: Write `.github/workflows/oidc-trust-check.yml`**

  Trigger: `workflow_dispatch`, with a choice input `expect-boundary`: `none` (default), `stage` or `all`. Workflow `permissions: {contents: read, id-token: write}`. Workflow `concurrency: {group: function-boundary, cancel-in-progress: false}`, shared with `environment.yml` (Task 11 Step 3), so the boundary-policy positive control never runs while a boundary deploy does. One job per subject.

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
  | `stage` | `stage` | prod, infra, integration-read, trust-check | deploy-stage | `describe-stacks activity-app-prod`; `ssm get-parameter /activity/prod/keys/client-token`; `iam list-roles`; boundary checks; boundary-policy denials |
  | `production` | `production` | stage, infra, integration-read, trust-check | deploy-prod | `describe-stacks activity-app-stage`; `iam list-roles`; boundary-policy denials |
  | `infrastructure` | `infrastructure` | stage, prod, integration-read, trust-check | infra | `describe-stacks activity-app-prod`; `iam create-policy --policy-name activity-app-oidc-check-policy`; then the boundary-policy positive control |
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

    The stage boundary policy exists only after Task 11. With `expect-boundary: none`, a `NoSuchEntity` on this positive control is reported, not failed. Any other result must still be the expected one.

  **Boundary-policy denials**, in `stage` and in `production`, for each of `<B>` = `activity-app-stage-function-boundary` and `activity-app-prod-function-boundary`:
  - `iam create-policy-version --policy-arn <B> --policy-document <a deny-all document>`, without `--set-as-default`: denied.
  - `iam set-default-policy-version --policy-arn <B> --version-id v999`: denied.
  - `iam delete-policy-version --policy-arn <B> --version-id v999`: denied.
  - `iam delete-policy` on `<B>-oidc-check`, a sibling ARN that does not exist: denied.

  None of these can change the effective boundary if a denial regresses: v999 and the sibling do not exist, so a call that is authorized returns `NoSuchEntity`, which fails the check.

  The deploy roles hold no managed-policy write action, so each call is expected to return `AccessDenied` whether or not `<B>` exists yet [inferred: IAM authorizes before it looks the policy up]. If a `create-policy-version` call succeeds, the run fails and prints the new version ID. That version is not the default, so it has no effect, and the job's cleanup step tries to delete it. If the role cannot, the cleanup fails and names the version for a maintainer to remove. Every other probe that can create something (`create-role`, `create-policy`) is cleaned up the same way.

  **Boundary-policy positive control**, in `infrastructure`, for each `<B>`:
  1. `iam get-policy` reads `DefaultVersionId`, and `iam get-policy-version` reads that version's document.
  2. `iam create-policy-version` with the same document and no `--set-as-default` succeeds. The new version is not the default, so the effective boundary does not change.
  3. `iam delete-policy-version` on the new version succeeds.

  A cleanup step with `if: always()` deletes that version again. A `NoSuchEntity` there counts as success, because it means step 3 already removed the version. Any other cleanup error fails the run.

  With `expect-boundary: none`, a `NoSuchEntity` from step 1 is reported, not failed: before Task 11 the policies do not exist. With `stage` or `all`, both policies must pass all three steps. Task 11 deploys both boundaries before Task 3, so both exist by the time either value is used. A `LimitExceeded` on step 2, from a policy already at the version limit, fails the check under its own name.

  **Inventory**, in `inventory`, for each `<S>` in `stage` and `prod`:
  - **Role list.** List every role whose name begins `activity-app-<S>-`, with `iam list-roles --query "Roles[?starts_with(RoleName, 'activity-app-<S>-')].RoleName" --output text`.
    - The filter runs inside the CLI process, so only matching names leave it.
    - The raw `list-roles` output must never reach the log, the step summary or an artifact. No `--debug` on any `iam` call. No step echoes or saves the unfiltered response.
    - Only the `activity-app-<S>-*` names and their verdicts are printed.
  - **Trust.** For each listed role, fail if `AssumeRolePolicyDocument` has any statement whose principal is anything other than exactly `{"Service": "lambda.amazonaws.com"}` (Q5).
  - **Boundary.** For each listed role, `iam get-role` reports `PermissionsBoundary.PermissionsBoundaryArn`. Print only whether it ends `activity-app-<S>-function-boundary`, as `yes` or `no`.
    - With `expect-boundary: stage`, any `no` for a stage role fails the run. With `all`, any `no` for either stage fails it.
    - With `none`, the default, it is reported only. That is for Task 2 Step 5 and Task 11, before Task 3 has deployed.
    - `stage` is for the window after Task 3 reaches stage and before a release carries it to prod.
  - **Stack roles.** Find the FunctionsStack with `describe-stack-resource --logical-resource-id FunctionsStack` on `activity-app-<S>`, then `list-stack-resources`. Every `AWS::IAM::Role` it lists must appear in the role list.
  - **Managed policies.** Print the distinct `arn:aws:iam::aws:policy/...` strings in `cloudformation get-template --template-stage Processed` of the FunctionsStack.
  - **Distribution.** The `CloudFrontDistributionId` output of `activity-app-<S>` must equal `vars.ACTIVITY_DISTRIBUTION_ID_<S>`. If it does not, fail and print both values; distribution IDs are not secrets.

- [ ] **Step 5: Open the PR**

  Expected: `test` green. After merge, the push changes `.github/`, so `deploy-stage` runs its full path on the static keys. Expected: green.

- [ ] **Step 6: Commit**

  ```bash
  git add activity-oidc/template.yaml .github/workflows/oidc-roles.yml .github/workflows/oidc-trust-check.yml
  git commit -m "ci: add OIDC role stack and trust check"
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

  On `failed`, a maintainer reads the stack events in the console, then stops and decides. Do not change any grant on the strength of the log alone.

- [ ] **Step 5: Positive-path trust check from `main`**

  Run `oidc-trust-check.yml` from `main`. At this point the boundary policies do not exist yet (Task 11 creates them) and the function roles do not carry them, so the inventory's boundary column shows `no`, which is expected here.

  Expected:
  - the assume, scope, boundary-create denials, boundary-policy denials, trust and distribution checks pass;
  - the two positive controls that need a boundary policy, in `stage` and `infrastructure`, report `NoSuchEntity` [inferred: the error IAM returns for a policy that does not exist];
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
- Consumes: the managed policies `activity-app-<stage>-function-boundary`, both deployed by Task 11.

**Precondition:** Task 11 is done, so both boundary policies exist. Stage's function roles take the boundary on this PR's stage deploy and prod's on the next release, so the prod boundary must already exist too.

- [ ] **Step 1: Add the boundary**

  Under `Globals.Function`, add:

  ```yaml
  PermissionsBoundary: !Sub arn:aws:iam::${AWS::AccountId}:policy/activity-app-${Stage}-function-boundary
  ```

- [ ] **Step 2: Open the PR; after merge, observe `deploy-stage`**

  The run is on the static keys. Expected:
  - green, including the integration tests, which exercise the SSM, KMS, DynamoDB, SQS-send and S3 paths under the boundary. They do not reach the handlers D5 lists;
  - the trust check's inventory shows `yes` for every stage function role.

  Watch the stage functions' error counts in the Lambda console for one hour after the deploy. Expected: no new `AccessDenied` (U9).

- [ ] **Step 3: Prod**

  The boundary reaches prod with the next release, still on the static keys. Task 8 requires that release first.

- [ ] **Step 4: Reversibility**

  Until Task 10, reverting this PR removes the boundary, because the static keys can do so. After Task 10, the deploy roles are denied `iam:DeleteRolePermissionsBoundary` by design. Removing or replacing the boundary then needs one of two changes. Either the infra role changes the boundary document, through `environment.yml` (Task 11), or the role stack temporarily changes the deploy roles' grant, through `oidc-roles.yml`. Record this in `AWSPermissions.md` (Task 9).

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

- [ ] **Step 1: Run `oidc-trust-check.yml` from `main` with `expect-boundary: stage`**

  From here on, every trust-check run sets `expect-boundary`: `stage` until a release has carried Task 3 to prod, then `all`. A missing boundary then fails the run. Once Task 8's precondition run with `all` is green, change the input's default from `none` to `all` in the same PR as Task 8, so a dispatch that omits the input still enforces the boundary on both stages.

  Expected: green. The inventory shows `yes` for every `activity-app-stage-*` role, and no non-Lambda trust in either stage. The `stage` job's boundary checks are the negative control for the IAM conditions:
  - creating a role without the stage boundary is denied;
  - creating one with the prod boundary is denied;
  - creating one outside the prefix is denied;
  - removing a boundary is denied.

  The boundary-policy checks are the negative and positive controls for who may change a boundary:
  - in `stage` and `production`, `iam:CreatePolicyVersion`, `iam:SetDefaultPolicyVersion`, `iam:DeletePolicyVersion` and `iam:DeletePolicy` on both boundary ARNs are denied;
  - in `infrastructure`, a non-default version is created and deleted on both, and `iam create-policy` for any other name is denied.

### Task 6: `run-integration-tests.yml` on the integration role

**Files:**
- Modify: `.github/workflows/run-integration-tests.yml:18-37`

Line numbers in this task are at `origin/main`. Task 11 runs first and adds a `workflow_call` trigger under `on:`, which moves them down by the lines it adds.

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

**Precondition:** Tasks 3 and 4 are deployed to stage. The Task 5 run with `expect-boundary: stage` is green.

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

### Task 8: `deploy-prod.yml` and `bootstrap.yml`

`environment.yml` moved to the infra role in Task 11.

**Files:**
- Modify: `.github/workflows/deploy-prod.yml:9-10` and `:83-88`
- Modify: `.github/workflows/bootstrap.yml:3-4`, `:22-23` and `:31-36`

**Precondition:** a release containing Tasks 3 and 4 has deployed to prod. A trust-check run with `expect-boundary: all` is green, which means every prod function role carries the prod boundary.

- [ ] **Step 1: `deploy-prod.yml`**

  Workflow `permissions: {contents: read, id-token: write}`. The credentials step uses `...-deploy-prod`, followed by "Show assumed role".

- [ ] **Step 2: `bootstrap.yml`**

  - Workflow `permissions: {contents: read, id-token: write}`.
  - The job gains `environment: infrastructure`.
  - The credentials step uses `...-infra`, pinned as in Task 4, followed by "Show assumed role".

  `bootstrap.yml` also gains, before "SAM build", a step named "Refuse a domain change on an existing stack". It reads the `DomainName` parameter of `activity-bootstrap` with `describe-stacks` and fails if the stack exists and the value differs from `inputs.domain-name`.

- [ ] **Step 3: Check**

  `grep -rn "AWS_ACCESS_KEY_ID\|AWS_SECRET_ACCESS_KEY" .github/` prints nothing.

- [ ] **Step 4: Open the PR; after merge, validate with explicit go per run**

  1. The next published `v*` release runs `deploy-prod`. Expected: green, naming `...-deploy-prod`, with the distribution guard passing.

  Release timing is not part of this plan.

- [ ] **Step 5: Commit**

  ```bash
  git add .github/workflows/deploy-prod.yml .github/workflows/bootstrap.yml
  git commit -m "ci: prod and bootstrap stacks use OIDC roles"
  ```

### Task 9: Docs, including the self-hosted path and the function boundary

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
     - `activity-environment-stage` and `activity-environment-prod`, with `CAPABILITY_NAMED_IAM`, which also creates each stage's function boundary;
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
  - Add a section on `oidc-roles.yml` and `oidc-trust-check.yml`.
  - The `environment.yml` section says it runs on the infra role, deploys the stage's function boundary, and for `stage` runs the integration tests afterwards.

- [ ] **Step 4: `AWSPermissions.md`**

  Add a "CI roles and the function boundary" section. It states:
  - `activity-oidc/template.yaml` is the authoritative list for the CI roles. The function boundary is `FunctionBoundary` in `activity-environment/template.yaml`, one per stage, deployed by `environment.yml` on the infra role.
  - **A function permission outside the boundary deploys green and fails with `AccessDenied` when the handler runs.** Stage's post-deploy integration tests are what detect it, before a release reaches prod. They run after every `deploy-stage` run that changes the functions template, and after every `environment.yml` run for `stage`.
  - **What the tests don't reach.** Copy D5's list of handlers the stage tests don't call, and the handlers covered only in part. A gap there passes stage and shows up only as `AccessDenied` in that function's logs when traffic reaches it.
  - The boundary allows `kms:Decrypt` only through SSM (`kms:ViaService`). A function that calls KMS directly fails at runtime, and the tests catch it only on a path they exercise.
  - **To change a boundary**, edit `FunctionBoundary`, merge, and run `environment.yml` for `stage`, then for `prod`. The `prod` run refuses to deploy unless the latest `stage` run at the same commit succeeded.
  - Removing the boundary after the static keys are gone needs an infra-role or role-stack change (Task 3 Step 4).

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
  - a trust-check run dispatched with no inputs (so the default `all` applies) is green;
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

### Task 11: Function boundaries in the environment stacks, deployed by the infra role

This task runs after Task 2 Steps 4–6 and before Task 3 (see Execution order).

**Why the environment stack.** The boundaries need a stack the infra role deploys. `activity-environment-<stage>` is the smallest change:
- it already exists once per stage;
- the infra role already deploys it through an existing workflow;
- it defines the table, queue and bucket the boundary is scoped to, so the boundary can name them with `!GetAtt` instead of rebuilding the names;
- one resource definition, substituted by `Stage`, yields both boundaries, so they differ only by stage.

A new stack would add a template, a workflow and a stack name to the infra role's grant, and it would buy nothing.

**Files:**
- Modify: `activity-environment/template.yaml`: a new resource `FunctionBoundary` after `DLQAlarm` (lines 101–120) and before `Outputs` (line 122)
- Modify: `activity-environment/samconfig.toml:7`
- Modify: `.github/workflows/environment.yml:4-5`, `:19-20`, `:28-33` and `:43`, plus a new job
- Modify: `.github/workflows/run-integration-tests.yml:3-12`

**Interfaces:**
- Produces: the managed policy `activity-app-<stage>-function-boundary` in stack `activity-environment-<stage>`, with the ARN `arn:aws:iam::<A>:policy/activity-app-<stage>-function-boundary` that A.1's `<B>` names.
- Consumes: the infra role and its `FunctionBoundaries` statement (A.2), deployed in Task 2 Step 4.

- [ ] **Step 1: Add `FunctionBoundary`**

  ```yaml
  FunctionBoundary:
    Type: AWS::IAM::ManagedPolicy
    Properties:
      ManagedPolicyName: !Sub "activity-app-${Stage}-function-boundary"
      Description: !Sub "Permissions boundary for the activity-app-${Stage} function roles"
      PolicyDocument:
        Version: "2012-10-17"
        Statement: # Appendix A.5
  ```

  The statements are those in A.5. The table is `!GetAtt ActorsTable.Arn` and `!Sub "${ActorsTable.Arn}/index/*"`, the queue is `!GetAtt DeliveryQueue.Arn`, and the media objects are `!Sub "${MediaBucket.Arn}/*"`. The resource sets no `Roles`, `Groups` or `Users`, so the policy is attached to nothing; it is used only as a boundary. It sets no tags, because the registry schema marks the type not taggable (D3.2).

- [ ] **Step 2: `CAPABILITY_NAMED_IAM`**

  A managed policy with a custom name requires `CAPABILITY_NAMED_IAM` (CloudFormation API reference, `CreateStack`, `Capabilities`: "If you have IAM resources with custom names, you must specify CAPABILITY_NAMED_IAM"). Change `--capabilities CAPABILITY_IAM` to `CAPABILITY_NAMED_IAM` in `environment.yml:43`, and `capabilities` in `activity-environment/samconfig.toml:7` to match.

- [ ] **Step 3: `environment.yml` on the infra role**

  - Workflow `permissions: {contents: read, actions: read, id-token: write}` (lines 4–5). `actions: read` is for the stage gate below.
  - Workflow `concurrency: {group: function-boundary, cancel-in-progress: false}`, the same group as `oidc-trust-check.yml` (Task 1 Step 4). A trust check's version create and delete then never overlaps a boundary deploy, and a `prod` run waits for a `stage` run in progress.
  - Job `deploy` gains `environment: infrastructure`.
  - **Stage gate.** The first step of `deploy`, named "Require a green stage run at this commit", runs only when `inputs.stage == 'prod'`, with `GH_TOKEN: ${{ github.token }}`:

    ```bash
    CONCLUSION=$(gh api "repos/${{ github.repository }}/actions/workflows/environment.yml/runs?head_sha=${{ github.sha }}&event=workflow_dispatch&per_page=100" \
      --jq '[.workflow_runs[] | select(.display_title == "Deploy Environment Stack (stage)")] | sort_by(.created_at) | last | .conclusion // "none"')
    if [ "$CONCLUSION" != "success" ]; then
      echo "Refusing prod: no successful stage run of environment.yml at ${{ github.sha }} (latest: $CONCLUSION)"
      exit 1
    fi
    ```

    - `display_title` matches the workflow's `run-name` (line 2), which embeds `inputs.stage`.
    - The receipt is GitHub docs, "REST API endpoints for workflow runs", "List workflow runs for a workflow". It documents the `head_sha` and `event` query parameters, and the run object carries `display_title`, `created_at` and `conclusion`.
    - A stage run still in progress has no `success` conclusion, so it does not satisfy the gate.
    - That `gh` is on the runner image is [unverified]. The negative control in Step 6 asserts the gate's own message, so a missing `gh` cannot pass as a refusal.
  - The credentials step (lines 28–33) becomes the pinned `configure-aws-credentials` from Task 4, with `role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/FederatedActivityPublisher-github-actions-infra` and the existing `aws-region`, followed by "Show assumed role".
  - A new job runs the stage integration tests after every stage deploy, because a boundary change is a change to every stage function's permissions:

    ```yaml
    integration-tests:
      needs: deploy
      if: inputs.stage == 'stage'
      uses: ./.github/workflows/run-integration-tests.yml
      with:
        environment: stage
      secrets: inherit
    ```

    Receipts are GitHub docs, "Reusing workflows": a reusable workflow in the same repository is referenced as `./.github/workflows/<file>`, and `secrets: inherit` passes the caller's secrets. Until Task 6, the called job reads stage outputs with the static keys it inherits. After Task 6 it binds to `integration` and assumes the integration role. The caller's `id-token: write` lets it do that.

- [ ] **Step 4: Make `run-integration-tests.yml` callable**

  Under `on:` (lines 3–12), add:

  ```yaml
  workflow_call:
    inputs:
      environment:
        required: true
        type: string
  ```

  The `workflow_dispatch` input stays a `choice`. `workflow_call` inputs take only `boolean`, `number` or `string` (GitHub docs, "Workflow syntax for GitHub Actions", `on.workflow_call.inputs.<input_id>.type`). The job reads `inputs.environment` the same way under both triggers.

- [ ] **Step 5: Check the boundary size**

  Minify each stage's document with the Task 1 Step 2 placeholders. Expected: each under 6,144 characters. Computed from A.5 on 2026-10-27: 1,569 for stage and 1,562 for prod. Record the measured numbers in the PR body.

- [ ] **Step 6: Open the PR; after merge, validate with explicit go per run**

  The merge changes `.github/`, so `deploy-stage` runs its full path on the static keys. Expected: green.

  0. **Negative control for the stage gate.** Before any `stage` run at the merge commit, dispatch `environment.yml` with `prod`. Expected: "Require a green stage run at this commit" fails, and its output contains `Refusing prod: no successful stage run`. No later step runs, so no AWS credential is requested. Any other failure means the gate was not measured; stop.
  1. `environment.yml` with `stage`.
     - Expected: green. "Show assumed role" names `...-infra`.
     - The change set adds `FunctionBoundary`, creating `activity-app-stage-function-boundary`.
     - `integration-tests` runs and is green. The function roles do not carry the boundary yet, so this run checks the plumbing only.
  2. Then `environment.yml` with `prod`, at the same commit.
     - Expected: the stage gate passes, and the run is green, creating `activity-app-prod-function-boundary`.
     - `integration-tests` is skipped.

  On a failure, a maintainer reads the stack events. An `AccessDenied` there names the missing IAM action (U13). Stop and decide; do not change a grant on the strength of the log alone.

- [ ] **Step 7: Trust check**

  Run `oidc-trust-check.yml` from `main` with `expect-boundary: none`. Expected:
  - the boundary-policy denials pass in `stage` and `production`;
  - the boundary-policy positive control passes on both policies in `infrastructure`, with no `NoSuchEntity`;
  - the `stage` job's boundary-create positive control now succeeds.

- [ ] **Step 8: Commit**

  ```bash
  git add activity-environment/template.yaml activity-environment/samconfig.toml .github/workflows/environment.yml .github/workflows/run-integration-tests.yml
  git commit -m "infra: function boundaries in the environment stacks"
  ```

---

## Open questions

- **Q1: Where the roles are defined.** Options (a), (b) and (c) are compared in D1. Recommendation: (c). The credential that deploys the role stack is Q12.
- **Q2: Five roles.** Stage deploy, prod deploy, infra, integration read, and the read-only trust-check role that holds `iam:ListRoles`. The stage test job's credential is removed, not just narrowed (D2).
- **Q3: Integration tests from branches.** `run-integration-tests.yml` was last dispatched from a non-`main` branch on 2026-06-16. The `integration` environment's `main` rule ends that. Recommendation: keep `main` only.
- **Q4: `bootstrap.yml`.** Run a no-op dispatch before Task 10, which needs the existing `domain-name` and `dns-mode` values? Or accept it untested until it is next needed?
- **Q5: Function-role trust.** A deploy role can create a stage function role with an arbitrary trust (D5). The plan adds a detective control: the trust check fails on any non-Lambda principal in any `activity-app-<S>-*` role in the account. It runs on dispatch, not continuously. Is that sufficient?
- **Q6: `oidc-trust-check.yml` after cutover.** Keep it as a regression check for template changes, or delete it after Task 10? Recommendation: keep.
- **Q7: The access key behind the deleted secrets.** Rotate, deactivate or leave it? This is a separate IAM-write decision.
- **Q8: Role names.** Are the five names acceptable?
- **Q9: `v*` tag ruleset bypass list.** Who may create, move and delete release tags? Recommendation: the repository admin role only. Whoever cuts the release that carries Tasks 3 and 4 to prod, which Task 8 requires, must be on that bypass list.
- **Q10: Required reviewers.** Add required reviewers to `production`, `infrastructure` and `oidc-bootstrap`? Recommendation: yes for `oidc-bootstrap` and `infrastructure`; for `production`, it is a release-flow decision. `infrastructure` now also gates every change to the function boundaries (Task 11).
- **Q11: Split build and deploy jobs.** Splitting would mean the jobs that hold `id-token: write` run no build steps at all; artifacts would pass between jobs. With SHA pins and a token-free build container, the remaining exposure is GitHub-owned actions. Recommendation: not now.
- **Q12: The one-time role-stack credential.** How is the credential behind `OIDC_BOOTSTRAP_ROLE_ARN`, used by `oidc-roles.yml` for the role stack's first deploy, provided? This is decided outside this plan. The role stack's contents are fixed in D6.

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
| U9 | The boundary, including `kms:Decrypt` conditioned on `kms:ViaService`, keeps every function working. | Task 3 Step 2: integration tests and one hour of Lambda error counts. The tests reach only the handlers and paths D5 names as covered. |
| U10 | `--force-upload` on `sam package` with `--s3-prefix` re-uploads every artifact each time. | Task 4 Step 4 log |
| U11 | CloudFormation needs no `lambda:TagResource` on an event source mapping when the template sets no tags. | Task 7 Step 4 |
| U13 | CloudFormation calls nothing for `AWS::IAM::ManagedPolicy` beyond the registry handler permissions in A.2 `FunctionBoundaries` (D3.2). | Task 11 Step 6, on stage first |

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
| `FunctionRolesBounded` | Allow | `iam:CreateRole`, `iam:PutRolePolicy`, `iam:DeleteRolePolicy`, `iam:PutRolePermissionsBoundary`, `iam:DeleteRole`, `iam:UpdateRole`, `iam:UpdateRoleDescription` | `arn:aws:iam::<A>:role/activity-app-<S>-*` | `StringEquals` `iam:PermissionsBoundary`: `<B>` |
| `FunctionRoleManagedPolicies` | Allow | `iam:AttachRolePolicy`, `iam:DetachRolePolicy` | `arn:aws:iam::<A>:role/activity-app-<S>-*` | `StringEquals` `iam:PermissionsBoundary`: `<B>` and `ArnEquals` `iam:PolicyARN`: `arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole`, `arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole` |
| `FunctionRolesOther` | Allow | `iam:` `GetRole`, `GetRolePolicy`, `ListRolePolicies`, `ListAttachedRolePolicies`, `TagRole`, `UntagRole`, `ListRoleTags` | `arn:aws:iam::<A>:role/activity-app-<S>-*` | |
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

Per the IAM service reference, `https://servicereference.us-east-1.amazonaws.com/v1/iam/iam.json`, read 2026-10-27, `iam:DeleteRole`, `iam:UpdateRole` and `iam:UpdateRoleDescription` take the `iam:PermissionsBoundary` condition key, so they sit in `FunctionRolesBounded`. The actions left in `FunctionRolesOther` take no such key.

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
| `FunctionBoundaries` | `iam:` `CreatePolicy`, `CreatePolicyVersion`, `DeletePolicyVersion`, `DeletePolicy`, `GetPolicy`, `GetPolicyVersion`, `ListPolicyVersions`, `ListEntitiesForPolicy` | `arn:aws:iam::<A>:policy/activity-app-stage-function-boundary`, `arn:aws:iam::<A>:policy/activity-app-prod-function-boundary` |

The SNS topic and the alarm are not retained, so they keep create and delete. The table, bucket and queues get neither.

`FunctionBoundaries` is the only managed-policy write grant on any of the five roles. A.1 grants the deploy roles none of `iam:CreatePolicy`, `iam:CreatePolicyVersion`, `iam:DeletePolicyVersion`, `iam:DeletePolicy` or `iam:SetDefaultPolicyVersion`, so neither deploy role can change its stage's boundary. Their role-write actions stay conditioned on `iam:PermissionsBoundary` (`FunctionRolesBounded`, `FunctionRoleManagedPolicies`).

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
| `ListRoles` | `iam:ListRoles` | `*` |
| `ReadAppRoles` | `iam:GetRole` | `arn:aws:iam::<A>:role/activity-app-stage-*`, `arn:aws:iam::<A>:role/activity-app-prod-*` |
| `AppStacks` | `cloudformation:` `DescribeStacks`, `DescribeStackResource`, `ListStackResources`, `GetTemplate` | `stack/activity-app-stage/*`, `stack/activity-app-stage-*/*`, `stack/activity-app-prod/*`, `stack/activity-app-prod-*/*` |

`iam:ListRoles` has no resource type in the IAM service reference, `https://servicereference.us-east-1.amazonaws.com/v1/iam/iam.json`, read 2026-10-27, so it is granted on `*`. `iam:GetRole` stays scoped to the two prefixes.

### A.5 Function boundaries (`activity-app-<S>-function-boundary`, resource `FunctionBoundary` in `activity-environment-<S>`)

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
