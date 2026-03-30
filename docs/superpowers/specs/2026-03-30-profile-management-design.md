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

**Fields semantics:** Sending `fields_attributes` replaces all fields (even if empty array). Omitting `fields_attributes` entirely preserves existing fields. This matches Mastodon's behavior.

### Data Flow

1. Authenticate via bearer token (SSM lookup, same as PostHandler)
2. Parse multipart form body (shared `MultipartParser` from ActivityPubCore)
3. If avatar provided: validate file size (max 2 MB, return 413 if exceeded), then upload to S3 at `media/avatars/{username}` (no extension — set `Content-Type` via S3 metadata on upload)
4. If header provided: validate file size (max 2 MB, return 413 if exceeded), then upload to S3 at `media/headers/{username}` (no extension — set `Content-Type` via S3 metadata on upload)
5. Update actor record in DynamoDB with changed fields only (conditional UpdateItem)
6. Build and return the updated account JSON response
7. Query all followers and enqueue `Update` activity delivery via SQS (shared inbox coalescing)
8. Invalidate CloudFront cache for `/users/{username}*` (actor, webfinger), `/media/avatars/{username}*`, and `/media/headers/{username}*`

### Response Format

Mastodon-compatible account JSON:
```json
{
  "id": "{username}",
  "username": "{username}",
  "acct": "{username}",
  "display_name": "Random Forms",
  "note": "<p>Generative art for iOS</p>",
  "url": "https://happitec.com/@{username}",
  "avatar": "https://happitec.com/media/avatars/randomforms",
  "avatar_static": "https://happitec.com/media/avatars/randomforms",
  "header": "https://happitec.com/media/headers/randomforms",
  "header_static": "https://happitec.com/media/headers/randomforms",
  "locked": false,
  "bot": true,
  "created_at": "2026-01-01T00:00:00.000Z",
  "fields": [
    {"name": "Website", "value": "<a href=\"https://randomforms.app\" rel=\"me\">randomforms.app</a>"},
    {"name": "App Store", "value": "<a href=\"https://apps.apple.com/app/random-forms\" rel=\"me\">Download</a>"}
  ],
  "emojis": [],
  "followers_count": 42,
  "following_count": 0,
  "statuses_count": 7
}
```

Notes on response fields:
- `avatar_static` / `header_static`: identical to `avatar` / `header` — we do not generate static (non-animated) versions.
- `locked`: always `false` (auto-accept follows).
- `bot`: `true` — accounts are `Service` type actors.
- `created_at`: actor creation timestamp from DynamoDB.
- `url`: the human-readable profile URL.
- `emojis`: always empty array (no custom emoji support).

## DynamoDB Changes

No new entity types. The existing actor record (`PK: ACTOR#{username}`, `SK: PROFILE`) already has `displayName`, `summary`, `avatarUrl`, `headerUrl`.

**New attribute:** `fields` — JSON-encoded string of `[{"name": "...", "value": "..."}]`. Max 4 entries. Storing fields as a JSON string is intentional: they are always read and written as a whole array, so there is no benefit to using a DynamoDB native list/map.

The `summary` field stores HTML (converted from plain text `note` input). Existing actors have plain text summaries — the update handler should store HTML going forward. The ActorHandler already serves `summary` as-is in the actor JSON-LD.

## S3 Media Storage

Avatar and header images use extension-agnostic paths:
- `media/avatars/{username}` — e.g. `media/avatars/randomforms`
- `media/headers/{username}` — e.g. `media/headers/randomforms`

The `Content-Type` is set via S3 object metadata on upload, so changing image format (e.g. PNG to JPEG) does not leave a stale file at the old extension path. These overwrite on each update (no accumulation of old images). The CloudFront OAC serves them at `https://happitec.com/media/avatars/randomforms`.

Content type validation: only allow `image/png`, `image/jpeg`, `image/gif`. Reject other types.

**Image size limits:** Max 2 MB for avatars and 2 MB for headers. The handler must check file size before uploading to S3 and return HTTP 413 if exceeded.

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
  "cc": ["https://happitec.com/users/{username}/followers"],
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

ActorHandler must also be updated to serialize `image` (header) in the actor JSON-LD, using the same pattern as `icon` (avatar):
```json
"image": {
  "type": "Image",
  "url": "https://happitec.com/media/headers/{username}"
}
```

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
        MEDIA_BUCKET_NAME: !Ref MediaBucket
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

**Note:** ProfileUpdateHandler needs the AWSCloudFront dependency in Package.swift explicitly, same as PostHandler. Ensure it is listed in the target's dependencies array.

## Shared Code Extraction

Extract multipart parsing from `Sources/MediaUploadHandler/main.swift` into `Sources/ActivityPubCore/MultipartParser.swift`:
- `MultipartPart` struct
- `extractBoundary(from:)` function
- `parseMultipart(data:boundary:)` function

Both MediaUploadHandler and ProfileUpdateHandler import and use the shared parser.

Additionally, bearer token authentication should be extracted to a shared utility in ActivityPubCore alongside the multipart parser. PostHandler, MediaUploadHandler, and ProfileUpdateHandler all duplicate the same SSM-based bearer token validation logic.

JSON escaping logic should also be extracted to shared code in ActivityPubCore as part of the same refactor pass.

## Note-to-HTML Conversion

The `note` field arrives as plain text. Convert to HTML before storing:
- Wrap in `<p>` tags
- Convert `\n\n` to `</p><p>`
- Convert single `\n` to `<br>`
- Autolink URLs

The existing `Sources/ActivityPubCore/TextToHTML.swift` already handles this conversion for posts. Reuse it for profile note conversion. Note that profile field link formatting needs `rel="me nofollow noopener noreferrer"` which is different from the post autolinker — handle this as a separate code path or a parameter to the formatter.

## Testing

- Unit tests for profile field serialization/deserialization
- Unit tests for note-to-HTML conversion (if extracted)
- Curl smoke test: `curl -X PATCH` with display_name + note + avatar file + header file, verify actor endpoint reflects changes
- Verify `Update` activity appears in follower's Mastodon client (profile refresh)

## Parallelization

1. Extract MultipartParser to ActivityPubCore (no dependencies)
2. Add `fields` support to ActorHandler (independent)
3. ProfileUpdateFunction + SAM template changes
4. Delivery fan-out for Update activity
5. Smoke test

Steps 1-2 can run in parallel. Steps 3-4 are sequential. Step 5 is last.
