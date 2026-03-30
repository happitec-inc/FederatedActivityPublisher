import AWSLambdaEvents
import AWSLambdaRuntime
import AWSCloudFront
import ActivityPubCore
import Foundation

let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] ?? "activity.happitec.com"
let handleDomain = ProcessInfo.processInfo.environment["HANDLE_DOMAIN"] ?? "happitec.com"
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

        // Verify actor field matches HTTP Signature's actor
        let bodyActorUri = json["actor"] as? String ?? ""
        let signingActorUri = keyManager.extractActorUri(from: keyId)
        if !bodyActorUri.isEmpty && bodyActorUri != signingActorUri {
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

        case "Accept", "Reject", "Block", "Move", "Add", "Remove", "Flag":
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

    let formatter = ISO8601DateFormatter()
    let now = formatter.string(from: Date())

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

        try await store.updateReply(
            username: username,
            objectUri: objectUri,
            content: sanitizedContent
        )

        context.logger.info("Updated reply \(objectUri) from \(actorUri)")

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

        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())

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

    // Extract the object being deleted
    let objectUri: String
    let objectType: String?

    if let objectDict = json["object"] as? [String: Any] {
        objectUri = objectDict["id"] as? String ?? ""
        objectType = objectDict["type"] as? String
    } else if let objectStr = json["object"] as? String {
        objectUri = objectStr
        objectType = nil
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

    // Case 1: Object URI matches our status pattern -- deleting an interaction or reply
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

        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Check if it's a reply being deleted (objectUri is the remote Note's id, not our status URI)
    if let inReplyTo = try await store.removeReply(username: username, objectUri: objectUri) {
        context.logger.info("Deleted reply \(objectUri) from \(actorUri)")
        // Decrement the parent status's reply count using inReplyTo from the deleted item
        if !inReplyTo.isEmpty, let parentParsed = parseStatusUri(inReplyTo) {
            try await store.decrementRepliesCount(username: parentParsed.username, statusId: parentParsed.statusId)
        }
    }

    // Case 2: Actor self-deletion (objectUri matches an actor URI, and actorUri == objectUri)
    if actorUri == objectUri && !objectUri.contains("/statuses/") {
        context.logger.info("Processing actor self-deletion for \(actorUri)")
        let wasRemoved = try await store.removeFollower(username: username, actorUri: actorUri)
        if wasRemoved {
            try await store.decrementFollowerCount(username: username)
            await invalidateFollowersCache(username: username, context: context)
            context.logger.info("Removed follower \(actorUri) via self-deletion")
        }
    } else {
        context.logger.info("Delete for unrecognized object \(objectUri) from \(actorUri)")
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

try await runtime.run()
