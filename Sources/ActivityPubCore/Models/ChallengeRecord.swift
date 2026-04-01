import AWSDynamoDB
import Foundation

/// A stored WebAuthn challenge (registration or authentication).
public struct ChallengeRecord: Sendable {
    public let challengeId: String
    public let challenge: String
    public let type: String  // "registration" or "authentication"
    public let username: String?

    public init(challengeId: String, challenge: String, type: String, username: String?) {
        self.challengeId = challengeId
        self.challenge = challenge
        self.type = type
        self.username = username
    }

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
