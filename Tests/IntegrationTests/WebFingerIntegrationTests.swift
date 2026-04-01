import Testing
import OpenAPIRuntime
import OpenAPIURLSession
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import APIClient

@Test func webFingerKnownActor() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_API_URL"],
        "TEST_API_URL environment variable is required for integration tests"
    )
    let handleDomain = try #require(
        ProcessInfo.processInfo.environment["TEST_HANDLE_DOMAIN"],
        "TEST_HANDLE_DOMAIN environment variable is required for integration tests"
    )
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.webfinger(query: .init(resource: "acct:randomforms@\(handleDomain)"))
    switch response {
    case .ok(let ok):
        let jrd = try ok.body.application_jrd_plus_json
        #expect(jrd.subject == "acct:randomforms@\(handleDomain)")
        #expect(jrd.links.isEmpty == false)
        let selfLink = jrd.links.first { $0.rel == "self" }
        #expect(selfLink?.href?.contains("/users/randomforms") == true)
    default:
        Issue.record("Expected 200, got \(response)")
    }
}

@Test func webFingerUnknownActor() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_API_URL"],
        "TEST_API_URL environment variable is required for integration tests"
    )
    let handleDomain = try #require(
        ProcessInfo.processInfo.environment["TEST_HANDLE_DOMAIN"],
        "TEST_HANDLE_DOMAIN environment variable is required for integration tests"
    )
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.webfinger(query: .init(resource: "acct:nonexistent@\(handleDomain)"))
    switch response {
    case .notFound:
        break // expected
    default:
        Issue.record("Expected 404, got \(response)")
    }
}

@Test func webFingerMissingResource() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_API_URL"],
        "TEST_API_URL environment variable is required for integration tests"
    )
    let url = URL(string: "\(baseURL)/.well-known/webfinger")! // no resource param
    let (_, response) = try await URLSession.shared.data(from: url)
    let httpResponse = response as! HTTPURLResponse
    #expect(httpResponse.statusCode == 400)
}
