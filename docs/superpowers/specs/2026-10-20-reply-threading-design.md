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

The work ships as five changes, in order. Each can be released on its own.

| Step | Change | Depends on | New components (full list in each section) |
|---|---|---|---|
| 0 | **Fetch hardening**, a security change to the existing shared fetch, built on the generated client (decisions 14 and 16) | FederatedActivityPublisher#279 merged | A FAP-authored OpenAPI document (`Sources/ActivityPubCore/openapi.yaml`) with typed actor and object schemas, and a client generated from it inside `ActivityPubCore`; one FAP `ClientMiddleware`; one long-lived `HTTPClient` per container behind `AsyncHTTPClientTransport`, with the connection-level address check; `ActorKeyCache` (§0.1) |
| 1 | Self-replies | — | None |
| 2 | Replies to other local actors | 1 | `SearchHandler` Lambda; `GET /api/v2/search` route and CloudFront behaviour; `REF#` item type |
| 3a | Replies to remote statuses, delivered unsigned | 0, 2 | Remote resolve in `SearchHandler`; remote `REF#` entries; actor-URI delivery in `DeliverHandler` |
| 3b | Linked Data Signatures on remote replies | 3a | LD signing in ActivityPubCore: FAP-owned canonicalization with vendored, credited reference code (decision 13), and `@context` alignment |

**Precondition for the live tests: FederatedActivityPublisher#278.** The stage integration gate
(`deploy-stage.yml:513-530`) discards the test exit code and passes on XCTest's empty
`Test Suite … passed` line, which `swift test` prints in every run of these Swift Testing suites,
so it can't go red. The phase 1
and phase 2 integration tests and their negative controls (Testing) count only once #278 is fixed
and its own negative control (a stage run with one failing test fails the job) has been seen red.
Phases 1 and 2 can be written before that, but their integration criteria aren't discharged until
then.

**Why step 0 goes first.** The quote path already sends client-supplied URIs to `fetchRemoteObject`
with no scheme check, unlimited redirects and no body cap (`FetchRemoteObject.swift:37-45`;
`PostHandler/main.swift:252,264`). That exposure exists today and depends on nothing in the reply
work. Step 0 also carries the signer that FederatedActivityPublisher#280 asks for (§3.2).

**Why step 0 ships the address check and the generated client together.** An earlier revision
shipped the other controls first on the `URLSession` fetch and moved them to a new transport later.
With the generated client and the AsyncHTTPClient hook decided (decision 14), that would build the
controls twice, once on a `URLSession` delegate that is then thrown away. Step 0 builds them once,
in the middleware. The maintainer chose to keep step 0 folded (decision 15).

**Why 3a waits for 0.** Phase 3a adds a new way for an authenticated user to make the server fetch
an arbitrary URL (`resolve=true` search, §3.3) and adds signed actor fetches in `DeliverHandler`
(§3.5). Without the address check, search adds a path to loopback and link-local addresses that
a signed-in user controls directly and whose result is returned to that user. Steps 1 and 2 don't
fetch remote URLs and don't wait.

**Why 3b goes last.** Delivery degrades to unsigned when signing fails (§3.8). Remote replies
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

All sources were fetched 2026-10-20. Mastodon source references are to `mastodon/mastodon`
`main` as of 2026-10-20, whose head that day was commit `2c540e458d6bb99ecb7729aec82078fc3dd2e175`
(github.com/mastodon/mastodon/commits/main, read 2026-10-20). References into
`app/helpers/json_ld_helper.rb` name the method or constant in `JsonLdHelper` rather than a line.

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
    scheme is `http` or `https` (`tag_manager.rb:18-19`; `JsonLdHelper#unsupported_uri_scheme?`,
    `app/helpers/json_ld_helper.rb`).
  - Both values are HTML-escaped with `h()`.
  - `display_username` is `pretty_acct` when `with_domain` is set. For a remote account,
    `pretty_acct` is `username@domain`, where `domain` is the account's WebFinger domain. For a
    local account it is the bare `username` (`app/models/account.rb:249-254`).

**Who Mastodon delivers to** (`app/lib/status_reach_finder.rb`):
- Inboxes are reached accounts, plus followers, plus relays (`:12-13`).
- Reached accounts include:
  - `replied_to_account_id` (`:31`), which is reached only `if distributable?` (`:48-49`)
  - mentioned accounts (`:34`)
  - `replies_account_ids` (`:38,79-81`)
  - `replies_account_ids` and the other interaction lookups run only when the status is
    `distributable? || unsafe?` (`:79-81`).
- **Followers.** For a distributable reply to a local account, the author's followers plus the
  direct parent author's followers (`:105-106`; `app/models/status.rb:210-212`). For a direct or
  limited status, none (`:108-109`). Otherwise, including a private status, the author's followers
  (`:110-111`).
- Create and Update are distributed with `StatusReachFinder`
  (`app/workers/activitypub/distribution_worker.rb:22-23`; `status_update_distribution_worker.rb:3`).
- Delete uses `StatusReachFinder.new(@status, unsafe: true)` (`app/services/remove_status_service.rb:92-106`).
  So Mastodon delivers a status's **Delete** to every account that replied to it. Its **Update**
  reaches those accounts only when the status is distributable (public or unlisted).

**How Mastodon forwards:**
- **The forwarding condition.** `forward_for_reply` runs only when
  `@status.distributable? && @json['signature'].present? && reply_to_local?`
  (`app/lib/activitypub/activity/create.rb:491-495`).
- **Signature on receipt.** `@json = compact(@json) if @json['signature'].is_a?(Hash)`
  (`app/services/activitypub/process_activity_service.rb:24`).
  - The signature is kept only if `safe_for_forwarding?` holds after `patch_for_forwarding!`
    (`:59-66`; `JsonLdHelper#patch_for_forwarding!`, `#safe_for_forwarding?`).
  - That requires every original key to survive compaction against `full_context`
    (`JsonLdHelper#compact`; `app/helpers/context_helper.rb:75-76`).
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
  - It rejects `@graph`, `@included` and `@reverse` (`JsonLdHelper::UNSUPPORTED_JSONLD_KEYWORDS`, `#unsupported_jsonld_features?`).
  - It requires `type == "RsaSignature2017"`.
  - It rejects an `expires` in the past *if one is present* (`:22`). `expires` isn't required.
- **Canonicalization:** `RDF::Graph.new << JSON::LD::API.toRdf(json, documentLoader: …)`, dumped
  as `:normalize` (`JsonLdHelper#canonicalize`).
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
  - `JsonLdHelper#load_jsonld_context` fetches other contexts and caches them
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
- `JsonLdHelper#fetch_resource` requires `json['id'] == uri`.
- **Response checks:** status 200 and an AP content type (`JsonLdHelper#fetch_resource_without_id_validation`,
  `#valid_activitypub_content_type?`), a 1 MB body
  (`app/lib/request.rb:293-294`), and at most 3 redirect hops (`:101-102`).
- Each request it sends is signed (`:72-75`).
- Private addresses are rejected per connection (`:325-334,389-394`).
- **Attribution:** `trustworthy_attribution?` (`app/services/activitypub/fetch_remote_status_service.rb:61-66`),
  with `attributedTo` read through `value_or_id(first_of_value(...))` (`:29`).
- **Types:** `Note` and `Question` are supported, and `Image`, `Audio`, `Video`, `Article`, `Page`
  and `Event` are converted (`app/lib/activitypub/activity.rb:9-10`).
- **Actors:** the `id` must equal the requested URI. `FetchRemoteActorService` fetches with
  `fetch_resource(uri, true, …)` (`fetch_remote_actor_service.rb:18`), and the comparison
  `json['id'] == uri` is in `JsonLdHelper#fetch_resource`.

**Search and URL resolution.**
- **Docs** (https://docs.joinmastodon.org/methods/search/):
  - `GET /api/v2/search` with `q` an HTTPS URL and `resolve=true`: "if `true`, resolving the URL
    and returning the matching status, account or Collection is attempted."
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

Code on the signing path must be code FAP owns, or a dependency the maintainer has approved
explicitly. Candidate packages found by searching package indexes are not evidence. A project's
own README and CI results are statements from the party being evaluated, so they don't count as
evidence of fitness.

The maintainer chose to vendor two packages as reference code (decision 13). What he said about
their authors, 2026-10-20: of `mattmassicotte/JSONLD`'s author, "a very known entity in the swift
community that I'd trust"; of `1amageek/swift-knowledge-graph`'s author, "very reputable developer
again". That is a statement about the authors, not a review of the code: the code passes the
same §3.8 gate as code FAP writes. Both packages were read from their repository pages only, and
their scope below comes from their own READMEs, so it is unverified until that gate runs:

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

**Gaps that apply to any vendored file put to use** [inferred]. These are checked by the §3.8 gate:
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
  inbound-signature trust anchor (`KeyManager.swift:41-42`). Two code paths write it:
  `KeyManager` on a key fetch (`KeyManager.swift:47,55`), and `InboxHandler` on an inbox `Update`
  of a `Person` (`InboxHandler/main.swift:947`, through `DynamoDBStore.swift:478-480`), after
  checking that the activity's actor is the actor being updated (`:909`). Readers besides
  `KeyManager`: the quote path's inbox lookup (`PostHandler/main.swift:267`) and
  `InboxHandler/main.swift:388,1592`. This spec adds no writer (§3.3).

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
  (`activity-app/functions/template.yaml:446-453`).
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
- `PostFunction` reads SSM `activity/${Stage}/*` (`activity-app/functions/template.yaml:122-140`).
- `InboxFunction` has DynamoDB CRUD and SQS only (`:429-433`). FederatedActivityPublisher#279
  (open) adds SSM read of `activity/${Stage}/keys/*` with an explicit `Deny` on
  `session-signing-key`, `jwt-signing-key` and `client-token` and on `ssm:GetParametersByPath`,
  so the inbox can sign its key fetches. FederatedActivityPublisher#282 tracks moving actor keys
  to their own sub-path, `keys/actors/{username}`, so grants no longer need a deny-list.
- Bearer auth falls back to the legacy SSM parameter `{ssmKeyPrefix}/client-token`
  (`BearerAuth.swift:97,151`), so a handler that authenticates clients reads `client-token` as
  well as `session-signing-key`.
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

Every remote `GET` goes through one of two public functions over one client, and every control
below applies to both: `fetchRemoteObject`, which returns a typed object document, and the new
`fetchRemoteActor`, which returns a typed actor document (§0.1, decision 16).
`KeyManager.fetchActorDocument` moves onto `fetchRemoteActor` in the same change, keeping the
signing key FederatedActivityPublisher#279 gives it; its hand parser (`KeyManager.swift:89-105`)
is replaced by the actor schema. So every remote GET is covered: the quote path, inbox object
fetches and key fetches. Delivery POSTs from `DeliverHandler` are not fetches and are outside
this spec; their address check is tracked separately (FederatedActivityPublisher#277).

**Base.** Step 0 builds on FederatedActivityPublisher#279, which adds
`HTTPSignature.signGet(privateKeyPem:keyId:path:host:date:)` (signing `(request-target) host
date`) and `FetchSigningKey {keyId, privateKeyPem}`, and changes `fetchActorDocument` to
`fetchActorDocument(actorUri:signingKey:)`. Step 0 reuses both types and adds no second GET
signer. If #279 changes before it merges, step 0 follows what merged.

The requirements follow Mastodon's `Request` and `fetch_resource`; the Reference column says
where FAP is stricter:

| Control | Requirement | Where it lives | Reference |
|---|---|---|---|
| Scheme | `https` on the initial URI and every hop | Middleware | Stricter than Mastodon, which allows `http` (`JsonLdHelper#unsupported_uri_scheme?`) |
| Redirects | At most 3 hops, each validated and, with a signer, re-signed | Middleware; AHC follows none | `request.rb:101-102,72-75` |
| Body | 1 MB cap. Abort the read past it. | Middleware | `request.rb:293-294` |
| Content type | The received `Content-Type` parses with the runtime's own `OpenAPIMIMEType` to a concrete type that matches a declared type: `application/activity+json`, or `application/ld+json` with the AS profile. Anything else is refused: missing, empty, unparsable or wildcard | Middleware (§0.1), with the generated client's match behind it | `JsonLdHelper#fetch_resource_without_id_validation`, `#valid_activitypub_content_type?`. Stricter than Mastodon on a multi-profile `ld+json` value (§0.1) |
| Status | Only 200 counts as success | Middleware, with the generated client's `.undocumented` case behind it | `JsonLdHelper#fetch_resource_without_id_validation` (`response.code == 200`) |
| Deadline | An absolute deadline per fetch, from the caller. It bounds the response head, which the middleware races against it, and it is checked on every body chunk, which stops a slow drip. A body that stalls completely sends no chunk to check and is bounded by `timeout.read` (§0.2) | Middleware; `timeout.read` on the `HTTPClient` | Platform limits |
| Address | Refuse every address Mastodon's private-address check refuses (§0.2), applied to the address actually connected to, on every connection | `HTTPClient` connection hook | Mastodon's `PrivateAddressCheck.private_address?`, called per connection (`request.rb:325-334,389-394`). Its `CIDR_LIST` (`app/lib/private_address_check.rb`) is adopted verbatim. The ranges behind its Ruby `IPAddr` predicates are named by FAP, not read from Ruby, so parity is claimed for `CIDR_LIST` only (§0.2) |

### 0.1 Shape

This section is the spec's design for decisions 14 and 16 (Decisions); the words quoted there are
the maintainer's, and everything here is this spec's.

- **One client per container.** A process-wide `RemoteFetchClient.shared` (an `internal` struct
  holding the generated `Client`), built once:
  - an `HTTPClient` (`swift-server/async-http-client`) configured as in §0.2;
  - `AsyncHTTPClientTransport` (`swift-server/swift-openapi-async-http-client`) over that
    `HTTPClient`, with its `timeout` set to the per-fetch deadline every caller uses (10 s, §0.2).
    Its `Configuration` is `init(client: HTTPClient = .shared, timeout: TimeAmount = .minutes(1))`
    (`Sources/OpenAPIAsyncHTTPClient/AsyncHTTPClientTransport.swift:71`, at tag 1.5.0, the
    version step 0 declares). The transport hands `configuration.client` and
    `configuration.timeout` to its request sender (`:214`), and `AsyncHTTPRequestSender.send`
    calls `client.execute(request, timeout: timeout)` (`:241-244`). So this is a backstop, not
    the per-fetch deadline;
  - the generated `Client`, with `serverURL` read from the document's own `servers:` entry
    through the generated `Servers` namespace, `try Servers.Server1.url()` (the generator emits
    one `Servers.Server<n>` enum per server with a static `url()` function,
    `Translator/TypesTranslator/translateServers.swift:119-160`, generator 1.11.1), and one
    middleware, `RemoteFetchMiddleware`. That entry is the placeholder origin
    `https://remote-fetch.invalid` (RFC 6761 §6.4: `.invalid` never resolves), so the origin is
    written once, in the document, and never as a literal in Swift.

  The shared `HTTPClient` lives for the life of the Lambda container and is never shut down or
  deinitialized; it is built on the shared singleton event-loop group
  (`eventLoopGroupProvider: .singleton`, as the spike's client is, FederatedActivityPublisher#283).
- **`shutdown()` for every other client.** `RemoteFetchClient` exposes `shutdown() async throws`,
  which calls the `HTTPClient`'s `shutdown()` (`AsyncAwait/HTTPClient+shutdown.swift:20`).
  - **Why.** AHC's `deinit` runs `preconditionFailure("Client not shut down before the deinit…")`
    for a client still `.upAndRunning`, inside `debugOnly` (`HTTPClient.swift:196-218`).
    `swift test` builds debug, so a test client that deinitializes without `shutdown()` crashes
    the test process.
  - **How.** Every `RemoteFetchClient` and `HTTPClient` a test builds is shut down on every exit
    path, the `defer` discipline. Because the tests are `async` and the blocking `syncShutdown()`
    is marked `noasync` (`HTTPClient.swift:225`), this is a test helper, `withTestClient(_:body:)`,
    that runs the body and awaits `shutdown()` on both the returning and the throwing path.
  - Production never builds a second client, and `RemoteFetchClient.shared` is never
    deinitialized.
- **Per-call context.** `fetchRemoteObject` and `fetchRemoteActor` each bind one `@TaskLocal`
  value, `RemoteFetchContext {target: URL, signer: FetchSigningKey?, deadline:
  ContinuousClock.Instant, schemePolicy: SchemePolicy}`, for the duration of the call. The
  middleware reads all four. `deadline` is the instant the caller passes for that fetch
  (§0.2, "Fetch deadlines by call site").
  The runtime gives middleware no other per-call channel:
  `intercept(_:body:baseURL:operationID:next:)` and `next:
  @Sendable (HTTPRequest, HTTPBody?, URL)` carry only the request, body, base URL and operation id
  (`apple/swift-openapi-runtime`, `Sources/OpenAPIRuntime/Interface/ClientTransport.swift`).
  `UniversalClient.send` awaits the middleware chain inline with no new `Task`, so the binding is
  visible in the middleware and isolated per task, which concurrent fetches on the one client
  rely on [inferred from source; the concurrent "One client" test measures it].
- **Why a TaskLocal and not a header parameter.** A declared header (`X-Fap-Target`) would show
  the target in the generated call's signature, but it puts a non-wire header in the document and
  the middleware would still need the signer, deadline and policy from somewhere else; a single
  TaskLocal carries all four, and keeping the generated client `internal` means no caller ever
  sees an operation without `fetchRemoteObject` or `fetchRemoteActor` around it.
- **Set at construction, not per call.** The address policy (§0.2) and the TLS trust roots are
  properties of the `HTTPClient`. Production uses the address policy below and the system trust
  store. Tests build their own `RemoteFetchClient` with a test address policy and a test CA.
- **Injection.** The public functions are `fetchRemoteObject(uri:signer:deadline:)` and
  `fetchRemoteActor(uri:signer:deadline:)`, with `signer: FetchSigningKey? = nil`. Each calls an
  `internal` overload that adds `schemePolicy: SchemePolicy` and `client: RemoteFetchClient`, and
  passes `.httpsOnly` and `.shared`. `SchemePolicy` and `RemoteFetchClient` are `internal` types,
  so no code outside `ActivityPubCore` can pass a test-only policy or client; tests reach the
  overloads through `@testable import ActivityPubCore`, as they reach the middleware's check
  switch (Testing). Every production call site passes only `uri`, `deadline` and, where it has
  one, `signer`. A test passes its own client; no global is swapped.
- **How `KeyManager` gets the client.** `KeyManager` (a `Sendable` struct, `KeyManager.swift:26`)
  gains a stored `let client: RemoteFetchClient`. Its `public init()` sets it to
  `RemoteFetchClient.shared`, and an `internal init(client:)` takes a test client.
  `fetchActorDocument(actorUri:signingKey:deadline:)` calls the internal
  `fetchRemoteActor` overload with `client: self.client`. `RemoteFetchClient` is `Sendable` (it
  holds the generated `Client` and the `HTTPClient`), so `KeyManager` stays `Sendable`.
  `getPublicKey` and `refreshKey` keep #279's `signingKey:` closure and gain
  `deadline: ContinuousClock.Instant`. InboxHandler's `let keyManager = KeyManager()`
  (`InboxHandler/main.swift:50`) is unchanged. The `client:` parameter an earlier revision named
  on `fetchActorDocument` is replaced by this stored property.
- **Signing keys: `ActorKeyCache`.** Step 0's quote path signs as the posting actor, so step 0
  adds the one key cache every signer uses. `ActorKeyCache` is a `final class` in
  `ActivityPubCore`, `Sendable`, with two stored `let`s: the private keys by username, in a
  `Mutex<[String: String]>` from the standard library's `Synchronization` module, and a
  `@Sendable` loader that reads `{SSM_KEY_PREFIX}/{username}`. `Mutex` is declared
  `public struct Mutex<Value: ~Copyable>: ~Copyable`, conforms `@unchecked Sendable` where
  `Value: ~Copyable`, and offers `withLock(_:)`, whose closure is synchronous
  (swiftlang/swift `main`, `stdlib/public/Synchronization/Mutex/Mutex.swift`, read 2026-10-21).
  It is `@available(SwiftStdlib 6.0, *)`, which is macOS 15.0 (`utils/availability-macros.def`
  in the same repository), and FAP's platform floor is `.macOS(.v15)` (`Package.swift:7`).
  - **Owner.** Each handler that signs builds one, as a top-level `let`, once per container:
    `PostHandler` and `InboxHandler` in step 0 (in `InboxHandler` it replaces #279's
    `nonisolated(unsafe) var cachedActorKeys`), and `SearchHandler` and `DeliverHandler` in
    phase 3a. `DeliverHandler` today reads SSM on every job (`DeliverHandler/main.swift:52-58`).
  - **Concurrency.** `signingKey(for:)` reads the dictionary inside `withLock`. On a miss it
    awaits the loader outside the lock, then stores the key inside a second `withLock`. No lock
    is held across an `await`. Two concurrent misses for one username both read SSM and store the
    same value.
  - **Key rotation.** The cache is never invalidated, so a warm container keeps signing with the
    key it first read until the container ends. FAP has no rotation operation: after #279 the
    provisioner refuses an actor that already exists (its test
    `provisioningExistingActorFailsAndChangesNothing`, `Tests/ActivityPubCoreTests/ActorProvisioningTests.swift`).
    A key changed in SSM by other means reaches a container only when that container is
    replaced. Until then remote servers, which fetch the actor's new public key, reject that
    container's signatures. A rotation feature would have to clear this cache, and is out of
    scope.
- **One middleware.** `RemoteFetchMiddleware` does the whole exchange, so there is no separate
  URL-rewrite middleware and no FAP transport:
  1. Throw if no context is bound, so the placeholder origin is never contacted.
  2. For each hop (the initial request plus at most 3 redirects): throw the deadline error,
     before connecting, if the context's deadline has passed; check the hop's scheme against
     `schemePolicy`; set the base URL to the hop's origin and the request's path and query to the
     hop's, byte for byte (`HTTPRequest.path` is the `:path` pseudo-header, path plus query, in
     `apple/swift-http-types`); with a signer, add the headers from `HTTPSignature.signGet` using that path-and-query and the
     `host[:port]`, as #279's `KeyManager.actorDocumentRequest(url:signingKey:)` does; call
     `next` under the remaining time.
  3. On a 3xx with a `Location`, discard the body, resolve `Location` against the hop's URL and
     loop. A 4th redirect throws.
  4. On any other response, require status 200, or throw the status error. Then read the
     `Content-Type` as the runtime does, `headerFields[.contentType]` parsed with
     `OpenAPIMIMEType(_:)` (`Converter+Common.swift:30-33`), and require that it parses to a
     `.concrete` kind and matches a declared type (below). Anything else throws the content-type
     error: a missing header, an empty value, a value that doesn't parse (`html`, `*/html`,
     `text/html/x`), `*/*`, a partial wildcard such as `text/*`, and an undeclared concrete type.
     Then return the response with its body wrapped in a sequence that throws past 1 MB and past
     the deadline.
- **The document.** `Sources/ActivityPubCore/openapi.yaml`, with
  `Sources/ActivityPubCore/openapi-generator-config.yaml` beside it. The generator plugin reads
  a file of that name from the target's source directory (`Plugins/PluginsShared/PluginError.swift:110`,
  generator 1.11.1). It is not the repository-root `openapi.yaml` that describes FAP's own API,
  and the mirror workflow triggers on the root file only (`.github/workflows/sync-openapi.yml:5,12`).
  It declares `servers: [{url: https://remote-fetch.invalid}]` and two operations, `getObject`
  (`GET /object`) and `getActor` (`GET /actor`). Their paths are placeholders, like the origin:
  the middleware replaces path and query with the hop's. Each declares a 200 response under both
  ActivityStreams content types, with a typed schema (decision 16).
- **Typed schemas** (decision 16). The schemas declare the fields FAP reads and nothing else:
  - **`RemoteActor`**: `id` (string) and `inbox` (string) required; `endpoints` (an object
    with an optional string `sharedInbox`), `publicKey`, `followers` (string), `url` and
    `preferredUsername` (string) optional. `preferredUsername` is not in the decision's list; it
    is declared because the existing parser reads it (`KeyManager.swift:101`) and the remote
    `REF#` entry stores it (§3.1), and an undeclared field is dropped (below). `publicKey` is
    `PublicKeyValue`: `oneOf` a `PublicKey` object (`publicKeyPem` string required, `id` and
    `owner` strings optional) or an array of them.
  - **`RemoteObject`**: `id` and `type` required; `attributedTo`, `to`, `cc`, `url`, `content`,
    `summary`, `sensitive` (boolean), `published` (string) and `contentMap` (an object whose
    values are strings) optional. These are the fields §3.3 validates (`id`, `type`,
    `attributedTo`, `to`, `cc`) and the fields the remote `REF#` entry stores (§3.1).
  - **Value or array.** Every field JSON-LD lets appear as a value, an object or an array uses
    `oneOf`, through shared component schemas: `type` is `oneOf` a string or an array of strings;
    `attributedTo`, `to` and `cc` are `IdRefs`, `oneOf` an `IdRef` or an array of `IdRef`, where
    `IdRef` is `oneOf` a string or an object with a required string `id`; `url` is `UrlValue`,
    `oneOf` a string, a `Link` (an object with a required string `href`) or an array of strings
    and `Link`s.
  - **How the generator handles `oneOf`.** A `oneOf` without a discriminator becomes an enum
    with one case per child, named `case1`, `case2`… for inline children and after the type for
    references (`Translator/CommonTranslations/translateAllAnyOneOf.swift:126-170`). Its decoder
    tries each case in declared order and keeps the first that decodes
    (`Translator/CommonTranslations/translateCodable.swift:260-281`). When none does, it throws
    `DecodingError.failedToDecodeOneOfSchema` (`:299-311`), which the runtime builds as a
    `DecodingError.valueNotFound` carrying every case's error (`Conversion/ErrorExtensions.swift:52-65`,
    runtime 1.11.0). Cases are ordered so the first match is the intended one: string before
    object, single value before array.
  - **Unknown fields are tolerated.** No schema sets `additionalProperties`. When it is unspecified,
    the generator emits no custom `Codable` code and the compiler synthesizes it from the stored
    properties (`Translator/CommonTranslations/translateObjectStruct.swift:139`, returning
    `.synthesized`; `translateCodable.swift:36`, which returns no decoder for that strategy; and
    the generator's documentation, `Documentation.docc/Development/Generating-custom-Codable-conformance-methods.md:30-32`).
    `additionalProperties: false` is the case that adds `ensureNoAdditionalProperties` (`:33-35`;
    `translateCodable.swift:37-47`), and the document never uses it. So the many fields an
    ActivityPub document carries beyond these are skipped, and only the declared fields are
    checked: a missing required field, or a declared field of the wrong JSON type, refuses the
    document. A JSON `null` in an optional field reads as absent.
- **How the typed results are consumed.** The generated types are `internal`. `fetchRemoteObject`
  and `fetchRemoteActor` map them to two public FAP structs, so no caller sees a generated type
  or a `[String: Any]`:
  - **`RemoteObjectDocument`** `{id, types: [String], attributedTo: String?, to: [String],
    cc: [String], url: String?, content, summary: String?, sensitive: Bool?, published: String?,
    language: String?}`. `attributedTo` is Mastodon's `value_or_id(first_of_value(...))`
    (`fetch_remote_status_service.rb:29`): the first entry, as its string or its `id`. `to` and
    `cc` are every entry the same way. `url` is the §2.7 step 1 candidate: the string, or the
    first `Link`'s `href`, or the first string. `language` is `contentMap`'s key when it has
    exactly one, and `nil` otherwise.
  - **`RemoteActorDocument`** `{id, inbox, sharedInbox: String?, publicKeyPem: String?,
    followers: String?, url: String?, preferredUsername: String?}`. `publicKeyPem` is the first
    `PublicKey` entry's; `url` is chosen as for the object.
  - **Callers at `8a78008`:**
    - `PostHandler/main.swift:264-265`: the quote path's status fetch becomes
      `fetchRemoteObject(uri: quotedId, signer:, deadline:)` and reads `.attributedTo` instead of
      `["attributedTo"] as? String`. An `attributedTo` given as an object or an array now
      resolves where today only a bare string did.
    - `PostHandler/main.swift:272-273`: the actor fetch becomes `fetchRemoteActor(...)` and reads
      `.inbox`.
    - `InboxHandler/main.swift:1598-1599`: the QuoteRequest actor lookup becomes
      `fetchRemoteActor(...)` and reads `.inbox`.
    - `KeyManager.swift:68-118`: `fetchActorDocument` calls `fetchRemoteActor` and builds the
      `RemoteActor` record from `.publicKeyPem`, `.inbox`, `.sharedInbox` and
      `.preferredUsername`. The hand parser at `:89-105` is deleted. `KeyManagerError.missingPublicKey`
      stays, for an actor without `publicKey`. `fetchFailed`, `invalidJSON` and `missingInbox` are
      no longer thrown, because the fetch errors and the schema's required `inbox` now refuse
      those documents first, and they are removed.
    - `InboxHandler/main.swift:125,153,390`: `getPublicKey` and `refreshKey` gain `deadline:`.
  - The bytes are decoded once, by the generated client.
- **Content type and status: the middleware checks, the generated layer stands behind.**
  - **Parsing.** `OpenAPIMIMEType` is declared `@_spi(Generated) public struct`
    (`Base/OpenAPIMIMEType.swift:22`, runtime 1.11.0), so the middleware imports it with
    `@_spi(Generated) import OpenAPIRuntime`, as generated code does. `init?(_:)` splits the value
    on `;` and returns `nil` when nothing is left, as for an empty value, or when the first part
    is not a valid kind (`:123-130`). `Kind.init?(_:)` returns `nil` unless that part splits on
    `/` into exactly two parts, and for a `*` type with a subtype other than `*` (`:97-107`). So
    `html`, `*/html` and `text/html/x` don't parse. Reading the header with the runtime's own
    parser means the middleware and the generated client see the same value.
  - **Matching.** The runtime's matcher, `OpenAPIMIMEType.evaluate`, is `internal` (`:206-251`),
    so the middleware applies its rule for a concrete received type itself. Type and subtype
    compare case-insensitively. Every parameter of the declared type must be present in the
    received one, with parameter names compared case-insensitively and values case-sensitively.
    Extra received parameters are ignored (`:217-249`). With the two declared types, a bare
    `application/ld+json` is refused and `application/activity+json; charset=utf-8` is accepted.
  - **Why the middleware owns it.** The runtime's match covers concrete received types only.
    `extractContentTypeIfPresent` returns `nil` both for a missing header and for one that doesn't
    parse (`Converter+Common.swift:30-33`). `bestContentType` returns the first option when it gets
    `nil` *or* a non-concrete type (`guard let received, case let .concrete(...) = received.kind
    else { return options[0] }`, `:45-53`; a partial wildcard is treated as `*/*`, per the comment
    at `:48-51`). So without the middleware, a missing, empty, unparsable or wildcard
    `Content-Type` would be read as `application/activity+json`. Owning the whole check also gives
    the middleware one switch for the test's negative control (Testing). The runtime's match still
    runs behind it and refuses the same undeclared concrete types: `bestContentType` throws
    `RuntimeError.unexpectedContentTypeHeader` when every option is `.incompatible` (`:43-76`).
  - **Status.** The middleware refuses any final status other than 200 with its status error. A
    status not in the document also comes back from the generated client as the `.undocumented`
    case. Both functions turn that case into `generatedLayerRefused(underlying:)`, whose underlying
    error is FAP's internal `UndocumentedStatusError(statusCode:)`, so a test can tell which layer
    refused.
- **Stricter than Mastodon on multi-profile `ld+json`.** Mastodon's
  `valid_activitypub_content_type?` splits the quoted `profile` value on whitespace and accepts it
  when any entry is the AS profile (`str[9...-1].split.include?(…)` in
  `JsonLdHelper#valid_activitypub_content_type?`).
  The middleware, like `OpenAPIMIMEType.evaluate`, compares the whole parameter value, so FAP
  rejects an
  `application/ld+json` whose `profile` lists the AS profile beside another one. This spec keeps
  that difference rather than adding a profile parser; a remote server that sends only such a value
  cannot be fetched by FAP.
- **Errors arrive wrapped.** The runtime wraps every error thrown by the transport, by a middleware
  or while decoding the response in `ClientError` (`Interface/UniversalClient.swift:94-185`). For
  transport and middleware failures it puts the original error in `underlyingError`
  (`Errors/RuntimeError.swift:77-83`), and for a non-runtime error thrown while decoding, such as
  the body wrapper's size or deadline error, the error itself (`UniversalClient.swift:119-126`;
  `Errors/ClientError.swift:71`). `fetchRemoteObject` and `fetchRemoteActor` unwrap
  `ClientError.underlyingError` before mapping to their own error cases, and the Step 0 tests
  assert on the unwrapped case. A failure in
  the generated decode step is a `ClientError` with `response` set whose underlying error is not
  one of FAP's, and its two causes can be told apart:
  - **An invalid document.** The runtime's JSON body decode, `getResponseBodyAsJSON`
    (`Conversion/Converter+Client.swift:315-327`), ends in `convertJSONToBodyCodable`, which calls
    `decoder.decode(T.self, from: data)` (`Conversion/CurrencyExtensions.swift:140-143`) and so
    throws Swift's `DecodingError`, both for bytes that are not JSON and for JSON that does not
    match the schema: a missing required field, a declared field of the wrong type, or a `oneOf`
    no case matches (`DecodingError.valueNotFound`, above). That is not a `RuntimeError`, so
    `makeError` puts it in `underlyingError` unchanged (`UniversalClient.swift:123-126`).
  - **A content type the runtime refuses.** `RuntimeError.unexpectedContentTypeHeader`
    (`Errors/RuntimeError.swift:46`) has a `nil` `underlyingError` (`:77-83`), so `makeError`
    puts the `RuntimeError` itself there (`UniversalClient.swift:120-122`). `RuntimeError` is
    `internal` (`:23`), so FAP can't match its case.

  **Telling the generated layer from the transport.** The runtime sets `ClientError.response`
  only for an error thrown after the response head, in the deserializer
  (`Interface/UniversalClient.swift:179-188`, runtime 1.11.0). An error from the transport is
  wrapped with no response (`:146-155`, as `RuntimeError.transportFailed`), and one from a
  middleware likewise (`:160-175`). Both functions map the unwrapped error in this order:
  1. A `RemoteFetchError` thrown by the middleware, the hook or the body wrapper is rethrown as
     it is.
  2. A `DecodingError` becomes `invalidDocument`, carrying it.
  3. An `HTTPClientError` from AHC, such as `readTimeout` (`HTTPClient.swift:1596`), becomes
     `transportFailed(underlying:)`, whether or not `response` is set: a body that stalls after
     the head fails in AHC, not in the generated layer.
  4. Any other error with `response` set becomes `generatedLayerRefused(underlying:)`, as does
     the `.undocumented` case (above). That is everything the generated layer refuses behind the
     middleware: an undocumented status, and a content type the runtime's match refuses.
  5. Everything else becomes `transportFailed(underlying:)`: a refused or reset connect, which
     AHC passes on as the raw connection error when retries are off
     (`ConnectionPool/State Machine/HTTPConnectionPool+HTTP1StateMachine.swift:260-271`), or a TLS
     verification failure.

  With every middleware check on, production reaches `generatedLayerRefused` only if the
  middleware and the runtime disagree, because the middleware refuses those responses first. The
  case exists so that a test with one middleware check switched off can see the generated layer
  refuse, and it replaces the two separate cases, `undocumentedStatus` and `decodeFailed`, an
  earlier revision had for that purpose (Testing).
- **The error type.** `fetchRemoteObject` and `fetchRemoteActor` throw one public enum,
  `RemoteFetchError: Error, Sendable`, which replaces today's `FetchRemoteObjectError`
  (`FetchRemoteObject.swift:19-26`, used nowhere else in `Sources/` or `Tests/`). Every other
  section names these cases by their meaning ("the deadline error" and so on); this is the one
  declaration:
  - `invalidURI(String)`: the URI does not parse as an absolute URL.
  - `noContext`: the middleware ran with no `RemoteFetchContext` bound ("the no-target error").
  - `schemeRefused(URL)`: a hop's scheme is not admitted by the scheme policy ("the scheme
    error").
  - `tooManyRedirects(URL)`: a 4th redirect ("the redirect error").
  - `deadlineExceeded`: the fetch's deadline passed before a hop, during the head, or at a body
    chunk ("the deadline error").
  - `status(Int)`: the final status was not 200 ("the status error").
  - `contentType(String?)`: the `Content-Type` was missing, empty, unparsable, a wildcard or
    undeclared ("the content-type error").
  - `bodyTooLarge`: the body passed 1 MB ("the size error").
  - `addressRefused(String)`: the connection hook refused the connected address ("the address
    error").
  - `invalidDocument(DecodingError)`: the body is not JSON, or doesn't match the operation's
    schema.
  - `generatedLayerRefused(underlying: any Error)`: the generated layer refused a response the
    middleware passed (below).
  - `transportFailed(underlying: any Error)`: the connection, TLS or AHC failed (below).

  `UndocumentedStatusError(statusCode:)`, the underlying error for an undocumented status, is
  `internal`. `KeyManager.fetchActorDocument` lets these errors through unchanged.
- **The generated client is `internal`** (`accessModifier: internal` in
  `openapi-generator-config.yaml`). Only `fetchRemoteObject`, `fetchRemoteActor` and the two
  document structs are public.
- **Where it lives, and what that costs.** The client is generated inside `ActivityPubCore`,
  beside `fetchRemoteObject`, `KeyManager`, `HTTPSignature` and `FetchSigningKey`. A separate
  target is possible only if those move out of `ActivityPubCore` with it, because `KeyManager`
  calls the client and the middleware calls `HTTPSignature`; left where they are, a separate
  target and `ActivityPubCore` would each need the other. This spec keeps them in
  `ActivityPubCore`, and accepts the cost: every target that links `ActivityPubCore` links AHC,
  and every build of `ActivityPubCore` runs the generator plugin. At `8a78008` that is 17 of the
  19 deployed handlers (all but `NodeInfoHandler` and `InstanceHandler`, whose dependencies
  don't include it, `Package.swift`), plus `ActivityProvisioner`, and phase 2's `SearchHandler`
  makes 18 of 20. Only four handlers fetch: `PostHandler` and `InboxHandler` from step 0,
  `SearchHandler` and `DeliverHandler` from phase 3a. The other fourteen carry AHC and never
  call it.

### 0.2 The `HTTPClient` configuration

Each setting below was required by the spike, FederatedActivityPublisher#283, or follows from its
findings.

**Versions behind the line references.** Third-party file:line references in this spec are to
the versions one maintainer host resolved locally as of 2026-10-20: `async-http-client` 1.33.1,
`swift-openapi-runtime` 1.11.0, `swift-openapi-generator` 1.11.1 and `swift-nio-ssl` 2.36.1; the
same host resolved `swift-nio` 2.97.1 and `swift-nio-http2` 1.42.0.
`Package.resolved` is gitignored (`.gitignore:3`), so FAP commits no lockfile and CI resolves the
`from:` ranges in `Package.swift` fresh; it may build later versions. The step 0 PR records, in
its description, the versions CI resolved for its build, and re-checks each cited line against
them.

| Setting | Why | Evidence |
|---|---|---|
| `http1_1ConnectionDebugInitializer` checks `channel.remoteAddress` against the address policy and fails the future for a refused address (`HTTPClient.swift:922`) | The address check (C1, C2) | C1 [measured+negative-control]: T1 throws the hook's error and the server receives 0 bytes; T1-control, hook removed, gets 200 and the server receives bytes. C2 [measured]: `remoteAddress` was non-nil in every hook call. macOS and Linux CI (run 39520739042). |
| The hook calls `channel.close()` itself before failing | AHC passes a hook failure to `failedToCreateHTTPConnection` and does not close the channel (`HTTPConnectionPool+Factory.swift:84-92`) | [measured+negative-control]: T1 (no close) left the connection open, `closes=0`; T1c (close in the hook) `closes=1`, still 0 bytes |
| `connectionPool.retryConnectionEstablishment = false` (default `true`, `HTTPClient.swift:1396`) | With retries on, a refused host is reconnected with backoff until the deadline | [measured+negative-control]: T1, retries off, 1 connection; T1b, retries on, 7 connections in 2 s on macOS and 9 on Linux, 0 bytes each |
| `httpVersion = .http1Only` (`HTTPClient.swift:1428`) | The hook only runs for HTTP/1.1 connections; HTTP/2 has its own `http2ConnectionDebugInitializer` (`HTTPConnectionPool+Factory.swift:114`) | [inferred from source]; the step 0 h2 test measures it (Testing) |
| `proxy = nil` | Through a proxy, `remoteAddress` is the proxy's | Set explicitly; the spike's clients set it (`config.proxy = nil`) |
| `redirectConfiguration = .disallow` (`HTTPClient.swift:1351`) | Redirects come back to the middleware, which validates and re-signs each hop | C3 [measured+negative-control]: T2, `.disallow`, the caller gets the 302 and the target gets 0 connections; T2-control, `.follow(max: 3, allowCycles: false)`, the target is contacted |
| `timeout.connect = .seconds(5)` and `timeout.read = .seconds(10)` (`HTTPClient.swift:1249,1251`) | `connect` bounds connection setup; AHC's default is 10 s (`connectionCreationTimeout`, `HTTPClient.swift:1256-1258`). `read` is an idle timeout: AHC passes it as the request's `idleReadTimeout` (`ConnectionPool/RequestOptions.swift:44`) and restarts it on every response part read (`ConnectionPool/HTTP1/HTTP1ClientChannelHandler.swift:148`); it has no default, so without it a fully stalled body is never ended. Both values are Mastodon's `connect_timeout: 5` and `read_timeout: 10` (`app/lib/request.rb:86`). Per fetch, the worst case is the 10 s deadline on the head plus one `timeout.read` on a stalled body, 20 s. Two such fetches in sequence exceed the 29 s API Gateway limit ("Fetch deadlines by call site", below; FederatedActivityPublisher#284) | The values are a choice. That `read` ends a stalled body is [unverified] until the stall test runs |

**Address policy: Mastodon's, adopted verbatim.** The policy refuses every address Mastodon's
`PrivateAddressCheck.private_address?` refuses. Source: `app/lib/private_address_check.rb` in
`mastodon/mastodon` at `main`, read 2026-10-21
(https://github.com/mastodon/mastodon/blob/main/app/lib/private_address_check.rb). The file last
changed in commit `467c933459c7d0e5513475b9e4888afaedfb1074` (2026-07-27), so it is the same at
the `2c540e4` head the Standards section cites. The method unwraps an IPv4-mapped or
IPv4-compatible IPv6 address to IPv4, then refuses it if `IPAddr#private?`, `#loopback?` or
`#link_local?` holds or if it falls in `CIDR_LIST`. FAP adopts that as follows:
- **`CIDR_LIST`, verbatim, all 24 entries.** IPv4: `0.0.0.0/8`, `100.64.0.0/10`,
  `172.16.0.0/12`, `192.0.0.0/24`, `192.0.2.0/24`, `192.88.99.0/24`, `198.18.0.0/15`,
  `198.51.100.0/24`, `203.0.113.0/24`, `224.0.0.0/4`, `240.0.0.0/4`, `255.255.255.255`. IPv6:
  `::/128`, `64:ff9b::/96`, `64:ff9b:1::/48`, `100::/64`, `2001::/32`, `2001:10::/28`,
  `2001:20::/28`, `2001:db8::/32`, `2002::/16`, `fc00::/7`, `3fff::/20`, `ff00::/8`.
- **The three Ruby predicates, as named ranges.** Ruby's `IPAddr` source was not read for this
  spec, so FAP does not claim to reproduce those predicates exactly. It refuses, by name, the
  ranges they stand for: private `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` and
  `fc00::/7`; loopback `127.0.0.0/8` and `::1`; link-local `169.254.0.0/16` and `fe80::/10`.
  These are the ranges FAP's earlier policy already refused.
- **Unwrapping** (this spec's design, following the method's first line). `::` and `::1` are
  checked first, as IPv6. An IPv4-mapped address (`::ffff:0:0/96`) or an IPv4-compatible one
  (`::/96`) is then checked as the IPv4 address it embeds. NAT64 (`64:ff9b::/96`,
  `64:ff9b:1::/48`) and 6to4 (`2002::/16`) addresses also embed an IPv4 address, and need no
  unwrapping, because their whole prefixes are refused.

The spike's policy test covers 20 literals, among them `::ffff:127.0.0.1`,
`::ffff:169.254.169.254`, `fe80::1` and `fd00::1`; step 0's classifier test adds a literal for
every range above (Testing). A test policy admits named loopback ports only.

**What the hook does not prevent, stated plainly.** The hook runs after the connection is set
up: after the TCP connect, and for `https` after the TLS handshake, since the factory completes
the connection only once `tlsEstablishedFuture` has fired (`HTTPConnectionPool+Factory.swift:532`).
So a refused address still receives a TCP connection, and for `https` a TLS ClientHello with the
requested host as SNI. Only the HTTP request is blocked: no request line, headers or signature
reach it. The spike measured the plain-`http` case; the `https` ordering is from the source.

**Deadline.** The middleware runs each hop's `next` raced against the remaining time and cancels
it on expiry; AHC's `execute` honours task cancellation (`AsyncAwait/HTTPClient+execute.swift:170-173`).
That covers the response head only: `execute` returns once the head arrives ("the `body` of the
response may not yet have been fully received", `:38`). After that, the body is read in the
caller's task during the generated decode, and nothing in this design cancels that read. The body
wrapper checks the deadline on every chunk, which stops a slow drip. A body that stalls
completely sends no chunk to check, so it is bounded by `timeout.read` alone. AHC starts that
timer once the request end is sent (`ConnectionPool/HTTP1/HTTP1ClientChannelHandler.swift:234,294`)
and restarts it on every response part (`:148`). When it fires while the head or body
is awaited, it fails the request with `HTTPClientError.readTimeout` and closes the connection
(`ConnectionPool/HTTPRequestStateMachine.swift:738-741`).

**Fetch deadlines by call site.** Each fetch gets its own deadline, `ContinuousClock.now` plus
10 s when the call is made; the middleware checks it before every hop of that fetch, the first
included, and throws its deadline error without connecting once it has passed. One fetch can
take up to 10 s + 10 s = 20 s: the deadline bounds the head, and a body that stalls after the
last byte runs on until `timeout.read` fires (Deadline, above). Search is the one caller that
passes a single overall deadline to all its fetches: that is §3.3's 10 s search deadline,
unchanged and kept by decision 15. A time budget shared across all the fetches in one request,
for the other handlers, was dropped (decision 17) and is FederatedActivityPublisher#284.

| Call site | Fetches, in sequence | Deadline of each fetch | Worst case for the fetches | Limit |
|---|---|---|---|---|
| `PostHandler`, quote path (`PostHandler/main.swift:264,272`) | The quoted status, then its actor on a `REMOTE_ACTOR#` miss | 10 s from that fetch's call | 20 s per fetch, 40 s for both. **Known gap: over the 29 s limit** (#284) | `ClientApi`, a REST API with no timeout override (`activity-app/functions/template.yaml:111-120`; the route at `:142-144`), so 29 s; function timeout 60 s (`:127`) |
| `InboxHandler` (`InboxHandler/main.swift:125,153,390,1598`) | The key fetch on a cache miss, the refresh after a failed verification, then either the Follow path's refresh on a cache miss or the QuoteRequest actor lookup | 10 s from that fetch's call | 20 s per fetch, up to 60 s for three. **Known gap: two fetches already exceed the 29 s limit and the 30 s function timeout** (#284) | The implicit `ServerlessRestApi`: `PostInbox` is `Type: Api` with no `RestApiId` (`activity-app/functions/template.yaml:434-439`), and the stack outputs it as `ServerlessRestApiId` (`:538-540`), so it is a REST API and 29 s applies; function timeout 30 s (Globals, `:76-77`) |
| `SearchHandler`, phase 3a (§3.3) | The object, the re-fetch of a non-canonical `id`, and the actor | §3.3's one 10 s overall deadline, from the start of the request | 20 s in all: once the deadline has passed, every later fetch fails at its first hop check | `ClientApi`, 29 s |
| `DeliverHandler`, phase 3a (§3.5) | *R*'s actor, once per job | 10 s from that fetch's call | 20 s | Not behind API Gateway. Function timeout 60 s (`activity-app/functions/template.yaml:446`). The POST that follows has its own 30 s idle timeout (`DeliverHandler/main.swift:92`) and is outside this spec (FederatedActivityPublisher#277) |

The quote path and the inbox are within the limit when every fetch answers promptly, and a single
fetch is within it in the worst case. Only a run of slow fetches in one request can pass 29 s,
and what follows differs:
- **Quote path: a duplicate post on retry.** API Gateway answers the client 504 at 29 s. The
  function's own timeout is 60 s (`activity-app/functions/template.yaml:127`), so Lambda does not
  stop it at 29 s. That API Gateway leaves the invocation running after its 504 is [inferred]:
  neither AWS page read for it, the REST API quotas page (Platform limits) and Lambda's
  synchronous-invocation page (https://docs.aws.amazon.com/lambda/latest/dg/invocation-sync.html),
  both read 2026-10-21, says what happens to the function. If it keeps running, it continues
  past both quote fetches (`PostHandler/main.swift:264-273`) to `storeStatus` (`:319`), counts
  the status and enqueues its delivery. FAP has no client idempotency key (the only idempotency
  in `Sources/` is the inbox's activity dedup, `DynamoDBStore.swift:256` onward), so a client
  that retries after the 504 creates a second, duplicate post.
- **Inbox: lost at `8a78008`, delayed with #279.** The function's 30 s timeout (Globals,
  `:76-77`) stops the invocation. What a redelivery then does depends on where the fetches sit
  relative to the dedup write:
  - **The key fetch and its refresh** (`InboxHandler/main.swift:125,153`) run during signature
    verification, before any dedup write. A delivery killed there leaves no record, and the
    remote server's redelivery is processed normally.
  - **The Follow path's refresh and the QuoteRequest actor lookup** (`:390`, `:1598`) run after
    it. At `8a78008` the inbox marks the activity seen with `storeReceivedActivity` before routing
    (`:211`), and a redelivery of a seen activity gets 202 "already processed" (`:219-226`). So a
    delivery killed in one of those fetches is lost, and nothing logs it.
  - **With FederatedActivityPublisher#279, which step 0 builds on**, the inbox claims the
    activity instead (`DynamoDBStore.claimReceivedActivity`, a `pending` record whose
    `claimExpiresAt` is `activityClaimLease`, 300 s, ahead), and `processActivityOnce` marks it
    processed with `completeReceivedActivity` only after the handler succeeds, or drops the claim
    with `releaseReceivedActivity` after it fails. A killed invocation runs neither, so the claim
    stays `pending` until the lease expires. A redelivery inside the lease finds it `pending`,
    gets `ActivityClaim.inProgress`, and is answered 503; the claim's conditional write admits the
    first redelivery after `claimExpiresAt` (`processingState = :pending AND claimExpiresAt <
    :now`), which processes the activity. So with #279 the activity is delayed by at least the
    300 s lease, not lost. When the remote server retries is its own schedule, which this spec
    does not rely on.

This spec does not close that gap; #284 tracks it. The transport's 10 s `timeout` backstop
(§0.1) applies per hop, inside each fetch's deadline, and doesn't raise the worst case.

**Dependencies.**
- **`swift-server/swift-openapi-async-http-client`** (product `OpenAPIAsyncHTTPClient`), a new
  package entry declared `from: "1.5.0"`, its latest release tag
  (github.com/swift-server/swift-openapi-async-http-client/releases/tag/1.5.0, read 2026-10-20).
  It is a new third-party dependency, and the maintainer approved it on 2026-10-20 (decision
  15). It follows from the transport choice in decision 14's implementation, which is this
  spec's design, not the maintainer's words.
- **`swift-server/async-http-client`** becomes a direct dependency of `ActivityPubCore`,
  declared `from: "1.33.1"`. The maintainer approved this on 2026-10-21 (decision 16). It is
  already resolved through `smithy-swift`, and the spike's `Package.swift` change left the
  resolved pins unchanged (#283).
- **`apple/swift-nio`** (`from: "2.97.1"`), **`apple/swift-nio-ssl`** (`from: "2.36.1"`) and
  **`apple/swift-nio-http2`** (`from: "1.42.0"`) get package entries so that the test target can
  depend on `NIOCore`, `NIOPosix`, `NIOSSL` and `NIOHTTP2` directly (Testing). No production
  target names them. The maintainer approved these as direct test-target dependencies on
  2026-10-21 (decision 16). All three are already resolved through `async-http-client`.
- **Floors.** The step 0 PR raises `swift-openapi-generator` from `from: "1.6.0"` to
  `from: "1.11.1"`, and `swift-openapi-runtime` from `from: "1.7.0"` to `from: "1.11.0"`
  (`Package.swift:36-37`), the versions behind this spec's line references. Each new entry above
  is declared at the version cited for it. A lower floor would let a fresh resolution build
  against code the cited lines were never read in.
- **First use in the deployed build.** Nothing imports `APIClient` today (only
  `Package.swift:240` names it), so `OpenAPIRuntime`, `AsyncHTTPClient` and the generator plugin
  reach the deployed Lambdas, and the plugin runs in the Lambda archive build, for the first
  time. Seventeen of the 19 deployed handlers link `ActivityPubCore`, and so AHC (§0.1, "Where
  it lives, and what that costs").

**Deployed build (C4, not yet measured).** The deploy build is
`swift package --allow-network-connections docker archive --base-docker-image swift-al2023:6.3`
(`deploy-stage.yml:326`): a glibc Amazon Linux 2023 image with the UBI9 Swift toolchain
(`docker/Dockerfile.al2023-swift`), with `libcrypto.so.3` and `libssl.so.3` copied into each
zip's `lib/` (`deploy-stage.yml:334-350`). It is not the static Linux SDK. No deployed handler
links AHC today (#283: 0 `AsyncHTTPClient` symbols in each of the 19 handler binaries), so the
existing deploy build says nothing about it.

C4 is measured on stage, after merge, and fixed forward. That follows the maintainer's
2026-06-12 call on build validation, as the repository's `CLAUDE.md` records it: PR CI validates
with `swift test`, the full archive build runs only in `deploy-stage` after merge, no runner VM is
used by hand, and a broken archive build is fixed forward. The step 0 PR's CI is therefore
`swift test` on Linux (`.github/workflows/test.yml:13`), and step 0 adds no archive job to PR CI.
- **Pass.** The `deploy-stage` run for the step 0 merge commit builds the archive
  (`deploy-stage.yml:326`) and deploys, and on stage an inbound delivery signed by an actor whose
  key is not cached in `REMOTE_ACTOR#`, for example a first Follow from a remote account, verifies.
  That verification needs a key fetch, and after step 0 the only GET path in `ActivityPubCore` is
  the AHC client, so the fetch ran on AHC in the deployed binary.
- **Fail.** The archive step fails, a handler fails to start, or that key fetch fails with a
  transport error. A follow-up PR fixes it forward.
- **Release.** No prod release containing step 0 is cut until C4 has passed on stage. Prod
  deploys only from a release tag (`CLAUDE.md`, Architecture).
- **Control.** The before state is #283's count, 0 `AsyncHTTPClient` symbols in each handler
  binary. The fetch's own capability controls are the Step 0 unit tests, which run on Linux on
  every PR; C4 adds only the AL2023 build and runtime.

### 0.3 Behaviour changes

- **Quote path.** A `quoted_status_id` that is `http://`, redirects too often, is oversize, has a
  non-AP type or resolves to a refused address now fails. The quote is then marked `failed`,
  through the existing path (`PostHandler/main.swift:282-287`). Quote-path fetches are signed as
  the posting actor, which closes FederatedActivityPublisher#280 for `PostHandler`; the
  QuoteRequest actor lookup in `InboxHandler` (`InboxHandler/main.swift:1598`) is signed as the
  inbox owner, with the key #279 already loads.
- **Inbound key fetch.** Verifying an inbound signature now fetches the key through
  `fetchRemoteActor`: only status 200 and the two ActivityStreams content types are accepted,
  with at most 3 redirects, a 1 MB cap and the address check. Its deadline is an absolute 10 s
  on the head, checked on every body chunk, with `timeout.read` bounding a stalled body (§0.2).
  Today's 10 seconds (`KeyManager.swift:75`) is an idle timeout, so a slow response that keeps
  sending bytes now fails where it used to succeed. A remote server whose
  actor document fails these checks can no longer deliver to FAP.
- **Typed documents** (decision 16). A fetched actor without a string `id` or `inbox`, an object
  without a string `id` or a `type`, or either one with a declared field of the wrong JSON type
  (for example a numeric `inbox`, or `sensitive` as a string) is refused with `invalidDocument`.
  Today any JSON object is accepted and fields of the wrong type are silently skipped. Unknown
  fields are still ignored. Two consequences fall on paths that don't use the field that refuses:
  - **Inbound key fetch.** A `preferredUsername` that is present but not a string (today skipped
    by `as? String`, `KeyManager.swift:101`) now refuses the actor, so the key fetch fails and
    the inbound delivery fails with it.
  - **Quote path.** The quote only needs `attributedTo`, but a `summary`, `sensitive`,
    `published`, `content`, `url` or `contentMap` of an unexpected JSON type now refuses the
    quoted status, and the quote is marked `failed`.

  The typed fields stay (decision 16); the step 0 release notes name both consequences.
- **No connection retries.** `retryConnectionEstablishment = false` (§0.2) applies to every
  fetch, not only refused addresses. A key fetch whose first connection attempt fails for an
  ordinary reason, such as a refused or reset connect, now fails at once where AHC's default would
  have retried it. `keyManager.getPublicKey` then throws and the inbound delivery fails
  (`InboxHandler/main.swift:125`). Only keys not already cached in `REMOTE_ACTOR#` (24 h TTL) are
  fetched, and the remote server's own delivery retry is then the only retry.
- **Release notes:** all of the behaviour changes above.
- **Tests:** the Step 0 tests under Testing.

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
3. If nothing is found, return **404** and write nothing. The 404 matches Mastodon's `set_thread`
   (`statuses_controller.rb:106-111`); the body, `{"error":"Status to reply to not found"}`, is
   FAP's own text. Phases 2 and 3 widen what resolves.
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
  - **`acct`** is `R@handleDomain`, FAP's choice. Mastodon's `pretty_acct` for a local account is
    the bare username (`account.rb:249-254`); FAP shows the full handle so the mention reads the
    same on every server it reaches.
  - **No duplicate.** If the client text begins with `@{username}` followed by an optional
    `@{any domain}`, matched case-insensitively and followed by whitespace or the end of the text,
    that leading token is removed before conversion and replaced by the linked form. This covers
    `@R`, `@R@handleDomain` and `@R@serverDomain`.
- **`cc`.** *R* is appended for every visibility (`tag_manager.rb:215,228`).

**Carried-over self-reply (*P* = poster, *R* carried over).** Decided 2026-10-20 (decision 11):
- *R* goes in `cc`, with **no** Mention and **no** visible mention.
- **This goes beyond Mastodon for private replies, and FAP chooses it deliberately.** Mastodon
  reaches the replied-to account only for distributable replies (`status_reach_finder.rb:48-49`),
  and puts only mentioned accounts in `cc` (`tag_manager.rb:215,228`). So on Mastodon, *R*
  receives a private self-continuation only as one of the poster's followers
  (`status_reach_finder.rb:110-111`). On FAP, *R* is in `cc` at every visibility, and receives it
  whether or not *R* follows the poster.

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

This mirrors `StatusReachFinder` for Create and for Delete (`distribution_worker.rb:22-23`;
`remove_status_service.rb:92-106`). For Update it reaches further than Mastodon on private
statuses: Mastodon's Update reaches repliers only when the status is distributable
(`status_reach_finder.rb:80-81`), while `replyAudience` always includes *R* when *R* is in `cc`.
That follows from decision 11 putting *R* in `cc` at every visibility.

**Callers:**
- PostHandler's Create fan-out.
- The quote-accept `Update` (`InboxHandler/main.swift:1284` onward), which today goes to followers
  only.
- **Any future status delete or edit endpoint MUST use it.**

### 2.7 Safe links in generated HTML

Every link FAP renders into post HTML from data it didn't author follows one rule. That covers the
mention `href` (§2.5, §3.5) and the "In reply to" link (§1.8, §3.7).

1. **Pick the candidate URL.**
   - For a local account or status, it is the FAP-built URL.
   - For a remote one, it is the object's `url` when that is a string. When it is an array or an
     object, use the first `Link`'s `href`, or the first string.
2. **Check the scheme.** The candidate must be `https` or `http` and parse as an absolute URL, as
   Mastodon's `url_for` requires (`tag_manager.rb:18-19`; `JsonLdHelper#unsupported_uri_scheme?`).
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
- **`openapi.yaml`:** `GET /api/v2/search` (`operationId: search`) with a `SearchResults` schema
  whose `accounts`, `statuses` and `hashtags` are all `required` arrays; FAP always returns all
  three, empty where it has nothing (§2.1).
- The post page's "In reply to" links to *P*'s post page, following §2.7.

### Phase 2 components

| Component | What it is |
|---|---|
| `SearchHandler` | New Lambda. Auth, local resolution, `show?`, `REF#` writes. Policies: DynamoDB CRUD, plus SSM read of exactly the two parameters client auth reads: `activity/${Stage}/keys/session-signing-key` (`PostHandler/main.swift:51-52`) and `activity/${Stage}/keys/client-token` (`BearerAuth.swift:97,151`), with `kms:Decrypt` on `alias/aws/ssm`. Phase 2 needs no actor key; phase 3a widens the grant (§3.2). |
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

Signing itself ships in step 0: `fetchRemoteObject` and `fetchRemoteActor` take a
`FetchSigningKey`, and the middleware re-signs every hop with FederatedActivityPublisher#279's
`HTTPSignature.signGet(privateKeyPem:keyId:path:host:date:)`. That helper signs
`(request-target) host date`, with the query string in the request target, which is what
`signed_request.rb:54-57,113` requires. Phase 3a only adds signers:
- **Search** signs as the caller, with keyId `https://{serverDomain}/users/{u}#main-key`.
  Mastodon accepts any verifying account key (`signature_verification.rb:45` onward).
- **`DeliverHandler`** signs its actor fetch (§3.5) as the job's `actorUsername`, with the key it
  already reads (`DeliverHandler/main.swift:52-58`).
- **Keys** come from `{SSM_KEY_PREFIX}/{u}`, through each handler's `ActorKeyCache` (§0.1),
  which owns the cache, makes it safe under Swift 6 concurrency and states what a key rotation
  does.
- **IAM.** `SearchHandler`'s grant widens to the actor keys. If FederatedActivityPublisher#282 has
  landed, that is `activity/${Stage}/keys/actors/*`. If not, it is `activity/${Stage}/keys/*`
  with #279's pattern: an explicit `Deny` on `jwt-signing-key` and on `ssm:GetParametersByPath`
  (it still needs `session-signing-key` and `client-token` for auth).

### 3.3 Remote resolution in search

`resolve=true` with a non-local `https://` `q` runs under a **10 s overall deadline**, which
search passes to each of its fetches (§0.2). Its worst case is 20 s, the deadline plus one
`timeout.read` on a stalled body (§0.2), under the 29 s API Gateway limit. On overrun or
any failure, it returns empty `statuses` and writes nothing.

1. **Fetch** the object signed as the caller, with `fetchRemoteObject`.
2. **Canonicalize.** If `json['id']` ≠ `q`, re-fetch `id` and require equality
   (`JsonLdHelper#fetch_resource`). A pasted web URL resolves this way.
3. **Validate.**
   - `type` must be in Mastodon's supported or converted set (`activity.rb:9-10`).
   - `attributedTo` must be present. The document maps it through `first_of_value`/`value_or_id`
     (§0.1).
   - The host of `attributedTo` must equal the host of `id` (`fetch_remote_status_service.rb:61-66`).
4. **Fetch the actor** signed.
   - Require `json['id'] == attributedTo` (Mastodon: `JsonLdHelper#fetch_resource`, called from
     `fetch_remote_actor_service.rb:18`).
   - It is fetched with `fetchRemoteActor`, so it arrives as step 0's typed
     `RemoteActorDocument`, which already carries `followers`, `url` and `preferredUsername`
     (§0.1). There is no separate parser.
   - It writes nothing to `REMOTE_ACTOR#`. The record is the inbound-signature trust anchor and
     already has two writers (Current FAP behaviour). Nothing in this spec would read a
     search-time copy: `DeliverHandler` fetches *R*'s actor at delivery (§3.5).
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

### 3.6 Interaction with InboxHandler

- `handleCreate` keeps dropping non-local `inReplyTo` (`:756-772`).
- *R*'s reply to FAP's reply is handled by existing code.
- `handleDelete` and `handleUpdate` gain the §3.1 invalidation.

### 3.7 Client API and web

- Search returns remote statuses with FAP ids.
- `in_reply_to_id` is the remote id, and `in_reply_to_account_id` is the remote account id.
- The post page's "In reply to" links to the cached `url`, following §2.7 with the canonical URI
  as the fallback.

### Phase 3a components

| Component | What it is |
|---|---|
| Remote resolve in `SearchHandler` | An extension of the phase 2 handler |
| Remote `REF#` entries (`META` or `VIEWER#`) | The existing item type, with a TTL |
| Signers for search and `DeliverHandler` | Callers of the step 0 signer support (§3.2) |
| `SearchHandler` SSM widening | Actor keys added to its grant (§3.2) |
| `DeliveryJob.targetActorUri` | An extension of the job and of `DeliverHandler` |
| `REF#` invalidation | An extension of `handleDelete` / `handleUpdate` |
| Actor and object documents | None new: step 0's `RemoteActorDocument` and `RemoteObjectDocument` (§0.1) |

**Invariants:**
- **Smallest mechanism.** Remote ids are deterministic, so there is no by-URI index. The cache
  reuses `REF#`. Inbox resolution sits in `DeliverHandler`. PostHandler makes no fetch.
- **One job.** Each handler keeps its one job.
- **Blast radius.** One repository.

## Phase 3b — Linked Data Signatures (decision 10)

### 3.8 Signing remote replies

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
(`process_activity_service.rb:59-66`; `JsonLdHelper#patch_for_forwarding!`, `#safe_for_forwarding?`):
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
- FAP emits no `@graph`, `@included` or `@reverse` (`JsonLdHelper::UNSUPPORTED_JSONLD_KEYWORDS`).

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
  `json-ld-preloaded` 3.3.2, `rdf-normalize` 0.7.0, and Mastodon's two context initializers).
  - **Where it runs** (this spec's design): in a throwaway container on a maintainer's machine,
    from a stock Ruby image with those three gems pinned, with no FAP credentials: no AWS
    credentials or SSM access, no GitHub token, no FAP actor keys and no mounted home directory.
    The test key is generated for the fixture and is not an actor key. Its network use is
    pulling the stock Ruby image, installing the three pinned gems, and fetching Mastodon's two
    context initializers (`config/initializers/json_ld_identity.rb` and
    `config/initializers/json_ld_security.rb`) from `mastodon/mastodon` at a pinned commit. It
    runs third-party code, which the maintainer's option B ("Mastodon-generated
    fixtures", decision 13) covers; it never runs in FAP's CI.
  - The fixtures it writes are:
    - a FAP-shaped Create
    - its canonical N-Quads and both hashes
    - the signature for a fixed test key and timestamps
    - the document **compacted against Mastodon's `full_context`**, for the compaction-safety test

### Phase 3b components

| Component | What it is |
|---|---|
| LD signer | A new ActivityPubCore module: three embedded contexts, RSA-SHA256, using the canonicalization module |
| Canonicalization | A module FAP owns in ActivityPubCore: `toRdf` for FAP's shapes and RDFC-1.0 (decision 13) |
| Vendored reference code | The two packages' source at a pinned commit, licences retained, authors credited (decision 13) |
| Credits | `CONTRIBUTORS.md` and a README Acknowledgements section (decision 13) |
| Context alignment | A change to `buildNoteJSON` / `buildCreateActivityJSON` |
| Fixture generator | A committed script, run once outside CI in an isolated container with no FAP credentials |

**Invariants.**
- LD signing is required by decision 10.
- Its cost is a canonicalization module FAP owns and maintains, and that cost is surfaced.
- It is isolated to remote public and unlisted replies.

## Testing

Every test below names a negative control, and each control must be seen going red with its
capability removed before the test counts.

### Unit (`Tests/ActivityPubCoreTests`, Swift Testing)

**Step 0**, against local test servers. CI runs them on Linux only: PR CI is the `test` job of
`.github/workflows/test.yml`, on the Linux runner (`:13`). A developer may also run them on
macOS, but no CI job does.

The harness uses real sockets, not a stub transport, because a stub skips the layer under test.

- **Test servers.** Written in the test target on SwiftNIO, as the spike's is (#283): listening
  on `127.0.0.1:0`, counting connections, bytes received and closes. They serve fixed responses,
  redirects, oversize bodies, a slow drip and a stall. `NIOCore`, `NIOPosix`, `NIOSSL` and
  `NIOHTTP2` are already resolved through `async-http-client` (its `Package.swift` depends on
  `swift-nio-ssl` and `swift-nio-http2`). They become direct dependencies of the test target
  only (decision 16). That needs package entries for `swift-nio`, `swift-nio-ssl` and
  `swift-nio-http2` (§0.2, Dependencies), but no package that isn't already resolved. None of them
  pulls `libxml2-dev` or `libicu-dev` onto the runner, which
  crashes `FoundationNetworking` test binaries.
- **TLS.** The TLS server uses `NIOSSLServerHandler` with a certificate from a test-only CA. The
  CA and the leaf (for `127.0.0.1` and `localhost`, long validity) are committed test fixtures,
  generated once with `openssl`; they are not secrets. The test client sets the CA as
  `tlsConfiguration.trustRoots = .certificates([…])` (`NIOSSL`, `TLSConfiguration.swift:352`).
- **Test client.** Built with the production construction function, given a test address policy
  that admits only the loopback ports a test names, and the test CA. Tests pass a scheme policy
  that admits `http` to named test ports. Production builds neither.
- **Shutdown.** Every client a test builds, test, control and bare, runs inside
  `withTestClient(_:body:)` and is shut down on every exit path (§0.1, AHC's debug `deinit`
  precondition).
- **The negative control removes one capability.** For a check the middleware owns (scheme, redirect
  count, body cap, content type, status, deadline), the control is the production construction with
  that one check switched off, everything else unchanged. The switch is an `internal` option set on
  `RemoteFetchMiddleware`'s initializer, defaulted to every check, so production code can't reach it
  and tests set it through `@testable import ActivityPubCore`. For a setting of the `HTTPClient`
  (hook, close, retries, HTTP version, trust), the control is the production construction with that
  one setting changed. The test asserts the control gets the response the FAP client refuses or, where the generated
  layer behind the middleware refuses the same input (undeclared concrete content types, statuses
  other than 200), that the refusal now comes from that layer, with its error, and not from the
  middleware.
- **The bare client is a fixture check, not a control.** The same request through an
  `HTTPClient` with AHC defaults and no generated layer or middleware, called with `execute`,
  shows that the test server serves what the test claims. It runs beside the control and does
  not replace it.
- **Every refusal test checks which control refused.** Each control throws its own
  `RemoteFetchError` case (§0.1, "The error type").
  The test unwraps `ClientError.underlyingError` (§0.1) and asserts that case, so a test can't
  pass on a connection error or a different control.

Tests (control in brackets):
- **Redirects:** 3 pass, and a 4th fails with the redirect error. [With the redirect limit off,
  the 4th is followed.]
- **Scheme:** an `http://` initial URI fails under the default policy. With a policy admitting
  port A only, a redirect from A to B fails. An `https`→`http` hop fails. [Same calls with a
  policy admitting A and B, or `http`, succeed.]
- **Body:** a body over 1 MB fails with the size error. [With the body cap off, it is read in
  full.]
- **Content type:** `text/html`, `text/html; charset=utf-8`, bare `application/ld+json`, and an
  `application/ld+json` whose `profile` lists the AS profile beside another one, each fail with the
  middleware's content-type error, on a valid document, so the content type is the
  only thing that can refuse it. (Here and below, "a valid document" means a body that decodes
  under the operation's schema.) `application/activity+json; charset=utf-8` and
  `application/ld+json; profile="https://www.w3.org/ns/activitystreams"` (the exact profile string,
  since values compare case-sensitively) pass. [The production client with the content-type check
  switched off: the four refused values now fail in the runtime's match instead, with
  `generatedLayerRefused`, whose underlying error is not a `DecodingError` and whose
  `ClientError.response` is set, which shows the response head arrived and the refusal came after
  it, not from the connection (§0.1).]
- **Non-concrete or unparsable content type:** a 200 with a valid document and no
  `Content-Type`, an empty one, `*/*`, `text/*`, `html` or `*/html` each fails with the
  middleware's content-type error. [The production client with only the content-type check switched
  off, every other middleware check still on, accepts all six and decodes the body, the runtime
  behaviour §0.1 names.]
- **Invalid document:** a 200 with `Content-Type: application/activity+json` fails with
  `invalidDocument` for each of: the body `{"a":`; an actor that is a valid JSON object without
  `inbox`; an actor whose `inbox` is a number; an object whose `attributedTo` is a number, which
  no `oneOf` case decodes. [The same response with a valid document returns it.]
- **Unknown fields are tolerated:** an actor document with Mastodon's full set of fields, plus
  40 invented ones holding strings, numbers, nested objects and arrays, decodes, and every
  declared field reads back. [The same document without `inbox` fails with `invalidDocument`,
  which shows the decode checks the declared fields and isn't passing everything.]
- **Value or array:** `attributedTo` as a string, as `{"id": …}`, and as an array whose first
  entry is `{"id": …}` all give the same `attributedTo`; `to` as a string and as a one-element
  array give the same `to`; `url` as a string, as a `Link` and as an array of `Link`s gives the
  same `url`; `publicKey` as an object and as a one-element array gives the same `publicKeyPem`.
  [Each field given a JSON number fails with `invalidDocument`.]
- **Status:** a 404 with a valid document and a 204, each sent with
  `Content-Type: application/activity+json` so that the content-type check passes, fail with the
  middleware's status error. [The production client with
  the status check switched off: both come back from the generated client as `.undocumented`, and
  `fetchRemoteObject` throws `generatedLayerRefused` instead, whose underlying error is
  `UndocumentedStatusError` with the status code.]
- **Deadline, slow drip:** with a 2 s deadline, a body that sends one byte every 100 ms for 5 s
  fails with the deadline error between 2 s and 2.5 s. [With the deadline check off, it
  completes after about 5 s; `timeout.read` never fires, because bytes keep arriving.]
- **Deadline, stall:** with a 2 s deadline and a test client built with `timeout.read =
  .seconds(3)`, a server that sends the response head at once and then nothing fails with AHC's
  `HTTPClientError.readTimeout` between 3 s and 3.5 s after the request: `timeout.read` restarts
  when the head arrives, and the deadline, already past, has no chunk to check. It is
  `transportFailed` whose underlying error is that `HTTPClientError` (§0.1). [The same production
  construction with only `timeout.read` removed, the deadline check still on, is still waiting at
  10 s. The test then ends it by calling `shutdown()` on the client inside `withTestClient`, since
  nothing in the design cancels a pending body read (§0.2), and asserts it had not completed.]
- **Key fetch:** `KeyManager(client:)` with the test client, then
  `fetchActorDocument(actorUri:signingKey:deadline:)`, both through
  `@testable import ActivityPubCore`, fetches a valid key document from the test server; a
  4-redirect chain ending at a valid document fails with the redirect error; a valid document
  padded past 1 MB fails with the size error. [On the parent commit (with #279, before step 0),
  `fetchActorDocument(actorUri:signingKey: nil)` returns a key for both, because that code has
  no redirect or size cap and both fixtures parse.]
- **Address check, end to end:** a redirect from port A (admitted) to `127.0.0.1` on port C (not
  admitted) fails with the address error; server C records a connection, 0 bytes and a close.
  [A client built without the hook delivers the request to C.]
- **Address classifier:** the policy refuses every literal in §0.2, including the IPv4-mapped
  forms, `169.254.169.254` and `10.0.0.1`, and one literal inside every range of §0.2's list:
  - Mastodon's `CIDR_LIST`: `0.1.2.3`, `100.64.0.1`, `172.16.0.1`, `192.0.0.1`, `192.0.2.1`,
    `192.88.99.1`, `198.18.0.1`, `198.51.100.1`, `203.0.113.1`, `224.0.0.1`, `240.0.0.1`,
    `255.255.255.255`, `::`, `64:ff9b::1`, `64:ff9b:1::1`, `100::1`, `2001::1`, `2001:10::1`,
    `2001:20::1`, `2001:db8::1`, `2002::1`, `fd00::1`, `3fff::1` and `ff02::1`;
  - the named ranges: `10.0.0.1`, `192.168.0.1`, `127.0.0.1`, `::1`, `169.254.0.1` and `fe80::1`;
  - embedded metadata addresses: `64:ff9b::a9fe:a9fe` (NAT64, embedding `169.254.169.254`),
    `2002:a9fe:a9fe::1` (6to4, embedding it), `::ffff:169.254.169.254` (IPv4-mapped) and
    `::169.254.169.254` (IPv4-compatible).

  It admits the public addresses `1.1.1.1` and `2606:4700:4700::1111`. These are unit tests on
  literals: an end-to-end connect to the metadata address would reach a real service on a cloud
  runner. [An allow-all policy turns every refusal case red. The policy without the unwrapping
  step admits `::169.254.169.254`, and without `CIDR_LIST` admits `64:ff9b::a9fe:a9fe`.]
- **Address check over TLS (hook ordering):** the same redirect to a refused port C, where C is
  the TLS test server. C records a completed TLS handshake, 0 HTTP bytes and a close, and the
  fetch fails with the address error. This measures the decision-14 residual for `https`: the
  hook runs after the handshake (`HTTPConnectionPool+Factory.swift:532`). [A client built
  without the hook delivers the HTTP request to C.]
- **Rejected channel is closed:** server C above records the close. [A hook that fails without
  calling `close()` leaves `closes == 0`, as the spike's T1 did.]
- **No connection retries:** a refused address gets exactly 1 connection. [With
  `retryConnectionEstablishment = true`, more than 1, as in the spike's T1b.]
- **HTTP/1.1 only:** a TLS test server offering `h2` and `http/1.1` by ALPN, on a port the
  address policy refuses, is refused. [With `httpVersion = .automatic`, the connection
  negotiates `h2`, the HTTP/1.1 hook never runs, and the request reaches the server.]
- **Trust:** the test client reaches the TLS server. [A client with the system trust store
  refuses it, with `transportFailed`, whose `ClientError.response` is `nil`.]
- **Request target:** a URI with a query string and percent-encoded characters reaches the test
  server byte for byte. [The same URI through a plain `/{path}` template does not.]
- **Signing:** a signed fetch of a URI with a query string carries a `Signature` over
  `(request-target) host date`, with the query in the request target, that verifies against the
  actor's public key, and a redirected fetch is signed again with the second hop's path. This
  also covers #279's `signGet`, so phase 3a has no test of its own for it. [An unsigned call
  carries no `Signature`; the same signature checked against the path without its query fails;
  reusing the first hop's headers fails verification on the second.]
- **One client, concurrent:** two fetches to servers A and B run concurrently through one
  `RemoteFetchClient`, and server A holds its response until B has received its request; each
  reaches its own server. A fetch with no context bound throws the no-target error before any
  connection. [A test-only middleware variant that keeps the target in a stored property on the
  shared middleware sends one fetch to the wrong server.]

**Phases 1 to 3b: what the controls are.** Most tests below exercise symbols their step
introduces, so on the step's parent commit they don't compile; that is not a capability-removed
red, and no blanket parent-commit control is claimed. The control for each test is the case it
lists as "negative control": an input on the other side of the rule that the same code must
tell apart, so a test that passes on both sides fails. The test that comes closest to a
parent-commit run still doesn't have one: the `buildNoteJSON` test sets `inReplyToId`, which
phase 1 adds, so it doesn't compile on the parent. Phase 1's capability-removed control is the
integration tests' run against the
pre-change stage build (Integration, below). Phase 2 has no integration-level capability-removed
control: a reply by ULID to another actor's status gets `.notFound` on both builds until a search
writes the `REF#` pointer (§2.3). Its capability-removed control is the resolver unit test with a
seeded pointer (Phase 2, below).

**Phase 1**
- **`buildNoteJSON`** emits `inReplyTo` when `inReplyToId` is set.
  - Negative control: a legacy `inReplyTo` without it emits no key.
- **The resolver** returns `none` for no `in_reply_to_id`, `resolved` for the caller's own status,
  and `notFound` for an unknown id.
  - Negative control: an id that exists only in another actor's partition gives `notFound` in
    phase 1. (Before phase 1 the create path copies any id verbatim, `PostHandler/main.swift:310`;
    the integration "unknown parent" case shows that against the pre-change build.)
- **`cappedReplyVisibility`** covers all nine pairs.
  - Negative control: `public` under `private` gives `private`.
- **`buildStatusResponse`** returns the stored ids.
  - Negative control: a non-reply gives `null`.

**Phase 2**
- **The `REF#` local pointer** resolves another actor's unlisted status.
  - Negative controls: another actor's private status gives `notFound` in both search and the
    resolver, and a ULID with no pointer gives `notFound`.
  - Capability-removed control: the resolver with its `REF#` lookup (§2.4 step 2) switched off,
    given the same seeded pointer, returns `notFound`.
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
- **Signature.** RSASSA-PKCS1-v1_5 is deterministic, so signing the fixture Create with the
  fixture's test key and timestamps produces a `signatureValue` byte-equal to the one in the
  Mastodon-generated fixture. The result also verifies with an independent RSA-SHA256 check.
  - Negative controls: changing `created` by one second gives a different `signatureValue`, and
    flipping one byte of `signatureValue` fails the check.
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
  Negative control: the same fixture without `statuses` fails to decode, because `statuses` is
  `required` in `SearchResults` (§2.9).

### Integration (`integration-tests/`, on stage, generated `APIClient`)

These count only once FederatedActivityPublisher#278 is fixed (Sequence).

**Phase 1:** round trip, unknown parent, visibility cap, and a chain of three.
- Negative control: the same four cases run against the stage build before phase 1 fail: the
  round trip has no `inReplyTo` on the Note, the unknown parent gets 200, the reply keeps the
  requested visibility, and the chain's Notes are unlinked.

**Phase 2** (needs a second stage actor and token)
- A searches B's unlisted status URL, gets B's ULID and replies.
- The response carries the parent id and B. The Note has a Mention, the h-card, `cc` B, and B's
  count rises.
- Negative controls:
  - B's private status: search returns nothing, and replying with its ULID gets `.notFound`.
  - Search without a token gets 401.
- No integration-level capability-removed control for the reply half: without a search, the
  `REF#` pointer doesn't exist and the reply gets `.notFound` on the phase 1 and phase 2 builds
  alike (§2.3). The resolver unit test with a seeded pointer covers it.
- The search half has no capability-removed control. Before phase 2, `/api/v2/search` doesn't
  exist, and a 404 for a missing route is not the capability going red, any more than a compile
  failure is. Search rests on its other-side inputs above.

Phase 3 needs a third-party server, so it is in the manual federation checks below, not in CI.

### Federation (manual, against stage)

- **BrowserPub** (https://browse.activitypub.dev) renders "in reply to" up the chain.
  - Negative control: a chain posted by the pre-change build shows no "in reply to".
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

- **Before merge**, PR CI runs `swift test` on Linux (`.github/workflows/test.yml:13`), which
  builds every target for Linux and runs the Step 0 and 3b unit tests there. A macOS
  `swift build` doesn't catch Linux-only compile errors; this does.
- **After merge**, `deploy-stage` builds every target the way the deploy does,
  `swift package --allow-network-connections docker archive --base-docker-image swift-al2023:6.3`
  (`deploy-stage.yml:326`), on the glibc Amazon Linux 2023 image from
  `docker/Dockerfile.al2023-swift`, with OpenSSL's shared libraries bundled into each zip's
  `lib/`. The deployed binary is that build. Under the maintainer's 2026-06-12 call (§0.2), this
  build runs only there, no runner VM is used by hand, and a break is fixed forward. For step 0
  that run is the C4 measurement (§0.2), with its pass and fail criteria.
- Build the generated consumers against the branch's `openapi.yaml`.

## Unverified

- **C4: AsyncHTTPClient in the deployed build.** No deployed handler links it today (#283). It
  is measured on stage after merge: the `deploy-stage` archive build for the step 0 merge commit
  and a stage key fetch for an uncached actor, with the pass and fail criteria in §0.2. A failure
  is fixed forward, and no prod release containing step 0 is cut before it passes.
- **Hook ordering for `https`.** Read in source: the hook runs after the TLS handshake
  (`HTTPConnectionPool+Factory.swift:532`). The spike measured plain `http` only. The Step 0
  "Address check over TLS" test measures it.
- **TaskLocal isolation on one client.** [inferred] from `UniversalClient.send` awaiting the chain
  inline. The concurrent "One client" test measures it.
- **Pooled connections across a Lambda freeze** [unmeasured]. The long-lived client keeps
  AHC's default pooling, so an idle keep-alive connection can sit in the pool while the container
  is frozen, and the remote server may close it before the thaw. Whether AHC notices before
  reusing it, or the first fetch after the thaw fails, is not known; with connection retries off
  (§0.2), such a failure on a key fetch fails the inbound delivery, and the remote server's retry
  is the only retry. `connectionPool.idleTimeout` defaults to 60 s (`HTTPClient.swift:1383`).
  Turning pool reuse off was dropped from this spec (decision 17) and is
  FederatedActivityPublisher#285. The mechanisms found in AHC 1.33.1's source, for that
  follow-up:
  - `maximumUsesPerConnection` (`HTTPClient.swift:895`, default `nil`): leasing a connection
    decrements its remaining uses (`ConnectionPool/State Machine/HTTPConnectionPool+HTTP1Connections.swift:142-143`);
    a connection returned idle with none left reports `idleAndNoRemainingUses` (`:72-83`), which
    becomes the idle context's `shouldBeClosed` (`:773-774`); the pool then closes it instead of
    parking it (`ConnectionPool/State Machine/HTTPConnectionPool+HTTP1StateMachine.swift:446-447,564-593`),
    and opens a replacement only for queued requests or pre-warming, which defaults to 0
    (`HTTPClient.swift:1407`).
  - A request's own `Connection: close`: AHC reads it into the request's framing metadata
    (`RequestValidation.swift:39`), the HTTP/1.1 connection state machine keeps it as `close`
    (`ConnectionPool/HTTP1/HTTP1ConnectionStateMachine.swift:201`), and at the response end moves
    to `.closing` with a `.close` action instead of going idle (`:471-474`).
- **Live secure-mode acceptance of a regular actor key.** The source has been read
  (`signature_verification.rb:45` onward). The phase 3a secure-mode check is the measurement.
- **Mastodon internals.** The `items_context_url` path shape, a read of `context` on intake, the
  composer's handling of the author's own `@handle`, and the `replies_count` "added" version. None
  of these is relied on.
- **Forcing out-of-order delivery** for the manual check. No mechanism has been identified.

## Guards and fallbacks

Each guard or fallback this spec plans, and whether it rests on an observed failure. "Read in
code" means the defect was seen in FAP's source, not in production.

| Guard or fallback | Where | Observed failure it rests on |
|---|---|---|
| Signed fetches | Step 0, §3.2 | Yes: unsigned actor fetches answered 401 by mastodon.social, in inbox logs (FederatedActivityPublisher#279) |
| Visibility cap on local parents | §1.2 | Read in code: `ObjectHandler` serves any visibility (FederatedActivityPublisher#270) |
| Scheme, redirect, body, content-type, status and deadline controls | Step 0 | None. Security controls, matching Mastodon's fetch |
| Connection-level address check, with Mastodon's `CIDR_LIST` | Step 0, §0.2 | None. Security control |
| Hook closes the rejected channel itself | §0.2 | Yes, in the spike: without the close the connection stayed open, `closes=0` (FederatedActivityPublisher#283, T1 vs T1c) |
| `retryConnectionEstablishment = false` | §0.2 | Yes, in the spike: with retries on, a refused host got 7 connections in 2 s on macOS and 9 on Linux (FederatedActivityPublisher#283, T1b) |
| `httpVersion = .http1Only` | §0.2 | Not observed. Covered by decision 15's address check: decision 14's Settings make `.http1Only` a precondition of the hook, which runs only for HTTP/1.1 connections. FederatedActivityPublisher#283 notes that as a source reading (its finding 3), every spike client was `.http1Only`, and the step 0 "HTTP/1.1 only" test is the first observation |
| `timeout.connect` / `timeout.read`, and the transport's 10 s `timeout` backstop | §0.1, §0.2 | None. Bounds on stalls the deadline race can't interrupt |
| Middleware throws with no target bound | §0.1 | None |
| Missing, empty, unparsable or non-concrete `Content-Type` refused | §0.1 | None. Closes a gap read in the runtime |
| 10 s search deadline | §3.3 | None. Rests on the documented 29 s API Gateway limit |
| ~~One 10 s fetch deadline per invocation, shared by every fetch in it~~ | Dropped | Dropped by decision 17; follow-up FederatedActivityPublisher#284. Each fetch has its own deadline (§0.2) |
| ~~`maximumUsesPerConnection = 1`~~ | Dropped | Dropped by decision 17; follow-up FederatedActivityPublisher#285. AHC's default pooling stays (Unverified) |
| Typed schemas refuse a document missing a required field or with a declared field of the wrong JSON type | §0.1 | None. Decision 16 |
| `repliesCount` failure logged and swallowed | §1.6 | None |
| Safe-link scheme check and fallback | §2.7 | None. Security control |
| Remote validation (`id`, `attributedTo` host, actor `id`) | §3.3 | None. Matches Mastodon |
| Search returns empty and writes nothing on any failure | §3.3 | None |
| `DeliverHandler` requires the fetched actor's `id == targetActorUri` | §3.5 | None. Matches Mastodon's actor check (`JsonLdHelper#fetch_resource`, called from `fetch_remote_actor_service.rb:18`) |
| Read-time `ttl` comparison on `REF#` entries | §3.1 | None |
| Legacy `inReplyTo` without `inReplyToId` ignored | §1.3 | None. No legacy item has been observed |
| `META` deleted when a re-search derives `private` | §3.1 | None. Security control |
| Never change `visibility` from an Update | §3.1 | None. Security control |
| Delete/Update invalidation only from the object's origin | §3.1 | None. Security control |
| Unsigned delivery when LD signing fails | §3.8 | None |

## Decisions (2026-10-20 and 2026-10-21)

The maintainer decided items 1–15 on 2026-10-20 and items 16 and 17 on 2026-10-21. Each item states
his decision; where his own words are known they are quoted. Section references, function and type
names, and anything
labelled as this spec's are the spec's implementation of the decision, not his words.

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
10. **Linked Data Signatures** are part of phase 3, as step 3b (§3.8).
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
      packages. The maintainer confirmed this reading of "list them as contributors" on 2026-10-20:
      "yes". This
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
        are source files and come along. Any W3C suite data committed for the §3.8 gate is listed
        in `VENDORED.md` with its own licence.
      - The vendoring PR shows the full copied source in its diff, and is reviewed like FAP code.
      - The fetch is limited to these two repositories at the pinned commit.
    - **Other references.** Mastodon's `linked_data_signature.rb` and ruby-rdf's
      `rdf-normalize` are linked from the code as references. Nothing is copied from them.
    - The gate in §3.8 applies to all of it. Step 3b stays last, because delivery degrades to
      unsigned.

14. **HTTP client for remote fetches: generated, on an existing transport.** The maintainer's
    words, in order:
    - On the client (former Open Question 2, the revision at `6271b24`): "2 we write our own by
      generating from swift-OpenAPI-generator".
    - On a client built per request: "A client being built per request?! No."
    - On writing a transport: "Why would we write our own transport layer when they already
      exist from the Apple Swift ecosystem that we've already used?"
    - On AsyncHTTPClient's connection debug initializer as the address check, after the spike
      (FederatedActivityPublisher#283): "Yes acceptable. No more probe."

    **Implementation (this spec's design, not the maintainer's words):**
    - **Transport.** FAP's existing OpenAPI transport is `URLSessionTransport`
      (`OpenAPIURLSession`, `integration-tests/Package.swift:18,29`). Its `Configuration` takes
      only a `URLSession` and a body-processing mode
      (`Sources/OpenAPIURLSession/URLSessionTransport.swift:67-81`, swift-openapi-urlsession
      1.2.0), so a connection-level hook would have to come from `URLSession` itself. Whether
      FoundationNetworking's `URLSession` on Linux offers one has not been checked; the transport
      choice doesn't rest on it. The address check the maintainer accepted is AsyncHTTPClient's
      `http1_1ConnectionDebugInitializer`, so the transport follows from that acceptance: the
      existing `AsyncHTTPClientTransport` (`swift-server/swift-openapi-async-http-client`) over
      `swift-server/async-http-client`. FAP's fetch controls live in a `ClientMiddleware`, and FAP
      writes no transport.
    - **Settings.** The accepted hook holds only with these settings, each with its evidence in
      §0.2: the hook closes the rejected channel itself, `retryConnectionEstablishment = false`,
      `.http1Only`, no proxy, and `redirectConfiguration = .disallow` with each hop handled in
      FAP's middleware.
    - **Residual weakness.** The TCP connect, and for `https` the TLS handshake, reach the address
      before the hook rejects it; only the HTTP request is blocked (§0.2).
    - **What the generated layer contributes and costs.** With decision 16's typed schemas it
      contributes the validation of the two documents FAP reads: typed decoding of the actor and
      object fields FAP uses, refusal of a document missing a required field or carrying a
      declared field of the wrong JSON type, JSON-LD's value-or-array forms through `oneOf`, and
      tolerance of every undeclared field (§0.1). That replaces the hand parser in `KeyManager`
      and the `as? String` reads at each call site. It also contributes a second status check (the
      `.undocumented` case) and a concrete content-type match behind the middleware's. It costs an
      OpenAPI document whose origin and paths are placeholders, rewritten per hop; a `@TaskLocal`
      side channel, because the operations have no real input; the middleware's own status and
      content-type checks (the runtime lets missing, unparsable and wildcard types through, and
      its checks have no switch for a negative control); `@_spi(Generated)` use of
      `OpenAPIMIMEType`; and AHC linked, and the generator plugin run, in every build of the 17
      deployed handlers that link `ActivityPubCore`, though only four of them fetch (§0.1).
    - **Structure** (§0.1, §0.2). One client per container; one `@TaskLocal`
      `RemoteFetchContext` carrying target, signer, deadline and scheme policy; the address policy
      and trust roots set when the client is built; the client injected through `internal`
      overloads of `fetchRemoteObject` and `fetchRemoteActor`, with `.shared` as the default; one
      middleware that does the URL rewrite and every per-hop control; the generated client
      `internal` to `ActivityPubCore`; the placeholder origin `https://remote-fetch.invalid`, in
      the document's `servers:`.

15. **Guards, step 0 and the new dependency.** Decided 2026-10-20, from the options the spec put
    to the maintainer (former Open questions 1–3):
    - **Security controls** (the first group in "Guards and fallbacks": the step 0 scheme,
      redirect, body, content-type, status and deadline controls, the address check, the
      `Content-Type` refusals, the safe-link check, remote validation, the `DeliverHandler`
      actor-`id` check, deleting `META` on a re-derived `private`, never changing `visibility`
      from an Update, and origin-only invalidation): exempt from the observed-failure rule, all
      kept.
    - **Other guards and fallbacks** (the `repliesCount` swallow, unsigned delivery when LD signing
      fails, the no-target throw, the 10 s search deadline, search's empty-on-failure result, the
      `timeout.connect`/`timeout.read` and transport backstops, the read-time `ttl` comparison,
      and ignoring legacy `inReplyTo`): all kept as written.
    - **Step 0:** kept folded. The controls are built once, in the AsyncHTTPClient middleware.
    - **`swift-server/swift-openapi-async-http-client`** (`from: "1.5.0"`): approved.

16. **Typed schemas and two dependencies.** Decided 2026-10-21, through a structured question
    that followed the advisory review of FederatedActivityPublisher#271:
    - **Typed schemas.** The remote-fetch OpenAPI document gets real schemas for the two
      documents FAP reads: the actor (`id`, `inbox`, `endpoints.sharedInbox`, `publicKey`,
      `followers`, `url`), and the Note fields that §3.3 validates. JSON-LD value-or-array fields
      use `oneOf`. The generated layer then does real validation work.
    - **`swift-server/async-http-client` as a direct dependency:** approved.
    - **`NIOCore`, `NIOPosix`, `NIOSSL` and `NIOHTTP2` as direct dependencies of the test target
      only:** approved.
    - **Not adopted:** the review's other option, a generated `Client` built per call. There
      stays exactly one long-lived client (decision 14: "A client being built per request?! No.").

    **Implementation (this spec's design, not the maintainer's words):**
    - The document is `Sources/ActivityPubCore/openapi.yaml`, with operations `getObject` and
      `getActor` and schemas `RemoteObject` and `RemoteActor` (§0.1).
    - The schemas also declare the fields the spec stores or reads beyond the decision's list:
      `preferredUsername` on the actor, and `content`, `summary`, `sensitive`, `published`,
      `url` and `contentMap` on the object, because the generated decoder drops any undeclared
      field (§0.1).
    - No schema sets `additionalProperties`, so unknown fields are tolerated (§0.1).
    - Two public FAP structs, `RemoteObjectDocument` and `RemoteActorDocument`, carry the typed
      results to callers, who no longer read `[String: Any]` (§0.1 names each call site).
    - Package entries and floors: §0.2, Dependencies.

17. **Two guards outside decision 15.** Decided 2026-10-21, through a structured question that
    followed the second advisory review of FederatedActivityPublisher#271:
    - **The shared per-invocation fetch deadline:** dropped. Filed as the follow-up
      FederatedActivityPublisher#284.
    - **`maximumUsesPerConnection = 1`:** dropped. In the maintainer's words: "Drop this, but file
      it as an issue to consider following up on in the future". Filed as
      FederatedActivityPublisher#285.

    **Implementation (this spec's design, not the maintainer's words):**
    - Each fetch has its own 10 s deadline; search keeps §3.3's overall deadline. Where sequential
      fetches can pass the 29 s API Gateway limit, §0.2 ("Fetch deadlines by call site") says so as
      a known gap and cites #284.
    - AHC's default connection pooling stays. The stale-connection risk is recorded as unmeasured
      in Unverified, with the AHC source found for #285.
    - Both rows in "Guards and fallbacks" are marked dropped.

## Open questions

None. The questions earlier revisions raised were decided on 2026-10-20 (decision 15) and
2026-10-21 (decisions 16 and 17).
