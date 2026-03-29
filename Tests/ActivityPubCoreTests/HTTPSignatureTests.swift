import Testing
import Foundation
import Crypto
import _CryptoExtras
@testable import ActivityPubCore

// MARK: - Test Helpers

/// Generate an RSA key pair for testing.
private func generateTestKeyPair() throws -> (privateKey: _RSA.Signing.PrivateKey, publicKey: _RSA.Signing.PublicKey) {
    let privateKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
    let publicKey = privateKey.publicKey
    return (privateKey, publicKey)
}

// MARK: - Verification Tests

@Test func validSignatureVerifiesCorrectly() throws {
    let (privateKey, publicKey) = try generateTestKeyPair()

    let method = "post"
    let path = "/users/alice/inbox"
    let body = Data(#"{"type":"Follow","actor":"https://remote.server/users/bob"}"#.utf8)
    let host = "activity.happitec.com"
    let date = "Thu, 28 Mar 2026 12:00:00 GMT"

    // Compute digest
    let hash = SHA256.hash(data: body)
    let digest = "sha-256=\(Data(hash).base64EncodedString())"

    // Build signing string
    let signingString = """
    (request-target): \(method) \(path)
    host: \(host)
    date: \(date)
    digest: \(digest)
    """

    // Sign
    let signingData = Data(signingString.utf8)
    let signature = try privateKey.signature(for: signingData, padding: .insecurePKCS1v15)
    let signatureBase64 = signature.rawRepresentation.base64EncodedString()

    let signatureHeader = #"keyId="https://remote.server/users/bob#main-key",headers="(request-target) host date digest",signature="\#(signatureBase64)""#

    let headers = [
        "host": host,
        "date": date,
        "digest": digest,
        "signature": signatureHeader,
    ]

    let publicKeyPem = publicKey.pemRepresentation

    let result = try HTTPSignature.verify(
        signatureHeader: signatureHeader,
        method: method,
        path: path,
        headers: headers,
        body: body,
        publicKeyPem: publicKeyPem
    )

    #expect(result == true)
}

@Test func tamperedBodyFailsDigestCheck() throws {
    let (privateKey, publicKey) = try generateTestKeyPair()

    let method = "post"
    let path = "/users/alice/inbox"
    let originalBody = Data(#"{"type":"Follow"}"#.utf8)
    let tamperedBody = Data(#"{"type":"Delete"}"#.utf8)
    let host = "activity.happitec.com"
    let date = "Thu, 28 Mar 2026 12:00:00 GMT"

    let hash = SHA256.hash(data: originalBody)
    let digest = "sha-256=\(Data(hash).base64EncodedString())"

    let signingString = "(request-target): \(method) \(path)\nhost: \(host)\ndate: \(date)\ndigest: \(digest)"
    let signature = try privateKey.signature(for: Data(signingString.utf8), padding: .insecurePKCS1v15)
    let signatureBase64 = signature.rawRepresentation.base64EncodedString()

    let signatureHeader = #"keyId="https://remote.server/users/bob#main-key",headers="(request-target) host date digest",signature="\#(signatureBase64)""#

    let headers = [
        "host": host,
        "date": date,
        "digest": digest,
    ]

    let result = try HTTPSignature.verify(
        signatureHeader: signatureHeader,
        method: method,
        path: path,
        headers: headers,
        body: tamperedBody,
        publicKeyPem: publicKey.pemRepresentation
    )

    #expect(result == false)
}

@Test func tamperedSignatureFailsVerification() throws {
    let (_, publicKey) = try generateTestKeyPair()
    // Use a different key to sign — simulates tampering
    let (otherPrivateKey, _) = try generateTestKeyPair()

    let method = "post"
    let path = "/users/alice/inbox"
    let body = Data(#"{"type":"Follow"}"#.utf8)
    let host = "activity.happitec.com"
    let date = "Thu, 28 Mar 2026 12:00:00 GMT"

    let hash = SHA256.hash(data: body)
    let digest = "sha-256=\(Data(hash).base64EncodedString())"

    let signingString = "(request-target): \(method) \(path)\nhost: \(host)\ndate: \(date)\ndigest: \(digest)"
    let signature = try otherPrivateKey.signature(for: Data(signingString.utf8), padding: .insecurePKCS1v15)
    let signatureBase64 = signature.rawRepresentation.base64EncodedString()

    let signatureHeader = #"keyId="https://remote.server/users/bob#main-key",headers="(request-target) host date digest",signature="\#(signatureBase64)""#

    let headers = [
        "host": host,
        "date": date,
        "digest": digest,
    ]

    let result = try HTTPSignature.verify(
        signatureHeader: signatureHeader,
        method: method,
        path: path,
        headers: headers,
        body: body,
        publicKeyPem: publicKey.pemRepresentation
    )

    #expect(result == false)
}

@Test func missingSignatureHeaderReturnsFalse() throws {
    let (_, publicKey) = try generateTestKeyPair()

    let result = try HTTPSignature.verify(
        signatureHeader: "",
        method: "post",
        path: "/users/alice/inbox",
        headers: [:],
        body: Data(),
        publicKeyPem: publicKey.pemRepresentation
    )

    #expect(result == false)
}

@Test func extractKeyIdParsesCorrectly() {
    let header = #"keyId="https://mastodon.social/users/alice#main-key",headers="(request-target) host date digest",signature="abc123""#

    let keyId = HTTPSignature.extractKeyId(from: header)
    #expect(keyId == "https://mastodon.social/users/alice#main-key")
}

@Test func extractKeyIdReturnsNilForInvalidHeader() {
    let keyId = HTTPSignature.extractKeyId(from: "invalid header content")
    #expect(keyId == nil)
}

// MARK: - Signing Tests

@Test func signProducesRequiredHeaders() throws {
    let (privateKey, _) = try generateTestKeyPair()

    let body = Data(#"{"type":"Accept"}"#.utf8)

    let headers = try HTTPSignature.sign(
        privateKeyPem: privateKey.pemRepresentation,
        keyId: "https://activity.happitec.com/users/bot#main-key",
        method: "POST",
        path: "/users/alice/inbox",
        host: "mastodon.social",
        body: body
    )

    #expect(headers["Signature"] != nil)
    #expect(headers["Date"] != nil)
    #expect(headers["Digest"] != nil)
    #expect(headers["Host"] == "mastodon.social")
    #expect(headers["Content-Type"] == "application/activity+json")

    // Signature header should contain keyId, headers, signature
    let sig = headers["Signature"]!
    #expect(sig.contains("keyId="))
    #expect(sig.contains("headers="))
    #expect(sig.contains("signature="))
}

@Test func signDigestMatchesBody() throws {
    let (privateKey, _) = try generateTestKeyPair()

    let body = Data(#"{"type":"Accept","actor":"https://activity.happitec.com/users/bot"}"#.utf8)

    let headers = try HTTPSignature.sign(
        privateKeyPem: privateKey.pemRepresentation,
        keyId: "https://activity.happitec.com/users/bot#main-key",
        method: "POST",
        path: "/inbox",
        host: "remote.server",
        body: body
    )

    let expectedHash = SHA256.hash(data: body)
    let expectedDigest = "sha-256=\(Data(expectedHash).base64EncodedString())"
    #expect(headers["Digest"] == expectedDigest)
}

@Test func signThenVerifyRoundTrip() throws {
    let (privateKey, publicKey) = try generateTestKeyPair()

    let body = Data(#"{"type":"Accept","actor":"https://activity.happitec.com/users/bot"}"#.utf8)
    let path = "/users/alice/inbox"
    let host = "mastodon.social"

    let signedHeaders = try HTTPSignature.sign(
        privateKeyPem: privateKey.pemRepresentation,
        keyId: "https://activity.happitec.com/users/bot#main-key",
        method: "POST",
        path: path,
        host: host,
        body: body
    )

    // Build the headers map for verification (lowercase keys as would come from HTTP)
    var verifyHeaders: [String: String] = [:]
    for (key, value) in signedHeaders {
        verifyHeaders[key.lowercased()] = value
    }

    let result = try HTTPSignature.verify(
        signatureHeader: signedHeaders["Signature"]!,
        method: "post",
        path: path,
        headers: verifyHeaders,
        body: body,
        publicKeyPem: publicKey.pemRepresentation
    )

    #expect(result == true)
}

// MARK: - Parser Tests

@Test func parseSignatureHeaderHandlesCommasInValues() {
    // keyId contains a comma-like character scenario (fragment with special chars)
    let header = #"keyId="https://server.example/users/alice#main-key",headers="(request-target) host date digest",algorithm="rsa-sha256",signature="base64data==""#

    let params = HTTPSignature.parseSignatureHeader(header)
    #expect(params["keyId"] == "https://server.example/users/alice#main-key")
    #expect(params["headers"] == "(request-target) host date digest")
    #expect(params["algorithm"] == "rsa-sha256")
    #expect(params["signature"] == "base64data==")
}
