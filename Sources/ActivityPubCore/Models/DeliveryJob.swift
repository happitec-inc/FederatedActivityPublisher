import Foundation

/// An SQS delivery job payload for sending signed HTTP requests to remote inboxes.
public struct DeliveryJob: Codable, Sendable {
    public let targetInbox: String
    public let activityJSON: String
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
