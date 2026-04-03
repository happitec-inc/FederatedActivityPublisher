# Building and Deploying

Build Lambda binaries with Docker, deploy with SAM, and manage CI/CD pipelines.

## Overview

The project builds Swift Lambda binaries targeting Amazon Linux 2023 (ARM64). A custom Docker image handles cross-compilation, and SAM CLI manages packaging and CloudFormation deployment. Six GitHub Actions workflows automate the full lifecycle from build through testing and documentation publishing.

## GitHub Actions Workflows

### Build App (`build.yml`)

Builds all Swift Lambda handlers inside a Docker container on the `linux_large` runner, packages the template with SAM, and uploads artifacts for the deploy workflow.

**Triggers:**
- Push to `main`
- GitHub Release (non-prerelease, `v`-prefixed tag)
- Manual dispatch (`workflow_dispatch`) -- caller selects stage or prod

**Key steps:**
1. Install Swift 6.3 and Docker on the `linux_large` runner
2. Restore or build the AL2023 Docker image (cached by Dockerfile content hash)
3. Restore the SwiftPM `.build` directory (cached by `Package.resolved` hash + commit SHA)
4. Build all Lambda zip archives via `swift package archive`
5. Package with `sam package` and upload the packaged template as a GitHub Actions artifact
6. Upload frontend assets as a separate artifact

**Required secrets:**
- `AWS_ACCESS_KEY_ID` -- IAM access key (for `sam package` S3 upload)
- `AWS_SECRET_ACCESS_KEY` -- IAM secret key

### Deploy App Stack (`deploy.yml`)

Downloads the packaged template from the build workflow and deploys it via SAM on a standard `ubuntu-latest` runner. Triggers automatically when `build.yml` completes successfully, or can be triggered manually with a specific build run ID.

**Triggers:**
- `workflow_run` on "Build App" completion
- Manual dispatch -- caller selects stage and optionally a build run ID

**Key steps:**
1. Determine the stage (inferred from build workflow name or manual input)
2. Download the packaged template and frontend assets from the build run
3. Deploy with `sam deploy` (nested stacks require `CAPABILITY_AUTO_EXPAND`)
4. Upload frontend assets to the environment S3 media bucket with immutable cache headers
5. Print stack outputs to the GitHub Actions summary

**Required secrets:**
- `AWS_ACCESS_KEY_ID` -- IAM access key for deployment
- `AWS_SECRET_ACCESS_KEY` -- IAM secret key for deployment

**Required repository variables:**
- `PROXY_DISTRIBUTION_ID` -- CloudFront distribution ID for parent-domain proxy (cross-invalidation)
- `ACTIVITY_DISTRIBUTION_ID_STAGE` -- CloudFront distribution ID for the stage activity subdomain
- `ACTIVITY_DISTRIBUTION_ID_PROD` -- CloudFront distribution ID for the prod activity subdomain
- `CLIENT_API_DOMAIN_STAGE` -- Execute-api domain for the stage Client API Gateway
- `CLIENT_API_DOMAIN_PROD` -- Execute-api domain for the prod Client API Gateway

See <doc:ArchitectureOverview> for a diagram of the resources this stack creates.

### Fast Stage Deploy (`fast-stage-deploy.yml`)

An optimized pipeline for code-only changes to stage. Detects which Lambda targets changed via `git diff`, builds only those targets selectively, and updates the Lambda functions directly via the AWS API -- bypassing CloudFormation entirely.

**Triggers:**
- Push to `main` when files under `Sources/` changed
- Manual dispatch (`workflow_dispatch`)

**Key steps:**
1. Run `git diff` and pipe changed files through `scripts/detect-changed-targets.sh`
2. If infrastructure files changed (`Package.swift`, `docker/`, `activity-app/`), skip and defer to the full pipeline
3. Build only affected targets inside the Docker container using `scripts/build-selective.sh`
4. Look up physical Lambda function names from the nested functions stack
5. Update each Lambda directly with `aws lambda update-function-code`

**Timing:** ~2m 23s with warm caches. See <doc:NestedStacksOverview> for details on the selective build system.

### Integration Tests (`integration-tests.yml`)

Runs the Swift integration test suite against a deployed stack. Triggers automatically after either "Deploy App Stack" or "Fast Stage Deploy" completes.

**Triggers:**
- `workflow_run` on "Deploy App Stack" or "Fast Stage Deploy" completion
- Manual dispatch -- caller selects stage

**Key steps:**
1. Load or build the AL2023 Docker image (shared cache with build workflows)
2. Fetch stack outputs and bearer token from AWS
3. Run `swift test --filter IntegrationTests` inside the AL2023 Docker container

The tests compile inside the Docker container to avoid ICU/Swift version conflicts on the runner host.

### Deploy DocC Documentation (`deploy-docc.yml`)

Builds Swift DocC documentation with Mermaid diagram support and deploys it to GitHub Pages.

**Triggers:**
- Push to `main`
- Manual dispatch

**What it creates or modifies:**
- GitHub Pages deployment at `docs.happitec.com/FederatedActivityPublisher`
- OG images and meta tags for social sharing

**Required secrets:**
- `HAPPITEC_READ_ONLY_PAT` -- PAT for accessing the logo generator repository

**Key steps:**
1. Generate an OG image via a reusable workflow in `happitec-logo-generator`
2. Check out the `swift-docc-render` fork with Mermaid diagram support
3. Build the custom DocC renderer with Node.js
4. Run `swift package generate-documentation` targeting `ActivityPubCore`
5. Post-process OG images and meta tags
6. Deploy to GitHub Pages

**Permissions:** `contents: read`, `pages: write`, `id-token: write`

### Deploy Bootstrap Stack (`bootstrap.yml`)

One-time infrastructure setup. Creates the Route 53 hosted zone and ACM TLS certificate for `activity.happitec.com`.

**Triggers:**
- Manual dispatch only (`workflow_dispatch`)

**What it creates or modifies:**
- Route 53 hosted zone for `activity.happitec.com`
- ACM certificate with DNS validation for `activity.happitec.com` and `*.activity.happitec.com`

**Required secrets:**
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

> Important: After deploying the bootstrap stack, you must manually add NS delegation records in the parent `happitec.com` hosted zone. The stack outputs list the nameservers.

### Deploy Environment Stack (`environment.yml`)

Creates per-stage persistent resources that the app stack depends on.

**Triggers:**
- Manual dispatch only -- caller selects `stage` or `prod`

**What it creates or modifies:**
- DynamoDB table for actor data, posts, followers, and federation state
- S3 media bucket for uploaded images and frontend assets
- SQS queue for asynchronous activity delivery
- SSM Parameter Store prefix for actor signing keys

**Required secrets:**
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

## Deployment Order

Standing up a new environment from scratch requires deploying stacks in a specific order due to cross-stack references.

### 1. Bootstrap Stack (one-time)

Deploy the bootstrap stack to create the hosted zone and TLS certificate. This is a one-time operation shared across all stages.

```bash
cd activity-bootstrap
sam deploy --guided --stack-name activity-bootstrap
```

Or trigger the `bootstrap.yml` workflow manually from the GitHub Actions UI.

### 2. NS Delegation in Parent Zone

After the bootstrap stack deploys, copy the four NS record values from the stack outputs and create an NS record in the parent `happitec.com` hosted zone pointing `activity.happitec.com` to those nameservers. Without this, ACM certificate validation will not complete and CloudFront will not serve traffic.

### 3. Environment Stack (per stage)

Deploy the environment stack for each stage. Deploy `stage` first to validate, then `prod`.

```bash
cd activity-environment
sam deploy \
  --stack-name activity-environment-stage \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides Stage=stage
```

Or trigger the `environment.yml` workflow manually, selecting the desired stage.

### 4. App Stack (per stage)

Deploy the app stack, which references both the bootstrap and environment stacks. The app stack uses nested CloudFormation stacks, so `CAPABILITY_AUTO_EXPAND` is required alongside `CAPABILITY_IAM`.

```bash
cd activity-app
sam deploy \
  --stack-name activity-app-stage \
  --resolve-s3 \
  --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND \
  --parameter-overrides \
    Stage=stage \
    EnvironmentStackName=activity-environment-stage \
    BootstrapStackName=activity-bootstrap \
    ServerDomain=happitec.com \
    HandleDomain=happitec.com \
    ProxyDistributionId=YOUR_DISTRIBUTION_ID
```

After the first manual deploy, pushes to `main` automatically deploy to stage via the `build.yml` -> `deploy.yml` pipeline. See <doc:NestedStacksOverview> for details on the nested stack architecture.

### 5. Actor Provisioning

Use the `ActivityProvisioner` CLI tool to create actor accounts in DynamoDB and generate signing key pairs in SSM Parameter Store. See <doc:ProvisioningAccounts> for detailed instructions.

### 6. happitec.com CloudFront Behaviors

Configure the parent `happitec.com` CloudFront distribution to proxy ActivityPub paths to the `activity.happitec.com` CloudFront distribution. The required behaviors are:

- `/.well-known/webfinger*`
- `/.well-known/nodeinfo`
- `/nodeinfo/*`
- `/users/*`

Each behavior uses an origin pointing to `activity.happitec.com` with HTTPS-only and forwards the appropriate headers.

### 7. GitHub Repository Variables

Set these repository variables so the CI/CD workflows can reference them:

| Variable | Purpose | Example |
|---|---|---|
| `PROXY_DISTRIBUTION_ID` | CloudFront distribution ID for parent-domain proxy (cross-invalidation) | `E1234567890ABC` |
| `ACTIVITY_DISTRIBUTION_ID_STAGE` | CloudFront distribution ID for the stage activity subdomain (from first deploy output) | `E1234567890ABC` |
| `ACTIVITY_DISTRIBUTION_ID_PROD` | CloudFront distribution ID for the prod activity subdomain | `E1234567890ABC` |
| `CLIENT_API_DOMAIN_STAGE` | Execute-api domain for the stage Client API Gateway | `abc123.execute-api.us-east-1.amazonaws.com` |
| `CLIENT_API_DOMAIN_PROD` | Execute-api domain for the prod Client API Gateway | `def456.execute-api.us-east-1.amazonaws.com` |

The `ACTIVITY_DISTRIBUTION_ID_*` and `CLIENT_API_DOMAIN_*` values come from the stack outputs after the first deploy. Set them and redeploy to enable CloudFront cache invalidation from Lambda and same-origin client API routing through CloudFront.

## CI/CD Pipeline

### Stage Deployment

Every push to `main` triggers two parallel pipelines:

1. **Full pipeline** (`build.yml` -> `deploy.yml`): Builds all handlers, packages with SAM, and deploys via CloudFormation. This handles infrastructure changes (template modifications, new resources).
2. **Fast pipeline** (`fast-stage-deploy.yml`): Detects which handlers changed, builds only those, and updates Lambda functions directly. This handles code-only changes in ~2m 23s with warm caches.

Both pipelines run in parallel. The fast pipeline skips automatically if infrastructure files changed, deferring to the full pipeline.

### Production Deployment

Creating a GitHub Release with a `v`-prefixed tag (e.g., `v1.2.0`) triggers `build.yml` targeting **prod**. The release must not be marked as a prerelease. When the build completes, `deploy.yml` picks up the artifact and deploys to prod. You can also trigger a prod deploy manually via `workflow_dispatch` on either workflow.

The fast-stage-deploy pipeline is stage-only by design. Production deployments always go through the full CloudFormation pipeline.

### Integration Tests

After either deploy pipeline completes successfully, `integration-tests.yml` triggers automatically. It compiles and runs the Swift integration test suite inside the AL2023 Docker container against the deployed stack.

### Documentation Deployment

Every push to `main` also triggers the `deploy-docc.yml` workflow, which builds and deploys DocC documentation to GitHub Pages. The documentation and app deployments run in parallel.

### Build Caching

All workflows that use Docker share two layers of caching via `actions/cache`:

- **Docker image cache** -- keyed by the Dockerfile content hash. Saves ~3 minutes per run by loading a pre-built tarball instead of rebuilding the image.
- **SwiftPM `.build` directory cache** -- keyed by `Package.resolved` hash and commit SHA, with fallback to any previous `.build` directory. Enables incremental Swift builds.

See <doc:NestedStacksOverview> for detailed cache key strategies and timing comparisons.

### Frontend Assets

The `deploy.yml` workflow uploads files from the `frontend/` directory to the environment S3 media bucket on every deploy, with `Cache-Control: public, max-age=31536000, immutable` headers. This includes `latex.css` for rendering mathematical notation in posts.

### CloudFront Cache Invalidation

You do not need to manually invalidate CloudFront caches after deployment. The `PostHandler` and `ProfileUpdateHandler` Lambdas automatically issue CloudFront invalidations when content changes, targeting both the `activity.happitec.com` distribution and the parent `happitec.com` distribution.

## Runner Configuration

The build-intensive workflows (`build.yml`, `fast-stage-deploy.yml`, `integration-tests.yml`) run on the `linux_large` runner, which provides the disk space and memory needed for Docker builds and Swift compilation. The lightweight deploy workflow (`deploy.yml`) runs on `ubuntu-latest`.

### Configuration Variables

| Variable | Purpose | Default (if unset) |
|---|---|---|
| `RUNNER_LABELS_MACOS` | Runner labels for macOS jobs (DocC builds) | `macos-26` |

The `linux_large` runner label is hardcoded in the build, fast-deploy, and integration-test workflows. The deploy workflow uses `ubuntu-latest` directly.

## Building the Docker Image

The repository includes a Dockerfile at `docker/Dockerfile.al2023-swift` for the Lambda build environment:

```bash
docker build -t activity-builder -f docker/Dockerfile.al2023-swift .
```

This image is based on Amazon Linux 2023 with Swift 6.3 and all required build dependencies (OpenSSL, libxml2, libcurl, SQLite). It supports both x86_64 and ARM64 architectures.

## Building Lambda Binaries Locally

Use the Swift Package Manager's Lambda archiver plugin to build all Lambda handlers:

```bash
swift package --allow-network-connections docker archive \
  --base-docker-image swift-al2023:6.3 \
  --disable-docker-image-update
```

This produces zip archives under `.build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager/` for each executable target.

## Topics

### Related Articles

- <doc:NestedStacksOverview>
- <doc:ArchitectureOverview>
- <doc:AWSPermissions>
- <doc:CostEstimates>
- <doc:ProvisioningAccounts>
