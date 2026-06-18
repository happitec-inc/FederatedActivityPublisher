/// A record of a remote actor who follows a local actor, stored in DynamoDB.
///
/// Written by `InboxHandler` when it receives and accepts a Follow activity. The record is read
/// by `PostHandler` when fanning out deliveries: it collects all followers for a given username
/// and enqueues one ``DeliveryJob`` per follower (using `sharedInboxUrl` when available to
/// reduce per-server request count). `UnfollowHandler` deletes the record when an Undo(Follow)
/// arrives. The GSI on `FOLLOWERS#{username}` / `{acceptedAt}` supports time-ordered listing
/// for the followers collection endpoint.
import Foundation

/// A record of a remote actor who follows a local actor.
///
/// Keyed by `PK=ACTOR#{username}`, `SK=FOLLOWER#{actorUri}`. A GSI1 entry on
/// `GSI1PK=FOLLOWERS#{username}` / `GSI1SK={acceptedAt}` enables time-ordered listing.
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

    /// Create a Follower record.
    ///
    /// - Parameters:
    ///   - actorUri: The remote actor's canonical ActivityPub URI.
    ///   - inboxUrl: The remote actor's personal inbox URL.
    ///   - sharedInboxUrl: The remote server's shared inbox, if advertised; `nil` falls back to `inboxUrl`.
    ///   - followActivityId: The AP ID of the Follow activity, included in the Accept response.
    ///   - acceptedAt: ISO 8601 timestamp of acceptance; doubles as the GSI sort key.
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
