# QuoteRequest Implementation Plan (FEP-044f)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement consent-based quoting per FEP-044f / Mastodon 4.5+. Both inbound (remote servers requesting to quote our posts) and outbound (us quoting remote posts and seeking approval).

**Issue:** happitec-inc/FederatedActivityPublisher#57

**Architecture:** Extends InboxHandler (new `QuoteRequest` case + `Accept`/`Reject` of QuoteRequest), PostHandler (outbound quote flow), and Note builder (`quoteUri` property). New DynamoDB fields on Status entity. New DynamoDBStore methods. No new Lambda functions or SAM template changes.

**Tech Stack:** Swift 6.3, AWS Lambda (provided.al2023), DynamoDB, SQS, AWSLambdaRuntime, AWSLambdaEvents

> **Note for executing agents:** All SCP and build commands below use `$WORKING_DIR` as a placeholder for the local source directory. Replace it with your actual working directory (e.g., the worktree path or repo checkout path). Do NOT use hardcoded worktree paths from a previous session.

---

## Spec

### ActivityPub Wire Format

**QuoteRequest** (sent by the quoting server to the quoted post's actor inbox):
```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    {
      "QuoteRequest": "https://w3id.org/fep/044f#QuoteRequest"
    }
  ],
  "id": "https://remote.server/users/alice#quote_requests/123",
  "type": "QuoteRequest",
  "actor": "https://remote.server/users/alice",
  "object": "https://activity.happitec.com/users/logos/statuses/01JQFG1234",
  "instrument": "https://remote.server/users/alice/statuses/456"
}
```

- `object` = URI of the status being quoted (ours, for inbound)
- `instrument` = URI of the quoting status (theirs, for inbound) -- may be a bare URI string or an inline Note object
- `actor` = the account requesting to quote

**Accept** (our response when approving):
```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    {
      "QuoteRequest": "https://w3id.org/fep/044f#QuoteRequest"
    }
  ],
  "id": "https://activity.happitec.com/users/logos#accepts/quote_requests/01JQFG5678",
  "type": "Accept",
  "actor": "https://activity.happitec.com/users/logos",
  "object": {
    "id": "https://remote.server/users/alice#quote_requests/123",
    "type": "QuoteRequest",
    "actor": "https://remote.server/users/alice",
    "object": "https://activity.happitec.com/users/logos/statuses/01JQFG1234",
    "instrument": "https://remote.server/users/alice/statuses/456"
  }
}
```

**Reject** (our response when denying):
```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    {
      "QuoteRequest": "https://w3id.org/fep/044f#QuoteRequest"
    }
  ],
  "id": "https://activity.happitec.com/users/logos#rejects/quote_requests/01JQFG9012",
  "type": "Reject",
  "actor": "https://activity.happitec.com/users/logos",
  "object": {
    "id": "https://remote.server/users/alice#quote_requests/123",
    "type": "QuoteRequest",
    "actor": "https://remote.server/users/alice",
    "object": "https://activity.happitec.com/users/logos/statuses/01JQFG1234",
    "instrument": "https://remote.server/users/alice/statuses/456"
  }
}
```

**Note with quoteUri** (outbound federated Note when quote is approved):
```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    {
      "toot": "http://joinmastodon.org/ns#",
      "quoteUri": "toot:quoteUri"
    }
  ],
  "type": "Note",
  "quoteUri": "https://remote.server/users/alice/statuses/456",
  "_misskey_quote": "https://remote.server/users/alice/statuses/456"
}
```

### Quote Approval Policy

The actor document already emits `"quoteApprovalPolicy": "https://www.w3.org/ns/activitystreams#Public"` (hardcoded in `ActorSerializer.swift` since v0.3.13). The three effective policy values are:

| Policy | Meaning | Inbound behavior |
|--------|---------|-----------------|
| `public` (default) | Anyone may quote | Auto-accept all QuoteRequests (unless the actor is blocked -- blocking not yet implemented) |
| `followers` | Followers only | Auto-accept if the requesting actor is in our followers list; reject otherwise |
| `nobody` | Author only | Reject all external QuoteRequests |

Additional rules:
- Only `public` and `unlisted` statuses can be quoted (`distributable?` check). `private` and `direct` statuses always reject.
- The `quoteApprovalPolicy` is currently hardcoded to `public` on the actor. A future task can make it configurable per-actor (stored in DynamoDB on the Actor profile). This plan implements the policy check logic for all three values, defaulting to the actor-level policy.

### DynamoDB Schema Changes

The `Status` entity gains three new optional attributes:

| Attribute | Type | Description |
|-----------|------|-------------|
| `quotedStatusUri` | String (S) | URI of the remote status being quoted (set on outbound quotes) |
| `quoteApprovalState` | String (S) | `pending`, `accepted`, `rejected`, or `failed` (set on outbound quotes of remote posts; local-to-local quotes are auto-accepted; `failed` means we could not deliver the QuoteRequest) |
| `quotesCount` | Number (N) | Count of accepted inbound quotes of this status |

No new DynamoDB table, GSI, or index changes needed. These are sparse attributes on existing Status items.

---

## File Structure

### New files

```
Tests/
  ActivityPubCoreTests/
    QuoteRequestTests.swift          # Unit tests for quote approval policy logic
```

### Modified files

```
Sources/ActivityPubCore/Models/Status.swift              # Add quotedStatusUri, quoteApprovalState, quotesCount
Sources/ActivityPubCore/Models/CreateStatusRequest.swift  # Add quoted_status_id field
Sources/ActivityPubCore/Models/Note.swift                 # Add quoteUri to buildNoteJSON
Sources/ActivityPubCore/DynamoDBStore.swift               # Add isFollower, updateQuoteApprovalState, incrementQuotesCount
Sources/InboxHandler/main.swift                           # Add QuoteRequest handler, Accept/Reject of QuoteRequest
Sources/PostHandler/main.swift                            # Add outbound quote flow
```

## Build and Test Commands

Build (on linux-runner VM):
```bash
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

SCP files first (the VM cannot git fetch this worktree):
```bash
sshpass -p admin scp -o StrictHostKeyChecking=no -r $WORKING_DIR/Sources admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Sources
sshpass -p admin scp -o StrictHostKeyChecking=no -r $WORKING_DIR/Tests admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Tests
```

Test (on linux-runner VM):
```bash
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift test --filter QuoteRequestTests 2>&1"
```

---

## Task 1: Status Model -- Add Quote Fields

**Files:** `Sources/ActivityPubCore/Models/Status.swift`

**Dependencies:** None. Start here -- all subsequent tasks depend on the updated model.

### Steps

- [ ] **1a. Add three new properties to `Status` struct**

Add `quotedStatusUri`, `quoteApprovalState`, and `quotesCount` to the struct, init, `fromDynamoDB`, and `toDynamoDB`.

In `Sources/ActivityPubCore/Models/Status.swift`, add three properties after `repliesCount`:

```swift
    /// URI of the remote status being quoted by this status, if any.
    public let quotedStatusUri: String?
    /// Quote approval state for outbound quotes: `pending`, `accepted`, `rejected`, or `failed`.
    public let quoteApprovalState: String?
    /// Number of accepted inbound quotes of this status.
    public let quotesCount: Int
```

Update the `init` signature -- add the three new parameters with defaults after `repliesCount`:

```swift
    public init(
        id: String, username: String, content: String, contentWarning: String?,
        visibility: String, sensitive: Bool, language: String?,
        published: String, url: String, uri: String,
        to: [String], cc: [String], tags: [Tag]?,
        attachments: [MediaAttachmentRef]?, inReplyTo: String?,
        likesCount: Int = 0, boostsCount: Int = 0, repliesCount: Int = 0,
        quotedStatusUri: String? = nil, quoteApprovalState: String? = nil,
        quotesCount: Int = 0
    ) {
        self.id = id
        self.username = username
        self.content = content
        self.contentWarning = contentWarning
        self.visibility = visibility
        self.sensitive = sensitive
        self.language = language
        self.published = published
        self.url = url
        self.uri = uri
        self.to = to
        self.cc = cc
        self.tags = tags
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.likesCount = likesCount
        self.boostsCount = boostsCount
        self.repliesCount = repliesCount
        self.quotedStatusUri = quotedStatusUri
        self.quoteApprovalState = quoteApprovalState
        self.quotesCount = quotesCount
    }
```

- [ ] **1b. Update `fromDynamoDB` to read the new fields**

Add these lines after the existing `repliesCount` extraction (before the `return Status(...)` call):

```swift
        var quotedStatusUri: String?
        if case .s(let qs) = attributes["quotedStatusUri"] {
            quotedStatusUri = qs
        }

        var quoteApprovalState: String?
        if case .s(let qa) = attributes["quoteApprovalState"] {
            quoteApprovalState = qa
        }

        var quotesCount = 0
        if case .n(let n) = attributes["quotesCount"], let v = Int(n) { quotesCount = v }
```

And update the `return Status(...)` call to include the new fields:

```swift
        return Status(
            id: id, username: username, content: content, contentWarning: contentWarning,
            visibility: visibility, sensitive: sensitive, language: language,
            published: published, url: url, uri: uri,
            to: to, cc: cc, tags: tags,
            attachments: attachments, inReplyTo: inReplyTo,
            likesCount: likesCount, boostsCount: boostsCount, repliesCount: repliesCount,
            quotedStatusUri: quotedStatusUri, quoteApprovalState: quoteApprovalState,
            quotesCount: quotesCount
        )
```

- [ ] **1c. Update `toDynamoDB` to write the new fields**

Add these lines after the existing `inReplyTo` serialization block (inside `toDynamoDB()`):

```swift
        if let quotedStatusUri {
            item["quotedStatusUri"] = .s(quotedStatusUri)
        }
        if let quoteApprovalState {
            item["quoteApprovalState"] = .s(quoteApprovalState)
        }
        if quotesCount > 0 {
            item["quotesCount"] = .n(String(quotesCount))
        }
```

- [ ] **1d. SCP to VM and verify build succeeds**

```bash
sshpass -p admin scp -o StrictHostKeyChecking=no -r $WORKING_DIR/Sources admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Sources
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

All existing callers of `Status.init(...)` omit these new parameters, so they get the defaults. No breakage expected.

---

## Task 2: DynamoDB Store -- New Methods for Quote Flow

**Files:** `Sources/ActivityPubCore/DynamoDBStore.swift`

**Dependencies:** Task 1 (Status model changes must be in place).

### Steps

- [ ] **2a. Add `isFollower(username:actorUri:)` method**

This does a point read on `PK=ACTOR#{username}, SK=FOLLOWER#{actorUri}` and returns a Bool. Add this in the `// MARK: - Follower Storage` section, after `removeFollower`:

```swift
    /// Check if a remote actor is a follower of the given local actor.
    /// Uses a point read on the follower record -- no scan required.
    public func isFollower(username: String, actorUri: String) async throws -> Bool {
        let input = GetItemInput(
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("FOLLOWER#\(actorUri)"),
            ],
            projectionExpression: "PK",
            tableName: tableName
        )
        let output = try await client.getItem(input: input)
        return output.item != nil
    }
```

- [ ] **2b. Add `updateQuoteApprovalState(username:statusId:state:)` method**

Atomically updates the `quoteApprovalState` attribute on an existing status record. Add this in the `// MARK: - Status Storage` section:

```swift
    /// Atomically update the quote approval state on a status.
    /// Used when receiving Accept/Reject of our outbound QuoteRequest.
    public func updateQuoteApprovalState(
        username: String,
        statusId: String,
        state: String
    ) async throws {
        let input = UpdateItemInput(
            expressionAttributeNames: ["#qa": "quoteApprovalState"],
            expressionAttributeValues: [":state": .s(state)],
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("STATUS#\(statusId)"),
            ],
            tableName: tableName,
            updateExpression: "SET #qa = :state"
        )
        _ = try await client.updateItem(input: input)
    }
```

- [ ] **2c. Add `incrementQuotesCount(username:statusId:)` method**

Atomically increments the `quotesCount` on a status. Used when we accept an inbound QuoteRequest:

```swift
    /// Atomically increment the quotes count for a status.
    public func incrementQuotesCount(username: String, statusId: String, by amount: Int = 1) async throws {
        let input = UpdateItemInput(
            expressionAttributeNames: ["#qc": "quotesCount"],
            expressionAttributeValues: [":val": .n(String(amount)), ":zero": .n("0")],
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("STATUS#\(statusId)"),
            ],
            tableName: tableName,
            updateExpression: "SET #qc = if_not_exists(#qc, :zero) + :val"
        )
        _ = try await client.updateItem(input: input)
    }
```

- [ ] **2d. Add `findStatusByUri(username:uri:)` method**

Look up a status by its `uri` attribute. This is needed for inbound QuoteRequest handling where we receive the quoted status URI and need to find the status record. Since `uri` is not a key, this queries the main table with a filter expression. For our single-actor use case with modest status counts, this is acceptable. A GSI on `uri` could be added later if needed.

```swift
    /// Find a status by its ActivityPub URI.
    /// Queries statuses for the given username and filters by URI.
    /// Returns nil if not found.
    ///
    /// Note: DynamoDB `Limit` limits items *evaluated*, not items *returned*.
    /// With a `FilterExpression`, `limit: 1` would evaluate only one item and
    /// return nothing if that item doesn't match the filter. We omit the limit
    /// entirely and take the first matching result in code.
    public func findStatusByUri(username: String, uri: String) async throws -> Status? {
        let input = QueryInput(
            expressionAttributeNames: [
                "#pk": "PK",
                "#sk": "SK",
                "#uri": "uri",
            ],
            expressionAttributeValues: [
                ":pk": .s("ACTOR#\(username)"),
                ":prefix": .s("STATUS#"),
                ":uri": .s(uri),
            ],
            filterExpression: "#uri = :uri",
            keyConditionExpression: "#pk = :pk AND begins_with(#sk, :prefix)",
            tableName: tableName
        )
        let output = try await client.query(input: input)
        guard let items = output.items, let first = items.first else { return nil }
        return Status.fromDynamoDB(first)
    }
```

- [ ] **2e. SCP to VM and verify build succeeds**

```bash
sshpass -p admin scp -o StrictHostKeyChecking=no -r $WORKING_DIR/Sources admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Sources
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

---

## Task 3: InboxHandler -- Handle Inbound QuoteRequest (TDD)

**Files:** `Sources/InboxHandler/main.swift`, `Tests/ActivityPubCoreTests/QuoteRequestTests.swift`

**Dependencies:** Task 1, Task 2.

### Steps

- [ ] **3a. Write unit tests for quote approval policy logic**

Create `Tests/ActivityPubCoreTests/QuoteRequestTests.swift`. The policy logic will be a pure function in ActivityPubCore that we can test without Lambda dependencies. The function signature:

```swift
/// Determine whether an inbound QuoteRequest should be accepted or rejected.
/// Returns `true` to accept, `false` to reject.
public func shouldAcceptQuoteRequest(
    quotedStatusVisibility: String,
    quoteApprovalPolicy: String,
    isFollower: Bool
) -> Bool
```

Test file:

```swift
import Testing
@testable import ActivityPubCore

@Suite("QuoteRequest Approval Policy")
struct QuoteRequestTests {

    // MARK: - Public policy

    @Test("Public policy accepts any actor for public status")
    func publicPolicyPublicStatus() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "public",
            quoteApprovalPolicy: "public",
            isFollower: false
        ) == true)
    }

    @Test("Public policy accepts any actor for unlisted status")
    func publicPolicyUnlistedStatus() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "unlisted",
            quoteApprovalPolicy: "public",
            isFollower: false
        ) == true)
    }

    @Test("Public policy rejects private status")
    func publicPolicyPrivateStatus() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "private",
            quoteApprovalPolicy: "public",
            isFollower: false
        ) == false)
    }

    @Test("Public policy rejects direct status")
    func publicPolicyDirectStatus() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "direct",
            quoteApprovalPolicy: "public",
            isFollower: false
        ) == false)
    }

    // MARK: - Followers policy

    @Test("Followers policy accepts follower for public status")
    func followersPolicyAcceptsFollower() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "public",
            quoteApprovalPolicy: "followers",
            isFollower: true
        ) == true)
    }

    @Test("Followers policy rejects non-follower for public status")
    func followersPolicyRejectsNonFollower() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "public",
            quoteApprovalPolicy: "followers",
            isFollower: false
        ) == false)
    }

    @Test("Followers policy rejects follower for private status")
    func followersPolicyRejectsPrivateStatus() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "private",
            quoteApprovalPolicy: "followers",
            isFollower: true
        ) == false)
    }

    // MARK: - Nobody policy

    @Test("Nobody policy rejects everyone")
    func nobodyPolicyRejectsAll() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "public",
            quoteApprovalPolicy: "nobody",
            isFollower: true
        ) == false)
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "public",
            quoteApprovalPolicy: "nobody",
            isFollower: false
        ) == false)
    }

    // MARK: - Unknown policy defaults to nobody

    @Test("Unknown policy defaults to reject")
    func unknownPolicyRejects() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "public",
            quoteApprovalPolicy: "some_future_value",
            isFollower: true
        ) == false)
    }
}
```

- [ ] **3b. Implement the policy function**

Create a new file `Sources/ActivityPubCore/QuoteApproval.swift` (or add to an existing utility file). This is a pure function, no DynamoDB dependency:

```swift
import Foundation

/// Determine whether an inbound QuoteRequest should be accepted or rejected.
///
/// Checks status visibility (only public/unlisted are quotable) and the actor's
/// `quoteApprovalPolicy` setting against the requesting actor's follower status.
///
/// - Parameters:
///   - quotedStatusVisibility: The visibility of the status being quoted (`public`, `unlisted`, `private`, `direct`).
///   - quoteApprovalPolicy: The quoted actor's policy: `public`, `followers`, or `nobody`.
///   - isFollower: Whether the requesting actor is a follower of the quoted actor.
/// - Returns: `true` if the quote should be accepted, `false` if rejected.
public func shouldAcceptQuoteRequest(
    quotedStatusVisibility: String,
    quoteApprovalPolicy: String,
    isFollower: Bool
) -> Bool {
    // Only public and unlisted statuses can be quoted (distributable check)
    guard quotedStatusVisibility == "public" || quotedStatusVisibility == "unlisted" else {
        return false
    }

    switch quoteApprovalPolicy {
    case "public":
        return true
    case "followers":
        return isFollower
    case "nobody":
        return false
    default:
        // Unknown policy -- default to restrictive (reject)
        return false
    }
}
```

- [ ] **3c. SCP to VM, run tests, verify they pass**

```bash
sshpass -p admin scp -o StrictHostKeyChecking=no -r $WORKING_DIR/Sources $WORKING_DIR/Tests admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift test --filter QuoteRequestTests 2>&1"
```

- [ ] **3d. Add `QuoteRequest` case to InboxHandler switch statement**

In `Sources/InboxHandler/main.swift`, add a new case in the `switch activityType` block. Place it before the existing `case "Accept", "Reject", ...` stub handler:

```swift
        case "QuoteRequest":
            let activityId = json["id"] as? String
            return try await handleQuoteRequest(
                json: json,
                username: username,
                actorUri: actorUri,
                activityId: activityId,
                context: context
            )
```

- [ ] **3e. Implement `handleQuoteRequest` function**

Add this function to `Sources/InboxHandler/main.swift` after the existing handler functions (e.g., after `handleDelete`):

```swift
// MARK: - QuoteRequest Handling

func handleQuoteRequest(
    json: [String: Any],
    username: String,
    actorUri: String,
    activityId: String?,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    context.logger.info("Processing QuoteRequest from \(actorUri) for \(username)")

    // Extract the quoted status URI from `object` field
    let quotedStatusUri: String
    if let objectStr = json["object"] as? String {
        quotedStatusUri = objectStr
    } else if let objectDict = json["object"] as? [String: Any],
              let objectId = objectDict["id"] as? String {
        quotedStatusUri = objectId
    } else {
        context.logger.warning("QuoteRequest missing object URI from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Missing object in QuoteRequest"}"#
        )
    }

    // Extract the quoting status URI from `instrument` field
    let quotingStatusUri: String
    if let instrumentStr = json["instrument"] as? String {
        quotingStatusUri = instrumentStr
    } else if let instrumentDict = json["instrument"] as? [String: Any],
              let instrumentId = instrumentDict["id"] as? String {
        quotingStatusUri = instrumentId
    } else {
        context.logger.warning("QuoteRequest missing instrument URI from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Missing instrument in QuoteRequest"}"#
        )
    }

    // Parse the quoted status URI to find our local status
    guard let parsed = parseStatusUri(quotedStatusUri) else {
        context.logger.info("QuoteRequest for non-local status \(quotedStatusUri) from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Verify the quoted status exists
    guard let quotedStatus = try await store.getStatus(username: parsed.username, id: parsed.statusId) else {
        context.logger.warning("QuoteRequest for non-existent status \(quotedStatusUri) from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Check follower status for policy evaluation
    let follower = try await store.isFollower(username: parsed.username, actorUri: actorUri)

    // Determine the actor's quote approval policy
    // For now, hardcoded to "public" (matches ActorSerializer). When per-actor policy
    // is stored in DynamoDB, read it from the actor profile here instead.
    let quoteApprovalPolicy = "public"

    // Evaluate policy
    let accepted = shouldAcceptQuoteRequest(
        quotedStatusVisibility: quotedStatus.visibility,
        quoteApprovalPolicy: quoteApprovalPolicy,
        isFollower: follower
    )

    // Build the response activity (Accept or Reject)
    let ulid = store.generateULID()
    let responseType = accepted ? "Accept" : "Reject"
    let fragmentPath = accepted ? "accepts" : "rejects"
    let responseId = "https://\(serverDomain)/users/\(username)#\(fragmentPath)/quote_requests/\(ulid)"

    // Echo the full original QuoteRequest (including its `id`) as the object
    // of our Accept/Reject so the remote server can correlate this response.
    var quoteRequestObject: [String: Any] = [
        "type": "QuoteRequest",
        "actor": actorUri,
        "object": quotedStatusUri,
        "instrument": quotingStatusUri,
    ]
    if let activityId {
        quoteRequestObject["id"] = activityId
    }

    // The @context must include the FEP-044f extension since the object body
    // contains `"type": "QuoteRequest"`.
    let responseActivity: [String: Any] = [
        "@context": [
            "https://www.w3.org/ns/activitystreams",
            ["QuoteRequest": "https://w3id.org/fep/044f#QuoteRequest"]
        ] as [Any],
        "id": responseId,
        "type": responseType,
        "actor": "https://\(serverDomain)/users/\(username)",
        "object": quoteRequestObject,
    ]

    let responseData = try JSONSerialization.data(withJSONObject: responseActivity)
    guard let responseJSON = String(data: responseData, encoding: .utf8) else {
        throw InboxError.encodingFailed
    }

    // Resolve the remote actor's inbox for delivery.
    // First check our local cache, then try fetching the actor profile if not cached.
    var targetInbox: String?
    let remoteActor = try await store.getRemoteActor(actorUri: actorUri)
    targetInbox = remoteActor?.inbox

    if targetInbox == nil {
        // Actor not in cache -- try fetching their profile directly
        do {
            let actorObject = try await fetchRemoteObject(uri: actorUri)
            targetInbox = actorObject["inbox"] as? String
        } catch {
            context.logger.error("Failed to fetch remote actor \(actorUri): \(error)")
        }
    }

    guard let targetInbox else {
        context.logger.error("Cannot resolve inbox for \(actorUri) to deliver \(responseType) -- response will not be delivered")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Enqueue delivery
    let job = DeliveryJob(
        targetInbox: targetInbox,
        activityJSON: responseJSON,
        actorUsername: username
    )
    try await sqsClient.enqueue(job: job)

    // If accepted, increment the quotes count on the quoted status
    if accepted {
        try await store.incrementQuotesCount(username: parsed.username, statusId: parsed.statusId)
    }

    context.logger.info("QuoteRequest \(accepted ? "accepted" : "rejected") from \(actorUri) for \(quotedStatusUri), \(responseType) enqueued to \(targetInbox)")

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}
```

- [ ] **3f. SCP to VM and verify build succeeds**

```bash
sshpass -p admin scp -o StrictHostKeyChecking=no -r $WORKING_DIR/Sources admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Sources
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

---

## Task 4: InboxHandler -- Handle Accept/Reject of Our Outbound QuoteRequest

**Files:** `Sources/InboxHandler/main.swift`

**Dependencies:** Task 1, Task 2.

### Steps

- [ ] **4a. Replace the stub `Accept`/`Reject` handler with real logic**

Currently the InboxHandler has:
```swift
case "Accept", "Reject", "Block", "Move", "Add", "Remove", "Flag":
    let objectUri = extractObjectUri(from: json) ?? "unknown"
    context.logger.info("Stub handler: \(activityType) from \(actorUri), object=\(objectUri)")
```

Split `Accept` and `Reject` out of this combined case into their own handler. The remaining types stay as stubs:

```swift
        case "Accept":
            return try await handleAcceptActivity(
                json: json,
                username: username,
                actorUri: actorUri,
                context: context
            )

        case "Reject":
            return try await handleRejectActivity(
                json: json,
                username: username,
                actorUri: actorUri,
                context: context
            )

        case "Block", "Move", "Add", "Remove", "Flag":
            let objectUri = extractObjectUri(from: json) ?? "unknown"
            context.logger.info("Stub handler: \(activityType) from \(actorUri), object=\(objectUri)")
            return APIGatewayResponse(
                statusCode: .accepted,
                headers: ["content-type": "application/json"],
                body: #"{"status":"accepted"}"#
            )
```

- [ ] **4b. Implement `handleAcceptActivity`**

This function checks if the accepted object is a QuoteRequest (by inspecting `object.type`). If so, it finds our local status that initiated the quote and updates its `quoteApprovalState` to `accepted`.

```swift
// MARK: - Accept Handling

func handleAcceptActivity(
    json: [String: Any],
    username: String,
    actorUri: String,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    // Extract the inner object to determine what is being accepted
    guard let objectDict = json["object"] as? [String: Any],
          let objectType = objectDict["type"] as? String else {
        // Object might be a bare URI (e.g., Accept of Follow) -- log and accept
        let objectUri = extractObjectUri(from: json) ?? "unknown"
        context.logger.info("Accept (non-inline object) from \(actorUri), object=\(objectUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    if objectType == "QuoteRequest" {
        return try await handleAcceptQuoteRequest(
            objectDict: objectDict,
            username: username,
            actorUri: actorUri,
            context: context
        )
    }

    // Other Accept types (e.g., Accept of Follow -- already handled by Follow flow)
    context.logger.info("Accept of \(objectType) from \(actorUri)")
    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}

func handleAcceptQuoteRequest(
    objectDict: [String: Any],
    username: String,
    actorUri: String,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    context.logger.info("Processing Accept of QuoteRequest from \(actorUri) for \(username)")

    // The `instrument` in the QuoteRequest is our quoting status URI.
    // Extract it to find which of our statuses to update.
    let quotingStatusUri: String
    if let instrumentStr = objectDict["instrument"] as? String {
        quotingStatusUri = instrumentStr
    } else if let instrumentDict = objectDict["instrument"] as? [String: Any],
              let instrumentId = instrumentDict["id"] as? String {
        quotingStatusUri = instrumentId
    } else {
        context.logger.warning("Accept QuoteRequest missing instrument from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Parse our status URI from the instrument
    guard let parsed = parseStatusUri(quotingStatusUri) else {
        context.logger.warning("Accept QuoteRequest instrument is not our status: \(quotingStatusUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Update the quote approval state to accepted
    try await store.updateQuoteApprovalState(
        username: parsed.username,
        statusId: parsed.statusId,
        state: "accepted"
    )

    // Re-federate: send an Update activity for our quoting Note to all followers.
    // The Note now includes `quoteUri` (which was withheld while the quote was pending).
    if let updatedStatus = try await store.getStatus(username: parsed.username, id: parsed.statusId) {
        let noteJSON = buildNoteJSON(status: updatedStatus, serverDomain: serverDomain)
        let updateId = "https://\(serverDomain)/users/\(parsed.username)#updates/\(store.generateULID())"
        let updateActivity: [String: Any] = [
            "@context": "https://www.w3.org/ns/activitystreams",
            "id": updateId,
            "type": "Update",
            "actor": "https://\(serverDomain)/users/\(parsed.username)",
            "object": noteJSON,
        ]
        let updateData = try JSONSerialization.data(withJSONObject: updateActivity)
        if let updateJSON = String(data: updateData, encoding: .utf8) {
            // Fan out Update to all followers so they see the quoteUri
            let followers = try await store.getFollowers(username: parsed.username)
            for follower in followers {
                if let inbox = follower.inbox {
                    let job = DeliveryJob(
                        targetInbox: inbox,
                        activityJSON: updateJSON,
                        actorUsername: parsed.username
                    )
                    try await sqsClient.enqueue(job: job)
                }
            }
            context.logger.info("Update activity for status \(parsed.statusId) enqueued to \(followers.count) followers")
        }
    }

    context.logger.info("Quote approval accepted for status \(parsed.statusId) by \(actorUri)")

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}
```

- [ ] **4c. Implement `handleRejectActivity`**

Same structure as Accept but sets state to `rejected`:

```swift
// MARK: - Reject Handling

func handleRejectActivity(
    json: [String: Any],
    username: String,
    actorUri: String,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    guard let objectDict = json["object"] as? [String: Any],
          let objectType = objectDict["type"] as? String else {
        let objectUri = extractObjectUri(from: json) ?? "unknown"
        context.logger.info("Reject (non-inline object) from \(actorUri), object=\(objectUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    if objectType == "QuoteRequest" {
        return try await handleRejectQuoteRequest(
            objectDict: objectDict,
            username: username,
            actorUri: actorUri,
            context: context
        )
    }

    context.logger.info("Reject of \(objectType) from \(actorUri)")
    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}

func handleRejectQuoteRequest(
    objectDict: [String: Any],
    username: String,
    actorUri: String,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    context.logger.info("Processing Reject of QuoteRequest from \(actorUri) for \(username)")

    let quotingStatusUri: String
    if let instrumentStr = objectDict["instrument"] as? String {
        quotingStatusUri = instrumentStr
    } else if let instrumentDict = objectDict["instrument"] as? [String: Any],
              let instrumentId = instrumentDict["id"] as? String {
        quotingStatusUri = instrumentId
    } else {
        context.logger.warning("Reject QuoteRequest missing instrument from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    guard let parsed = parseStatusUri(quotingStatusUri) else {
        context.logger.warning("Reject QuoteRequest instrument is not our status: \(quotingStatusUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    try await store.updateQuoteApprovalState(
        username: parsed.username,
        statusId: parsed.statusId,
        state: "rejected"
    )

    context.logger.info("Quote approval rejected for status \(parsed.statusId) by \(actorUri)")

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}
```

- [ ] **4d. SCP to VM and verify build succeeds**

```bash
sshpass -p admin scp -o StrictHostKeyChecking=no -r $WORKING_DIR/Sources admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Sources
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

---

## Task 5: Note Builder -- Add `quoteUri` Property

**Files:** `Sources/ActivityPubCore/Models/Note.swift`

**Dependencies:** Task 1 (Status model has `quotedStatusUri` and `quoteApprovalState`).

### Steps

- [ ] **5a. Update `buildNoteJSON` to emit `quoteUri` when approved**

In `Sources/ActivityPubCore/Models/Note.swift`, add quote URI handling after the existing `contentMapJSON` block and before the final JSON string construction. The `quoteUri` is only included when the quote is approved (or when quoting a local post, which is auto-approved).

Add this block after `var contentMapJSON = ""` / `if let lang = ...` block:

```swift
    // Quote URI -- only include when quote is accepted (or local-to-local)
    var quoteJSON = ""
    if let quotedUri = status.quotedStatusUri {
        // Use a proper URL prefix check (not substring `contains`) to determine
        // if the quoted status is local. A `contains` check is fragile -- the
        // domain could appear as a substring in a remote URI.
        let isLocalQuote = quotedUri.hasPrefix("https://\(serverDomain)/")

        // Emit quoteUri when:
        // - The quote is explicitly accepted (remote quote, approval received)
        // - The quote is local-to-local (quoteApprovalState is nil, always approved)
        if status.quoteApprovalState == "accepted" || (isLocalQuote && status.quoteApprovalState == nil) {
            quoteJSON = ",\"quoteUri\":\(jsonString(quotedUri)),\"_misskey_quote\":\(jsonString(quotedUri))"
        }
    }
```

Then update the Note JSON template string to include `quoteJSON`. In the existing JSON construction line:

```swift
    let json = """
    {"@context":["https://www.w3.org/ns/activitystreams",{"Hashtag":"as:Hashtag","sensitive":"as:sensitive","blurhash":"toot:blurhash","focalPoint":{"@container":"@list","@id":"toot:focalPoint"},"toot":"http://joinmastodon.org/ns#","quoteUri":"toot:quoteUri"}],"id":"\(statusUrl)","type":"Note","attributedTo":"\(actorUrl)","content":\(jsonString(status.content)),"url":"\(escapeJSON(status.url))","published":"\(escapeJSON(status.published))","to":\(toJSON),"cc":\(ccJSON),"sensitive":\(status.sensitive)\(summaryJSON)\(contentMapJSON)\(quoteJSON)\(attachmentJSON)\(tagJSON)}
    """
```

Note the two changes to the context:
1. Added `"quoteUri":"toot:quoteUri"` to the context object (this was already in the context extension list in the actor document, but must also be in Note context for the property to be recognized)

- [ ] **5b. SCP to VM and verify build succeeds**

```bash
sshpass -p admin scp -o StrictHostKeyChecking=no -r $WORKING_DIR/Sources admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Sources
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

---

## Task 6: CreateStatusRequest -- Add `quoted_status_id` Field

**Files:** `Sources/ActivityPubCore/Models/CreateStatusRequest.swift`

**Dependencies:** None (pure model change).

### Steps

- [ ] **6a. Add `quotedStatusId` property**

In `Sources/ActivityPubCore/Models/CreateStatusRequest.swift`, add the new field:

After `public let inReplyToId: String?`:
```swift
    /// ID of the status being quoted (Mastodon 4.5+ API).
    public let quotedStatusId: String?
```

Add the CodingKey:
```swift
        case quotedStatusId = "quoted_status_id"
```

Update the `init`:
```swift
    public init(
        status: String, mediaIds: [String]? = nil, sensitive: Bool? = nil,
        spoilerText: String? = nil, visibility: String? = nil,
        language: String? = nil, inReplyToId: String? = nil,
        quotedStatusId: String? = nil
    ) {
        self.status = status
        self.mediaIds = mediaIds
        self.sensitive = sensitive
        self.spoilerText = spoilerText
        self.visibility = visibility
        self.language = language
        self.inReplyToId = inReplyToId
        self.quotedStatusId = quotedStatusId
    }
```

- [ ] **6b. SCP to VM and verify build succeeds**

```bash
sshpass -p admin scp -o StrictHostKeyChecking=no -r $WORKING_DIR/Sources admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Sources
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

---

## Task 7: PostHandler -- Outbound Quote Flow

**Files:** `Sources/PostHandler/main.swift`

**Dependencies:** Tasks 1, 2, 5, 6.

### Steps

- [ ] **7a. Add quote resolution after media attachment lookup**

In `Sources/PostHandler/main.swift`, after the media attachment lookup block (step 7 in the existing code, around line 139) and before the status construction (step 8), add the quote resolution logic:

```swift
        // 7.5. Resolve quoted status if quoting
        var quotedStatusUri: String?
        var quoteApprovalState: String?
        var quotedActorInbox: String?

        if let quotedId = request.quotedStatusId, !quotedId.isEmpty {
            // Look up the quoted status -- could be local or remote
            // First try as a local status ID
            if let quotedStatus = try await store.getStatus(username: username, id: quotedId) {
                // Local-to-local quote: auto-approved, no QuoteRequest needed
                quotedStatusUri = quotedStatus.uri
                // quoteApprovalState stays nil -- local quotes don't need approval tracking
            } else {
                // The quotedStatusId is a URI for a remote status.
                // Store as pending -- QuoteRequest will be sent below.
                quotedStatusUri = quotedId
                quoteApprovalState = "pending"

                // Fetch the remote status object to discover the actor via `attributedTo`.
                // We cannot guess the actor URI from the status URI path because different
                // server software uses different formats:
                //   Mastodon: /users/{name}/statuses/{id}
                //   Misskey:  /users/{id}
                //   GoToSocial: /@{name}/statuses/{id}
                //   Lemmy:    /post/{id}
                // Instead, dereference the status URI and read `attributedTo`.
                do {
                    let remoteStatusObject = try await fetchRemoteObject(uri: quotedId)
                    if let attributedTo = remoteStatusObject["attributedTo"] as? String {
                        // Try our local cache first
                        let remoteActor = try await store.getRemoteActor(actorUri: attributedTo)
                        if let actor = remoteActor {
                            quotedActorInbox = actor.inbox
                        } else {
                            // Actor not in cache -- fetch their profile to get the inbox
                            let actorObject = try await fetchRemoteObject(uri: attributedTo)
                            if let inbox = actorObject["inbox"] as? String {
                                quotedActorInbox = inbox
                            }
                        }
                    }
                } catch {
                    context.logger.error("Failed to fetch remote status \(quotedId) for QuoteRequest: \(error)")
                }

                // If we still don't have an inbox, the QuoteRequest cannot be delivered.
                // Mark the quote as `failed` rather than leaving it silently `pending`.
                if quotedActorInbox == nil {
                    context.logger.error("Cannot determine inbox for quoted status \(quotedId) -- marking quote as failed")
                    quoteApprovalState = "failed"
                }
            }
        }
```

- [ ] **7b. Update status construction to include quote fields**

Update the `Status(...)` constructor call (step 8) to pass the new quote fields:

```swift
        let status = Status(
            id: statusId,
            username: username,
            content: htmlContent,
            contentWarning: request.spoilerText,
            visibility: visibility,
            sensitive: request.sensitive ?? false,
            language: request.language,
            published: published,
            url: statusUrl,
            uri: statusUri,
            to: addressing.to,
            cc: addressing.cc,
            tags: nil,
            attachments: attachments,
            inReplyTo: request.inReplyToId,
            likesCount: 0,
            boostsCount: 0,
            repliesCount: 0,
            quotedStatusUri: quotedStatusUri,
            quoteApprovalState: quoteApprovalState
        )
```

- [ ] **7c. Add QuoteRequest delivery after follower fan-out**

After the follower delivery fan-out (step 12) and before the CloudFront invalidation (step 13), add the QuoteRequest delivery:

```swift
        // 12.5. Send QuoteRequest if quoting a remote post
        if let quotedUri = quotedStatusUri,
           quoteApprovalState == "pending",
           let targetInbox = quotedActorInbox {
            // Build the QuoteRequest activity
            let quoteRequestId = "https://\(serverDomain)/users/\(username)#quote_requests/\(statusId)"
            let quoteRequest: [String: Any] = [
                "@context": [
                    "https://www.w3.org/ns/activitystreams",
                    ["QuoteRequest": "https://w3id.org/fep/044f#QuoteRequest"]
                ] as [Any],
                "id": quoteRequestId,
                "type": "QuoteRequest",
                "actor": "https://\(serverDomain)/users/\(username)",
                "object": quotedUri,
                "instrument": statusUri,
            ] as [String: Any]

            let quoteRequestData = try JSONSerialization.data(withJSONObject: quoteRequest)
            guard let quoteRequestJSON = String(data: quoteRequestData, encoding: .utf8) else {
                throw PostError.encodingFailed
            }

            let quoteJob = DeliveryJob(
                targetInbox: targetInbox,
                activityJSON: quoteRequestJSON,
                actorUsername: username
            )
            try await sqsClient.enqueue(job: quoteJob)

            context.logger.info("QuoteRequest enqueued for \(quotedUri) to \(targetInbox)")
        }
```

- [ ] **7d. Add `PostError` enum if not already present**

At the bottom of `Sources/PostHandler/main.swift`, before `try await runtime.run()`, add:

```swift
enum PostError: Error {
    case encodingFailed
}
```

- [ ] **7e. SCP to VM and verify build succeeds**

```bash
sshpass -p admin scp -o StrictHostKeyChecking=no -r $WORKING_DIR/Sources admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Sources
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

---

## Task 8: Status Response -- Include Quote Fields in API Response

**Files:** `Sources/PostHandler/main.swift`

**Dependencies:** Task 1 (Status model changes).

### Steps

- [ ] **8a. Update `buildStatusResponse` to include quote fields**

In `Sources/PostHandler/main.swift`, update the `buildStatusResponse` function to include the new fields in the JSON output. After the existing `replyTo` line:

```swift
    let quotedUri = status.quotedStatusUri.map { "\"\(escapeJSON($0))\"" } ?? "null"
    let quoteState = status.quoteApprovalState.map { "\"\(escapeJSON($0))\"" } ?? "null"
```

Then add these fields to the JSON response string, before the closing `}`:

```
,"quoted_status_uri":\(quotedUri),"quote_approval_state":\(quoteState),"quotes_count":\(status.quotesCount)
```

The full return statement becomes:
```swift
    return """
    {"id":"\(status.id)","created_at":"\(escapeJSON(status.published))","visibility":"\(status.visibility)","sensitive":\(status.sensitive),"spoiler_text":\(cw),"content":"\(escapeJSON(status.content))","url":"\(escapeJSON(status.url))","uri":"\(escapeJSON(status.uri))","language":\(lang),"in_reply_to_id":\(replyTo),"favourites_count":\(status.likesCount),"reblogs_count":\(status.boostsCount),"replies_count":\(status.repliesCount),"quotes_count":\(status.quotesCount),"quoted_status_uri":\(quotedUri),"quote_approval_state":\(quoteState),"media_attachments":\(mediaAttachments)}
    """
```

- [ ] **8b. SCP to VM and verify build succeeds**

```bash
sshpass -p admin scp -o StrictHostKeyChecking=no -r $WORKING_DIR/Sources admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Sources
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

---

## Task 9: Full Build and Test

**Files:** All modified files.

**Dependencies:** All previous tasks.

### Steps

- [ ] **9a. SCP all sources and tests to VM**

```bash
sshpass -p admin scp -o StrictHostKeyChecking=no -r $WORKING_DIR/Sources $WORKING_DIR/Tests admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/
```

- [ ] **9b. Full build**

```bash
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

- [ ] **9c. Run all tests**

```bash
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift test 2>&1"
```

- [ ] **9d. Run QuoteRequest-specific tests**

```bash
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift test --filter QuoteRequestTests 2>&1"
```

---

## Summary of Changes

| File | Change |
|------|--------|
| `Sources/ActivityPubCore/Models/Status.swift` | Add `quotedStatusUri`, `quoteApprovalState`, `quotesCount` properties + DynamoDB serialization |
| `Sources/ActivityPubCore/Models/CreateStatusRequest.swift` | Add `quotedStatusId` (`quoted_status_id`) field |
| `Sources/ActivityPubCore/Models/Note.swift` | Emit `quoteUri` + `_misskey_quote` on accepted quotes; add `quoteUri` to `@context` |
| `Sources/ActivityPubCore/QuoteApproval.swift` | **New file.** Pure `shouldAcceptQuoteRequest(...)` policy function |
| `Sources/ActivityPubCore/DynamoDBStore.swift` | Add `isFollower`, `updateQuoteApprovalState`, `incrementQuotesCount`, `findStatusByUri` methods |
| `Sources/InboxHandler/main.swift` | Add `QuoteRequest` case, `handleQuoteRequest`, split `Accept`/`Reject` into real handlers with QuoteRequest sub-handlers |
| `Sources/PostHandler/main.swift` | Add quote resolution, QuoteRequest delivery, update status response |
| `Tests/ActivityPubCoreTests/QuoteRequestTests.swift` | **New file.** Unit tests for approval policy logic |

## Edge Cases and Future Work

1. **Remote actor inbox resolution:** Task 7 extracts the actor URI from the quoted status URI by parsing `/users/{name}` pattern. This works for Mastodon-style URIs but not for all implementations. A more robust approach would HTTP-fetch the quoted status to get its `attributedTo` and then resolve the actor's inbox. This can be added in a follow-up.

2. **Undo QuoteRequest:** If a remote server sends `Undo` wrapping a `QuoteRequest`, we should decrement `quotesCount`. Not implemented in this plan -- add to the existing Undo handler in a follow-up.

3. **Per-actor quoteApprovalPolicy:** Currently hardcoded to `public`. Future work: store it on the Actor DynamoDB record and expose it via a profile update API.

4. **Quote revocation:** Mastodon 4.5 supports `POST /api/v1/statuses/:id/quotes/:quoting_status_id/revoke` to revoke a previously accepted quote. This sends a `Reject` for the original `QuoteRequest`. Not in scope for this plan.

5. **Re-federation on acceptance:** When a pending outbound quote is accepted (our `quoteApprovalState` transitions from `pending` to `accepted`), we should re-send an `Update` activity to all followers so the `quoteUri` appears in the federated Note. Not implemented in this plan.

6. **Blocking:** The `public` policy should reject QuoteRequests from blocked actors. Blocking is not yet implemented in the system.
