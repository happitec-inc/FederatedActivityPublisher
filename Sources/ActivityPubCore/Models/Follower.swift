import Foundation

/// A follower record stored in DynamoDB.
///
/// Keyed by `PK=ACTOR#{username}`, `SK=FOLLOWER#{actorUri}`. A GSI1 entry
/// (`GSI1PK=FOLLOWERS#{username}`, `GSI1SK={acceptedAt}`) enables time-ordered listing.
public struct Follower: Codable, Sendable {
    /// The remote actor's ActivityPub URI (e.g. `https://mastodon.social/users/alice`).
    public let actorUri: String
    /// The remote actor's personal inbox URL for direct delivery.
    public let inboxUrl: String
    /// The remote server's shared inbox URL, used for batch delivery optimization.
    public let sharedInboxUrl: String?
    /// The ActivityPub ID of the original Follow activity (used in Accept responses).
    public let followActivityId: String
    /// ISO 8601 timestamp of when the follow was accepted.
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
