import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors that can occur when fetching a remote ActivityPub object.
public enum FetchRemoteObjectError: Error {
    case invalidUri(String)
    case fetchFailed(String, Int)
    case invalidJSON(String)
}

/// Fetch a remote ActivityPub object by URI and return it as a dictionary.
///
/// Sends an HTTP GET with `Accept: application/activity+json` to dereference
/// the object. Used for discovering actor inboxes, status metadata, etc.
///
/// - Parameter uri: The ActivityPub URI to dereference.
/// - Returns: The parsed JSON dictionary.
/// - Throws: `FetchRemoteObjectError` if the fetch fails or the response is not valid JSON.
public func fetchRemoteObject(uri: String) async throws -> [String: Any] {
    guard let url = URL(string: uri) else {
        throw FetchRemoteObjectError.invalidUri(uri)
    }

    var request = URLRequest(url: url)
    request.setValue("application/activity+json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 10

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode) else {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        throw FetchRemoteObjectError.fetchFailed(uri, statusCode)
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw FetchRemoteObjectError.invalidJSON(uri)
    }

    return json
}
