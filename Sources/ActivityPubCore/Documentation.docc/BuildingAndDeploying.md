# Building and Deploying

Build Lambda binaries with Docker, deploy with SAM, and manage CI/CD pipelines.

## Overview

The project builds Swift Lambda binaries targeting Amazon Linux 2023 (ARM64). A custom Docker image handles cross-compilation, and SAM CLI manages packaging and CloudFormation deployment. Seven GitHub Actions workflows automate the full lifecycle from deployment through documentation publishing. Actor provisioning and token minting are deliberately not among them — they run locally via the `ActivityProvisioner` CLI (see <doc:ProvisioningAccounts>).

## GitHub Actions Workflows

### Deploy Stage (`deploy-stage.yml`)

The primary stage deployment workflow with a forking path: a **detect** job analyzes which files changed and routes to either a fast or full pipeline.

**Fast path** (~2.5 min with cache): When only individual Lambda handler source files changed (not `ActivityPubCore`, `Package.swift`, templates, or workflows), the workflow builds only the affected targets, bundles OpenSSL libraries, and updates each Lambda function directly via `aws lambda update-function-code`. No SAM deploy, no CloudFormation changeset.

**Full path** (~5-10 min): When core dependencies, templates, workflows, or the Dockerfile changed, the workflow builds all Lambda handlers via `swift package archive`, bundles OpenSSL, and deploys via SAM with nested stacks (`CAPABILITY_AUTO_EXPAND`).

After either path completes, integration tests run automatically in a Docker container against the deployed stage stack.

**Triggers:**
- Push to `main` -- deploys to **stage** (auto-detects fast vs full)
- Manual dispatch (`workflow_dispatch`) -- always takes the full path

**Required secrets:**
- `AWS_ACCESS_KEY_ID` -- IAM access key for deployment
- `AWS_SECRET_ACCESS_KEY` -- IAM secret key for deployment

**Key steps (full path):**
1. Clean workspace (self-hosted runners only)
2. Run `scripts/substitute-variables.sh` to replace domain placeholders in templates
3. Install Swift 6.3 on the runner if not already present
4. Build or reuse a cached Docker image from `docker/Dockerfile.al2023-swift`
5. Build Lambda zip archives via `swift package archive`
6. Bundle OpenSSL libraries (`libcrypto.so.3`, `libssl.so.3`) into each Lambda zip
7. Deploy with `sam deploy` using `CAPABILITY_IAM CAPABILITY_AUTO_EXPAND`
8. Upload frontend assets to S3 with immutable cache headers
9. Run integration tests in Docker against the deployed stack

See <doc:ArchitectureOverview> for a diagram of the resources this stack creates.

### Deploy Prod (`deploy-prod.yml`)

Production deployment workflow. Always takes the full build-and-deploy path (no fast path).

**Triggers:**
- GitHub Release (non-prerelease, `v`-prefixed tag) -- deploys to **prod**
- Manual dispatch (`workflow_dispatch`)

The build steps are identical to the full path in `deploy-stage.yml`. Deploys to the `production` GitHub deployment environment.

**Required secrets:**
- `AWS_ACCESS_KEY_ID` -- IAM access key for deployment
- `AWS_SECRET_ACCESS_KEY` -- IAM secret key for deployment

### Deploy DocC Documentation (`deploy-docc.yml`)

Builds Swift DocC documentation with Mermaid diagram support and deploys it to GitHub Pages.

**Triggers:**
- Push to `main`
- Manual dispatch

**What it creates or modifies:**
- GitHub Pages deployment at `your-org.github.io/FederatedActivityPublisher`
- OG images and meta tags for social sharing

**Required secrets:**
- `HAPPITEC_READ_ONLY_PAT` -- PAT for accessing the logo generator repository

**Key steps:**
1. Generate an OG image via a reusable workflow (requires `ENABLE_DOCC_DEPLOY` variable)
2. Check out the `swift-docc-render` fork with Mermaid diagram support
3. Build the custom DocC renderer with Node.js
4. Run `swift package generate-documentation` targeting `ActivityPubCore`
5. Post-process OG images and meta tags
6. Deploy to GitHub Pages

**Permissions:** `contents: read`, `pages: write`, `id-token: write`

### Deploy Bootstrap Stack (`bootstrap.yml`)

One-time infrastructure setup. Creates the Route 53 hosted zone and ACM TLS certificate for your server domain.

**Triggers:**
- Manual dispatch only (`workflow_dispatch`)

**What it creates or modifies:**
- Route 53 hosted zone for your server domain
- ACM certificate with DNS validation for your server domain and wildcard subdomain

**Required secrets:**
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

> Important: After deploying the bootstrap stack, you must set your domain's nameservers (simple mode) or add NS delegation records in the parent zone (split mode). The stack outputs list the nameservers.

### Deploy Environment Stack (`environment.yml`)

Creates per-stage persistent resources that the app stack depends on.

**Triggers:**
- Manual dispatch only -- caller selects `stage` or `prod`

**What it creates or modifies:**
- DynamoDB table for actor data, posts, followers, bearer tokens, and federation state
- S3 media bucket for uploaded images and frontend assets
- SQS queue for asynchronous activity delivery
- SSM Parameter Store prefix for actor signing keys

**Required secrets:**
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

### Unit Tests (`test.yml`)

Runs the `ActivityPubCoreTests` unit test suite on every pull request.

**Triggers:**
- Pull request targeting `main`
- Manual dispatch

### Run Integration Tests (`run-integration-tests.yml`)

Runs integration tests in a Docker container against a deployed stack. Tests are in the separate `integration-tests/` Swift package.

**Triggers:**
- Manual dispatch -- caller selects the target environment (stage or prod)

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

After the bootstrap stack deploys, copy the four NS record values from the stack outputs and configure DNS accordingly. In simple mode, set these as your registrar's nameservers. In split mode, add NS records in the parent zone. Without this, ACM certificate validation will not complete and CloudFront will not serve traffic.

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

Deploy the app stack, which references both the bootstrap and environment stacks. The app template uses nested stacks, so `CAPABILITY_AUTO_EXPAND` is required.

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
    ServerDomain={{SERVER_DOMAIN}} \
    HandleDomain={{HANDLE_DOMAIN}} \
    ProxyDistributionId=YOUR_DISTRIBUTION_ID
```

After the first manual deploy, pushes to `main` automatically deploy to stage via the `deploy-stage.yml` workflow.

### 5. Actor Provisioning

Use the `ActivityProvisioner` CLI tool to create actor accounts in DynamoDB and generate signing key pairs in SSM Parameter Store. See <doc:ProvisioningAccounts> for detailed instructions.

### 6. Parent Domain CloudFront Behaviors (split mode only)

In split DNS mode, configure the handle domain's CloudFront distribution to proxy ActivityPub paths to the server domain's CloudFront distribution. The required behaviors are:

- `/.well-known/webfinger*`
- `/.well-known/nodeinfo`
- `/nodeinfo/*`
- `/users/*`

Each behavior uses an origin pointing to the server domain with HTTPS-only and forwards the appropriate headers.

### 7. GitHub Repository Variables

Set these repository variables so the CI/CD workflows can reference them:

| Variable | Purpose | Example |
|---|---|---|
| `SERVER_DOMAIN` | Your ActivityPub server domain | `example.com` |
| `HANDLE_DOMAIN` | Your handle domain (same as server in simple mode) | `example.com` |
| `PROXY_DISTRIBUTION_ID` | CloudFront distribution ID for parent-domain proxy (split mode only) | `E1234567890ABC` |
| `ACTIVITY_DISTRIBUTION_ID_STAGE` | CloudFront distribution ID for the stage activity server | `E9876543210XYZ` |
| `ACTIVITY_DISTRIBUTION_ID_PROD` | CloudFront distribution ID for the prod activity server | `EABCDEF1234567` |
| `CLIENT_API_DOMAIN_STAGE` | Execute-api domain for stage Client API Gateway (enables same-origin routing) | `abc123.execute-api.us-east-1.amazonaws.com` |
| `CLIENT_API_DOMAIN_PROD` | Execute-api domain for prod Client API Gateway | `def456.execute-api.us-east-1.amazonaws.com` |
| `AWS_REGION` | AWS region for all deployments (default: `us-east-1`) | `us-east-1` |
| `RUNNER_LABELS_LINUX` | Runner labels for Linux jobs (default: `ubuntu-latest`) | `["self-hosted", "linux"]` |
| `RUNNER_LABELS_MACOS` | Runner labels for macOS jobs (default: `macos-26`) | `["self-hosted", "macOS"]` |

## CI/CD Pipeline

### Stage Deployment

Every push to `main` triggers the `deploy-stage.yml` workflow. A detect job analyzes the changed files and picks the appropriate path:

- **Fast path**: Only specific Lambda handlers changed. Builds those targets selectively, bundles OpenSSL, and updates the Lambda functions directly via API. Takes ~2.5 minutes with a warm cache.
- **Full path**: Core library, templates, Package.swift, Dockerfile, or workflows changed. Builds all handlers, bundles OpenSSL, and deploys the full nested stack via SAM. Takes ~5-10 minutes.
- **Skip**: No deployable changes (e.g., docs-only PRs).

After either deployment path succeeds, integration tests run automatically against the deployed stage stack in a Docker container.

GitHub deployment environments are tracked: the stage environment URL is `https://stage.{{SERVER_DOMAIN}}`.

### Production Deployment

Creating a GitHub Release with a `v`-prefixed tag (e.g., `v1.2.0`) triggers the `deploy-prod.yml` workflow. The release must not be marked as a prerelease. You can also trigger a prod deploy manually via `workflow_dispatch`. Production always takes the full build path.

The production environment URL is `https://{{SERVER_DOMAIN}}`.

### Documentation Deployment

Every push to `main` also triggers the `deploy-docc.yml` workflow, which builds and deploys DocC documentation to GitHub Pages. The documentation and app deployments run in parallel.

### Docker Image Caching

Both deployment workflows cache the Docker build image using GitHub Actions `actions/cache`. The image is saved to `/tmp/docker-image.tar` and keyed by the Dockerfile's content hash. On cache hit, the image is loaded directly; on miss, it is built and saved for next time.

### Swift Build Caching

The `.build` directory is cached across workflow runs, keyed by `Package.resolved` content and commit SHA. This significantly speeds up incremental builds, especially on the fast path where only a few targets need recompilation.

### OpenSSL Bundling

Lambda functions require OpenSSL libraries (`libcrypto.so.3`, `libssl.so.3`) that are not available in the Lambda runtime. Both deployment workflows extract these libraries from the AL2023 Swift Docker image and bundle them into each Lambda zip file. The Lambda environment variable `LD_LIBRARY_PATH` is set to `/var/task/lib` so the bundled libraries are found at runtime.

### Frontend Assets

Both deployment workflows upload files from the `frontend/` directory to the environment S3 media bucket, with `Cache-Control: public, max-age=31536000, immutable` headers. This includes `latex.css` for rendering mathematical notation in posts.

### Variable Substitution

Before building, both deployment workflows run `scripts/substitute-variables.sh`, which replaces `{{SERVER_DOMAIN}}` and `{{HANDLE_DOMAIN}}` placeholders in SAM templates with the actual values from GitHub repository variables. This keeps the templates portable across different deployments.

### CloudFront Cache Expiry

CloudFront caches expire based on TTL values configured in the CDN stack's cache policies. There are no programmatic invalidations -- the Lambda handlers do not call `CreateInvalidation`. This simplifies the Lambda IAM permissions and avoids the cost and latency of invalidation API calls.

## Runner Configuration

All deployment workflows support both self-hosted and GitHub-hosted runners via repository variables. This lets you migrate between runner types without modifying workflow files.

### Configuration Variables

| Variable | Purpose | Default (if unset) |
|---|---|---|
| `RUNNER_LABELS_LINUX` | Runner labels for Linux jobs | `ubuntu-latest` |
| `RUNNER_LABELS_MACOS` | Runner labels for macOS jobs | `macos-26` |

To use self-hosted runners, set these variables in the repository settings under **Settings > Variables > Actions**:

- `RUNNER_LABELS_LINUX` = `["self-hosted", "linux"]`
- `RUNNER_LABELS_MACOS` = `["self-hosted", "macOS"]`

To use GitHub-hosted runners, remove or leave these variables unset. The workflows fall back to `ubuntu-latest` for Linux and `macos-26` for macOS.

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
