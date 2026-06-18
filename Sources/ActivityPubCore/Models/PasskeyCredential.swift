/// A WebAuthn credential registered by a local actor for passwordless authentication.
///
/// Credentials are written to DynamoDB during passkey registration under
/// `PK=PASSKEY#{credentialId}`, `SK=CREDENTIAL`. On each authentication attempt, the
/// `AuthHandler` loads the credential by ID, verifies the authenticator's signature against
/// `publicKey`, and checks that `signCount` has increased (replay prevention). After a
/// successful authentication, `AuthHandler` updates `signCount` and `lastUsedAt` in place.
import AWSDynamoDB
import Foundation

/// A stored passkey credential for WebAuthn authentication.
public struct PasskeyCredential: Sendable {
    /// Base64url-encoded credential ID assigned by the authenticator. Used as the DynamoDB key suffix.
    public let credentialId: String
    /// The local actor this credential belongs to.
    public let username: String
    /// COSE-encoded public key bytes, base64url-encoded. Used to verify authentication assertions.
    public let publicKey: String
    /// COSE algorithm identifier (e.g. `-7` for ES256, `-257` for RS256).
    public let publicKeyAlg: Int
    /// Authenticator signature counter. Must increase on every successful authentication to detect cloned credentials.
    public let signCount: Int
    /// ISO 8601 timestamp of when the credential was registered.
    public let createdAt: String
    /// ISO 8601 timestamp of the most recent successful authentication with this credential.
    public let lastUsedAt: String

    /// Create a PasskeyCredential.
    ///
    /// - Parameters:
    ///   - credentialId: Base64url-encoded credential ID from the authenticator.
    ///   - username: The local actor who registered this credential.
    ///   - publicKey: COSE-encoded public key, base64url-encoded.
    ///   - publicKeyAlg: COSE algorithm integer (e.g. `-7` for ES256).
    ///   - signCount: Initial signature counter value from the registration response.
    ///   - createdAt: ISO 8601 registration timestamp.
    ///   - lastUsedAt: ISO 8601 timestamp of last use; equals `createdAt` on first write.
    public init(
        credentialId: String, username: String, publicKey: String,
        publicKeyAlg: Int, signCount: Int, createdAt: String, lastUsedAt: String
    ) {
        self.credentialId = credentialId
        self.username = username
        self.publicKey = publicKey
        self.publicKeyAlg = publicKeyAlg
        self.signCount = signCount
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    /// Parse a PasskeyCredential from a DynamoDB item.
    ///
    /// Derives `credentialId` from the `PK` attribute by stripping the `PASSKEY#` prefix.
    ///
    /// - Parameter item: The raw DynamoDB attribute map.
    /// - Returns: A populated credential, or `nil` if any required field is missing or malformed.
    public static func fromDynamoDB(_ item: [String: DynamoDBClientTypes.AttributeValue]) -> PasskeyCredential? {
        guard case .s(let pk) = item["PK"],
              pk.hasPrefix("PASSKEY#"),
              case .s(let username) = item["username"],
              case .s(let publicKey) = item["publicKey"],
              case .n(let algStr) = item["publicKeyAlg"], let alg = Int(algStr),
              case .n(let scStr) = item["signCount"], let sc = Int(scStr),
              case .s(let createdAt) = item["createdAt"],
              case .s(let lastUsedAt) = item["lastUsedAt"]
        else { return nil }
        let credentialId = String(pk.dropFirst("PASSKEY#".count))
        return PasskeyCredential(
            credentialId: credentialId, username: username,
            publicKey: publicKey, publicKeyAlg: alg, signCount: sc,
            createdAt: createdAt, lastUsedAt: lastUsedAt
        )
    }
}
