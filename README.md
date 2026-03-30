# FederatedActivityPublisher

A serverless ActivityPub server for brand accounts. Swift 6.3 on AWS Lambda, federated with Mastodon and the fediverse. Zero cost at rest.

Built for [happitec-inc](https://happitec.com) brand accounts like [@logos@happitec.com](https://happitec.com/@logos), [@randomforms@happitec.com](https://happitec.com/@randomforms), and others.

## What it does

- Hosts ActivityPub actors on `happitec.com` (e.g. `@logos@happitec.com`)
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

All public traffic is proxied through the `happitec.com` CloudFront distribution. The `activity.happitec.com` subdomain exists for infrastructure but is not the public-facing domain.

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

Full DocC documentation at [docs.happitec.com/FederatedActivityPublisher](https://docs.happitec.com/FederatedActivityPublisher/documentation/activitypubcore/).

See [AGENTS.md](AGENTS.md) for operating the server (provisioning accounts, posting, profile management).

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

## CI/CD Configuration

Workflows support both self-hosted and GitHub-hosted runners. Set these repository variables to use self-hosted runners:

| Variable | Self-hosted | Default (GitHub-hosted) |
|----------|-------------|------------------------|
| `RUNNER_LABELS_LINUX` | `["self-hosted", "linux"]` | `ubuntu-latest` |
| `RUNNER_LABELS_MACOS` | `["self-hosted", "macOS"]` | `macos-15` |

Additional required variables and secrets:

| Name | Type | Purpose |
|------|------|---------|
| `AWS_ACCESS_KEY_ID` | Secret | AWS credentials for deployment |
| `AWS_SECRET_ACCESS_KEY` | Secret | AWS credentials for deployment |
| `HAPPITEC_DISTRIBUTION_ID` | Variable | happitec.com CloudFront distribution ID (for cross-distribution cache invalidation) |
| `ACTIVITY_API_DOMAIN` | Variable | API Gateway execute-api domain (set on happitec.com repo) |
| `ACTIVITY_CDN_DOMAIN` | Variable | Activity CloudFront domain (set on happitec.com repo) |

## License

[MIT](LICENSE)
