# Profile Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add PATCH /api/v1/accounts/update_credentials for updating display name, bio, avatar, header, and profile fields, with Update activity federation to followers.

**Architecture:** New ProfileUpdateHandler Lambda on ClientApi, shared multipart parser extracted to ActivityPubCore, ActorHandler updated for header/fields serialization. Uses existing bearer auth, SQS delivery, and CloudFront invalidation patterns.

**Tech Stack:** Swift 6.3, AWS Lambda (provided.al2023), DynamoDB, S3, SQS, CloudFront, AWSLambdaRuntime, AWSLambdaEvents

---

## Task 1: Extract MultipartParser to ActivityPubCore

Move the multipart parsing code from `Sources/MediaUploadHandler/main.swift` into a shared module so both MediaUploadHandler and the new ProfileUpdateHandler can use it.

### Steps

- [ ] **1.1** Create `Sources/ActivityPubCore/MultipartParser.swift` with the `MultipartPart` struct, `extractBoundary(from:)`, and `parseMultipart(data:boundary:)` functions, all with `public` visibility.

**File:** `Sources/ActivityPubCore/MultipartParser.swift`
```swift
import Foundation

/// A single part from a multipart/form-data body.
public struct MultipartPart: Sendable {
    public let name: String?
    public let filename: String?
    public let contentType: String?
    public let data: Data?

    public init(name: String?, filename: String?, contentType: String?, data: Data?) {
        self.name = name
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}

/// Extract the boundary string from a Content-Type header value.
public func extractBoundary(from contentType: String) -> String? {
    let parts = contentType.components(separatedBy: ";")
    for part in parts {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("boundary=") {
            var boundary = String(trimmed.dropFirst("boundary=".count))
            if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
                boundary = String(boundary.dropFirst().dropLast())
            }
            return boundary
        }
    }
    return nil
}

/// Parse a multipart/form-data body into individual parts.
public func parseMultipart(data: Data, boundary: String) -> [MultipartPart] {
    let boundaryData = Data("--\(boundary)".utf8)
    let crlfData = Data("\r\n".utf8)
    let doubleCRLF = Data("\r\n\r\n".utf8)

    var parts: [MultipartPart] = []

    var ranges: [Range<Data.Index>] = []
    var searchStart = data.startIndex

    while let range = data.range(of: boundaryData, in: searchStart..<data.endIndex) {
        ranges.append(range)
        searchStart = range.upperBound
    }

    for i in 0..<(ranges.count - 1) {
        let partStart = ranges[i].upperBound
        let partEnd = ranges[i + 1].lowerBound

        var contentStart = partStart
        if contentStart + crlfData.count <= partEnd,
           data[contentStart..<contentStart + crlfData.count] == crlfData {
            contentStart += crlfData.count
        }

        var contentEnd = partEnd
        if contentEnd >= crlfData.count,
           data[contentEnd - crlfData.count..<contentEnd] == crlfData {
            contentEnd -= crlfData.count
        }

        guard contentStart < contentEnd else { continue }

        let partData = data[contentStart..<contentEnd]

        guard let headerEnd = partData.range(of: doubleCRLF) else { continue }

        let headerData = partData[partData.startIndex..<headerEnd.lowerBound]
        let bodyData = partData[headerEnd.upperBound..<partData.endIndex]

        guard let headerString = String(data: headerData, encoding: .utf8) else { continue }

        var name: String?
        var filename: String?
        var contentType: String?

        for line in headerString.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-disposition:") {
                if let nameRange = line.range(of: "name=\"") {
                    let afterName = line[nameRange.upperBound...]
                    if let endQuote = afterName.firstIndex(of: "\"") {
                        name = String(afterName[..<endQuote])
                    }
                }
                if let fnRange = line.range(of: "filename=\"") {
                    let afterFn = line[fnRange.upperBound...]
                    if let endQuote = afterFn.firstIndex(of: "\"") {
                        filename = String(afterFn[..<endQuote])
                    }
                }
            } else if lower.hasPrefix("content-type:") {
                contentType = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }

        parts.append(MultipartPart(
            name: name,
            filename: filename,
            contentType: contentType,
            data: Data(bodyData)
        ))
    }

    return parts
}
```

- [ ] **1.2** Update `Sources/MediaUploadHandler/main.swift`: remove the `MultipartPart` struct, `extractBoundary(from:)`, and `parseMultipart(data:boundary:)` functions. Add `import ActivityPubCore` (if not already present). The handler already imports ActivityPubCore for DynamoDBStore, so only the code removal is needed.

- [ ] **1.3** Build on Linux VM:
```bash
sshpass -p "$RUNNER_VM_PASSWORD" ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) \
  "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

- [ ] **1.4** Commit: "Extract MultipartParser to shared ActivityPubCore module"

---

## Task 2: Extract Bearer Token Auth to Shared Utility

The same SSM-based bearer token validation logic is duplicated in PostHandler and MediaUploadHandler. Extract it to ActivityPubCore so ProfileUpdateHandler can reuse it.

### Steps

- [ ] **2.1** Create `Sources/ActivityPubCore/BearerAuth.swift`:

**File:** `Sources/ActivityPubCore/BearerAuth.swift`
```swift
import AWSSSM
import Foundation

/// Result of bearer token authentication.
public struct BearerAuthResult: Sendable {
    public let username: String
}

/// Error type for bearer auth failures, carrying a pre-built API Gateway response status.
public enum BearerAuthError: Error, Sendable {
    case missingHeader
    case serverConfigError(String)
    case invalidToken
}

/// Validate a bearer token from an Authorization header against SSM-stored credentials.
///
/// Token format in SSM: "username:token" stored at `{ssmKeyPrefix}/client-token`.
///
/// - Parameters:
///   - authHeader: The raw Authorization header value (e.g. "Bearer abc123").
///   - ssmKeyPrefix: The SSM parameter path prefix (e.g. "/activity/stage/keys").
///   - ssmClient: An initialized SSM client.
/// - Returns: A `BearerAuthResult` containing the authenticated username.
/// - Throws: `BearerAuthError` on failure.
public func authenticateBearer(
    authHeader: String,
    ssmKeyPrefix: String,
    ssmClient: SSMClient
) async throws -> BearerAuthResult {
    guard authHeader.lowercased().hasPrefix("bearer ") else {
        throw BearerAuthError.missingHeader
    }
    let token = String(authHeader.dropFirst(7)).trimmingCharacters(in: .whitespaces)

    let tokenParamName = "\(ssmKeyPrefix)/client-token"
    let tokenOutput = try await ssmClient.getParameter(input: GetParameterInput(
        name: tokenParamName,
        withDecryption: true
    ))
    guard let storedValue = tokenOutput.parameter?.value else {
        throw BearerAuthError.serverConfigError("Client token not configured at \(tokenParamName)")
    }

    let parts = storedValue.split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else {
        throw BearerAuthError.serverConfigError("Invalid client token format in SSM")
    }
    let username = String(parts[0])
    let storedToken = String(parts[1])

    guard token == storedToken else {
        throw BearerAuthError.invalidToken
    }

    return BearerAuthResult(username: username)
}
```

- [ ] **2.2** Add `AWSSSM` as a dependency to the ActivityPubCore target in `Package.swift` (it only has AWSDynamoDB, AWSSQS, Crypto, _CryptoExtras currently).

In `Package.swift`, update the ActivityPubCore target dependencies:
```swift
.target(
    name: "ActivityPubCore",
    dependencies: [
        .product(name: "AWSDynamoDB", package: "aws-sdk-swift"),
        .product(name: "AWSSQS", package: "aws-sdk-swift"),
        .product(name: "AWSSSM", package: "aws-sdk-swift"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "_CryptoExtras", package: "swift-crypto"),
    ]
),
```

- [ ] **2.3** Update `Sources/PostHandler/main.swift`: replace the inline bearer auth block (lines 28-75) with a call to `authenticateBearer(...)`, catching `BearerAuthError` and returning appropriate responses.

- [ ] **2.4** Update `Sources/MediaUploadHandler/main.swift`: same refactor as PostHandler.

- [ ] **2.5** Build on Linux VM.

- [ ] **2.6** Commit: "Extract bearer token auth to shared BearerAuth utility"

---

## Task 3: Extract JSON Escape Helpers to ActivityPubCore

The `escapeJSONValue` / `escapeMediaJSON` / `escapeJSONString` functions are duplicated across PostHandler, MediaUploadHandler, and ActorHandler. The Note.swift module already has `escapeJSON` and `jsonString` but they are `internal`. Make them `public` so all handlers can use them.

### Steps

- [ ] **3.1** In `Sources/ActivityPubCore/Models/Note.swift`, change `escapeJSON`, `jsonString`, and `jsonArray` from `func` to `public func`.

- [ ] **3.2** Remove `escapeJSONValue` from `Sources/PostHandler/main.swift` — use `escapeJSON` from ActivityPubCore instead. Update the one call site in `buildStatusResponse` to use `escapeJSON`.

- [ ] **3.3** Remove `escapeMediaJSON` from `Sources/MediaUploadHandler/main.swift` — use `escapeJSON` from ActivityPubCore instead.

- [ ] **3.4** Remove `escapeJSONString` from `Sources/ActorHandler/main.swift` — use the public `escapeJSON` + `jsonString` from ActivityPubCore. Update `buildActorJSON` to use these.

- [ ] **3.5** Build on Linux VM.

- [ ] **3.6** Commit: "Make JSON escape helpers public in ActivityPubCore, remove duplicates"

---

## Task 4: Add `fields` and `image` (header) Support to ActorHandler

Update the Actor model to include a `fields` attribute, and update ActorHandler to serialize `image` (header) and `attachment` (PropertyValue fields) in the actor JSON-LD.

### Steps

- [ ] **4.1** Update `Sources/ActivityPubCore/Models/Actor.swift`:
  - Add `fields: String?` property (JSON-encoded string of `[{"name":"...","value":"..."}]`)
  - Update `init` with `fields: String? = nil` parameter
  - Update `fromDynamoDB` to extract `fields` from DynamoDB item

```swift
// Add to Actor struct:
public let fields: String?  // JSON-encoded: [{"name":"...","value":"..."}]

// In init, add parameter:
fields: String? = nil

// In fromDynamoDB, add after headerUrl extraction:
var fields: String?
if case .s(let f) = attributes["fields"] {
    fields = f
}
// Pass fields: fields to init
```

- [ ] **4.2** Add `Sources/ActivityPubCore/ProfileFields.swift` with a helper to format field values for actor JSON-LD (adding `rel="me"` to links):

**File:** `Sources/ActivityPubCore/ProfileFields.swift`
```swift
import Foundation

/// A profile field key-value pair.
public struct ProfileField: Codable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Format a profile field value for ActivityPub serialization.
/// URLs become `<a href="..." rel="me nofollow noopener noreferrer" target="_blank">display</a>`.
/// Non-URL values are HTML-escaped and returned as-is.
public func formatFieldValueForActivityPub(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
        let escaped = htmlEscapeField(trimmed)
        // Display text: strip scheme for cleaner display
        var display = trimmed
        if display.hasPrefix("https://") {
            display = String(display.dropFirst("https://".count))
        } else if display.hasPrefix("http://") {
            display = String(display.dropFirst("http://".count))
        }
        // Remove trailing slash for display
        if display.hasSuffix("/") {
            display = String(display.dropLast())
        }
        let escapedDisplay = htmlEscapeField(display)
        return "<a href=\"\(escaped)\" rel=\"me nofollow noopener noreferrer\" target=\"_blank\">\(escapedDisplay)</a>"
    } else {
        return htmlEscapeField(trimmed)
    }
}

/// Format a profile field value for the Mastodon API response.
/// URLs get `rel="me"` links. Non-URLs are HTML-escaped.
public func formatFieldValueForAPI(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
        let escaped = htmlEscapeField(trimmed)
        var display = trimmed
        if display.hasPrefix("https://") {
            display = String(display.dropFirst("https://".count))
        } else if display.hasPrefix("http://") {
            display = String(display.dropFirst("http://".count))
        }
        if display.hasSuffix("/") {
            display = String(display.dropLast())
        }
        let escapedDisplay = htmlEscapeField(display)
        return "<a href=\"\(escaped)\" rel=\"me\">\(escapedDisplay)</a>"
    } else {
        return htmlEscapeField(trimmed)
    }
}

/// Parse the JSON-encoded fields string from DynamoDB into ProfileField array.
public func parseProfileFields(_ json: String) -> [ProfileField] {
    guard let data = json.data(using: .utf8),
          let fields = try? JSONDecoder().decode([ProfileField].self, from: data) else {
        return []
    }
    return fields
}

/// Encode ProfileField array to JSON string for DynamoDB storage.
public func encodeProfileFields(_ fields: [ProfileField]) -> String {
    guard let data = try? JSONEncoder().encode(fields),
          let json = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return json
}

/// HTML-escape special characters for profile field values.
func htmlEscapeField(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
```

- [ ] **4.3** Update `Sources/ActorHandler/main.swift` `buildActorJSON` function to include:
  - `"image"` block for header URL (same pattern as `icon`)
  - `"attachment"` array for profile fields (PropertyValue type)

```swift
// After the existing iconBlock:
var imageBlock = ""
if let headerUrl = actor.headerUrl {
    imageBlock = """
    ,"image":{"type":"Image","url":"\(headerUrl)"}
    """
}

// Build attachment block for profile fields
var attachmentBlock = ""
if let fieldsJSON = actor.fields {
    let fields = parseProfileFields(fieldsJSON)
    if !fields.isEmpty {
        let items = fields.map { field -> String in
            let formattedValue = formatFieldValueForActivityPub(field.value)
            return "{\"type\":\"PropertyValue\",\"name\":\(jsonString(field.name)),\"value\":\(jsonString(formattedValue))}"
        }
        attachmentBlock = ",\"attachment\":[\(items.joined(separator: ","))]"
    }
}
```

Then insert `\(imageBlock)\(attachmentBlock)` into the JSON template after the `\(iconBlock)`.

- [ ] **4.4** Add unit tests in `Tests/ActivityPubCoreTests/ProfileFieldsTests.swift`:
  - Test `formatFieldValueForActivityPub` with URL and non-URL values
  - Test `formatFieldValueForAPI` with URL and non-URL values
  - Test `parseProfileFields` and `encodeProfileFields` round-trip
  - Test Actor.fromDynamoDB with fields attribute

- [ ] **4.5** Build and run tests on Linux VM:
```bash
swift build 2>&1
swift test --filter ActivityPubCoreTests 2>&1
```

- [ ] **4.6** Commit: "Add profile fields and header image to Actor model and ActorHandler"

---

## Task 5: Add ProfileUpdateHandler Lambda

The main handler: parses multipart form data, validates bearer token, uploads avatar/header to S3, updates DynamoDB, builds Update activity, fans out to followers, and invalidates CloudFront cache.

### Steps

- [ ] **5.1** Add `ProfileUpdateHandler` target to `Package.swift`:

```swift
.executable(name: "ProfileUpdateHandler", targets: ["ProfileUpdateHandler"]),
// in products array

.executableTarget(
    name: "ProfileUpdateHandler",
    dependencies: [
        "ActivityPubCore",
        .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
        .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
        .product(name: "AWSS3", package: "aws-sdk-swift"),
        .product(name: "AWSSSM", package: "aws-sdk-swift"),
        .product(name: "AWSCloudFront", package: "aws-sdk-swift"),
    ]
),
// in targets array
```

- [ ] **5.2** Create `Sources/ProfileUpdateHandler/main.swift`:

**File:** `Sources/ProfileUpdateHandler/main.swift`

The handler follows the PostHandler/MediaUploadHandler pattern:
1. Environment variables: `SERVER_DOMAIN`, `HANDLE_DOMAIN`, `MEDIA_BUCKET_NAME`, `CLOUDFRONT_DISTRIBUTION_ID`, `SSM_KEY_PREFIX`
2. Global clients: `DynamoDBStore`, `S3Client`, `SQSDeliveryClient`, `SSMClient`, `CloudFrontClient`
3. LambdaRuntime closure handling `APIGatewayRequest -> APIGatewayResponse`

Request processing flow:
1. Authenticate via `authenticateBearer(...)` from ActivityPubCore
2. Parse multipart body using `extractBoundary`/`parseMultipart` from ActivityPubCore
3. Extract optional fields: `display_name`, `note`, `avatar` (file), `header` (file), `fields_attributes[N][name]`, `fields_attributes[N][value]`
4. Validate avatar/header: max 2MB, content type must be image/png, image/jpeg, or image/gif
5. Upload avatar to S3 at `media/avatars/{username}` with correct Content-Type
6. Upload header to S3 at `media/headers/{username}` with correct Content-Type
7. Update actor in DynamoDB (only changed fields) using `updateActorProfile` (new method)
8. Fetch updated actor from DynamoDB
9. Build Mastodon-compatible account JSON response
10. Build Update activity with full actor JSON-LD as object
11. Fan out to all followers via SQS (shared inbox coalescing, same as PostHandler)
12. Invalidate CloudFront cache for actor + media paths
13. Return response

- [ ] **5.3** Add `updateActorProfile` method to `Sources/ActivityPubCore/DynamoDBStore.swift`:

```swift
/// Update an actor's profile fields. Only provided (non-nil) values are updated.
public func updateActorProfile(
    username: String,
    displayName: String?,
    summary: String?,
    avatarUrl: String?,
    headerUrl: String?,
    fields: String?
) async throws {
    var updateParts: [String] = []
    var exprNames: [String: String] = [:]
    var exprValues: [String: DynamoDBClientTypes.AttributeValue] = [:]

    if let displayName {
        updateParts.append("#dn = :dn")
        exprNames["#dn"] = "displayName"
        exprValues[":dn"] = .s(displayName)
    }
    if let summary {
        updateParts.append("#sm = :sm")
        exprNames["#sm"] = "summary"
        exprValues[":sm"] = .s(summary)
    }
    if let avatarUrl {
        updateParts.append("#au = :au")
        exprNames["#au"] = "avatarUrl"
        exprValues[":au"] = .s(avatarUrl)
    }
    if let headerUrl {
        updateParts.append("#hu = :hu")
        exprNames["#hu"] = "headerUrl"
        exprValues[":hu"] = .s(headerUrl)
    }
    if let fields {
        updateParts.append("#fl = :fl")
        exprNames["#fl"] = "fields"
        exprValues[":fl"] = .s(fields)
    }

    guard !updateParts.isEmpty else { return }

    let updateExpression = "SET " + updateParts.joined(separator: ", ")
    let input = UpdateItemInput(
        expressionAttributeNames: exprNames,
        expressionAttributeValues: exprValues,
        key: [
            "PK": .s("ACTOR#\(username)"),
            "SK": .s("PROFILE"),
        ],
        tableName: tableName,
        updateExpression: updateExpression
    )
    _ = try await client.updateItem(input: input)
}
```

- [ ] **5.4** Add `buildActorJSONLD` function to `Sources/ActivityPubCore/ActorSerializer.swift` that produces the full actor JSON-LD document (the same output as ActorHandler's `buildActorJSON`). This is needed so ProfileUpdateHandler can embed the actor document in the Update activity without importing ActorHandler. Extract the function from ActorHandler and make it shared.

**File:** `Sources/ActivityPubCore/ActorSerializer.swift`
```swift
import Foundation

/// Build the full actor JSON-LD document for ActivityPub federation.
/// Used by both ActorHandler (serving GET /users/{username}) and
/// ProfileUpdateHandler (embedding in Update activity).
public func buildActorJSONLD(
    actor: Actor,
    serverDomain: String,
    handleDomain: String
) -> String {
    let actorUrl = "https://\(serverDomain)/users/\(actor.username)"

    var iconBlock = ""
    if let avatarUrl = actor.avatarUrl {
        iconBlock = """
        ,"icon":{"type":"Image","url":"\(avatarUrl)"}
        """
    }

    var imageBlock = ""
    if let headerUrl = actor.headerUrl {
        imageBlock = """
        ,"image":{"type":"Image","url":"\(headerUrl)"}
        """
    }

    var attachmentBlock = ""
    if let fieldsJSON = actor.fields {
        let fields = parseProfileFields(fieldsJSON)
        if !fields.isEmpty {
            let items = fields.map { field -> String in
                let formattedValue = formatFieldValueForActivityPub(field.value)
                return "{\"type\":\"PropertyValue\",\"name\":\(jsonString(field.name)),\"value\":\(jsonString(formattedValue))}"
            }
            attachmentBlock = ",\"attachment\":[\(items.joined(separator: ","))]"
        }
    }

    let json = """
    {"@context":["https://www.w3.org/ns/activitystreams","https://w3id.org/security/v1",{"toot":"http://joinmastodon.org/ns#","discoverable":"toot:discoverable","indexable":"toot:indexable","featured":{"@id":"toot:featured","@type":"@id"},"featuredTags":{"@id":"toot:featuredTags","@type":"@id"},"attributionDomains":{"@id":"toot:attributionDomains","@type":"@id"},"schema":"http://schema.org#","PropertyValue":"schema:PropertyValue","value":"schema:value","manuallyApprovesFollowers":"as:manuallyApprovesFollowers","sensitive":"as:sensitive"}],"id":"\(actorUrl)","type":"Service","preferredUsername":\(jsonString(actor.username)),"name":\(jsonString(actor.displayName)),"summary":\(jsonString(actor.summary)),"inbox":"\(actorUrl)/inbox","outbox":"\(actorUrl)/outbox","followers":"\(actorUrl)/followers","following":"\(actorUrl)/following","url":"https://\(serverDomain)/@\(actor.username)"\(iconBlock)\(imageBlock)\(attachmentBlock),"publicKey":{"id":"\(actorUrl)#main-key","owner":"\(actorUrl)","publicKeyPem":\(jsonString(actor.publicKeyPem))},"discoverable":\(actor.discoverable),"indexable":false,"manuallyApprovesFollowers":\(actor.manuallyApprovesFollowers),"published":"\(actor.createdAt)","featured":"\(actorUrl)/collections/featured","featuredTags":"\(actorUrl)/collections/tags","attributionDomains":["\(handleDomain)"]}
    """
    return json.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

- [ ] **5.5** Update `Sources/ActorHandler/main.swift` to use the shared `buildActorJSONLD(...)` function from ActivityPubCore instead of its local `buildActorJSON`. Remove the local `buildActorJSON` and `escapeJSONString` functions.

- [ ] **5.6** Build on Linux VM.

- [ ] **5.7** Commit: "Add ProfileUpdateHandler Lambda with avatar/header upload and DynamoDB update"

---

## Task 6: Add Update Activity Federation and CloudFront Invalidation

Build the Update activity wrapping the full actor JSON-LD, fan out to all followers via SQS, and invalidate CloudFront cache. This is part of the ProfileUpdateHandler but is a separate logical step.

### Steps

- [ ] **6.1** The federation and invalidation logic is already included in the ProfileUpdateHandler from Task 5. This task verifies that the handler:
  - Builds an Update activity with `id: "https://{serverDomain}/users/{username}#update-{ulid}"`, `type: "Update"`, `actor: actorUrl`, `to: [Public]`, `cc: [followers]`, `object: <full actor JSON-LD>`
  - Queries all followers via `store.listAllFollowers(username:)`
  - Groups by shared inbox and enqueues via `sqsClient.enqueueBatch(jobs:)`
  - Invalidates CloudFront cache for paths: `/users/{username}`, `/.well-known/webfinger*`, `/media/avatars/{username}*`, `/media/headers/{username}*`

- [ ] **6.2** Build on Linux VM.

- [ ] **6.3** Commit (if any additional changes needed beyond Task 5): "Add Update activity federation to ProfileUpdateHandler"

---

## Task 7: SAM Template Changes

Add ProfileUpdateFunction to the SAM template.

### Steps

- [ ] **7.1** Add `ProfileUpdateFunction` resource to `activity-app/template.yaml` after `MediaUploadFunction`, following the same pattern but with additional S3, SQS, CloudFront, and SSM/KMS policies:

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
          MEDIA_BUCKET_NAME: !ImportValue
            Fn::Sub: "${EnvironmentStackName}-MediaBucketName"
      Policies:
        - DynamoDBCrudPolicy:
            TableName: !ImportValue
              Fn::Sub: "${EnvironmentStackName}-TableName"
        - Statement:
            - Effect: Allow
              Action: s3:PutObject
              Resource: !Sub
                - "${BucketArn}/*"
                - BucketArn: !ImportValue
                    Fn::Sub: "${EnvironmentStackName}-MediaBucketArn"
        - SQSSendMessagePolicy:
            QueueName: !Select [4, !Split ["/", !ImportValue { "Fn::Sub": "${EnvironmentStackName}-QueueUrl" }]]
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

- [ ] **7.2** Build on Linux VM (template changes don't affect Swift build, but verify the full build still works).

- [ ] **7.3** Commit: "Add ProfileUpdateFunction to SAM template"

---

## Task 8: Tests and Final Verification

### Steps

- [ ] **8.1** Add `Tests/ActivityPubCoreTests/MultipartParserTests.swift` with tests for:
  - `extractBoundary` with standard and quoted boundaries
  - `parseMultipart` with text fields and file fields
  - Empty body handling

- [ ] **8.2** Add `Tests/ActivityPubCoreTests/BearerAuthTests.swift` with tests for:
  - Missing/malformed Authorization header detection
  - (Note: full SSM integration tests are not possible in unit tests; test the parsing logic only)

- [ ] **8.3** Run full test suite on Linux VM:
```bash
swift test --filter ActivityPubCoreTests 2>&1
```

- [ ] **8.4** Commit: "Add unit tests for MultipartParser, BearerAuth, and ProfileFields"

---

## Build/Test Commands Reference

**Build:**
```bash
sshpass -p "$RUNNER_VM_PASSWORD" ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) \
  "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

**Test:**
```bash
sshpass -p "$RUNNER_VM_PASSWORD" ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) \
  "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift test --filter ActivityPubCoreTests 2>&1"
```

**SCP files to VM:**
```bash
scp -o StrictHostKeyChecking=no -r <local-path> admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/<remote-path>
```
