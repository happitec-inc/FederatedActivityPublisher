# Quote Support

Consent-based quoting using FEP-044f, compatible with Mastodon 4.5+ and the broader fediverse.

## Overview

FederatedActivityPublisher implements consent-based quoting as defined in [FEP-044f](https://codeberg.org/fediverse/fep/src/branch/main/fep/044f/fep-044f.md). This protocol requires the author of a quoted post to explicitly approve the quote before it becomes visible, preventing unwanted context collapse and harassment vectors that unrestricted quoting can enable.

Mastodon 4.5 introduced this protocol as its quoting mechanism. FederatedActivityPublisher supports it end-to-end: actors advertise a quote approval policy, outbound Notes carry interaction policies, inbound QuoteRequests are evaluated and answered, and accepted quotes are federated with the correct approval URI.

## The Four Layers

Quote support spans four distinct layers in the ActivityPub exchange. Each layer serves a specific role in the consent negotiation.

### Layer 1: Instance API (`api_versions`)

The `/api/v2/instance` endpoint advertises `"api_versions": {"mastodon": 7}`, signaling to clients that the server supports the quoting API. Clients use this to decide whether to show a "quote" button in their UI. The value 7 corresponds to the Mastodon API level that introduced `quoted_status_id` on `POST /api/v1/statuses`.

### Layer 2: Actor (`quoteApprovalPolicy`)

Each actor's JSON-LD document includes a `quoteApprovalPolicy` field that tells remote servers what approval behavior to expect. FederatedActivityPublisher currently sets this to `https://www.w3.org/ns/activitystreams#Public` for all actors, meaning anyone may quote their posts without restriction.

The three possible values are:

- **`as:Public`** -- Anyone can quote. QuoteRequests are automatically accepted.
- **`as:Followers`** -- Only followers of the actor may quote. Others are rejected.
- **`as:Nobody`** (empty) -- All QuoteRequests are rejected.

This field is serialized by ``buildActorJSONLD(actor:serverDomain:handleDomain:)`` and included in the `@context` via the `toot:quoteUri` extension namespace.

### Layer 3: Note (`interactionPolicy.canQuote`)

Each Note object includes an `interactionPolicy` block that declares quoting permissions at the individual post level. FederatedActivityPublisher emits:

```json
{
  "interactionPolicy": {
    "canQuote": {
      "automaticApproval": ["https://www.w3.org/ns/activitystreams#Public"]
    }
  }
}
```

This tells consuming servers that quotes of this Note will be automatically approved. The `canQuote.automaticApproval` array mirrors the actor-level policy but is attached to each Note, allowing per-post granularity in the future. This block is built by ``buildNoteJSON(status:serverDomain:username:)``.

### Layer 4: Accept with `result` (Approval URI)

When a QuoteRequest is accepted, the Accept activity includes a `result` field containing an approval URI:

```json
{
  "type": "Accept",
  "actor": "https://example.com/users/appbot",
  "object": { "type": "QuoteRequest", ... },
  "result": "https://example.com/users/appbot/quote_authorizations/01JQXYZ..."
}
```

The approval URI is critical. Mastodon 4.5+ requires it to verify that a quote was genuinely approved. Without this field, the remote server will not display the quote to users even if the Accept was delivered successfully. The URI follows the pattern `/users/{username}/quote_authorizations/{ulid}` and is generated per-approval.

## Inbound QuoteRequest Flow

When a remote actor wants to quote one of our posts, their server sends a QuoteRequest activity to our actor's inbox. The InboxHandler processes it through several steps:

1. **Parse the activity.** Extract the `object` field (URI of our status being quoted) and the `instrument` field (URI of the remote actor's quoting status).

2. **Locate the quoted status.** Parse the status URI to extract the username and status ID, then fetch the status from DynamoDB. If the status does not exist, the request is silently accepted (no error leakage).

3. **Check follower status.** Query whether the requesting actor is a follower of the quoted actor, which matters for the `followers` policy tier.

4. **Evaluate the policy.** The ``shouldAcceptQuoteRequest(quotedStatusVisibility:quoteApprovalPolicy:isFollower:)`` function applies two checks:
   - Only `public` and `unlisted` statuses are quotable. Followers-only and direct posts are never quotable regardless of policy.
   - The actor's `quoteApprovalPolicy` is matched against the follower relationship: `public` always accepts, `followers` accepts only followers, `nobody` always rejects.

5. **Build and deliver the response.** An Accept or Reject activity is constructed, wrapping the original QuoteRequest as its `object`. If accepted, the `result` field carries the approval URI. The response is signed and delivered to the requesting actor's inbox via SQS.

## Outbound Quoting Flow

When a local actor creates a post that quotes a remote status (via `quoted_status_id` in the API), PostHandler initiates the consent handshake:

1. **Resolve the quoted status.** If the quoted status ID refers to a local post, the quote is auto-approved with no QuoteRequest needed. For remote statuses, the status is marked as `pending` and the remote actor's inbox is resolved by fetching the status object and its `attributedTo` actor.

2. **Send the QuoteRequest.** A QuoteRequest activity is enqueued for delivery to the remote actor's inbox, with `object` set to the quoted status URI and `instrument` set to our quoting status URI.

3. **Wait for approval.** The quoting status is stored in DynamoDB with `quoteApprovalState: "pending"`. While pending, the Note is federated without `quoteUri` -- followers see the post but not the quote embed.

4. **Receive Accept.** When the remote server sends back an `Accept` wrapping the QuoteRequest, InboxHandler verifies the origin (the Accept must come from the same domain as the quoted status) and flips the state to `accepted`.

5. **Re-federate with quoteUri.** An Update activity is sent to all followers containing the Note with `quoteUri` and `_misskey_quote` now populated. This allows clients to render the quote embed.

If the remote server sends a Reject instead, the state is set to `rejected` and the Note remains without a quote link. If the remote actor's inbox cannot be resolved at post time, the state is set to `failed`.

## quoteUri and _misskey_quote on Notes

Approved quotes are represented on the Note object using two fields for broad compatibility:

- **`quoteUri`** -- The Mastodon/Toot namespace extension (`toot:quoteUri`), declared in the actor's `@context` block. This is the canonical field that Mastodon 4.5+ reads.
- **`_misskey_quote`** -- The legacy Misskey field, included for compatibility with Misskey, Calckey, Firefish, Sharkey, and other Misskey-family servers.

Both fields contain the same value: the URI of the quoted status. They are only emitted when the quote is in an accepted state. ``buildNoteJSON(status:serverDomain:username:)`` checks `quoteApprovalState` and suppresses both fields if the quote is still pending, rejected, or failed. Local-to-local quotes (where `quoteApprovalState` is nil) are always emitted since they do not require external consent.

## Policy Evaluation

The ``shouldAcceptQuoteRequest(quotedStatusVisibility:quoteApprovalPolicy:isFollower:)`` function centralizes the accept/reject decision:

| Visibility | Policy | Follower? | Result |
|---|---|---|---|
| public | public | -- | Accept |
| public | followers | yes | Accept |
| public | followers | no | Reject |
| public | nobody | -- | Reject |
| unlisted | public | -- | Accept |
| unlisted | followers | yes | Accept |
| private | any | -- | Reject |
| direct | any | -- | Reject |

The function defaults to rejection for unknown policy values, following a restrictive-by-default principle. Visibility is checked first: only distributable posts (public and unlisted) can be quoted, regardless of the actor's stated policy.
