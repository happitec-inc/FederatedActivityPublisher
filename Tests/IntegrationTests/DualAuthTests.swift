import Testing
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Test func postStatusWithBearerTokenWorks() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_API_URL"],
        "TEST_API_URL environment variable is required for integration tests"
    )
    guard let bearerToken = ProcessInfo.processInfo.environment["TEST_BEARER_TOKEN"] else {
        // Skip if no bearer token configured — not all environments have one
        return
    }

    let url = URL(string: "\(baseURL)/api/v1/statuses")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")

    let timestamp = Int(Date().timeIntervalSince1970)
    let body = """
    {"status":"Integration test post \(timestamp)","visibility":"unlisted"}
    """
    request.httpBody = body.data(using: .utf8)

    let session = URLSession(configuration: .default)
    let (data, response) = try await session.data(for: request)
    let httpResponse = response as! HTTPURLResponse

    #expect(httpResponse.statusCode == 200)

    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        #expect(json["id"] != nil)
        #expect(json["content"] != nil)
    }
}

@Test func postStatusWithNoAuthReturns401Or403() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_API_URL"],
        "TEST_API_URL environment variable is required for integration tests"
    )

    let url = URL(string: "\(baseURL)/api/v1/statuses")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body = #"{"status":"This should fail"}"#
    request.httpBody = body.data(using: .utf8)

    let session = URLSession(configuration: .default)
    let (_, response) = try await session.data(for: request)
    let httpResponse = response as! HTTPURLResponse

    // API Gateway may return 403 (missing auth) or Lambda may return 401
    #expect(httpResponse.statusCode == 401 || httpResponse.statusCode == 403)
}
