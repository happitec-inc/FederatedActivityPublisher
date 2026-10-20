# Reply Threading — Design Spec

## Goal

Let a local actor publish a reply to any status it can see: its own, another local actor's, or a
remote one. Each reply federates with a correct `inReplyTo`, reaches the parent's author, and is
reported through the Mastodon-compatible client API with Mastodon-style ids.

The motivating case is a bot that posts a long daily summary. When the summary exceeds the
5,000-character status limit, the bot splits it into a root post and a chain of self-replies.

Today FAP accepts `in_reply_to_id` on create but never federates it, so a "thread" arrives at
remote servers as N unrelated posts.

## Phases

The work ships in three phases. Each phase can be shipped and released on its own. Phase 1 has no
dependencies, phase 2 needs phase 1, and phase 3 needs phase 2.

| Phase | Parent | Unblocks | New components (full list in each phase's "Components") |
|---|---|---|---|
| 1 | The posting actor's own status | The motivating bot thread | None |
| 2 | Another local actor's public or unlisted status | Conversations between actors on one server | `SearchHandler` Lambda; `GET /api/v2/search` route and CloudFront behaviour; `REF#` item type |
| 3 | A remote status | Replying into the wider fediverse | Remote resolve in `SearchHandler`; remote `REF#` cache entries; fetch hardening and signing; actor-URI delivery in `DeliverHandler`; Linked Data Signatures with a JSON-LD/RDF canonicalization dependency |

**Out of scope for all phases (decided, see "Decisions"):**
- A `replies` collection.
- `context` / `conversation`.
- `GET /api/v1/statuses/:id` and `/context`.
- A thread view on the web.
- General mention parsing from status text.
- `direct` visibility. It is still rejected (`Sources/PostHandler/main.swift:194`).
- Server-side length enforcement, which is tracked separately in FederatedActivityPublisher#272.
- Rewriting `inReplyTo` values stored before this change (§1.3).

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

- **ActivityPub defines no `replies` side effect.** §3 (Objects) and §5 (Collections) never define
  a replies collection. FEP-7458 says the same: "Replies are not defined in ActivityPub, as there
  are no specified side effects for simply *encountering* objects or activities with `inReplyTo`
  set."
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

  A FAP reply addresses the parent author's *actor*, not a collection that author's server owns,
  so §7.1.2 doesn't trigger forwarding. Mastodon forwards on its own, stricter rule (see "How
  Mastodon forwards").
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
- Mentions: "Mastodon requires Mention tags in order to generate a notification. (The mentioned
  actor must still be included within to or cc explicitly in order to receive the post.)"

**Security docs** (https://docs.joinmastodon.org/spec/security/):
- "When secure mode is enabled, all GET requests require HTTP signatures as well."
- For a GET, "Typically, you will want to include the request target, as well as the host and the
  date."
- Receivers "check that the signed request was made within the past 12 hours".

**Signature verifier** (`app/lib/signed_request.rb`,
`app/controllers/concerns/signature_verification.rb`, `app/controllers/statuses_controller.rb`):
- On a GET, `verify_signature_strength!` (`signed_request.rb:54-57`) requires:
  - `date` or `(created)`
  - `(request-target)` or `digest`
  - `host`
- `(request-target)` is compared against `original_fullpath`, which includes the query string
  (`signed_request.rb:113`).
- Secure mode requires a signature on status JSON (`statuses_controller.rb:11`).
- `signed_request_account` (`signature_verification.rb:45` onward) accepts any account whose key
  verifies.

**What Mastodon emits** (`app/serializers/activitypub/note_serializer.rb`,
`app/lib/activitypub/tag_manager.rb`, `app/lib/text_formatter.rb`):
- `inReplyTo` is the parent's URI (`note_serializer.rb:99-107`).
- Mention tags are `{type: "Mention", href: <account URI>, name: "@acct"}` (`note_serializer.rb:333`
  onward).
- **`to`** (`tag_manager.rb:171-196`): public is `[as:Public]`; unlisted and private are
  `[author followers]`.
- **`cc`** (`tag_manager.rb:203-235`): public adds followers, unlisted adds `as:Public`, and every
  mentioned account is appended for every visibility except direct and limited (`:215,228`).
- All three public spellings are recognised: the full IRI, `as:Public` and `Public`
  (`tag_manager.rb:14-15`).
- Mentions come only from the status text (`app/services/process_mentions_service.rb:25-26`).
- **Mention HTML.** `link_to_mention` (`text_formatter.rb:80-87`) renders a mention as:

  ```html
  <span class="h-card" translate="no"><a href="{account url}" class="u-url mention">@<span>{display}</span></a></span>
  ```

  - `{account url}` is `TagManager#url_for(account)`, the profile URL.
  - `{display}` is the username, or `pretty_acct` (`user@domain`) when `with_domain` is set.

**Who Mastodon delivers to** (`app/lib/status_reach_finder.rb`, `app/workers/activitypub/distribution_worker.rb`,
`app/services/remove_status_service.rb`):
- **Inboxes** are reached accounts, plus followers, plus relays (`status_reach_finder.rb:12-13`).
- **Reached accounts** include `replied_to_account_id` (`:31`), mentioned accounts (`:34`) and
  `replies_account_ids` (`:38`). The last is the accounts that replied to the status (`:79-81`).
- **The replied-to account** is reached for a distributable reply even without a mention:
  `@status.in_reply_to_account_id if distributable?` (`:47-48`).
- **The direct parent's followers** are reached too when that parent's author is local:
  `if @status.in_reply_to_local_account? && distributable?` → `…@status.thread.account.followers…`
  (`:105-106`; `status.rb:210-212`).
- **Create and Update** are both distributed with `StatusReachFinder` (`distribution_worker.rb:22-23`;
  `StatusUpdateDistributionWorker` subclasses it, `status_update_distribution_worker.rb:3`).
- **Delete** uses `StatusReachFinder.new(@status, unsafe: true)` (`remove_status_service.rb:92-106`).
  So a Mastodon server delivers the Delete *and* Update of a status to every account that replied
  to it.

**How Mastodon forwards** (`app/lib/activitypub/activity/create.rb`,
`app/services/activitypub/process_activity_service.rb`, `app/helpers/json_ld_helper.rb`):
- **The forwarding condition.** `forward_for_reply` runs only when
  `@status.distributable? && @json['signature'].present? && reply_to_local?`
  (`create.rb:491-495`). It re-sends the raw JSON to the replied-to account's followers.
- **Signature on receipt.** `@json = compact(@json) if @json['signature'].is_a?(Hash)`
  (`process_activity_service.rb:24`).
  - When the document arrives directly from its author, the LD signature is not verified, but it
    is kept only if `safe_for_forwarding?(original_json, @json)` holds after `patch_for_forwarding!`
    (`:59-66`).
  - `safe_for_forwarding?` (`json_ld_helper.rb:220` onward) requires every original key to survive
    compaction with the same class and value. Exceptions: `@context` and `signature`, single-item
    arrays and the public IRI, which `patch_for_forwarding!` (`:184` onward) restores.
- **Compaction context.** Compaction uses Mastodon's `full_context` (`json_ld_helper.rb:125-129`;
  `app/helpers/context_helper.rb:75-76`).
  - A term that FAP's `@context` maps to a *different* IRI than Mastodon's context compacts to a
    different key.
  - A term FAP leaves undefined is dropped.
  - Either way the signature is stripped and nothing is forwarded.
- **Verification by forward recipients.** A server receiving the forwarded copy sees a different
  actor and verifies the LD signature (`process_activity_service.rb:36-48,89-94`).

**Linked Data Signature** (`app/lib/activitypub/linked_data_signature.rb`, `json_ld_helper.rb`):
- `sign!` (`:39-62`):
  - **Options.** `options = {type: "RsaSignature2017", creator: <keyId>, created: <now ISO 8601>,
    expires: <now + 2 days>}`.
  - **Options hash.** `options_hash = SHA256hex(canonicalize(options − type − id − signatureValue
    + {"@context": "https://w3id.org/identity/v1"}))`.
  - **Document hash.** `document_hash = SHA256hex(canonicalize(document − signature))`.
  - **Signature.** `signatureValue = base64(RSA-SHA256-sign(options_hash + document_hash))`. The
    two hex strings are concatenated.
  - **Output.** It adds `"signature": options + signatureValue`, and appends
    `https://w3id.org/security/v1` to the document's `@context`.
- `verify_actor!` (`:12-37`):
  - It rejects documents with `@graph`, `@included` or `@reverse` (`unsupported_jsonld_features?`;
    `json_ld_helper.rb:6,155-161`).
  - It requires `type == "RsaSignature2017"` and an unexpired `expires`.
  - It resolves `creator` to a key and verifies the same concatenation.
- **Canonicalization.** `canonicalize(json)` is
  `RDF::Graph.new << JSON::LD::API.toRdf(json, documentLoader: load_jsonld_context)`, dumped as
  `:normalize` (`json_ld_helper.rb:120-123`).
  - The gems are `json-ld` 3.3.2, `json-ld-preloaded` 3.3.2, `rdf` 3.3.4 and `rdf-normalize` 0.7.0
    (`Gemfile:101-103`; `Gemfile.lock:369,377,702,709`).
- **Context loading.** `load_jsonld_context` (`json_ld_helper.rb:388-402`) fetches a context URL
  and caches it for 30 days. Contexts bundled by `json-ld-preloaded` don't need a fetch.

**Who may reply** (`app/controllers/api/v1/statuses_controller.rb:106-111`, `app/policies/status_policy.rb:9-10`):
- `set_thread` finds the parent and authorizes `show?`. Not found or not permitted gives a 404.
- For a private status, `show?` is `owned? || following_author? || mention_exists?`.

**What Mastodon does on create** (`app/services/post_status_service.rb`, `app/models/status.rb`):
- **Visibility** is overridden only for silenced accounts (`:86`) and private quotes (`:87`), never
  because of the thread (`post_status_service.rb:85-87`).
- **`replies_count`** counts only distributable replies (`status.rb:484`; `visibility.rb:31-33`).
- **`in_reply_to_account_id`** follows `carried_over_reply_to_account_id` (`status.rb:461-466`).
- **Conversation.** A reply joins its parent's conversation (`status.rb:449`).

**What Mastodon consumes** (`app/lib/activitypub/activity/create.rb`, `app/lib/activitypub/parser/status_parser.rb`):
- **`inReplyTo`** (`create.rb:440-447`). An unknown parent is fetched by `ThreadResolveWorker`
  (`:382-386`; `app/workers/thread_resolve_worker.rb:9-21`).
- **Mentions** are resolved by `href` (`create.rb:255-263`).
- **Visibility** is derived from the audience (`status_parser.rb:101-111`).

**How Mastodon fetches** (`json_ld_helper.rb`, `app/lib/request.rb`,
`app/services/activitypub/fetch_remote_status_service.rb`,
`app/services/activitypub/fetch_remote_actor_service.rb`, `app/lib/activitypub/activity.rb`):
- **`fetch_resource`** re-fetches by `id` and requires `json['id'] == uri` (`json_ld_helper.rb:242-252`).
- **Response checks:** status 200 and an ActivityPub content type (`:281,351` onward), a 1 MB
  body (`request.rb:293-294`), and at most 3 redirect hops (`:101-102`).
- **Signing:** the signing feature wraps each request it sends (`request.rb:72-75`).
- **Private addresses:** each resolved address is checked before connecting (`:325-334,389-394`).
- **Attribution:** `trustworthy_attribution?` requires the same host for the object and
  `attributedTo` (`fetch_remote_status_service.rb:61-66`). `attributedTo` is read with
  `value_or_id(first_of_value(...))` (`:29`).
- **Object types:** `Note` and `Question` are supported, and `Image`, `Audio`, `Video`, `Article`,
  `Page` and `Event` are converted (`activity.rb:9-10`; `fetch_remote_status_service.rb:82-84`).
- **Actors** are fetched with a known id, so their `id` must equal the requested URI
  (`fetch_remote_actor_service.rb:16`).

**Search and URL resolution** (https://docs.joinmastodon.org/methods/search/,
`app/controllers/api/v2/search_controller.rb`, `app/services/resolve_url_service.rb`):
- **Docs.** `GET /api/v2/search`: with `q` an HTTPS URL and `resolve=true`, "resolving the URL
  and returning the matching status, account or Collection is attempted". `resolve` requires a
  user token.
- **Controller.** Without a signed-in user, a `resolve` request gets a 401: "Search queries that
  resolve remote resources are not supported without authentication"
  (`search_controller.rb:12-14,37-38`). Results are limited to `RESULTS_LIMIT = 20` (`:7`).
- **`ResolveURLService#call`** (`resolve_url_service.rb:9` onward):
  - A local URL is resolved from the database (`:13-14`, `process_local_url` at `:93`).
  - Otherwise `FetchRemoteStatusService` fetches it (`:28`).
  - Either way the result is returned only if `authorize_with @on_behalf_of, status, :show?`
    passes (`:29,59`).
- **Ids.** The returned status carries Mastodon's own id, which the client then sends as
  `in_reply_to_id`.

**Client API:**
- `POST /api/v1/statuses` takes `in_reply_to_id`: "ID of the status being replied to"
  (https://docs.joinmastodon.org/methods/statuses/).
- `in_reply_to_id` and `in_reply_to_account_id` are nullable strings, "cast from an integer but not
  guaranteed to be a number" (https://docs.joinmastodon.org/entities/Status/).

**Home-feed filtering:**
- A reply whose parent is unresolved is filtered from home feeds (`app/lib/feed_manager.rb:505`).
- Self-replies are kept (`:524`).
- Re-distribution after a late parent arrives is gated on the 6 h window
  (`thread_resolve_worker.rb:21`; `status.rb:188,218-220`).

### Platform limits

- **API Gateway REST integration timeout:** "50 milliseconds - 29 seconds for all integration
  types, including Lambda"
  (https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-execution-service-limits-table.html).
- **`URLRequest.timeoutInterval` is an idle timeout:** "If during a connection attempt the request
  remains idle for longer than the timeout interval, the request is considered to have timed out"
  (https://developer.apple.com/documentation/foundation/nsurlrequest/timeoutinterval).

### Swift JSON-LD and RDF canonicalization (checked 2026-10-20)

- **Search scope.** A Swift Package Index and web search found exactly one Swift stack:
  - `Kingpin-Apps/swift-jsonld`: "A pure-Swift, concurrency-safe implementation of the W3C JSON-LD
    1.1 specification". Version 0.1.3, MIT, 3 stars, 8 commits, one author. Linux is listed.
  - `Kingpin-Apps/swift-rdf-canonize`: "Pure-Swift implementation of RDF Dataset Canonicalization
    (RDFC-1.0 / URDNA2015)". Version 0.2.2, MIT, 0 stars, 18 commits, one author. Linux is listed.
- **Maturity.** Both are about four months old, single-author and pre-1.0. Neither index page
  claims W3C test-suite conformance. Whether `swift-jsonld` implements `toRdf` with a custom
  document loader is not stated.
- **No maintained, conformance-verified Swift JSON-LD + URDNA2015 stack was found.** That makes
  the phase 3 signing work a dependency-or-build decision (Open Question 1), not a library pick.

## Current FAP behaviour

Verified by reading the code at `8a78008`.

**Create path.**
- `CreateStatusRequest.inReplyToId` decodes `in_reply_to_id` (`CreateStatusRequest.swift:27,38`).
- `PostHandler` copies it verbatim into `Status.inReplyTo` (`PostHandler/main.swift:310`). An
  unknown value returns 200.
- **The quote path** looks up `quoted_status_id` in the caller's own partition only (`:252`).
  - Anything else goes to an unsigned `fetchRemoteObject` (`:264`).
  - The author's inbox is resolved through the cache or a fetch (`:265-277`).
  - If that fails, the quote is marked `failed` (`:282-287`).

**Model and storage.**
- `Status.inReplyTo` is documented as a URI but holds whatever the client sent (`Status.swift:47-48`).
  `repliesCount` is documented as remote-only (`:53-54`).
- `Status.tags` exists (`:44`), and `Tag` has `type`, `name` and `href` (`:267-273`).
  `PostHandler` writes `tags: nil` (`main.swift:308`).
- Statuses are keyed `ACTOR#{username}` / `STATUS#{ulid}` (`Status.swift:216-221`). There is no
  index on `inReplyTo` or on a bare status id.
- Remote actors are cached at `REMOTE_ACTOR#{actorUri}` with a 24 h TTL (`DynamoDBStore.swift:593-630`).
  That cache is the inbound-signature trust anchor (`KeyManager.swift:41-42`).

**Outbound Note.**
- `buildNoteJSON` (`Note.swift:23-109`) emits no `inReplyTo`. It serializes `tags`
  (`Note.swift:62-72`).
- It has four callers:
  - delivery (`PostHandler/main.swift:325`)
  - the object endpoint (`ObjectHandler/main.swift:74`)
  - the outbox (`OutboxHandler/main.swift:80`)
  - the quote-accept `Update` (`InboxHandler/main.swift:1285`), which goes to followers only
- `FederationOverview.md:15` claims "reply metadata", which is false at `8a78008`.
- **The Note `@context`** (`Note.swift:106`) maps `quoteUri` to `toot:quoteUri`. Mastodon maps it
  to `http://fedibird.com/ns#quoteUri` (`context_helper.rb:39`).
- The Note emits `_misskey_quote` (`:98`) and `interactionPolicy`/`canQuote`/`automaticApproval`
  (`:103`). It defines none of them in its `@context`, while Mastodon defines all of them
  (`context_helper.rb:40,43-48`).
- The Create's own `@context` is the bare ActivityStreams URL (`Note.swift:127`).

**Addressing.** `computeAddressing` (`Note.swift:146-165`) gives public `[Public]`/`[followers]`,
unlisted `[followers]`/`[Public]`, and private `[followers]`/`[]`.

**Delivery.**
- One `DeliveryJob {targetInbox, activityJSON, actorUsername}` (`DeliveryJob.swift`) is enqueued
  per distinct follower shared inbox (`PostHandler/main.swift:332-352`).
- `DeliverHandler` reads the key at `{SSM_KEY_PREFIX}/{username}` (`DeliverHandler/main.swift:52-58`),
  signs and POSTs (`:79-94`).
- `DeliverFunction` has DynamoDB *read*, SSM read of `activity/${Stage}/keys/*`, and a 60 s
  timeout (`functions/template.yaml:446-453`).
- The queue allows 3 receives (`activity-environment/template.yaml:87`).

**Fetching and signing.**
- `HTTPSignature.sign` is POST-only, signing `(request-target) host date digest content-type`
  (`HTTPSignature.swift:112-133`). Its signing string comes from `buildSigningString` (`:181-190`).
- `fetchRemoteObject` (`FetchRemoteObject.swift:36-58`):
  - It is unsigned and uses `URLSession.shared`, so it follows any redirect (`:45`).
  - Its 10 s timeout is an idle timeout.
  - It has no body cap and no content-type check.
- `KeyManager.fetchActorDocument` is unsigned (`KeyManager.swift:68-74`), and parses at `:89-105`.

**Infrastructure.**
- `PostFunction` has DynamoDB CRUD, SQS send and SSM read `activity/${Stage}/*`, with a 60 s
  timeout (`functions/template.yaml:122-140`).
- `InboxFunction` has DynamoDB CRUD and SQS send only (`:429-433`).
- `ClientApi` is a REST API with no integration-timeout override (`:111-120`), so 29 s applies.
- No function has a `VpcConfig`.
- **CloudFront.** The CloudFront default behaviour targets the ActivityPub API origin
  (`cdn/template.yaml:312-313`). Client-API paths each need their own behaviour with the
  `ClientApiGateway` origin, as `/api/v1/statuses` has (`:340-346`).

**Other.**
- FAP actors follow no one (`FollowingHandler/main.swift:8`).
- The local account id is the username (`VerifyCredentialsHandler/main.swift:131`).
- The actor `url` is `https://{serverDomain}/@{username}` (`ActorSerializer.swift:60`).
- `ObjectHandler` serves any visibility on `activity+json` (`:74-84`). That is
  FederatedActivityPublisher#270.
- **Inbound replies:**
  - `handleCreate` drops non-`Note` objects (`InboxHandler/main.swift:747`) and non-local
    `inReplyTo` (`:756-772`).
  - It stores `REPLY#` items and counts them (`:808-810`).
  - Delete (`handleDelete`, `:987` onward) removes a stored reply (`:1053-1059`).
  - Update of a reply uses the inbox owner's partition (`:884-885`).
  - The quote-accept origin check is at `:1257-1265`.

## Phase 1 — Self-replies

### 1.1 Shared helpers move to ActivityPubCore

- Move `parseStatusUri` (`InboxHandler/main.swift:1114`) into ActivityPubCore as
  `parseLocalStatusUri(_:serverDomain:handleDomain:)`. Behaviour is unchanged.
- Add `isLocalHost(_:)`, which is true when a URI's host is `serverDomain` or `handleDomain`.

### 1.2 Resolve and validate `in_reply_to_id`

Insert this step between visibility validation and addressing, before anything is written:

1. If `in_reply_to_id` is absent or empty, the status is not a reply.
2. Otherwise call `store.getStatus(username: <author>, id: in_reply_to_id, consistentRead: true)`.
   InboxHandler already reads with `consistentRead` after a write (`InboxHandler/main.swift:1284`).
3. If nothing is found, return **404** `{"error":"Status to reply to not found"}` and write
   nothing, as Mastodon does. Phases 2 and 3 widen what resolves (§2.2, §3.3).
4. If found, set:
   - `inReplyTo = parent.uri`, which is byte-identical to the Note `id` (`PostHandler/main.swift:293`;
     `Note.swift:25`)
   - `inReplyToId = parent.id`
   - `inReplyToAccountId = parent.username`
   - `inReplyToAccountUri = https://{serverDomain}/users/{username}`
5. **Cap the visibility while FederatedActivityPublisher#270 is open.**
   - Rank the visibilities `public` > `unlisted` > `private`. If the request ranks above the
     parent's visibility, downgrade the reply to the parent's visibility before
     `computeAddressing`. This follows Mastodon's quote downgrade (`post_status_service.rb:87`).
     The response's `visibility` reports the effective value.
   - The reason: a wider child would publish a narrower parent's URI, and the object endpoint
     serves that parent regardless of visibility (`ObjectHandler/main.swift:74-84`).
   - **Once #270 is fixed, the cap is removed to match Mastodon**, which never changes visibility
     because of the thread (`post_status_service.rb:85-87`). Decided 2026-10-20.
   - The cap applies only to local parents (phases 1 and 2).

### 1.3 Storage

A reply item gains four optional `Status` attributes. Only the resolver writes them, and always
together:
- `inReplyToId`: the FAP id of the parent
- `inReplyToAccountId`: the FAP account id of the parent's author, or of the carried-over
  account (§2.4)
- `inReplyToAccountUri`: that account's actor URI
- `inReplyTo`: the parent URI. This attribute already exists.

There is no index change.

**Values stored before this change are ignored.**
- A reader treats a status as a reply only when `inReplyToId` is present. A legacy `inReplyTo`
  without it is ignored as if absent.
- Normalizing would change object bodies already served under a one-year cache, and would turn
  unvalidated client input into URIs.
- No legacy item has been observed. If one is, that is a follow-up issue.

### 1.4 Emit `inReplyTo` on the Note

- `buildNoteJSON` emits `"inReplyTo":"<inReplyTo>"` when `inReplyToId` is present.
- All four callers pick it up, and `FederationOverview.md:15` becomes accurate.
- The Note's meaning stays immutable: a parent never changes.
- No `context` or `conversation` (decided). Mastodon puts the child in the parent's conversation
  (`status.rb:449`).

### 1.5 Addressing, mentions, delivery

- A self-reply uses `computeAddressing` with its capped visibility.
- It carries no Mention tag and no mention HTML.
- Fan-out is unchanged.
- Out-of-order arrival is handled on the receiving side (`feed_manager.rb:505`;
  `thread_resolve_worker.rb:21`; `status.rb:188,218-220`).

### 1.6 `repliesCount`

- **Gate.** Increment the parent's count only for a public or unlisted reply, Mastodon's
  `distributable?` gate (`status.rb:484`).
- **Ordering.** Do it *after* the delivery enqueue.
- **Failure.** Log and swallow a failure. The count is display-only, and a 5xx after delivery
  would make a retrying bot fork the chain.
- **Doc comment.** Update `Status.swift:53` to "replies received, local and remote, public or
  unlisted".
- **Page cache.** The parent's post page body already changes after publication when inbound
  likes, boosts, quotes and replies arrive. Its freshness is bounded by CloudFront's 300 s cap.
  Fixing the page's one-year header is separate.

### 1.7 Client API

- Move `buildStatusResponse` into ActivityPubCore.
- `in_reply_to_id` is the stored `inReplyToId`, and `in_reply_to_account_id` is the stored
  `inReplyToAccountId`. Both are `null` for a non-reply.
- **`openapi.yaml`:**
  - Add `in_reply_to_account_id` to `Status` as **optional, nullable**.
  - Add a `"404"` response to `createStatus`.
- The implementation PR builds the `integration-tests` `APIClient` and the mirrored client
  against the branch before merge (review standards S11/S12).
- Promote `in_reply_to_account_id` to `required` once every deployed server emits it.
- **Release notes:** an unknown `in_reply_to_id` now returns 404 instead of 200, and a reply's
  visibility is capped at its local parent's while #270 is open.

### 1.8 Web view

- The post page shows "In reply to", linking to `https://{serverDomain}/@{username}/{parentId}`.
- The profile page is unchanged: each post is listed separately (decided).

### Phase 1 components

- **Added:** none. Two functions move to ActivityPubCore, and a resolver, a cap function and four
  optional attributes are added.
- **Not added:** no handler, route, table, index, queue or workflow.

## Phase 2 — Replies to other local actors

### 2.1 Ids and search

**Ids work as on Mastodon: one FAP id per status, obtained through search.**
- A local status's FAP id is its ULID, whoever owns it.
- A client gets another actor's status id the way a Mastodon client does: by resolving the
  status URL through search.

**The new endpoint is `GET /api/v2/search?q=<https URL>&resolve=true[&type=statuses]`.**
- **Auth.** Bearer or session auth is required, as on `POST /api/v1/statuses`. A missing token
  gets a 401, as in Mastodon (`search_controller.rb:12-14,37-38`).
- **Query.** `q` must be an `https://` URL. Anything else returns empty results, because FAP has
  no full-text search.
- **Response.** A Mastodon `Search` result: `{accounts: [], statuses: [Status…], hashtags: []}`.
  Statuses use FAP's existing `Status` schema, built by `buildStatusResponse`.
- **Accounts.** Account resolution isn't needed for replies, so `accounts` is always empty.
  `type=accounts` and `type=hashtags` return empty lists.
- **Local URL resolution in phase 2** follows the order of `ResolveURLService` (`resolve_url_service.rb:13-14,93`):
  1. If `isLocalHost(q)`, accept either the status URI or the web URL `/@{username}/{id}`.
  2. Load the status with `getStatus(owner, id)`.
  3. Apply the visibility rule (§2.2).
  4. Write the `REF#` pointer (§2.3), and return the status.
- **Non-local URLs** return empty results in phase 2. Phase 3 adds them.

### 2.2 Who may see and reply: Mastodon's `show?`

- A status that is `private` and owned by someone other than the caller is never returned by
  search, and never resolves as a reply parent (404).
- This is `show?` (`status_policy.rb:9-10`; `statuses_controller.rb:106-111`;
  `resolve_url_service.rb:29,59`).
- Neither of the other two `show?` conditions can hold, because FAP actors follow no one
  (`FollowingHandler/main.swift:8`) and FAP records no Mentions of a peer in the parent.
- This rule stays after #270 is fixed.

### 2.3 `REF#` item type

- **Item.** `PK=REF#{id}`, `SK=META`, in the existing table. It is a new item type, like `MEDIA#`.
  It needs no new table and no index.
- **Local pointers.** For a local status, `id` is its ULID and the item holds
  `{kind: "local", owner: username, uri}`.
- **When it is written.** Search writes it on resolution, with a conditional put that is
  idempotent. A local pointer has no TTL. FAP has no status deletion today. A future
  delete-status feature must delete the pointer too.
- **Why lazily.** A client can hold another actor's id only after a search, so creating the
  pointer at search time covers every reachable id without a backfill.

### 2.4 Resolving `in_reply_to_id`

The resolver gains one step after the phase 1 own-partition lookup:
1. If the caller's partition misses, `GetItem REF#{in_reply_to_id}`.
2. For `kind == "local"`, `getStatus(owner, id, consistentRead: true)`, then apply §2.2.
3. A miss at any step gives a 404.

`in_reply_to_id` takes ids only. A URI goes through search first, as on Mastodon.

**Carry-over.** Implement `carried_over_reply_to_account_id` (`status.rb:461-466`):
- If the parent is by the posting actor *and* has `inReplyToAccountId`, carry the parent's
  `inReplyToAccountId` and `inReplyToAccountUri` over.
- Otherwise use the parent's author.

### 2.5 Addressing, Mention, delivery

Two accounts matter here:
- *P* is the direct parent's author.
- *R* is the account in `inReplyToAccountId`, when it isn't the posting actor.

**Direct reply to someone else (*P* ≠ poster, so *R* = *P*):**
- **Mention tag.** `Tag(type: "Mention", name: "@{R}@{handleDomain}", href: <R actor URI>)`.
  `buildNoteJSON` already serializes tags.
- **Visible mention.** Prepend Mastodon's mention HTML (`text_formatter.rb:80-87`) with the full
  acct, as `with_domain` renders it:

  ```html
  <span class="h-card" translate="no"><a href="https://{serverDomain}/@{R}" class="u-url mention">@<span>{R}@{handleDomain}</span></a></span>
  ```

  - `href` is the actor `url` (`ActorSerializer.swift:60`).
  - The HTML goes at the start of the first `<p>` that `convertTextToHTML` produces, followed by a
    space.
  - **No duplicate.** If the client's text already begins with `@{R}@{handleDomain}` or `@{R}`,
    matched case-insensitively and followed by whitespace or the end of the text, that token is
    removed before conversion and replaced by the linked form. The mention then appears once.
  - The username and domain are HTML-escaped.
- **`cc`.** *R* is appended for every visibility (`tag_manager.rb:215,228`).

**Carried-over self-reply (*P* = poster, *R* carried over).** Decided 2026-10-20:
- **No** Mention tag and **no** visible mention.
- *R* goes in `cc` only.

**Delivery.**
- No HTTP delivery is made to a local *R*.
- For a distributable reply whose *direct* parent is local and by another actor, fan out to the
  posting actor's followers ∪ *P*'s followers, deduplicated by shared inbox. This is Mastodon's
  `@status.thread.account.followers` (`status_reach_finder.rb:105-106`).
- A carried-over self-reply unions nothing, because *P* is the poster.

**`repliesCount`.** It goes on *P*'s partition, under the §1.6 rules.

**Visibility cap.** §1.2 step 5 applies. Private parents of others never resolve, so the cap only
ever lowers a public request to unlisted.

### 2.6 Delete and Update reach

A shared function `replyAudience(status)` returns:
- the posting actor's followers
- *P*'s followers, under the §2.5 union rule
- *R*, when *R* is in `cc`

This mirrors Mastodon's use of `StatusReachFinder` for Create, Update and Delete
(`distribution_worker.rb:22-23`; `remove_status_service.rb:92-106`).

**Callers:**
- PostHandler's Create fan-out.
- The quote-accept `Update` (`InboxHandler/main.swift:1284` onward). Today it goes to followers
  only. It switches to `replyAudience`, so an Update of a quoting reply also reaches *P*'s
  followers and *R*.
- **Any future status delete or edit endpoint MUST use `replyAudience`.** FAP has neither endpoint
  today.

In phase 2, *R* is local, so no HTTP delivery to *R* happens.

### 2.7 Interaction with InboxHandler

- A local reply never passes through InboxHandler, so no `REPLY#` item is written and the count is
  incremented once.
- No FAP inbox is in any fan-out, because actors follow no one.
- Remote replies to the local reply are handled by the existing `handleCreate`.
- The pre-existing Update partition mismatch (`:884-885`) is recorded here and not fixed.

### 2.8 Client API and web

- `in_reply_to_id` is *P*'s ULID, which the caller can post back because the `REF#` pointer
  exists.
- `in_reply_to_account_id` is *R*'s username.
- **`openapi.yaml`:** add `GET /api/v2/search` (`operationId: search`) with a `SearchResults`
  schema `{accounts, statuses, hashtags}`.
- The post page's "In reply to" links to *P*'s post page.

### Phase 2 components

| Component | What it is |
|---|---|
| `SearchHandler` | New Lambda. Bearer/session auth, local URL resolution, the `show?` rule, `REF#` writes. Same policies as `PostFunction` except SQS. |
| `GET /api/v2/search` | New `ClientApi` route |
| CloudFront `/api/v2/search` | New cache behaviour on `ClientApiGateway`: `CachingDisabled`, `ClientApiOriginRequestPolicy`, GET/HEAD/OPTIONS. It sits beside `/api/v1/statuses` (`cdn/template.yaml:340-346`). A deployment that serves the client API from a separate handle-domain distribution must route this path there as well. That routing lives outside this repository. |
| `REF#` item type | A new item type in the existing table. No table or index. |
| `replyAudience` | A shared function in ActivityPubCore |
| OpenAPI | The `search` operation and `SearchResults` schema |

**Re-checked against the design invariants:**
- **Smallest mechanism.** The new handler, route and behaviour are what Erin's id decision
  requires. A lazy pointer avoids an index and a backfill.
- **One job.** Search resolves URLs, PostHandler creates statuses, and delivery is unchanged.
- **Blast radius.** One repository, plus the handle-domain route noted above for deployments that
  use one.

## Phase 3 — Replies to remote statuses

### 3.1 Remote ids and the remote-status cache

**Remote status id.**
- The FAP id is the first 16 bytes of `SHA-256(canonical URI)`, encoded as 26 Crockford-base32
  characters. That is the same length and alphabet as a ULID.
- It is deterministic, so a re-search returns the same id, Delete invalidation can find the entry
  from the URI alone, and no by-URI index is needed.
- The resolver tries the caller's partition before `REF#`. A collision with a local ULID would
  need a 128-bit match [inferred: negligible probability].

**Remote account id.** The same construction, applied to the actor URI. It is returned as
`in_reply_to_account_id`.

**Cache entry.** `PK=REF#{id}`, `SK=META`, with these fields:
- `kind: "remote"`
- `uri`: the canonical id
- `url`
- `attributedTo` (actor URI)
- the actor's `preferredUsername` and profile `url`
- `visibility`, derived as in §3.3
- `content`, sanitized with `HTMLSanitizer`
- `summary`, `sensitive`, `published`, `language`
- `fetchedAt` and `ttl`

**TTL: 30 days.**
- An expired entry makes `in_reply_to_id` 404. The client searches again, which refreshes the
  entry under the same id.
- Mastodon keeps fetched statuses indefinitely. FAP keeps them for a bounded time because it has
  no other use for them.

**Invalidation in InboxHandler** (it already has DynamoDB CRUD):
- **Delete.** When a Delete arrives whose object (a URI or `Tombstone.id`) hashes to an existing
  remote `REF#` entry, and the activity's actor has the same host as the object, delete the entry.
  Mastodon delivers a status's Delete to every account that replied to it (`status_reach_finder.rb:38,79-81`;
  `remove_status_service.rb:98`), so FAP receives these for parents it replied to.
- **Update.** When an Update's `Note` (or other accepted type) hashes to an existing entry and
  passes the same origin check, refresh `content`, `summary`, `sensitive` and `visibility` from
  the object. Mastodon distributes Updates through the same reach finder (`distribution_worker.rb:22-23`).

### 3.2 Hardening and signing the shared fetch

All controls go into `fetchRemoteObject` as one mechanism. The quote path's fetches
(`PostHandler/main.swift:264,272`) are hardened by the same change.

| Control | Requirement | Reference |
|---|---|---|
| Scheme | `https` on the initial URI and every hop | Stricter than Mastodon, which allows `http` (`json_ld_helper.rb:95-97`) |
| Redirects | At most 3 hops, each re-signed | `request.rb:101-102,72-75` |
| Address | Reject loopback, private (RFC 1918 / ULA), link-local and unspecified addresses on every connection, including each hop. The check applies to the address actually connected to. | `request.rb:325-334,389-394` |
| Body | 1 MB cap | `request.rb:293-294` |
| Content type | `application/activity+json`, or `application/ld+json` with the AS profile | `json_ld_helper.rb:281,351` onward |
| Status | Only 200 counts as success | `json_ld_helper.rb:281` |
| Deadline | An absolute deadline from the caller, enforced even while bytes keep arriving | §3.3 |

**Signing.**
- `HTTPSignature.signGet(privateKeyPem:keyId:pathAndQuery:host:)` signs `(request-target) host date`.
  - The request target includes the query string (`signed_request.rb:113`).
  - It satisfies `verify_signature_strength!` (`signed_request.rb:54-57`).
  - It reuses `buildSigningString` (`HTTPSignature.swift:181-190`).
- The signer is the requesting actor, with keyId `https://{serverDomain}/users/{u}#main-key`.
  - The key is read from `{SSM_KEY_PREFIX}/{u}`, and cached in a per-container dictionary keyed by
    username.
  - Mastodon accepts any verifying account key (`signature_verification.rb:45` onward).

**The HTTP client is not decided.** `URLSession` doesn't expose the connected address. See
Unverified.

### 3.3 Remote resolution in search

Search resolves a non-local `https://` `q` under an overall **10 s deadline**, well under the 29 s
API Gateway limit. On overrun or any failure, the status is left out of the results (empty
`statuses`), and nothing is written.

The steps follow Mastodon's `FetchRemoteStatusService` and `fetch_resource`:
1. **Fetch** the object signed, as the caller, through §3.2.
2. **Canonicalize.** If `json['id']` ≠ `q`, re-fetch the returned `id` and require equality
   (`json_ld_helper.rb:242-252`). Use the canonical `id` from here on. A pasted web URL works this
   way.
3. **Validate.**
   - `type` must be one of Mastodon's supported or converted types (`activity.rb:9-10`). A
     `Tombstone` fails.
   - `attributedTo` is read via `first_of_value`/`value_or_id`.
   - The host of `attributedTo` must equal the host of `id` (`trustworthy_attribution?`,
     `fetch_remote_status_service.rb:61-66`).
4. **Fetch the actor** signed.
   - Require `json['id'] == attributedTo` (`fetch_remote_actor_service.rb:16`).
   - Parse it with the actor-document parser extracted from `KeyManager.fetchActorDocument`
     (`KeyManager.swift:89-105`), extended to return `followers` and `url`.
   - Write `REMOTE_ACTOR#{attributedTo}` only after the `id` check passes.
5. **Derive visibility** with `status_parser.rb:101-111`.
   - `to` and `cc` may be arrays or strings.
   - All three public spellings count (`tag_manager.rb:14-15`).
   - The comparison uses the actor's `followers`.
   - A `direct` parent is left out of the results. FAP can't reply to it (`PostHandler/main.swift:194`).
6. **Write** the remote `REF#` entry (§3.1) and return the `Status`.

FAP searches only for the authenticated caller. The remote server's own access control decides
what the signed fetch returns, which is equivalent to Mastodon's `show?` on the fetched status
(`resolve_url_service.rb:29`).

### 3.4 Resolving a remote `in_reply_to_id`

- PostHandler resolves `REF#{id}` with `kind == "remote"` from the cache. It makes **no network
  fetch**, so the create request stays within the API Gateway limit by construction.
- If the entry is missing or expired, the request gets a 404. **A parent that is unreachable or
  deleted is refused with 404**, decided 2026-10-20.
- On success it sets:
  - `inReplyTo` to the canonical URI
  - `inReplyToId` to the remote id
  - `inReplyToAccountId` to the remote account id
  - `inReplyToAccountUri` to `attributedTo`
- Remote parents get no visibility cap. #270 concerns FAP's own object endpoint.

### 3.5 Addressing, Mention, delivery

These are the §2.5 rules with a remote *R*.

**Direct reply to *R*:**
- **Mention tag.** `Tag(type: "Mention", name: "@{preferredUsername}@{actor host}", href: <actor URI>)`.
  Mastodon matches mentions by `href` (`create.rb:255-263`).
- **Visible mention.** The §2.5 HTML, with `href` set to the actor's `url` (falling back to the
  actor URI) and the display text `@{preferredUsername}@{actor host}`.
- **`cc`.** *R* is added.

**Carried-over self-reply:** *R* goes in `cc` only. No Mention and no visible mention (decided).

**Delivery to *R*.**
- `DeliveryJob` gains an optional `targetActorUri`. When `targetInbox` is empty, `DeliverHandler`:
  1. fetches the actor signed through §3.2
  2. requires `id == targetActorUri`
  3. delivers to `sharedInbox ?? inbox`
- Failures retry under the queue's existing 3 receives.
- `DeliverHandler` already holds the keys and needs no IAM change. It writes no cache, because its
  DynamoDB access is read-only.
- PostHandler adds one such job for *R* whenever *R* is in `cc`. That covers direct replies, and
  carried-over replies of every visibility.
- If *R*'s shared inbox equals a follower's shared inbox, the activity is delivered twice to that
  server [inferred: receivers deduplicate by activity id].
- There is no followers union for a remote parent (`status_reach_finder.rb:105-106` applies only
  to local authors).

**Forwarding to *R*'s followers** happens through Linked Data Signatures (§3.6).

**Delete and Update.** `replyAudience` (§2.6) adds the *R* job by `targetActorUri`. InboxHandler's
quote-accept Update can then reach *R* without SSM access, because `DeliverHandler` resolves the
inbox.

### 3.6 Linked Data Signatures on replies

**Scope.** PostHandler LD-signs every Create it delivers for a **public or unlisted reply whose
direct parent is remote**. Those are exactly the activities Mastodon's `forward_for_reply` can
forward (`create.rb:491-495`). The outbox's Create copies stay unsigned, as the field is optional.

**Algorithm.** This is byte-compatible with `linked_data_signature.rb:39-62`:
1. **Options.** `{type: "RsaSignature2017", creator: "https://{serverDomain}/users/{u}#main-key",
   created: <UTC ISO 8601, seconds>, expires: <created + 2 days>}`.
2. **Options hash.** `options_hash = hex(SHA-256(canonicalize({"@context": "https://w3id.org/identity/v1",
   creator, created, expires})))`.
3. **Document hash.** `document_hash = hex(SHA-256(canonicalize(create − signature)))`.
4. **Signature.** `signatureValue = base64(RSASSA-PKCS1-v1_5-SHA256(key, options_hash + document_hash))`.
5. **Emit.** Add `"signature": {type, creator, created, expires, signatureValue}`, and append
   `https://w3id.org/security/v1` to the Create's `@context`.

`canonicalize` is JSON-LD `toRdf`, then RDF dataset canonicalization (URDNA2015 / RDFC-1.0), then
N-Quads, matching `json_ld_helper.rb:120-123`.

**The Create must survive Mastodon's compaction**, or Mastodon strips the signature
(`process_activity_service.rb:59-66`; `json_ld_helper.rb:184-238`).
- **One top-level context.** The signed Create carries one top-level `@context`:
  `["https://www.w3.org/ns/activitystreams", "https://w3id.org/security/v1", {…}]`. The extension
  object maps every term FAP emits to the IRI Mastodon's `full_context` uses:
  - `sensitive` and `Hashtag` to `as:`
  - `toot`, `blurhash` and `focalPoint` as in `context_helper.rb:13-23`
  - `quoteUri` to `http://fedibird.com/ns#quoteUri`
  - `_misskey_quote` to `https://misskey-hub.net/ns#_misskey_quote`
  - `gts`, `interactionPolicy`, `canQuote` and `automaticApproval` as in `context_helper.rb:37-48`

  The embedded Note drops its own `@context`.
- **All Notes.** `buildNoteJSON`'s Note `@context` changes to the same mapping. That fixes the
  `quoteUri` mismatch and the undefined terms for every Note.
  - It changes the bytes of already-published Notes. Their JSON keys and values stay identical for
    plain-JSON consumers, so the immutability argument in §1.4 still holds for every consumer
    that doesn't process JSON-LD.
- **No unsupported keywords.** FAP emits no `@graph`, `@included` or `@reverse`
  (`json_ld_helper.rb:6`).

**Contexts are never fetched at sign time.**
- ActivityPubCore bundles exactly three context documents as package resources:
  - `https://www.w3.org/ns/activitystreams`
  - `https://w3id.org/security/v1`
  - `https://w3id.org/identity/v1`
- Each is committed with its source URL and SHA-256.
- The canonicalizer's document loader serves only those three, and fails for any other URL.
- **On failure, deliver unsigned.** If canonicalization or signing fails, the Create goes out
  unsigned and the failure is logged. The reply is delivered, and only forwarding is lost.
- Mastodon resolves the same three URLs through `json-ld-preloaded` or its 30-day context cache
  (`json_ld_helper.rb:388-402`).

**The implementation dependency is undecided.** No conformance-verified Swift JSON-LD +
URDNA2015 stack exists (Standards). Open Question 1 decides between adopting the young Kingpin
packages and building a canonicalizer. Either path must pass the same gate:
- **W3C test suites.** The W3C RDFC-1.0 test suite, and the JSON-LD 1.1 `toRdf` tests for the
  features FAP's documents use.
- **Byte-for-byte fixtures.** Committed fixtures produced once by Mastodon's reference stack (Ruby
  `json-ld` 3.3.2 + `rdf-normalize` 0.7.0) for:
  - a FAP-shaped signed Create
  - its canonical N-Quads
  - both hashes
  - the signature for a fixed test key and timestamps

### 3.7 Interaction with InboxHandler

- `handleCreate` keeps dropping inbound Notes whose `inReplyTo` isn't local (`:756-772`). FAP
  stores only its own reply and the remote parent's cache entry.
- *R*'s reply to FAP's reply is an inbound reply to a local status, and existing code handles it.
- `handleDelete` and `handleUpdate` gain the `REF#` invalidation in §3.1.

### 3.8 Client API and web

- Search returns remote statuses with their FAP ids.
- `in_reply_to_id` is the remote id, and `in_reply_to_account_id` is the remote account id.
- The post page's "In reply to" links to the cached `url`, falling back to the canonical URI.

### Phase 3 components

| Component | What it is |
|---|---|
| Remote resolve in `SearchHandler` | An extension of the phase 2 handler |
| Remote `REF#` entries | The existing item type, with a TTL. No table or index. |
| `fetchRemoteObject` hardening + `signGet` | An extension of the shared fetch, which also covers the quote path |
| HTTP client capable of per-connection address checks | A possible **new dependency** (Unverified) |
| `DeliveryJob.targetActorUri` | An extension of the existing job and of `DeliverHandler` |
| `REF#` invalidation | An extension of `handleDelete` / `handleUpdate` |
| Shared actor-document parser | Extracted from `KeyManager` |
| LD signing | A new ActivityPubCore module: JSON-LD `toRdf`, RDF canonicalization, three bundled contexts, an RSA-SHA256 signer. **A new dependency or a substantial new module** (Open Question 1). |
| Note/Create `@context` alignment | A change to `buildNoteJSON` / `buildCreateActivityJSON` |

**Re-checked against the design invariants:**
- **Smallest mechanism.**
  - Remote ids are deterministic, so no by-URI index is needed.
  - The cache reuses `REF#`.
  - Inbox resolution moves into `DeliverHandler` instead of adding IAM to InboxHandler.
  - PostHandler makes no remote fetch.
  - LD signing is unavoidable once forwarding is required (decided). Its size is the
    canonicalization dependency, and that is surfaced, not hidden.
- **One job.**
  - `SearchHandler` resolves.
  - PostHandler creates from cached data.
  - `DeliverHandler` delivers, including resolving its target inbox.
  - InboxHandler keeps its caches current.
- **Blast radius.** One repository. The only new external surface is the phase 2 route.

## Testing

Every test includes a negative control, and each must be seen going red with its capability
removed before it counts.

### Unit (`Tests/ActivityPubCoreTests`, Swift Testing)

**Phase 1**
- **`buildNoteJSON`** emits `inReplyTo` when `inReplyToId` is set.
  - Negative controls: `nil`, and a legacy `inReplyTo` without `inReplyToId`, emit no key.
- **The resolver** returns `none`, `resolved` or `notFound`.
  - Negative control: a lookup returning nil gives `notFound`.
- **`cappedReplyVisibility`** covers all nine pairs.
  - Negative control: `public` under `private` gives `private`.
- **`buildStatusResponse`** returns the stored ids.
  - Negative control: a non-reply gives `null`.

**Phase 2**
- **The `REF#` local pointer** resolves another actor's unlisted status.
  - Negative controls:
    - Another actor's **private** status gives `notFound`, both in the resolver and in search.
    - A bare ULID with no pointer gives `notFound`.
- **Carry-over.**
  - A self-reply to a reply to *R* yields *R*.
  - Negative control: a reply to someone else's reply yields that someone.
- **Followers union** is *P*'s followers.
  - Negative controls: a carried-over self-reply unions nothing, and a private reply unions
    nothing.
- **Mention.**
  - A direct reply to *R* has a Mention tag, the h-card HTML and *R* in `cc`.
  - Negative controls:
    - A carried-over self-reply has *R* in `cc`, but **no** Mention tag and **no** HTML.
    - A plain self-thread has none of these.
- **Mention dedup.**
  - Text starting `@R@domain hi` renders the mention exactly once.
  - Negative control: text with `@R` mid-sentence still gets the prepended mention.
- **`replyAudience`** includes *P*'s followers and *R*.
  - Negative control: the audience of a non-reply is followers only.

**Phase 3**
- **Remote id derivation** is stable across calls, and is 26 characters of Crockford base32.
  - Negative control: two URIs differing by one character give different ids.
- **`signGet`** produces exactly `(request-target): get {path}?{query}\nhost: …\ndate: …`, and it
  verifies.
  - Negative controls: a missing query string fails, and a tampered path fails.
- **Fetch hardening:**
  - 3 redirects pass, and a 4th fails.
  - An `https`→`http` hop fails.
  - Redirects to `127.0.0.1`, `169.254.169.254` and `10.0.0.1` fail.
  - A body over 1 MB fails.
  - A `text/html` response fails.
  - A slow drip fails at the deadline.
  - Negative control: a compliant response passes.
- **Remote validation:**
  - An `id` mismatch, an `attributedTo` host mismatch, a `Tombstone`, an unsupported type, and an
    actor `id` ≠ `attributedTo` each fail.
  - A web URL yields the canonical id.
  - Negative control: a valid `Page` resolves.
- **Visibility derivation** gives the four outcomes, with all three public spellings and
  string-valued `to`/`cc`.
  - Negative control: a parent addressed to a person only is `direct`, and is left out of the
    results.
- **Cache.**
  - Delete and Update invalidate or refresh only when the origins match.
  - Negative control: a Delete from a different host leaves the entry in place.
- **LD signature.**
  - **The canonicalizer** reproduces the committed Mastodon-generated N-Quads and hashes byte for
    byte. It also passes the W3C RDFC-1.0 tests.
    - Negative control: changing one character of `content` changes `document_hash`.
  - **The signed fixture** verifies with an independent RSA-SHA256 check over
    `options_hash + document_hash`.
    - Negative control: dropping the `@context` alignment for `quoteUri` makes a Mastodon-style
      compaction-safety check (a port of `safe_for_forwarding?`) fail.
  - **The document loader** refuses any URL outside the three bundled contexts.
    - Negative control: a document with an extra remote context fails to sign, and the Create is
      sent unsigned.

### Schema conformance (`integration-tests/Tests/IntegrationTests/SchemaConformanceTests.swift`)

Commit fixtures next to `Fixtures/outbox-page.json`, and decode them through the generated types:
- `status-reply.json` and `status-legacy.json`, through `Components.Schemas.Status`.
  Negative control: marking `in_reply_to_account_id` `required:` makes the legacy fixture fail.
- `search-results.json`, through `SearchResults`.

### Integration (`integration-tests/`, on stage, generated `APIClient`)

These tests use `TEST_CLIENT_API_URL` / `TEST_BEARER_TOKEN`, and posts are `unlisted`.

**Phase 1**
- A round trip, an unknown parent (`.notFound` vs `.ok`), the visibility cap, and a chain of
  three, as in §1.

**Phase 2** (needs a second stage actor and token)
- A searches B's unlisted status URL, gets B's ULID, and replies.
- The response carries the parent id and B. The Note has the Mention, the h-card and `cc` B, and
  B's count rises by 1.
- Negative controls:
  - Searching B's **private** status returns no statuses, and replying with its ULID gets
    `.notFound`.
  - Search without a token gets 401.

**Phase 3**
- Search a public status on a test instance, then reply with the returned id.
- The response has the remote id. The Note has the Mention, the h-card and `cc` *R*.
- Negative controls:
  - Searching a URL that returns 404 gives empty `statuses`.
  - Replying with an unknown id gives `.notFound`.

### Federation (manual, against stage)

- **BrowserPub** (https://browse.activitypub.dev).
  - Load the last reply. It renders "in reply to" its parent and walks up to the root.
  - BrowserPub doesn't cache failures, so it is the first check.
- **Mastodon, phases 1 and 2.**
  - Use an instance account that follows the stage actor. Acceptance: `/context` for the last post
    lists the others as `ancestors`, in order.
- **Mastodon, phase 3, reply.**
  - The test account *R* gets a mention notification.
  - `/context` of the parent on *R*'s instance lists FAP's reply.
  - Repeat against a secure-mode instance.
  - Negative control: with signing disabled, the secure-mode instance refuses the fetch, and
    search returns nothing.
- **Mastodon, phase 3, forwarding.**
  - Set up an account *F* on a **second** instance. *F* follows *R* but not the stage actor.
  - The stage actor posts a public reply to *R*'s public post.
  - **Acceptance:** *F*'s instance has FAP's reply. Search on *F*'s instance with `resolve=false`
    for the reply URI returns it, and it appears in *F*'s home timeline.
  - **Negative control:** the same procedure with LD signing disabled (or `quoteUri` misaligned)
    leaves *F*'s instance without the reply.
- **Delete and Update reach.** Run the quote-accept `Update` of a quoting reply to *R*, and
  confirm *R*'s instance receives it.
  - Negative control: the pre-change build sends it to followers only.
- **Mastodon caching.** Mastodon caches discovery failures for hours, so retry on another instance
  before debugging FAP.
- **Before/after control.** Run each procedure on the pre-change build and record the absence.

### Build gate

- Build every target for Linux with `swift package archive --allow-network-connections docker`.
  The deployed binary is the Linux build, and a macOS `swift build` doesn't catch Linux-only
  compile errors.
- Build the generated consumers against the branch's `openapi.yaml`.

## Unverified

- **Swift JSON-LD / URDNA2015.**
  - Whether `swift-jsonld` implements `toRdf` and a custom document loader.
  - Whether either Kingpin package passes the W3C suites.
  - Whether either is maintained beyond its first months.

  None of this is established. That is why it is Open Question 1.
- **`rdf-normalize` 0.7.0 output.** Whether its `:normalize` output is identical to RDFC-1.0 for
  FAP's documents is unverified. The committed reference fixtures in §3.6 settle it.
- **Mastodon's preloaded contexts.** Whether `json-ld-preloaded` 3.3.2 bundles all three contexts
  (activitystreams, security/v1, identity/v1) is unverified. If it doesn't, Mastodon fetches and
  caches the missing ones for 30 days (`json_ld_helper.rb:388-402`), which still verifies.
- **The `https://w3id.org/identity/v1` document.** Its current availability and content hash are
  unverified. It is fetched once at implementation time and committed.
- **The HTTP client for per-connection address checks.** No client has been chosen. `URLSession`
  and FoundationNetworking expose no connected-address hook, and `Package.resolved` isn't committed.
- **Duplicate delivery.** Whether receivers deduplicate a Create delivered twice to one shared
  inbox is inferred, not measured.
- **Secure-mode acceptance of a regular actor key.** The source has been read
  (`signature_verification.rb:45` onward). A live measurement is pending, and the phase 3
  secure-mode check is that measurement.
- **Mastodon internals.**
  - The `items_context_url` path shape.
  - A read of `context` on intake.
  - The web composer's handling of the author's own `@handle`.
  - The `replies_count` "added" version.

  None of these is relied on.
- **Forcing out-of-order delivery** for the manual check. No mechanism has been identified.

## Decisions (2026-10-20)

Erin decided the following on 2026-10-20.

1. **Scope: all replies.** Self, other local actors and remote statuses, in phases 1–3, each
   shippable on its own.
2. **`replies` collection:** a follow-up, not part of any phase.
3. **`context` / `conversation`:** not now. Revisit when a context FEP reaches FINAL.
4. **Profile page:** posts stay separate, and each post page gets "In reply to" (§1.8).
5. **Server-side length check:** tracked separately in FederatedActivityPublisher#272.
6. **Visibility cap:** it applies to local parents while #270 is open, and is lifted once #270 is
   fixed (§1.2 step 5).
7. **Ids:** FAP-local ids plus search, as Mastodon does. URIs aren't accepted as ids. This drives
   §2.1–2.4 and §3.1–3.4.
8. **Visible mention:** prepend a linked `@user@domain` in Mastodon's h-card shape to direct
   replies to others, never to self-replies, and without duplicating a leading mention already in
   the text (§2.5).
9. **Unreachable remote parent:** refused with 404 (§3.4).
10. **Linked Data Signatures** are part of phase 3, so Mastodon forwards replies to the parent
    author's followers (§3.6).
11. **Carried-over self-reply:** `cc` only, no Mention (§2.5, §3.5).
12. **Delete and Update reach:** they go to the parent author and the followers union, through
    `replyAudience`. This applies to the quote-accept Update now, and to any future delete or edit
    (§2.6, §3.5).

## Open questions

1. **LD-signature canonicalization: adopt or build?**
   - No maintained, conformance-verified Swift JSON-LD + URDNA2015 stack exists.
   - **Option A.** Adopt `Kingpin-Apps/swift-jsonld` 0.1.3 and `swift-rdf-canonize` 0.2.2. Both
     are MIT and pure Swift, and list Linux. They are pinned, and adoption is gated on the W3C
     suites and the Mastodon-generated fixtures in §3.6. The risk is young, single-author
     dependencies on a signing path.
   - **Option B.** Build a narrow canonicalizer in ActivityPubCore:
     - a JSON-LD `toRdf` for the closed set of terms and shapes FAP emits, with the three bundled
       contexts
     - URDNA2015 over the resulting quads

     It is gated the same way. The cost is a substantial module that FAP owns. The benefit is no
     third-party code on the signing path.
   - Proposed: try Option A first against the gate. Fall back to B if either package fails the
     suites or the fixtures.
2. **HTTP client for the fetch hardening.**
   - The per-connection address check needs a client that exposes or controls the connected
     address. `URLSession` doesn't.
   - Which client should be used, and is a new package dependency acceptable for it?
   - Proposed: decide in the phase 3 implementation plan, after checking the resolved dependency
     graph, and name the dependency there.
