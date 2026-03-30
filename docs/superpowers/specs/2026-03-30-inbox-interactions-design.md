# Workstream A: Inbox Interactions — Design Spec

## Goal

Handle all common inbound ActivityPub interactions: likes, boosts, replies, deletes, updates, and undo variants. Store interactions correctly, maintain accurate counts on statuses, and sanitize untrusted inbound HTML.

## Scope

**In scope:**
- Like, Announce (boost), Create (Note reply)
- Delete (interaction removal + actor deletion from followers)
- Update (Note edits + remote actor profile refresh)
- Undo Like, Undo Announce
- Block, Move, Add, Remove, Flag — log-only stubs
- HTML sanitization for inbound Note content (at inbox time)
- Unit tests for HTML sanitizer
- Curl-based smoke test script for inbox handlers

**Out of scope (deferred, issues filed):**
- QuoteRequest flow (FEP-044f) — #57
- Collection-Synchronization header — #58
- Full Swift integration test suite (ICU fix is separate tech debt)

## Architecture

All changes are in three layers. No new Lambda functions or SAM template changes.

### Layer 1: ActivityPubCore

**New file: `HTMLSanitizer.swift`**

Pure function. Input: untrusted HTML string. Output: sanitized HTML string.

Allowlisted tags: `p`, `br`, `a`, `span`, `em`, `strong`, `b`, `i`, `u`, `del`, `pre`, `code`, `ul`, `ol`, `li`, `blockquote`.

Rules:
- Only `href` attribute preserved, and only on `<a>` tags
- All other attributes stripped from all tags
- Self-closing tags handled (`<br>`, `<br/>`, `<br />`)
- Disallowed tags removed entirely (tag and its attributes, not its text content)
- Malformed/unclosed tags stripped
- No external dependencies — string/regex-based parsing
- `class` attribute on `<span>` preserved (Mastodon uses `class="h-card"` and `class="invisible"` for mentions and link display)

**New DynamoDB store methods:**

| Method | Purpose |
|--------|---------|
| `storeInteraction(username:actorUri:type:objectUri:)` | Store a Like or Announce. Returns Bool (new or duplicate). |
| `removeInteraction(username:actorUri:type:objectUri:)` | Remove a Like or Announce on Undo/Delete. Returns Bool (was present). |
| `storeReply(username:actorUri:objectUri:content:inReplyTo:raw:)` | Store an inbound reply Note. Sanitizes content before storing. |
| `removeReply(username:objectUri:)` | Remove a stored reply on Delete. Returns Bool. |
| `updateReply(username:objectUri:content:)` | Update a stored reply's content on Update. Sanitizes before storing. |
| `updateRemoteActor(actorUri:data:)` | Refresh cached remote actor profile. Reset TTL to 24h. |
| `incrementLikesCount(username:statusId:)` | Atomic `UpdateItem` ADD on likesCount. |
| `decrementLikesCount(username:statusId:)` | Atomic `UpdateItem` ADD -1 on likesCount (floor at 0). |
| `incrementBoostsCount(username:statusId:)` | Atomic `UpdateItem` ADD on boostsCount. |
| `decrementBoostsCount(username:statusId:)` | Atomic `UpdateItem` ADD -1 on boostsCount (floor at 0). |
| `incrementRepliesCount(username:statusId:)` | Atomic `UpdateItem` ADD on repliesCount. |
| `decrementRepliesCount(username:statusId:)` | Atomic `UpdateItem` ADD -1 on repliesCount (floor at 0). |

Count methods follow the existing `incrementFollowerCount`/`decrementFollowerCount` pattern.

### Layer 2: InboxHandler

New case branches in the existing `switch activityType` block. Each follows the same pattern:

```
case "Like":
    extract objectUri from json["object"]
    parse username + statusId from objectUri
    store interaction
    if new: increment count
    return 202
```

#### Activity Handlers

**Like:**
- Extract `object` (URI string or inline object with `id`)
- Parse `username` and `statusId` from the object URI (`https://happitec.com/users/{username}/statuses/{id}`)
- Verify the status exists and belongs to the target username
- Call `storeInteraction(type: "Like")`
- If new: `incrementLikesCount`

**Announce (boost):**
- Same pattern as Like but `incrementBoostsCount`

**Create (Note reply):**
- Extract the Note object from `json["object"]`
- Verify it has `inReplyTo` pointing to one of our statuses
- Parse parent username + statusId from `inReplyTo` URI
- Sanitize `content` via `HTMLSanitizer`
- Call `storeReply`
- If new: `incrementRepliesCount` on parent status

**Delete:**
- Extract `object` (URI string or inline object)
- Determine what's being deleted by checking the object URI or `object.type`:
  - If `object.type == "Tombstone"` or object URI matches our status URI pattern (`/users/{u}/statuses/{id}`) — remote actor is deleting an interaction or reply they sent about our status. Query stored activities by `actorUri` + `objectUri` to find what to remove, then decrement the relevant count.
  - If object URI matches an actor URI pattern (no `/statuses/` segment) and `actorUri == objectUri` — account self-deletion. Call existing `removeFollower` + `decrementFollowerCount` + invalidate followers cache.
  - If neither matches — log and 202 (forward compat).

**Update:**
- Extract `object` (always inline object for Update)
- If `object.type` is `Note`:
  - Parse our username + statusId from `object.inReplyTo`
  - Sanitize updated `content`
  - Call `updateReply`
- If `object.type` is `Person`, `Service`, `Application`, or `Organization`:
  - Extract actor data (publicKeyPem, preferredUsername, inbox, sharedInbox, etc.)
  - Call `updateRemoteActor` to refresh cache

**Undo (extended):**
- Existing handler already covers Undo-Follow
- Add: if `objectType == "Like"` → `removeInteraction(type: "Like")` + `decrementLikesCount`
- Add: if `objectType == "Announce"` → `removeInteraction(type: "Announce")` + `decrementBoostsCount`

**Block, Move, Add, Remove, Flag:**
- Log the activity type, actor URI, and object URI at info level
- Return 202
- Already stored via the activity idempotency check at the top of the handler

### Layer 3: No infrastructure changes

No new Lambdas, no SAM template changes, no new API Gateway routes.

## DynamoDB Schema

No new entity types needed. All interactions are already stored as received activities via the idempotency check (`PK: ACTOR#{username}, SK: ACTIVITY#{type}#{ulid}`).

For Like/Announce lookup on Undo, we query by `objectUri` attribute. The existing `objectUri` field stored during idempotency check enables this. We need a query with a filter expression on `objectUri` + `actorUri` to find the specific interaction to remove.

For replies, stored as `ACTIVITY#Create#{ulid}` with `objectUri` = the reply Note's `id`. Content stored in the `raw` field (already happening via idempotency). The `storeReply` method also writes sanitized content to a dedicated `content` attribute for direct reads.

Count updates use atomic `UpdateItem` with `SET likesCount = if_not_exists(likesCount, :zero) + :inc` pattern, same as follower counts.

## HTML Sanitizer Detail

Parsing approach: regex-based tag matching. Walk the input string, match `<tagname ...>` patterns:
- If tag is in allowlist: emit the tag with only allowed attributes
- If tag is not in allowlist: skip the tag, keep text content between open/close tags
- Handle self-closing variants
- Handle HTML entities (pass through as-is)

Edge cases:
- `<script>alert('xss')</script>` → `alert('xss')` (tag stripped, text kept)
- `<a href="https://example.com" onclick="evil()">link</a>` → `<a href="https://example.com">link</a>`
- `<a href="javascript:alert(1)">link</a>` → `<a>link</a>` (javascript: URIs stripped from href)
- `<div><p>text</p></div>` → `<p>text</p>` (div stripped, p kept)
- `<span class="h-card">@user</span>` → `<span class="h-card">@user</span>` (class preserved on span)
- Empty/whitespace-only input → empty string

## Testing Strategy

### Unit Tests: HTMLSanitizerTests

Test cases:
1. Allowed tags pass through unchanged
2. Disallowed tags stripped, content preserved
3. Attributes stripped except `href` on `<a>` and `class` on `<span>`
4. `javascript:` URIs stripped from href
5. Self-closing tags handled
6. Nested allowed/disallowed tags
7. Malformed HTML (unclosed tags, extra closing tags)
8. HTML entities preserved
9. Empty/nil input
10. Real-world Mastodon Note HTML (mentions, links, hashtags)

### Smoke Tests: scripts/test-inbox.sh

Shell script that:
1. Reads `test1`'s private key from SSM
2. Constructs ActivityPub payloads (Like, Announce, Create, Delete, Update, Undo)
3. Signs each with HTTP Signatures (Cavage format)
4. POSTs to `test2`'s inbox on stage
5. Verifies via outbox/status endpoints that counts updated correctly

Requires: `openssl` for RSA signing, `curl`, `jq`, deployed stage stack.

## Parallelization

All activity handlers are independent case branches. Implementation order:

1. **HTML Sanitizer** (ActivityPubCore) — no dependencies, has unit tests
2. **DynamoDB store methods** — no dependencies, follows existing patterns
3. **Like + Announce + Undo variants** — simplest handlers, prove the pattern
4. **Create (reply)** — depends on HTML sanitizer
5. **Delete** — depends on store methods (remove operations)
6. **Update** — depends on store methods (update operations)
7. **Stub handlers** (Block/Move/Add/Remove/Flag) — trivial, do last
8. **Smoke test script** — after all handlers are in place

Steps 1-2 can be done in parallel. Steps 3-7 can be done in parallel after 1-2.
