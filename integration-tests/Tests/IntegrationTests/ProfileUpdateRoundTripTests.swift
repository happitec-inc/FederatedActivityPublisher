import Testing
import OpenAPIRuntime
import OpenAPIURLSession
import HTTPTypes
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import APIClient

/// Smallest valid PNG (1×1, opaque). Non-empty image bytes are all the server needs to sniff.
private let onePixelPNG = Data([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
])

/// End-to-end profile-editing guarantee against deployed stage, exercised through the SAME
/// generated client the iOS app uses. `PATCH /api/v1/accounts/update_credentials` (multipart,
/// avatar bytes labeled `text/plain` by the generated client) must persist, then
/// `GET /api/v1/accounts/verify_credentials` must read back the new values — including the raw
/// bio in `source.note` (the round-trip the editor depends on) and the raw `source.fields` rows.
/// This mirrors `MediaUploadIntegrationTests`: it proves the generated client + server contract
/// the app relies on, not a hand-built request.
@Test func updateCredentialsRoundTripsRawNoteFieldsAndAvatar() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_CLIENT_API_URL"],
        "TEST_CLIENT_API_URL environment variable is required for profile-update tests"
    )
    let bearerToken = try #require(
        ProcessInfo.processInfo.environment["TEST_BEARER_TOKEN"],
        "TEST_BEARER_TOKEN environment variable is required for profile-update tests"
    )

    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport(),
        middlewares: [BearerMiddleware(token: bearerToken)]
    )

    let knownName = "Integration Sandbox Bot"
    let knownBio = "round-trip bio for the profile-update integration test"
    let fieldName = "Homepage"
    let fieldValue = "https://happitec.com"

    // 1. PATCH the profile through the generated multipart client. The avatar part is binary
    //    but the generated client labels it text/plain — the server sniffs it back to image/png.
    let parts: [Components.Schemas.UpdateCredentialsRequest] = [
        .display_name(.init(payload: .init(body: .init(knownName)))),
        .note(.init(payload: .init(body: .init(knownBio)))),
        .fields_attributes_lbrack_0_rbrack__lbrack_name_rbrack_(.init(payload: .init(body: .init(fieldName)))),
        .fields_attributes_lbrack_0_rbrack__lbrack_value_rbrack_(.init(payload: .init(body: .init(fieldValue)))),
        .avatar(.init(payload: .init(body: .init(onePixelPNG)), filename: "avatar.png")),
    ]
    let updateBody = Operations.updateCredentials.Input.Body.multipartForm(.init(parts))

    let updateResponse = try await client.updateCredentials(.init(body: updateBody))
    switch updateResponse {
    case .ok:
        break  // Expected: profile accepted (avatar sniffed from text/plain).
    default:
        Issue.record("Expected 200 OK from update_credentials, got \(updateResponse)")
        return
    }

    // 2. Read it back through verify_credentials and assert the round-trip.
    let verifyResponse = try await client.verifyCredentials(.init())
    switch verifyResponse {
    case let .ok(ok):
        let account = try ok.body.json
        #expect(account.display_name == knownName)
        // The RAW bio must round-trip exactly (not the HTML-rendered `note`).
        #expect(account.source.note == knownBio)
        // The raw field row must be present with both name and value.
        #expect(account.source.fields.contains { $0.name == fieldName && $0.value == fieldValue })
        // Avatar was accepted and is now served.
        #expect(account.avatar != nil)
    default:
        Issue.record("Expected 200 with a CredentialAccount, got \(verifyResponse)")
    }
}

/// An unauthenticated `update_credentials` must be rejected (documented 401, or a gateway/proxy
/// 403 short-circuit before the Lambda runs).
@Test func updateCredentialsWithNoAuthIsRejected() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_CLIENT_API_URL"],
        "TEST_CLIENT_API_URL environment variable is required for profile-update tests"
    )

    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let parts: [Components.Schemas.UpdateCredentialsRequest] = [
        .display_name(.init(payload: .init(body: .init("nope")))),
    ]
    let body = Operations.updateCredentials.Input.Body.multipartForm(.init(parts))

    let response = try await client.updateCredentials(.init(body: body))
    switch response {
    case .unauthorized:
        break  // Expected (documented 401)
    case let .undocumented(statusCode, _):
        #expect(statusCode == 401 || statusCode == 403)
    default:
        Issue.record("Expected 401/403 for an unauthenticated update, got \(response)")
    }
}
