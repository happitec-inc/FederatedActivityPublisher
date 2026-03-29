# Phase 3 Implementation Plan — Posting + Delivery (Client API)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable posting statuses via a Mastodon-compatible API, delivering them to followers via signed HTTP, and serving them through the outbox. Posts appear in followers' timelines on Mastodon.

**Architecture:** Separate Client API Gateway (not behind CloudFront) with bearer token auth. PostHandler writes status to DynamoDB, fans out delivery jobs to SQS, invalidates CloudFront outbox cache. MediaUploadHandler receives multipart uploads, writes to S3, stores metadata. DeliverHandler (already exists from Phase 2) delivers signed Create activities. OutboxHandler upgraded to serve real posts.

**Tech Stack:** Swift 6.3, aws-sdk-swift (AWSDynamoDB, AWSS3, AWSSQS, AWSSSM, AWSCloudFront), AWS SAM

**Spec:** `docs/PROJECT-PLAN.md` (post handler lines 495-544, media upload lines 546-550, outbox lines 457-461, client SAM lines 1349-1367, to/cc addressing lines 499-526, text-to-HTML line 542)

---

## Scope

**Included:**
- Client API Gateway (separate domain, bearer token auth)
- PostHandler: create status, text-to-HTML, to/cc addressing, fan out to SQS, CloudFront invalidation
- MediaUploadHandler: multipart upload to S3, metadata to DynamoDB
- Upgrade OutboxHandler to serve real posts (Create wrapper activities, pagination)
- Upgrade DeliverHandler to handle Create activity delivery (not just Accept)
- Status model in DynamoDB
- Shared inbox coalescing for delivery fan-out

**Deferred:**
- Quote posts / FEP-044f (Phase 5)
- `in_reply_to_id` threading (Phase 5)
- OAuth2 (Phase 6 — bearer token for MVP)

---

## File Structure

### New files

```
Sources/
  ActivityPubCore/
    TextToHTML.swift              # Plain text → HTML conversion (paragraphs, line breaks, autolinks)
    Models/
      Status.swift               # Status record model (DynamoDB entity)
      CreateStatusRequest.swift  # API request model
      Note.swift                 # ActivityPub Note JSON-LD builder
  PostHandler/main.swift         # POST /api/v1/statuses
  MediaUploadHandler/main.swift  # POST /api/v2/media
```

### Modified files

```
Package.swift                    # Add AWSS3, AWSCloudFront deps; PostHandler, MediaUploadHandler targets
Sources/ActivityPubCore/DynamoDBStore.swift  # Add status CRUD, media metadata, follower listing
Sources/ActivityPubCore/Delivery/SQSDeliveryClient.swift  # Add batch enqueue for fan-out
Sources/OutboxHandler/main.swift # Serve real posts with pagination
Sources/DeliverHandler/main.swift # Handle Create activities (not just Accept)
activity-app/template.yaml      # Add ClientApi, PostFunction, MediaUploadFunction, IAM
.github/workflows/app.yml       # Add new handler products
```

---

### Task 1: Status model + CreateStatusRequest

**Files:**
- Create: `Sources/ActivityPubCore/Models/Status.swift`
- Create: `Sources/ActivityPubCore/Models/CreateStatusRequest.swift`

- [ ] **Step 1: Implement Status model**

Matches DynamoDB schema (PROJECT-PLAN.md line 311):
```swift
public struct Status: Codable, Sendable {
    public let id: String           // ULID
    public let username: String
    public let content: String      // HTML
    public let contentWarning: String?
    public let visibility: String   // public, unlisted, private, direct
    public let sensitive: Bool
    public let language: String?
    public let published: String    // ISO 8601
    public let url: String          // human-readable permalink
    public let uri: String          // ActivityPub URI
    public let to: [String]
    public let cc: [String]
    public let attachments: [MediaAttachmentRef]?
    public let inReplyTo: String?
    public let likesCount: Int
    public let boostsCount: Int
    public let repliesCount: Int
}

public struct MediaAttachmentRef: Codable, Sendable {
    public let id: String
    public let url: String          // CloudFront URL
    public let contentType: String
    public let description: String? // alt text
    public let blurhash: String?
}
```

With `fromDynamoDB` and `toDynamoDB` conversion methods.

- [ ] **Step 2: Implement CreateStatusRequest**

Matches the OpenAPI schema:
```swift
public struct CreateStatusRequest: Codable, Sendable {
    public let status: String       // plain text
    public let mediaIds: [String]?
    public let sensitive: Bool?
    public let spoilerText: String?
    public let visibility: String?  // default: "public"
    public let language: String?
    public let inReplyToId: String?

    enum CodingKeys: String, CodingKey {
        case status
        case mediaIds = "media_ids"
        case sensitive
        case spoilerText = "spoiler_text"
        case visibility
        case language
        case inReplyToId = "in_reply_to_id"
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/ActivityPubCore/Models/Status.swift Sources/ActivityPubCore/Models/CreateStatusRequest.swift
git commit -m "Add Status and CreateStatusRequest models"
```

---

### Task 2: Text-to-HTML conversion

**Files:**
- Create: `Sources/ActivityPubCore/TextToHTML.swift`

- [ ] **Step 1: Implement text-to-HTML converter**

`public func convertTextToHTML(_ text: String) -> String`

Rules (from PROJECT-PLAN.md line 542):
1. Split on `\n\n` into paragraphs
2. Wrap each paragraph in `<p>...</p>`
3. Convert single `\n` within paragraphs to `<br>`
4. Autolink URLs: detect `https?://...` patterns, wrap in `<a href="...">...</a>`
5. HTML-escape special characters (`<`, `>`, `&`, `"`) before wrapping in tags

Do NOT implement `@mention` or `#hashtag` resolution for MVP — those require actor/tag lookup. Just convert plain text to paragraphed HTML with autolinked URLs.

- [ ] **Step 2: Commit**

```bash
git add Sources/ActivityPubCore/TextToHTML.swift
git commit -m "Add text-to-HTML converter (paragraphs, line breaks, autolinks)"
```

---

### Task 3: Note JSON-LD builder

**Files:**
- Create: `Sources/ActivityPubCore/Models/Note.swift`

- [ ] **Step 1: Implement Note builder**

Builds the ActivityPub Note JSON-LD for federation. This is the `object` inside a `Create` activity.

`public func buildNoteJSON(status:serverDomain:username:) -> String`

Must include:
- `@context` with Note-level additions (Hashtag, sensitive, blurhash, focalPoint, etc. — PROJECT-PLAN.md lines 399-409)
- `id`: `https://{serverDomain}/users/{username}/statuses/{id}`
- `type`: "Note"
- `attributedTo`: `https://{serverDomain}/users/{username}` — **required, posts invisible without it**
- `content`: HTML
- `url`: human-readable permalink
- `published`: ISO 8601
- `to`, `cc`: from the status
- `sensitive`, `summary` (content warning)
- `attachment`: array of media objects with `type`, `mediaType`, `url`, `name` (alt text), `blurhash`

Also build the `Create` wrapper:

`public func buildCreateActivityJSON(status:note:serverDomain:username:) -> String`

Must include:
- `@context`
- `id`: `https://{serverDomain}/users/{username}/statuses/{id}/activity`
- `type`: "Create"
- `actor`: `https://{serverDomain}/users/{username}`
- `published`
- `to`, `cc`: same as the Note
- `object`: the Note

Build JSON manually (same approach as ActorHandler — `@context` with mixed types is awkward in Codable).

- [ ] **Step 2: Commit**

```bash
git add Sources/ActivityPubCore/Models/Note.swift
git commit -m "Add Note + Create activity JSON-LD builders"
```

---

### Task 4: DynamoDBStore — status + follower listing

**Files:**
- Modify: `Sources/ActivityPubCore/DynamoDBStore.swift`

- [ ] **Step 1: Add status methods**

- `storeStatus(_ status: Status) async throws` — PK: `ACTOR#{username}`, SK: `STATUS#{ulid}`. Also writes GSI1PK: `ACTOR#{username}`, GSI1SK: `PUBLISHED#{iso8601}`.
- `incrementStatusCount(username:) async throws` — atomic UpdateItem
- `getStatus(username:id:) async throws -> Status?`
- `listStatuses(username:limit:cursor:) async throws -> ([Status], String?)` — Query GSI1 with `ScanIndexForward=false` for newest-first pagination. Returns statuses + next cursor.

- [ ] **Step 2: Add follower listing for fan-out**

- `listAllFollowers(username:) async throws -> [Follower]` — Paginated Query on GSI1 (`FOLLOWERS#{username}`), fetches ALL followers (for delivery fan-out). Returns array with `inboxUrl` and `sharedInboxUrl`.

- [ ] **Step 3: Add media metadata**

- `storeMediaMetadata(id:s3Key:contentType:description:blurhash:width:height:size:) async throws` — PK: `MEDIA#{id}`, SK: `META`
- `getMediaMetadata(id:) async throws -> MediaAttachmentRef?`

- [ ] **Step 4: Commit**

```bash
git add Sources/ActivityPubCore/DynamoDBStore.swift
git commit -m "Add status CRUD, follower listing, media metadata to DynamoDBStore"
```

---

### Task 5: PostHandler

**Files:**
- Create: `Sources/PostHandler/main.swift`

- [ ] **Step 1: Implement PostHandler**

`POST /api/v1/statuses` — the core posting endpoint.

Flow:
1. Verify bearer token auth (read `Authorization` header, compare against SSM-stored token for the actor)
2. Parse request body as `CreateStatusRequest`
3. Generate ULID for the status ID
4. Convert plain text to HTML via `convertTextToHTML`
5. Compute `to`/`cc` arrays based on visibility (PROJECT-PLAN.md lines 499-526):
   - `public`: to=[as:Public], cc=[followers collection]
   - `unlisted`: to=[followers], cc=[as:Public]
   - `private`: to=[followers], cc=[]
   - `direct`: to=[mentioned actors], cc=[]
6. If `media_ids` provided, look up media metadata from DynamoDB to build attachment refs
7. Store status in DynamoDB
8. Increment `statusCount` atomically
9. List all followers for fan-out
10. Group followers by `sharedInboxUrl` for shared inbox coalescing
11. Build Create activity JSON (wrapping the Note)
12. Enqueue one delivery job per unique inbox/shared-inbox to SQS
13. Fire CloudFront invalidation for `/users/{username}/outbox*`
14. Return the status as JSON (Mastodon-compatible Status entity)

Environment variables: `TABLE_NAME`, `SERVER_DOMAIN`, `HANDLE_DOMAIN`, `QUEUE_URL`, `SSM_KEY_PREFIX`, `CLOUDFRONT_DISTRIBUTION_ID`

IAM: DynamoDB CRUD, SQS SendMessage, CloudFront CreateInvalidation, SSM GetParameter

- [ ] **Step 2: Commit**

```bash
git add Sources/PostHandler/main.swift
git commit -m "Add PostHandler — create status, fan out delivery, invalidate cache"
```

---

### Task 6: MediaUploadHandler

**Files:**
- Create: `Sources/MediaUploadHandler/main.swift`

- [ ] **Step 1: Implement MediaUploadHandler**

`POST /api/v2/media` — receives multipart upload.

Flow:
1. Verify bearer token auth
2. Parse multipart form data from the API Gateway event (base64-encoded body)
3. Extract `file`, `description` (alt text), `focus` fields
4. Generate a unique media ID (ULID)
5. Determine content type from the file data or the `Content-Type` of the part
6. Upload to S3: key `media/{id}/{filename}`, content type from above
7. Store metadata in DynamoDB (PK: `MEDIA#{id}`, SK: `META`)
8. Return `MediaAttachment` JSON response with the CloudFront URL

Environment variables: `TABLE_NAME`, `SERVER_DOMAIN`, `MEDIA_BUCKET_NAME`

IAM: S3 PutObject, DynamoDB PutItem

Note: API Gateway has a 6MB payload limit. This covers most images. Larger files are out of scope for MVP.

- [ ] **Step 2: Commit**

```bash
git add Sources/MediaUploadHandler/main.swift
git commit -m "Add MediaUploadHandler — multipart upload to S3 + DynamoDB metadata"
```

---

### Task 7: Upgrade OutboxHandler

**Files:**
- Modify: `Sources/OutboxHandler/main.swift`

- [ ] **Step 1: Replace empty stub with real outbox**

The outbox now serves actual posts from DynamoDB, wrapped in Create activities.

Logic:
1. If no `page` query param (or `page=false`): return root `OrderedCollection` with `totalItems` (from actor's `statusCount`), `first` and `last` URIs. **No `orderedItems`.**
2. If `page=true`: query DynamoDB GSI1 for statuses, build `OrderedCollectionPage` with `orderedItems` (array of Create activities wrapping Notes), `partOf`, `next`, `prev`.
3. Pagination via `max_id` / `min_id` query params mapping to ULID cursors.

Content-Type: `application/activity+json`

- [ ] **Step 2: Commit**

```bash
git add Sources/OutboxHandler/main.swift
git commit -m "Upgrade OutboxHandler — serve real posts with pagination"
```

---

### Task 8: Upgrade DeliverHandler for Create activities

**Files:**
- Modify: `Sources/DeliverHandler/main.swift`

- [ ] **Step 1: Handle Create activities alongside Accept**

The DeliverHandler already handles Accept-Follow from Phase 2. It now also handles Create (new post) delivery. The same signing logic applies — the delivery job payload already contains the activity JSON and target inbox. No structural changes needed if the handler is generic (signs and POSTs whatever activity JSON is in the job). Verify this is the case; if the handler has Accept-specific logic, generalize it.

- [ ] **Step 2: Commit**

```bash
git add Sources/DeliverHandler/main.swift
git commit -m "Verify DeliverHandler handles Create activities generically"
```

---

### Task 9: Package.swift updates

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add dependencies and targets**

New dependencies on ActivityPubCore:
- `AWSS3` (from aws-sdk-swift) — for MediaUploadHandler
- `AWSCloudFront` (from aws-sdk-swift) — for PostHandler cache invalidation

New executable targets:
- `PostHandler` — depends on `ActivityPubCore`, `AWSLambdaRuntime`, `AWSLambdaEvents`, `AWSSSM`, `AWSCloudFront`
- `MediaUploadHandler` — depends on `ActivityPubCore`, `AWSLambdaRuntime`, `AWSLambdaEvents`, `AWSS3`

Add both to the products list.

- [ ] **Step 2: Commit**

```bash
git add Package.swift
git commit -m "Add PostHandler and MediaUploadHandler targets + S3/CloudFront deps"
```

---

### Task 10: SAM template — Client API + functions

**Files:**
- Modify: `activity-app/template.yaml`

- [ ] **Step 1: Add Client API Gateway**

The client API is a SEPARATE API Gateway (not behind CloudFront). Add a new `AWS::Serverless::Api` resource:

```yaml
ClientApi:
  Type: AWS::Serverless::Api
  Properties:
    StageName: !Ref Stage
    Auth:
      DefaultAuthorizer: NONE
```

Note: Auth is handled at the Lambda level (bearer token check), not API Gateway level for MVP.

- [ ] **Step 2: Add PostFunction**

```yaml
PostFunction:
  Type: AWS::Serverless::Function
  Properties:
    FunctionName: !Sub "activity-app-post-${Stage}"
    CodeUri: ../.build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager/PostHandler/PostHandler.zip
    Timeout: 60
    Environment:
      Variables:
        CLOUDFRONT_DISTRIBUTION_ID: !Ref CloudFrontDistribution
    Policies:
      - DynamoDBCrudPolicy:
          TableName: !ImportValue
            Fn::Sub: "${EnvironmentStackName}-TableName"
      - SQSSendMessagePolicy:
          QueueName: !Select [4, !Split ["/", !ImportValue { "Fn::Sub": "${EnvironmentStackName}-QueueUrl" }]]
      - Statement:
          - Effect: Allow
            Action: cloudfront:CreateInvalidation
            Resource: !Sub "arn:aws:cloudfront::${AWS::AccountId}:distribution/${CloudFrontDistribution}"
      - SSMParameterReadPolicy:
          ParameterName: !Sub "activity/${Stage}/*"
    Events:
      CreateStatus:
        Type: Api
        Properties:
          RestApiId: !Ref ClientApi
          Path: /api/v1/statuses
          Method: POST
```

- [ ] **Step 3: Add MediaUploadFunction**

```yaml
MediaUploadFunction:
  Type: AWS::Serverless::Function
  Properties:
    FunctionName: !Sub "activity-app-media-${Stage}"
    CodeUri: ../.build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager/MediaUploadHandler/MediaUploadHandler.zip
    Timeout: 60
    Environment:
      Variables:
        MEDIA_BUCKET_NAME: !ImportValue
          Fn::Sub: "${EnvironmentStackName}-MediaBucketName"
    Policies:
      - S3CrudPolicy:
          BucketName: !ImportValue
            Fn::Sub: "${EnvironmentStackName}-MediaBucketName"
      - DynamoDBCrudPolicy:
          TableName: !ImportValue
            Fn::Sub: "${EnvironmentStackName}-TableName"
      - SSMParameterReadPolicy:
          ParameterName: !Sub "activity/${Stage}/*"
    Events:
      UploadMedia:
        Type: Api
        Properties:
          RestApiId: !Ref ClientApi
          Path: /api/v2/media
          Method: POST
```

- [ ] **Step 4: Add Client API outputs**

```yaml
ClientApiUrl:
  Description: Client API endpoint URL
  Value: !Sub "https://${ClientApi}.execute-api.${AWS::Region}.amazonaws.com/${Stage}"
  Export:
    Name: !Sub "${AWS::StackName}-ClientApiUrl"
```

- [ ] **Step 5: Commit**

```bash
git add activity-app/template.yaml
git commit -m "Add Client API Gateway, PostFunction, MediaUploadFunction to SAM template"
```

---

### Task 11: Unit tests

**Files:**
- Create: `Tests/ActivityPubCoreTests/TextToHTMLTests.swift`
- Create: `Tests/ActivityPubCoreTests/NoteBuilderTests.swift`

- [ ] **Step 1: Text-to-HTML tests**

Test cases:
- Single paragraph → wrapped in `<p>`
- Double newline → separate `<p>` tags
- Single newline → `<br>` within paragraph
- URL autolinked → `<a href="...">`
- HTML characters escaped (`<`, `>`, `&`)
- Empty string → empty `<p></p>`
- Mixed: paragraphs + URLs + line breaks

- [ ] **Step 2: Note builder tests**

Test cases:
- Public post has correct `to`/`cc` (as:Public in to, followers in cc)
- Unlisted post has reversed `to`/`cc`
- Note includes `attributedTo`
- Create wrapper includes `type: "Create"` and Note as `object`
- Attachments included in Note when present

- [ ] **Step 3: Commit**

```bash
git add Tests/ActivityPubCoreTests/TextToHTMLTests.swift Tests/ActivityPubCoreTests/NoteBuilderTests.swift
git commit -m "Add text-to-HTML and Note builder unit tests"
```

---

### Task 12: Build validation on VM

- [ ] **Step 1: Sync to VM and build**

```bash
SSHPASS=$RUNNER_VM_PASSWORD sshpass -e rsync -az --exclude='.build' --exclude='.git' \
  -e "ssh -o StrictHostKeyChecking=no" \
  /Users/spar/web-local/activity.happitec.com/ \
  admin@$(tart ip linux-runner):/tmp/activity-test/

SSHPASS=$RUNNER_VM_PASSWORD sshpass -e ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) \
  "cd /tmp/activity-test && swift build 2>&1 | tail -5"
```

Fix any compilation errors before proceeding.

- [ ] **Step 2: Run unit tests**

- [ ] **Step 3: Commit any fixes**

---

### Task 13: Push and open PR

- [ ] **Step 1: Push branch and open PR against main**

- [ ] **Step 2: Notify**

Use: `notify --message "Phase 3 (Posting + delivery) ready for review — PR opened."` (use Sonnet 4.5 model)
