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
let ssmKeyPrefix = ProcessInfo.processInfo.environment["SSM_KEY_PREFIX"] ?? "/activity/stage/keys"

let store = try await DynamoDBStore()
let s3Client = try await S3Client()
let ssmClient = try await SSMClient()

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    do {
        // 1. Verify bearer token auth
        let authHeader = event.headers["authorization"] ?? event.headers["Authorization"] ?? ""
        guard authHeader.lowercased().hasPrefix("bearer ") else {
            return APIGatewayResponse(
                statusCode: .unauthorized,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Missing or invalid Authorization header"}"#
            )
        }
        let token = String(authHeader.dropFirst(7)).trimmingCharacters(in: .whitespaces)

        let tokenParamName = "\(ssmKeyPrefix)/client-token"
        let tokenOutput = try await ssmClient.getParameter(input: GetParameterInput(
            name: tokenParamName,
            withDecryption: true
        ))
        guard let storedValue = tokenOutput.parameter?.value else {
            context.logger.error("Client token not configured at \(tokenParamName)")
            return APIGatewayResponse(
                statusCode: .internalServerError,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Server configuration error"}"#
            )
        }

        let parts = storedValue.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else {
            return APIGatewayResponse(
                statusCode: .internalServerError,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Server configuration error"}"#
            )
        }
        let username = String(parts[0])
        let storedToken = String(parts[1])

        guard token == storedToken else {
            return APIGatewayResponse(
                statusCode: .unauthorized,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Invalid bearer token"}"#
            )
        }

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

        let descJSON = description.map { "\"\(escapeMediaJSON($0))\"" } ?? "null"

        let response = """
        {"id":"\(mediaId)","type":"\(mediaType)","url":"\(escapeMediaJSON(mediaUrl))","preview_url":"\(escapeMediaJSON(mediaUrl))","description":\(descJSON),"blurhash":null}
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

// MARK: - Multipart Parsing

struct MultipartPart {
    let name: String?
    let filename: String?
    let contentType: String?
    let data: Data?
}

func extractBoundary(from contentType: String) -> String? {
    // Content-Type: multipart/form-data; boundary=----WebKitFormBoundary...
    let parts = contentType.components(separatedBy: ";")
    for part in parts {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("boundary=") {
            var boundary = String(trimmed.dropFirst("boundary=".count))
            // Remove quotes if present
            if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
                boundary = String(boundary.dropFirst().dropLast())
            }
            return boundary
        }
    }
    return nil
}

func parseMultipart(data: Data, boundary: String) -> [MultipartPart] {
    let boundaryData = Data("--\(boundary)".utf8)
    let crlfData = Data("\r\n".utf8)
    let doubleCRLF = Data("\r\n\r\n".utf8)

    var parts: [MultipartPart] = []

    // Split data by boundary
    var ranges: [Range<Data.Index>] = []
    var searchStart = data.startIndex

    while let range = data.range(of: boundaryData, in: searchStart..<data.endIndex) {
        ranges.append(range)
        searchStart = range.upperBound
    }

    for i in 0..<(ranges.count - 1) {
        let partStart = ranges[i].upperBound
        let partEnd = ranges[i + 1].lowerBound

        // Skip CRLF after boundary
        var contentStart = partStart
        if contentStart + crlfData.count <= partEnd,
           data[contentStart..<contentStart + crlfData.count] == crlfData {
            contentStart += crlfData.count
        }

        // Remove trailing CRLF before next boundary
        var contentEnd = partEnd
        if contentEnd >= crlfData.count,
           data[contentEnd - crlfData.count..<contentEnd] == crlfData {
            contentEnd -= crlfData.count
        }

        guard contentStart < contentEnd else { continue }

        let partData = data[contentStart..<contentEnd]

        // Find header/body separator
        guard let headerEnd = partData.range(of: doubleCRLF) else { continue }

        let headerData = partData[partData.startIndex..<headerEnd.lowerBound]
        let bodyData = partData[headerEnd.upperBound..<partData.endIndex]

        guard let headerString = String(data: headerData, encoding: .utf8) else { continue }

        // Parse headers
        var name: String?
        var filename: String?
        var contentType: String?

        for line in headerString.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-disposition:") {
                // Extract name
                if let nameRange = line.range(of: "name=\"") {
                    let afterName = line[nameRange.upperBound...]
                    if let endQuote = afterName.firstIndex(of: "\"") {
                        name = String(afterName[..<endQuote])
                    }
                }
                // Extract filename
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

func escapeMediaJSON(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
}

try await runtime.run()
