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
    } else {
        context.logger.info("Unhandled Undo type: \(objectType ?? "unknown") from \(actorUri)")
    }

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}

// MARK: - Helpers

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
