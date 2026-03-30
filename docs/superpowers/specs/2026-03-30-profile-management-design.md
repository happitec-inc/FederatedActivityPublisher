# Workstream B: Profile Management — Design Spec

## Goal

Allow brand accounts to update their profile (display name, bio, avatar, header, profile links) via a Mastodon-compatible API endpoint, with changes federated to all followers.

## Scope

**In scope:**
- `PATCH /api/v1/accounts/update_credentials` on the client API
- Fields: display_name, note (bio), avatar (file), header (file), fields_attributes (up to 4 key-value pairs)
- Bearer token auth (existing pattern)
- Avatar/header upload to S3
- DynamoDB actor record update
- Federate `Update` activity to all followers via SQS
- CloudFront cache invalidation for actor endpoint
- Extract multipart parser to shared ActivityPubCore utility
- Profile fields as `PropertyValue` attachments in actor JSON-LD with `rel="me"` on links

**Out of scope (deferred):**
- OAuth2 token flow (Phase 6)
- Additional Mastodon flags: discoverable, locked, indexable, bot, source preferences (#72)
- Profile field verification (Mastodon verifies `rel="me"` links bidirectionally — we just set `rel="me"` and let remote servers verify)

## Architecture

### New Lambda: ProfileUpdateFunction

On the `ClientApi` gateway (same as PostHandler and MediaUploadHandler). No circular dependency risk since ClientApi is explicit and not referenced by CloudFront.

**Route:** `PATCH /api/v1/accounts/update_credentials`

**Auth:** Bearer token from SSM (same pattern as PostHandler/MediaUploadHandler).

### Request Format

Multipart form data. All fields optional — only provided fields are updated.

| Field | Type | Description |
|-------|------|-------------|
| `display_name` | string | Display name |
| `note` | string | Bio (plain text input, stored as HTML for federation) |
| `avatar` | file | Avatar image (PNG, JPEG, GIF) |
| `header` | file | Header image (PNG, JPEG, GIF) |
| `fields_attributes[0][name]` | string | Profile field label (e.g. "Website") |
| `fields_attributes[0][value]` | string | Profile field value (URL or text) |
| `fields_attributes[1][name]` | string | Second field label |
| `fields_attributes[1][value]` | string | Second field value |
| (up to index 3) | | Mastodon allows max 4 profile fields |

### Data Flow

1. Authenticate via bearer token (SSM lookup, same as PostHandler)
2. Parse multipart form body (shared `MultipartParser` from ActivityPubCore)
3. If avatar provided: upload to S3 at `media/avatars/{username}.{ext}` (overwrite previous)
4. If header provided: upload to S3 at `media/headers/{username}.{ext}` (overwrite previous)
5. Update actor record in DynamoDB with changed fields only (conditional UpdateItem)
6. Build and return the updated account JSON response
7. Query all followers and enqueue `Update` activity delivery via SQS (shared inbox coalescing)
8. Invalidate CloudFront cache for `/users/{username}*` (actor, webfinger)

### Response Format

Mastodon-compatible account JSON:
```json
{
  "id": "{username}",
  "username": "{username}",
  "acct": "{username}",
  "display_name": "Random Forms",
  "note": "<p>Generative art for iOS</p>",
  "avatar": "https://happitec.com/media/avatars/randomforms.png",
  "header": "https://happitec.com/media/headers/randomforms.png",
  "fields": [
    {"name": "Website", "value": "<a href=\"https://randomforms.app\" rel=\"me\">randomforms.app</a>"},
    {"name": "App Store", "value": "<a href=\"https://apps.apple.com/app/random-forms\" rel=\"me\">Download</a>"}
  ],
  "followers_count": 42,
  "following_count": 0,
  "statuses_count": 7
}
```

## DynamoDB Changes

No new entity types. The existing actor record (`PK: ACTOR#{username}`, `SK: PROFILE`) already has `displayName`, `summary`, `avatarUrl`, `headerUrl`.

**New attribute:** `fields` — JSON-encoded string of `[{"name": "...", "value": "..."}]`. Max 4 entries.

The `summary` field stores HTML (converted from plain text `note` input). Existing actors have plain text summaries — the update handler should store HTML going forward. The ActorHandler already serves `summary` as-is in the actor JSON-LD.

## S3 Media Storage

Avatar and header images use predictable paths:
- `media/avatars/{username}.{ext}` — e.g. `media/avatars/randomforms.png`
- `media/headers/{username}.{ext}` — e.g. `media/headers/randomforms.png`

These overwrite on each update (no accumulation of old images). The CloudFront OAC serves them at `https://happitec.com/media/avatars/randomforms.png`.

Content type validation: only allow `image/png`, `image/jpeg`, `image/gif`. Reject other types.

## ActivityPub Federation

### Update Activity

```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/v1",
    { "toot": "http://joinmastodon.org/ns#", ... }
  ],
  "id": "https://happitec.com/users/{username}#update-{ulid}",
  "type": "Update",
  "actor": "https://happitec.com/users/{username}",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "object": {
    // Full actor JSON-LD document (same as GET /users/{username})
  }
}
```

Delivered to all follower inboxes via SQS with shared inbox coalescing (same pattern as PostHandler's delivery fan-out).

### Profile Fields in Actor JSON-LD

Profile fields appear as `attachment` on the actor document:
```json
"attachment": [
  {
    "type": "PropertyValue",
    "name": "Website",
    "value": "<a href=\"https://randomforms.app\" rel=\"me nofollow noopener noreferrer\" target=\"_blank\">randomforms.app</a>"
  }
]
```

Links in field values get `rel="me nofollow noopener noreferrer"`. The `rel="me"` enables Mastodon's verified link feature (green checkmark when the linked page links back).

Plain text field values (non-URLs) are HTML-escaped and served as-is.

### ActorHandler Changes

The existing ActorHandler must be updated to include `attachment` (profile fields) in the actor JSON-LD response. Currently it does not serialize fields.

## SAM Template Changes

New resource:
```yaml
ProfileUpdateFunction:
  Type: AWS::Serverless::Function
  Properties:
    FunctionName: !Sub "activity-app-profileupdate-${Stage}"
    CodeUri: ../.build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager/ProfileUpdateHandler/ProfileUpdateHandler.zip
    Timeout: 60
    Environment:
      Variables:
        CLOUDFRONT_DISTRIBUTION_ID: !Ref CloudFrontDistribution
    Policies:
      - DynamoDBCrudPolicy:
          TableName: !ImportValue ...
      - Statement:
          - Effect: Allow
            Action: s3:PutObject
            Resource: !Sub "${BucketArn}/*"
      - SQSSendMessagePolicy:
          QueueName: ...
      - SSMParameterReadPolicy:
          ParameterName: !Sub "activity/${Stage}/*"
      - Statement:
          - Effect: Allow
            Action: kms:Decrypt
            Resource: !Sub "arn:aws:kms:${AWS::Region}:${AWS::AccountId}:alias/aws/ssm"
      - Statement:
          - Effect: Allow
            Action: cloudfront:CreateInvalidation
            Resource: !Sub "arn:aws:cloudfront::${AWS::AccountId}:distribution/${CloudFrontDistribution}"
    Events:
      UpdateCredentials:
        Type: Api
        Properties:
          RestApiId: !Ref ClientApi
          Path: /api/v1/accounts/update_credentials
          Method: PATCH
```

Note: uses `ClientApi` (not the federation API), so the CloudFront `!Ref` does not create a circular dependency.

Also add `ProfileUpdateHandler` to `Package.swift` as a new executable target with dependencies on ActivityPubCore, AWSLambdaRuntime, AWSLambdaEvents, AWSS3, AWSSQS, AWSSSM, AWSCloudFront.

## Shared Code Extraction

Extract multipart parsing from `Sources/MediaUploadHandler/main.swift` into `Sources/ActivityPubCore/MultipartParser.swift`:
- `MultipartPart` struct
- `extractBoundary(from:)` function
- `parseMultipart(data:boundary:)` function

Both MediaUploadHandler and ProfileUpdateHandler import and use the shared parser.

## Note-to-HTML Conversion

The `note` field arrives as plain text. Convert to HTML before storing:
- Wrap in `<p>` tags
- Convert `\n\n` to `</p><p>`
- Convert single `\n` to `<br>`
- Autolink URLs

This is the same conversion PostHandler already does for status text. Extract to a shared utility in ActivityPubCore if not already shared.

## Testing

- Unit tests for profile field serialization/deserialization
- Unit tests for note-to-HTML conversion (if extracted)
- Curl smoke test: `curl -X PATCH` with display_name + note + avatar file, verify actor endpoint reflects changes
- Verify `Update` activity appears in follower's Mastodon client (profile refresh)

## Parallelization

1. Extract MultipartParser to ActivityPubCore (no dependencies)
2. Add `fields` support to ActorHandler (independent)
3. ProfileUpdateFunction + SAM template changes
4. Delivery fan-out for Update activity
5. Smoke test

Steps 1-2 can run in parallel. Steps 3-4 are sequential. Step 5 is last.
