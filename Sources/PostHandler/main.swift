import AWSLambdaEvents
import AWSLambdaRuntime
import AWSCloudFront
import AWSSSM
import ActivityPubCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

guard let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] else {
    fatalError("SERVER_DOMAIN environment variable is required")
}
guard let handleDomain = ProcessInfo.processInfo.environment["HANDLE_DOMAIN"] else {
    fatalError("HANDLE_DOMAIN environment variable is required")
}
let distributionId = ProcessInfo.processInfo.environment["CLOUDFRONT_DISTRIBUTION_ID"] ?? ""
let proxyDistributionId = ProcessInfo.processInfo.environment["PROXY_DISTRIBUTION_ID"] ?? ""
let ssmKeyPrefixRaw = ProcessInfo.processInfo.environment["SSM_KEY_PREFIX"] ?? "/activity/stage/keys/"
let ssmKeyPrefix = ssmKeyPrefixRaw.hasSuffix("/") ? String(ssmKeyPrefixRaw.dropLast()) : ssmKeyPrefixRaw

let store = try await DynamoDBStore()
let sqsClient = try await SQSDeliveryClient()
let ssmClient = try await SSMClient()
let cfClient = try await CloudFrontClient()

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    do {
        // 1. Verify auth (bearer token or session cookie)
        let authHeader = event.headers["authorization"] ?? event.headers["Authorization"] ?? ""
        let cookies = event.headers["cookie"] ?? event.headers["Cookie"]

        // Lazy-load signing key for session auth
        let signingKey: String
        do {
            let signingKeyOutput = try await ssmClient.getParameter(input: .init(
                name: "\(ssmKeyPrefix)/session-signing-key",
                withDecryption: true
            ))
            signingKey = signingKeyOutput.parameter?.value ?? ""
        } catch {
            signingKey = ""  // Session auth unavailable, bearer-only
        }

        let authResult: RequestAuthResult
        do {
            authResult = try await authenticateRequest(
                authHeader: authHeader,
                cookies: cookies,
                ssmKeyPrefix: ssmKeyPrefix,
                ssmClient: ssmClient,
                signingKey: signingKey,
                serverDomain: serverDomain
            )
        } catch BearerAuthError.sessionExpired {
            let accept = event.headers["accept"] ?? event.headers["Accept"] ?? ""
            if accept.contains("text/html") {
                return APIGatewayResponse(
                    statusCode: .found,
                    headers: ["location": "/auth/login"],
                    body: nil
                )
            }
            return APIGatewayResponse(
                statusCode: .unauthorized,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Session expired"}"#
            )
        } catch BearerAuthError.missingHeader {
            let accept = event.headers["accept"] ?? event.headers["Accept"] ?? ""
            if accept.contains("text/html") {
                return APIGatewayResponse(
                    statusCode: .found,
                    headers: ["location": "/auth/login"],
                    body: nil
                )
            }
            return APIGatewayResponse(
                statusCode: .unauthorized,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Missing or invalid Authorization header"}"#
            )
        } catch BearerAuthError.invalidToken {
            return APIGatewayResponse(
                statusCode: .unauthorized,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Invalid bearer token"}"#
            )
        } catch let error as BearerAuthError {
            context.logger.error("Auth error: \(error)")
            return APIGatewayResponse(
                statusCode: .internalServerError,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Server configuration error"}"#
            )
        }

        // CSRF check for session-based auth on POST requests
        if authResult.method == .session {
            let csrfHeader = event.headers["x-csrf-token"] ?? event.headers["X-CSRF-Token"] ?? ""
            if csrfHeader.isEmpty {
                return APIGatewayResponse(
                    statusCode: .forbidden,
                    headers: ["content-type": "application/json"],
                    body: #"{"error":"Missing CSRF token"}"#
                )
            }
            // We need the JWT claims to verify CSRF
            if let sessionJWT = cookies.flatMap({ extractCookie(name: "session", from: $0) }),
               let claims = try? JWTSession.verify(jwt: sessionJWT, key: signingKey, expectedIssuer: serverDomain) {
                guard JWTSession.verifyCSRF(token: csrfHeader, signingKey: signingKey, sub: claims.sub, iat: claims.iat) else {
                    return APIGatewayResponse(
                        statusCode: .forbidden,
                        headers: ["content-type": "application/json"],
                        body: #"{"error":"Invalid CSRF token"}"#
                    )
                }
            }
        }

        let username = authResult.username

        // 2. Parse request body
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

        let request = try JSONDecoder().decode(CreateStatusRequest.self, from: bodyData)

        // 3. Validate visibility
        let visibility = request.visibility ?? "public"
        guard ["public", "unlisted", "private"].contains(visibility) else {
            if visibility == "direct" {
                return APIGatewayResponse(
                    statusCode: .unprocessableContent,
                    headers: ["content-type": "application/json"],
                    body: #"{"error":"Direct messages are not supported yet"}"#
                )
            }
            return APIGatewayResponse(
                statusCode: .badRequest,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Invalid visibility"}"#
            )
        }

        // 4. Compute to/cc addressing
        guard let addressing = computeAddressing(
            visibility: visibility,
            serverDomain: serverDomain,
            username: username
        ) else {
            return APIGatewayResponse(
                statusCode: .unprocessableContent,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Unsupported visibility for addressing"}"#
            )
        }

        // 5. Generate ULID + timestamp
        let statusId = store.generateULID()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let published = formatter.string(from: Date())

        // 6. Convert text to HTML
        let htmlContent = convertTextToHTML(request.status)

        // 7. Look up media attachments if provided
        var attachments: [MediaAttachmentRef]?
        if let mediaIds = request.mediaIds, !mediaIds.isEmpty {
            var refs: [MediaAttachmentRef] = []
            for mediaId in mediaIds {
                if let ref = try await store.getMediaMetadata(id: mediaId, serverDomain: serverDomain) {
                    refs.append(ref)
                }
            }
            if !refs.isEmpty {
                attachments = refs
            }
        }

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

        // 8. Build status
        let statusUrl = "https://\(serverDomain)/@\(username)/\(statusId)"
        let statusUri = "https://\(serverDomain)/users/\(username)/statuses/\(statusId)"

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

        // 9. Store status in DynamoDB
        try await store.storeStatus(status)

        // 10. Increment status count
        try await store.incrementStatusCount(username: username)

        // 11. Build Note + Create activity JSON
        let noteJSON = buildNoteJSON(status: status, serverDomain: serverDomain, username: username)
        let createJSON = buildCreateActivityJSON(
            status: status, noteJSON: noteJSON,
            serverDomain: serverDomain, username: username
        )

        // 12. Delivery fan-out (public/unlisted/private all deliver to followers)
        let followers = try await store.listAllFollowers(username: username)

        if !followers.isEmpty {
            // Group by shared inbox for coalescing
            var inboxToJob: [String: DeliveryJob] = [:]
            for follower in followers {
                let targetInbox = follower.sharedInboxUrl ?? follower.inboxUrl
                if inboxToJob[targetInbox] == nil {
                    inboxToJob[targetInbox] = DeliveryJob(
                        targetInbox: targetInbox,
                        activityJSON: createJSON,
                        actorUsername: username
                    )
                }
            }

            let jobs = Array(inboxToJob.values)
            try await sqsClient.enqueueBatch(jobs: jobs)

            context.logger.info("Enqueued \(jobs.count) delivery jobs for status \(statusId) (\(followers.count) followers)")
        }

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

        // 13. CloudFront invalidation for outbox + profile page
        if !distributionId.isEmpty {
            let activityPaths = [
                "/users/\(username)/outbox*",
                "/profile/\(username)*"
            ]
            let invalidation = CloudFrontClientTypes.InvalidationBatch(
                callerReference: "post-\(statusId)",
                paths: CloudFrontClientTypes.Paths(
                    items: activityPaths,
                    quantity: Int(activityPaths.count)
                )
            )
            _ = try? await cfClient.createInvalidation(input: CreateInvalidationInput(
                distributionId: distributionId,
                invalidationBatch: invalidation
            ))

            // Also invalidate the happitec.com CloudFront distribution (proxies same paths)
            if !proxyDistributionId.isEmpty {
                let happitecPaths = [
                    "/users/\(username)/outbox*",
                    "/profile/\(username)*",
                    "/@\(username)*"
                ]
                let happitecInvalidation = CloudFrontClientTypes.InvalidationBatch(
                    callerReference: "post-happitec-\(statusId)",
                    paths: CloudFrontClientTypes.Paths(
                        items: happitecPaths,
                        quantity: Int(happitecPaths.count)
                    )
                )
                _ = try? await cfClient.createInvalidation(input: CreateInvalidationInput(
                    distributionId: proxyDistributionId,
                    invalidationBatch: happitecInvalidation
                ))
            }
        }

        // 14. Return status response
        let response = buildStatusResponse(status: status, serverDomain: serverDomain)

        return APIGatewayResponse(
            statusCode: .ok,
            headers: ["content-type": "application/json"],
            body: response
        )

    } catch let error as DecodingError {
        context.logger.error("Failed to decode request: \(error)")
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Invalid request body"}"#
        )
    } catch {
        context.logger.error("PostHandler error: \(error)")
        return APIGatewayResponse(
            statusCode: .internalServerError,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Internal server error"}"#
        )
    }
}

/// Build a Mastodon-compatible Status JSON response.
func buildStatusResponse(status: Status, serverDomain: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    // Build a simplified Mastodon-compatible response
    var mediaAttachments = "[]"
    if let attachments = status.attachments {
        let items = attachments.map { att -> String in
            let desc = att.description.map { "\"\(escapeJSON($0))\"" } ?? "null"
            let bh = att.blurhash.map { "\"\(escapeJSON($0))\"" } ?? "null"
            return """
            {"id":"\(att.id)","type":"\(mediaTypeFromContentType(att.contentType))","url":"\(escapeJSON(att.url))","description":\(desc),"blurhash":\(bh)}
            """
        }
        mediaAttachments = "[\(items.joined(separator: ","))]"
    }

    let cw = status.contentWarning.map { "\"\(escapeJSON($0))\"" } ?? "null"
    let lang = status.language.map { "\"\(escapeJSON($0))\"" } ?? "null"
    let replyTo = status.inReplyTo.map { "\"\(escapeJSON($0))\"" } ?? "null"
    let quotedUri = status.quotedStatusUri.map { "\"\(escapeJSON($0))\"" } ?? "null"
    let quoteState = status.quoteApprovalState.map { "\"\(escapeJSON($0))\"" } ?? "null"

    return """
    {"id":"\(status.id)","created_at":"\(escapeJSON(status.published))","visibility":"\(status.visibility)","sensitive":\(status.sensitive),"spoiler_text":\(cw),"content":"\(escapeJSON(status.content))","url":"\(escapeJSON(status.url))","uri":"\(escapeJSON(status.uri))","language":\(lang),"in_reply_to_id":\(replyTo),"favourites_count":\(status.likesCount),"reblogs_count":\(status.boostsCount),"replies_count":\(status.repliesCount),"quotes_count":\(status.quotesCount),"quoted_status_uri":\(quotedUri),"quote_approval_state":\(quoteState),"media_attachments":\(mediaAttachments)}
    """
}

func mediaTypeFromContentType(_ contentType: String) -> String {
    if contentType.hasPrefix("image/") { return "image" }
    if contentType.hasPrefix("video/") { return "video" }
    if contentType.hasPrefix("audio/") { return "audio" }
    return "unknown"
}

enum PostError: Error {
    case encodingFailed
}

try await runtime.run()
