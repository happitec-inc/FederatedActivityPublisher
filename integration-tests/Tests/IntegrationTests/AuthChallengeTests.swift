import Testing
import OpenAPIRuntime
import OpenAPIURLSession
import Foundation
@testable import APIClient

@Test func authChallengeReturnsValidJSON() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_API_URL"],
        "TEST_API_URL environment variable is required for integration tests"
    )
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.createAuthChallenge()
    switch response {
    case .ok(let ok):
        let body = try ok.body.json
        #expect(!body.challengeId.isEmpty)
        #expect(!body.challenge.isEmpty)
        #expect(!body.rpId.isEmpty)
        #expect(body.timeout > 0)
        #expect(!body.userVerification.isEmpty)
    default:
        Issue.record("Expected 200, got \(response)")
    }
}

@Test func authChallengeTwoCallsReturnDifferentValues() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_API_URL"],
        "TEST_API_URL environment variable is required for integration tests"
    )
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response1 = try await client.createAuthChallenge()
    let response2 = try await client.createAuthChallenge()

    switch (response1, response2) {
    case (.ok(let ok1), .ok(let ok2)):
        let body1 = try ok1.body.json
        let body2 = try ok2.body.json
        #expect(body1.challengeId != body2.challengeId)
        #expect(body1.challenge != body2.challenge)
    default:
        Issue.record("Expected two 200 responses")
    }
}
