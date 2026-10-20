/// Exactly-once processing of inbound activities, and the activity-JSON helpers it shares with
/// `InboxHandler`.
///
/// Remote servers retry a delivery until the inbox answers with a 2xx status, and may deliver
/// the same activity more than once. `InboxHandler` therefore claims each activity id in
/// DynamoDB before handling it (``DynamoDBStore/claimReceivedActivity(activityId:type:actorUri:)``),
/// and marks it processed only after the handler has succeeded. A failed handler releases its
/// claim, so the sender's retry runs the activity again instead of being told it was already
/// processed. ``processActivityOnce(claim:complete:release:succeeded:handle:)`` holds that
/// ordering; the storage calls are passed in so the ordering can be tested without DynamoDB.
import Foundation

/// The result of trying to claim an inbound activity for processing.
public enum ActivityClaim: Sendable, Equatable {
    /// No earlier delivery holds or has finished the activity: this delivery handles it.
    case claimed
    /// An earlier delivery of the activity was processed successfully.
    case alreadyProcessed
    /// Another delivery of the activity is being processed right now.
    case inProgress
}

/// What happened to one delivery of an inbound activity.
public enum ActivityDelivery<Response> {
    /// This delivery ran the handler, which returned `Response`.
    case handled(Response)
    /// The activity had already been processed; the handler did not run.
    case alreadyProcessed
    /// Another delivery of the activity is still being processed; the handler did not run.
    case inProgress
}

/// Run `handle` for an inbound activity unless a delivery of it has already been processed.
///
/// The activity is marked processed (`complete`) only after `handle` returns a response for
/// which `succeeded` is `true`. If `handle` throws or returns a failure response, the claim is
/// released (`release`) so that a redelivery processes the activity again.
///
/// - Parameters:
///   - claim: Claims the activity id; see ``ActivityClaim``.
///   - complete: Marks the activity processed.
///   - release: Drops this delivery's claim.
///   - succeeded: Whether a handler response means the activity took effect.
///   - handle: Processes the activity.
/// - Returns: The handler's response, or why the handler did not run.
/// - Throws: Any error from `claim`, `handle`, `complete`, or (after a failure response)
///   `release`. An error from `release` after `handle` throws is dropped in favour of the
///   handler's error.
public func processActivityOnce<Response>(
    claim: () async throws -> ActivityClaim,
    complete: () async throws -> Void,
    release: () async throws -> Void,
    succeeded: (Response) -> Bool,
    handle: () async throws -> Response
) async throws -> ActivityDelivery<Response> {
    switch try await claim() {
    case .alreadyProcessed:
        return .alreadyProcessed
    case .inProgress:
        return .inProgress
    case .claimed:
        break
    }

    let response: Response
    do {
        response = try await handle()
    } catch {
        try? await release()
        throw error
    }

    if succeeded(response) {
        try await complete()
    } else {
        try await release()
    }
    return .handled(response)
}

/// Extracts the object URI from an ActivityPub JSON object.
///
/// The `object` field may be a bare URI string or an inline object containing an `id`.
/// Returns `nil` if neither form is present. For an Undo, this is the id of the activity
/// being undone.
///
/// - Parameter json: An activity or nested object dictionary.
/// - Returns: The URI string, or `nil`.
public func extractObjectUri(from json: [String: Any]) -> String? {
    if let objectStr = json["object"] as? String {
        return objectStr
    }
    if let objectDict = json["object"] as? [String: Any] {
        return objectDict["id"] as? String
    }
    return nil
}
