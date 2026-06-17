import Testing
import OpenAPIRuntime
import OpenAPIURLSession
import HTTPTypes
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import APIClient

/// Contract guard for `GET /api/v1/accounts/verify_credentials`: the generated `Client` must receive
/// a 200 `CredentialAccount` whose full required shape decodes — including the `source` object with
/// the raw editable values (`source.note` and the `source.fields` name/value rows) the editor seeds from.
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
        // Decoding alone enforces every *required* CredentialAccount field is present (the generated
        // types are non-optional for required properties); these assertions document the contract and
        // verify the server populates the identity + the raw `source` the profile editor depends on.
        let account = try ok.body.json
        #expect(!account.id.isEmpty)
        #expect(!account.username.isEmpty)
        // The server sets the account id to the username (documented identity convention).
        #expect(account.id == account.username)

        // `source` carries the RAW editable values. `note` is the raw bio (may be empty for a bot with
        // no bio, but must be present and is a non-optional String). `fields` is the raw name/value list;
        // each row must expose both name and value.
        let source = account.source
        let rawNote: String = source.note
        _ = rawNote
        for field in source.fields {
            let name: String = field.name
            let value: String = field.value
            _ = (name, value)
        }
    default:
        Issue.record("Expected 200 with a CredentialAccount, got \(response)")
    }
}

/// An unauthenticated request must be rejected: the handler returns a documented 401, or the
/// gateway/proxy may short-circuit with a 403 before the Lambda runs.
@Test func verifyCredentialsWithNoAuthIsRejected() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_CLIENT_API_URL"],
        "TEST_CLIENT_API_URL environment variable is required for verify_credentials tests"
    )

    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.verifyCredentials(.init())
    switch response {
    case .unauthorized:
        break  // Expected (documented 401)
    case let .undocumented(statusCode, _):
        #expect(statusCode == 401 || statusCode == 403)
    default:
        Issue.record("Expected 401/403 for an unauthenticated request, got \(response)")
    }
}
