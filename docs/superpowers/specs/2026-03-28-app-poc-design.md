# App PoC Design — Swift Lambda Build Pipeline

## Goal

Prove the Swift-on-Lambda build pipeline works end-to-end: Swift source compiles for ARM64 via Docker, SAM packages the zip, GitHub Actions deploys to AWS, and the Lambda responds to HTTP requests through API Gateway.

## What This Proves

- Swift cross-compilation for Lambda ARM64 using Docker on the self-hosted Linux runner
- The `AWSLambdaPackager` SwiftPM plugin produces a valid Lambda zip
- SAM packages and deploys the zip correctly
- API Gateway REST API (V1) routes to the Lambda
- The `bootstrap` custom runtime convention works with `provided.al2023`
- The CI pipeline is functional

## What This Does NOT Include

- No AWS SDK usage (Phase 1a)
- No DynamoDB reads (Phase 1a)
- No CloudFront or custom domains (Phase 1b)
- No shared library (`ActivityPubCore`)
- No PR/merge/release workflow triggers (Phase 1)
- No real WebFinger logic — hardcoded JSON only

## Toolchain

| Component | Choice | Rationale |
|-----------|--------|-----------|
| swift-tools-version | 6.3 | Latest stable Swift release |
| Build image | `swift:6.3-amazonlinux2` | Only official Swift image for AL; binary is statically linked |
| Lambda runtime | `provided.al2023` | AL2 EOL is June 2026; static binary runs fine on AL2023 |
| Packaging | `AWSLambdaPackager` SwiftPM plugin | Ships with `swift-aws-lambda-runtime`; no Makefile or Dockerfile needed |
| Lambda runtime lib | `swift-aws-lambda-runtime` 2.0+ | V2 API with `LambdaRuntime` closure pattern |
| Event types | `swift-aws-lambda-events` 1.0+ | `APIGatewayRequest` / `APIGatewayResponse` for REST API V1 |

## Build Pipeline

```
swift package --allow-network-connections docker archive
  → Pulls swift:6.3-amazonlinux2
  → Builds release binary with --static-swift-stdlib inside container
  → Produces .build/plugins/AWSLambdaPackager/outputs/.../WebFingerHandler.zip
       (contains bootstrap binary)

sam deploy --template-file activity-app/template.yaml
  → Uploads zip to S3
  → Creates/updates Lambda function + API Gateway
```

No `sam build` step needed — the SwiftPM plugin produces the final zip directly. SAM just needs to reference it in `CodeUri`.

## Files

### `Package.swift`

Root of the repo. One executable target for the PoC; more targets added as handlers are built.

- swift-tools-version: 6.3
- Dependencies: `swift-aws-lambda-runtime` (2.0+), `swift-aws-lambda-events` (1.0+)
- Executable target: `WebFingerHandler` (Sources/WebFingerHandler/)

### `Sources/WebFingerHandler/main.swift`

Hardcoded WebFinger response. Handles:
- Parse `resource` query parameter from `APIGatewayRequest`
- Return 400 if `resource` is missing
- Return 404 if `resource` doesn't match the test actor (`acct:test@activity.happitec.com`)
- Return hardcoded WebFinger JSON with Content-Type `application/jrd+json`

Response body:
```json
{
  "subject": "acct:test@activity.happitec.com",
  "links": [
    {
      "rel": "self",
      "type": "application/activity+json",
      "href": "https://activity.happitec.com/users/test"
    }
  ]
}
```

### `activity-app/template.yaml`

Minimal SAM template:
- One `AWS::Serverless::Function` (WebFingerHandler)
- Runtime: `provided.al2023`
- Architecture: `arm64`
- Memory: 512MB
- Timeout: 30s
- CodeUri: `../.build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager/WebFingerHandler/WebFingerHandler.zip` (relative to `activity-app/`, where the template lives)
- One API event: `GET /.well-known/webfinger`
- Parameters: `Stage` (for stack naming)

### `.github/workflows/app.yml`

Manual dispatch only for Phase 0. Steps:
1. Checkout
2. Install SAM CLI (setup-sam-portable)
3. Configure AWS credentials
4. `swift package --allow-network-connections docker archive` (builds inside Docker, produces zip)
5. `sam deploy` with the pre-built zip
6. Print stack outputs (API Gateway URL) to job summary

Self-hosted Linux runner (has Docker).

## Success Criteria

```bash
curl "https://<api-gw-url>/Prod/.well-known/webfinger?resource=acct:test@activity.happitec.com"
```

Returns:
- HTTP 200
- Content-Type: `application/jrd+json`
- Valid WebFinger JSON with `subject` and `links`

## Phase 1 Evolution

After the PoC succeeds, the app stack evolves:

- **Phase 1a:** Add DynamoDB reads (AWS SDK via `soto`), real WebFinger logic, actor endpoint, more Lambda handlers
- **Phase 1b:** Add CloudFront, custom domains, Route 53 records
- **Workflow triggers:** PR → `activity-app-pr-{n}` at `pr-{n}.activity.happitec.com`, push to main → `activity-app-stage` at `stage.activity.happitec.com`, release → `activity-app-prod` at `activity.happitec.com`
