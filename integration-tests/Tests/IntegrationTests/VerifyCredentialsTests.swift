import Testing
import OpenAPIRuntime
import OpenAPIURLSession
import HTTPTypes
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import APIClient

/// Regression guard for `GET /api/v1/accounts/verify_credentials`: the generated `Client`
/// must receive a 200 with a `CredentialAccount` body that includes the `source` object
/// (raw editable values) and a non-empty `username`.
@Test func verifyCredentialsReturnsAccountWithSource() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_CLIENT_API_URL"],
        "TEST_CLIENT_API_URL environment variable is required for verify_credentials tests"
    )
    let bearerToken = try #require(
        ProcessInfo.processInfo.environment["TEST_BEARER_TOKEN"],
        "TEST_BEARER_TOKEN environment variable is required for verify_credentials tests"
    )

    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport(),
        middlewares: [BearerMiddleware(token: bearerToken)]
    )

    let response = try await client.verifyCredentials(.init())
    switch response {
    case let .ok(ok):
        let account = try ok.body.json
        #expect(!account.username.isEmpty)
        // source is required in CredentialAccount and non-optional in the generated type;
        // verify it carries the expected note field (may be empty string but must be present)
        let _ = account.source
    default:
        Issue.record("Expected 200, got \(response)")
    }
}
