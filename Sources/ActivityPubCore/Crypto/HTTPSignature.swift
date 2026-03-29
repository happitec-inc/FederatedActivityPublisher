import Crypto
import _CryptoExtras
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP Signature utilities implementing the Cavage draft for ActivityPub federation.
/// Supports both signing (outbound) and verification (inbound) of HTTP requests.
public enum HTTPSignature: Sendable {

    // MARK: - Verification

    /// Verify the HTTP Signature on an inbound request.
    ///
    /// - Parameters:
    ///   - signatureHeader: The raw `Signature` header value.
    ///   - method: HTTP method (e.g., "POST").
    ///   - path: Request path (e.g., "/users/alice/inbox").
    ///   - headers: All HTTP headers from the request (lowercased keys).
    ///   - body: The raw request body bytes.
    ///   - publicKeyPem: PEM-encoded RSA public key of the remote actor.
    /// - Returns: `true` if the signature is valid.
    public static func verify(
        signatureHeader: String,
        method: String,
        path: String,
        headers: [String: String],
        body: Data,
        publicKeyPem: String
    ) throws -> Bool {
        // Parse signature header fields
        let params = parseSignatureHeader(signatureHeader)
        guard let signedHeadersList = params["headers"],
              let signatureBase64 = params["signature"] else {
            return false
        }

        // Verify Digest header matches body
        let signedHeaders = signedHeadersList.split(separator: " ").map(String.init)
        if signedHeaders.contains("digest") {
            guard let digestHeader = findHeader("digest", in: headers) else {
                return false
            }
            let expectedDigest = computeDigest(body: body)
            // Compare case-insensitively for the prefix (SHA-256= vs sha-256=)
            let normalizedActual = digestHeader.lowercased()
            let normalizedExpected = expectedDigest.lowercased()
            guard normalizedActual == normalizedExpected else {
                return false
            }
        }

        // Reconstruct the signing string
        let signingString = buildSigningString(
            signedHeaders: signedHeaders,
            method: method,
            path: path,
            headers: headers
        )

        // Verify RSA-SHA256 signature
        guard let signatureData = Data(base64Encoded: signatureBase64) else {
            return false
        }

        let publicKey = try _RSA.Signing.PublicKey(pemRepresentation: publicKeyPem)
        let signature = _RSA.Signing.RSASignature(rawRepresentation: signatureData)
        let signingData = Data(signingString.utf8)

        return publicKey.isValidSignature(signature, for: signingData, padding: .insecurePKCS1v15)
    }

    /// Extract the `keyId` value from a Signature header.
    public static func extractKeyId(from signatureHeader: String) -> String? {
        let params = parseSignatureHeader(signatureHeader)
        return params["keyId"]
    }

    // MARK: - Signing

    /// Sign an outbound HTTP request using the Cavage draft format.
    ///
    /// - Parameters:
    ///   - privateKeyPem: PEM-encoded RSA private key.
    ///   - keyId: The key ID URI (e.g., "https://server/users/alice#main-key").
    ///   - method: HTTP method (e.g., "POST").
    ///   - path: Request path (e.g., "/users/bob/inbox").
    ///   - host: The target host (e.g., "remote.server").
    ///   - body: The request body bytes.
    /// - Returns: Dictionary of headers to add to the outbound request.
    public static func sign(
        privateKeyPem: String,
        keyId: String,
        method: String,
        path: String,
        host: String,
        body: Data
    ) throws -> [String: String] {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "GMT")
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let dateString = dateFormatter.string(from: Date())

        let digest = computeDigest(body: body)

        let headersToSign = ["(request-target)", "host", "date", "digest", "content-type"]
        let headerValues: [String: String] = [
            "host": host,
            "date": dateString,
            "digest": digest,
            "content-type": "application/activity+json",
        ]

        let signingString = buildSigningString(
            signedHeaders: headersToSign,
            method: method,
            path: path,
            headers: headerValues
        )

        let privateKey = try _RSA.Signing.PrivateKey(pemRepresentation: privateKeyPem)
        let signingData = Data(signingString.utf8)
        let signature = try privateKey.signature(for: signingData, padding: .insecurePKCS1v15)
        let signatureBase64 = signature.rawRepresentation.base64EncodedString()

        let signatureHeader = #"keyId="\#(keyId)",headers="\#(headersToSign.joined(separator: " "))",signature="\#(signatureBase64)""#

        return [
            "Signature": signatureHeader,
            "Date": dateString,
            "Digest": digest,
            "Host": host,
            "Content-Type": "application/activity+json",
        ]
    }

    // MARK: - Internal Helpers

    /// Parse a Signature header into key-value pairs using regex.
    /// Uses `(\w+)="([^"]*)"` to handle values that may contain commas.
    static func parseSignatureHeader(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"(\w+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return result
        }
        let nsRange = NSRange(header.startIndex..<header.endIndex, in: header)
        let matches = regex.matches(in: header, range: nsRange)
        for match in matches {
            if let keyRange = Range(match.range(at: 1), in: header),
               let valueRange = Range(match.range(at: 2), in: header) {
                result[String(header[keyRange])] = String(header[valueRange])
            }
        }
        return result
    }

    /// Build the signing string from the list of signed headers.
    static func buildSigningString(
        signedHeaders: [String],
        method: String,
        path: String,
        headers: [String: String]
    ) -> String {
        var lines: [String] = []
        for headerName in signedHeaders {
            if headerName == "(request-target)" {
                lines.append("(request-target): \(method.lowercased()) \(path)")
            } else {
                let value = findHeader(headerName, in: headers) ?? ""
                lines.append("\(headerName.lowercased()): \(value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Compute the Digest header value: `sha-256={base64(sha256(body))}`.
    static func computeDigest(body: Data) -> String {
        let hash = SHA256.hash(data: body)
        let base64 = Data(hash).base64EncodedString()
        return "sha-256=\(base64)"
    }

    /// Case-insensitive header lookup.
    static func findHeader(_ name: String, in headers: [String: String]) -> String? {
        let lowered = name.lowercased()
        for (key, value) in headers {
            if key.lowercased() == lowered {
                return value
            }
        }
        return nil
    }
}
