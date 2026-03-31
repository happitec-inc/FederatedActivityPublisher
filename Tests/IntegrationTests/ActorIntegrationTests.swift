import Testing
import OpenAPIRuntime
import OpenAPIURLSession
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import APIClient

@Test func actorKnownUser() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_API_URL"],
        "TEST_API_URL environment variable is required for integration tests"
    )
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.getActor(path: .init(username: "randomforms"))
    switch response {
    case .ok(let ok):
        let actor = try ok.body.application_activity_plus_json
        #expect(actor.preferredUsername == "randomforms")
        #expect(actor.publicKey.publicKeyPem.contains("BEGIN PUBLIC KEY") == true)
        #expect(actor.inbox.hasSuffix("/users/randomforms/inbox") == true)
    default:
        Issue.record("Expected 200, got \(response)")
    }
}

@Test func actorUnknownUser() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_API_URL"],
        "TEST_API_URL environment variable is required for integration tests"
    )
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.getActor(path: .init(username: "nonexistent"))
    switch response {
    case .notFound:
        break // expected
    default:
        Issue.record("Expected 404, got \(response)")
    }
}

@Test func actorContentNegotiationHTML() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_API_URL"],
        "TEST_API_URL environment variable is required for integration tests"
    )
    var request = URLRequest(url: URL(string: "\(baseURL)/users/randomforms")!)
    request.setValue("text/html", forHTTPHeaderField: "Accept")
    let (_, response) = try await URLSession.shared.data(for: request)
    let httpResponse = response as! HTTPURLResponse
    // Expect 302 redirect to /@randomforms
    #expect(httpResponse.statusCode == 302 || httpResponse.statusCode == 200)
    if httpResponse.statusCode == 302 {
        let location = httpResponse.value(forHTTPHeaderField: "Location")
        #expect(location?.contains("/@randomforms") == true)
    }
}
