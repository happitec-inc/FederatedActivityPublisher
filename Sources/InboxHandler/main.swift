/// Lambda handler for `POST /users/{username}/inbox` — the ActivityPub inbound federation endpoint.
///
/// This is the entry point for all activities sent by remote servers: follows, likes,
/// boosts, replies, quote requests, and actor updates. API Gateway routes the request here
/// after CloudFront forwards it, and this Lambda is the only place that verifies inbound
/// HTTP Signatures before touching DynamoDB.
///
/// ## Request pipeline
///
/// 1. Verify the actor exists locally.
/// 2. Decode the raw body (handles base64-encoded payloads from API Gateway).
/// 3. Parse and verify the HTTP Signature using the remote actor's public key from
///    `KeyManager` (which caches keys in DynamoDB). On first failure, the key is refreshed
///    in case the remote server rotated its key pair.
/// 4. Confirm that the `actor` field in the JSON body matches the key owner — prevents one
///    server from impersonating another.
/// 5. Dedup via `storeReceivedActivity` (DynamoDB conditional write); duplicate activities
///    return 202 immediately.
/// 6. Dispatch to the appropriate `handle*` function by `type`.
///
/// ## Activity types handled
///
/// - `Follow` — stores follower, sends Accept back via SQS.
/// - `Undo` — reverses a Follow, Like, or Announce.
/// - `Like` / `Announce` — records an interaction and increments the counter.
/// - `Create` — stores inbound Note replies to local statuses.
/// - `Update` — updates a stored reply or a cached remote actor profile.
/// - `Delete` — removes a reply, interaction, or follower (actor self-deletion).
/// - `QuoteRequest` — evaluates a quote approval policy and sends Accept or Reject.
/// - `Accept` / `Reject` — handles responses to outbound QuoteRequests.
/// - `Block`, `Move`, `Add`, `Remove`, `Flag`, `EmojiReact` — acknowledged but not stored.
///
/// ## Key dependencies
///
/// `ActivityPubCore`: `DynamoDBStore`, `SQSDeliveryClient`, `KeyManager`,
/// `HTTPSignature`, `HTMLSanitizer`, `shouldAcceptQuoteRequest`, `buildNoteJSON`.
import AWSLambdaEvents
import AWSLambdaRuntime
import ActivityPubCore
import Foundation

guard let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] else {
    fatalError("SERVER_DOMAIN environment variable is required")
}
guard let handleDomain = ProcessInfo.processInfo.environment["HANDLE_DOMAIN"] else {
    fatalError("HANDLE_DOMAIN environment variable is required")
}
let store = try await DynamoDBStore()
let sqsClient = try await SQSDeliveryClient()
let keyManager = KeyManager()

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    guard let username = event.pathParameters["username"] else {
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Missing username path parameter"}"#
        )
    }

    do {
        // Verify actor exists
        guard try await store.actorExists(username: username) else {
            return APIGatewayResponse(
                statusCode: .notFound,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Actor not found"}"#
            )
        }

        // Parse the request body
        guard let bodyString = event.body else {
            return APIGatewayResponse(
                statusCode: .badRequest,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Missing request body"}"#
            )
        }

        let bodyData: Data
        if event.isBase64Encoded {
            guard let decoded = Data(base64Encoded: bodyString) else {
                return APIGatewayResponse(
                    statusCode: .badRequest,
                    headers: ["content-type": "application/json"],
                    body: #"{"error":"Invalid base64 body"}"#
                )
            }
            bodyData = decoded
        } else {
            bodyData = Data(bodyString.utf8)
        }

        guard let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return APIGatewayResponse(
                statusCode: .badRequest,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Invalid JSON body"}"#
            )
        }

        // Extract and verify HTTP Signature
        let signatureHeader = event.headers["signature"] ?? event.headers["Signature"] ?? ""
        guard !signatureHeader.isEmpty else {
            context.logger.warning("Missing Signature header")
            return APIGatewayResponse(
                statusCode: .unauthorized,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Missing Signature header"}"#
            )
        }

        guard let keyId = HTTPSignature.extractKeyId(from: signatureHeader) else {
            context.logger.warning("Cannot extract keyId from Signature header")
            return APIGatewayResponse(
                statusCode: .unauthorized,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Invalid Signature header"}"#
            )
        }

        // Fetch the remote actor's public key
        let publicKeyPem = try await keyManager.getPublicKey(keyId: keyId, store: store)

        // Build headers map for verification (lowercase keys)
        // Override host with SERVER_DOMAIN — CloudFront strips the original Host header
        // and sends the API Gateway execute-api domain instead. Remote servers signed
        // with the public domain, so we must use that for verification.
        var requestHeaders: [String: String] = [:]
        for (key, value) in event.headers {
            requestHeaders[key.lowercased()] = value
        }
        requestHeaders["host"] = serverDomain

        // Determine the request path
        let path = "/users/\(username)/inbox"

        // Verify the signature
        var verified = try HTTPSignature.verify(
            signatureHeader: signatureHeader,
            method: "post",
            path: path,
            headers: requestHeaders,
            body: bodyData,
            publicKeyPem: publicKeyPem
        )

        // If verification failed, try refreshing the key (key rotation)
        if !verified {
            context.logger.info("Signature verification failed, trying key refresh for \(keyId)")
            let refreshedKey = try await keyManager.refreshKey(keyId: keyId, store: store)
            verified = try HTTPSignature.verify(
                signatureHeader: signatureHeader,
                method: "post",
                path: path,
                headers: requestHeaders,
                body: bodyData,
                publicKeyPem: refreshedKey
            )
        }

        guard verified else {
            context.logger.warning("HTTP Signature verification failed for \(keyId)")
            return APIGatewayResponse(
                statusCode: .unauthorized,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Invalid HTTP Signature"}"#
            )
        }

        // Verify actor field is present and matches HTTP Signature's actor
        let bodyActorUri = json["actor"] as? String ?? ""
        guard !bodyActorUri.isEmpty else {
            context.logger.warning("Missing actor field in activity body")
            return APIGatewayResponse(
                statusCode: .unauthorized,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Missing actor field"}"#
            )
        }
        let signingActorUri = keyManager.extractActorUri(from: keyId)
        guard bodyActorUri == signingActorUri else {
            context.logger.warning(
                "Actor mismatch: body actor=\(bodyActorUri) but signing key actor=\(signingActorUri)"
            )
            return APIGatewayResponse(
                statusCode: .forbidden,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Actor does not match signing key"}"#
            )
        }

        // Extract activity fields
        guard let activityType = json["type"] as? String else {
            context.logger.warning("Missing activity type")
            return APIGatewayResponse(
                statusCode: .badRequest,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Missing activity type"}"#
            )
        }

        let activityId = json["id"] as? String ?? ""
        let actorUri = json["actor"] as? String ?? ""

        // Activity idempotency check
        if !activityId.isEmpty {
            let objectUri = extractObjectUri(from: json)
            let isNew = try await store.storeReceivedActivity(
                username: username,
                activityId: activityId,
                type: activityType,
                actorUri: actorUri,
                objectUri: objectUri,
                raw: bodyString
            )
            if !isNew {
                context.logger.info("Duplicate activity \(activityId), returning 202")
                return APIGatewayResponse(
                    statusCode: .accepted,
                    headers: ["content-type": "application/json"],
                    body: #"{"status":"already processed"}"#
                )
            }
        }

        // Route by activity type
        switch activityType {
        case "Follow":
            return try await handleFollow(
                json: json,
                username: username,
                actorUri: actorUri,
                activityId: activityId,
                keyId: keyId,
                bodyString: bodyString,
                context: context
            )

        case "Undo":
            return try await handleUndo(
                json: json,
                username: username,
                actorUri: actorUri,
                context: context
            )

        case "Like":
            return try await handleLike(
                json: json,
                username: username,
                actorUri: actorUri,
                context: context
            )

        case "Announce":
            return try await handleAnnounce(
                json: json,
                username: username,
                actorUri: actorUri,
                context: context
            )

        case "Create":
            return try await handleCreate(
                json: json,
                username: username,
                actorUri: actorUri,
                bodyString: bodyString,
                context: context
            )

        case "Delete":
            return try await handleDelete(
                json: json,
                username: username,
                actorUri: actorUri,
                context: context
            )

        case "Update":
            return try await handleUpdate(
                json: json,
                username: username,
                actorUri: actorUri,
                context: context
            )

        case "QuoteRequest":
            let activityId = json["id"] as? String
            return try await handleQuoteRequest(
                json: json,
                username: username,
                actorUri: actorUri,
                activityId: activityId,
                context: context
            )

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

        case "EmojiReact":
            context.logger.info("Ignored EmojiReact from \(actorUri)")
            return APIGatewayResponse(
                statusCode: .accepted,
                headers: ["content-type": "application/json"],
                body: #"{"status":"accepted"}"#
            )

        default:
            context.logger.info("Unhandled activity type: \(activityType) from \(actorUri)")
            return APIGatewayResponse(
                statusCode: .accepted,
                headers: ["content-type": "application/json"],
                body: #"{"status":"accepted"}"#
            )
        }

    } catch {
        context.logger.error("InboxHandler error: \(error)")
        return APIGatewayResponse(
            statusCode: .internalServerError,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Internal server error"}"#
        )
    }
}

// MARK: - Follow Handling

/// Handles an inbound Follow activity.
///
/// Stores the remote actor as a follower of `username`, increments the follower count if
/// the follow is new, then enqueues an Accept activity back to the remote actor's inbox
/// via SQS. The Accept wraps the original Follow JSON as its `object`, which Mastodon
/// requires for correlation.
///
/// The remote actor's inbox URL comes from the DynamoDB cache populated during HTTP
/// Signature verification. On a cache miss (rare), the key is refreshed to repopulate it.
///
/// - Parameters:
///   - json: The parsed activity JSON from the request body.
///   - username: The local actor receiving the follow.
///   - actorUri: The URI of the remote actor sending the Follow.
///   - activityId: The `id` of the Follow activity, embedded in the Accept's `object`.
///   - keyId: The HTTP Signature key ID, used to look up the remote actor's cached profile.
///   - bodyString: The raw body string, re-serialized into the Accept's `object`.
///   - context: Lambda context for logging.
/// - Returns: 202 Accepted on success or if the actor cannot be resolved.
func handleFollow(
    json: [String: Any],
    username: String,
    actorUri: String,
    activityId: String,
    keyId: String,
    bodyString: String,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    context.logger.info("Processing Follow from \(actorUri) for \(username)")

    // Look up the remote actor for inbox URL — should be cached from signature verification.
    // If cache miss (edge case), re-fetch via KeyManager which re-populates the cache.
    let remoteActorUri = KeyManager().extractActorUri(from: keyId)
    var remoteActor = try await store.getRemoteActor(actorUri: remoteActorUri)
    if remoteActor == nil {
        let _ = try await keyManager.refreshKey(keyId: keyId, store: store)
        remoteActor = try await store.getRemoteActor(actorUri: remoteActorUri)
    }
    guard let resolvedActor = remoteActor else {
        context.logger.error("Cannot resolve remote actor \(remoteActorUri) for Follow")
        return APIGatewayResponse(
            statusCode: .internalServerError,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Cannot resolve remote actor"}"#
        )
    }
    let inboxUrl = resolvedActor.inbox
    let sharedInboxUrl = resolvedActor.sharedInbox

    let now = iso8601Formatter.string(from: Date())

    let follower = Follower(
        actorUri: actorUri,
        inboxUrl: inboxUrl,
        sharedInboxUrl: sharedInboxUrl,
        followActivityId: activityId,
        acceptedAt: now
    )

    // Store follower — only increment count if new
    let isNew = try await store.storeFollower(username: username, follower: follower)
    if isNew {
        try await store.incrementFollowerCount(username: username)
    }

    // Build Accept activity with a unique id (required by Mastodon)
    let ulid = store.generateULID()
    let acceptId = "https://\(serverDomain)/users/\(username)#accept-\(ulid)"

    // Re-serialize the original Follow activity as the Accept's object
    let acceptActivity: [String: Any] = [
        "@context": "https://www.w3.org/ns/activitystreams",
        "id": acceptId,
        "type": "Accept",
        "actor": "https://\(serverDomain)/users/\(username)",
        "object": json,
    ]

    let acceptData = try JSONSerialization.data(withJSONObject: acceptActivity)
    guard let acceptJSON = String(data: acceptData, encoding: .utf8) else {
        throw InboxError.encodingFailed
    }

    // Enqueue delivery job — target the follower's inbox
    let targetInbox = inboxUrl
    let job = DeliveryJob(
        targetInbox: targetInbox,
        activityJSON: acceptJSON,
        actorUsername: username
    )
    try await sqsClient.enqueue(job: job)

    context.logger.info("Follow accepted from \(actorUri), Accept enqueued to \(targetInbox)")

    // Invalidate followers cache so the count updates
    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}

// MARK: - Undo Handling

/// Handles an inbound Undo activity.
///
/// The `object` of an Undo can be an inline dict or a bare URI string. This handler
/// infers the undone activity type from the `object.type` field, or assumes `Follow`
/// when the object is a bare URI (the common case from Mastodon).
///
/// Supported inner types:
/// - `Follow`: removes the follower record and decrements the follower count.
/// - `Like`: removes the Like interaction and decrements the likes counter on the status.
/// - `Announce`: removes the Announce interaction and decrements the boosts counter.
///
/// Unknown inner types are logged and accepted without error.
///
/// - Parameters:
///   - json: The parsed activity JSON.
///   - username: The local actor whose follower/interaction data is being modified.
///   - actorUri: The remote actor performing the Undo.
///   - context: Lambda context for logging.
/// - Returns: 202 Accepted in all cases.
func handleUndo(
    json: [String: Any],
    username: String,
    actorUri: String,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    // The `object` field may be a URI string or an inline object
    let objectType: String?

    if let objectDict = json["object"] as? [String: Any] {
        objectType = objectDict["type"] as? String
    } else if let objectUri = json["object"] as? String {
        // URI string — for Undo Follow, we can infer based on the activity pattern
        // but we won't resolve the URI in Phase 2; just log it
        context.logger.info("Undo with object URI: \(objectUri), assuming Follow for actor \(actorUri)")
        objectType = "Follow"
    } else {
        context.logger.warning("Undo with unrecognized object format from \(actorUri)")
        objectType = nil
    }

    if objectType == "Follow" {
        context.logger.info("Processing Undo Follow from \(actorUri) for \(username)")
        let wasRemoved = try await store.removeFollower(username: username, actorUri: actorUri)
        if wasRemoved {
            try await store.decrementFollowerCount(username: username)
        }
    } else if objectType == "Like" {
        context.logger.info("Processing Undo Like from \(actorUri) for \(username)")
        let likeObjectUri: String?
        if let objectDict = json["object"] as? [String: Any] {
            likeObjectUri = extractObjectUri(from: objectDict)
        } else {
            likeObjectUri = nil
        }

        if let likeObjectUri, let parsed = parseStatusUri(likeObjectUri) {
            let wasRemoved = try await store.removeInteraction(
                username: parsed.username,
                actorUri: actorUri,
                type: "Like",
                objectUri: likeObjectUri
            )
            if wasRemoved {
                try await store.decrementLikesCount(username: parsed.username, statusId: parsed.statusId)

            }
        } else {
            context.logger.info("Undo Like with unparseable object from \(actorUri)")
        }

    } else if objectType == "Announce" {
        context.logger.info("Processing Undo Announce from \(actorUri) for \(username)")
        let announceObjectUri: String?
        if let objectDict = json["object"] as? [String: Any] {
            announceObjectUri = extractObjectUri(from: objectDict)
        } else {
            announceObjectUri = nil
        }

        if let announceObjectUri, let parsed = parseStatusUri(announceObjectUri) {
            let wasRemoved = try await store.removeInteraction(
                username: parsed.username,
                actorUri: actorUri,
                type: "Announce",
                objectUri: announceObjectUri
            )
            if wasRemoved {
                try await store.decrementBoostsCount(username: parsed.username, statusId: parsed.statusId)

            }
        } else {
            context.logger.info("Undo Announce with unparseable object from \(actorUri)")
        }

    } else {
        context.logger.info("Unhandled Undo type: \(objectType ?? "unknown") from \(actorUri)")
    }

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}

// MARK: - Like Handling

/// Handles an inbound Like activity.
///
/// Parses the `object` URI, verifies it refers to a local status, stores the interaction
/// in DynamoDB (conditional write for dedup), and increments the like count on first write.
/// Likes against non-local or non-existent statuses are silently accepted.
///
/// - Parameters:
///   - json: The parsed activity JSON.
///   - username: The local actor whose inbox received the Like.
///   - actorUri: The remote actor who sent the Like.
///   - context: Lambda context for logging.
/// - Returns: 202 Accepted, or 400 if the `object` field is missing.
func handleLike(
    json: [String: Any],
    username: String,
    actorUri: String,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    context.logger.info("Processing Like from \(actorUri) for \(username)")

    // Extract the object URI (the status being liked)
    guard let objectUri = extractObjectUri(from: json) else {
        context.logger.warning("Like missing object URI from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Missing object in Like activity"}"#
        )
    }

    // Parse username and statusId from the object URI
    guard let parsed = parseStatusUri(objectUri) else {
        context.logger.info("Like for non-local object \(objectUri) from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Verify the status exists
    guard try await store.getStatus(username: parsed.username, id: parsed.statusId) != nil else {
        context.logger.warning("Like for non-existent status \(objectUri) from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Store the interaction
    let isNew = try await store.storeInteraction(
        username: parsed.username,
        actorUri: actorUri,
        type: "Like",
        objectUri: objectUri
    )

    if isNew {
        try await store.incrementLikesCount(username: parsed.username, statusId: parsed.statusId)

    }

    context.logger.info("Like \(isNew ? "stored" : "duplicate") from \(actorUri) on \(objectUri)")

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}

// MARK: - Announce Handling

/// Handles an inbound Announce (boost) activity.
///
/// Identical flow to `handleLike`: parses the object URI, verifies it is a local status,
/// stores the interaction, and increments the boost count on first write. Announces for
/// non-local or non-existent statuses are silently accepted.
///
/// - Parameters:
///   - json: The parsed activity JSON.
///   - username: The local actor whose inbox received the Announce.
///   - actorUri: The remote actor who boosted.
///   - context: Lambda context for logging.
/// - Returns: 202 Accepted, or 400 if the `object` field is missing.
func handleAnnounce(
    json: [String: Any],
    username: String,
    actorUri: String,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    context.logger.info("Processing Announce from \(actorUri) for \(username)")

    guard let objectUri = extractObjectUri(from: json) else {
        context.logger.warning("Announce missing object URI from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Missing object in Announce activity"}"#
        )
    }

    guard let parsed = parseStatusUri(objectUri) else {
        context.logger.info("Announce for non-local object \(objectUri) from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    guard try await store.getStatus(username: parsed.username, id: parsed.statusId) != nil else {
        context.logger.warning("Announce for non-existent status \(objectUri) from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    let isNew = try await store.storeInteraction(
        username: parsed.username,
        actorUri: actorUri,
        type: "Announce",
        objectUri: objectUri
    )

    if isNew {
        try await store.incrementBoostsCount(username: parsed.username, statusId: parsed.statusId)

    }

    context.logger.info("Announce \(isNew ? "stored" : "duplicate") from \(actorUri) on \(objectUri)")

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}

// MARK: - Create Handling

/// Handles an inbound Create activity.
///
/// Only `Create` activities whose `object` is an inline `Note` with an `inReplyTo` pointing
/// at one of our local statuses are stored. All other Create types (non-Note objects,
/// replies to remote statuses) are accepted and discarded. This keeps the inbox focused:
/// the server only stores content that belongs in a thread it hosts.
///
/// The reply content is sanitized by `HTMLSanitizer` before storage. The reply count on
/// the parent status is incremented on first write.
///
/// - Parameters:
///   - json: The parsed activity JSON.
///   - username: The local actor whose inbox received the Create.
///   - actorUri: The remote actor who created the Note.
///   - bodyString: The raw request body, stored as the canonical representation of the reply.
///   - context: Lambda context for logging.
/// - Returns: 202 Accepted in all cases (including silently dropped creates).
func handleCreate(
    json: [String: Any],
    username: String,
    actorUri: String,
    bodyString: String,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    context.logger.info("Processing Create from \(actorUri) for \(username)")

    // Extract the object (must be an inline Note)
    guard let objectDict = json["object"] as? [String: Any],
          let objectType = objectDict["type"] as? String else {
        context.logger.warning("Create missing inline object from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    guard objectType == "Note" else {
        context.logger.info("Create with non-Note object type \(objectType) from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Must have inReplyTo pointing to one of our statuses
    guard let inReplyTo = objectDict["inReplyTo"] as? String else {
        context.logger.info("Create Note without inReplyTo from \(actorUri), not a reply")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    guard let parsed = parseStatusUri(inReplyTo) else {
        context.logger.info("Create Note replying to non-local status \(inReplyTo) from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Verify the parent status exists
    guard try await store.getStatus(username: parsed.username, id: parsed.statusId) != nil else {
        context.logger.warning("Create Note replying to non-existent status \(inReplyTo) from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    guard let objectUri = objectDict["id"] as? String else {
        context.logger.warning("Create Note missing id from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Note missing id"}"#
        )
    }

    // Sanitize the content
    let rawContent = objectDict["content"] as? String ?? ""
    let sanitizedContent = HTMLSanitizer.sanitize(rawContent)

    // Store the reply
    let isNew = try await store.storeReply(
        username: parsed.username,
        actorUri: actorUri,
        objectUri: objectUri,
        content: sanitizedContent,
        inReplyTo: inReplyTo,
        raw: bodyString
    )

    if isNew {
        try await store.incrementRepliesCount(username: parsed.username, statusId: parsed.statusId)

    }

    context.logger.info("Reply \(isNew ? "stored" : "duplicate") from \(actorUri) to \(inReplyTo)")

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}

// MARK: - Update Handling

/// Handles an inbound Update activity.
///
/// Two object types are handled:
/// - `Note`: updates a stored reply if `inReplyTo` points at a local status. The update
///   is rejected if the acting actor does not own the reply (ownership check in the store).
/// - `Person` / `Service` / `Application` / `Organization`: updates the cached remote
///   actor profile in DynamoDB, including the public key, inbox URL, and shared inbox.
///   The actor can only update its own profile (`actorUri == object.id`).
///
/// Updates for other object types are accepted and logged without storing.
///
/// - Parameters:
///   - json: The parsed activity JSON.
///   - username: The local actor whose inbox received the Update.
///   - actorUri: The remote actor sending the Update.
///   - context: Lambda context for logging.
/// - Returns: 202 Accepted in all cases; 403 if an actor tries to update another actor's profile.
func handleUpdate(
    json: [String: Any],
    username: String,
    actorUri: String,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    context.logger.info("Processing Update from \(actorUri) for \(username)")

    // Extract the inline object
    guard let objectDict = json["object"] as? [String: Any],
          let objectType = objectDict["type"] as? String else {
        context.logger.warning("Update missing inline object from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    if objectType == "Note" {
        // Update a reply Note
        guard let inReplyTo = objectDict["inReplyTo"] as? String,
              let _ = parseStatusUri(inReplyTo) else {
            context.logger.info("Update Note not replying to our status from \(actorUri)")
            return APIGatewayResponse(
                statusCode: .accepted,
                headers: ["content-type": "application/json"],
                body: #"{"status":"accepted"}"#
            )
        }

        guard let objectUri = objectDict["id"] as? String else {
            context.logger.warning("Update Note missing id from \(actorUri)")
            return APIGatewayResponse(
                statusCode: .accepted,
                headers: ["content-type": "application/json"],
                body: #"{"status":"accepted"}"#
            )
        }

        let rawContent = objectDict["content"] as? String ?? ""
        let sanitizedContent = HTMLSanitizer.sanitize(rawContent)

        let updated = try await store.updateReply(
            username: username,
            objectUri: objectUri,
            content: sanitizedContent,
            actorUri: actorUri
        )

        if updated {
            context.logger.info("Updated reply \(objectUri) from \(actorUri)")
        } else {
            context.logger.warning("Update reply rejected: actor \(actorUri) does not own reply \(objectUri)")
        }

    } else if ["Person", "Service", "Application", "Organization"].contains(objectType) {
        // Update a remote actor profile
        guard let remoteActorUri = objectDict["id"] as? String else {
            context.logger.warning("Update actor missing id from \(actorUri)")
            return APIGatewayResponse(
                statusCode: .accepted,
                headers: ["content-type": "application/json"],
                body: #"{"status":"accepted"}"#
            )
        }

        // Verify the actor updating is the same as the actor being updated
        guard remoteActorUri == actorUri else {
            context.logger.warning("Update actor mismatch: activity actor=\(actorUri), object id=\(remoteActorUri)")
            return APIGatewayResponse(
                statusCode: .forbidden,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Cannot update another actor's profile"}"#
            )
        }

        // Extract actor fields
        guard let publicKeyObj = objectDict["publicKey"] as? [String: Any],
              let publicKeyPem = publicKeyObj["publicKeyPem"] as? String,
              let inbox = objectDict["inbox"] as? String else {
            context.logger.warning("Update actor missing required fields from \(actorUri)")
            return APIGatewayResponse(
                statusCode: .accepted,
                headers: ["content-type": "application/json"],
                body: #"{"status":"accepted"}"#
            )
        }

        let preferredUsername = objectDict["preferredUsername"] as? String
        var sharedInbox: String?
        if let endpoints = objectDict["endpoints"] as? [String: Any] {
            sharedInbox = endpoints["sharedInbox"] as? String
        }

        let now = iso8601Formatter.string(from: Date())

        let updatedActor = RemoteActor(
            actorUri: remoteActorUri,
            publicKeyPem: publicKeyPem,
            preferredUsername: preferredUsername,
            inbox: inbox,
            sharedInbox: sharedInbox,
            fetchedAt: now
        )

        try await store.updateRemoteActor(actorUri: remoteActorUri, data: updatedActor)
        context.logger.info("Updated remote actor profile for \(remoteActorUri)")

    } else {
        context.logger.info("Update with unhandled object type \(objectType) from \(actorUri)")
    }

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}

// MARK: - Delete Handling

/// Handles an inbound Delete activity.
///
/// The `object` field may be a Tombstone dict or a bare URI string. This handler
/// tries three interpretation branches in order:
///
/// 1. **Local status URI** (`parseStatusUri` matches): the object is one of our status
///    URIs. This is unusual — remote servers normally send `Undo` to retract a Like or
///    Announce — but can occur when a remote server purges objects retroactively. The
///    handler tries to remove a Like interaction, an Announce interaction, and a reply,
///    decrementing the relevant counters for any that existed.
///
/// 2. **Actor self-deletion** (`actorUri == objectUri`): the remote server is signalling
///    that an actor account has been deleted. The follower record is removed and the count
///    decremented. Any stored reply by that actor is also removed.
///
/// 3. **Unknown remote URI**: may be a remote Note (a reply stored here). The handler
///    tries to remove it as a reply; if nothing matches, the Delete is logged and accepted.
///
/// - Parameters:
///   - json: The parsed activity JSON.
///   - username: The local actor whose inbox received the Delete.
///   - actorUri: The remote actor sending the Delete.
///   - context: Lambda context for logging.
/// - Returns: 202 Accepted in all cases.
func handleDelete(
    json: [String: Any],
    username: String,
    actorUri: String,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    context.logger.info("Processing Delete from \(actorUri) for \(username)")

    // Extract the object being deleted. The object may be a Tombstone dict or a bare URI string.
    let objectUri: String

    if let objectDict = json["object"] as? [String: Any] {
        objectUri = objectDict["id"] as? String ?? ""
    } else if let objectStr = json["object"] as? String {
        objectUri = objectStr
    } else {
        context.logger.warning("Delete with unrecognized object format from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    guard !objectUri.isEmpty else {
        context.logger.warning("Delete with empty object URI from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Branch 1: Object URI matches our status URI pattern — deleting an interaction or reply
    // about one of our statuses. This is an edge case; remote servers typically send `Undo`
    // (not `Delete`) to retract a Like/Announce. Delete via Tombstone may occur when a remote
    // server purges an object retroactively, carrying the *remote* object's URI rather than
    // our status URI. We handle it here for completeness.
    if let parsed = parseStatusUri(objectUri) {
        // Try removing a Like interaction
        let removedLike = try await store.removeInteraction(
            username: parsed.username,
            actorUri: actorUri,
            type: "Like",
            objectUri: objectUri
        )
        if removedLike {
            try await store.decrementLikesCount(username: parsed.username, statusId: parsed.statusId)
    
            context.logger.info("Deleted Like from \(actorUri) on \(objectUri)")
        }

        // Try removing an Announce interaction
        let removedAnnounce = try await store.removeInteraction(
            username: parsed.username,
            actorUri: actorUri,
            type: "Announce",
            objectUri: objectUri
        )
        if removedAnnounce {
            try await store.decrementBoostsCount(username: parsed.username, statusId: parsed.statusId)
    
            context.logger.info("Deleted Announce from \(actorUri) on \(objectUri)")
        }

        // Also try removing a reply whose objectUri happens to match
        if let inReplyTo = try await store.removeReply(username: parsed.username, objectUri: objectUri) {
            context.logger.info("Deleted reply \(objectUri) from \(actorUri)")
            if !inReplyTo.isEmpty, let parentParsed = parseStatusUri(inReplyTo) {
                try await store.decrementRepliesCount(username: parentParsed.username, statusId: parentParsed.statusId)

            }
        }

    // Branch 2: Actor self-deletion (actorUri == objectUri). This is the primary real-world
    // use of Delete — a remote server announces that an actor account has been removed.
    // We clean up the follower record and decrement the count.
    } else if actorUri == objectUri {
        context.logger.info("Processing actor self-deletion for \(actorUri)")
        let wasRemoved = try await store.removeFollower(username: username, actorUri: actorUri)
        if wasRemoved {
            try await store.decrementFollowerCount(username: username)

            context.logger.info("Removed follower \(actorUri) via self-deletion")
        }

        // Also try removing a reply by remote objectUri (the deleted actor's Note)
        if let inReplyTo = try await store.removeReply(username: username, objectUri: objectUri) {
            context.logger.info("Deleted reply \(objectUri) from \(actorUri)")
            if !inReplyTo.isEmpty, let parentParsed = parseStatusUri(inReplyTo) {
                try await store.decrementRepliesCount(username: parentParsed.username, statusId: parentParsed.statusId)

            }
        }

    // Branch 3: Unrecognized object — could be a remote Note URI being deleted (reply removal).
    // Try removing it as a reply; otherwise log and accept for forward compatibility.
    } else {
        if let inReplyTo = try await store.removeReply(username: username, objectUri: objectUri) {
            context.logger.info("Deleted reply \(objectUri) from \(actorUri)")
            if !inReplyTo.isEmpty, let parentParsed = parseStatusUri(inReplyTo) {
                try await store.decrementRepliesCount(username: parentParsed.username, statusId: parentParsed.statusId)

            }
        } else {
            context.logger.info("Delete for unrecognized object \(objectUri) from \(actorUri)")
        }
    }

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}

// MARK: - Helpers

/// Parses a status URI into its username and status ID components.
///
/// Accepts URIs on either the server domain (`activity.happitec.com`) or the handle
/// domain (`happitec.com`), both of which resolve to local statuses. Returns `nil` for
/// any URI that doesn't match the expected `https://{domain}/users/{username}/statuses/{id}`
/// pattern.
///
/// - Parameter uri: A fully-qualified status URI.
/// - Returns: A tuple of `(username, statusId)`, or `nil` if the URI is not local.
func parseStatusUri(_ uri: String) -> (username: String, statusId: String)? {
    // Match both serverDomain and handleDomain
    let patterns = [
        "https://\(serverDomain)/users/",
        "https://\(handleDomain)/users/"
    ]
    for prefix in patterns {
        guard uri.hasPrefix(prefix) else { continue }
        let remainder = String(uri.dropFirst(prefix.count))
        let parts = remainder.split(separator: "/", maxSplits: 3)
        // Expected: ["username", "statuses", "id"]
        guard parts.count >= 3, parts[1] == "statuses" else { continue }
        return (username: String(parts[0]), statusId: String(parts[2]))
    }
    return nil
}

/// Extracts the object URI from an ActivityPub JSON object.
///
/// The `object` field may be a bare URI string or an inline object containing an `id`.
/// Returns `nil` if neither form is present.
///
/// - Parameter json: An activity or nested object dictionary.
/// - Returns: The URI string, or `nil`.
func extractObjectUri(from json: [String: Any]) -> String? {
    if let objectStr = json["object"] as? String {
        return objectStr
    }
    if let objectDict = json["object"] as? [String: Any] {
        return objectDict["id"] as? String
    }
    return nil
}

/// Errors thrown internally by InboxHandler.
enum InboxError: Error {
    /// JSON serialization to a UTF-8 string failed, which should not happen in practice.
    case encodingFailed
}

// MARK: - Accept Handling

/// Handles an inbound Accept activity.
///
/// The only Accept type that requires action is `Accept<QuoteRequest>`, which means
/// a remote server approved one of our outbound quote posts. That case is delegated to
/// `handleAcceptQuoteRequest`. All other Accept types (including `Accept<Follow>`, which
/// is handled implicitly by the Follow flow) are acknowledged and logged.
///
/// - Parameters:
///   - json: The parsed activity JSON.
///   - username: The local actor whose inbox received the Accept.
///   - actorUri: The remote actor sending the Accept.
///   - context: Lambda context for logging.
/// - Returns: 202 Accepted in all cases.
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

/// Handles an `Accept<QuoteRequest>` — a remote server approving one of our quote posts.
///
/// The `instrument` field in the embedded QuoteRequest is the URI of our quoting status.
/// After verifying that the accepting actor is from the same origin as the quoted post
/// (to prevent forgery), the quote approval state is updated to `"accepted"` in DynamoDB.
///
/// Once accepted, the handler re-federates an `Update` activity for the quoting Note to
/// all followers. The Note now includes the `quoteUri` field that was withheld while the
/// quote was pending, so followers' clients can render the inline quote.
///
/// - Parameters:
///   - objectDict: The inline QuoteRequest object from the Accept's `object` field.
///   - username: The local actor whose inbox received the Accept.
///   - actorUri: The remote actor sending the Accept (must be from the quoted post's origin).
///   - context: Lambda context for logging.
/// - Returns: 202 Accepted in all cases.
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

    // Verify the sender is the author of the quoted post (origin check).
    // Without this, any authenticated actor could send a forged Accept to flip
    // our pending quotes to "accepted".
    if let existingStatus = try await store.getStatus(username: parsed.username, id: parsed.statusId),
       let quotedUri = existingStatus.quotedStatusUri {
        let actorOrigin = URL(string: actorUri).flatMap { "\($0.scheme ?? "")://\($0.host ?? "")" }
        let quotedOrigin = URL(string: quotedUri).flatMap { "\($0.scheme ?? "")://\($0.host ?? "")" }
        guard actorOrigin != nil && actorOrigin == quotedOrigin else {
            context.logger.warning("Accept QuoteRequest origin mismatch: actor=\(actorUri), quotedStatus=\(quotedUri)")
            return APIGatewayResponse(
                statusCode: .accepted,
                headers: ["content-type": "application/json"],
                body: #"{"status":"accepted"}"#
            )
        }
    }

    // Update the quote approval state to accepted
    try await store.updateQuoteApprovalState(
        username: parsed.username,
        statusId: parsed.statusId,
        state: "accepted"
    )

    // Re-federate: send an Update activity for our quoting Note to all followers.
    // The Note now includes `quoteUri` (which was withheld while the quote was pending).
    // Use consistentRead to ensure we see the updated quoteApprovalState.
    if let updatedStatus = try await store.getStatus(username: parsed.username, id: parsed.statusId, consistentRead: true) {
        let noteJSON = buildNoteJSON(status: updatedStatus, serverDomain: serverDomain, username: parsed.username)
        let actorUrl = "https://\(serverDomain)/users/\(parsed.username)"
        let updateId = "https://\(serverDomain)/users/\(parsed.username)#updates/\(store.generateULID())"
        let toJSON = jsonArray(updatedStatus.to)
        let ccJSON = jsonArray(updatedStatus.cc)
        // Build Update activity via string interpolation (not JSONSerialization)
        // to avoid double-encoding the Note JSON string.
        let updateJSON = """
        {"@context":"https://www.w3.org/ns/activitystreams","id":"\(updateId)","type":"Update","actor":"\(actorUrl)","published":"\(escapeJSON(updatedStatus.published))","to":\(toJSON),"cc":\(ccJSON),"object":\(noteJSON)}
        """.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fan out Update to all followers so they see the quoteUri
        let followers = try await store.listAllFollowers(username: parsed.username)
        for follower in followers {
            let inbox = follower.sharedInboxUrl ?? follower.inboxUrl
            let job = DeliveryJob(
                targetInbox: inbox,
                activityJSON: updateJSON,
                actorUsername: parsed.username
            )
            try await sqsClient.enqueue(job: job)
        }
        context.logger.info("Update activity for status \(parsed.statusId) enqueued to \(followers.count) followers")
    }

    context.logger.info("Quote approval accepted for status \(parsed.statusId) by \(actorUri)")

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}

// MARK: - Reject Handling

/// Handles an inbound Reject activity.
///
/// The only Reject type that requires action is `Reject<QuoteRequest>`, delegated to
/// `handleRejectQuoteRequest`. All other Reject types are accepted and logged.
///
/// - Parameters:
///   - json: The parsed activity JSON.
///   - username: The local actor whose inbox received the Reject.
///   - actorUri: The remote actor sending the Reject.
///   - context: Lambda context for logging.
/// - Returns: 202 Accepted in all cases.
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

/// Handles a `Reject<QuoteRequest>` — a remote server declining one of our quote posts.
///
/// The same origin-check as `handleAcceptQuoteRequest` applies: the rejecting actor must
/// be from the same origin as the quoted post. On success, the quote approval state is
/// updated to `"rejected"` in DynamoDB. The quoting Note is not re-federated on rejection
/// because the `quoteUri` was never included in the distributed copy.
///
/// - Parameters:
///   - objectDict: The inline QuoteRequest object from the Reject's `object` field.
///   - username: The local actor whose inbox received the Reject.
///   - actorUri: The remote actor sending the Reject (must be from the quoted post's origin).
///   - context: Lambda context for logging.
/// - Returns: 202 Accepted in all cases.
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

    // Verify the sender is the author of the quoted post (origin check).
    if let existingStatus = try await store.getStatus(username: parsed.username, id: parsed.statusId),
       let quotedUri = existingStatus.quotedStatusUri {
        let actorOrigin = URL(string: actorUri).flatMap { "\($0.scheme ?? "")://\($0.host ?? "")" }
        let quotedOrigin = URL(string: quotedUri).flatMap { "\($0.scheme ?? "")://\($0.host ?? "")" }
        guard actorOrigin != nil && actorOrigin == quotedOrigin else {
            context.logger.warning("Reject QuoteRequest origin mismatch: actor=\(actorUri), quotedStatus=\(quotedUri)")
            return APIGatewayResponse(
                statusCode: .accepted,
                headers: ["content-type": "application/json"],
                body: #"{"status":"accepted"}"#
            )
        }
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

// MARK: - QuoteRequest Handling

/// Handles an inbound QuoteRequest (FEP-044f) from a remote server.
///
/// A QuoteRequest means a remote actor wants to quote one of our local statuses. The
/// `object` field is the URI of the status being quoted; `instrument` is the URI of the
/// remote actor's quoting post.
///
/// The handler:
/// 1. Verifies the quoted status is local and exists.
/// 2. Checks whether the requesting actor is a follower.
/// 3. Evaluates the actor's quote approval policy via `shouldAcceptQuoteRequest`.
///    The policy is currently hardcoded to `"public"` (auto-accept from anyone).
/// 4. Builds an Accept or Reject activity (with the FEP-044f `@context` extension) and
///    enqueues it for delivery to the remote actor's inbox.
/// 5. On accept, increments the quotes count on the quoted status.
///
/// If the remote actor's inbox URL is not in the local cache, the handler falls back to
/// fetching their actor profile directly before giving up.
///
/// - Parameters:
///   - json: The parsed activity JSON.
///   - username: The local actor whose inbox received the QuoteRequest.
///   - actorUri: The remote actor requesting the quote.
///   - activityId: The `id` of the QuoteRequest, echoed back in the response for correlation.
///   - context: Lambda context for logging.
/// - Returns: 202 Accepted in all cases. If the remote inbox cannot be resolved, the
///   Accept/Reject is not delivered, but the request is still acknowledged.
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
    // Generate an approval URI that the remote server can reference
    let approvalUri = "https://\(serverDomain)/users/\(username)/quote_authorizations/\(ulid)"

    var responseActivity: [String: Any] = [
        "@context": [
            "https://www.w3.org/ns/activitystreams",
            ["QuoteRequest": "https://w3id.org/fep/044f#QuoteRequest"]
        ] as [Any],
        "id": responseId,
        "type": responseType,
        "actor": "https://\(serverDomain)/users/\(username)",
        "object": quoteRequestObject,
    ]

    // Mastodon requires a `result` field containing an approval URI
    if accepted {
        responseActivity["result"] = approvalUri
    }

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

try await runtime.run()
