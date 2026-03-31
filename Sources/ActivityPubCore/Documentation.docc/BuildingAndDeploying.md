# Building and Deploying

Build Lambda binaries with Docker, deploy with SAM, and manage CI/CD pipelines.

## Overview

The project builds Swift Lambda binaries targeting Amazon Linux 2023 (ARM64). A custom Docker image handles cross-compilation, and SAM CLI manages packaging and CloudFormation deployment. Four GitHub Actions workflows automate the full lifecycle from deployment through documentation publishing.

## GitHub Actions Workflows

### Deploy App Stack (`app.yml`)

The primary deployment workflow. Builds all Swift Lambda handlers inside a Docker container, deploys the app CloudFormation stack via SAM, and uploads frontend assets to S3.

**Triggers:**
- Push to `main` -- deploys to **stage**
- GitHub Release (non-prerelease, `v`-prefixed tag) -- deploys to **prod**
- Manual dispatch (`workflow_dispatch`) -- caller selects stage or prod

**What it creates or modifies:**
- All Lambda functions (PostHandler, InboxHandler, ActorHandler, WebFingerHandler, etc.)
- API Gateway (federation API and client API)
- CloudFront distribution with cache behaviors
- Route 53 DNS record for `activity.happitec.com` or `stage.activity.happitec.com`
- CloudFront cache policies and origin request policies
- S3 bucket policy for media OAC access
- Frontend assets (`latex.css`) uploaded to the environment S3 media bucket

**Required secrets:**
- `AWS_ACCESS_KEY_ID` -- IAM access key for deployment
- `AWS_SECRET_ACCESS_KEY` -- IAM secret key for deployment

**Required repository variables:**
- `HAPPITEC_DISTRIBUTION_ID` -- CloudFront distribution ID for the parent `happitec.com` site (used for cross-invalidation)

**Key steps:**
1. Clean workspace (self-hosted runners only)
2. Install Swift 6.3 on the runner if not already present
3. Build or reuse a cached Docker image from `docker/Dockerfile.al2023-swift` (keyed by Dockerfile SHA-256 hash)
4. Build Lambda zip archives via `swift package archive`
5. Deploy with `sam deploy`
6. Upload frontend assets to S3 with immutable cache headers
7. Print stack outputs to the GitHub Actions summary

See <doc:ArchitectureOverview> for a diagram of the resources this stack creates.

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

Deploy the app stack, which references both the bootstrap and environment stacks.

```bash
cd activity-app
sam deploy \
  --stack-name activity-app-stage \
  --resolve-s3 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    Stage=stage \
    EnvironmentStackName=activity-environment-stage \
    BootstrapStackName=activity-bootstrap \
    ServerDomain=happitec.com \
    HandleDomain=happitec.com \
    HappitecDistributionId=YOUR_DISTRIBUTION_ID
```

After the first manual deploy, pushes to `main` automatically deploy to stage via the `app.yml` workflow.

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
| `HAPPITEC_DISTRIBUTION_ID` | CloudFront distribution ID for `happitec.com` (cross-invalidation) | `E1234567890ABC` |

The `ACTIVITY_API_DOMAIN` and `ACTIVITY_CDN_DOMAIN` values are derived from stack outputs automatically.

## CI/CD Pipeline

### Stage Deployment

Every push to `main` triggers the `app.yml` workflow targeting **stage**. The workflow builds all Lambda handlers, deploys to CloudFormation, uploads frontend assets, and prints stack outputs.

### Production Deployment

Creating a GitHub Release with a `v`-prefixed tag (e.g., `v1.2.0`) triggers the `app.yml` workflow targeting **prod**. The release must not be marked as a prerelease. You can also trigger a prod deploy manually via `workflow_dispatch`.

### Documentation Deployment

Every push to `main` also triggers the `deploy-docc.yml` workflow, which builds and deploys DocC documentation to GitHub Pages. The documentation and app deployments run in parallel.

### Docker Image Caching

The `app.yml` workflow caches the Docker build image by tagging it with the first 12 characters of the Dockerfile's SHA-256 hash. If the Dockerfile has not changed since the last build, the cached image is reused. On GitHub-hosted runners there is no persistent Docker cache, so the image is always rebuilt. On self-hosted runners, the cache persists across workflow runs.

### Frontend Assets

The `app.yml` workflow uploads files from the `frontend/` directory to the environment S3 media bucket on every deploy, with `Cache-Control: public, max-age=31536000, immutable` headers. This includes `latex.css` for rendering mathematical notation in posts.

### CloudFront Cache Invalidation

You do not need to manually invalidate CloudFront caches after deployment. The `PostHandler` and `ProfileUpdateHandler` Lambdas automatically issue CloudFront invalidations when content changes, targeting both the `activity.happitec.com` distribution and the parent `happitec.com` distribution.

## Runner Configuration

All deployment workflows support both self-hosted and GitHub-hosted runners via repository variables. This lets you migrate between runner types without modifying workflow files.

### Configuration Variables

| Variable | Purpose | Default (if unset) |
|---|---|---|
| `RUNNER_LABELS_LINUX` | Runner labels for Linux jobs | `ubuntu-latest` |
| `RUNNER_LABELS_MACOS` | Runner labels for macOS jobs | `macos-15` |

To use self-hosted runners, set these variables in the repository settings under **Settings > Variables > Actions**:

- `RUNNER_LABELS_LINUX` = `["self-hosted", "linux"]`
- `RUNNER_LABELS_MACOS` = `["self-hosted", "macOS"]`

To use GitHub-hosted runners, remove or leave these variables unset. The workflows fall back to `ubuntu-latest` for Linux and `macos-15` for macOS.

### Self-Hosted Runner Considerations

When using self-hosted runners, the workflows include additional cleanup steps:
- Workspace cleaning (`rm -rf .build/`, `git clean -fdx`) to avoid stale build artifacts
- Docker container and builder pruning
- Persistent Docker image cache (avoids rebuilding the Swift AL2023 image on every run)

These cleanup steps are automatically skipped on GitHub-hosted runners, which start with a clean environment.

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

- <doc:ArchitectureOverview>
- <doc:AWSPermissions>
- <doc:CostEstimates>
- <doc:ProvisioningAccounts>
