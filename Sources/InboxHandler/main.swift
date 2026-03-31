import AWSLambdaEvents
import AWSLambdaRuntime
import AWSCloudFront
import ActivityPubCore
import Foundation

guard let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] else {
    fatalError("SERVER_DOMAIN environment variable is required")
}
guard let handleDomain = ProcessInfo.processInfo.environment["HANDLE_DOMAIN"] else {
    fatalError("HANDLE_DOMAIN environment variable is required")
}
let distributionId = ProcessInfo.processInfo.environment["CLOUDFRONT_DISTRIBUTION_ID"] ?? ""

let store = try await DynamoDBStore()
let sqsClient = try await SQSDeliveryClient()
let keyManager = KeyManager()
let cfClient = try await CloudFrontClient()

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
    await invalidateFollowersCache(username: username, context: context)

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}

// MARK: - Undo Handling

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
            await invalidateFollowersCache(username: username, context: context)
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
            await invalidateFollowersCache(username: username, context: context)
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

/// Parse a status URI like `https://activity.happitec.com/users/{username}/statuses/{id}`
/// or `https://happitec.com/users/{username}/statuses/{id}` into (username, statusId).
/// Returns nil if the URI doesn't match our domain pattern.
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

func extractObjectUri(from json: [String: Any]) -> String? {
    if let objectStr = json["object"] as? String {
        return objectStr
    }
    if let objectDict = json["object"] as? [String: Any] {
        return objectDict["id"] as? String
    }
    return nil
}

enum InboxError: Error {
    case encodingFailed
}

/// Invalidate CloudFront cache for the followers collection so count updates are visible.
func invalidateFollowersCache(username: String, context: LambdaContext) async {
    guard !distributionId.isEmpty else { return }
    do {
        let paths = CloudFrontClientTypes.Paths(
            items: ["/users/\(username)/followers*"],
            quantity: 1
        )
        let batch = CloudFrontClientTypes.InvalidationBatch(
            callerReference: UUID().uuidString,
            paths: paths
        )
        _ = try await cfClient.createInvalidation(input: CreateInvalidationInput(
            distributionId: distributionId,
            invalidationBatch: batch
        ))
        context.logger.info("Invalidated followers cache for \(username)")
    } catch {
        context.logger.error("Failed to invalidate followers cache: \(error)")
    }
}

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

try await runtime.run()
