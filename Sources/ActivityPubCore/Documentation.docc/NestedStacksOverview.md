# Nested Stacks and Fast Deploys

The nested stack architecture, selective build system, and fast-stage-deploy pipeline.

## Overview

The app stack (`activity-app-{stage}`) uses a nested CloudFormation architecture: a root orchestrator template delegates to two child stacks that manage resources with different change frequencies. This separation enables a fast-deploy pipeline that updates only the Lambda functions that changed, bypassing full CloudFormation deployments for code-only changes.

## Why Nested Stacks

A flat SAM template containing all Lambda functions, API Gateways, CloudFront, cache policies, and DNS records in a single template has two problems:

1. **Blast radius.** Every deploy touches every resource, even when only one Lambda's code changed. A CloudFormation update that modifies CloudFront or API Gateway takes 10-20 minutes.
2. **Circular dependencies.** Lambda functions need the CloudFront distribution ID for cache invalidation, but CloudFront needs the API Gateway ID that is created alongside the Lambdas. In a flat template this creates a dependency cycle.

Splitting into nested stacks solves both: the functions stack and CDN stack deploy as independent CloudFormation resources, and the circular dependency is broken by passing the CloudFront distribution ID as an external parameter (`ActivityDistributionId`) from a repository variable.

## Two-Stack Layout

### Root Orchestrator (`activity-app/template.yaml`)

The root template accepts all parameters and creates two nested stacks. It passes outputs from the functions stack (API Gateway IDs) into the CDN stack, and passes the external `ActivityDistributionId` parameter into the functions stack.

### Functions Stack (`activity-app/functions/template.yaml`)

Contains all compute and API resources:

- All Lambda functions (18 handlers)
- Server API Gateway (federation endpoints)
- Client API Gateway (authenticated posting/media/profile endpoints)
- IAM roles and policies
- SQS event source mappings

### CDN Stack (`activity-app/cdn/template.yaml`)

Contains all edge and DNS resources:

- CloudFront distribution with OAC for S3
- Cache policies and origin request policies
- Cache behaviors (federation API, client API, media)
- Route 53 DNS record for `activity.happitec.com` or `stage.activity.happitec.com`

### Parameter Flow

```
Root template
  |
  |-- Parameters: Stage, ServerDomain, HandleDomain, ProxyDistributionId,
  |               ActivityDistributionId, ClientApiDomain, ...
  |
  +-- FunctionsStack
  |     Receives: all parameters + CloudFrontDistributionId
  |     Outputs:  ServerlessRestApiId, ClientApiId, ApiEndpoint, ...
  |
  +-- CdnStack
        Receives: Stage, ServerlessRestApiId (from FunctionsStack),
                  ClientApiId (from FunctionsStack), ClientApiDomain, ...
        Outputs:  CloudFrontDistributionId, CloudFrontDomainName
```

### Circular Dependency Resolution

Lambda functions that invalidate CloudFront caches (PostHandler, ProfileUpdateHandler) need the distribution ID. But the distribution is created in the CDN stack, which depends on API Gateway IDs from the functions stack. This creates a cycle:

> Functions stack -> needs CloudFront ID -> CDN stack -> needs API Gateway ID -> Functions stack

The solution: the CloudFront distribution ID is passed as a repository variable (`ACTIVITY_DISTRIBUTION_ID_STAGE` / `ACTIVITY_DISTRIBUTION_ID_PROD`) rather than referenced via `!GetAtt`. On first deploy, the variable is empty and cache invalidation is skipped. After the first deploy creates the distribution, you set the variable and redeploy. From that point forward, Lambdas can invalidate the cache.

## Selective Build System

### Detecting Changed Targets

The `scripts/detect-changed-targets.sh` script reads a list of changed file paths from stdin (produced by `git diff --name-only`) and determines which Swift targets need rebuilding.

The script applies these rules:
- **`Package.swift`, `Package.resolved`, or `Dockerfile` changed:** output `all` (full rebuild required)
- **`Sources/ActivityPubCore/` changed:** output all handler targets that depend on the shared library (16 of 18 handlers)
- **`Sources/{HandlerName}/` changed:** output just that handler
- **`Sources/ActivityProvisioner/` or `Sources/APIClient/` changed:** ignored (not Lambda targets)
- **No source files changed:** output `none`

### Building Selectively

The `scripts/build-selective.sh` script runs inside the AL2023 Docker container. It accepts a list of target names, builds each with `swift build -c release --product {target} --static-swift-stdlib`, and packages the binary as a zip file in the layout expected by SAM:

```
.build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager/{Target}/{Target}.zip
```

Each zip contains a single `bootstrap` binary (the AWS Lambda custom runtime convention).

## CI/CD Pipelines

### Full Pipeline: build.yml + deploy.yml

The full pipeline runs on every push to `main` and for production releases. It consists of two workflows chained by `workflow_run`:

1. **build.yml** runs on `linux_large`. It builds all Lambda handlers inside the Docker container, packages the template with `sam package`, and uploads the packaged template and frontend assets as GitHub Actions artifacts.
2. **deploy.yml** triggers when `build.yml` completes successfully. It runs on `ubuntu-latest`, downloads the artifacts, deploys with `sam deploy`, uploads frontend assets to S3, and prints stack outputs.

This two-step design means the heavy build (requiring Docker + Swift + large disk) runs on the `linux_large` runner, while the lightweight deploy (just SAM CLI + AWS CLI) runs on a standard GitHub-hosted runner.

**Timing:** ~7 minutes with warm caches, 20+ minutes on cold cache (Docker image rebuild + full SwiftPM resolution).

### Fast Stage Deploy: fast-stage-deploy.yml

The fast-stage-deploy pipeline is an alternative path for code-only changes to stage. It runs the entire process -- detect, build, and deploy -- in a single job on `linux_large`.

**Triggers:**
- Push to `main` when files under `Sources/` changed
- Manual dispatch (`workflow_dispatch`)

**Steps:**
1. `git diff` the changed files between the push's before/after commits
2. If infrastructure files changed (`Package.swift`, `docker/`, `activity-app/`), skip and let the full pipeline handle it
3. Run `detect-changed-targets.sh` to identify affected Lambda targets
4. Build only those targets inside the Docker container using `build-selective.sh`
5. Look up the physical Lambda function names from the nested functions stack via `aws cloudformation list-stack-resources`
6. Update each changed Lambda directly with `aws lambda update-function-code`

**Timing:** ~2m 23s with warm caches (Docker image + SwiftPM `.build` directory cached). No CloudFormation deployment is involved -- the Lambda code is updated directly via the AWS API.

### Integration Tests: integration-tests.yml

Integration tests run automatically after both deploy pipelines complete. The workflow triggers on `workflow_run` completion of either "Deploy App Stack" or "Fast Stage Deploy".

**Steps:**
1. Determine the stage from the triggering workflow's run name
2. Load or build the AL2023 Docker image (shared cache with build workflows)
3. Fetch stack outputs (API URL, Client API URL) from CloudFormation
4. Retrieve the bearer token from SSM Parameter Store
5. Run `swift test --filter IntegrationTests` inside the Docker container, passing environment variables for the test URLs and credentials

The tests compile and run inside the same AL2023 Docker container used for Lambda builds. This avoids ICU/Swift version conflicts that occur when compiling natively on the runner.

## Build Caching Strategy

Two layers of caching keep build times low:

### Docker Image Cache

The AL2023 Swift Docker image is cached using `actions/cache` with a key derived from the Dockerfile's content hash:

```
key: docker-al2023-swift-${{ hashFiles('docker/Dockerfile.al2023-swift') }}
path: /tmp/docker-image.tar
```

When the Dockerfile has not changed, the cached tarball is loaded with `docker load` instead of rebuilding. This saves ~3 minutes per run.

### SwiftPM Build Directory Cache

The `.build` directory is cached with a composite key:

```
key: swift-build-${{ hashFiles('**/Package.resolved') }}-${{ github.sha }}
restore-keys:
  swift-build-${{ hashFiles('**/Package.resolved') }}-
  swift-build-
```

This means a build reuses the most recent `.build` directory with the same dependency versions, falling back to any previous `.build` directory. Incremental Swift builds with a warm cache complete in under a minute for single-target changes.

### Cache Sharing

All three pipelines (build, fast-stage-deploy, integration-tests) use the same cache keys for the Docker image. This means whichever pipeline runs first populates the cache, and subsequent pipelines reuse it.

## Timing Comparison

| Scenario | Time |
|---|---|
| Full pipeline, warm cache (build + deploy) | ~7 min |
| Full pipeline, cold cache (Docker rebuild + full SwiftPM) | 20+ min |
| Fast stage deploy, warm cache (single target) | ~2m 23s |
| Fast stage deploy, cold cache | ~7 min |
| Integration tests | ~3-5 min |

## Topics

### Related Articles

- <doc:BuildingAndDeploying>
- <doc:ArchitectureOverview>
