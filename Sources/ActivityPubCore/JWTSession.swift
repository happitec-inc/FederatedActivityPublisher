/// Stateless JWT session management for browser-facing handlers.
///
/// After a successful WebAuthn authentication, the profile and settings handlers issue a
/// signed session cookie using ``JWTSession/sign(claims:key:)``. Subsequent requests from
/// the browser carry that cookie and are verified with ``JWTSession/verify(jwt:key:expectedIssuer:)``.
///
/// Tokens are HMAC-SHA256 signed (HS256), with no external key store: the signing key comes
/// from SSM (`{ssmKeyPrefix}/jwt-signing-key`) and is passed in by each handler at startup.
/// CSRF protection derives a per-session token from the same key via a second HMAC over
/// `sub + iat`, so CSRF tokens are stateless and rotate with each new session.
///
/// `JWTError` cases propagate through ``BearerAuth`` so that callers can distinguish an
/// expired cookie (redirect to login) from a tampered one (401).
import Crypto
import Foundation

/// Stateless JWT session token management using HMAC-SHA256.
public struct JWTSession: Sendable {

    /// JWT claims for a session token.
    public struct Claims: Codable, Sendable {
        /// Subject: the authenticated username.
        public let sub: String
        /// Issued-at timestamp (seconds since epoch).
        public let iat: Int
        /// Expiry timestamp (seconds since epoch).
        public let exp: Int
        /// Issuer: the server domain (e.g. `activity.happitec.com`).
        public let iss: String

        public init(sub: String, iss: String, duration: TimeInterval = 86400) {
            self.sub = sub
            self.iat = Int(Date().timeIntervalSince1970)
            self.exp = self.iat + Int(duration)
            self.iss = iss
        }

        public init(sub: String, iat: Int, exp: Int, iss: String) {
            self.sub = sub
            self.iat = iat
            self.exp = exp
            self.iss = iss
        }
    }

    /// Sign a JWT with HMAC-SHA256.
    /// Returns the complete JWT string (header.payload.signature).
    public static func sign(claims: Claims, key: String) throws -> String {
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        let encoder = JSONEncoder()
        let payloadData = try encoder.encode(claims)

        let headerB64 = base64urlEncode(Data(header.utf8))
        let payloadB64 = base64urlEncode(payloadData)
        let signingInput = "\(headerB64).\(payloadB64)"

        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(signingInput.utf8),
            using: symmetricKey
        )
        let signatureB64 = base64urlEncode(Data(signature))
        return "\(signingInput).\(signatureB64)"
    }

    /// Verify a JWT and return its claims.
    /// Throws if the signature is invalid, the token is expired, or the issuer is wrong.
    public static func verify(jwt: String, key: String, expectedIssuer: String) throws -> Claims {
        let parts = jwt.split(separator: ".", maxSplits: 2)
        guard parts.count == 3 else {
            throw JWTError.malformed
        }
        let headerB64 = String(parts[0])
        let payloadB64 = String(parts[1])
        let signatureB64 = String(parts[2])

        // Verify signature
        let signingInput = "\(headerB64).\(payloadB64)"
        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        guard let signatureData = base64urlDecode(signatureB64) else {
            throw JWTError.malformed
        }
        guard HMAC<SHA256>.isValidAuthenticationCode(
            signatureData,
            authenticating: Data(signingInput.utf8),
            using: symmetricKey
        ) else {
            throw JWTError.invalidSignature
        }

        // Decode payload
        guard let payloadData = base64urlDecode(payloadB64) else {
            throw JWTError.malformed
        }
        let decoder = JSONDecoder()
        let claims = try decoder.decode(Claims.self, from: payloadData)

        // Check expiry
        guard claims.exp > Int(Date().timeIntervalSince1970) else {
            throw JWTError.expired
        }

        // Check issuer
        guard claims.iss == expectedIssuer else {
            throw JWTError.invalidIssuer
        }

        return claims
    }

    /// Derive a CSRF token from the signing key and session claims.
    /// HMAC-SHA256(key: signingKey, message: sub + iat), truncated to 32 hex chars.
    public static func csrfToken(signingKey: String, sub: String, iat: Int) -> String {
        let key = SymmetricKey(data: Data(signingKey.utf8))
        let message = "\(sub)\(iat)"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: key
        )
        return Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Verify a CSRF token against the expected value.
    public static func verifyCSRF(token: String, signingKey: String, sub: String, iat: Int) -> Bool {
        let expected = csrfToken(signingKey: signingKey, sub: sub, iat: iat)
        // Constant-time comparison
        guard token.count == expected.count else { return false }
        var result: UInt8 = 0
        for (a, b) in zip(token.utf8, expected.utf8) {
            result |= a ^ b
        }
        return result == 0
    }
}

public enum JWTError: Error, Sendable {
    /// The token does not have exactly three dot-separated parts, or a part cannot be base64url-decoded.
    case malformed
    /// The HMAC-SHA256 signature does not match the header and payload.
    case invalidSignature
    /// The `exp` claim is in the past.
    case expired
    /// The `iss` claim does not match the expected server domain.
    case invalidIssuer
}

// MARK: - Base64URL helpers

/// Encode data as base64url (RFC 4648 §5): replaces `+` with `-`, `/` with `_`, strips `=` padding.
public func base64urlEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Decode a base64url string, re-adding `=` padding before calling the standard decoder.
public func base64urlDecode(_ string: String) -> Data? {
    var base64 = string
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 {
        base64 += "="
    }
    return Data(base64Encoded: base64)
}
