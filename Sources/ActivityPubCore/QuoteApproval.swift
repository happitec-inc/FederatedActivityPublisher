import Foundation

/// Determine whether an inbound QuoteRequest should be accepted or rejected.
///
/// Checks status visibility (only public/unlisted are quotable) and the actor's
/// `quoteApprovalPolicy` setting against the requesting actor's follower status.
///
/// - Parameters:
///   - quotedStatusVisibility: The visibility of the status being quoted (`public`, `unlisted`, `private`, `direct`).
///   - quoteApprovalPolicy: The quoted actor's policy: `public`, `followers`, or `nobody`.
///   - isFollower: Whether the requesting actor is a follower of the quoted actor.
/// - Returns: `true` if the quote should be accepted, `false` if rejected.
public func shouldAcceptQuoteRequest(
    quotedStatusVisibility: String,
    quoteApprovalPolicy: String,
    isFollower: Bool
) -> Bool {
    // Only public and unlisted statuses can be quoted (distributable check)
    guard quotedStatusVisibility == "public" || quotedStatusVisibility == "unlisted" else {
        return false
    }

    switch quoteApprovalPolicy {
    case "public":
        return true
    case "followers":
        return isFollower
    case "nobody":
        return false
    default:
        // Unknown policy -- default to restrictive (reject)
        return false
    }
}
