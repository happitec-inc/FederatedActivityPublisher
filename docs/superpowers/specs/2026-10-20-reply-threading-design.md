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
- Emit `inReplyTo` on every outbound Note: delivery fan-out, `GET /users/{u}/statuses/{id}`, and the
  outbox.
- Increment the parent's `repliesCount` when a self-reply is created.
- Return the correct `in_reply_to_id` and `in_reply_to_account_id` in the create response.
- Show an "In reply to" link on the web post page.
- Handle any legacy `inReplyTo` values that hold a raw id.

**Out of scope (each needs its own spec):**
- Replies to another local actor's status. Statuses are keyed per actor (`PK=ACTOR#{username}`),
  so a bare id can't be resolved to an owner without a new lookup path. See Open Question 1.
- Replies to remote statuses. This needs a remote-status cache, Mention tags, and addressing to the
  remote author.
- A `replies` collection on the parent Note (Open Question 4).
- `context` / `conversation` properties (Open Question 5).
- `GET /api/v1/statuses/:id` and `GET /api/v1/statuses/:id/context`. FAP serves no Mastodon-API
  status reads at all today. See "Current behaviour".
- A thread view on the web: the parent page listing its descendants.
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
| 7888 | Demystifying the context property | DRAFT | 2023-03-14 | "A `context` SHOULD be resolvable"; objects sharing a context "SHOULD be strongly related"; consumers SHOULD group by `context`. |
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

**What Mastodon consumes** (`app/lib/activitypub/activity/create.rb`):
- `inReplyTo` (falling back to `inReplyToAtomUri`), lines 441-447.
- When the parent is unknown, `resolve_thread` (lines 382-386) enqueues `ThreadResolveWorker`.
  That worker looks the parent up locally and otherwise calls `FetchRemoteStatusService` on the
  `inReplyTo` URI, then attaches the child (`app/workers/thread_resolve_worker.rb:9-21`).
- `fetch_replies` (line 81) backfills from the `replies` collection.
- On intake it reads `conversation` (line 118, `conversation_from_uri`, lines 422-431). No read of
  `context` was found.

**Client API:**
- `POST /api/v1/statuses` takes `in_reply_to_id`: "ID of the status being replied to"
  (https://docs.joinmastodon.org/methods/statuses/).
- When that id is missing or not viewable, Mastodon returns **404** with
  `statuses.errors.in_reply_not_found` (`app/controllers/api/v1/statuses_controller.rb`,
  `set_thread`, ~lines 105-110).
- The Status entity (https://docs.joinmastodon.org/entities/Status/) has `in_reply_to_id` and
  `in_reply_to_account_id`. Both are nullable strings.
- `GET /api/v1/statuses/:id/context` returns a Context entity with `ancestors` and `descendants`
  (https://docs.joinmastodon.org/entities/Context/).

### What this means for a self-thread

`inReplyTo` set to the parent's dereferenceable URI is what threads a post on Mastodon. It is
both the only threading property Mastodon requires on intake and the property FEP-f228 names as
the primary backfill path.

A self-reply needs no Mention tag. Mastodon generates none for a self-reply whose text contains no
`@`, and a self-reply has nobody to notify. Addressing stays the same as for any post of that
visibility.

`replies`, `context` and `conversation` improve backfill for servers that discover a thread
without following the author. A follower doesn't need them, because it receives every post in
the chain by delivery.

## Current FAP behaviour

Verified by reading the code at `8a78008`.

**Create path.**
- `CreateStatusRequest.inReplyToId` decodes `in_reply_to_id`
  (`Sources/ActivityPubCore/Models/CreateStatusRequest.swift:27,38`).
- `PostHandler` copies it verbatim into `Status.inReplyTo` (`Sources/PostHandler/main.swift:310`)
  without looking anything up or validating it.
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
- It has three callers:
  - delivery fan-out (`Sources/PostHandler/main.swift:325`)
  - the object endpoint (`Sources/ObjectHandler/main.swift:74`)
  - the outbox (`Sources/OutboxHandler/main.swift:80`)
- `buildCreateActivityJSON` (`Note.swift:119-130`) wraps it.
- `DeliverHandler` signs and POSTs the prebuilt JSON unchanged.

**Addressing.** `computeAddressing` (`Note.swift:146-165`):

| visibility | `to` | `cc` |
|---|---|---|
| public | `[as:Public]` | `[followers]` |
| unlisted | `[followers]` | `[as:Public]` |
| private | `[followers]` | `[]` |

`PostHandler` sets `tags: nil` (`main.swift:308`), so no Mention tags are ever emitted.

**Delivery.** One `DeliveryJob` per distinct (shared) inbox of the author's followers, enqueued to
SQS (`main.swift:332-352`).

**Object endpoint caching.**
- `ObjectHandler` returns `cache-control: public, max-age=31536000` (`ObjectHandler/main.swift:80`).
- CloudFront caps `/users/*/statuses/*` at 300 s (`LongCachePolicy`, `activity-app/cdn/template.yaml:103-109,404-409`).
- Downstream caches still see the one-year header, so the Note body must be immutable.

**Mastodon client API.**
- The only status endpoint is `POST /api/v1/statuses` (`activity-app/functions/template.yaml:145-146`).
- There is no `GET /api/v1/statuses/:id` and no `/context`.
- The create response comes from `buildStatusResponse` (`Sources/PostHandler/main.swift:425-451`).
  It echoes the stored `inReplyTo` as `in_reply_to_id` (`:444,449`) and has no
  `in_reply_to_account_id`.
- `openapi.yaml:891` and `:958` document `in_reply_to_id`.
- The account id FAP exposes is the username (`Sources/VerifyCredentialsHandler/main.swift:131`).

**Web view.**
- The post page (`Sources/ProfileHandler/main.swift:395` onward) shows a reply count
  (`:534-537`) but no reply relationship.
- The post page is served with `max-age=31536000` (`:121-127`). CloudFront caps `/@*` at 300 s
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

InboxHandler, PostHandler and the read helpers below all call it. This is one function in one
place, with no new component.

### 2. Resolve and validate `in_reply_to_id` (PostHandler)

Insert a step between visibility validation and status construction, before anything is written:

1. If `in_reply_to_id` is absent or empty, the status is not a reply.
2. Otherwise call `store.getStatus(username: <authenticated user>, id: in_reply_to_id,
   consistentRead: true)`.
   - Use `consistentRead: true` because a bot posts the chain back-to-back. The parent was
     written milliseconds earlier, and a default eventually-consistent `GetItem` can miss it.
3. If no status is found, return **404** `{"error":"Status to reply to not found"}` and write nothing. This
   matches Mastodon's 404 for an unknown or unviewable `in_reply_to_id`. The same 404 covers all
   three non-self cases:
   - **missing parent**
   - **another local actor's status**: the lookup is scoped to the author's partition, so the
     item is invisible
   - **a remote URI**: not a local id, so the lookup misses
4. If found, set `inReplyTo = parent.uri`. That is the canonical URI
   `https://{serverDomain}/users/{u}/statuses/{id}`, as constructed at
   `Sources/PostHandler/main.swift:293`.

Parent visibility does not restrict the reply's visibility. This matches Mastodon, which allows a
public reply to a followers-only post. Open Question 7 covers whether FAP should restrict it.

Put the resolution logic in an ActivityPubCore function that takes a lookup closure, so it can be
unit-tested without DynamoDB:

```swift
public enum ReplyParentResolution { case none, resolved(Status), notFound }
public func resolveReplyParent(
    inReplyToId: String?, lookup: (String) async throws -> Status?
) async throws -> ReplyParentResolution
```

### 3. Storage: `inReplyTo` is a URI

New items store the parent URI. There is no schema change and no new attribute.

**Legacy items.**
- A stored `inReplyTo` that does not begin with `https://` is a raw id from before this change.
  It can only refer to a status by the same author, because FAP clients only ever had their own
  ids.
- Add `Status.inReplyToUri(serverDomain:) -> String?`:
  - a value starting with `https://` is returned unchanged
  - any other non-empty value returns `https://{serverDomain}/users/{username}/statuses/{value}`
- Every reader uses this helper instead of the raw field.
- Normalizing at read time needs no data migration. A data migration would need a one-off
  workflow, because local AWS commands are not used for stack data.
- Whether any legacy items exist is unverified (see Unverified).

### 4. Emit `inReplyTo` on the Note

In `buildNoteJSON`, emit `"inReplyTo":"<uri>"` when `status.inReplyToUri(serverDomain:)` is
non-nil, and omit the key otherwise. All three callers (delivery, object endpoint, outbox) pick it
up because they share the builder.

The Note body stays immutable: a child's parent never changes. The one-year `cache-control` on the
object endpoint therefore stays correct.

Do not emit `context` or `conversation` in this change (Open Question 5):
- Every context FEP is DRAFT.
- FEP-7888 and FEP-f228 say a `context` SHOULD/MUST resolve to a collection, which FAP has no
  endpoint for.
- Mastodon threads on `inReplyTo` alone and reads `conversation`, not `context`, on intake.

### 5. Addressing and mentions

A self-reply uses `computeAddressing` exactly like any other post of its visibility, and carries
no Mention tag. This matches what Mastodon emits for a self-reply with no `@` in its text (see
Standards).

Replies to other actors would need the parent author in `cc` and a `Mention` tag (Mastodon docs,
Mentions). That is out of scope with the rest of non-self replies.

### 6. Delivery

There is no change to fan-out. Followers receive each post of the chain as its own
`Create(Note)`.

SQS does not guarantee cross-message ordering, so a follower can receive a child before its
parent. That is handled on the receiving side. Mastodon's `resolve_thread` → `ThreadResolveWorker`
fetches the `inReplyTo` URI, and FAP's object endpoint serves it, because the parent was stored
before the client could learn its id.

### 7. `repliesCount` on the parent

After `storeStatus` succeeds for a reply, call `store.incrementRepliesCount(username:statusId:)`
on the parent (`DynamoDBStore.swift:556`). Follow the same sequential, non-transactional pattern
as `incrementStatusCount` (`PostHandler/main.swift:322`) and the inbox reply path.

Update the doc comment at `Status.swift:53` to "replies received, local and remote". Mastodon's
`replies_count` is "How many replies this status has received", so it counts self-replies too.

There are no outbound reply deletes, because FAP has no status-delete endpoint, so nothing ever
decrements this count.

FAP does not emit a `replies` collection in this change (Open Question 4).

### 8. Mastodon client API

- Move `buildStatusResponse` from `Sources/PostHandler/main.swift:425` into ActivityPubCore so it
  can be tested.
- `in_reply_to_id` becomes the parent's **id**, derived from `inReplyToUri` via
  `parseLocalStatusUri`. It is no longer the stored string.
- Add `in_reply_to_account_id`, which is the parent's username and therefore the account id FAP
  already exposes. It is `null` when the status is not a reply.
- Update the `Status` schema in `openapi.yaml`:
  - add `in_reply_to_account_id` as a required, nullable string
  - update the `in_reply_to_id` description
- The OpenAPI spec is mirrored to the downstream client repository by
  `.github/workflows/sync-openapi.yml`, so the client sees the field on its next sync.
- `/context` and status GETs stay out of scope. No read endpoint exists to add them to.

### 9. Web view

**Required:** on the post page, when `inReplyToUri` parses as a local status, render "In reply
to" with a link to `https://{serverDomain}/@{username}/{parentId}`. This is immutable, so the
one-year page cache stays valid.

**Optional / out of scope:** "continued below" links or a descendant list on the parent page. The
parent page body would then change after publication, which conflicts with its `max-age=31536000`
(`ProfileHandler/main.swift:127`).

The profile page keeps listing every post of a thread newest-first (Open Question 6).

## Testing

Every test below includes a negative control. Before the test counts, it must be seen going red
when the capability is removed.

### Unit (`Tests/ActivityPubCoreTests`, Swift Testing)

- **`buildNoteJSON` emits `inReplyTo`.**
  - A status with `inReplyTo` set to a URI produces `"inReplyTo":"<uri>"`.
  - Negative control: `inReplyTo: nil` produces no `inReplyTo` key.
  - Break it: temporarily remove the emission and confirm the positive test fails.
- **Legacy normalization.**
  - `inReplyToUri` returns a URI unchanged.
  - A bare ULID becomes the author's status URI.
  - nil or empty returns nil.
- **`parseLocalStatusUri`.**
  - It parses server-domain and handle-domain URIs.
  - Negative control: it rejects a remote host, a non-`statuses` path, and a URI with too few
    segments.
  - Existing InboxHandler behaviour is preserved.
- **`resolveReplyParent`.**
  - nil or empty input returns `.none`, and the lookup is not called.
  - A found status returns `.resolved`.
  - Negative control: a lookup returning nil gives `.notFound`.
- **`buildStatusResponse`.**
  - A reply yields `in_reply_to_id == parent id` (not the URI) and
    `in_reply_to_account_id == username`.
  - Negative control: a non-reply yields both as `null`.

### Integration (`integration-tests/`, runs on stage via `run-integration-tests.yml`)

These tests use the existing `TEST_CLIENT_API_URL` / `TEST_BEARER_TOKEN` pattern from
`DualAuthTests.swift`. Posts are `unlisted`, as in the existing test.

- **Thread round trip.**
  1. Post a root status, then post a reply with `in_reply_to_id = root.id`.
  2. Assert the reply response has `in_reply_to_id == root.id` and
     `in_reply_to_account_id == <username>`.
  3. `GET <reply.uri>` with `Accept: application/activity+json` and assert
     `inReplyTo == root.uri`.
  - Negative control: `GET <root.uri>` has no `inReplyTo` key.
- **Unknown parent.**
  - Post with `in_reply_to_id` set to a well-formed ULID that doesn't exist, and assert 404.
  - Negative control: the same body without `in_reply_to_id` returns 200.
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
  - Confirm the posts render as one thread in the home timeline. Confirm
    `GET /api/v1/statuses/:id/context` on that instance, for the last post, returns the other two
    as `ancestors`.
  - Mastodon caches discovery failures for hours, so if a lookup fails, retry on a different
    instance before debugging FAP.
- **Negative control for both.** Run the same three-post procedure against the current build,
  before this change, and record that the posts appear as three unrelated statuses. This shows
  the check can fail, and that the change is what makes it pass.

### Build gate

Per the repo's CLAUDE.md, build every target on the Linux runner VM with
`swift package archive --allow-network-connections docker` before opening the implementation PR.

## Unverified

- **Legacy raw-id items.**
  - Whether any stored status currently has an `inReplyTo` holding a raw id. Checking needs a
    DynamoDB read against stage and prod, which this spec did not do.
  - The design handles both cases.
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
  definition, not its version.
- **The AS2 Vocabulary's "intentionally vague" remark on `context`.** It is known only through
  FEP-7888's quotation of it.

## Open questions for Erin

1. **Replies to other local actors.** Is replying to another FAP actor's status on the same server
   in scope? It needs an id→owner lookup, such as a GSI on status id or accepting a full status
   URI in `in_reply_to_id`, plus Mention and `cc` handling. Proposed: no, a follow-up spec.
2. **Replies to remote statuses.** Confirm they stay out of scope. They need a remote-status cache,
   signed fetch for authorized-fetch servers (`fetchRemoteObject` sends no signature,
   `Sources/ActivityPubCore/FetchRemoteObject.swift:36-42`), Mention tags and remote addressing.
3. **Legacy items.** Is read-time normalization (Design §3) acceptable, or do you want a one-off
   backfill workflow that rewrites raw ids to URIs?
4. **`replies` collection.** Should FAP add `replies` now, so that servers which discover the root
   without following the author can backfill the thread? Mastodon fetches up to 5 same-server
   replies this way.
   - The lowest-risk form is a link-only `"replies":"…/statuses/{id}/replies"`, which keeps the
     Note body immutable.
   - It needs a new handler and API Gateway route. The existing `/users/*/statuses/*` CloudFront
     behavior already matches the path.
   - It also needs an index from parent to self-replies, because statuses have no `inReplyTo`
     index today.
   - Proposed: a follow-up.
5. **`context` / `conversation`.** Do you want either emitted later? All context FEPs are DRAFT,
   Mastodon reads `conversation` on intake, and a FEP-7888-conformant `context` must resolve to a
   collection that FAP would have to serve.
6. **Profile page.** Should a thread show on the profile page as N separate posts newest-first, as
   it does today? Or should replies be collapsed under their root, or hidden from the profile
   list?
7. **Visibility across a thread.** Should a reply be allowed to be *more* visible than its parent,
   for example a public reply to a private parent? Mastodon allows it. FAP would then publicly
   link the parent's URI.
8. **Server-side length check.** `PostHandler` doesn't enforce the advertised 5,000-character
   limit. Should that be fixed alongside this, so an over-long chunk fails loudly instead of being
   published? Or should it be a separate issue?
9. **Object endpoint and private statuses (observed, separate issue?).** `ObjectHandler` returns
   404 for private and direct statuses only on the HTML branch (`ObjectHandler/main.swift:52-62`).
   A request with `Accept: application/activity+json` gets the Note regardless of visibility.
   Threading makes parent URIs more discoverable. Should this be filed as its own issue?
