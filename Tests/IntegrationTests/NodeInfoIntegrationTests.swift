import Testing
import OpenAPIRuntime
import OpenAPIURLSession
import Foundation
@testable import APIClient

@Test func nodeInfoDiscovery() async throws {
    guard let baseURL = ProcessInfo.processInfo.environment["TEST_API_URL"] else {
        print("Skipping: TEST_API_URL not set")
        return
    }
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
    guard let baseURL = ProcessInfo.processInfo.environment["TEST_API_URL"] else {
        print("Skipping: TEST_API_URL not set")
        return
    }
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.nodeInfo()
    switch response {
    case .ok(let ok):
        let info = try ok.body.json
        #expect(info.software.name == "activity-happitec")
        #expect(info.protocols == ["activitypub"])
        #expect(info.openRegistrations == false)
    default:
        Issue.record("Expected 200, got \(response)")
    }
}
