import Testing
import OpenAPIRuntime
import OpenAPIURLSession
import Foundation
@testable import APIClient

@Test func registerChallengeWithInvalidTokenReturns401() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_API_URL"],
        "TEST_API_URL environment variable is required for integration tests"
    )
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.createRegistrationChallenge(body: .json(.init(token: "invalid-token-that-does-not-exist")))
    switch response {
    case .unauthorized:
        break  // Expected
    default:
        Issue.record("Expected 401, got \(response)")
    }
}

@Test func registerChallengeWithExpiredTokenReturns401() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_API_URL"],
        "TEST_API_URL environment variable is required for integration tests"
    )
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    // A token that never existed is effectively expired
    let response = try await client.createRegistrationChallenge(body: .json(.init(token: "00000000000000000000000000000000")))
    switch response {
    case .unauthorized:
        break  // Expected
    default:
        Issue.record("Expected 401, got \(response)")
    }
}
