import Testing
@testable import ActivityPubCore
import Foundation

@Suite("JWT session management")
struct JWTSessionTests {

    let testKey = "test-signing-key-at-least-32-characters-long"
    let testIssuer = "test.example.com"

    @Test("Sign and verify round-trip")
    func signAndVerify() throws {
        let claims = JWTSession.Claims(sub: "testuser", iss: testIssuer)
        let jwt = try JWTSession.sign(claims: claims, key: testKey)

        let verified = try JWTSession.verify(jwt: jwt, key: testKey, expectedIssuer: testIssuer)
        #expect(verified.sub == "testuser")
        #expect(verified.iss == testIssuer)
        #expect(verified.exp > verified.iat)
    }

    @Test("Reject expired tokens")
    func rejectExpired() throws {
        // Create a token that expired 1 hour ago
        let iat = Int(Date().timeIntervalSince1970) - 7200
        let exp = iat + 3600  // Expired 1 hour ago
        let claims = JWTSession.Claims(sub: "testuser", iat: iat, exp: exp, iss: testIssuer)
        let jwt = try JWTSession.sign(claims: claims, key: testKey)

        #expect(throws: JWTError.expired) {
            _ = try JWTSession.verify(jwt: jwt, key: testKey, expectedIssuer: testIssuer)
        }
    }

    @Test("Reject tampered tokens")
    func rejectTampered() throws {
        let claims = JWTSession.Claims(sub: "testuser", iss: testIssuer)
        let jwt = try JWTSession.sign(claims: claims, key: testKey)

        // Tamper with the payload
        var parts = jwt.split(separator: ".")
        parts[1] = "dGFtcGVyZWQ"  // "tampered" in base64
        let tampered = parts.joined(separator: ".")

        #expect(throws: (any Error).self) {
            _ = try JWTSession.verify(jwt: tampered, key: testKey, expectedIssuer: testIssuer)
        }
    }

    @Test("Reject wrong issuer")
    func rejectWrongIssuer() throws {
        let claims = JWTSession.Claims(sub: "testuser", iss: "wrong.example.com")
        let jwt = try JWTSession.sign(claims: claims, key: testKey)

        #expect(throws: JWTError.invalidIssuer) {
            _ = try JWTSession.verify(jwt: jwt, key: testKey, expectedIssuer: testIssuer)
        }
    }

    @Test("Reject wrong key")
    func rejectWrongKey() throws {
        let claims = JWTSession.Claims(sub: "testuser", iss: testIssuer)
        let jwt = try JWTSession.sign(claims: claims, key: testKey)

        #expect(throws: JWTError.invalidSignature) {
            _ = try JWTSession.verify(jwt: jwt, key: "wrong-key-completely-different-value", expectedIssuer: testIssuer)
        }
    }

    @Test("Reject malformed JWT")
    func rejectMalformed() {
        #expect(throws: JWTError.malformed) {
            _ = try JWTSession.verify(jwt: "not.a.valid.jwt", key: testKey, expectedIssuer: testIssuer)
        }

        #expect(throws: JWTError.malformed) {
            _ = try JWTSession.verify(jwt: "onlyonepart", key: testKey, expectedIssuer: testIssuer)
        }
    }

    @Test("CSRF token derivation is deterministic")
    func csrfDeterministic() {
        let token1 = JWTSession.csrfToken(signingKey: testKey, sub: "testuser", iat: 1000000)
        let token2 = JWTSession.csrfToken(signingKey: testKey, sub: "testuser", iat: 1000000)
        #expect(token1 == token2)
        #expect(!token1.isEmpty)
        #expect(token1.count == 32)  // 16 bytes = 32 hex chars
    }

    @Test("CSRF token changes with different session")
    func csrfChangesDifferentSession() {
        let token1 = JWTSession.csrfToken(signingKey: testKey, sub: "user1", iat: 1000000)
        let token2 = JWTSession.csrfToken(signingKey: testKey, sub: "user2", iat: 1000000)
        let token3 = JWTSession.csrfToken(signingKey: testKey, sub: "user1", iat: 2000000)
        #expect(token1 != token2)
        #expect(token1 != token3)
    }

    @Test("CSRF verification rejects tampered tokens")
    func csrfRejectsTampered() {
        let valid = JWTSession.csrfToken(signingKey: testKey, sub: "testuser", iat: 1000000)
        #expect(JWTSession.verifyCSRF(token: valid, signingKey: testKey, sub: "testuser", iat: 1000000))
        #expect(!JWTSession.verifyCSRF(token: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0", signingKey: testKey, sub: "testuser", iat: 1000000))
        #expect(!JWTSession.verifyCSRF(token: "", signingKey: testKey, sub: "testuser", iat: 1000000))
    }

    @Test("Base64url encode/decode round-trip")
    func base64urlRoundTrip() {
        let original = Data("Hello, World! This has special chars: +/=".utf8)
        let encoded = base64urlEncode(original)
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))

        let decoded = base64urlDecode(encoded)
        #expect(decoded == original)
    }

    @Test("extractCookie parses cookie header")
    func extractCookieTest() {
        let header = "session=abc123; other=xyz; third=value"
        #expect(extractCookie(name: "session", from: header) == "abc123")
        #expect(extractCookie(name: "other", from: header) == "xyz")
        #expect(extractCookie(name: "missing", from: header) == nil)

        // Single cookie
        #expect(extractCookie(name: "session", from: "session=token") == "token")
    }

    @Test("RequestAuthResult stores method")
    func requestAuthResult() {
        let bearer = RequestAuthResult(username: "user", method: .bearer)
        let session = RequestAuthResult(username: "user", method: .session)
        #expect(bearer.method == .bearer)
        #expect(session.method == .session)
    }

    @Test("BearerAuthError sessionExpired case exists")
    func sessionExpiredCase() {
        let error = BearerAuthError.sessionExpired
        switch error {
        case .sessionExpired: break
        default: Issue.record("Expected sessionExpired")
        }
    }
}
