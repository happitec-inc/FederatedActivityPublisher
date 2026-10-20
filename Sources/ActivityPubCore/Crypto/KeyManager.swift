/// Remote actor public key resolution for HTTP Signature verification.
///
/// When the inbox Lambda receives a signed `POST`, it extracts the `keyId` from the
/// `Signature` header and calls ``KeyManager/getPublicKey(keyId:store:)`` to get the
/// corresponding RSA public key. ``HTTPSignature/verify(signatureHeader:method:path:headers:body:publicKeyPem:)``
/// then uses that key to check the signature.
///
/// Keys are cached as ``RemoteActor`` records in DynamoDB with a 24-hour TTL. If verification
/// fails on a cached key (possible after key rotation on the remote side), the inbox handler
/// calls ``KeyManager/refreshKey(keyId:store:)`` to force a fresh fetch before retrying.
///
/// Actor documents are fetched with `Accept: application/activity+json` and a 10-second
/// timeout. The fetch is signed with a local actor's key (``FetchSigningKey``) because servers
/// in authorized fetch mode, mastodon.social among them, answer an unsigned fetch with 401. The same `FoundationNetworking` conditional import pattern as ``FetchRemoteObject``
/// applies here for Linux Lambda compatibility.
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches and caches remote actor public keys for HTTP Signature verification.
///
/// When an inbox Lambda receives a signed request, it uses KeyManager to resolve the
/// signer's public key. Keys are cached in DynamoDB as ``RemoteActor`` records with
/// a 24-hour TTL to avoid refetching on every request.
public struct KeyManager: Sendable {

    /// Create a new key manager.
    public init() {}

    /// Fetch the public key PEM for a given keyId, using the DynamoDB cache.
    ///
    /// - Parameters:
    ///   - keyId: The key ID from the Signature header (e.g., "https://remote.server/users/alice#main-key").
    ///   - store: DynamoDBStore for cache reads/writes.
    ///   - signingKey: Supplies the local actor key that signs the actor-document fetch. Called
    ///     only on a cache miss. If `nil`, the fetch is unsigned, which servers in authorized
    ///     fetch mode reject.
    /// - Returns: The PEM-encoded public key string.
    public func getPublicKey(
        keyId: String,
        store: DynamoDBStore,
        signingKey: (() async throws -> FetchSigningKey)? = nil
    ) async throws -> String {
        let actorUri = extractActorUri(from: keyId)

        // Check cache
        if let cached = try await store.getRemoteActor(actorUri: actorUri) {
            return cached.publicKeyPem
        }

        // Fetch fresh
        let actor = try await fetchActorDocument(actorUri: actorUri, signingKey: try await signingKey?())
        try await store.storeRemoteActor(actor)
        return actor.publicKeyPem
    }

    /// Force-refresh the public key for a given keyId (for key rotation retry).
    ///
    /// `signingKey` is as for ``getPublicKey(keyId:store:signingKey:)``.
    public func refreshKey(
        keyId: String,
        store: DynamoDBStore,
        signingKey: (() async throws -> FetchSigningKey)? = nil
    ) async throws -> String {
        let actorUri = extractActorUri(from: keyId)
        let actor = try await fetchActorDocument(actorUri: actorUri, signingKey: try await signingKey?())
        try await store.storeRemoteActor(actor)
        return actor.publicKeyPem
    }

    /// Extract the actor URI from a keyId by stripping the fragment (e.g., "#main-key").
    public func extractActorUri(from keyId: String) -> String {
        if let hashIndex = keyId.firstIndex(of: "#") {
            return String(keyId[keyId.startIndex..<hashIndex])
        }
        return keyId
    }

    /// Build the `GET` request for a remote actor document, signed if `signingKey` is given.
    ///
    /// The signed `(request-target)` is the URL's path plus its query string, and `host`
    /// carries the port when the URL names one.
    static func actorDocumentRequest(
        url: URL,
        signingKey: FetchSigningKey?,
        date: Date = Date()
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/activity+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let signingKey else { return request }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host else {
            throw KeyManagerError.invalidActorUri(url.absoluteString)
        }
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery {
            path += "?\(query)"
        }
        let hostHeader = components.port.map { "\(host):\($0)" } ?? host

        let signedHeaders = try HTTPSignature.signGet(
            privateKeyPem: signingKey.privateKeyPem,
            keyId: signingKey.keyId,
            path: path,
            host: hostHeader,
            date: date
        )
        for (key, value) in signedHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    /// Fetch a remote actor's ActivityPub document and parse it.
    func fetchActorDocument(actorUri: String, signingKey: FetchSigningKey?) async throws -> RemoteActor {
        guard let url = URL(string: actorUri) else {
            throw KeyManagerError.invalidActorUri(actorUri)
        }

        let request = try Self.actorDocumentRequest(url: url, signingKey: signingKey)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw KeyManagerError.fetchFailed(actorUri, statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KeyManagerError.invalidJSON(actorUri)
        }

        // Extract public key
        guard let publicKeyObj = json["publicKey"] as? [String: Any],
              let publicKeyPem = publicKeyObj["publicKeyPem"] as? String else {
            throw KeyManagerError.missingPublicKey(actorUri)
        }

        // Extract inbox
        guard let inbox = json["inbox"] as? String else {
            throw KeyManagerError.missingInbox(actorUri)
        }

        // Extract optional fields
        let preferredUsername = json["preferredUsername"] as? String
        var sharedInbox: String?
        if let endpoints = json["endpoints"] as? [String: Any] {
            sharedInbox = endpoints["sharedInbox"] as? String
        }

        let formatter = ISO8601DateFormatter()
        let fetchedAt = formatter.string(from: Date())

        return RemoteActor(
            actorUri: actorUri,
            publicKeyPem: publicKeyPem,
            preferredUsername: preferredUsername,
            inbox: inbox,
            sharedInbox: sharedInbox,
            fetchedAt: fetchedAt
        )
    }
}

/// A local actor's key, used to sign fetches of remote actor documents.
public struct FetchSigningKey: Sendable {
    /// The key ID URI (e.g., "https://server/users/alice#main-key").
    public let keyId: String
    /// The PEM-encoded RSA private key matching `keyId`.
    public let privateKeyPem: String

    /// Create a signing key.
    public init(keyId: String, privateKeyPem: String) {
        self.keyId = keyId
        self.privateKeyPem = privateKeyPem
    }
}

/// Errors thrown by ``KeyManager`` when fetching or parsing remote actor documents.
public enum KeyManagerError: Error, CustomStringConvertible {
    /// The actor URI could not be parsed as a URL.
    case invalidActorUri(String)
    /// The HTTP fetch of the actor document returned a non-2xx status code.
    case fetchFailed(String, Int)
    /// The actor document response was not valid JSON.
    case invalidJSON(String)
    /// The actor document did not contain a `publicKey.publicKeyPem` field.
    case missingPublicKey(String)
    /// The actor document did not contain an `inbox` field.
    case missingInbox(String)

    public var description: String {
        switch self {
        case .invalidActorUri(let uri): return "Invalid actor URI: \(uri)"
        case .fetchFailed(let uri, let status): return "Failed to fetch actor \(uri): HTTP \(status)"
        case .invalidJSON(let uri): return "Invalid JSON from actor \(uri)"
        case .missingPublicKey(let uri): return "Missing publicKey in actor document: \(uri)"
        case .missingInbox(let uri): return "Missing inbox in actor document: \(uri)"
        }
    }
}
