import Testing
import OpenAPIRuntime
import OpenAPIURLSession
import Foundation
@testable import APIClient

@Test func nodeInfoDiscovery() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_API_URL"],
        "TEST_API_URL environment variable is required for integration tests"
    )
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.nodeInfoDiscovery()
    switch response {
    case .ok(let ok):
        let body = try ok.body.json
        #expect(body.links.isEmpty == false)
    default:
        Issue.record("Expected 200, got \(response)")
    }
}

@Test func nodeInfo21() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_API_URL"],
        "TEST_API_URL environment variable is required for integration tests"
    )
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.nodeInfo()
    switch response {
    case .ok(let ok):
        let info = try ok.body.json
        #expect(info.software.name == "federated-activity-publisher")
        #expect(info.protocols == ["activitypub"])
        #expect(info.openRegistrations == false)
    default:
        Issue.record("Expected 200, got \(response)")
    }
}
