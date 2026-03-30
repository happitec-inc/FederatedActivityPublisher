import AWSDynamoDB
import Foundation

/// Cached remote actor data (public key, inbox URLs) fetched from their ActivityPub profile.
///
/// Stored in DynamoDB with `PK=REMOTE_ACTOR#{actorUri}`, `SK=PROFILE` and a 24-hour TTL.
/// Used by ``KeyManager`` to cache public keys for HTTP Signature verification.
public struct RemoteActor: Codable, Sendable {
    /// The remote actor's canonical ActivityPub URI.
    public let actorUri: String
    /// PEM-encoded RSA public key for verifying this actor's HTTP Signatures.
    public let publicKeyPem: String
    /// The remote actor's preferred username, if available.
    public let preferredUsername: String?
    /// The remote actor's personal inbox URL.
    public let inbox: String
    /// The remote server's shared inbox URL.
    public let sharedInbox: String?
    /// ISO 8601 timestamp of when this cache entry was fetched.
    public let fetchedAt: String

    public init(
        actorUri: String,
        publicKeyPem: String,
        preferredUsername: String?,
        inbox: String,
        sharedInbox: String?,
        fetchedAt: String
    ) {
        self.actorUri = actorUri
        self.publicKeyPem = publicKeyPem
        self.preferredUsername = preferredUsername
        self.inbox = inbox
        self.sharedInbox = sharedInbox
        self.fetchedAt = fetchedAt
    }

    /// Convert a DynamoDB attribute map to a RemoteActor, returning nil if required fields are missing.
    public static func fromDynamoDB(_ attributes: [String: DynamoDBClientTypes.AttributeValue]) -> RemoteActor? {
        guard
            case .s(let actorUri) = attributes["actorUri"],
            case .s(let publicKeyPem) = attributes["publicKeyPem"],
            case .s(let inbox) = attributes["inbox"],
            case .s(let fetchedAt) = attributes["fetchedAt"]
        else {
            return nil
        }

        var preferredUsername: String?
        if case .s(let name) = attributes["preferredUsername"] {
            preferredUsername = name
        }

        var sharedInbox: String?
        if case .s(let url) = attributes["sharedInbox"] {
            sharedInbox = url
        }

        return RemoteActor(
            actorUri: actorUri,
            publicKeyPem: publicKeyPem,
            preferredUsername: preferredUsername,
            inbox: inbox,
            sharedInbox: sharedInbox,
            fetchedAt: fetchedAt
        )
    }

    /// Convert to DynamoDB attribute map.
    public func toDynamoDB() -> [String: DynamoDBClientTypes.AttributeValue] {
        var item: [String: DynamoDBClientTypes.AttributeValue] = [
            "actorUri": .s(actorUri),
            "publicKeyPem": .s(publicKeyPem),
            "inbox": .s(inbox),
            "fetchedAt": .s(fetchedAt),
        ]
        if let preferredUsername {
            item["preferredUsername"] = .s(preferredUsername)
        }
        if let sharedInbox {
            item["sharedInbox"] = .s(sharedInbox)
        }
        return item
    }
}
