# Reply Threading — Design Spec

## Goal

Let a local actor publish a reply to any status it can see: its own, another local actor's, or a
remote one. Each reply federates with a correct `inReplyTo`, reaches the parent's author, and is
reported through the Mastodon-compatible client API.

The motivating case is a bot that posts a long daily summary. When the summary exceeds the
5,000-character status limit, the bot splits it into a root post and a chain of self-replies.

Today FAP accepts `in_reply_to_id` on create but never federates it, so a "thread" arrives at
remote servers as N unrelated posts.

## Phases

The work ships in three phases. Each phase can be shipped and released on its own.

| Phase | Parent | Unblocks | New components |
|---|---|---|---|
| 1 | The posting actor's own status | The motivating bot thread | None |
| 2 | Another local actor's public or unlisted status | Conversations between actors on one server | None |
| 3 | A remote status | Replying into the wider fediverse | Signing and hardening in the existing shared fetch function |

Phase 1 doesn't depend on phases 2 or 3. Phase 2 builds on phase 1's resolver and stored fields.
Phase 3 builds on phase 2's Mention and addressing logic.

**Out of scope for all phases (decided, see "Decisions"):**
- A `replies` collection.
- `context` / `conversation`.
- `GET /api/v1/statuses/:id` and `/context`. FAP serves no Mastodon-API status reads today.
- A thread view on the web.
- Mention parsing from status text (Open Question 2).
- `direct` visibility. It is still rejected (`Sources/PostHandler/main.swift:194`).
- Server-side length enforcement, which is tracked separately in FederatedActivityPublisher#272.
- Rewriting `inReplyTo` values stored before this change (§1.3).

**Follow-ups outside every phase:**
- Linked Data Signatures, which would make a remote server forward FAP's replies (Open Question 4).
- Delete and Update reaching the parent's author (Open Question 6).

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
- **§7.1.2 Forwarding from Inbox:** a server MUST forward an inbound activity only when all three
  conditions hold:
  - it hasn't seen the activity before
  - its `to`/`cc`/`audience` contain "a Collection owned by the server"
  - its "`inReplyTo`, `object`, `target` and/or `tag` are objects owned by the server"

  `context` is not a forwarding condition. A FAP reply addresses the parent author's *actor*, not
  a collection that the author's server owns, so this rule never makes that server forward a FAP
  reply. Mastodon's own forwarding has a stricter condition again (see Mastodon below).
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

**Security docs** (https://docs.joinmastodon.org/spec/security/):
- "When secure mode is enabled, all GET requests require HTTP signatures as well."
- For a GET, "Typically, you will want to include the request target, as well as the host and the
  date." For a POST, "The `Digest:` header must also be included".
- Receivers "check that the signed request was made within the past 12 hours".

**What Mastodon's signature verifier needs** (`app/lib/signed_request.rb`,
`app/controllers/concerns/signature_verification.rb`, `app/controllers/statuses_controller.rb`):
- `verify_signature_strength!` (`signed_request.rb:54-57`) requires three things on a GET:
  - `date` or `(created)`
  - `(request-target)` or `digest`
  - `host`
- `(request-target)` is checked first against `original_fullpath`, which includes the query string
  (`signed_request.rb:113`). A path without the query string is only a temporary compatibility
  fallback.
- In secure mode, status JSON requires a signature: `require_account_signature!`
  (`statuses_controller.rb:11`).
- `signed_request_account` (`signature_verification.rb:45` onward) accepts any account whose key
  verifies. No instance actor is required.

**What Mastodon emits** (`app/serializers/activitypub/note_serializer.rb`,
`app/lib/activitypub/tag_manager.rb`):
- `inReplyTo` is the parent's URI, and only when the status is a reply with a resolved thread
  (`note_serializer.rb:99-107`).
- `replies` is emitted only for local statuses (`note_serializer.rb:22`). Its first page holds up
  to 5 self-replies (`:61-74`; `app/controllers/activitypub/replies_controller.rb:33-34,76`).
- It emits both `conversation` (`note_serializer.rb:157-166`) and `context` (`:168-173`).
- Mention tags are `{type: "Mention", href: <account URI>, name: "@acct"}` (`note_serializer.rb:333`
  onward, `MentionSerializer`).
- **`to`** (`tag_manager.rb:171-196`):
  - public is `[as:Public]`
  - unlisted and private are `[author followers]` (`:175`)
- **`cc`** (`tag_manager.rb:203-235`):
  - public adds `author followers`
  - unlisted adds `as:Public`
  - for every visibility except direct and limited, every mentioned account's URI is appended
    (`:215,228`)
- Mentions come only from scanning the status text (`app/services/process_mentions_service.rb:25-26`).
  The parent's author is never mentioned or put in `cc` automatically.
- **Public spellings.** All three public spellings are recognised: the full IRI, `as:Public` and
  `Public` (`tag_manager.rb:14-15`).

**Who Mastodon delivers a reply to** (`app/lib/status_reach_finder.rb`):
- Inboxes are reached accounts, plus followers, plus relays (`:12-13`).
- The reached accounts include `replied_to_account_id` (`:31`) and the mentioned accounts (`:34`).
- **A distributable reply reaches `in_reply_to_account_id` even without a mention:**
  `@status.in_reply_to_account_id if distributable?` (`:47-48`). That value is the carried-over
  account.
- **When the direct parent's author is local**, a distributable reply also goes to that author's
  followers:
  `if @status.in_reply_to_local_account? && distributable?` →
  `@status.account.followers.or(@status.thread.account.followers…)` (`:105-106`).
  - `in_reply_to_local_account?` is `reply? && thread&.account&.local?` (`status.rb:210-212`).
  - `thread` is the *direct* parent. Carry-over doesn't drive the followers union.

**How Mastodon forwards an inbound reply** (`app/lib/activitypub/activity/create.rb:491-495`):
- `forward_for_reply` runs only when
  `@status.distributable? && @json['signature'].present? && reply_to_local?`.
- `signature` is a Linked Data Signature embedded in the activity body. FAP emits none: there is no
  `RsaSignature2017` in `Sources/`.
- **So a Mastodon server never forwards a FAP reply to its local author's followers.**

**Who may reply** (`app/controllers/api/v1/statuses_controller.rb:106-111`,
`app/policies/status_policy.rb`):
- `set_thread` finds the parent, then calls `authorize(@thread, :show?)`. Not found or not
  permitted gives a **404** with `statuses.errors.in_reply_not_found`.
- For a private status, `show?` is `owned? || following_author? || mention_exists?`
  (`status_policy.rb:9-10`).

**What Mastodon does on create** (`app/services/post_status_service.rb`, `app/models/status.rb`):
- **Visibility is never changed because of the thread.** It is overridden in two cases only
  (`post_status_service.rb:85-87`):
  - a silenced account's public post becomes unlisted (`:86`)
  - a public or unlisted post that quotes a private status becomes private (`:87`)

  Line 87 is the precedent this spec follows for its temporary cap: Mastodon downgrades rather
  than rejecting.
- **`replies_count` counts only distributable replies:**
  `thread&.increment_count!(:replies_count) if in_reply_to_id.present? && distributable?`
  (`status.rb:484`). `distributable?` is `public_visibility? || unlisted_visibility?`
  (`app/models/concerns/status/visibility.rb:31-33`).
- **`in_reply_to_account_id` follows `carried_over_reply_to_account_id`** (`status.rb:461-466`):
  - if the parent is by the same account *and* is itself a reply, the parent's own
    `in_reply_to_account_id` is carried over
  - otherwise the parent's author is used

  The Status entity docs say it "sometimes skips over self-replies".
- **Conversation.** When no `conversation` is supplied, a reply joins its parent's conversation
  (`status.rb:449`).

**What Mastodon consumes** (`app/lib/activitypub/activity/create.rb`,
`app/lib/activitypub/parser/status_parser.rb`):
- **`inReplyTo`.** It reads `inReplyTo`, falling back to `inReplyToAtomUri` (`create.rb:440-447`).
  When the parent is unknown, `resolve_thread` (`:382-386`) enqueues `ThreadResolveWorker`, which
  fetches the parent (`app/workers/thread_resolve_worker.rb:9-21`).
- **Mentions** are resolved by `href`, not by `name` (`create.rb:255-263`).
- **Visibility** is derived from the audience (`status_parser.rb:101-111`):
  - public in `to` → public
  - public in `cc` → unlisted
  - the author's followers collection in `to` → private
  - anything else → direct
- **`conversation`.** It reads `conversation` (`create.rb:118`). No read of `context` was found.

**How Mastodon fetches remote objects** (`app/helpers/json_ld_helper.rb`, `app/lib/request.rb`,
`app/services/activitypub/fetch_remote_status_service.rb`,
`app/services/activitypub/fetch_remote_actor_service.rb`, `app/lib/activitypub/activity.rb`):
- **`fetch_resource`** (`json_ld_helper.rb:242-252`):
  - With an unknown id, it fetches, takes `json['id']`, re-fetches that id, and accepts the result
    only if `json['id'] == uri`.
  - With a known id, it does just the second step.
- **Response checks.** A response is used only when the status is 200 *and*
  `valid_activitypub_content_type?` holds (`json_ld_helper.rb:281,351` onward). That means
  `application/activity+json`, or `application/ld+json` with the ActivityStreams profile.
- **Body cap.** The body is capped at 1 MB (`request.rb:293-294`, `body_with_limit(limit = 1.megabyte)`).
- **Redirects.** At most 3 hops (`request.rb:101-102`, `max_hops: 3`). The HTTP-signature feature
  signs each request it sends (`request.rb:72-75`).
- **Private addresses.** Every resolved address is checked before the socket connects
  (`request.rb:325-334`, `check_private_address` at `:389-394`).
- **Status attribution.** `trustworthy_attribution?` requires the object's host to equal the host
  of `attributedTo` (`fetch_remote_status_service.rb:61-66`). `attributedTo` is read with
  `value_or_id(first_of_value(...))`, so an array, a string or an object all work (`:29`;
  `json_ld_helper.rb:16,83`).
- **Object types.** Accepted types are `SUPPORTED_TYPES = Note Question` and
  `CONVERTED_TYPES = Image Audio Video Article Page Event` (`activity.rb:9-10`;
  `fetch_remote_status_service.rb:82-84`).
- **Actors.** An actor is fetched with a known id (`fetch_remote_actor_service.rb:16`,
  `fetch_resource(uri, true, …)`), so its `id` must equal the URI that was requested.
- **Signing account.** Fetches are signed on behalf of `Account.representative` by default
  (`json_ld_helper.rb:272-275`).

**Home-feed filtering** (`app/lib/feed_manager.rb`):
- A reply whose parent is unresolved is filtered from home feeds (`:505`).
- Self-replies are kept (`:524`).
- A child that arrived before its parent reaches feeds through `ThreadResolveWorker`'s
  re-distribution (`thread_resolve_worker.rb:21`). That is gated on the 6-hour realtime window
  (`status.rb:188,218-220`).

**Client API:**
- `POST /api/v1/statuses` takes `in_reply_to_id`: "ID of the status being replied to"
  (https://docs.joinmastodon.org/methods/statuses/).
- **Mastodon ids for remote statuses are local cache ids.** A client gets one through
  `GET /api/v2/search` with `resolve=true` and an HTTPS URL, which attempts "resolving the URL and
  returning the matching status" (https://docs.joinmastodon.org/methods/search/).
- The Status entity has `in_reply_to_id` and `in_reply_to_account_id`, both nullable strings,
  "cast from an integer but not guaranteed to be a number"
  (https://docs.joinmastodon.org/entities/Status/).
- `GET /api/v1/statuses/:id/context` returns `ancestors` and `descendants`
  (https://docs.joinmastodon.org/entities/Context/).
- A web URL `/@:account_username/:id` serves the same status as its canonical URI
  (`config/routes.rb:174`).

### Platform limits

- **API Gateway REST integration timeout:** "50 milliseconds - 29 seconds for all integration
  types, including Lambda" (Integration timeout for Regional APIs,
  https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-execution-service-limits-table.html).
- **`URLRequest.timeoutInterval` is an idle timeout:** "If during a connection attempt the request
  remains idle for longer than the timeout interval, the request is considered to have timed out"
  (https://developer.apple.com/documentation/foundation/nsurlrequest/timeoutinterval).
  A server that keeps sending bytes slowly is never cut off by it.

### What this means

`inReplyTo` set to the parent's dereferenceable URI is what threads a post on Mastodon. It is
both the only threading property Mastodon requires on intake and the property FEP-f228 names as
the primary backfill path.

A reply to someone else must also do three more things:
- put the parent author in `cc` with a `Mention` tag
- be delivered to the parent author's inbox
- respect who may see the parent

Delivery to the parent author's *followers* happens on Mastodon only when the parent is local to
the replying server. Nothing on the remote side does it for FAP.

## Current FAP behaviour

Verified by reading the code at `8a78008`.

**Create path.**
- `CreateStatusRequest.inReplyToId` decodes `in_reply_to_id`
  (`Sources/ActivityPubCore/Models/CreateStatusRequest.swift:27,38`).
- `PostHandler` copies it verbatim into `Status.inReplyTo` (`Sources/PostHandler/main.swift:310`).
  An unknown or garbage value returns 200.
- The parent's `repliesCount` is not touched.
- **The quote path** (`main.swift:249-288`):
  - It looks up `quoted_status_id` in the *caller's own* partition only (`:252`).
  - Any other value, including another local actor's URI, is treated as remote. It is fetched
    unsigned with `fetchRemoteObject` (`:264`), and its author's inbox is resolved through the
    remote-actor cache or a fetch (`:265-277`).
  - If no inbox is found, the quote is marked `failed` and the post still goes out (`:282-287`).

**Model.**
- `Status.inReplyTo` is documented as a URI (`Sources/ActivityPubCore/Models/Status.swift:47-48`,
  init doc `:79`), but holds whatever the client sent.
- `repliesCount` is documented as "replies received from remote actors" (`Status.swift:53-54`).
- `Status.tags` is `[Tag]?` (`Status.swift:44`). `Tag` has `type`, `name` and `href`, and its doc
  lists `Mention` (`Status.swift:267-273`). `PostHandler` always writes `tags: nil`
  (`main.swift:308`).

**Storage.**
- Statuses live at `PK=ACTOR#{username}`, `SK=STATUS#{ulid}`, with `GSI1PK=ACTOR#{username}` and
  `GSI1SK=PUBLISHED#…` (`Status.swift:216-221`).
- No index on `inReplyTo` or on status id alone exists.
- `getStatus` supports `consistentRead` (`Sources/ActivityPubCore/DynamoDBStore.swift:728`).
- Remote actors are cached at `REMOTE_ACTOR#{actorUri}` with a 24 h TTL (`DynamoDBStore.swift:593-630`,
  TTL at `:598-600`). The cache holds `actorUri`, `publicKeyPem`, `preferredUsername`, `inbox`,
  `sharedInbox` and `fetchedAt`, but no `followers` (`Sources/ActivityPubCore/Models/RemoteActor.swift:8-20`).
- **That cache is the trust anchor for inbound signatures.** `KeyManager.getPublicKey` returns
  `cached.publicKeyPem` when present (`Sources/ActivityPubCore/Crypto/KeyManager.swift:41-42`).

**Outbound Note.**
- `buildNoteJSON` (`Note.swift:23-109`) is the only Note builder. It emits no `inReplyTo`,
  `replies`, `context` or `conversation`.
- It already serializes `status.tags` as `{type, name, href}` (`Note.swift:62-72`).
- It has four callers:
  - delivery (`PostHandler/main.swift:325`)
  - the object endpoint (`Sources/ObjectHandler/main.swift:74`)
  - the outbox (`Sources/OutboxHandler/main.swift:80`)
  - the quote-accept `Update` (`Sources/InboxHandler/main.swift:1285`), which goes to followers only
- `Documentation.docc/FederationOverview.md:15` claims "reply metadata". That is false at
  `8a78008`.

**Addressing.** `computeAddressing` (`Note.swift:146-165`):

| visibility | `to` | `cc` |
|---|---|---|
| public | `[as:Public]` | `[followers]` |
| unlisted | `[followers]` | `[as:Public]` |
| private | `[followers]` | `[]` |

These rows match Mastodon's `to`/`cc` for a post with no mentions.

**Delivery.**
- `PostHandler` enqueues one `DeliveryJob` per distinct `sharedInboxUrl ?? inboxUrl` among the
  author's followers (`main.swift:332-352`).
- `DeliverHandler` reads the actor's key from SSM at `{SSM_KEY_PREFIX}/{username}`
  (`Sources/DeliverHandler/main.swift:52-58`).
- It signs with `HTTPSignature.sign` and POSTs (`:79-94`).
- The queue retries up to `maxReceiveCount: 3` (`activity-environment/template.yaml:87`).

**Signing and fetching.**
- `HTTPSignature.sign` always signs `(request-target) host date digest content-type`
  (`Sources/ActivityPubCore/Crypto/HTTPSignature.swift:112-133`). It is built for POST. The
  signing string comes from `buildSigningString` (`:181-190`).
- **`fetchRemoteObject`** (`Sources/ActivityPubCore/FetchRemoteObject.swift:36-58`):
  - It sends an unsigned GET with `Accept: application/activity+json` and a 10 s idle timeout.
  - It uses `URLSession.shared` with no delegate (`:45`), so it follows redirects of any scheme
    and to any address.
  - It has no body cap and doesn't check the response content type.
- `KeyManager.fetchActorDocument` is also unsigned (`KeyManager.swift:68-74`). It parses the actor
  document into a `RemoteActor` (`:89-105`).
- PostHandler caches one value per warm container, the session signing key (`PostHandler/main.swift:40-60`,
  `cachedSigningKey` at `:42`).

**Infrastructure.**
- `PostFunction` can read `activity/${Stage}/*` from SSM and has a 60 s Lambda timeout
  (`activity-app/functions/template.yaml:127,134-135`).
- `ClientApi` is an `AWS::Serverless::Api` (a REST API) with no integration timeout override
  (`functions/template.yaml:111-120`). The 29 s limit therefore applies.
- No function has a `VpcConfig`, so Lambdas reach the network directly.

**Following.** FAP actors follow no one. The following collection is always an empty stub
(`Sources/FollowingHandler/main.swift:8`).

**Object endpoint.**
- Private and direct statuses get a 404 only on the HTML branch (`ObjectHandler/main.swift:51-62`).
  The `activity+json` branch (`:74-84`) serves any visibility. FederatedActivityPublisher#270
  tracks this.
- The response carries `cache-control: public, max-age=31536000` (`:80`). CloudFront caps it at
  300 s (`cdn/template.yaml:103-109,404-409`).

**Mastodon client API.**
- `POST /api/v1/statuses` is the only status endpoint (`functions/template.yaml:145-146`;
  `operationId: createStatus`, `openapi.yaml:381-410`, responses 200/401/422).
- `buildStatusResponse` (`PostHandler/main.swift:425-451`) echoes `inReplyTo` as `in_reply_to_id`
  and has no `in_reply_to_account_id`.
- The local account id is the username (`Sources/VerifyCredentialsHandler/main.swift:131`).
- `openapi.yaml` is mirrored downstream on every push to `main` that touches it
  (`.github/workflows/sync-openapi.yml:2-5`).

**Web view.**
- The post page (`Sources/ProfileHandler/main.swift:395` onward) shows counts (`:534-537`) but no
  reply relationship.
- It is served with `max-age=31536000` (`:121-128`), and CloudFront caps `/@*` at 300 s.
- The profile page lists the 20 newest public/unlisted posts (`:80-81,300`).

**Inbound replies (InboxHandler).**
- `handleCreate` (`InboxHandler/main.swift:727-818`) drops anything that isn't a `Note` (`:747`).
  It also drops anything whose `inReplyTo` doesn't parse as a local status URI (`:756-772`,
  `parseStatusUri` at `:1114-1129`).
- It stores `REPLY#{objectUri}` under the parent owner, with `GSI1PK=REPLIES#{inReplyTo}`
  (`DynamoDBStore.swift:382-417`), and increments the parent's `repliesCount` (`:808-810`).
- Delete removes a stored reply and decrements the count (`:1053-1088`). A Delete for an object
  FAP never stored is a no-op, because `removeReply` returns nil (`:1053-1059`).
- Inbound Update of a reply looks under the *inbox owner's* partition (`:884-885`), while Create
  stores it under the *parent owner's* partition. That mismatch is pre-existing.
- The quote-accept origin check compares the scheme and host of the actor and the quoted post
  (`:1257-1265`).
- `REPLIES#` is never queried.

## Phase 1 — Self-replies

### 1.1 Shared URI parsing moves to ActivityPubCore

Move `parseStatusUri` (`InboxHandler/main.swift:1114`) into ActivityPubCore as
`parseLocalStatusUri(_:serverDomain:handleDomain:)`. Behaviour is unchanged.

InboxHandler, PostHandler, `buildNoteJSON`, `buildStatusResponse` and the post page all call it.
Add `isLocalHost(_:)` beside it: true when the URI's host is `serverDomain` or `handleDomain`.

### 1.2 Resolve and validate `in_reply_to_id`

Insert a step between visibility validation and addressing, before anything is written:

1. If `in_reply_to_id` is absent or empty, the status is not a reply.
2. Otherwise call `store.getStatus(username: <author>, id: in_reply_to_id, consistentRead: true)`.
   - Use `consistentRead: true` because the bot posts back-to-back.
   - InboxHandler already reads this way after a write (`InboxHandler/main.swift:1284`).
3. If nothing is found, return **404** `{"error":"Status to reply to not found"}` and write
   nothing, as Mastodon does. Phases 2 and 3 widen what resolves.
4. If found:
   - set `inReplyTo = parent.uri` (`PostHandler/main.swift:293`). This is byte-identical to the
     parent's Note `id` (`Note.swift:25`).
   - set the new attribute `inReplyToAccountId = parent.username` (§1.3)
5. **Cap the visibility while FederatedActivityPublisher#270 is open.**
   - Rank the visibilities `public` > `unlisted` > `private`. If the request ranks above the
     parent's visibility, downgrade the reply to the parent's visibility before
     `computeAddressing`. This follows Mastodon's quote downgrade (`post_status_service.rb:87`).
     The response's `visibility` shows the effective value.
   - The reason: a wider child would publish a narrower parent's URI, and the object endpoint's
     `activity+json` branch serves that parent regardless of visibility (`ObjectHandler/main.swift:74-84`).
   - **Once #270 is fixed, remove the cap to match Mastodon**, which never changes visibility
     because of the thread (`post_status_service.rb:85-87`). That was decided 2026-10-20.
   - The cap applies to local parents (phases 1 and 2).

Testable shape:

```swift
public enum ReplyParentResolution { case none, resolved(ReplyParent), notFound, unsupported }
public func cappedReplyVisibility(requested: String, parent: String) -> String
```

`ReplyParent` carries `uri`, `directAuthorAccountId`, `directAuthorActorUri`, `visibility`,
`isLocal`, and, for local parents, the parent `Status`.

### 1.3 Storage

New reply items store:
- `inReplyTo`: the parent URI
- `inReplyToAccountId`: a new optional `Status` attribute, written only by the resolver. For a
  local account it is the username, which is the account id FAP exposes. For a remote account it
  is the actor URI (Phase 3).

There is no index change.

**Values stored before this change are ignored.**
- A reader treats `inReplyTo` as a reply link only when it is an `https://` URI that
  `parseLocalStatusUri` accepts. §3.6 widens this rule.
- Any other value is ignored as if absent. Nothing is normalized or migrated.
- Normalizing would change object-endpoint bodies already served under a one-year cache, and
  would turn unvalidated client input (`PostHandler/main.swift:310`) into URIs.
- No legacy item has been observed. If one is, that is a follow-up issue.

### 1.4 Emit `inReplyTo` on the Note

`buildNoteJSON` emits `"inReplyTo":"<uri>"` when the §1.3 rule passes. All four callers pick it
up, and `FederationOverview.md:15` becomes accurate.

The Note body stays immutable: a parent never changes, and pre-change items never start emitting
the key.

No `context` or `conversation` (decided). Mastodon threads on `inReplyTo` alone, and puts the
child in the parent's conversation (`status.rb:449`).

### 1.5 Addressing, mentions, delivery

- A self-reply uses `computeAddressing` with its capped visibility and carries no Mention tag.
  This matches Mastodon for a self-reply with no `@` in its text.
- Fan-out is unchanged.
- Out-of-order arrival is handled on the receiving side:
  - Mastodon filters the orphan from home feeds (`feed_manager.rb:505`).
  - `ThreadResolveWorker` fetches the parent from FAP's object endpoint.
  - The worker then re-distributes the child within the 6 h window (`thread_resolve_worker.rb:21`;
    `status.rb:188,218-220`).

### 1.6 `repliesCount`

- **Gate.** Increment the parent's count only when the reply's effective visibility is public or
  unlisted. This is Mastodon's `distributable?` gate (`status.rb:484`; `visibility.rb:31-33`).
  The post page shows the count to anyone (`ProfileHandler/main.swift:536`).
- **Ordering.** Do it *after* the delivery enqueue (`PostHandler/main.swift:332-352`).
- **Failure.** Log and swallow a failure. The count is display-only, and a 5xx after a delivered
  post would make a retrying bot fork the chain.
- **Doc comment.** Update `Status.swift:53` to "replies received, local and remote, public or
  unlisted".
- **Page cache.** This changes the parent's post page body, which is served with a one-year
  header (`ProfileHandler/main.swift:121-128`).
  - That is pre-existing: inbound likes, boosts, quotes and replies already do it.
  - The page's real freshness has always been CloudFront's 300 s cap.
  - Fixing that header is separate from this work.

### 1.7 Client API

- Move `buildStatusResponse` into ActivityPubCore.
- `in_reply_to_id` is the parent id from `parseLocalStatusUri(inReplyTo)`.
- `in_reply_to_account_id` is the stored `inReplyToAccountId`.
- Both are `null` when the §1.3 rule fails.
- **`openapi.yaml`:**
  - Add `in_reply_to_account_id` to `Status` as **optional, nullable**, not in `required:`.
  - Update the `in_reply_to_id` description.
  - Add a `"404"` response to `createStatus`.
- **Optional first.** The schema mirrors downstream on merge, but servers emit the field only
  after their next release.
  - Promote the field to `required` once every deployed server emits it.
  - The implementation PR builds the `integration-tests` `APIClient` and the mirrored client
    against the branch before merge (review standards S11/S12).
- **Release notes:** an unknown or non-owned `in_reply_to_id` now returns 404 instead of 200,
  and a reply's visibility is capped at its local parent's while #270 is open.

### 1.8 Web view

- **Post page.** When the §1.3 rule passes, the post page shows "In reply to" linking to
  `https://{serverDomain}/@{username}/{parentId}`.
- **Profile page.** Unchanged. Each post is listed separately, as today (decided).
- **Descendant links on the parent page.** These are out of scope. They need a parent→children
  query, and no `inReplyTo` index exists. That is the same work as the deferred `replies`
  collection.

### Phase 1 components

None.
- Two functions move into ActivityPubCore.
- A resolver and a cap function are added.
- One optional attribute is added.
- No handler, route, table, index, queue or workflow is added.
- The work stays in one repository.

## Phase 2 — Replies to other local actors

### 2.1 What `in_reply_to_id` means

**"Local" is defined by host.** A URI is local when `isLocalHost` holds, meaning its host is
`serverDomain` or `handleDomain`.

**The resolver gains one branch after the phase 1 bare-id lookup:**
1. If `in_reply_to_id` is a local-host `https://` URI and `parseLocalStatusUri` accepts it, call
   `getStatus(owner, id, consistentRead: true)`.
2. If it is a local-host URI that isn't a status URI, return 404. It never takes phase 3's remote
   branch.
3. A bare id still resolves only within the caller's own partition, as in phase 1.

**Why a URI.**
- A client can't learn another local actor's status id from FAP's API. FAP serves no status
  reads, and the create response returns only the caller's own ids.
- Clients meet such statuses by URI or URL, through federation or the web.
- No id→owner index is added.

The quote path is *not* a precedent for this branch. It looks only in the caller's partition and
sends every other value, including another local actor's URI, down the remote fetch
(`PostHandler/main.swift:252-264`).

**Who may reply. This rule is Mastodon's `show?`, and it stays after #270 is fixed.**
- A parent that is `private` and not owned by the posting actor resolves to `notFound`, and the
  request gets a **404**.
- The Mastodon receipt: `set_thread` authorizes `show?`, then 404 (`statuses_controller.rb:106-111`).
  For a private status `show?` is `owned? || following_author? || mention_exists?`
  (`status_policy.rb:9-10`).
- Neither of the other two conditions can hold in FAP:
  - FAP actors follow no one (`FollowingHandler/main.swift:8`).
  - FAP never records a Mention *of* a peer into the parent.
- So only public and unlisted parents of other local actors resolve.

**Response.**
- `in_reply_to_id` for a parent the caller doesn't own is the parent's **URI**, not its bare id.
  The URI is the only form the caller can post back.
- `in_reply_to_account_id` is the parent owner's username (§2.2).
- Open Question 1 covers URI-valued ids.

### 2.2 `in_reply_to_account_id` and carry-over

Implement Mastodon's `carried_over_reply_to_account_id` (`status.rb:461-466`):
- If `parent.username == author` *and* the parent has `inReplyToAccountId`, carry the parent's
  value over.
- Otherwise use the parent's author.

The carried-over account, *R*, drives the Mention, `cc` and direct delivery. It never drives the
followers union (§2.3).

In phase 1 the result is always the author, so the rule changes nothing there.

### 2.3 Addressing, Mention, delivery

Two accounts matter here:
- *P* is the direct parent's author.
- *R* is the carried-over account. It is used only when it isn't the posting actor.

- **Mention.**
  - Add `Tag(type: "Mention", name: "@{R}@{handleDomain}", href: "https://{serverDomain}/users/{R}")`
    to `status.tags`. `buildNoteJSON` already serializes tags (`Note.swift:62-72`).
  - Mastodon resolves mentions by `href` (`create.rb:255-263`).
  - **This is FAP's choice, not Mastodon's behaviour.** Mastodon never mentions automatically
    (`process_mentions_service.rb:25-26`). Its clients usually put `@user` in the text. Open
    Question 5 covers the case where *R* is carried over.
- **`cc`.** Append *R*'s actor URI for public, unlisted and private. This is Mastodon's `cc` rule
  for mentioned accounts (`tag_manager.rb:215,228`).
- **Direct delivery to *R*.** *R* is local, so no HTTP delivery is made. FAP has no notifications
  or home timeline to deliver into.
- **Followers union.** This applies only to a distributable (public or unlisted) reply whose
  *direct* parent is local and by another actor.
  - Fan out to the posting actor's followers ∪ *P*'s followers, deduplicated by shared inbox.
  - This is Mastodon's `@status.thread.account.followers` (`status_reach_finder.rb:105-106`;
    `status.rb:210-212`).
  - A self-reply that carries *R* over unions nothing, because *P* is the poster.
  - It costs one extra `listAllFollowers(username:)` call.
- **`repliesCount`.** Increment it on *P*'s partition, with the same `distributable?` gate,
  ordering and swallow rule as §1.6.
- **Visibility cap.** It applies as in §1.2 step 5. Because private parents of others don't
  resolve, the cap only ever lowers a public request to unlisted.

### 2.4 Interaction with InboxHandler

- The local reply never passes through InboxHandler, so no `REPLY#` item is written and the
  parent count is incremented once, directly.
- FAP actors follow no one, so no follower inbox in the fan-out is a FAP inbox. A local reply
  can't loop back as an inbound `Create`.
- Remote replies *to* the local reply are inbound replies to a local status, so the existing
  `handleCreate` handles them unchanged.
- The pre-existing Update partition mismatch (`InboxHandler/main.swift:884-885`) isn't made worse:
  local replies aren't `REPLY#` items. It is recorded here and not fixed.

### 2.5 Client API and web

- The `openapi.yaml` description of `in_reply_to_id` says it accepts "a status id, or the https
  URI of a status".
- The post page's "In reply to" links to *P*'s post page.

### Phase 2 components

None.
- The resolver gains the local-URI branch, the `show?` rule and carry-over.
- The fan-out gains a union with the direct parent's followers.
- Mention tags use the existing `tags` field.

## Phase 3 — Replies to remote statuses

### 3.1 What `in_reply_to_id` means for a remote parent

- On Mastodon, a client gets a remote status's id by resolving its URL through
  `GET /api/v2/search?resolve=true`. That id is a key into Mastodon's own cache of remote
  statuses.
- FAP has neither search nor a remote-status cache. Phase 3 therefore accepts the remote status's
  `https://` URI, or its web URL, in `in_reply_to_id`, when its host is not local.
- In responses, a reply to a remote parent reports:
  - `in_reply_to_id`: the **canonical fetched `id`** (§3.3 step 2)
  - `in_reply_to_account_id`: the remote author's actor URI, which is the key FAP's remote-actor
    cache uses
- Both are strings, as the Status entity allows (Open Question 1).

### 3.2 Hardening and signing the shared fetch

All controls go into `fetchRemoteObject` itself, as one mechanism. The quote path's fetches
(`PostHandler/main.swift:264,272`) are hardened by the same change.

| Control | Requirement | Mastodon reference |
|---|---|---|
| Scheme | `https` on the initial URI and on every redirect hop | Stricter than Mastodon, whose `unsupported_uri_scheme?` also allows `http` (`json_ld_helper.rb:95-97`) |
| Redirects | At most 3 hops, each re-signed for its own path and host | `request.rb:101-102,72-75` |
| Address | Resolve the host and reject loopback, private (RFC 1918 / ULA), link-local and unspecified addresses, on every connection including each hop. The check must apply to the address actually connected to. | `request.rb:325-334,389-394` |
| Body | 1 MB cap. Abort the read past it. | `request.rb:293-294` |
| Content type | Accept only `application/activity+json`, or `application/ld+json` with the ActivityStreams profile | `json_ld_helper.rb:281,351` onward |
| Status | Only 200 is a success | `json_ld_helper.rb:281` |
| Deadline | The caller passes an absolute deadline. The fetch fails when the deadline passes, whether or not bytes are still arriving. | (§3.3) |

**Signing.**
- Add `HTTPSignature.signGet(privateKeyPem:keyId:pathAndQuery:host:)`, which signs
  `(request-target) host date`.
  - `(request-target)` is `get {path}{?query}`, query string included, matching Mastodon's
    `original_fullpath` check (`signed_request.rb:113`).
  - It reuses `buildSigningString` (`HTTPSignature.swift:181-190`), and satisfies
    `verify_signature_strength!` (`signed_request.rb:54-57`).
- `fetchRemoteObject` takes an optional signer and signs every hop. Without a signer, the
  hardening still applies and nothing is signed.
- PostHandler signs as the **posting actor**, with keyId `https://{serverDomain}/users/{u}#main-key`.
  - It reads the key from `{SSM_KEY_PREFIX}/{u}` (as `DeliverHandler` does, `main.swift:52-58`).
  - It caches keys in a per-container dictionary keyed by username. The existing cache at
    `PostHandler/main.swift:42` holds a single value.
  - `PostFunction` already has the SSM permission (`functions/template.yaml:134-135`).
  - Mastodon accepts any verifying account key (`signature_verification.rb:45` onward), so FAP's
    lack of an instance actor doesn't block verification.

**The HTTP client is not decided.** `URLSession` doesn't expose the connected address. Which
client can enforce the address control is listed under Unverified, and it is an implementation-plan
decision. If it means a new package dependency, the plan must name it.

### 3.3 Resolving the remote parent

Resolution runs under one **overall deadline of 10 s**, measured from the start of resolution.
That leaves headroom under API Gateway's 29 s integration timeout for the write, the fan-out
enqueue and the response. If the deadline passes, the request gets a **404** and *nothing has been
written*, because resolution finishes before `storeStatus`.

If `in_reply_to_id` is an `https://` URI with a non-local host:

1. **Fetch the object** signed, through §3.2. Any failure gives a 404: a fetch error, a non-200,
   the wrong content type, an oversize body, invalid JSON, or a `Tombstone`.
2. **Canonicalize the id.**
   - Take `json['id']`. If it differs from the requested URI, for example a pasted
     `/@user/id` web URL (`config/routes.rb:174`), re-fetch that `id` and require
     `json['id'] == id`. This is `fetch_resource` (`json_ld_helper.rb:242-252`).
   - Use the canonical `id` from here on.
3. **Validate the object.**
   - `type` must be one of Mastodon's supported or converted types: `Note`, `Question`, `Image`,
     `Audio`, `Video`, `Article`, `Page`, `Event` (`activity.rb:9-10`).
   - `attributedTo` is read as Mastodon reads it: the first element if it is an array, and the
     `id` if it is an object (`first_of_value`/`value_or_id`, `json_ld_helper.rb:16,83`).
   - The host of `attributedTo` must equal the host of `id`, compared case-insensitively
     (`trustworthy_attribution?`, `fetch_remote_status_service.rb:61-66`).
   - Any failure gives a 404.
4. **Fetch the author's actor document** signed, through §3.2.
   - Require `json['id'] == attributedTo`, the URI that was requested, as Mastodon's known-id
     actor fetch does (`fetch_remote_actor_service.rb:16`; `json_ld_helper.rb:251-252`).
   - Parse it with the same function `KeyManager.fetchActorDocument` uses (`KeyManager.swift:89-105`).
     Extract that function and add `followers` to what it returns.
   - Any failure gives a 404.
5. **Write the cache from this validated fetch.** Write `REMOTE_ACTOR#{attributedTo}` keyed by
   the fetched URI only *after* the `id` check passes.
   - It replaces any cached entry with a document the actor's own origin just served. That is the
     same trust basis `KeyManager` uses today.
   - Nothing else in this phase writes that cache.
6. **Derive the parent's visibility** with Mastodon's rule (`status_parser.rb:101-111`).
   - Read `to` and `cc` as arrays *or* single strings.
   - Recognise all three public spellings (`tag_manager.rb:14-15`).
   - Compare against the actor's `followers`.
   - A **direct** parent gets a **422** `{"error":"Replying to a direct message is not supported"}`,
     because FAP can't address a direct reply (`PostHandler/main.swift:194`).
   - Public, unlisted and private parents are accepted. A private parent was fetchable, so the
     remote server's own access rules allowed it.
   - There is no visibility cap for remote parents: #270 concerns FAP's object endpoint.
7. **Set the parent fields.** Set `inReplyTo` to the canonical `id`, and `inReplyToAccountId` to
   the author's actor URI. Carry-over (§2.2) can't apply here, because a remote parent is never by
   the posting actor.

There is no remote-status cache. The reply stores the canonical URI, the author id and the Mention
tag.

### 3.4 Addressing, Mention, delivery

*R* is the account in `inReplyToAccountId`, when it is a remote actor URI. That is either the
direct remote author, or one carried over by a later self-reply.

- **Mention.**
  - Add `Tag(type: "Mention", name: "@{preferredUsername}@{actor host}", href: <actor URI>)`.
  - Mastodon resolves the mention by `href` (`create.rb:255-263`). The `name` is a display form,
    not a WebFinger-verified acct.
  - Auto-mentioning is FAP's choice (§2.3, Open Question 5).
- **`cc`.** Append *R*'s actor URI for public, unlisted and private (`tag_manager.rb:215,228`).
- **Direct delivery.**
  - Add one `DeliveryJob` to *R*'s `sharedInbox ?? inbox`, deduplicated against the followers'
    shared inboxes as `PostHandler/main.swift:338` coalesces.
  - It goes through the existing queue and `DeliverHandler`.
  - For a distributable reply this matches Mastodon's `replied_to_account_id` (`status_reach_finder.rb:47-48`).
- **Where *R*'s inbox comes from.**
  - On the direct reply, it comes from the actor document fetched in §3.3 step 4.
  - On a later self-reply that carries *R* over, FAP has only *R*'s actor URI. FAP re-fetches it
    signed through the same validated path: §3.2, plus the `id == URI` check from §3.3 step 4.
    That fetch runs under the same 10 s resolution deadline, and a failure gives a 404.
  - That re-fetch writes the `REMOTE_ACTOR#` cache entry, as in §3.3 step 5. The cache is never
    read for *R*'s inbox. An expired or absent entry therefore changes nothing.
- **Followers union.** None for a remote parent, as in Mastodon (`status_reach_finder.rb:105-106`
  applies only to local authors).
- **Known limitation: reach to *R*'s followers.**
  - *R*'s server doesn't forward FAP's reply. Mastodon's `forward_for_reply` needs a Linked Data
    Signature (`create.rb:491-495`), and FAP emits none.
  - AP §7.1.2 isn't triggered either, because the reply addresses *R*'s actor and no collection
    *R*'s server owns.
  - So *R*'s followers who don't follow the FAP actor won't get the reply in their home feeds. They
    see it only in the parent's thread view on *R*'s server, once *R*'s server has stored it.
  - This reach is narrower than a Mastodon-to-Mastodon reply's (Open Question 4).
- **`repliesCount`.** There is no local parent to update.

### 3.5 When the remote parent is deleted or unreachable

- **At create time:** fail closed with a 404 (§3.3). No reply is stored or delivered. The
  alternative is Open Question 3.
- **After create:** nothing changes on FAP's side.
  - The reply's Note stays immutable and keeps pointing at the parent URI.
  - A receiving server that can't resolve the parent filters the reply from home feeds
    (`feed_manager.rb:505`).
  - A Delete for the remote parent that reaches FAP's inbox is a no-op, because FAP stored no copy
    (`InboxHandler/main.swift:1053-1059`).

### 3.6 Reading the stored reply

- The §1.3 rule widens: emit `inReplyTo` when it is a local status URI, **or** when it is an
  `https://` URI and the item carries `inReplyToAccountId`.
- Only the resolver writes `inReplyToAccountId`, so an unvalidated pre-change URI never qualifies.
- The post page's "In reply to" links to the remote URI.

### 3.7 Interaction with InboxHandler

- `handleCreate` keeps dropping inbound Notes whose `inReplyTo` isn't local (`:756-772`). That
  includes other people's replies to the same remote parent. This phase stores only FAP's own
  outgoing reply.
- When *R* replies to FAP's reply, the existing `handleCreate` stores it, because FAP's reply is a
  local status. The count on FAP's reply is incremented there.
- **Delete and Update don't reach *R*.** FAP has no status-delete or status-edit endpoint today.
  The only outbound Update is the quote-accept re-federation, and it goes to followers only
  (`InboxHandler/main.swift:1284` onward). Once FAP can delete or edit a reply, the activity must
  also go to *R*'s inbox. That is a follow-up (Open Question 6).

### Phase 3 components

**One extended mechanism.** It is the shared `fetchRemoteObject`, which gains the hardening in
§3.2, an optional signer and a deadline. `HTTPSignature` gains `signGet`.

Supporting pieces:
- the actor-document parse is extracted from `KeyManager` and shared
- a per-actor key dictionary is added in PostHandler
- the `REMOTE_ACTOR#` cache gains one more writer, only after validation

**Re-checked against the design invariants (smallest mechanism, one job per component, blast
radius):**
- **Smallest mechanism.** Two candidates were rejected as larger:
  - a remote-status cache with local ids and a search endpoint (a new route, handler and table
    use)
  - an asynchronous resolver worker (a new queue consumer)
- **The hardening is placed so that both callers get it.** It lives in the shared function, not in
  a reply-only copy, so the quote path is fixed too.
- **One job.** Resolving the parent is part of validating the create request. That is
  PostHandler's job, and it does the same for quotes. Delivery stays in `DeliverHandler`.
- **Blast radius.** No new handler, route, table, index, queue or workflow. The work stays in one
  repository.

## Testing

Every test includes a negative control, and each must be seen going red with its capability
removed before it counts.

### Unit (`Tests/ActivityPubCoreTests`, Swift Testing)

**Phase 1**
- **`buildNoteJSON` emits `inReplyTo`.**
  - A local URI produces the key.
  - Negative controls: `nil`, a bare id, and a remote URI without `inReplyToAccountId` produce no
    key.
- **`parseLocalStatusUri` and `isLocalHost`** accept both domains.
  - Negative control: they reject a remote host, a wrong path, and too few segments.
- **The resolver.**
  - It returns `none`, `resolved` or `notFound`.
  - Negative control: a lookup returning nil gives `notFound`.
- **`cappedReplyVisibility`** covers all nine pairs.
  - Negative control: `public` under `private` gives `private`.
- **`buildStatusResponse`.**
  - A reply returns the id and account id.
  - Negative control: a non-reply, or a bare-id `inReplyTo`, gives `null`.

**Phase 2**
- **The local-URI branch** resolves another actor's public or unlisted status.
  - Negative controls:
    - Another actor's **private** status gives `notFound`.
    - A local-host non-status URI gives `notFound` and makes no fetch.
    - A remote URI misses in phase 2.
- **Carry-over.**
  - A self-reply to a reply to *R* yields *R*.
  - A self-reply to a non-reply yields the author.
  - Negative control: a reply to someone else's reply yields that someone, not the grandparent.
- **Followers union.**
  - A distributable reply to *P*'s post unions *P*'s followers.
  - Negative controls:
    - A self-reply that carries *R* over unions **nothing**, not *R*'s followers.
    - A private reply unions nothing.
- **Mention tag and `cc`.**
  - They contain *R*.
  - Negative control: a plain self-thread has no Mention and an unchanged `cc`.

**Phase 3**
- **`signGet`.**
  - The signing string is exactly `(request-target): get {path}?{query}\nhost: …\ndate: …`, and
    it verifies with `HTTPSignature.verify`.
  - Negative controls:
    - Dropping the query string from the signed path fails verification against the full path.
    - A tampered path fails verification.
- **Fetch hardening**, each control against a local test server:
  - Redirect hops: 3 succeed, and a 4th fails.
  - An `https`→`http` redirect fails.
  - A redirect to `127.0.0.1`, `169.254.169.254` or `10.0.0.1` fails.
  - A body over 1 MB fails.
  - A `text/html` response fails.
  - A slow-drip response fails at the deadline even though bytes keep arriving.
  - Negative control: a compliant response succeeds.
- **Remote validation**, run on fixtures:
  - An `id` mismatch after re-fetch, an `attributedTo` host mismatch, a `Tombstone`, an
    unsupported type, and an actor document whose `id` ≠ `attributedTo` each give `notFound`.
  - Array and object `attributedTo` are parsed.
  - A web-URL input yields the canonical `id`.
  - Negative control: a valid `Page` resolves.
- **Visibility derivation** gives the four outcomes, accepts all three public spellings, and
  accepts string-valued `to`/`cc`.
  - Negative control: a parent addressed only to a person is `direct`, and the request gets a 422.
- **Cache write.**
  - It happens only after the actor `id` check.
  - Negative control: a mismatched actor document leaves the cache unchanged.

### Schema conformance (`integration-tests/Tests/IntegrationTests/SchemaConformanceTests.swift`)

Commit two fixtures next to `Fixtures/outbox-page.json`, and decode both through
`Components.Schemas.Status`:
- `status-reply.json`, which includes `in_reply_to_account_id`
- `status-legacy.json`, which lacks it

Negative control: temporarily mark the field `required:` and confirm that `status-legacy.json`
fails to decode.

### Integration (`integration-tests/`, on stage, generated `APIClient`)

These tests drive `client.createStatus` so responses decode through the generated types. They use
the `TEST_CLIENT_API_URL` / `TEST_BEARER_TOKEN` variables from `DualAuthTests.swift`, and posts
are `unlisted`.

**Phase 1**
- **Round trip.** Post a root, then a reply. The reply has the root's id and account id, and
  `GET <reply.uri>` (`activity+json`) has `inReplyTo == root.uri`.
  - Negative control: the root has no `inReplyTo`.
- **Unknown parent** gets `.notFound`.
  - Negative control: the same body without `in_reply_to_id` gets `.ok`.
- **Visibility cap.** A `private` root plus a `public` reply gives `visibility == private`.
  - Negative control: `unlisted` under `unlisted` stays `unlisted`.
- **Chain of three.** Each child points at the previous post.

**Phase 2** (needs a second stage actor and token)
- A reply by A to B's `unlisted` status, given by URI, returns:
  - `in_reply_to_id` equal to B's status URI
  - `in_reply_to_account_id == B`
  - a Mention tag for B, and B in `cc`
  - B's `repliesCount` + 1
- Negative controls:
  - A's reply to B's **private** status gets `.notFound`.
  - A `private` reply leaves the count unchanged.

**Phase 3**
- A reply to a remote public status on a test instance, given by URI, returns
  `in_reply_to_id == <canonical id>` and a Note whose `cc` and Mention contain the remote actor.
- Negative control: a URI on the same instance that returns 404 gives `.notFound`.

### Federation (manual, against stage)

- **BrowserPub** (https://browse.activitypub.dev).
  - Load the last reply. It renders "in reply to" its parent and walks up to the root.
  - BrowserPub doesn't cache failures, so it is the first check.
- **Mastodon, phases 1 and 2.**
  - Use an instance account that follows the stage actor. Acceptance:
    `GET /api/v1/statuses/:id/context` for the last post lists the others as `ancestors`, in order.
  - The home timeline is not the criterion.
  - Out-of-order case: run it if delivery order can be forced.
- **Mastodon, phase 3.** Reply from the stage actor to a post by a test account on a Mastodon
  instance. Acceptance has three parts:
  - The test account receives a mention notification.
  - On that instance, `/context` of the parent lists FAP's reply among the `descendants`.
  - Run it against an instance with secure mode on as well.
  - Negative control: with signing disabled, the secure-mode instance refuses the fetch and FAP
    returns 404.
  - Also record that a follower of the test account who doesn't follow the stage actor gets no
    home-feed entry. That observes the §3.4 limitation directly.
- **Mastodon caching.** Mastodon caches discovery failures for hours, so retry on another
  instance before debugging FAP.
- **Before/after control.** Run each procedure against the pre-change build and record that
  `/context` shows no relationship.

### Build gate

- Build every target for Linux with `swift package archive --allow-network-connections docker`.
  The deployed binary is the Linux build, and a macOS `swift build` doesn't catch Linux-only
  compile errors.
- Build the generated consumers against the branch's `openapi.yaml`.

## Unverified

- **The HTTP client for the address control.** No client has been chosen that can check the
  connected address on every connection, including each redirect hop. `URLSession` and
  FoundationNetworking expose no hook for this. Whether a client already in the resolved
  dependency graph can do it is unverified, because `Package.resolved` is not committed. The
  phase 3 plan must pick the client and name any new dependency.
- **Mastodon's `items_context_url` path shape.** Only the helper name is verified
  (`tag_manager.rb:101-108`).
- **Mastodon reading `context` on intake.** No read was found in `create.rb`. That doesn't prove
  Mastodon never reads it.
- **Mastodon's web composer on self-replies.** Whether it omits the author's own `@handle` is
  unverified. Only the server-side mention scan was read.
- **The `replies_count` "added" version.** The docs page showed 4.5.0, which conflicts with the
  field's history. This spec relies on `status.rb:484`, not on the version.
- **Forcing out-of-order delivery** for the manual check. No mechanism has been identified.
- **A secure-mode instance accepting a regular actor's key, in practice.** The source reading is
  done: `signature_verification.rb:45` onward accepts any verifying account, and nothing requires
  an instance actor. A live measurement is still pending, and the phase 3 secure-mode federation
  check is that measurement.

## Decisions (2026-10-20)

Erin decided the following on 2026-10-20.

1. **Scope: all replies.** That covers self-replies, other local actors and remote statuses,
   shipped as phases 1–3 in this document, each shippable on its own.
2. **`replies` collection:** a follow-up. It isn't part of any phase here.
3. **`context` / `conversation`:** not now. Revisit when a context FEP reaches FINAL.
4. **Profile page:** posts stay listed separately, as today, and each post page gets an "In reply
   to" link (§1.8).
5. **Server-side length check:** tracked separately in FederatedActivityPublisher#272. It is not
   part of this spec.
6. **Visibility cap:** it applies to local parents while FederatedActivityPublisher#270 is open,
   and is lifted once #270 is fixed, to match Mastodon (§1.2 step 5).

## Open questions

These are new questions raised by phases 2 and 3.

1. **URI-valued ids in the client API.**
   - Phases 2 and 3 accept an https URI in `in_reply_to_id`.
   - For a parent the caller doesn't own, the response returns a URI as `in_reply_to_id`: the
     local status URI in phase 2, the canonical remote id in phase 3. Phase 3 also returns the
     actor URI as `in_reply_to_account_id`.
   - The Mastodon entity allows non-numeric strings, but a client can't look these up through
     `GET /api/v1/statuses/:id` or `/accounts/:id`. FAP serves neither endpoint today.
   - The alternative is FAP-local ids for other actors' and remote statuses, plus
     `GET /api/v2/search?resolve=true`. That is a new route and handler, and a cache.
   - Proposed: URI-valued ids.
2. **Visible mention text.**
   - FAP adds the Mention tag and `cc` server-side, and leaves the text alone. FAP has no
     `@mention` parser (`TextToHTML.swift`).
   - Should replies to others also get a linked `@user@domain` prepended to the content?
   - Proposed: keep the text as sent, and treat mention parsing as its own feature.
3. **Unreachable remote parent.**
   - Phase 3 fails closed: on a fetch failure or a deadline overrun, the request gets a 404 and
     nothing is posted.
   - The quote path posts anyway and marks the quote `failed` (`PostHandler/main.swift:282-287`).
   - Should a reply whose parent can't be fetched still post, with `inReplyTo` but no Mention and
     no delivery to the author?
   - Proposed: fail closed, which matches Mastodon's 404 for a parent it can't resolve.
4. **Reach to the remote author's followers.**
   - Without Linked Data Signatures, Mastodon never forwards FAP's reply to *R*'s followers
     (`create.rb:491-495`), so FAP's reach is narrower than a Mastodon reply's (§3.4).
   - Is that acceptable for phase 3, with LD signing (`RsaSignature2017` on outbound activities) as
     a separate follow-up?
   - Proposed: accept it for phase 3, and file LD signing as a follow-up.
5. **Mention on a carried-over self-reply.**
   - When an actor continues a conversation with *R* through a self-reply, FAP Mentions and `cc`s
     *R* and delivers to *R*, even when the reply is private.
   - Mastodon would reach *R* only for a distributable reply (`status_reach_finder.rb:47-48`), and
     would Mention *R* only if the text did.
   - Should FAP keep auto-mentioning *R* on carried-over self-replies, or Mention only the direct
     parent's author and leave carried-over delivery to the distributable rule?
   - Proposed: Mention only on direct replies to *R*. A carried-over self-reply then gets *R* in
     `cc` and direct delivery when distributable, and no Mention, which matches Mastodon's reach
     without the notification.
6. **Delete and Update reaching *R*.**
   - FAP can't delete or edit statuses today, but when it can, a Delete or Update of a reply must
     also be delivered to *R*'s inbox. The quote-accept `Update` already goes only to followers
     (`InboxHandler/main.swift:1284` onward).
   - Should that requirement be recorded now as a follow-up issue against the future delete/edit
     work?
   - Proposed: yes, file it as a follow-up when this spec merges.
