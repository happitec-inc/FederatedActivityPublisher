import AWSLambdaEvents
import AWSLambdaRuntime
import AWSCloudFront
import AWSS3
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
let mediaBucketName = ProcessInfo.processInfo.environment["MEDIA_BUCKET_NAME"] ?? ""
let distributionId = ProcessInfo.processInfo.environment["CLOUDFRONT_DISTRIBUTION_ID"] ?? ""
let happitecDistributionId = ProcessInfo.processInfo.environment["HAPPITEC_DISTRIBUTION_ID"] ?? ""
let ssmKeyPrefixRaw = ProcessInfo.processInfo.environment["SSM_KEY_PREFIX"] ?? "/activity/stage/keys/"
let ssmKeyPrefix = ssmKeyPrefixRaw.hasSuffix("/") ? String(ssmKeyPrefixRaw.dropLast()) : ssmKeyPrefixRaw

let store = try await DynamoDBStore()
let s3Client = try await S3Client()
let sqsClient = try await SQSDeliveryClient()
let ssmClient = try await SSMClient()
let cfClient = try await CloudFrontClient()

/// Maximum file size for avatar and header images (2 MB).
let maxImageSize = 2 * 1024 * 1024

/// Allowed content types for avatar and header images.
let allowedImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif"]

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    do {
        // 1. Authenticate via bearer token
        let authHeader = event.headers["authorization"] ?? event.headers["Authorization"] ?? ""
        let authResult: BearerAuthResult
        do {
            authResult = try await authenticateBearer(
                authHeader: authHeader,
                ssmKeyPrefix: ssmKeyPrefix,
                ssmClient: ssmClient
            )
        } catch BearerAuthError.missingHeader {
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
            context.logger.error("Bearer auth error: \(error)")
            return APIGatewayResponse(
                statusCode: .internalServerError,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Server configuration error"}"#
            )
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

        // 3. Parse multipart form data
        let contentTypeHeader = event.headers["content-type"] ?? event.headers["Content-Type"] ?? ""
        guard let boundary = extractBoundary(from: contentTypeHeader) else {
            return APIGatewayResponse(
                statusCode: .badRequest,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Missing or invalid Content-Type boundary"}"#
            )
        }

        let parts = parseMultipart(data: bodyData, boundary: boundary)

        // 4. Extract fields from multipart parts
        var newDisplayName: String?
        var newNote: String?
        var avatarPart: MultipartPart?
        var headerPart: MultipartPart?
        var fieldEntries: [(Int, String, String)] = []  // (index, name/value, value)
        var hasFieldsAttributes = false

        for part in parts {
            guard let name = part.name else { continue }

            switch name {
            case "display_name":
                if let data = part.data, let value = String(data: data, encoding: .utf8) {
                    newDisplayName = value
                }
            case "note":
                if let data = part.data, let value = String(data: data, encoding: .utf8) {
                    newNote = value
                }
            case "avatar":
                avatarPart = part
            case "header":
                headerPart = part
            default:
                // Parse fields_attributes[N][name] and fields_attributes[N][value]
                if name.hasPrefix("fields_attributes[") {
                    hasFieldsAttributes = true
                    if let data = part.data, let value = String(data: data, encoding: .utf8) {
                        // Extract index and key from "fields_attributes[0][name]"
                        let stripped = name.dropFirst("fields_attributes[".count)
                        if let closeBracket = stripped.firstIndex(of: "]") {
                            let indexStr = stripped[..<closeBracket]
                            if let index = Int(indexStr) {
                                let rest = stripped[stripped.index(after: closeBracket)...]
                                if rest.hasPrefix("[name]") {
                                    fieldEntries.append((index, "name", value))
                                } else if rest.hasPrefix("[value]") {
                                    fieldEntries.append((index, "value", value))
                                }
                            }
                        }
                    }
                }
            }
        }

        // 5. Validate and upload avatar
        var newAvatarUrl: String?
        if let avatarPart, let avatarData = avatarPart.data, !avatarData.isEmpty {
            let contentType = avatarPart.contentType ?? "application/octet-stream"
            guard allowedImageTypes.contains(contentType) else {
                return APIGatewayResponse(
                    statusCode: .unprocessableContent,
                    headers: ["content-type": "application/json"],
                    body: #"{"error":"Avatar must be PNG, JPEG, or GIF"}"#
                )
            }
            guard avatarData.count <= maxImageSize else {
                return APIGatewayResponse(
                    statusCode: .contentTooLarge,
                    headers: ["content-type": "application/json"],
                    body: #"{"error":"Avatar exceeds 2 MB limit"}"#
                )
            }

            let s3Key = "media/avatars/\(username)"
            let putInput = PutObjectInput(
                body: .data(avatarData),
                bucket: mediaBucketName,
                contentType: contentType,
                key: s3Key
            )
            _ = try await s3Client.putObject(input: putInput)
            newAvatarUrl = "https://\(serverDomain)/\(s3Key)"
        }

        // 6. Validate and upload header
        var newHeaderUrl: String?
        if let headerPart, let headerData = headerPart.data, !headerData.isEmpty {
            let contentType = headerPart.contentType ?? "application/octet-stream"
            guard allowedImageTypes.contains(contentType) else {
                return APIGatewayResponse(
                    statusCode: .unprocessableContent,
                    headers: ["content-type": "application/json"],
                    body: #"{"error":"Header must be PNG, JPEG, or GIF"}"#
                )
            }
            guard headerData.count <= maxImageSize else {
                return APIGatewayResponse(
                    statusCode: .contentTooLarge,
                    headers: ["content-type": "application/json"],
                    body: #"{"error":"Header exceeds 2 MB limit"}"#
                )
            }

            let s3Key = "media/headers/\(username)"
            let putInput = PutObjectInput(
                body: .data(headerData),
                bucket: mediaBucketName,
                contentType: contentType,
                key: s3Key
            )
            _ = try await s3Client.putObject(input: putInput)
            newHeaderUrl = "https://\(serverDomain)/\(s3Key)"
        }

        // 7. Build profile fields if provided
        var newFieldsJSON: String?
        if hasFieldsAttributes {
            // Assemble fields from entries, max 4 fields (indices 0-3)
            var fieldsByIndex: [Int: (name: String?, value: String?)] = [:]
            for (index, key, value) in fieldEntries {
                guard index >= 0, index <= 3 else { continue }
                var entry = fieldsByIndex[index] ?? (name: nil, value: nil)
                if key == "name" {
                    entry.name = value
                } else {
                    entry.value = value
                }
                fieldsByIndex[index] = entry
            }

            var profileFields: [ProfileField] = []
            for index in 0...3 {
                if let entry = fieldsByIndex[index],
                   let name = entry.name, !name.isEmpty,
                   let value = entry.value {
                    profileFields.append(ProfileField(name: name, value: value))
                }
            }
            newFieldsJSON = encodeProfileFields(profileFields)
        }

        // 8. Convert note to HTML if provided
        var newSummary: String?
        if let note = newNote {
            newSummary = convertTextToHTML(note)
        }

        // 9. Update actor in DynamoDB
        try await store.updateActorProfile(
            username: username,
            displayName: newDisplayName,
            summary: newSummary,
            avatarUrl: newAvatarUrl,
            headerUrl: newHeaderUrl,
            fields: newFieldsJSON
        )

        // 10. Fetch updated actor
        guard let actor = try await store.getActor(username: username) else {
            return APIGatewayResponse(
                statusCode: .internalServerError,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Failed to fetch updated actor"}"#
            )
        }

        // 11. Build Mastodon-compatible account JSON response
        let response = buildAccountJSON(actor: actor, serverDomain: serverDomain)

        // 12. Build Update activity and fan out to followers
        let actorJSONLD = buildActorJSONLD(actor: actor, serverDomain: serverDomain, handleDomain: handleDomain)
        let updateId = store.generateULID()
        let actorUrl = "https://\(serverDomain)/users/\(username)"
        let updateActivityJSON = buildUpdateActivityJSON(
            updateId: updateId,
            actorUrl: actorUrl,
            username: username,
            serverDomain: serverDomain,
            actorJSONLD: actorJSONLD
        )

        let followers = try await store.listAllFollowers(username: username)
        if !followers.isEmpty {
            var inboxToJob: [String: DeliveryJob] = [:]
            for follower in followers {
                let targetInbox = follower.sharedInboxUrl ?? follower.inboxUrl
                if inboxToJob[targetInbox] == nil {
                    inboxToJob[targetInbox] = DeliveryJob(
                        targetInbox: targetInbox,
                        activityJSON: updateActivityJSON,
                        actorUsername: username
                    )
                }
            }
            let jobs = Array(inboxToJob.values)
            try await sqsClient.enqueueBatch(jobs: jobs)
            context.logger.info("Enqueued \(jobs.count) Update delivery jobs for \(username) (\(followers.count) followers)")
        }

        // 13. Invalidate CloudFront cache
        if !distributionId.isEmpty {
            var invalidationPaths = [
                "/users/\(username)",
                "/.well-known/webfinger*",
            ]
            if newAvatarUrl != nil {
                invalidationPaths.append("/media/avatars/\(username)")
            }
            if newHeaderUrl != nil {
                invalidationPaths.append("/media/headers/\(username)")
            }

            let invalidation = CloudFrontClientTypes.InvalidationBatch(
                callerReference: "profile-update-\(updateId)",
                paths: CloudFrontClientTypes.Paths(
                    items: invalidationPaths,
                    quantity: Int(invalidationPaths.count)
                )
            )
            _ = try? await cfClient.createInvalidation(input: CreateInvalidationInput(
                distributionId: distributionId,
                invalidationBatch: invalidation
            ))

            // Also invalidate the happitec.com CloudFront distribution (proxies same paths)
            if !happitecDistributionId.isEmpty {
                let happitecInvalidation = CloudFrontClientTypes.InvalidationBatch(
                    callerReference: "profile-update-happitec-\(updateId)",
                    paths: CloudFrontClientTypes.Paths(
                        items: invalidationPaths,
                        quantity: Int(invalidationPaths.count)
                    )
                )
                _ = try? await cfClient.createInvalidation(input: CreateInvalidationInput(
                    distributionId: happitecDistributionId,
                    invalidationBatch: happitecInvalidation
                ))
            }
        }

        // 14. Return response
        return APIGatewayResponse(
            statusCode: .ok,
            headers: ["content-type": "application/json"],
            body: response
        )

    } catch {
        context.logger.error("ProfileUpdateHandler error: \(error)")
        return APIGatewayResponse(
            statusCode: .internalServerError,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Internal server error"}"#
        )
    }
}

/// Build a Mastodon-compatible account JSON response.
func buildAccountJSON(actor: Actor, serverDomain: String) -> String {
    let avatarUrl = actor.avatarUrl ?? ""
    let headerUrl = actor.headerUrl ?? ""

    // Build fields array
    var fieldsJSON = "[]"
    if let fieldsStr = actor.fields {
        let fields = parseProfileFields(fieldsStr)
        if !fields.isEmpty {
            let items = fields.map { field -> String in
                let formattedValue = formatFieldValueForAPI(field.value)
                return "{\"name\":\(jsonString(field.name)),\"value\":\(jsonString(formattedValue))}"
            }
            fieldsJSON = "[\(items.joined(separator: ","))]"
        }
    }

    return """
    {"id":"\(escapeJSON(actor.username))","username":"\(escapeJSON(actor.username))","acct":"\(escapeJSON(actor.username))","display_name":\(jsonString(actor.displayName)),"note":\(jsonString(actor.summary)),"url":"https://\(escapeJSON(serverDomain))/@\(escapeJSON(actor.username))","avatar":"\(escapeJSON(avatarUrl))","avatar_static":"\(escapeJSON(avatarUrl))","header":"\(escapeJSON(headerUrl))","header_static":"\(escapeJSON(headerUrl))","locked":false,"bot":true,"created_at":"\(escapeJSON(actor.createdAt))","fields":\(fieldsJSON),"emojis":[],"followers_count":\(actor.followerCount),"following_count":\(actor.followingCount),"statuses_count":\(actor.statusCount)}
    """
}

/// Build an Update activity wrapping the full actor JSON-LD document.
func buildUpdateActivityJSON(
    updateId: String,
    actorUrl: String,
    username: String,
    serverDomain: String,
    actorJSONLD: String
) -> String {
    let publicURI = "https://www.w3.org/ns/activitystreams#Public"
    let followersCollection = "\(actorUrl)/followers"

    let json = """
    {"@context":["https://www.w3.org/ns/activitystreams","https://w3id.org/security/v1",{"toot":"http://joinmastodon.org/ns#","discoverable":"toot:discoverable","indexable":"toot:indexable","featured":{"@id":"toot:featured","@type":"@id"},"featuredTags":{"@id":"toot:featuredTags","@type":"@id"},"attributionDomains":{"@id":"toot:attributionDomains","@type":"@id"},"schema":"http://schema.org#","PropertyValue":"schema:PropertyValue","value":"schema:value","manuallyApprovesFollowers":"as:manuallyApprovesFollowers","sensitive":"as:sensitive"}],"id":"\(actorUrl)#update-\(updateId)","type":"Update","actor":"\(actorUrl)","to":["\(publicURI)"],"cc":["\(followersCollection)"],"object":\(actorJSONLD)}
    """
    return json.trimmingCharacters(in: .whitespacesAndNewlines)
}

try await runtime.run()
