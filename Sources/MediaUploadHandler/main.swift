import AWSLambdaEvents
import AWSLambdaRuntime
import AWSS3
import AWSSSM
import ActivityPubCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] ?? "activity.happitec.com"
let mediaBucketName = ProcessInfo.processInfo.environment["MEDIA_BUCKET_NAME"] ?? ""
let ssmKeyPrefixRaw = ProcessInfo.processInfo.environment["SSM_KEY_PREFIX"] ?? "/activity/stage/keys/"
let ssmKeyPrefix = ssmKeyPrefixRaw.hasSuffix("/") ? String(ssmKeyPrefixRaw.dropLast()) : ssmKeyPrefixRaw

let store = try await DynamoDBStore()
let s3Client = try await S3Client()
let ssmClient = try await SSMClient()

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    do {
        // 1. Verify bearer token auth
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

        // 2. Parse the request body (multipart or base64)
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

        let multipartParts = parseMultipart(data: bodyData, boundary: boundary)

        // Find the file part
        guard let filePart = multipartParts.first(where: { $0.name == "file" }),
              let fileData = filePart.data, !fileData.isEmpty else {
            return APIGatewayResponse(
                statusCode: .badRequest,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Missing file in upload"}"#
            )
        }

        // Get optional description (alt text)
        let description = multipartParts.first(where: { $0.name == "description" })
            .flatMap { part in part.data.flatMap { String(data: $0, encoding: .utf8) } }

        // 4. Generate media ID
        let mediaId = store.generateULID()

        // Determine content type and filename
        let fileContentType = filePart.contentType ?? "application/octet-stream"
        let filename = filePart.filename ?? "upload"
        let s3Key = "media/\(mediaId)/\(filename)"

        // 5. Upload to S3
        let putInput = PutObjectInput(
            body: .data(fileData),
            bucket: mediaBucketName,
            contentType: fileContentType,
            key: s3Key
        )
        _ = try await s3Client.putObject(input: putInput)

        // 6. Store metadata in DynamoDB
        try await store.storeMediaMetadata(
            id: mediaId,
            username: username,
            s3Key: s3Key,
            contentType: fileContentType,
            description: description,
            blurhash: nil,
            width: nil,
            height: nil,
            size: fileData.count
        )

        // 7. Build response
        let mediaUrl = "https://\(serverDomain)/\(s3Key)"
        let mediaType: String
        if fileContentType.hasPrefix("image/") {
            mediaType = "image"
        } else if fileContentType.hasPrefix("video/") {
            mediaType = "video"
        } else if fileContentType.hasPrefix("audio/") {
            mediaType = "audio"
        } else {
            mediaType = "unknown"
        }

        let descJSON = description.map { "\"\(escapeJSON($0))\"" } ?? "null"

        let response = """
        {"id":"\(mediaId)","type":"\(mediaType)","url":"\(escapeJSON(mediaUrl))","preview_url":"\(escapeJSON(mediaUrl))","description":\(descJSON),"blurhash":null}
        """

        return APIGatewayResponse(
            statusCode: .ok,
            headers: ["content-type": "application/json"],
            body: response
        )

    } catch {
        context.logger.error("MediaUploadHandler error: \(error)")
        return APIGatewayResponse(
            statusCode: .internalServerError,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Internal server error"}"#
        )
    }
}

try await runtime.run()
