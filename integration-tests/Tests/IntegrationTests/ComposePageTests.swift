import Testing
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Test func composePageWithoutSessionRedirects() async throws {
    let baseURL = try #require(
        ProcessInfo.processInfo.environment["TEST_API_URL"],
        "TEST_API_URL environment variable is required for integration tests"
    )

    // Make a direct request without following redirects
    let url = URL(string: "\(baseURL)/compose")!
    var request = URLRequest(url: url)
    request.httpMethod = "GET"

    // Use a session that does not follow redirects
    let config = URLSessionConfiguration.default
    let delegate = ComposeNoRedirectDelegate()
    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

    let (_, response) = try await session.data(for: request)
    let httpResponse = response as! HTTPURLResponse

    // Should redirect to /auth/login (302)
    #expect(httpResponse.statusCode == 302)
    let location = httpResponse.value(forHTTPHeaderField: "location") ?? ""
    #expect(location.contains("/auth/login"))
}

/// URLSession delegate that prevents automatic redirect following.
final class ComposeNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Return nil to prevent redirect
        completionHandler(nil)
    }
}
