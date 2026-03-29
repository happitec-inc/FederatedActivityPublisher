import Testing
import OpenAPIRuntime
import OpenAPIURLSession
import Foundation
@testable import APIClient

@Test func outboxEmpty() async throws {
    guard let baseURL = ProcessInfo.processInfo.environment["TEST_API_URL"] else {
        print("Skipping: TEST_API_URL not set")
        return
    }
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.getOutbox(path: .init(username: "randomforms"))
    switch response {
    case .ok(let ok):
        let collection = try ok.body.json
        #expect(collection.totalItems == 0)
    default:
        Issue.record("Expected 200, got \(response)")
    }
}

@Test func followersEmpty() async throws {
    guard let baseURL = ProcessInfo.processInfo.environment["TEST_API_URL"] else {
        print("Skipping: TEST_API_URL not set")
        return
    }
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.getFollowers(path: .init(username: "randomforms"))
    switch response {
    case .ok(let ok):
        let collection = try ok.body.json
        #expect(collection.totalItems == 0)
    default:
        Issue.record("Expected 200, got \(response)")
    }
}

@Test func followingEmpty() async throws {
    guard let baseURL = ProcessInfo.processInfo.environment["TEST_API_URL"] else {
        print("Skipping: TEST_API_URL not set")
        return
    }
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.getFollowing(path: .init(username: "randomforms"))
    switch response {
    case .ok(let ok):
        let collection = try ok.body.json
        #expect(collection.totalItems == 0)
    default:
        Issue.record("Expected 200, got \(response)")
    }
}

@Test func featuredEmpty() async throws {
    guard let baseURL = ProcessInfo.processInfo.environment["TEST_API_URL"] else {
        print("Skipping: TEST_API_URL not set")
        return
    }
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.getFeatured(path: .init(username: "randomforms"))
    switch response {
    case .ok(let ok):
        let collection = try ok.body.json
        #expect(collection.totalItems == 0)
    default:
        Issue.record("Expected 200, got \(response)")
    }
}

@Test func featuredTagsEmpty() async throws {
    guard let baseURL = ProcessInfo.processInfo.environment["TEST_API_URL"] else {
        print("Skipping: TEST_API_URL not set")
        return
    }
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.getFeaturedTags(path: .init(username: "randomforms"))
    switch response {
    case .ok(let ok):
        let collection = try ok.body.json
        #expect(collection.totalItems == 0)
    default:
        Issue.record("Expected 200, got \(response)")
    }
}

@Test func collectionsReturn404ForUnknownActor() async throws {
    guard let baseURL = ProcessInfo.processInfo.environment["TEST_API_URL"] else {
        print("Skipping: TEST_API_URL not set")
        return
    }
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.getOutbox(path: .init(username: "nonexistent"))
    switch response {
    case .notFound:
        break // expected
    default:
        Issue.record("Expected 404, got \(response)")
    }
}
