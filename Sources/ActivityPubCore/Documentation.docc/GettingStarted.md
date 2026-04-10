# Getting Started

Set up your development environment and understand the project structure.

## Overview

This guide covers prerequisites, repository setup, and an overview of the three-template architecture that powers your ActivityPub server.

### Prerequisites

- **Swift 6.3+** -- the project uses `swift-tools-version: 6.3`
- **Docker** -- required for building Lambda-compatible binaries using the `docker/Dockerfile.al2023-swift` image
- **AWS CLI v2** -- for deploying SAM templates
- **AWS SAM CLI** -- for packaging and deploying the serverless stacks
- **An AWS account** with permissions to create CloudFormation stacks, Lambda functions, DynamoDB tables, S3 buckets, SQS queues, CloudFront distributions, Route 53 hosted zones, and ACM certificates

### Clone the Repository

```bash
git clone https://github.com/happitec-inc/FederatedActivityPublisher.git
cd FederatedActivityPublisher
swift package resolve
```

### Project Structure

```
federated-activity-publisher/
  Sources/
    ActivityPubCore/        # Shared library (models, DB, crypto, delivery)
    WebFingerHandler/       # Lambda: GET /.well-known/webfinger
    ActorHandler/           # Lambda: GET /users/{username}
    NodeInfoHandler/        # Lambda: GET /.well-known/nodeinfo
    InstanceHandler/        # Lambda: GET /api/v1/instance, /api/v2/instance
    OutboxHandler/          # Lambda: GET /users/{username}/outbox
    FollowersHandler/       # Lambda: GET /users/{username}/followers
    FollowingHandler/       # Lambda: GET /users/{username}/following
    FeaturedHandler/        # Lambda: GET /users/{username}/collections/featured
    FeaturedTagsHandler/    # Lambda: GET /users/{username}/collections/tags
    ObjectHandler/          # Lambda: GET /users/{username}/statuses/{id}
    ProfileHandler/         # Lambda: GET /profile/{proxy+}
    InboxHandler/           # Lambda: POST /users/{username}/inbox
    DeliverHandler/         # Lambda: SQS consumer, signed HTTP POST
    PostHandler/            # Lambda: POST /api/v1/statuses
    MediaUploadHandler/     # Lambda: POST /api/v2/media
    ProfileUpdateHandler/   # Lambda: PATCH /api/v1/accounts/update_credentials
    AuthHandler/            # Lambda: session auth (login/logout/register)
    ComposeHandler/         # Lambda: web compose UI
    ActivityProvisioner/    # CLI: seed actors and generate keypairs
    APIClient/              # OpenAPI-generated client (symlinks openapi.yaml from root)
  Tests/
    ActivityPubCoreTests/   # Unit tests
  integration-tests/        # Separate Swift package for integration tests (runs in Docker)
    Package.swift
    Sources/
    Tests/
  openapi.yaml              # Single OpenAPI spec (symlinked into Sources/APIClient/)
  activity-app/
    template.yaml           # SAM template: root orchestrator (nested stacks)
    functions/
      template.yaml         # Nested stack: Lambda functions + API Gateway
    cdn/
      template.yaml         # Nested stack: CloudFront, cache policies, DNS
  activity-environment/
    template.yaml           # SAM template: environment stack (DynamoDB, SQS, S3)
  activity-bootstrap/
    template.yaml           # SAM template: bootstrap stack (Route 53, ACM)
  scripts/
    substitute-variables.sh # Domain variable substitution for portability
    detect-changed-targets.sh # Selective build target detection
    build-selective.sh      # Build individual Lambda targets
  docker/
    Dockerfile.al2023-swift # Docker image for building Lambda binaries
```

### Three-Template Architecture

The deployment is split into three SAM templates, each managing a different lifecycle:

1. **Bootstrap** (`activity-bootstrap/template.yaml`) -- deployed once, manually. Creates the Route 53 hosted zone for your server domain and an ACM wildcard certificate. These resources outlive all environments.

2. **Environment** (`activity-environment/template.yaml`) -- deployed per stage (prod, stage). Creates the DynamoDB table, SQS delivery queue with DLQ, S3 media bucket, and establishes the SSM parameter naming convention for actor keypairs.

3. **App** (`activity-app/template.yaml`) -- deployed per stage by CI. This is a root orchestrator that delegates to two nested CloudFormation stacks:
   - **FunctionsStack** (`activity-app/functions/template.yaml`) -- all Lambda functions and both API Gateways (federation and client)
   - **CdnStack** (`activity-app/cdn/template.yaml`) -- CloudFront distribution, cache policies, origin access control, and Route 53 DNS records

   The nested stack design separates compute from CDN configuration, allowing CloudFormation to resolve cross-resource references cleanly. This is what gets redeployed on every code change.

This separation means you can redeploy application code without touching your data stores, and data stores without touching DNS/certificates.
