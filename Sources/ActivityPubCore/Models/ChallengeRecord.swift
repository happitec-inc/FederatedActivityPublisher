/// A short-lived WebAuthn challenge stored in DynamoDB.
///
/// When a passkey registration or authentication ceremony starts, the server generates a random
/// challenge and writes it here under `PK=PASSKEY_CHALLENGE#{challengeId}`. The client signs
/// the challenge with the device credential, and the server reads this record back to verify the
/// signed response. A DynamoDB TTL attribute removes stale challenges automatically. The
/// challenge byte string is stored base64url-encoded in `challenge`.
import AWSDynamoDB
import Foundation

/// A stored WebAuthn challenge (registration or authentication).
public struct ChallengeRecord: Sendable {
    /// UUID that identifies this challenge, derived from the DynamoDB `PK` by stripping the
    /// `PASSKEY_CHALLENGE#` prefix.
    public let challengeId: String
    /// Base64url-encoded random challenge bytes sent to the authenticator.
    public let challenge: String
    /// Ceremony type: `"registration"` or `"authentication"`.
    public let type: String  // "registration" or "authentication"
    /// Username associated with a registration challenge; absent for authentication challenges
    /// where the user identity is determined from the credential response.
    public let username: String?

    /// Create a ChallengeRecord.
    ///
    /// - Parameters:
    ///   - challengeId: Unique identifier for this challenge (used as the DynamoDB key suffix).
    ///   - challenge: Base64url-encoded random bytes to be signed by the authenticator.
    ///   - type: Either `"registration"` or `"authentication"`.
    ///   - username: For registration challenges, the username being enrolled; `nil` for authentication.
    public init(challengeId: String, challenge: String, type: String, username: String?) {
        self.challengeId = challengeId
        self.challenge = challenge
        self.type = type
        self.username = username
    }

    /// Parse a ChallengeRecord from a DynamoDB item.
    ///
    /// Extracts `challengeId` from the `PK` attribute by stripping the `PASSKEY_CHALLENGE#` prefix.
    ///
    /// - Parameter item: The raw DynamoDB attribute map.
    /// - Returns: A populated record, or `nil` if `PK`, `challenge`, or `type` are missing or malformed.
    public static func fromDynamoDB(_ item: [String: DynamoDBClientTypes.AttributeValue]) -> ChallengeRecord? {
        guard case .s(let pk) = item["PK"],
              pk.hasPrefix("PASSKEY_CHALLENGE#"),
              case .s(let challenge) = item["challenge"],
              case .s(let type) = item["type"]
        else { return nil }
        let challengeId = String(pk.dropFirst("PASSKEY_CHALLENGE#".count))
        var username: String?
        if case .s(let u) = item["username"] { username = u }
        return ChallengeRecord(challengeId: challengeId, challenge: challenge, type: type, username: username)
    }
}
