import AWSDynamoDB
import Foundation

/// Cached remote actor data (public key, inbox URLs) fetched from their ActivityPub profile.
public struct RemoteActor: Codable, Sendable {
    public let actorUri: String
    public let publicKeyPem: String
    public let preferredUsername: String?
    public let inbox: String
    public let sharedInbox: String?
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
