/// Quote-post approval policy for inbound `QuoteRequest` activities.
///
/// When a remote server sends a `QuoteRequest` to `/users/{username}/inbox`,
/// `InboxHandler` calls ``shouldAcceptQuoteRequest(quotedStatusVisibility:quoteApprovalPolicy:isFollower:)``
/// to decide whether to emit an `Accept` or `Reject` response activity.
///
/// Two independent checks must pass: the quoted status must be publicly distributable
/// (visibility `public` or `unlisted`), and the quoted actor's policy must permit quotes
/// from the requesting actor. This file holds only the policy logic; the follower lookup
/// and activity dispatch live in `InboxHandler`.
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
