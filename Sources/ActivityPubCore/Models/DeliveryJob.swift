/// The JSON payload enqueued to SQS for asynchronous ActivityPub delivery.
///
/// After a local actor posts a status or sends a follow/accept/undo, the originating Lambda
/// (typically `PostHandler` or `InboxHandler`) enqueues one `DeliveryJob` per target inbox.
/// The `DeliverHandler` Lambda consumes these messages, fetches the actor's RSA private key
/// from SSM Parameter Store, signs the HTTP request with an HTTP Signature, and POSTs the
/// activity to the remote inbox. Using SQS decouples fan-out delivery from the request path
/// and provides automatic retries on transient failures.
import Foundation

/// An SQS message payload for delivering a signed ActivityPub activity to a single remote inbox.
public struct DeliveryJob: Codable, Sendable {
    /// The remote inbox URL to deliver to (e.g. `https://mastodon.social/inbox`).
    public let targetInbox: String
    /// The full ActivityPub activity JSON to deliver.
    public let activityJSON: String
    /// Username of the local actor sending this activity (used to look up the signing key).
    public let actorUsername: String

    /// Create a DeliveryJob.
    ///
    /// - Parameters:
    ///   - targetInbox: The remote inbox URL to POST to (e.g. `https://mastodon.social/inbox`).
    ///   - activityJSON: The full ActivityPub activity JSON string to deliver as the request body.
    ///   - actorUsername: Local username whose private key will be used to sign the request.
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
