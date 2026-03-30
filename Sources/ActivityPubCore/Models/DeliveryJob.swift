import Foundation

/// An SQS delivery job payload for sending signed HTTP requests to remote inboxes.
///
/// Serialized as JSON and enqueued to SQS by PostHandler/InboxHandler. Consumed by
/// DeliverHandler, which signs the activity with the actor's private key and POSTs it.
public struct DeliveryJob: Codable, Sendable {
    /// The remote inbox URL to deliver to (e.g. `https://mastodon.social/inbox`).
    public let targetInbox: String
    /// The full ActivityPub activity JSON to deliver.
    public let activityJSON: String
    /// Username of the local actor sending this activity (used to look up the signing key).
    public let actorUsername: String

    public init(
        targetInbox: String,
        activityJSON: String,
        actorUsername: String
    ) {
        self.targetInbox = targetInbox
        self.activityJSON = activityJSON
        self.actorUsername = actorUsername
    }
}
