import Foundation

/// A follower record stored in DynamoDB.
public struct Follower: Codable, Sendable {
    public let actorUri: String
    public let inboxUrl: String
    public let sharedInboxUrl: String?
    public let followActivityId: String
    public let acceptedAt: String

    public init(
        actorUri: String,
        inboxUrl: String,
        sharedInboxUrl: String?,
        followActivityId: String,
        acceptedAt: String
    ) {
        self.actorUri = actorUri
        self.inboxUrl = inboxUrl
        self.sharedInboxUrl = sharedInboxUrl
        self.followActivityId = followActivityId
        self.acceptedAt = acceptedAt
    }
}
