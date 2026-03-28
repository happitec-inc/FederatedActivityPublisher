# Phase 1a Design — Dynamic Actor from DynamoDB

## Goal

Replace the hardcoded Phase 0 WebFinger handler with DynamoDB-backed federation endpoints. Seed actor data via a provisioning CLI. Serve live actor profiles, WebFinger, NodeInfo, and empty collection stubs from the deployed environment stack's DynamoDB table.

## What This Builds

- 8 Lambda handlers across 9 routes (1 upgraded, 7 new; NodeInfo handles 2 routes)
- A minimal shared library (`ActivityPubCore`) with DynamoDB access and model types
- A provisioning CLI to seed actor records
- Updated SAM template importing environment stack resources

## What This Does NOT Include

- No inbox (Phase 2)
- No outbox with real posts (Phase 3)
- No CloudFront or custom domains (Phase 1b)
- No HTTP Signatures (Phase 2)
- No S3 media access (Phase 3)
- No SQS delivery (Phase 3)

## New Dependencies

| Package | Module Used | Purpose |
|---------|------------|---------|
| `aws-sdk-swift` | `AWSDynamoDB` | DynamoDB reads for all handlers |
| `aws-sdk-swift` | `AWSSSM` | SSM Parameter Store writes (provisioning CLI only) |
| `swift-crypto` | `_CryptoExtras` | RSA keypair generation (provisioning CLI — RSA lives in `_CryptoExtras`, not the main `Crypto` module) |
| `swift-argument-parser` | `ArgumentParser` | CLI argument parsing (provisioning CLI only) |

Package URL: `https://github.com/awslabs/aws-sdk-swift.git`

Only `AWSDynamoDB` is needed by Lambda handlers. `AWSSSM` and `swift-crypto` are CLI-only dependencies.

## Shared Library: `ActivityPubCore`

Minimal library target — just enough to avoid duplicating DynamoDB access across 8 handlers.

### `DynamoDBStore`

Thin wrapper around `AWSDynamoDB.DynamoDBClient`. Initialized from environment variables (`TABLE_NAME`).

Methods:
- `getActor(username: String) async throws -> Actor?` — PK: `ACTOR#{username}`, SK: `PROFILE`
- `actorExists(username: String) async throws -> Bool` — lightweight existence check

### Model Types

**`Actor`** — Codable struct matching the DynamoDB schema:
- `username`, `displayName`, `summary`, `avatarUrl`, `headerUrl`
- `publicKeyPem` (PEM-encoded RSA public key)
- `privateKeyArn` (SSM parameter path, e.g. `/activity/stage/keys/randomforms` — stored in DynamoDB so Lambdas can locate the private key for signing in later phases)
- `createdAt`, `discoverable`
- `manuallyApprovesFollowers` (always `false` for now)
- `followerCount`, `followingCount`, `statusCount` (all 0 initially)

**`WebFingerResponse`** — Codable struct for JRD:
- `subject: String`
- `links: [WebFingerLink]`

**`WebFingerLink`** — Codable struct:
- `rel: String`
- `type: String?`
- `href: String?`
- `template: String?`

**`OrderedCollection`** — Codable struct for collections:
- `context: String` (the `@context` URL)
- `id: String`
- `type: String` ("OrderedCollection")
- `totalItems: Int`
- `first: String?` (root collection only)
- `last: String?` (root collection only)
- `orderedItems: [String]?` (present for featured/featuredTags as empty `[]`; absent for outbox root per spec — "MUST NOT embed orderedItems inline")

## Lambda Handlers

All handlers depend on `ActivityPubCore`. All read these environment variables:
- `TABLE_NAME` — DynamoDB table name (imported from environment stack)
- `SERVER_DOMAIN` — where actor URLs live (`activity.happitec.com`)
- `HANDLE_DOMAIN` — what goes after the `@` in handles (`happitec.com`)

Handles are `@username@happitec.com`. Actor URLs are `https://activity.happitec.com/users/username`. WebFinger accepts queries for the handle domain and returns URLs on the server domain.

### WebFingerHandler — `GET /.well-known/webfinger`

Upgraded from Phase 0. Now reads from DynamoDB.

1. Parse `resource` query parameter
2. Validate format: must be `acct:{username}@{handle_domain}` (where `{handle_domain}` matches `HANDLE_DOMAIN` env var)
3. Look up actor in DynamoDB via `DynamoDBStore.getActor(username:)`
4. Return 404 if not found
5. Return JRD JSON with:
   - `rel: "self"` link → `https://{SERVER_DOMAIN}/users/{username}`
   - `rel: "http://webfinger.net/rel/profile-page"` link → `https://{SERVER_DOMAIN}/@{username}`
6. Content-Type: `application/jrd+json`

### ActorHandler — `GET /users/{username}`

Returns the full ActivityPub Actor document (JSON-LD).

1. Extract `{username}` from path parameters
2. Look up actor in DynamoDB
3. Return 404 if not found
4. Content-negotiate: if `Accept` header contains `application/activity+json` or `application/ld+json`, return Actor JSON-LD. If `text/html`, return 302 redirect to `https://{SERVER_DOMAIN}/@{username}`. Default to JSON-LD.
5. Build Actor JSON-LD with full `@context` (AS2 + security + toot namespace), public key block, endpoints (inbox, outbox, followers, following, featured, featuredTags). `attributionDomains` set to `[HANDLE_DOMAIN]`.
6. Content-Type: `application/activity+json`

The Actor JSON structure follows the spec exactly (lines 349-400 of PROJECT-PLAN.md).

### NodeInfoHandler — `GET /.well-known/nodeinfo` + `GET /nodeinfo/2.1`

Two routes, one handler. No DynamoDB needed — mostly static.

- `/.well-known/nodeinfo` → returns JRD with link to `/nodeinfo/2.1`
- `/nodeinfo/2.1` → returns NodeInfo 2.1 JSON (software name/version, protocols: ["activitypub"], openRegistrations: false, usage counts hardcoded to 0 for now)

Content-Type: `application/json`

### Empty Collection Stubs (5 handlers)

Each returns an `OrderedCollection` with `totalItems: 0`. Vary only in the collection `id` URL.

| Handler | Path | `id` |
|---------|------|------|
| OutboxHandler | `GET /users/{username}/outbox` | `https://{domain}/users/{username}/outbox` |
| FollowersHandler | `GET /users/{username}/followers` | `https://{domain}/users/{username}/followers` |
| FollowingHandler | `GET /users/{username}/following` | `https://{domain}/users/{username}/following` |
| FeaturedHandler | `GET /users/{username}/collections/featured` | `https://{domain}/users/{username}/collections/featured` |
| FeaturedTagsHandler | `GET /users/{username}/collections/tags` | `https://{domain}/users/{username}/collections/tags` |

All return Content-Type: `application/activity+json`.

All should verify the actor exists in DynamoDB (return 404 if not) except FollowingHandler, FeaturedHandler, and FeaturedTagsHandler which can skip the check since they always return empty.

Actually — all should verify the actor exists. A request for a non-existent actor's followers should 404, not return an empty collection.

## Provisioning CLI: `ActivityProvisioner`

Separate executable target. Not deployed as a Lambda — run locally or in CI.

Usage:
```bash
swift run ActivityProvisioner \
  --stage stage \
  --username randomforms \
  --display-name "Random Forms" \
  --summary "A bot account" \
  --region us-east-1
```

Steps:
1. Generate RSA 2048 keypair using `swift-crypto` (`_CryptoExtras` module)
2. Store private key as SSM SecureString at `/activity/{stage}/keys/{username}`
3. Write actor profile to DynamoDB:
   - PK: `ACTOR#{username}`, SK: `PROFILE`
   - All fields from the Actor model
   - `publicKeyPem`: PEM-encoded public key
   - `privateKeyArn`: SSM parameter path (`/activity/{stage}/keys/{username}`)
   - `followerCount`, `followingCount`, `statusCount`: 0
   - `manuallyApprovesFollowers`: false
   - `discoverable`: true
   - `createdAt`: current ISO 8601 timestamp

Dependencies: `AWSDynamoDB`, `AWSSSM`, `_CryptoExtras` (from swift-crypto), `ArgumentParser` (for CLI arg parsing)

## SAM Template Changes

### New Parameters

```yaml
EnvironmentStackName:
  Type: String
  Default: activity-environment-stage

ServerDomain:
  Type: String
  Default: activity.happitec.com
  Description: Domain where actor URLs live

HandleDomain:
  Type: String
  Default: happitec.com
  Description: Domain used in handles (@user@happitec.com)
```

### Environment Variables (all Lambda functions)

```yaml
Environment:
  Variables:
    TABLE_NAME: !ImportValue
      Fn::Sub: "${EnvironmentStackName}-TableName"
    SERVER_DOMAIN: !Ref ServerDomain
    HANDLE_DOMAIN: !Ref HandleDomain
```

### IAM Policies (federation handlers)

```yaml
Policies:
  - DynamoDBReadPolicy:
      TableName: !ImportValue
        Fn::Sub: "${EnvironmentStackName}-TableName"
```

SAM's `DynamoDBReadPolicy` grants `GetItem`, `Scan`, `Query`, `BatchGetItem` on the table. Sufficient for all Phase 1a handlers.

### API Gateway Routes (9 total, 8 handlers)

```
GET /.well-known/webfinger       → WebFingerFunction
GET /.well-known/nodeinfo        → NodeInfoFunction
GET /nodeinfo/2.1                → NodeInfoFunction
GET /users/{username}            → ActorFunction
GET /users/{username}/outbox     → OutboxFunction
GET /users/{username}/followers  → FollowersFunction
GET /users/{username}/following  → FollowingFunction
GET /users/{username}/collections/featured → FeaturedFunction
GET /users/{username}/collections/tags     → FeaturedTagsFunction
```

### CodeUri per handler

Each handler gets its own zip from the AWSLambdaPackager output:
```yaml
CodeUri: ../.build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager/{HandlerName}/{HandlerName}.zip
```

## Package.swift Changes

### New dependencies

```swift
.package(url: "https://github.com/awslabs/aws-sdk-swift.git", from: "1.0.0"),
.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
```

### New targets

- `ActivityPubCore` — library target, depends on `AWSDynamoDB`
- 7 new executable targets (ActorHandler, NodeInfoHandler, OutboxHandler, FollowersHandler, FollowingHandler, FeaturedHandler, FeaturedTagsHandler) — all depend on `ActivityPubCore`, `AWSLambdaRuntime`, `AWSLambdaEvents`
- `ActivityProvisioner` — executable target, depends on `ActivityPubCore`, `AWSDynamoDB`, `AWSSSM`, `_CryptoExtras`, `ArgumentParser`
- Updated `WebFingerHandler` — add `ActivityPubCore` dependency

## Build Pipeline Changes

The `swift package archive` command builds all executable products by default. The provisioning CLI will also be archived — this is fine (it produces a zip we don't deploy). Alternatively, we can scope the archive to Lambda handlers only:

```bash
swift package --allow-network-connections docker archive --products WebFingerHandler ActorHandler NodeInfoHandler OutboxHandler FollowersHandler FollowingHandler FeaturedHandler FeaturedTagsHandler
```

This avoids building the CLI inside Docker (it's not a Lambda and doesn't need to run on Amazon Linux).

## Success Criteria

1. Run provisioning CLI to seed actor `randomforms` in stage DynamoDB
2. `GET .../webfinger?resource=acct:randomforms@happitec.com` → 200, dynamic JRD from DynamoDB (note: handle domain is `happitec.com`, actor URLs point to `activity.happitec.com`)
3. `GET .../webfinger?resource=acct:nonexistent@happitec.com` → 404
4. `GET .../users/randomforms` → 200, full Actor JSON-LD with public key and all endpoint URLs
5. `GET .../users/nonexistent` → 404
6. `GET .../.well-known/nodeinfo` → 200, JRD with link to `/nodeinfo/2.1`
7. `GET .../nodeinfo/2.1` → 200, NodeInfo 2.1 JSON
8. `GET .../users/randomforms/outbox` → 200, empty OrderedCollection
9. `GET .../users/randomforms/followers` → 200, empty OrderedCollection
10. `GET .../users/randomforms/following` → 200, empty OrderedCollection
11. `GET .../users/randomforms/collections/featured` → 200, empty OrderedCollection
12. `GET .../users/randomforms/collections/tags` → 200, empty OrderedCollection
