# Reply Threading — Design Spec

## Goal

Let a local actor publish a reply to any status it can see: its own, another local actor's, or a
remote one. Each reply federates with a correct `inReplyTo`, reaches the parent's author, and is
reported through the Mastodon-compatible client API with Mastodon-style ids.

The motivating case is a bot that posts a long daily summary. When the summary exceeds the
5,000-character status limit, the bot splits it into a root post and a chain of self-replies.

Today FAP accepts `in_reply_to_id` on create but never federates it, so a "thread" arrives at
remote servers as N unrelated posts.

## Sequence

The work ships as six changes, in order. Each can be released on its own.

| Step | Change | Depends on | New components (full list in each section) |
|---|---|---|---|
| 0 | **Fetch hardening**, a security change to the existing shared fetch | — | None. Scheme, redirect, body, content-type, status and deadline controls on `fetchRemoteObject`. |
| 0b | **Generated fetch client and transport** (decision 14) | 0, Open question 1 | A FAP-authored OpenAPI document, a generated client target, a FAP-written `ClientTransport` that owns redirects, per-hop checks and re-signing, the body cap, the deadline and the per-connection address check |
| 1 | Self-replies | — | None |
| 2 | Replies to other local actors | 1 | `SearchHandler` Lambda; `GET /api/v2/search` route and CloudFront behaviour; `REF#` item type |
| 3a | Replies to remote statuses, delivered unsigned | 0b, 2 | Remote resolve in `SearchHandler`; remote `REF#` entries; `signGet`; actor-URI delivery in `DeliverHandler` |
| 3b | Linked Data Signatures on remote replies | 3a | LD signing in ActivityPubCore: FAP-owned canonicalization with vendored, credited reference code (decision 13), and `@context` alignment |

**Why step 0 goes first.** The quote path already sends client-supplied URIs to `fetchRemoteObject`
with no scheme check, unlimited redirects and no body cap (`FetchRemoteObject.swift:37-45`;
`PostHandler/main.swift:252,264`). That exposure exists today and depends on nothing in the reply
work.

**Why 3a waits for 0b.** Phase 3a adds a new way for an authenticated user to make the server fetch
an arbitrary URL (`resolve=true` search, §3.3) and adds signed actor fetches in `DeliverHandler`
(§3.5). Without the address check, search adds a path to loopback and link-local addresses that
a signed-in user controls directly and whose result is returned to that user. Steps 1 and 2 don't
fetch remote URLs and don't wait.

**Why 3b goes last.** Delivery degrades to unsigned when signing fails (§3.6). Remote replies
therefore work without 3b. Only forwarding to the parent author's followers waits for it.

**Out of scope (decided, see "Decisions"):**
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

- **ActivityPub defines no `replies` side effect.** §3 and §5 never define a replies collection.
  FEP-7458: "Replies are not defined in ActivityPub, as there are no specified side effects for
  simply *encountering* objects or activities with `inReplyTo` set."
- **§6.2 Create Activity (C2S):** "the actor of the activity SHOULD be copied onto the object's
  attributedTo field" and "a server SHOULD copy any recipients of the Create activity to its
  object". FAP already gives the Create and the Note identical `to`/`cc`
  (`Sources/ActivityPubCore/Models/Note.swift:28-29,123-124`).
- **§7.2 Create Activity (S2S):** "Receiving a Create activity in an inbox has surprisingly few
  side effects".
- **§7.1.2 Forwarding from Inbox:** forwarding requires three things:
  - the activity hasn't been seen before
  - `to`/`cc`/`audience` contain "a Collection owned by the server"
  - the "`inReplyTo`, `object`, `target` and/or `tag` are objects owned by the server"

  A FAP reply addresses the parent author's *actor*, not a collection that author's server owns,
  so §7.1.2 doesn't trigger. Mastodon forwards on its own rule (see "How Mastodon forwards").
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

**Signature verifier:**
- `verify_signature_strength!` (`app/lib/signed_request.rb:54-57`) requires these on a GET:
  - `date` or `(created)`
  - `(request-target)` or `digest`
  - `host`
- `(request-target)` is compared against `original_fullpath`, which includes the query string
  (`signed_request.rb:113`).
- Secure mode requires a signature on status JSON (`app/controllers/statuses_controller.rb:11`).
- `signed_request_account` (`app/controllers/concerns/signature_verification.rb:45` onward) accepts
  any account whose key verifies.

**What Mastodon emits:**
- `inReplyTo` is the parent's URI (`note_serializer.rb:99-107`).
- Mention tags are `{type: "Mention", href: <account URI>, name: "@acct"}` (`note_serializer.rb:333`
  onward).
- **`to`** (`app/lib/activitypub/tag_manager.rb:171-196`): public is `[as:Public]`; unlisted and
  private are `[author followers]`.
- **`cc`** (`tag_manager.rb:203-235`): public adds followers, unlisted adds `as:Public`, and
  mentioned accounts are appended for all but direct and limited (`:215,228`).
- All three public spellings are recognised: the full IRI, `as:Public` and `Public`
  (`tag_manager.rb:14-15`).
- Mentions come only from the status text (`app/services/process_mentions_service.rb:25-26`).
- **Mention HTML.** `link_to_mention` (`app/lib/text_formatter.rb:80-87`) renders:

  ```html
  <span class="h-card" translate="no"><a href="#{h(url)}" class="u-url mention">@<span>#{h(display_username)}</span></a></span>
  ```

  - `url` is `TagManager#url_for(account)`. For a remote account, it is `nil` unless the URL's
    scheme is `http` or `https` (`tag_manager.rb:18-19`; `unsupported_uri_scheme?`,
    `app/helpers/json_ld_helper.rb:95-97`).
  - Both values are HTML-escaped with `h()`.
  - `display_username` is `pretty_acct` when `with_domain` is set. `pretty_acct` is
    `username@domain`, where `domain` is the account's WebFinger domain (`app/models/account.rb:249-254`).

**Who Mastodon delivers to** (`app/lib/status_reach_finder.rb`):
- Inboxes are reached accounts, plus followers, plus relays (`:12-13`).
- Reached accounts include:
  - `replied_to_account_id` (`:31`), which is reached only `if distributable?` (`:47-48`)
  - mentioned accounts (`:34`)
  - `replies_account_ids` (`:38,79-81`)
- The direct parent's followers are reached too, when that parent's author is local (`:105-106`;
  `app/models/status.rb:210-212`).
- Create and Update are distributed with `StatusReachFinder`
  (`app/workers/activitypub/distribution_worker.rb:22-23`; `status_update_distribution_worker.rb:3`).
- Delete uses `StatusReachFinder.new(@status, unsafe: true)` (`app/services/remove_status_service.rb:92-106`).
  So Mastodon delivers a status's Delete and Update to every account that replied to it.

**How Mastodon forwards:**
- **The forwarding condition.** `forward_for_reply` runs only when
  `@status.distributable? && @json['signature'].present? && reply_to_local?`
  (`app/lib/activitypub/activity/create.rb:491-495`).
- **Signature on receipt.** `@json = compact(@json) if @json['signature'].is_a?(Hash)`
  (`app/services/activitypub/process_activity_service.rb:24`).
  - The signature is kept only if `safe_for_forwarding?` holds after `patch_for_forwarding!`
    (`:59-66`; `json_ld_helper.rb:184-235`).
  - That requires every original key to survive compaction against `full_context`
    (`json_ld_helper.rb:125-129`; `app/helpers/context_helper.rb:75-76`).
- **Verification.** Forward recipients verify the LD signature (`process_activity_service.rb:36-48,89-94`).
- **Acceptance.** A forwarded copy is accepted where a local account follows the replied-to
  account (`create.rb:464-479`).

**Linked Data Signature** (`app/lib/activitypub/linked_data_signature.rb`):
- **`sign!`** (`:39-62`):
  - **Options:** `{type: "RsaSignature2017", creator, created, expires: now + 2 days}`.
  - **Options hash:** `options_hash = SHA256hex(canonicalize(options − type − id − signatureValue
    + {"@context": "https://w3id.org/identity/v1"}))`.
  - **Document hash:** `document_hash = SHA256hex(canonicalize(document − signature))`.
  - **Signature:** `signatureValue = base64(RSA-SHA256(options_hash + document_hash))`.
  - **Context:** `https://w3id.org/security/v1` is appended to `@context` and `uniq!`ed
    (`:56-59`), so it is a no-op when already present.
- **`verify_actor!`** (`:12-37`):
  - It rejects `@graph`, `@included` and `@reverse` (`json_ld_helper.rb:6,155-161`).
  - It requires `type == "RsaSignature2017"`.
  - It rejects an `expires` in the past *if one is present* (`:22`). `expires` isn't required.
- **Canonicalization:** `RDF::Graph.new << JSON::LD::API.toRdf(json, documentLoader: …)`, dumped
  as `:normalize` (`json_ld_helper.rb:120-123`).
  - Gem versions: `json-ld` 3.3.2, `json-ld-preloaded` 3.3.2, `rdf-normalize` 0.7.0
    (`Gemfile:101-103`; `Gemfile.lock:369,377,709`).
  - `rdf-normalize` 0.7.0 defaults to RDFC-1.0: `options.fetch(:algorithm, :rdfc10)`
    (`ruby-rdf/rdf-normalize@0.7.0`, `lib/rdf/normalize.rb:62`).
- **Contexts used in signing:**
  - Mastodon ships `identity/v1` and `security/v1` as preloaded term definitions:
    - `config/initializers/json_ld_identity.rb:5` ("generated automatically from
      http://w3id.org/identity/v1"), aliased to `https` at `:85`
    - `config/initializers/json_ld_security.rb:5`, aliased at `:49`
  - `json-ld-preloaded` provides `activitystreams` (`ruby-rdf/json-ld-preloaded`,
    `lib/json/ld/preloaded/activitystreams.rb:6`).
  - `load_jsonld_context` (`json_ld_helper.rb:388-402`) fetches other contexts and caches them
    for 30 days.
- **The live URL is dead.** `https://w3id.org/identity/v1` redirects to
  `web-payments.org/contexts/identity-v1.jsonld`, which refused connections on 2026-10-20.

**Inbound Create dedup.**
- `create_status` holds a lock on `create:#{object_uri}` (`create.rb:30`), and returns when
  `find_existing_status` finds the object URI (`:95-99`).
- So a second delivery of the same Note to one server is dropped.

**Who may reply.**
- `set_thread` authorizes `show?` and gives a 404 when that fails
  (`app/controllers/api/v1/statuses_controller.rb:106-111`).
- A private status is visible to `owned? || following_author? || mention_exists?`
  (`app/policies/status_policy.rb:9-10`).

**What Mastodon does on create.**
- **Visibility** is overridden only for silenced accounts and private quotes
  (`app/services/post_status_service.rb:85-87`).
- **`replies_count`** counts only distributable replies (`status.rb:484`).
- **`in_reply_to_account_id`** follows `carried_over_reply_to_account_id` (`status.rb:461-466`).
- **Conversation.** A reply joins its parent's conversation (`status.rb:449`).

**Remote edits never change visibility.** `app/services/activitypub/process_status_update_service.rb`
contains no `visibility` handling.

**What Mastodon consumes.**
- `inReplyTo` (`create.rb:440-447`), with `ThreadResolveWorker` for unknown parents (`:382-386`).
- Mentions by `href` (`create.rb:255-263`).
- Visibility from the audience (`app/lib/activitypub/parser/status_parser.rb:101-111`).

**How Mastodon fetches.**
- `fetch_resource` requires `json['id'] == uri` (`json_ld_helper.rb:242-252`).
- **Response checks:** status 200 and an AP content type (`:281,351` onward), a 1 MB body
  (`app/lib/request.rb:293-294`), and at most 3 redirect hops (`:101-102`).
- Each request it sends is signed (`:72-75`).
- Private addresses are rejected per connection (`:325-334,389-394`).
- **Attribution:** `trustworthy_attribution?` (`app/services/activitypub/fetch_remote_status_service.rb:61-66`),
  with `attributedTo` read through `value_or_id(first_of_value(...))` (`:29`).
- **Types:** `Note` and `Question` are supported, and `Image`, `Audio`, `Video`, `Article`, `Page`
  and `Event` are converted (`app/lib/activitypub/activity.rb:9-10`).
- **Actors:** the `id` must equal the requested URI (`fetch_remote_actor_service.rb:16`).

**Search and URL resolution.**
- **Docs** (https://docs.joinmastodon.org/methods/search/):
  - `GET /api/v2/search` with `q` an HTTPS URL and `resolve=true` attempts "resolving the URL and
    returning the matching status".
  - With `resolve=false`, "this resolving logic is circumvented and a regular search is performed
    instead".
  - `resolve` requires a user token.
- **Controller:** an unauthenticated resolve gets a 401 (`app/controllers/api/v2/search_controller.rb:12-14,37-38`),
  and results are capped at `RESULTS_LIMIT = 20` (`:7`).
- **`ResolveURLService`:**
  - A local URL is resolved from the database (`app/services/resolve_url_service.rb:13-14,93`).
  - A remote one goes through `FetchRemoteStatusService` (`:28`).
  - Either way the result must pass `authorize_with @on_behalf_of, status, :show?` (`:29,59`).

**Client API and feeds.**
- `in_reply_to_id` and `in_reply_to_account_id` are nullable strings, "cast from an integer but not
  guaranteed to be a number" (https://docs.joinmastodon.org/entities/Status/).
- A reply whose parent is unresolved is filtered from home feeds (`app/lib/feed_manager.rb:505`),
  and self-replies are kept (`:524`).
- Late-parent re-distribution is gated on the 6 h window (`thread_resolve_worker.rb:21`;
  `status.rb:188,218-220`).

### Platform limits

- **API Gateway REST integration timeout:** "50 milliseconds - 29 seconds for all integration
  types, including Lambda"
  (https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-execution-service-limits-table.html).
- **`URLRequest.timeoutInterval` is an idle timeout:** "If during a connection attempt the request
  remains idle for longer than the timeout interval, the request is considered to have timed out"
  (https://developer.apple.com/documentation/foundation/nsurlrequest/timeoutinterval).

### Swift JSON-LD and RDF canonicalization

Code on the signing path must be code FAP owns, or a dependency the maintainer has vetted and
approved explicitly. Candidate packages found by searching package indexes are not evidence. A
project's own README and CI results are statements from the party being evaluated, so they don't
count as vetting.

The maintainer has vetted two packages on the strength of their authors (2026-10-20). Both were
read from their repository pages only, and their scope comes from their own READMEs, so it is
unverified until FAP's gate runs:

- **`mattmassicotte/JSONLD`** (BSD-3-Clause, no tagged releases).
  - Codable decoding and encoding of JSON-LD documents, centred on `@context` (`ContextOnlyDocument`).
  - Its README does not mention expansion, compaction, `toRdf`, canonicalization or document
    loaders.
- **`1amageek/swift-knowledge-graph`** (MIT, no tagged releases, no third-party dependencies).
  - A JSON-LD 1.1 parser that "implements the toRdf algorithm and is exercised against the W3C
    `toRdf` test suite", plus N-Quads and other RDF parsers.
  - Unsupported features are rejected with `ParserError.unsupportedFeature`, including scoped
    contexts and term-driven container maps.
  - Its README does not mention canonicalization, compaction, document loaders or Linux.

Neither package provides RDFC-1.0, so FAP writes its own (decision 13).

**Gaps that apply to any vendored file put to use** [inferred]. These are checked by the §3.6 gate:
- **Container definitions.** The Note `@context` FAP emits, and Mastodon's `full_context`, contain
  container definitions (`focalPoint` with `@container: @list`). A parser that rejects
  term-driven container maps may reject exactly the documents FAP signs.
- **Context loading.** Contexts must load from bundled copies with no network access.
- **Linux.** The deployed binary is a Linux build, and neither README states Linux support.

## Current FAP behaviour

Verified by reading the code at `8a78008`.

**Create path.**
- `CreateStatusRequest.inReplyToId` decodes `in_reply_to_id` (`CreateStatusRequest.swift:27,38`).
- `PostHandler` copies it verbatim into `Status.inReplyTo` (`PostHandler/main.swift:310`). An
  unknown value returns 200.
- **The quote path** looks up `quoted_status_id` in the caller's partition only (`:252`). Anything
  else goes to `fetchRemoteObject` (`:259,264`), and an unresolvable inbox marks the quote
  `failed` (`:282-287`).

**Model and storage.**
- `Status.inReplyTo` is documented as a URI (`Status.swift:47-48`).
- `repliesCount` is documented as remote-only (`:53-54`).
- `tags` exists (`:44`; `Tag` at `:267-273`). PostHandler writes `tags: nil` (`main.swift:308`).
- Statuses are keyed `ACTOR#{username}` / `STATUS#{ulid}` (`Status.swift:216-221`). There is no
  index on `inReplyTo` or on a bare id.
- `REMOTE_ACTOR#{actorUri}` has a 24 h TTL (`DynamoDBStore.swift:593-630`). It is the
  inbound-signature trust anchor (`KeyManager.swift:41-42`), and today only `KeyManager` writes it.

**Outbound Note.**
- `buildNoteJSON` (`Note.swift:23-109`) emits no `inReplyTo`. It does serialize `tags`
  (`:62-72`).
- It has four callers:
  - delivery (`PostHandler/main.swift:325`)
  - the object endpoint (`ObjectHandler/main.swift:74`)
  - the outbox (`OutboxHandler/main.swift:80`)
  - the quote-accept `Update` (`InboxHandler/main.swift:1285`), which goes to followers only
- `FederationOverview.md:15` claims "reply metadata", which is false at `8a78008`.
- **The Note `@context`** (`Note.swift:106`) maps `quoteUri` to `toot:quoteUri`, where Mastodon
  uses fedibird (`context_helper.rb:39`).
  - It also emits `_misskey_quote` (`:98`) and `interactionPolicy`/`canQuote`/`automaticApproval`
    (`:103`) without defining them. Mastodon defines all of them (`context_helper.rb:40,43-48`).
  - The Create's `@context` is the bare AS URL (`:127`).

**Addressing.** `computeAddressing` (`Note.swift:146-165`) gives public `[Public]`/`[followers]`,
unlisted `[followers]`/`[Public]`, and private `[followers]`/`[]`.

**Delivery.**
- One `DeliveryJob {targetInbox, activityJSON, actorUsername}` is enqueued per distinct follower
  shared inbox (`PostHandler/main.swift:332-352`).
- `DeliverHandler` reads `{SSM_KEY_PREFIX}/{username}` (`DeliverHandler/main.swift:52-58`), signs
  and POSTs (`:79-94`).
- `DeliverFunction` has DynamoDB *read* and SSM read of `activity/${Stage}/keys/*`
  (`functions/template.yaml:446-453`).
- The queue allows 3 receives (`activity-environment/template.yaml:87`).

**Fetching and signing.**
- `HTTPSignature.sign` is POST-only (`HTTPSignature.swift:112-133`). Its signing string comes from
  `buildSigningString` (`:181-190`).
- `fetchRemoteObject` (`FetchRemoteObject.swift:36-58`):
  - It accepts any URL `URL(string:)` parses, including `http://` and any host (`:37-39`).
  - It uses `URLSession.shared`, which follows redirects (`:45`).
  - Its timeout is idle-only, and it has no body cap or content-type check.
- `KeyManager.fetchActorDocument` fetches with `URLSession.shared` directly, not through
  `fetchRemoteObject`, unsigned (`KeyManager.swift:68-77`), and parses at `:89-105`. Its URI comes
  from the `keyId` of an inbound `Signature` header (`InboxHandler/main.swift:115,125,153`).
- `DeliverHandler` POSTs to stored inbox URLs with `URLSession.shared` (`DeliverHandler/main.swift:98`).
- The PostHandler session key lives under the keys prefix: `"\(ssmKeyPrefix)/session-signing-key"`
  (`PostHandler/main.swift:51-52`).

**Infrastructure.**
- `PostFunction` reads SSM `activity/${Stage}/*` (`functions/template.yaml:122-140`).
- `InboxFunction` has DynamoDB CRUD and SQS only (`:429-433`).
- `ClientApi` is a REST API with no timeout override (`:111-120`), so 29 s applies.
- No function has a `VpcConfig`.
- The CloudFront default behaviour targets the ActivityPub API origin (`cdn/template.yaml:312-313`).
  Client paths each have their own `ClientApiGateway` behaviour (`:340-346`).
- No FAP source target uses SwiftPM resources. There is no `Bundle.module` in `Sources/`.

**Other.**
- FAP actors follow no one (`FollowingHandler/main.swift:8`).
- The local account id is the username (`VerifyCredentialsHandler/main.swift:131`).
- The actor `url` is `https://{serverDomain}/@{username}` (`ActorSerializer.swift:60`).
- `ObjectHandler` serves any visibility on `activity+json` (`:74-84`). That is
  FederatedActivityPublisher#270.
- **Inbound replies:**
  - `handleCreate` drops non-`Note` objects (`InboxHandler/main.swift:747`) and non-local
    `inReplyTo` (`:756-772`).
  - It stores and counts `REPLY#` items (`:808-810`).
  - `handleDelete` (`:987` onward) removes stored replies (`:1053-1059`).
  - Update of a reply uses the inbox owner's partition (`:884-885`).
  - The quote-accept origin check is at `:1257-1265`.

## Step 0 — Fetch hardening (security)

Every control is added inside `fetchRemoteObject`. `KeyManager.fetchActorDocument` moves onto
`fetchRemoteObject` in the same change, keeping its parser (`KeyManager.swift:89-105`), so every
remote GET is covered: the quote path, inbox object fetches and key fetches. Delivery POSTs from
`DeliverHandler` are not fetches and are outside this spec; their address check is tracked
separately (FederatedActivityPublisher#277). These requirements match Mastodon's `Request` and `fetch_resource`:

| Control | Requirement | Reference |
|---|---|---|
| Scheme | `https` on the initial URI and every hop | Stricter than Mastodon, which allows `http` (`json_ld_helper.rb:95-97`) |
| Redirects | At most 3 hops, validated per hop. With a signer (§3.2), each hop is re-signed. | `request.rb:101-102,72-75` |
| Body | 1 MB cap. Abort the read past it. | `request.rb:293-294` |
| Content type | `application/activity+json`, or `application/ld+json` with the AS profile | `json_ld_helper.rb:281,351` onward |
| Status | Only 200 counts as success | `json_ld_helper.rb:281` |
| Deadline | An absolute deadline from the caller, enforced even while bytes keep arriving | Platform limits |
| Address | Reject loopback, private (RFC 1918 / ULA), link-local and unspecified addresses on every connection, applied to the address actually connected to | `request.rb:325-334,389-394`. **Ships in step 0b, with the transport (Open question 1).** |

- **Ships first.** Every control except the address check ships first, on the existing
  `URLSession` fetch (`FetchRemoteObject.swift:36-58`).
  - The body cap, deadline and per-hop checks need the response delivered incrementally and
    redirects surfaced to FAP code: a delegate-based data task with
    `urlSession(_:dataTask:didReceive:)` and
    `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`, not
    `data(for:)`. In `swift-corelibs-foundation`, both callbacks fire only when a delegate is
    attached: `HTTPURLProtocol.redirectFor(request:)` asks the task delegate and otherwise follows
    up to 20 redirects itself, and `NativeProtocol.notifyDelegate(aboutReceivedData:)` calls
    `didReceive` only for delegate-backed tasks (`Sources/FoundationNetworking/URLSession/`). The
    Step 0 tests on Linux are the measurement.
  - Step 0b moves these controls into the FAP-written transport. The step 0 tests carry over and
    must pass on both, with the test address policy added so the plain-http test server stays
    reachable; 0b adds the TLS and address tests (Testing).
- **Quote-path behaviour change.** A `quoted_status_id` that is `http://`, redirects too often,
  is oversize or has a non-AP type now fails. The quote is then marked `failed`, through the
  existing path (`PostHandler/main.swift:282-287`).
- **Inbound key-fetch behaviour change.** Verifying an inbound signature now fetches the key
  through `fetchRemoteObject`: only status 200 and the two ActivityStreams content types are
  accepted, with at most 3 redirects and a 1 MB cap. The deadline is an absolute 10 seconds.
  Today's 10 seconds (`KeyManager.swift:75`) is an idle timeout, so a slow response that keeps
  sending bytes now fails where it used to succeed. A remote server whose actor document
  fails these checks can no longer deliver to FAP.
- **Release notes:** both behaviour changes.
- **Tests:** these are the Step 0 tests listed under Testing.
- **Components:** none. `fetchRemoteObject` changes, and `KeyManager.fetchActorDocument` moves
  onto it.

## Phase 1 — Self-replies

### 1.1 Shared helpers move to ActivityPubCore

- Move `parseStatusUri` (`InboxHandler/main.swift:1114`) into ActivityPubCore as
  `parseLocalStatusUri(_:serverDomain:handleDomain:)`. Behaviour is unchanged.
- Add `isLocalHost(_:)`, which is true when a URI's host is `serverDomain` or `handleDomain`.

### 1.2 Resolve and validate `in_reply_to_id`

Insert this step between visibility validation and addressing, before anything is written:

1. If `in_reply_to_id` is absent or empty, the status is not a reply.
2. Otherwise call `store.getStatus(username: <author>, id: in_reply_to_id, consistentRead: true)`.
   InboxHandler already reads this way after a write (`InboxHandler/main.swift:1284`).
3. If nothing is found, return **404** `{"error":"Status to reply to not found"}` and write
   nothing, as Mastodon does. Phases 2 and 3 widen what resolves.
4. If found, set:
   - `inReplyTo = parent.uri`, which equals the Note `id` (`PostHandler/main.swift:293`;
     `Note.swift:25`)
   - `inReplyToId = parent.id`
   - `inReplyToAccountId = parent.username`
   - `inReplyToAccountUri = https://{serverDomain}/users/{username}`
5. **Cap the visibility while FederatedActivityPublisher#270 is open.**
   - If the request ranks above the parent's visibility (`public` > `unlisted` > `private`),
     downgrade the reply to the parent's visibility before `computeAddressing`. This follows
     Mastodon's quote downgrade (`post_status_service.rb:87`). The response reports the effective
     value.
   - **The cap is removed once #270 is fixed, to match Mastodon** (`post_status_service.rb:85-87`).
     Decided 2026-10-20.
   - The cap applies only to local parents.

### 1.3 Storage

A reply item gains three optional `Status` attributes. Only the resolver writes them, and always
together with `inReplyTo`:
- `inReplyToId`
- `inReplyToAccountId`
- `inReplyToAccountUri`

There is no index change.

**Legacy values are ignored.** A status counts as a reply only when `inReplyToId` is present. A
legacy `inReplyTo` without it is ignored. No legacy item has been observed. If one is, that is a
follow-up issue.

### 1.4 Emit `inReplyTo` on the Note

- `buildNoteJSON` emits `"inReplyTo":"<inReplyTo>"` when `inReplyToId` is present.
- All four callers pick it up, and `FederationOverview.md:15` becomes accurate.
- No `context` or `conversation` (decided). Mastodon puts the child in the parent's conversation
  (`status.rb:449`).

### 1.5 Addressing, mentions, delivery

- A self-reply uses `computeAddressing` with its capped visibility.
- It has no Mention tag and no mention HTML.
- Fan-out is unchanged.
- Out-of-order arrival is handled on the receiving side (`feed_manager.rb:505`;
  `thread_resolve_worker.rb:21`).

### 1.6 `repliesCount`

- **Gate.** Increment only for public or unlisted replies, the `distributable?` gate
  (`status.rb:484`).
- **Ordering.** Do it after the delivery enqueue.
- **Failure.** Log and swallow a failure, so a retrying bot can't fork the chain.
- **Doc comment.** Update `Status.swift:53`.
- **Page cache.** The post page's body already changes after publication, and its freshness is
  CloudFront's 300 s cap. Fixing its one-year header is separate.

### 1.7 Client API

- Move `buildStatusResponse` into ActivityPubCore.
- `in_reply_to_id` and `in_reply_to_account_id` come from the stored attributes. Both are `null`
  for a non-reply.
- **`openapi.yaml`:** add `in_reply_to_account_id` as **optional, nullable**, and a `"404"`
  response on `createStatus`.
- **Consumer build.** The implementation PR builds the generated consumers against the branch
  before merge: the `integration-tests` `APIClient` and the mirrored downstream client (review
  standards S11/S12).
- Promote `in_reply_to_account_id` to `required` once every deployed server emits it.
- **Release notes:** an unknown `in_reply_to_id` now gets 404 instead of 200, and the visibility
  cap applies.

### 1.8 Web view

- The post page shows "In reply to", linking to `https://{serverDomain}/@{username}/{parentId}`.
  Every interpolated value is HTML-attribute-escaped.
- The profile page is unchanged (decided).

### Phase 1 components

- **Added:** none. Two helpers move to ActivityPubCore, and a resolver, a cap function and three
  optional attributes are added.
- **Not added:** no handler, route, table, index, queue or workflow.

## Phase 2 — Replies to other local actors

### 2.1 Ids and search

**Ids work as on Mastodon: one FAP id per status, obtained through search.** A local status's
FAP id is its ULID, whoever owns it.

**The new endpoint is `GET /api/v2/search?q=<https URL>&resolve=true[&type=statuses]`.**
- **Auth.** Bearer or session auth is required. A missing token gets a 401, as in Mastodon
  (`search_controller.rb:12-14,37-38`).
- **`resolve=true` with an `https://` URL:**
  1. If `isLocalHost(q)`, accept the status URI or the web URL `/@{username}/{id}`.
  2. Load the status, and apply §2.2.
  3. Write the `REF#` pointer (§2.3), and return the status.

  This follows `ResolveURLService` (`resolve_url_service.rb:13-14,93`). Non-local URLs return
  empty results in phase 2, and phase 3 adds them.
- **Without `resolve=true`, or with a non-URL `q`:** empty results. Mastodon runs "a regular
  search" in that case, and FAP has no full-text search.
- **Response:** a Mastodon `Search` result, `{accounts: [], statuses: [Status…], hashtags: []}`.
  Statuses use FAP's existing `Status` schema. `type=accounts` and `type=hashtags` return empty
  lists.

### 2.2 Who may see and reply: Mastodon's `show?`

- A status that is `private` and owned by someone other than the caller is never returned by
  search, and never resolves as a parent (404).
- This is `show?` (`status_policy.rb:9-10`; `statuses_controller.rb:106-111`;
  `resolve_url_service.rb:29,59`).
- FAP actors follow no one, and FAP records no Mentions of a peer in the parent, so neither other
  `show?` condition can hold.
- This rule stays after #270 is fixed.

### 2.3 `REF#` item type

- **Item.** `PK=REF#{id}`, with an `SK` of `META` for a shared entry. It is a new item type in the
  existing table, like `MEDIA#`. There is no new table or index.
- **Local pointer.** `id` is the status's ULID, and the item is `{kind: "local", owner, uri}`.
- **When it is written.** Search writes it on resolution, with an idempotent conditional put. It
  has no TTL. A future delete-status feature must delete it.
- **How a client meets an id.** Local ULIDs are visible in public status URLs and on the web, so a
  client can have another actor's ULID without having searched. Such an id gets a 404 from
  `POST /api/v1/statuses` until a search writes its pointer. That avoids a backfill or an index.
  The release notes say so.

### 2.4 Resolving `in_reply_to_id`

1. Try the caller's partition (phase 1).
2. On a miss, `GetItem REF#{id}` / `META`.
3. For `kind == "local"`, `getStatus(owner, id, consistentRead: true)`, then apply §2.2.
4. A miss at any step gives a 404.

`in_reply_to_id` takes ids only (decision 7). A URL goes through search first.

**Carry-over** follows `carried_over_reply_to_account_id` (`status.rb:461-466`):
- If the parent is by the poster and has `inReplyToAccountId`, carry over its
  `inReplyToAccountId` and `inReplyToAccountUri`.
- Otherwise use the parent's author.

### 2.5 Addressing, Mention, delivery

Two accounts matter here:
- *P* is the direct parent's author.
- *R* is the account in `inReplyToAccountId`, when it isn't the poster.

**Direct reply to someone else (*P* ≠ poster, so *R* = *P*):**
- **Mention tag.** `Tag(type: "Mention", name: "@{R}@{handleDomain}", href: <R actor URI>)`.
- **Visible mention** (decision 8). Mastodon's `link_to_mention` shape with the full acct
  (`text_formatter.rb:80-87`) is prepended to the first `<p>`, followed by a space:

  ```html
  <span class="h-card" translate="no"><a href="{escaped url}" class="u-url mention">@<span>{escaped acct}</span></a></span>
  ```

  - **`url`** comes from §2.7.
  - **`acct`** is `R@handleDomain`. The handle domain is the local WebFinger domain, which is what
    `pretty_acct` uses (`account.rb:249-254`).
  - **No duplicate.** If the client text begins with `@{username}` followed by an optional
    `@{any domain}`, matched case-insensitively and followed by whitespace or the end of the text,
    that leading token is removed before conversion and replaced by the linked form. This covers
    `@R`, `@R@handleDomain` and `@R@serverDomain`.
- **`cc`.** *R* is appended for every visibility (`tag_manager.rb:215,228`).

**Carried-over self-reply (*P* = poster, *R* carried over).** Decided 2026-10-20 (decision 11):
- *R* goes in `cc`, with **no** Mention and **no** visible mention.
- **This goes beyond Mastodon for private replies, and FAP chooses it deliberately.** Mastodon
  reaches the replied-to account only for distributable replies (`status_reach_finder.rb:47-48`),
  and puts only mentioned accounts in `cc` (`tag_manager.rb:215,228`). So on Mastodon, *R* never
  receives a private self-continuation. On FAP, *R* is in `cc` at every visibility, and receives it.

**Delivery.**
- No HTTP delivery is made to a local *R*.
- A distributable reply whose direct parent is local and by another actor fans out to the
  poster's followers ∪ *P*'s followers, deduplicated by shared inbox (`status_reach_finder.rb:105-106`).
- A carried-over self-reply unions nothing.

**`repliesCount`** is updated on *P*'s partition, under the §1.6 rules.

**Visibility cap.** §1.2 step 5 applies. Private parents of others never resolve.

### 2.6 Delete and Update reach

`replyAudience(status)` returns:
- the poster's followers
- *P*'s followers, under the §2.5 union rule
- *R*, when *R* is in `cc`

This mirrors `StatusReachFinder` for Create, Update and Delete (`distribution_worker.rb:22-23`;
`remove_status_service.rb:92-106`).

**Callers:**
- PostHandler's Create fan-out.
- The quote-accept `Update` (`InboxHandler/main.swift:1284` onward), which today goes to followers
  only.
- **Any future status delete or edit endpoint MUST use it.**

### 2.7 Safe links in generated HTML

Every link FAP renders into post HTML from data it didn't author follows one rule. That covers the
mention `href` (§2.5, §3.5) and the "In reply to" link (§1.8, §3.8).

1. **Pick the candidate URL.**
   - For a local account or status, it is the FAP-built URL.
   - For a remote one, it is the object's `url` when that is a string. When it is an array or an
     object, use the first `Link`'s `href`, or the first string.
2. **Check the scheme.** The candidate must be `https` or `http` and parse as an absolute URL, as
   Mastodon's `url_for` requires (`tag_manager.rb:18-19`; `json_ld_helper.rb:95-97`).
3. **Fall back.** If it fails, use the validated actor URI or status URI instead. Those already
   passed the Step 0 `https` check and the §3.3 checks.
4. **Escape.** HTML-attribute-escape every interpolated value (`&`, `<`, `>`, `"`, `'`), as
   Mastodon's `h()` does (`text_formatter.rb:85`). That covers the URL, the username and the
   domain.

### 2.8 Interaction with InboxHandler

- A local reply never passes through InboxHandler.
- No FAP inbox is in any fan-out.
- Remote replies to it are handled by the existing `handleCreate`.
- The Update partition mismatch (`:884-885`) is recorded here and not fixed.

### 2.9 Client API and web

- `in_reply_to_id` is *P*'s ULID, and `in_reply_to_account_id` is *R*'s username.
- **`openapi.yaml`:** `GET /api/v2/search` (`operationId: search`) with a `SearchResults` schema.
- The post page's "In reply to" links to *P*'s post page, following §2.7.

### Phase 2 components

| Component | What it is |
|---|---|
| `SearchHandler` | New Lambda. Auth, local resolution, `show?`, `REF#` writes. Policies: DynamoDB CRUD, plus SSM read limited to `activity/${Stage}/keys/*`, which holds both the session key (`PostHandler/main.swift:51-52`) and the actor keys. |
| `GET /api/v2/search` | New `ClientApi` route |
| CloudFront `/api/v2/search` | New behaviour on `ClientApiGateway`: `CachingDisabled`, `ClientApiOriginRequestPolicy`, GET/HEAD/OPTIONS (beside `cdn/template.yaml:340-346`) |
| `REF#` item type | A new item type in the existing table |
| `replyAudience` | A shared ActivityPubCore function |
| Safe-link helper (§2.7) | A shared ActivityPubCore function |
| OpenAPI | The `search` operation and `SearchResults` |

**Release steps:**
1. **Handle-domain route.** A deployment that serves the client API from a separate handle-domain
   CloudFront distribution must add a `/api/v2/search` behaviour to its client-API origin *before*
   the release. Without it, the path falls through to that distribution's default origin. That
   distribution lives outside this repository.
2. **Client.** Any client app that posts replies to statuses it doesn't own, including the
   downstream client generated from this OpenAPI spec, must resolve the URL through search first
   and post the returned id.

**Invariants:**
- **Smallest mechanism.** The handler, route and behaviour are what decision 7 requires. A lazy
  pointer avoids an index and a backfill.
- **One job.** Search resolves, and PostHandler creates.
- **Blast radius.** One repository, plus the handle-domain route.

## Phase 3a — Replies to remote statuses (unsigned)

### 3.1 Remote ids and the remote-status cache

**Remote status id.**
- It is 26 Crockford-base32 characters encoding the first 16 bytes of `SHA-256(canonical URI)`.
  That is the same length and alphabet as a ULID.
- It is deterministic, so a re-search returns the same id, and Delete invalidation needs no index.
- **Collision probability is arithmetic.** For n cached URIs, the chance of any collision is about
  n²/2¹²⁹. For one remote id matching an existing ULID, it is 2⁻¹²⁸.
- The resolver tries the caller's partition first.

**Remote account id.** The same construction, applied to the actor URI.

**Entries.** `PK=REF#{id}`. Each entry holds:
- `kind: "remote"`
- `uri`
- `url`
- `attributedTo`
- the actor's `preferredUsername` and `url`
- `visibility`
- `content`, sanitized with `HTMLSanitizer`
- `summary`, `sensitive`, `published`, `language`
- `fetchedAt` and `ttl`

**Where an entry lives depends on visibility.**
- **Public and unlisted:** one shared entry, `SK=META`.
- **Private:** one entry per caller who resolved it, `SK=VIEWER#{username}`. There is no `META`
  entry.
  - A remote server may show a followers-only post to a specific requester. For example, Mastodon
    shows one to a mentioned account (`status_policy.rb:9-10`).
  - Only that requester may reply. This applies Mastodon's per-viewer `show?`
    (`resolve_url_service.rb:29`) to FAP's cache.
  - **Re-search.** If a re-search derives `private` while a `META` entry exists, `META` is deleted.

**TTL: 30 days.**
- Readers compare `ttl` with the current time, because DynamoDB TTL deletion is lazy.
- An expired entry is treated as absent, so the client searches again.

**Invalidation in InboxHandler** (it has DynamoDB CRUD):
- **Delete.** For an object (URI or `Tombstone.id`) whose id has `REF#` entries, where the actor's
  host equals the object's host: `Query PK=REF#{id}` and delete every item. Mastodon delivers a
  status's Delete to the accounts that replied to it (`status_reach_finder.rb:38,79-81`;
  `remove_status_service.rb:98`).
- **Update.** With the same origin check, refresh `content`, `summary` and `sensitive` on every
  item. **Never change `visibility` from an Update.** Mastodon never does
  (`process_status_update_service.rb`), and an Update could otherwise widen access.

### 3.2 Signed fetch

This adds signing to the Step 0 fetch.
- **`signGet`.** `HTTPSignature.signGet(privateKeyPem:keyId:pathAndQuery:host:)` signs
  `(request-target) host date`.
  - The request target includes the query string (`signed_request.rb:113`).
  - It satisfies `signed_request.rb:54-57`.
  - It reuses `buildSigningString` (`HTTPSignature.swift:181-190`).
- **Re-signing.** `fetchRemoteObject` takes an optional signer and re-signs every redirect hop.
- **Signer.** The signer is the requesting actor, with keyId `https://{serverDomain}/users/{u}#main-key`.
  - The key comes from `{SSM_KEY_PREFIX}/{u}`, cached per container in a dictionary keyed by
    username.
  - Mastodon accepts any verifying account key (`signature_verification.rb:45` onward).

### 3.3 Remote resolution in search

`resolve=true` with a non-local `https://` `q` runs under a **10 s overall deadline**, well under
the 29 s API Gateway limit. On overrun or any failure, it returns empty `statuses` and writes
nothing.

1. **Fetch** the object signed as the caller.
2. **Canonicalize.** If `json['id']` ≠ `q`, re-fetch `id` and require equality
   (`json_ld_helper.rb:242-252`). A pasted web URL resolves this way.
3. **Validate.**
   - `type` must be in Mastodon's supported or converted set (`activity.rb:9-10`).
   - `attributedTo` is read via `first_of_value`/`value_or_id`.
   - The host of `attributedTo` must equal the host of `id` (`fetch_remote_status_service.rb:61-66`).
4. **Fetch the actor** signed.
   - Require `json['id'] == attributedTo` (`fetch_remote_actor_service.rb:16`).
   - Parse it with the parser extracted from `KeyManager.fetchActorDocument` (`KeyManager.swift:89-105`),
     extended to return `followers` and `url`.
   - Then write `REMOTE_ACTOR#{attributedTo}`. **This makes `SearchHandler` a second writer of the
     inbound-signature trust anchor.** It writes only after the `id` check, from a document the
     actor's own origin served. That is the same trust basis `KeyManager` uses.
5. **Derive visibility** (`status_parser.rb:101-111`).
   - `to` and `cc` may be arrays or strings.
   - All three public spellings count (`tag_manager.rb:14-15`).
   - The comparison uses the actor's `followers`.
   - A `direct` parent is left out of the results (`PostHandler/main.swift:194`).
6. **Write** the entry (§3.1), shared or per-viewer, and return the `Status`.

### 3.4 Resolving a remote `in_reply_to_id`

- PostHandler reads `REF#{id}`: first `META`, then `VIEWER#{caller}`. It checks `ttl` against the
  current time.
- **It makes no network fetch**, so the create request stays inside the API Gateway limit.
- **404 cases:**
  - A missing or expired entry.
  - A private entry that belongs to another caller. **A parent that is unreachable or deleted is
    refused with 404** (decided).
- On success it sets:
  - `inReplyTo` to the canonical URI
  - `inReplyToId` to the remote id
  - `inReplyToAccountId` to the remote account id
  - `inReplyToAccountUri` to `attributedTo`
- Remote parents get no visibility cap.

### 3.5 Addressing, Mention, delivery

These are the §2.5 rules with a remote *R*.

**Direct reply to *R*:**
- **Mention tag.** `Tag(type: "Mention", name: "@{preferredUsername}@{actor host}", href: <actor URI>)`.
  Mastodon matches mentions by `href` (`create.rb:255-263`).
- **Visible mention.** The §2.5 HTML.
  - Its `href` follows §2.7: the actor's `url`, or the actor URI as the fallback.
  - The display acct is `{preferredUsername}@{actor host}`.
- **Known limitation: the display domain.** Mastodon displays the WebFinger domain
  (`account.rb:249-254`). FAP displays the actor host, because it does no WebFinger lookup, and on
  split-domain servers those differ.
  - The dedup rule in §2.5 matches `@{preferredUsername}@{any domain}`, so a client-prefilled
    WebFinger form isn't duplicated.
  - The Mention `href`, which Mastodon uses to resolve the account, is unaffected.
- **`cc`.** *R* is added.

**Carried-over self-reply:** *R* goes in `cc` only, as in §2.5.

**Delivery to *R*.**
- `DeliveryJob` gains an optional `targetActorUri`. When `targetInbox` is empty, `DeliverHandler`:
  1. fetches the actor signed through Step 0 and §3.2
  2. requires `id == targetActorUri`
  3. delivers to `sharedInbox ?? inbox`
- There is no IAM change, and no cache write, because `DeliverHandler` has read-only DynamoDB.
- PostHandler adds this job whenever *R* is in `cc`.
- **Double delivery.** If *R*'s shared inbox equals a follower's, the Create reaches that server
  twice, and the second copy is dropped by the object-URI lock and lookup (`create.rb:30,95-99`).
- There is no followers union for a remote parent.

**Delete and Update.** `replyAudience` adds the *R* job by `targetActorUri`, so InboxHandler's
quote-accept Update reaches *R* without SSM access.

### 3.7 Interaction with InboxHandler

- `handleCreate` keeps dropping non-local `inReplyTo` (`:756-772`).
- *R*'s reply to FAP's reply is handled by existing code.
- `handleDelete` and `handleUpdate` gain the §3.1 invalidation.

### 3.8 Client API and web

- Search returns remote statuses with FAP ids.
- `in_reply_to_id` is the remote id, and `in_reply_to_account_id` is the remote account id.
- The post page's "In reply to" links to the cached `url`, following §2.7 with the canonical URI
  as the fallback.

### Phase 3a components

| Component | What it is |
|---|---|
| Remote resolve in `SearchHandler` | An extension of the phase 2 handler |
| Remote `REF#` entries (`META` or `VIEWER#`) | The existing item type, with a TTL |
| `signGet` and signer support in `fetchRemoteObject` | An extension of the Step 0 fetch |
| Second `REMOTE_ACTOR#` writer | `SearchHandler`, after actor validation |
| `DeliveryJob.targetActorUri` | An extension of the job and of `DeliverHandler` |
| `REF#` invalidation | An extension of `handleDelete` / `handleUpdate` |
| Shared actor-document parser | Extracted from `KeyManager` |

**Invariants:**
- **Smallest mechanism.** Remote ids are deterministic, so there is no by-URI index. The cache
  reuses `REF#`. Inbox resolution sits in `DeliverHandler`. PostHandler makes no fetch.
- **One job.** Each handler keeps its one job.
- **Blast radius.** One repository.

## Phase 3b — Linked Data Signatures (decision 10)

### 3.6 Signing remote replies

**Scope.** PostHandler LD-signs every Create it delivers for a **public or unlisted reply whose
direct parent is remote**. Those are exactly the activities `forward_for_reply` can forward
(`create.rb:491-495`).

**Algorithm.** This is byte-compatible with `linked_data_signature.rb:39-62`:
1. **Options:** `{type: "RsaSignature2017", creator: "https://{serverDomain}/users/{u}#main-key",
   created: <UTC ISO 8601, seconds>, expires: <created + 2 days>}`.
   - FAP sets `expires` as `sign!` does. Verification only checks it when it is present (`:22`).
2. **Options hash:** `options_hash = hex(SHA-256(canonicalize({"@context": "https://w3id.org/identity/v1",
   creator, created, expires})))`.
3. **Document hash:** `document_hash = hex(SHA-256(canonicalize(create − signature)))`. It is
   computed over the Create's **final** `@context`, which already contains
   `https://w3id.org/security/v1`. Mastodon's append is a `uniq!` no-op (`:56-59`), so nothing
   changes after hashing.
4. **Signature:** `signatureValue = base64(RSASSA-PKCS1-v1_5-SHA256(key, options_hash + document_hash))`.
5. **Emit:** add `"signature": {type, creator, created, expires, signatureValue}`.

`canonicalize` is JSON-LD `toRdf`, then RDFC-1.0, then N-Quads. RDFC-1.0 is the algorithm Mastodon's
`rdf-normalize` 0.7.0 uses by default (`lib/rdf/normalize.rb:62`).

**`@context` alignment, so the signature survives Mastodon's compaction**
(`process_activity_service.rb:59-66`; `json_ld_helper.rb:184-235`):
- **The Create's context.** The signed Create carries one top-level `@context`:
  `["https://www.w3.org/ns/activitystreams", "https://w3id.org/security/v1", {…}]`. The extension
  object maps every term FAP emits to the IRIs in Mastodon's `full_context`:
  - `sensitive` and `Hashtag`
  - `toot`, `blurhash` and `focalPoint` (`context_helper.rb:13-23`)
  - `quoteUri` (fedibird) and `_misskey_quote` (`:39-40`)
  - `gts`, `interactionPolicy`, `canQuote` and `automaticApproval` (`:43-48`)

  The embedded Note has no `@context` of its own.
- **Every Note.** `buildNoteJSON` uses the same mapping for every Note. Already-published Notes
  keep identical JSON keys and values, and only the context IRIs change.
- FAP emits no `@graph`, `@included` or `@reverse` (`json_ld_helper.rb:6`).

**Contexts are embedded and never fetched.**
- ActivityPubCore embeds three context documents as Swift string constants. There are no SwiftPM
  resources, because no FAP target ships resource bundles today:
  - **`https://www.w3.org/ns/activitystreams`:** the document `json-ld-preloaded` provides
    (`lib/json/ld/preloaded/activitystreams.rb`).
  - **`https://w3id.org/security/v1` and `https://w3id.org/identity/v1`:** transcribed from
    Mastodon's preloaded term definitions (`config/initializers/json_ld_security.rb`,
    `config/initializers/json_ld_identity.rb`) into context JSON, term for term.
- The receipt for each constant is the source repository, commit and path. No live fetch is
  planned, and the identity URL is dead anyway (Standards).
- **Loader.** The document loader returns only these three, under both `http` and `https`
  spellings as Mastodon aliases them. Any other URL fails.
- **On failure, deliver unsigned.** If canonicalization or signing fails, the Create is delivered
  unsigned and the failure is logged. Only forwarding is lost.

**Gate (decision 13).** Vendored code that is in use passes the same gate as code FAP writes.
- **FAP's own documents.** Every Note, Create and Delete shape FAP emits, including the
  `focalPoint` `@container: @list` definition, goes through `toRdf` without an unsupported-feature
  error.
- **No network.** Contexts load only from the embedded copies.
- **Linux.** The canonicalization tests run on Linux, not only a Linux build.
- **W3C suites in FAP's CI.** The W3C RDFC-1.0 suite, and the JSON-LD `toRdf` tests for the
  features FAP's documents use, run in FAP's own CI.
- **Mastodon-generated fixtures.** These are committed together with the generator script that
  produced them, run once against Mastodon's reference stack (Ruby `json-ld` 3.3.2,
  `json-ld-preloaded` 3.3.2, `rdf-normalize` 0.7.0, and Mastodon's two context initializers):
  - a FAP-shaped Create
  - its canonical N-Quads and both hashes
  - the signature for a fixed test key and timestamps
  - the document **compacted against Mastodon's `full_context`**, for the compaction-safety test

### Phase 3b components

| Component | What it is |
|---|---|
| LD signer | A new ActivityPubCore module: three embedded contexts, RSA-SHA256, using the canonicalization module |
| Canonicalization | A module FAP owns in ActivityPubCore: `toRdf` for FAP's shapes and RDFC-1.0 (decision 13) |
| Vendored reference code | The two vetted packages' source at a pinned commit, licences retained, authors credited (decision 13) |
| Credits | `CONTRIBUTORS.md` and a README Acknowledgements section (decision 13) |
| Context alignment | A change to `buildNoteJSON` / `buildCreateActivityJSON` |
| Fixture generator | A committed script, run once outside CI |

**Invariants.**
- LD signing is required by decision 10.
- Its cost is a canonicalization module FAP owns and maintains, and that cost is surfaced.
- It is isolated to remote public and unlisted replies.

## Testing

Every test includes a negative control, and each must be seen going red with its capability
removed before it counts.

### Unit (`Tests/ActivityPubCoreTests`, Swift Testing)

**Step 0 and 0b**, each against a local test server, run on Linux as well as macOS.

The harness uses real sockets, not a `URLProtocol` stub, because a stub skips the layer under test.

- **Step 0 server.** A minimal HTTP/1.1 server written in the test target on POSIX sockets,
  listening on loopback over plain `http`. No new package. It serves fixed responses, redirects,
  oversize bodies and a slow drip.
- **Scheme policy is injected.** `fetchRemoteObject` takes its scheme policy as a parameter
  whose default is `https` only. `KeyManager` takes the same defaulted parameter and passes it
  through. Every production call site uses the default, and the permissive policy is built only
  in the test target. Step 0 tests pass one that admits `http` to the test server's ports they
  name (A, or A and B below) and nothing else, on the initial request and on every hop.
  Negative control: the default policy refuses the test server's `http` URI.
- **Per-hop scheme check in step 0.** The test server listens on two loopback ports, A and B.
  With a policy admitting only A, a redirect from A to B fails with the policy's refusal.
  Control: with a policy admitting A and B, the same redirect succeeds. The full
  `https`→`http` hop test needs a TLS server and runs in 0b.
- **Every "fails" test checks which control refused.** Each control throws its own error case,
  and the test asserts that case, so a test can't pass on a connection error or a different
  control.
- **Why plain http in step 0.** On Linux, `FoundationNetworking` reads its CA bundle from fixed
  system paths and handles no server-trust challenge, so a test CA can't be injected per task.
  Plain http still exercises the delegate callbacks, incremental delivery and redirects on Linux,
  which is what step 0 measures.
- **Step 0b adds TLS and the address check.** The test server presents a certificate from a
  test-only CA, passed to the transport as an injected trust value; production passes none and
  uses the system store. The address policy is injected the same way; tests admit only the test
  server's loopback port. Negative controls: a production-configured client refuses the test
  server, on trust and on address.
- **0b server.** Which TLS server runs the 0b harness on Linux is decided with Open question 1,
  and any new test-only package is flagged there. It must not pull `libxml2-dev` or
  `libicu-dev` onto the runner, which crashes `FoundationNetworking` test binaries.

Tests:
- **Redirects:** 3 pass, and a 4th fails.
- **Scheme:** an `http://` initial URI fails under the default policy, and a hop to a
  non-admitted `http` URI fails. In 0b, an `https`→`http` hop fails.
- **Body:** a body over 1 MB fails.
- **Content type:** a `text/html` response fails.
- **Status:** a non-200 fails.
- **Deadline:** a slow drip fails at the deadline.
- Negative control: a compliant response passes.
- **Content type with parameters:** `application/activity+json; charset=utf-8` passes, and
  `text/html; charset=utf-8` fails.
- **LD profile:** `application/ld+json; profile="https://www.w3.org/ns/activitystreams"` passes,
  and bare `application/ld+json` fails.
- **Key fetch:** the test calls the internal `fetchActorDocument(actorUri:schemePolicy:)` through
  `@testable import ActivityPubCore`, so no `DynamoDBStore` is needed (`KeyManager.swift:68`).
  The policy is a method parameter with the `https`-only default. With the test policy, it
  fetches a valid key document from the test server. An actor URI whose 4-redirect chain ends at
  a valid key document fails with the redirect error. An actor URI serving a valid key document
  padded with whitespace past 1 MB fails with the size error. Negative control: the same calls
  against the pre-move `fetchActorDocument(actorUri:)`, with no policy argument, succeed,
  because that code has no scheme check, redirect cap or size cap, and both fixtures parse.
- **Address check (0b):** redirects to `127.0.0.1`, `169.254.169.254` and `10.0.0.1` fail.
- **Request target (0b):** a URI with a query string and percent-encoded characters reaches the
  test server byte for byte. Negative control: the same URI through a plain `/{path}` template
  fails.
- **One client (0b):** two fetches to different origins through the same client instance each
  reach their own test server. A fetch with no target bound throws before any connection, and
  the placeholder origin receives nothing.

**Phase 1**
- **`buildNoteJSON`** emits `inReplyTo` when `inReplyToId` is set.
  - Negative control: a legacy `inReplyTo` without it emits no key.
- **The resolver** returns `none`, `resolved` or `notFound`.
- **`cappedReplyVisibility`** covers all nine pairs.
  - Negative control: `public` under `private` gives `private`.
- **`buildStatusResponse`** returns the stored ids.
  - Negative control: a non-reply gives `null`.

**Phase 2**
- **The `REF#` local pointer** resolves another actor's unlisted status.
  - Negative controls: another actor's private status gives `notFound` in both search and the
    resolver, and a ULID with no pointer gives `notFound`.
- **Carry-over** yields *R*.
  - Negative control: a reply to someone else's reply yields that someone.
- **Followers union** is *P*'s followers.
  - Negative control: carried-over self-replies and private replies union nothing.
- **Mention.** A direct reply has a Mention tag, the h-card and *R* in `cc`.
  - Negative controls: a carried-over self-reply has `cc` only, and a self-thread has none of
    these.
- **Mention dedup.** Leading `@R`, `@R@handleDomain` and `@R@serverDomain` each render one
  mention.
  - Negative control: `@R` mid-sentence still gets the prepended mention.
- **Safe links (§2.7).**
  - An actor `url` of `javascript:alert(1)` falls back to the actor URI.
  - So does a `url` containing `"><script>alert(1)</script>`. The output contains no unescaped
    `"`, `<` or `>`.
  - An array `url` of Links uses the first `href`.
  - Negative control: a valid `https://` `url` is used as-is, escaped.
- **`replyAudience`** includes *P*'s followers and *R*.
  - Negative control: a non-reply gets followers only.
- **Search without `resolve=true`** returns empty.
  - Negative control: the same `q` with `resolve=true` returns the status.

**Phase 3a**
- **Remote id derivation** is stable.
  - Negative control: a one-character difference gives a different id.
- **`signGet`** covers the query string, and verifies.
  - Negative controls: a missing query string fails, and a tampered path fails.
- **Remote validation.** An `id` mismatch, an `attributedTo` host mismatch, a `Tombstone`, an
  unsupported type, and an actor `id` ≠ `attributedTo` each fail. A web URL yields the canonical
  id.
  - Negative control: a valid `Page` resolves.
- **Visibility derivation** covers the four outcomes, the public spellings, and string `to`/`cc`.
  - Negative control: a person-only audience gives `direct`, which is excluded.
- **Private entries.** A resolves a private parent and can reply.
  - Negative control: B replying with the same id gets `notFound`, and B gets no `VIEWER#` entry.
- **Cache.**
  - An expired-but-present entry is treated as absent.
  - Delete removes `META` and every `VIEWER#` entry. Update refreshes `content`, and never
    `visibility`.
  - Negative controls: a Delete from a different host leaves the entries, and an Update whose
    object audience is public leaves a private entry private.

**Phase 3b**
- **Canonicalizer.** It reproduces the committed Mastodon-generated N-Quads and hashes byte for
  byte, and passes the W3C suites in FAP's CI.
  - Negative control: changing one character of `content` changes `document_hash`.
- **Signature.** The signed fixture verifies with an independent RSA-SHA256 check.
- **Compaction safety.** A port of `safe_for_forwarding?` compares the FAP document with the
  committed Mastodon compaction fixture, and passes.
  - Negative control: the fixture of a document with the pre-alignment `quoteUri` mapping fails
    it.
- **Loader.** It refuses any URL outside the three embedded contexts.
  - Negative control: an extra remote context fails signing, and the Create is sent unsigned.

### Schema conformance (`integration-tests/Tests/IntegrationTests/SchemaConformanceTests.swift`)

Fixtures are decoded through the generated types:
- `status-reply.json` and `status-legacy.json` (`Components.Schemas.Status`).
  Negative control: marking `in_reply_to_account_id` `required:` makes the legacy fixture fail.
- `search-results.json` (`SearchResults`).

### Integration (`integration-tests/`, on stage, generated `APIClient`)

**Phase 1:** round trip, unknown parent, visibility cap, and a chain of three.

**Phase 2** (needs a second stage actor and token)
- A searches B's unlisted status URL, gets B's ULID and replies.
- The response carries the parent id and B. The Note has a Mention, the h-card, `cc` B, and B's
  count rises.
- Negative controls:
  - B's private status: search returns nothing, and replying with its ULID gets `.notFound`.
  - Search without a token gets 401.

Phase 3 needs a third-party server, so it is in the manual federation checks below, not in CI.

### Federation (manual, against stage)

- **BrowserPub** (https://browse.activitypub.dev) renders "in reply to" up the chain.
- **Mastodon, phases 1 and 2.** `/context` for the last post lists the others as `ancestors`.
- **Mastodon, phase 3a.** On a Mastodon instance the tester controls or has an account on:
  - Search *R*'s public post, then reply with the returned id.
  - *R* gets a mention notification, and `/context` of the parent lists FAP's reply.
  - Repeat against a secure-mode instance.
  - Negative control: with signing disabled, the secure-mode instance refuses the fetch, and
    search returns nothing.
- **Mastodon, phase 3b (forwarding).**
  - Set up account *F* on a second instance. *F* follows *R* but not the stage actor.
  - The stage actor posts a public reply to *R*'s public post.
  - **Acceptance:** *F*'s instance has FAP's reply. Search for it there with `resolve=false`, and
    check *F*'s home timeline.
  - **Negative control:** with LD signing disabled, or with `quoteUri` misaligned, *F*'s instance
    lacks the reply.
- **Delete and Update reach.** A quote-accept `Update` of a quoting reply to *R* reaches *R*'s
  instance.
  - Negative control: the pre-change build sends it to followers only.
- **Mastodon caching.** Mastodon caches discovery failures for hours, so retry on another instance
  before debugging FAP.
- **Before/after control.** Run each procedure on the pre-change build and record the absence.

### Build gate

- Build every target for Linux with `swift package archive --allow-network-connections docker`.
  The deployed binary is the Linux build, and a macOS `swift build` doesn't catch Linux-only
  compile errors.
- Run the Step 0, 0b and 3b unit tests on Linux.
- Build the generated consumers against the branch's `openapi.yaml`.

## Unverified

- **The transport under the FAP-generated fetch client.** The client is decided (decision 14).
  The transport is Open question 1.
- **Incremental delivery and redirect callbacks in `FoundationNetworking`.** Read in
  `swift-corelibs-foundation` source (Step 0); the Step 0 Linux tests measure it.
- **Live secure-mode acceptance of a regular actor key.** The source has been read
  (`signature_verification.rb:45` onward). The phase 3a secure-mode check is the measurement.
- **Mastodon internals.** The `items_context_url` path shape, a read of `context` on intake, the
  composer's handling of the author's own `@handle`, and the `replies_count` "added" version. None
  of these is relied on.
- **Forcing out-of-order delivery** for the manual check. No mechanism has been identified.

## Decisions (2026-10-20)

The maintainer decided the following on 2026-10-20.

1. **Scope: all replies.** Self, other local actors and remote statuses, each shippable on its own.
2. **`replies` collection:** a follow-up.
3. **`context` / `conversation`:** not now. Revisit when a context FEP reaches FINAL.
4. **Profile page:** posts stay separate, and each post page gets "In reply to" (§1.8).
5. **Server-side length check:** FederatedActivityPublisher#272.
6. **Visibility cap:** it applies to local parents while #270 is open, and is lifted once #270 is
   fixed (§1.2).
7. **Ids:** FAP-local ids plus search, as Mastodon does. URIs aren't accepted as ids
   (§2.1–2.4, §3.1–3.4).
8. **Visible mention:** a linked `@user@domain` in Mastodon's h-card shape on direct replies to
   others, without duplicating a leading mention (§2.5, §2.7).
9. **Unreachable remote parent:** refused with 404 (§3.4).
10. **Linked Data Signatures** are part of phase 3, as step 3b (§3.6).
11. **Carried-over self-reply:** `cc` only, no Mention (§2.5).
12. **Delete and Update reach:** they go to the parent author and the followers union through
    `replyAudience`. That applies to the quote-accept Update now, and to any future delete or edit
    (§2.6, §3.5).

13. **LD-signature canonicalization: reference implementations, vendored and credited**
    (former Open Question 1, option B; the revision at `6271b24`).
    - FAP owns the canonicalization in ActivityPubCore: `toRdf` for the closed set of terms and
      shapes FAP emits, plus RDFC-1.0.
    - **Vendor the reference code.** The source files of `1amageek/swift-knowledge-graph` (MIT)
      and `mattmassicotte/JSONLD` (BSD-3-Clause) are copied into the repository at one pinned
      commit each, whether FAP's code ends up using them or only learns from them.
    - **Credit, prominently.** Both authors are listed as contributors: in a new
      `CONTRIBUTORS.md`, and in an Acknowledgements section in `README.md` that links both
      packages (this spec's reading of "list them as contributors"; Open question 2). This
      applies whether the vendored files are in use or were only inspiration. FAP source
      informed by them links to the vendored file it follows. The wording credits their work
      and doesn't suggest they endorse FAP (BSD-3-Clause clause 3).
    - **Implementation rules** (added by this spec for the signing-path rule, not part of the
      maintainer's words):
      - Location: `Vendor/<package>/`, outside every SwiftPM target. That copy stays pristine.
      - A file put to use is **copied**, not moved, into ActivityPubCore. The copy carries an SPDX
        identifier, the upstream copyright line and the path of the retained `LICENSE`, and is
        listed in `VENDORED.md`, so the change from the pristine copy can be diffed.
      - Each directory keeps the upstream `LICENSE` verbatim and a `VENDORED.md` that names the
        source URL, the commit, the licence and every local change.
      - Source files only. Nothing from the packages is built, run or added to `Package.swift`
        while vendoring, and their manifests, plugins and scripts are not copied. Upstream tests
        are source files and come along. Any W3C suite data committed for the §3.6 gate is listed
        in `VENDORED.md` with its own licence.
      - The vendoring PR shows the full copied source in its diff, and is reviewed like FAP code.
      - The fetch is limited to these two repositories at the pinned commit.
    - **Other references.** Mastodon's `linked_data_signature.rb` and ruby-rdf's
      `rdf-normalize` are linked from the code as references. Nothing is copied from them.
    - The gate in §3.6 applies to all of it. Step 3b stays last, because delivery degrades to
      unsigned.
14. **HTTP client for remote fetches: FAP's own, generated with swift-openapi-generator**
    (former Open Question 2; the revision at `6271b24`).
    - FAP writes an OpenAPI document for the remote ActivityPub object fetch: a `GET` with the
      AS `Accept` header, a 200 response in `application/activity+json` or
      `application/ld+json; profile="https://www.w3.org/ns/activitystreams"`, and redirects.
    - The client is generated by `swift-openapi-generator`, which `Package.swift` already declares
      (`Package.swift:36-38`) for the `APIClient` target (`:238-248`). It gets its own target.
    - **Mapping a remote URI to the operation.** OpenAPI path parameters default to `simple` style
      and `allowReserved` applies only to query parameters, so one `/{path}` template can't carry an
      arbitrary path and query. Instead:
      - the document's `servers:` holds a placeholder origin and the operation path is `/`;
      - **one client** is built once per Lambda container and reused for every fetch;
      - `fetchRemoteObject` binds the target URI in a `@TaskLocal` for the duration of the call;
      - a FAP `ClientMiddleware` reads it and calls `next` with the URI's origin as the base URL
        and the request's path and query set to the URI's, byte for byte. `next` takes the
        request and the base URL as arguments: `next: @Sendable (HTTPRequest, HTTPBody?, URL)`
        (`apple/swift-openapi-runtime`, `Sources/OpenAPIRuntime/Interface/ClientTransport.swift`).
      - With no target bound, the middleware throws, so the placeholder origin is never contacted.
      The signed `(request-target)` (§3.2) and the `id == q` check (§3.3) both depend on this.
    - **Where the controls live.** The transport owns everything that happens during the exchange:
      redirects, per-hop scheme checks, signing of every hop including the first, the body cap,
      the deadline and the address check. Signing in the transport happens after the middleware
      has set the path and query, so `(request-target)` is the real one. Content-type and status
      checks can run on the response in FAP code.
    - **Dependencies.** The generator and runtime are already declared. Whether the transport adds a
      package entry to `Package.swift` is part of Open question 1. Nothing imports `APIClient` today
      (only `Package.swift:240` names it), so `swift-openapi-runtime` and the generator plugin
      reach the deployed Lambdas, and the plugin runs in the `swift package archive` Docker build,
      for the first time.

## Open questions

1. **The transport under the generated fetch client (step 0b).** The transport owns redirects,
   per-hop scheme checks and re-signing, the 1 MB cap, the absolute deadline and the address check
   (decision 14).
   - `OpenAPIURLSession` won't do. Its README says streaming is available only on Apple platforms
     and points Linux users to the AsyncHTTPClient transport
     (https://github.com/apple/swift-openapi-urlsession), so on the Lambda the body arrives
     buffered. The per-hop checks also need the redirect callback on a delegate FAP owns, so they
     live in the transport FAP writes.
   - `URLSessionTaskTransactionMetrics.remoteAddress`
     (https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics/remoteaddress)
     is documented for Apple platforms only, and it reports a connection after it is made, so it
     can't refuse one.
   - So the transport needs a TLS-capable connection layer that either exposes a connect-time hook
     or connects to a pre-validated address while keeping the original `Host` and SNI.

   - The same choice settles the Linux test harness: which https server the step 0b tests run
     against, and how a test-only CA is injected (Testing, Step 0 and 0b). The transport must also
     accept plain `http` under an injected test policy, so the step 0 tests carry over.

   **Proposed:** while planning step 0b, list what the resolved dependency graph already provides
   for both, with receipts, name any new package (runtime or test-only), and bring the choice back
   to the maintainer before writing it. Step 0 ships first, on the existing fetch, and step 3a
   waits for 0b.
2. **"List them as contributors."** This spec reads it as a new `CONTRIBUTORS.md` plus a README
   Acknowledgements section (decision 13). Confirm, or name another place (for example GitHub's
   co-author trailers on the vendoring commit).
