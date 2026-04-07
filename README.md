# FederatedActivityPublisher

A serverless ActivityPub server for brand accounts. Swift 6.3 on AWS Lambda, federated with Mastodon and the fediverse. Zero cost at rest.

Originally built for [Happitec](https://happitec.com) brand accounts. Fork it to run your own.

## What it does

- Hosts ActivityPub actors on your domain (e.g. `@myapp@example.com`)
- Federates with Mastodon, GoToSocial, Misskey, and other ActivityPub servers
- Posts text and images, accepts followers, receives likes/boosts/replies
- Serves HTML profile and post pages with [latex.css](https://latex.css.netlify.app/) styling
- Runs entirely on AWS serverless infrastructure (Lambda, DynamoDB, SQS, S3, CloudFront)

## Architecture

Three SAM/CloudFormation templates, parameterized by stage:

| Stack | Purpose |
|-------|---------|
| `activity-bootstrap` | Route 53 hosted zone, ACM wildcard certificate |
| `activity-environment-{stage}` | DynamoDB table, S3 media bucket, SQS delivery queue |
| `activity-app-{stage}` | 14 Lambda handlers, API Gateway, CloudFront |

In simple DNS mode, your domain points directly to the server. In split DNS mode, traffic is proxied through a parent domain's CloudFront distribution.

## Lambda Handlers

| Handler | Route | Purpose |
|---------|-------|---------|
| WebFingerHandler | `GET /.well-known/webfinger` | Actor discovery |
| ActorHandler | `GET /users/{username}` | Actor JSON-LD + content negotiation |
| InboxHandler | `POST /users/{username}/inbox` | Receive activities (Follow, Like, Announce, Create, Delete, Update, Undo) |
| OutboxHandler | `GET /users/{username}/outbox` | Public post collection |
| ObjectHandler | `GET /users/{username}/statuses/{id}` | Note JSON-LD + content negotiation |
| FollowersHandler | `GET /users/{username}/followers` | Follower collection |
| FollowingHandler | `GET /users/{username}/following` | Following collection |
| FeaturedHandler | `GET /users/{username}/collections/featured` | Pinned posts |
| FeaturedTagsHandler | `GET /users/{username}/collections/tags` | Featured hashtags |
| NodeInfoHandler | `GET /.well-known/nodeinfo` | Server metadata |
| DeliverHandler | SQS consumer | Signed HTTP POST to remote inboxes |
| PostHandler | `POST /api/v1/statuses` | Create posts |
| MediaUploadHandler | `POST /api/v2/media` | Upload images |
| ProfileUpdateHandler | `PATCH /api/v1/accounts/update_credentials` | Update profile |
| ProfileHandler | `GET /profile/{proxy+}` | HTML profile and post pages |

## Cost

| Scale | Estimated Monthly Cost |
|-------|----------------------|
| 100 followers | ~$0.50 |
| 1,000 followers | ~$1-2 |
| 100,000 followers | ~$70-100 |

Route 53 hosted zone ($0.50/month) is the only fixed cost. Everything else is pay-per-request.

## Documentation

Full DocC documentation available when deployed to GitHub Pages (see `deploy-docc.yml` workflow).

See [AGENTS.md](AGENTS.md) for operating the server (provisioning accounts, posting, profile management).

See [Sources/ActivityPubCore/Documentation.docc/DNSSetup.md](Sources/ActivityPubCore/Documentation.docc/DNSSetup.md) for DNS architecture options (simple vs. split domain).

See [Sources/ActivityPubCore/Documentation.docc/DeployYourOwn.md](Sources/ActivityPubCore/Documentation.docc/DeployYourOwn.md) for a step-by-step guide to deploying your own instance.

## Building

Requires Swift 6.3, Docker (for the AL2023 build image), and AWS SAM CLI.

```bash
# Build the Docker image
docker build -t swift-al2023:6.3 -f docker/Dockerfile.al2023-swift .

# Build all Lambda zips
swift package --allow-network-connections docker archive \
  --base-docker-image swift-al2023:6.3 \
  --disable-docker-image-update

# Deploy to stage
sam deploy \
  --template-file activity-app/template.yaml \
  --stack-name activity-app-stage \
  --resolve-s3 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides Stage=stage ...
```

## Configuration

### Required GitHub Secrets

These must be set for deployment workflows to succeed:

| Secret | Used by | Description |
|--------|---------|-------------|
| `AWS_ACCESS_KEY_ID` | app, bootstrap, environment | IAM access key for SAM deployments |
| `AWS_SECRET_ACCESS_KEY` | app, bootstrap, environment | IAM secret key for SAM deployments |

### Optional GitHub Secrets

| Secret | Used by | Description |
|--------|---------|-------------|
| `HAPPITEC_READ_ONLY_PAT` | deploy-docc | PAT for private repo access (OG image generation) |

### Repository Variables

| Variable | Used by | Default | Description |
|----------|---------|---------|-------------|
| `SERVER_DOMAIN` | app, provision-actor | _(required)_ | Domain where the ActivityPub server runs. In simple mode, same as handle domain. In split mode, the subdomain (e.g. `activity.example.com`). |
| `HANDLE_DOMAIN` | app, provision-actor | _(required)_ | Domain used in handles (`@user@example.com`). Permanent once federated. |
| `RUNNER_LABELS_LINUX` | app, bootstrap, environment | `"ubuntu-latest"` | JSON array of runner labels, e.g. `["self-hosted", "linux"]` |
| `RUNNER_LABELS_MACOS` | deploy-docc | `"macos-26"` | JSON array of runner labels for macOS jobs |
| `PROXY_DISTRIBUTION_ID` | app | _(empty)_ | CloudFront distribution ID for cross-distribution cache invalidation; leave empty if not using a parent domain proxy |
| `ACTIVITY_DISTRIBUTION_ID` | app | _(empty)_ | CloudFront distribution ID for activity subdomain; passed as parameter to avoid circular dependency |
| `CLIENT_API_DOMAIN_STAGE` | app | _(empty)_ | Execute-api domain for the stage Client API Gateway (e.g. `abc123.execute-api.us-east-1.amazonaws.com`). Enables same-origin routing through CloudFront. |
| `CLIENT_API_DOMAIN_PROD` | app | _(empty)_ | Execute-api domain for the prod Client API Gateway. Same as stage but for the production stack. |
| `AWS_REGION` | all | `us-east-1` | AWS region for all deployments |
| `ENABLE_DOCC_DEPLOY` | deploy-docc | _(unset)_ | Set to `true` to enable DocC features (OG images, Mermaid diagrams) |
| `DOCC_BASE_URL` | deploy-docc | `https://{owner}.github.io/FederatedActivityPublisher` | Base URL for DocC OG meta tags |

### SAM Parameter Overrides

Key parameters passed to `sam deploy` for the app stack:

| Parameter | Stack | Description |
|-----------|-------|-------------|
| `ServerDomain` | app | The domain the ActivityPub server runs on (e.g. `activity.example.com`) |
| `HandleDomain` | app | The domain used in ActivityPub handles (e.g. `example.com` for `@user@example.com`) |
| `ProxyDistributionId` | app | Optional cross-distribution invalidation target; empty string to skip |
| `Stage` | app, environment | `stage` or `prod` |

## License

[MIT](LICENSE)
