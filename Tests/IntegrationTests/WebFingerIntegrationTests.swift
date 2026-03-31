import Testing
import OpenAPIRuntime
import OpenAPIURLSession
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import APIClient

@Test func webFingerKnownActor() async throws {
    guard let baseURL = ProcessInfo.processInfo.environment["TEST_API_URL"] else {
        print("Skipping: TEST_API_URL not set")
        return
    }
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.webfinger(query: .init(resource: "acct:randomforms@happitec.com"))
    switch response {
    case .ok(let ok):
        let jrd = try ok.body.application_jrd_plus_json
        #expect(jrd.subject == "acct:randomforms@happitec.com")
        #expect(jrd.links.isEmpty == false)
        let selfLink = jrd.links.first { $0.rel == "self" }
        #expect(selfLink?.href?.contains("/users/randomforms") == true)
    default:
        Issue.record("Expected 200, got \(response)")
    }
}

@Test func webFingerUnknownActor() async throws {
    guard let baseURL = ProcessInfo.processInfo.environment["TEST_API_URL"] else {
        print("Skipping: TEST_API_URL not set")
        return
    }
    let client = Client(
        serverURL: URL(string: baseURL)!,
        transport: URLSessionTransport()
    )

    let response = try await client.webfinger(query: .init(resource: "acct:nonexistent@happitec.com"))
    switch response {
    case .notFound:
        break // expected
    default:
        Issue.record("Expected 404, got \(response)")
    }
}

@Test func webFingerMissingResource() async throws {
    guard let baseURL = ProcessInfo.processInfo.environment["TEST_API_URL"] else {
        print("Skipping: TEST_API_URL not set")
        return
    }
    let url = URL(string: "\(baseURL)/.well-known/webfinger")! // no resource param
    let (_, response) = try await URLSession.shared.data(from: url)
    let httpResponse = response as! HTTPURLResponse
    #expect(httpResponse.statusCode == 400)
}
