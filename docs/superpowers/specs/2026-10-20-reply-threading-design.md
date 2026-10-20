# Reply Threading — Design Spec

## Goal

Let a local actor publish a reply to one of its own statuses, so that a chain of posts federates
as a thread. Remote servers must show each post in the chain as a reply to the previous one, and
the Mastodon-compatible client API must report the reply relationship.

The motivating case is a bot that posts a long daily summary. When the summary exceeds the
5,000-character status limit, the bot splits it into a root post and a chain of self-replies.

Today FAP accepts `in_reply_to_id` on create but never federates it, so a "thread" arrives at
remote servers as N unrelated posts.

## Scope

**In scope (a self-thread):**
- Resolve `in_reply_to_id` on `POST /api/v1/statuses` to a status owned by the posting actor.
  Reject anything else with 404.
- Store `Status.inReplyTo` as the parent's canonical URI.
- Cap a reply's visibility at its parent's visibility.
- Emit `inReplyTo` on every outbound Note built by `buildNoteJSON`.
- Increment the parent's `repliesCount` for public and unlisted replies.
- Return the correct `in_reply_to_id` in the create response, and add an optional
  `in_reply_to_account_id`.
- Show an "In reply to" link on the web post page.

**Out of scope (each needs its own spec):**
- Replies to another local actor's status. Statuses are keyed per actor (`PK=ACTOR#{username}`),
  so a bare id can't be resolved to an owner without a new lookup path. See Open Question 1.
- Replies to remote statuses. This needs a remote-status cache, Mention tags, and addressing to the
  remote author.
- A `replies` collection on the parent Note (Open Question 3).
- `context` / `conversation` properties (Open Question 4).
- `GET /api/v1/statuses/:id` and `GET /api/v1/statuses/:id/context`. FAP serves no Mastodon-API
  status reads at all today. See "Current behaviour".
- A thread view on the web: the parent page listing its descendants.
- Rewriting `inReplyTo` values stored before this change (Design §3).
- `direct` visibility. It is still rejected (`Sources/PostHandler/main.swift:194`).

## Standards

All sources were fetched 2026-10-20. Mastodon source references are to `mastodon/mastodon` branch
`main` on that date, so line numbers may drift.

### ActivityStreams 2.0 Vocabulary

Source: https://www.w3.org/TR/activitystreams-vocabulary/

| Term | Anchor | Range | Definition (verbatim) |
|---|---|---|---|
| `inReplyTo` | `#dfn-inreplyto` | Object \| Link | "Indicates one or more entities for which this object is considered a response." |
| `replies` | `#dfn-replies` | Collection (functional) | "Identifies a Collection containing objects considered to be responses to this object." |
| `context` | `#dfn-context` | Object \| Link | "Identifies the context within which the object exists or an activity was performed." |
| `tag` | `#dfn-tag` | Object \| Link | "One or more "tags" that have been associated with an objects." |
| `Mention` | `#dfn-mention` | extends Link | "A specialized Link that represents an @mention." |

The `context` entry goes on: "The notion of "context" used is intentionally vague. The intended
function is to serve as a means of grouping objects and activities that share a common
originating context or purpose."

`conversation` is not an AS2 term. It is an OStatus-era extension that Mastodon declares as a
context extension (`app/serializers/activitypub/note_serializer.rb:7`).

ActivityStreams Core (https://www.w3.org/TR/activitystreams-core/ §4.1) only lists `context` and
`inReplyTo` as Object properties. It assigns no conversation semantics to them.

### ActivityPub (W3C Recommendation)

Source: https://www.w3.org/TR/activitypub/

- **ActivityPub defines no `replies` side effect.** §3 (Objects) and §5 (Collections: Outbox,
  Inbox, Followers, Following, Liked, Public Addressing, Likes, Shares) never define a replies
  collection. No section requires a server to add a reply to its parent's `replies`. FEP-7458
  says the same: "Replies are not defined in ActivityPub, as there are no specified side effects
  for simply *encountering* objects or activities with `inReplyTo` set."
- **§6.2 Create Activity (C2S):** "the actor of the activity SHOULD be copied onto the object's
  attributedTo field" and "a server SHOULD copy any recipients of the Create activity to its
  object". FAP already gives the Create and the Note identical `to`/`cc`
  (`Sources/ActivityPubCore/Models/Note.swift:28-29,123-124`).
- **§7.2 Create Activity (S2S):** "Receiving a Create activity in an inbox has surprisingly few
  side effects".
- **§7.1.2 Forwarding from Inbox:** a server MUST forward an inbound activity only when it hasn't
  seen it before, its `to`/`cc`/`audience` contain a collection the server owns, *and* its
  "`inReplyTo`, `object`, `target` and/or `tag` are objects owned by the server". `context` is not
  a forwarding condition. This governs *inbound* replies from third parties. It does not apply to
  a self-thread, which FAP delivers directly to its own followers.
- **Addressing.** §5.6 defines `https://www.w3.org/ns/activitystreams#Public` and says it MUST
  NOT be delivered to as an inbox. §6.1 names the Followers and Public collections as "good
  choices for the default addressing of new Activities".

### FEPs

Index: https://codeberg.org/fediverse/fep (README and per-FEP front matter). Every FEP below is
DRAFT. None is FINAL.

| FEP | Title | Status | Received | What it asks |
|---|---|---|---|---|
| 7888 | Demystifying the context property | DRAFT | 2023-03-14 | "A `context` SHOULD be resolvable" (l.48); "the resolved `context` SHOULD in some way have an associated Collection" (l.55); consumers SHOULD group by `context`. |
| f228 | Backfilling conversations | DRAFT | 2025-02-17 | Names recursive `inReplyTo` + `replies` traversal as "the most common conversation backfill method"; if `context` is present it "MUST resolve to a collection of posts". |
| 171b | Conversation Containers | DRAFT | 2024-11-23 | A conversation is a collection owned by one actor, populated with `Add` activities. |
| 76ea | Conversation Threads | DRAFT | 2024-10-04 | A `thread` OrderedCollection that a reply inherits from its parent; the root's server maintains it. |
| 7458 | Using the replies collection | DRAFT | 2024-04-26 | Guidance for explicitly maintaining `replies`. |

No FEP covers self-threads specifically. FEP-76ea is the closest.

### Mastodon

**ActivityPub docs** (https://docs.joinmastodon.org/spec/activitypub/):
- `inReplyTo`: "Used for threading a status as a reply to another status".
- `replies`: "Up to 5 replies from the same server will be fetched upon discovery of a remote
  status ... the first page contains self-replies, and additional pages contain replies from other
  people."
- Mentions: "Mastodon requires Mention tags in order to generate a notification. (The mentioned
  actor must still be included within to or cc explicitly in order to receive the post.)"

**What Mastodon emits** (`app/serializers/activitypub/note_serializer.rb`):
- `inReplyTo` is the parent's URI, and only when the status is a reply with a resolved thread
  (lines 99-107).
- `replies` is emitted only for local statuses (line 22). Its embedded first page holds up to 5
  self-replies (`object.self_replies(5)`, lines 61-74). The replies controller serves
  self-replies first and other accounts on later pages
  (`app/controllers/activitypub/replies_controller.rb:33-34,76`).
- It emits both `conversation` (lines 157-166) and `context` (lines 168-173). Both derive from the
  status's conversation record.
- `to`/`cc` for a public status: `to: [as:Public]`, `cc: [author followers]` plus mentioned
  accounts (`app/lib/activitypub/tag_manager.rb`, `to` at 171-196 and `cc` from 203). Mentions
  come only from scanning the status text (`app/services/process_mentions_service.rb:25-26`). The
  parent's author is never added automatically.

**What Mastodon does on create** (`app/services/post_status_service.rb`, `app/models/status.rb`):
- **Visibility is never changed because of the thread.** It is overridden in two cases only
  (`post_status_service.rb:85-87`):
  - a silenced account's public post becomes unlisted (`:86`)
  - a public or unlisted post that quotes a private status becomes private (`:87`)

  So Mastodon allows a public reply to a followers-only post. Line 87 shows the precedent this
  spec follows: Mastodon downgrades a post's visibility rather than rejecting it.
- **`replies_count` counts only distributable replies:**
  `thread&.increment_count!(:replies_count) if in_reply_to_id.present? && distributable?`
  (`status.rb:484`). `distributable?` is `public_visibility? || unlisted_visibility?`
  (`app/models/concerns/status/visibility.rb:31-33`).
- **`in_reply_to_account_id` is not always the parent's author.** `carried_over_reply_to_account_id`
  (`status.rb:461-466`) works like this when the parent is by the same account:
  - if the parent is itself a reply, the parent's own `in_reply_to_account_id` is carried over
  - otherwise the parent's author is used

  For a self-thread rooted at the actor's own non-reply post, every value is the actor. Open
  Question 1 changes this.
- **Conversation.** When no `conversation` is supplied, a reply joins its parent's conversation
  (`status.rb:449`, `self.conversation_id = thread.conversation_id if conversation_id.nil?`).

**What Mastodon consumes** (`app/lib/activitypub/activity/create.rb`):
- `inReplyTo` (falling back to `inReplyToAtomUri`), lines 440-447.
- When the parent is unknown, `resolve_thread` (lines 382-386) enqueues `ThreadResolveWorker`.
  That worker looks the parent up locally and otherwise calls `FetchRemoteStatusService` on the
  `inReplyTo` URI, then attaches the child (`app/workers/thread_resolve_worker.rb:9-21`).
- `fetch_replies` (line 81) backfills from the `replies` collection.
- On intake it reads `conversation` (line 118, `conversation_from_uri`, lines 422-431). No read of
  `context` was found.

**Home-feed filtering** (`app/lib/feed_manager.rb`):
- A reply whose parent is not resolved (`in_reply_to_id` nil) is filtered from home feeds (`:505`).
- Self-replies are kept in home feeds (`:524`, "and it's not a self-reply").
- A child that arrived before its parent reaches home feeds only through `ThreadResolveWorker`'s
  re-distribution (`thread_resolve_worker.rb:21`). That is gated on `within_realtime_window?`:
  `REAL_TIME_WINDOW = 6.hours` (`status.rb:188,218-220`).

**Client API:**
- `POST /api/v1/statuses` takes `in_reply_to_id`: "ID of the status being replied to"
  (https://docs.joinmastodon.org/methods/statuses/).
- When that id is missing or not viewable, Mastodon returns **404** with
  `statuses.errors.in_reply_not_found` (`app/controllers/api/v1/statuses_controller.rb`,
  `set_thread`, lines 106-111).
- The Status entity (https://docs.joinmastodon.org/entities/Status/) has `in_reply_to_id` and
  `in_reply_to_account_id`. Both are nullable strings. The docs say `in_reply_to_account_id`
  "Might be the ID of the account that authored the status being replied to. This sometimes skips
  over self-replies", which matches `carried_over_reply_to_account_id` above.
- `GET /api/v1/statuses/:id/context` returns a Context entity with `ancestors` and `descendants`
  (https://docs.joinmastodon.org/entities/Context/).

### What this means for a self-thread

`inReplyTo` set to the parent's dereferenceable URI is what threads a post on Mastodon. It is
both the only threading property Mastodon requires on intake and the property FEP-f228 names as
the primary backfill path. The parent's stored `uri` (`Sources/PostHandler/main.swift:293`) is
byte-identical to its Note `id` (`Sources/ActivityPubCore/Models/Note.swift:25`), so Mastodon
resolves it.

A self-reply needs no Mention tag. Mastodon generates none for a self-reply whose text contains no
`@`, and a self-reply has nobody to notify. Addressing stays the same as for any post of that
visibility.

`replies`, `context` and `conversation` improve backfill for servers that discover a thread
without following the author. Without `replies`, a server that finds only the root can't
discover the descendants. A follower doesn't need any of the three, because it receives every
post in the chain by delivery.

## Current FAP behaviour

Verified by reading the code at `8a78008`.

**Create path.**
- `CreateStatusRequest.inReplyToId` decodes `in_reply_to_id`
  (`Sources/ActivityPubCore/Models/CreateStatusRequest.swift:27,38`).
- `PostHandler` copies it verbatim into `Status.inReplyTo` (`Sources/PostHandler/main.swift:310`)
  without looking anything up or validating it.
- An unknown or garbage `in_reply_to_id` returns 200.
- The parent's `repliesCount` is not touched.

**Model.**
- `Status.inReplyTo` is documented as "URI of the status this is replying to"
  (`Sources/ActivityPubCore/Models/Status.swift:47-48`, and the init doc at `:79`). It actually
  holds whatever string the client sent, which for Mastodon clients is an id.
- `repliesCount` is documented as "replies received from remote actors" (`Status.swift:53-54`).

**Storage.**
- Statuses live at `PK=ACTOR#{username}`, `SK=STATUS#{ulid}`. They use `GSI1PK=ACTOR#{username}`
  and `GSI1SK=PUBLISHED#…` (`Status.swift:216-221`).
- `inReplyTo` is written only when non-nil (`Status.swift:243-245`).
- No index on a status's `inReplyTo` exists.
- `getStatus` supports `consistentRead` (`Sources/ActivityPubCore/DynamoDBStore.swift:728`).

**Outbound Note.**
- `buildNoteJSON` (`Sources/ActivityPubCore/Models/Note.swift:23-109`) is the only Note builder.
  It emits no `inReplyTo`, `replies`, `context` or `conversation`.
- It has four callers:
  - delivery fan-out (`Sources/PostHandler/main.swift:325`)
  - the object endpoint (`Sources/ObjectHandler/main.swift:74`)
  - the outbox (`Sources/OutboxHandler/main.swift:80`)
  - the `Update` re-federation sent when a quote is accepted (`Sources/InboxHandler/main.swift:1285`)
- `buildCreateActivityJSON` (`Note.swift:119-130`) wraps it.
- `DeliverHandler` signs and POSTs the prebuilt JSON unchanged.
- `Documentation.docc/FederationOverview.md:15` says `buildNoteJSON` emits "reply metadata". That
  is false at `8a78008`. This change makes it true.

**Addressing.** `computeAddressing` (`Note.swift:146-165`):

| visibility | `to` | `cc` |
|---|---|---|
| public | `[as:Public]` | `[followers]` |
| unlisted | `[followers]` | `[as:Public]` |
| private | `[followers]` | `[]` |

`PostHandler` sets `tags: nil` (`main.swift:308`), so no Mention tags are ever emitted.

**Delivery.** One `DeliveryJob` per distinct (shared) inbox of the author's followers, enqueued to
SQS (`main.swift:332-352`).

**Object endpoint.**
- `ObjectHandler` returns 404 for private and direct statuses only on the HTML branch
  (`ObjectHandler/main.swift:51-62`). The `application/activity+json` branch (`:74-84`) serves any
  visibility. FederatedActivityPublisher#270 tracks this.
- It returns `cache-control: public, max-age=31536000` (`:80`).
- CloudFront caps `/users/*/statuses/*` at 300 s (`LongCachePolicy`,
  `activity-app/cdn/template.yaml:103-109,404-409`).
- Downstream caches still see the one-year header, so the Note body must be immutable.

**Mastodon client API.**
- The only status endpoint is `POST /api/v1/statuses` (`activity-app/functions/template.yaml:145-146`;
  `operationId: createStatus`, `openapi.yaml:381-410`).
- The OpenAPI document lists 200, 401 and 422 responses, and no 404.
- There is no `GET /api/v1/statuses/:id` and no `/context`.
- The create response comes from `buildStatusResponse` (`Sources/PostHandler/main.swift:425-451`).
  It echoes the stored `inReplyTo` as `in_reply_to_id` (`:444,449`) and has no
  `in_reply_to_account_id`.
- `openapi.yaml:891` and `:958` document `in_reply_to_id`.
- The account id FAP exposes is the username (`Sources/VerifyCredentialsHandler/main.swift:131`).
- `openapi.yaml` is mirrored to the downstream client repository on every push to `main` that
  touches it (`.github/workflows/sync-openapi.yml:2-5`). That happens independently of any server
  release.

**Web view.**
- The post page (`Sources/ProfileHandler/main.swift:395` onward) shows likes, boosts, quotes and
  reply counts (`:534-537`) but no reply relationship.
- The post page is served with `max-age=31536000` (`:121-128`). CloudFront caps `/@*` at 300 s
  (`MediumCachePolicy`, `cdn/template.yaml:125-126,453`).
- The profile page lists the 20 newest public/unlisted statuses with no reply marking (`:80-81,300`).

**Inbound replies (already implemented).**
- `handleCreate` (`Sources/InboxHandler/main.swift:727-818`) accepts a remote `Create(Note)` only
  when `inReplyTo` parses as a local status URI (`parseStatusUri`, `:1114-1129`, matching both
  server and handle domains) and the parent exists.
- It stores the reply at `PK=ACTOR#{parent owner}`, `SK=REPLY#{objectUri}`,
  `GSI1PK=REPLIES#{inReplyTo}` (`DynamoDBStore.swift:382-417`), and increments the parent's
  `repliesCount` on first write (`:808-810`).
- Delete decrements the count (`InboxHandler/main.swift:1053-1088`).
- **Nothing queries `REPLIES#`.** The GSI key is written (`DynamoDBStore.swift:395`) and never
  read.

**Character limit.**
- `max_characters: 5000` is advertised by `InstanceHandler` (`Sources/InstanceHandler/main.swift:61,125`).
- It is enforced only in the compose page's JavaScript (`Sources/ComposeHandler/main.swift:387`).
  `PostHandler` doesn't check length.

## Design

### 1. Shared URI parsing moves to ActivityPubCore

Move `parseStatusUri` from `Sources/InboxHandler/main.swift:1114` into ActivityPubCore as
`parseLocalStatusUri(_:serverDomain:handleDomain:) -> (username: String, statusId: String)?`.
Behaviour is unchanged.

InboxHandler, PostHandler, `buildNoteJSON`, `buildStatusResponse` and the post page all call it.
This is one function in one place, with no new component.

### 2. Resolve and validate `in_reply_to_id` (PostHandler)

Insert a step between visibility validation and addressing, before anything is written:

1. If `in_reply_to_id` is absent or empty, the status is not a reply.
2. Otherwise call `store.getStatus(username: <authenticated user>, id: in_reply_to_id,
   consistentRead: true)`.
   - Use `consistentRead: true` because a bot posts the chain back-to-back. The parent was
     written milliseconds earlier, and a default eventually-consistent `GetItem` can miss it.
   - The codebase already reads this way after a write (`InboxHandler/main.swift:1284`).
3. If no status is found, return **404** `{"error":"Status to reply to not found"}` and write
   nothing. This matches Mastodon's 404 for an unknown or unviewable `in_reply_to_id`. The same 404
   covers all three non-self cases:
   - **missing parent**
   - **another local actor's status**: the lookup is scoped to the author's partition, so the
     item is invisible
   - **a remote URI**: not a local id, so the lookup misses
4. If found, set `inReplyTo = parent.uri`. That is the canonical URI
   `https://{serverDomain}/users/{u}/statuses/{id}`, as constructed at
   `Sources/PostHandler/main.swift:293`.
5. **Cap the visibility.** Rank the visibilities `public` > `unlisted` > `private`. If the
   requested visibility ranks above the parent's, downgrade the reply to the parent's visibility
   *before* calling `computeAddressing`.
   - This follows Mastodon's quote precedent (`post_status_service.rb:87`): downgrade, don't
     reject.
   - The create response's `visibility` field reports the effective value, so the client sees
     the change.
   - The cap stays while FederatedActivityPublisher#270 is open. A wider child would publish a
     narrower parent's URI to an audience that can then fetch the parent through the object
     endpoint's `activity+json` branch, which ignores visibility (`ObjectHandler/main.swift:74-84`).
     A server that sees the child without the parent fetches that URI automatically
     (`ThreadResolveWorker`).
   - For the motivating case, every chunk of a summary shares one visibility, so the cap changes
     nothing.

Put the resolution logic in an ActivityPubCore function that takes a lookup closure, so it can be
unit-tested without DynamoDB:

```swift
public enum ReplyParentResolution { case none, resolved(Status), notFound }
public func resolveReplyParent(
    inReplyToId: String?, lookup: (String) async throws -> Status?
) async throws -> ReplyParentResolution
public func cappedReplyVisibility(requested: String, parent: String) -> String
```

### 3. Storage: `inReplyTo` is a URI

New items store the parent URI. There is no schema change and no new attribute.

**Values stored before this change are ignored.** Every reader treats `inReplyTo` as a reply link
only when it begins with `https://` and `parseLocalStatusUri` accepts it. Any other value is
ignored as if absent: no normalization, no migration.

- Normalizing a legacy value would change an object-endpoint body that was already served under a
  one-year cache header. It would never reach servers that already ingested the Note, because no
  `Update` is sent.
- It would also turn unvalidated client input (`PostHandler/main.swift:310`) into a URI path.
- No legacy item has been observed. If one is observed later, that is a follow-up issue.

### 4. Emit `inReplyTo` on the Note

In `buildNoteJSON`, emit `"inReplyTo":"<uri>"` when `status.inReplyTo` passes the §3 check, and
omit the key otherwise. All four callers pick it up because they share the builder:
- delivery
- the object endpoint
- the outbox
- the quote-accept `Update` (`InboxHandler/main.swift:1285`)

`FederationOverview.md:15` ("reply metadata") becomes accurate. No docs edit is needed beyond
confirming the sentence.

The Note body stays immutable: a child's parent never changes, and pre-change items never start
emitting the key. The one-year `cache-control` on the object endpoint therefore stays correct.

Do not emit `context` or `conversation` in this change (Open Question 4):
- Every context FEP is DRAFT.
- FEP-7888 says a `context` "SHOULD be resolvable" and its resolved form "SHOULD in some way have
  an associated Collection".
- FEP-f228 says a present `context` "MUST resolve to a collection of posts".
- FAP has no endpoint to serve such a collection.
- Mastodon threads on `inReplyTo` alone, reads `conversation` rather than `context` on intake, and
  without `conversation` puts the child in the parent's conversation (`status.rb:449`).

### 5. Addressing and mentions

A self-reply uses `computeAddressing` with its capped visibility (§2), exactly like any other
post of that visibility, and carries no Mention tag. This matches what Mastodon emits for a
self-reply with no `@` in its text (see Standards).

Replies to other actors would need the parent author in `cc` and a `Mention` tag (Mastodon docs,
Mentions). That is out of scope with the rest of non-self replies.

### 6. Delivery

There is no change to fan-out. Followers receive each post of the chain as its own
`Create(Note)`.

SQS does not guarantee cross-message ordering, so a follower can receive a child before its
parent. Mastodon handles that case like this:
1. It first filters the child from home feeds, because its `in_reply_to_id` is still nil
   (`feed_manager.rb:505`).
2. `resolve_thread` → `ThreadResolveWorker` fetches the `inReplyTo` URI. FAP's object endpoint
   serves it, because the parent was stored before the client could learn its id.
3. The worker attaches the child and re-distributes it to feeds (`thread_resolve_worker.rb:21`),
   provided the child is within the 6-hour realtime window (`status.rb:188,218-220`).

A bot posting a chain in one run is well inside that window.

### 7. `repliesCount` on the parent

Increment the parent's `repliesCount` (`store.incrementRepliesCount(username:statusId:)`,
`DynamoDBStore.swift:556`) when the reply's effective visibility is `public` or `unlisted`. This
matches Mastodon's `distributable?` gate (`status.rb:484`, `visibility.rb:31-33`). A `private`
reply does not count, because the post page shows the count to anyone
(`ProfileHandler/main.swift:536`).

- **Ordering.** Do the increment *after* the delivery fan-out has been enqueued
  (`PostHandler/main.swift:332-352`), not between `storeStatus` and delivery.
- **Failure.** Log a failed increment and swallow it, so the request still returns 200. The count
  is display-only. If it threw, the client would get a 5xx for a status that was stored and
  delivered, and a retrying bot would post a second child of the same parent, which forks the
  chain.
- **Doc comment.** Update the comment at `Status.swift:53` to "replies received, local and remote,
  public or unlisted".
- **No decrement.** There are no outbound reply deletes, because FAP has no status-delete endpoint,
  so nothing ever decrements this count.

**This mutates the parent's post page.** The page renders the count under a one-year
`cache-control` (`ProfileHandler/main.swift:121-128,536`). This is not new:
- Inbound likes, boosts, quotes and replies already change the same body after publication.
- The page's freshness has only ever been bounded by CloudFront's 300 s cap (`MediumCachePolicy`).

So the one-year header is already inaccurate for this page, and §7 follows existing behaviour.
§9 does **not** use the cache header as its reason to defer descendant links. Fixing the post
page's header is separate from this change.

FAP does not emit a `replies` collection in this change (Open Question 3).

### 8. Mastodon client API

- Move `buildStatusResponse` from `Sources/PostHandler/main.swift:425` into ActivityPubCore so it
  can be tested.
- `in_reply_to_id` becomes the parent's **id**, taken from `parseLocalStatusUri(inReplyTo)`. It is
  `null` when the §3 check fails. It is no longer the stored string.
- Add `in_reply_to_account_id`, which is the parent's username and therefore the account id FAP
  already exposes. It is `null` when the status is not a reply. For a pure self-thread it equals
  Mastodon's `carried_over_reply_to_account_id` result. See Open Question 1 for cross-actor
  threads.
- **`openapi.yaml`:**
  - Add `in_reply_to_account_id` to the `Status` schema as an **optional, nullable** string. It
    is *not* listed in `required:`.
  - Update the `in_reply_to_id` description.
  - Add a `"404"` response to `createStatus` (`openapi.yaml:400-410`).
- **Why optional first.** `sync-openapi.yml` mirrors the spec to the downstream client as soon as
  it merges, but a production server emits the field only after its next release. A generated
  client that treats the field as required would fail to decode every create response from a
  server that predates it.
  - Promote the field to `required` in a later change, once every deployed server emits it.
  - The implementation PR must build a generated consumer against the branch's `openapi.yaml`
    before merge: the `integration-tests` `APIClient` package and the mirrored client (review
    standards S11/S12).
- `/context` and status GETs stay out of scope. No read endpoint exists to add them to.
- **Release notes.** The release that ships this must say that `POST /api/v1/statuses` with an
  unknown or non-owned `in_reply_to_id` now returns 404 instead of 200. It must also say that a
  reply's visibility is capped at its parent's.

### 9. Web view

**Required:** on the post page, when `inReplyTo` passes the §3 check, render "In reply to" with a
link to `https://{serverDomain}/@{username}/{parentId}`.

**Out of scope:** "continued below" links or a descendant list on the parent page. These need a
query from parent to children. Statuses have no `inReplyTo` index, so that is the same index
work as the `replies` collection (Open Question 3). The page cache is not the reason (see §7).

The profile page keeps listing every post of a thread newest-first (Open Question 5).

## Testing

Every test below includes a negative control. Before the test counts, it must be seen going red
when the capability is removed.

### Unit (`Tests/ActivityPubCoreTests`, Swift Testing)

- **`buildNoteJSON` emits `inReplyTo`.**
  - A status whose `inReplyTo` is a local status URI produces `"inReplyTo":"<uri>"`.
  - Negative controls:
    - `inReplyTo: nil` produces no key.
    - A bare id such as `"01ABC…"` produces no key.
    - A remote `https://` URI produces no key.
  - Break it: temporarily remove the emission and confirm the positive test fails.
- **`parseLocalStatusUri`.**
  - It parses server-domain and handle-domain URIs.
  - Negative control: it rejects a remote host, a non-`statuses` path, and a URI with too few
    segments.
  - Existing InboxHandler behaviour is preserved.
- **`resolveReplyParent`.**
  - nil or empty input returns `.none`, and the lookup is not called.
  - A found status returns `.resolved`.
  - Negative control: a lookup returning nil gives `.notFound`.
- **`cappedReplyVisibility`.**
  - It covers all nine requested × parent pairs.
  - Wider requests are downgraded, and equal or narrower ones pass through.
  - Negative control: `public` under a `private` parent yields `private`, not `public`.
- **`buildStatusResponse`.**
  - A reply yields `in_reply_to_id == parent id` (not the URI) and
    `in_reply_to_account_id == username`.
  - Negative control: a non-reply, and a status holding a bare-id `inReplyTo`, both yield `null`
    for both fields.

### Schema conformance (`integration-tests/Tests/IntegrationTests/SchemaConformanceTests.swift`)

Commit two create-response fixtures next to `Fixtures/outbox-page.json`, and decode both through
the generated `Components.Schemas.Status`:
- `status-reply.json`: a reply response including `in_reply_to_account_id`. Assert both reply
  fields decode.
- `status-legacy.json`: a response from a server that predates this change, without
  `in_reply_to_account_id`. Assert it decodes.

**Negative control:** temporarily list `in_reply_to_account_id` in `required:` and confirm that
`status-legacy.json` fails to decode. That shows the fixture measures the optional-first
sequencing in §8.

### Integration (`integration-tests/`, runs on stage)

These tests drive the generated `APIClient` (`client.createStatus`), not raw `URLSession`, so the
response is decoded through `Components.Schemas.Status`. They use the `TEST_CLIENT_API_URL` /
`TEST_BEARER_TOKEN` variables already used by `DualAuthTests.swift`. Posts are `unlisted`, as in
the existing test.

- **Thread round trip.**
  1. Post a root status, then post a reply with `in_reply_to_id = root.id`.
  2. Assert the decoded reply has `in_reply_to_id == root.id` and
     `in_reply_to_account_id == <username>`.
  3. `GET <reply.uri>` with `Accept: application/activity+json` and assert
     `inReplyTo == root.uri`.
  - Negative control: `GET <root.uri>` has no `inReplyTo` key.
- **Unknown parent.**
  - Post with `in_reply_to_id` set to a well-formed ULID that doesn't exist, and assert the
    `.notFound` (404) case.
  - Negative control: the same body without `in_reply_to_id` returns `.ok`.
- **Visibility cap.**
  - Post a `private` root, then reply with `visibility: public`.
  - Assert the response `visibility == "private"` and that the reply Note's `to` is
    `[followers]`.
  - Negative control: an `unlisted` reply to an `unlisted` root stays `unlisted`.
- **Chain of three.** Assert that each child's `inReplyTo` is the previous post's URI, not the
  root's.

### Federation (manual, against stage)

- **BrowserPub** (https://browse.activitypub.dev).
  - Load the last reply's URI and confirm it renders "in reply to" the previous post and walks
    up to the root.
  - BrowserPub doesn't cache failed lookups, which makes it the first check.
- **Mastodon.**
  - Use an account on a Mastodon instance that follows the stage test actor. Post a three-part
    thread.
  - **Acceptance:** on that instance, `GET /api/v1/statuses/:id/context` for the last post
    returns the other two posts as `ancestors`, in order. The home timeline is not the
    criterion, because it shows each post as its own entry.
  - **Out-of-order case:** if delivery order can be forced, deliver the child before the parent.
    Confirm `/context` still returns the parent as an ancestor once `ThreadResolveWorker` has
    run.
  - Mastodon caches discovery failures for hours, so if a lookup fails, retry on a different
    instance before debugging FAP.
- **Negative control for both.** Run the same three-post procedure against the current build,
  before this change, and record that `/context` returns no ancestors. This shows the check can
  fail, and that the change is what makes it pass.

### Build gate

Per the repo's CLAUDE.md, build every target on the Linux runner VM with
`swift package archive --allow-network-connections docker` before opening the implementation PR.
Also build the generated consumers against the branch's `openapi.yaml` (§8).

## Unverified

- **Mastodon's `items_context_url` route.**
  - The URL path shape, and whether Mastodon serves it as a dereferenceable collection.
  - Only the helper name is verified (`app/lib/activitypub/tag_manager.rb:101-108`).
- **Mastodon reading `context` on intake.** No such read was found in `create.rb`. Absence in one
  file does not prove Mastodon never consumes it.
- **Mastodon's web composer on self-replies.**
  - Whether it omits the author's own `@handle` when replying to yourself. The client JS was not
    read.
  - Only the server-side mention scan is verified.
- **The `replies_count` "added" version on the Mastodon Status entity page.** The research
  returned 4.5.0, which conflicts with the field's long history. This spec relies only on its
  definition and on `status.rb:484`, not on its version.
- **Forcing out-of-order delivery for the manual federation check.** No mechanism has been
  identified. Without one, only the in-order path is exercised against a real Mastodon.

## Open questions

1. **Replies to other local actors.** Is replying to another FAP actor's status on the same server
   in scope? It needs:
   - an id→owner lookup, such as a GSI on status id or accepting a full status URI in
     `in_reply_to_id`
   - Mention and `cc` handling
   - an `in_reply_to_account_id` that follows Mastodon's `carried_over_reply_to_account_id`
     (`status.rb:461-466`) rather than always naming the parent's author

   Proposed: no, a follow-up spec.
2. **Replies to remote statuses.** Confirm they stay out of scope. They need a remote-status cache,
   signed fetch for authorized-fetch servers (`fetchRemoteObject` sends no signature,
   `Sources/ActivityPubCore/FetchRemoteObject.swift:36-42`), Mention tags and remote addressing.
3. **`replies` collection.** Should FAP add `replies` now, so that servers which discover the root
   without following the author can backfill the thread? Mastodon fetches up to 5 same-server
   replies this way.
   - The lowest-risk form is a link-only `"replies":"…/statuses/{id}/replies"`, which keeps the
     Note body immutable.
   - It needs a new handler and API Gateway route. The existing `/users/*/statuses/*` CloudFront
     behavior already matches the path.
   - It also needs an index from parent to self-replies, because statuses have no `inReplyTo`
     index today.
   - Proposed: a follow-up.
4. **`context` / `conversation`.** Do you want either emitted later? All context FEPs are DRAFT,
   Mastodon reads `conversation` on intake, and FEP-7888/FEP-f228 expect a `context` to resolve to
   something with an associated collection, which FAP would have to serve.
5. **Profile page.** Should a thread show on the profile page as N separate posts newest-first, as
   it does today? Or should replies be collapsed under their root, or hidden from the profile
   list?
6. **Server-side length check.** `PostHandler` doesn't enforce the advertised 5,000-character
   limit. Should that be fixed alongside this, so an over-long chunk fails loudly instead of being
   published? Or should it be a separate issue?
7. **Visibility cap after #270.** This spec downgrades a reply that is wider than its parent
   (§2 step 5) while FederatedActivityPublisher#270 is open. Once #270 makes the object endpoint
   respect visibility, should the cap be lifted to match Mastodon? Mastodon never changes
   visibility because of the thread (`post_status_service.rb:85-87`). Or should the cap stay as
   FAP policy?
