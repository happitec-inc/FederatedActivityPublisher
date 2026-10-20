import Testing
import Foundation
import Crypto
import _CryptoExtras
@testable import ActivityPubCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Actor-document fetches must carry an HTTP Signature: servers in authorized fetch mode
// (mastodon.social among them) answer an unsigned GET of an actor with 401.

private let keyId = "https://activity.example/users/memes#main-key"

private func signingKey() throws -> (FetchSigningKey, publicKeyPem: String) {
    let privateKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
    return (
        FetchSigningKey(keyId: keyId, privateKeyPem: privateKey.pemRepresentation),
        privateKey.publicKey.pemRepresentation
    )
}

/// The request's headers with lowercased names, as the verifier expects.
private func lowercasedHeaders(_ request: URLRequest) -> [String: String] {
    var headers: [String: String] = [:]
    for (name, value) in request.allHTTPHeaderFields ?? [:] {
        headers[name.lowercased()] = value
    }
    return headers
}

@Test func signedActorFetchVerifiesAgainstPublicKey() throws {
    let (key, publicKeyPem) = try signingKey()
    let url = URL(string: "https://mastodon.example/users/alice")!
    let request = try KeyManager.actorDocumentRequest(url: url, signingKey: key)
    let headers = lowercasedHeaders(request)

    let signature = try #require(headers["signature"])
    let params = HTTPSignature.parseSignatureHeader(signature)
    #expect(params["keyId"] == keyId)
    #expect(params["algorithm"] == "rsa-sha256")
    #expect(params["headers"] == "(request-target) host date")
    #expect(headers["host"] == "mastodon.example")
    #expect(headers["date"] != nil)
    #expect(headers["accept"] == "application/activity+json")

    // What the remote server does: rebuild the signing string for GET of the path, and verify
    let verified = try HTTPSignature.verify(
        signatureHeader: signature,
        method: "get",
        path: "/users/alice",
        headers: headers,
        body: Data(),
        publicKeyPem: publicKeyPem
    )
    #expect(verified)
}

@Test func signedActorFetchCoversQueryAndPort() throws {
    let (key, publicKeyPem) = try signingKey()
    let url = URL(string: "https://mastodon.example:8443/users/alice?format=ap")!
    let request = try KeyManager.actorDocumentRequest(url: url, signingKey: key)
    let headers = lowercasedHeaders(request)
    #expect(headers["host"] == "mastodon.example:8443")

    let signature = try #require(headers["signature"])
    #expect(try HTTPSignature.verify(
        signatureHeader: signature,
        method: "get",
        path: "/users/alice?format=ap",
        headers: headers,
        body: Data(),
        publicKeyPem: publicKeyPem
    ))
    // The signature does not verify for the path without its query string
    #expect(try !HTTPSignature.verify(
        signatureHeader: signature,
        method: "get",
        path: "/users/alice",
        headers: headers,
        body: Data(),
        publicKeyPem: publicKeyPem
    ))
}

@Test func signGetSigningStringCoversRequestTargetHostDate() throws {
    let (key, publicKeyPem) = try signingKey()
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let headers = try HTTPSignature.signGet(
        privateKeyPem: key.privateKeyPem,
        keyId: keyId,
        path: "/users/alice",
        host: "mastodon.example",
        date: date
    )
    #expect(headers["Date"] == "Fri, 15 Jan 2027 08:00:00 GMT")

    let expected = """
        (request-target): get /users/alice
        host: mastodon.example
        date: Fri, 15 Jan 2027 08:00:00 GMT
        """
    let signatureHeader = try #require(headers["Signature"])
    let signatureBase64 = try #require(HTTPSignature.parseSignatureHeader(signatureHeader)["signature"])
    let signatureData = try #require(Data(base64Encoded: signatureBase64))
    let publicKey = try _RSA.Signing.PublicKey(pemRepresentation: publicKeyPem)
    let signature = _RSA.Signing.RSASignature(rawRepresentation: signatureData)
    #expect(publicKey.isValidSignature(signature, for: Data(expected.utf8), padding: .insecurePKCS1v1_5))
}

@Test func actorFetchWithoutSigningKeyIsUnsigned() throws {
    // The request as sent before signed fetches: no Signature, which authorized fetch rejects
    let url = URL(string: "https://mastodon.example/users/alice")!
    let request = try KeyManager.actorDocumentRequest(url: url, signingKey: nil)
    #expect(lowercasedHeaders(request)["signature"] == nil)
}
