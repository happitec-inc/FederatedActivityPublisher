import Testing
import OpenAPIRuntime
import OpenAPIURLSession
import HTTPTypes
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import APIClient

/// Injects `Authorization: Bearer <token>` on every request, mirroring how the iOS client's
/// generated `Client` is configured. Lives in the test target so the upload path exercises the
/// real generated multipart encoding rather than a hand-built request.
private struct BearerMiddleware: ClientMiddleware {
    let token: String

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(token)"
        return try await next(request, body, baseURL)
    }
}

/// Smallest valid PNG (1×1, opaque). Non-empty image bytes are all `MediaUploadHandler` requires.
private let onePixelPNG = Data([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
])

/// Regression guard for the "Missing file in upload" bug: the generated swift-openapi-urlsession
/// client must produce multipart/form-data that the server's parser accepts. The hand-rolled parser
/// (replaced by multipart-kit) only matched a quoted `name=` param and dropped the file part.
@Test func uploadMediaWithGeneratedClientReturnsMediaID() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_CLIENT_API_URL"],
        "TEST_CLIENT_API_URL environment variable is required for media upload tests"
    )
    let bearerToken = try #require(
        ProcessInfo.processInfo.environment["TEST_BEARER_TOKEN"],
        "TEST_BEARER_TOKEN environment variable is required for media upload tests"
    )

    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport(),
        middlewares: [BearerMiddleware(token: bearerToken)]
    )

    let parts: [Operations.uploadMedia.Input.Body.multipartFormPayload] = [
        .file(.init(
            payload: .init(body: .init(onePixelPNG)),
            filename: "upload.png"
        )),
        .description(.init(payload: .init(body: .init("Integration test alt text")))),
    ]
    let body = Operations.uploadMedia.Input.Body.multipartForm(.init(parts))

    let response = try await client.uploadMedia(.init(body: body))
    switch response {
    case let .ok(ok):
        let media = try ok.body.json
        #expect(!media.id.isEmpty)
    default:
        Issue.record("Expected 200 OK with a media id, got \(response)")
    }
}

@Test func uploadMediaWithNoAuthIsRejected() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_CLIENT_API_URL"],
        "TEST_CLIENT_API_URL environment variable is required for media upload tests"
    )

    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let parts: [Operations.uploadMedia.Input.Body.multipartFormPayload] = [
        .file(.init(payload: .init(body: .init(onePixelPNG)), filename: "upload.png")),
    ]
    let body = Operations.uploadMedia.Input.Body.multipartForm(.init(parts))

    let response = try await client.uploadMedia(.init(body: body))
    switch response {
    case .unauthorized:
        break  // Expected
    case let .undocumented(statusCode, _):
        // API Gateway may short-circuit missing auth with 403 before the Lambda runs.
        #expect(statusCode == 401 || statusCode == 403)
    default:
        Issue.record("Expected 401/403 for an unauthenticated upload, got \(response)")
    }
}
