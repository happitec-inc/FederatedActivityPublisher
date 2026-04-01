import AWSDynamoDB
import Foundation

/// A stored passkey credential for WebAuthn authentication.
public struct PasskeyCredential: Sendable {
    public let credentialId: String
    public let username: String
    public let publicKey: String
    public let publicKeyAlg: Int
    public let signCount: Int
    public let createdAt: String
    public let lastUsedAt: String

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
