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
| 0 | **Fetch hardening**, a security change to the existing shared fetch, built on the generated client (decision 14) | FederatedActivityPublisher#279 merged | A FAP-authored OpenAPI document and a client generated from it inside `ActivityPubCore`; one FAP `ClientMiddleware`; one long-lived `HTTPClient` per container behind `AsyncHTTPClientTransport`, with the connection-level address check |
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
in the middleware.

**Why 3a waits for 0.** Phase 3a adds a new way for an authenticated user to make the server fetch
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
same §3.6 gate as code FAP writes. Both packages were read from their repository pages only, and
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

Every remote `GET` goes through `fetchRemoteObject`, and every control below applies to it.
`KeyManager.fetchActorDocument` moves onto `fetchRemoteObject` in the same change, keeping its
parser (`KeyManager.swift:89-105`) and the signing key FederatedActivityPublisher#279 gives it.
So every remote GET is covered: the quote path, inbox object fetches and key fetches. Delivery
POSTs from `DeliverHandler` are not fetches and are outside this spec; their address check is
tracked separately (FederatedActivityPublisher#277).

**Base.** Step 0 builds on FederatedActivityPublisher#279, which adds
`HTTPSignature.signGet(privateKeyPem:keyId:path:host:date:)` (signing `(request-target) host
date`) and `FetchSigningKey {keyId, privateKeyPem}`, and changes `fetchActorDocument` to
`fetchActorDocument(actorUri:signingKey:)`. Step 0 reuses both types and adds no second GET
signer. If #279 changes before it merges, step 0 follows what merged.

The requirements follow Mastodon's `Request` and `fetch_resource`; the Reference column says
where FAP is stricter:

| Control | Requirement | Where it lives | Reference |
|---|---|---|---|
| Scheme | `https` on the initial URI and every hop | Middleware | Stricter than Mastodon, which allows `http` (`json_ld_helper.rb:95-97`) |
| Redirects | At most 3 hops, each validated and, with a signer, re-signed | Middleware; AHC follows none | `request.rb:101-102,72-75` |
| Body | 1 MB cap. Abort the read past it. | Middleware | `request.rb:293-294` |
| Content type | A concrete received type that is `application/activity+json`, or `application/ld+json` with the AS profile | Generated client, plus the middleware's concrete-type check (§0.1) | `json_ld_helper.rb:281,351` onward. Stricter than Mastodon on a multi-profile `ld+json` value (§0.1) |
| Status | Only 200 counts as success | Generated client | `json_ld_helper.rb:281` |
| Deadline | An absolute deadline from the caller, enforced even while bytes keep arriving | Middleware | Platform limits |
| Address | Reject loopback, private (RFC 1918 / ULA), link-local and unspecified addresses, applied to the address actually connected to, on every connection | `HTTPClient` connection hook | `request.rb:325-334,389-394` |

### 0.1 Shape

This section is the spec's design for decision 14 (Decisions); the words quoted there are the
maintainer's, and everything here is this spec's.

- **One client per container.** A process-wide `RemoteFetchClient.shared` (a struct holding the
  generated `Client`), built once:
  - an `HTTPClient` (`swift-server/async-http-client`) configured as in §0.2;
  - `AsyncHTTPClientTransport` (`swift-server/swift-openapi-async-http-client`) over that
    `HTTPClient`, with its `timeout` set to the longest deadline any caller uses (10 s). Its
    `Configuration` is `init(client: HTTPClient = .shared, timeout: TimeAmount = .minutes(1))`,
    and `send` calls `client.execute(request, timeout: configuration.timeout)`, so this is a
    backstop, not the per-call deadline;
  - the generated `Client`, with `serverURL` the placeholder origin `https://remote-fetch.invalid`
    (RFC 6761 §6.4: `.invalid` never resolves) and one middleware, `RemoteFetchMiddleware`.

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
- **Per-call context.** `fetchRemoteObject` binds one `@TaskLocal` value, `RemoteFetchContext
  {target: URL, signer: FetchSigningKey?, deadline: ContinuousClock.Instant, schemePolicy:
  SchemePolicy}`, for the duration of the call. The middleware reads all four. The runtime gives
  middleware no other per-call channel: `intercept(_:body:baseURL:operationID:next:)` and `next:
  @Sendable (HTTPRequest, HTTPBody?, URL)` carry only the request, body, base URL and operation id
  (`apple/swift-openapi-runtime`, `Sources/OpenAPIRuntime/Interface/ClientTransport.swift`).
  `UniversalClient.send` awaits the middleware chain inline with no new `Task`, so the binding is
  visible in the middleware and isolated per task, which concurrent fetches on the one client
  rely on [inferred from source; the concurrent "One client" test measures it].
- **Why a TaskLocal and not a header parameter.** A declared header (`X-Fap-Target`) would show
  the target in the generated call's signature, but it puts a non-wire header in the document and
  the middleware would still need the signer, deadline and policy from somewhere else; a single
  TaskLocal carries all four, and keeping the generated client `internal` means no caller ever
  sees the operation without `fetchRemoteObject` around it.
- **Set at construction, not per call.** The address policy (§0.2) and the TLS trust roots are
  properties of the `HTTPClient`. Production uses the address policy below and the system trust
  store. Tests build their own `RemoteFetchClient` with a test address policy and a test CA.
- **Injection.** `fetchRemoteObject(uri:signer:deadline:schemePolicy:client:)`, with
  `signer: FetchSigningKey? = nil`, `schemePolicy: SchemePolicy = .httpsOnly` and
  `client: RemoteFetchClient = .shared`. Every production call site passes only `uri`, `deadline`
  and, where it has one, `signer`. A test passes its own client; no global is swapped.
- **One middleware.** `RemoteFetchMiddleware` does the whole exchange, so there is no separate
  URL-rewrite middleware and no FAP transport:
  1. Throw if no context is bound, so the placeholder origin is never contacted.
  2. For each hop (the initial request plus at most 3 redirects): check the hop's scheme against
     `schemePolicy`; set the base URL to the hop's origin and the request's path and query to the
     hop's, byte for byte (`HTTPRequest.path` is the `:path` pseudo-header, path plus query, in
     `apple/swift-http-types`); with a signer, add the headers from `HTTPSignature.signGet` using that path-and-query and the
     `host[:port]`, as #279's `KeyManager.actorDocumentRequest(url:signingKey:)` does; call
     `next` under the remaining time.
  3. On a 3xx with a `Location`, discard the body, resolve `Location` against the hop's URL and
     loop. A 4th redirect throws.
  4. On any other response, require a `Content-Type` header whose media type is concrete: a
     missing header, `*/*` or a partial wildcard such as `text/*` throws the content-type error
     (the runtime accepts all three, below). Then return the response with its body wrapped in a
     sequence that throws past 1 MB and past the deadline.
- **Response decoding.** The document declares the 200 response as `type: object` with no
  properties, which the generator maps to `OpenAPIRuntime.OpenAPIObjectContainer`
  (`_OpenAPIGeneratorCore/Translator/TypeAssignment/TypeMatcher.swift:321-326`, generator 1.11.1).
  Its `value` is `[String: (any Sendable)?]`, with nested objects as `[String: (any Sendable)?]`
  and arrays as `[(any Sendable)?]` (`Sources/OpenAPIRuntime/Base/OpenAPIValue.swift`).
  `fetchRemoteObject` converts that tree to the `[String: Any]` its callers use today
  (`FetchRemoteObject.swift:36-58`) by walking it, dropping JSON `null`s. The bytes are parsed
  once; there is no re-encode and second `JSONSerialization` pass. A typed schema is not used,
  because JSON-LD lets a value and a one-element array stand for each other.
- **Content type and status: one check each.** The generated client picks the response case
  with `converter.bestContentType(received:options:)`, which throws
  `RuntimeError.unexpectedContentTypeHeader` when every option is `.incompatible`
  (`Converter+Common.swift:43-76`, runtime 1.11.0). `OpenAPIMIMEType.evaluate` makes a parameter
  in the option that is missing from the received type incompatible, ignores extra received
  parameters, and compares values case-sensitively. So with the two documented types, a bare
  `application/ld+json` is rejected and `application/activity+json; charset=utf-8` is accepted.
  FAP doesn't repeat that check for concrete types. It does not cover non-concrete ones:
  `bestContentType` returns the first option when no type was received *or* the received type
  is not concrete (`guard let received, case let .concrete(...) = received.kind else { return
  options[0] }`, `:45-52`; a partial wildcard such as `text/*` is treated as `*/*`, per the
  comment at `:48-51`). So a missing header, `*/*` and `text/*` would all be read as
  `application/activity+json`. The middleware's concrete-type check (step 4 above) closes those
  three. A status not in the document comes back as the generated `.undocumented` case, which
  `fetchRemoteObject` turns into its status error.
- **Stricter than Mastodon on multi-profile `ld+json`.** Mastodon's
  `valid_activitypub_content_type?` splits the quoted `profile` value on whitespace and accepts it
  when any entry is the AS profile (`json_ld_helper.rb:344-354`, the split at `:352`).
  `OpenAPIMIMEType.evaluate` compares the whole parameter value, so FAP rejects an
  `application/ld+json` whose `profile` lists the AS profile beside another one. This spec keeps
  that difference rather than adding a profile parser; a remote server that sends only such a value
  cannot be fetched by FAP.
- **Errors arrive wrapped.** The runtime wraps every error thrown by the transport, by a middleware
  or while decoding the response in `ClientError` (`Interface/UniversalClient.swift:94-185`). For
  transport and middleware failures it puts the original error in `underlyingError`
  (`Errors/RuntimeError.swift:77-83`), and for a non-runtime error thrown while decoding, such as
  the body wrapper's size or deadline error, the error itself (`UniversalClient.swift:119-126`;
  `Errors/ClientError.swift:71`). `fetchRemoteObject` unwraps `ClientError.underlyingError` before
  mapping to its own error cases, and the Step 0 tests assert on the unwrapped case. The runtime's
  own error type is `internal` (`Errors/RuntimeError.swift:23`), so a failure in the generated
  decode step (a `ClientError` with `response` set whose underlying error is not one of FAP's) can't
  be told apart by case: `fetchRemoteObject` maps it to one decode error that covers both a refused
  content type and invalid JSON.
- **The generated client is `internal`** (`accessModifier: internal` in
  `openapi-generator-config.yaml`). It is generated inside `ActivityPubCore`, beside
  `fetchRemoteObject`, `HTTPSignature` and `FetchSigningKey`; a separate target would need those
  types and would make the dependency circular. Only `fetchRemoteObject` is public.

### 0.2 The `HTTPClient` configuration

Each setting below was required by the spike, FederatedActivityPublisher#283, or follows from its
findings.

**Versions behind the line references.** Third-party file:line references in this spec are to
the versions one maintainer host resolved locally as of 2026-10-20: `async-http-client` 1.33.1,
`swift-openapi-runtime` 1.11.0, `swift-openapi-generator` 1.11.1 and `swift-nio-ssl` 2.36.1.
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
| `timeout.connect = .seconds(5)` and `timeout.read = .seconds(10)` (`HTTPClient.swift:1249,1251`) | `connect` bounds connection setup; AHC's default is 10 s (`connectionCreationTimeout`, `HTTPClient.swift:1256-1258`). `read` is an idle timeout: AHC passes it as the request's `idleReadTimeout` (`ConnectionPool/RequestOptions.swift:44`) and restarts it on every response part read (`ConnectionPool/HTTP1/HTTP1ClientChannelHandler.swift:148`); it has no default, so without it a fully stalled body is never ended. Both values are Mastodon's `connect_timeout: 5` and `read_timeout: 10` (`app/lib/request.rb:86`). With the longest caller deadline of 10 s, the worst case for a stalled body is 10 s + 10 s = 20 s, under the 29 s API Gateway limit | The values are a choice. That `read` ends a stalled body is [unverified] until the stall test runs |

**Address policy.** Refuse loopback (`127.0.0.0/8`, `::1`), RFC 1918, `100.64.0.0/10`, link-local
(`169.254.0.0/16`, `fe80::/10`), ULA (`fc00::/7`), unspecified, and IPv4-mapped IPv6 forms of
all of these. The spike's policy test covers 20 literals, among them `::ffff:127.0.0.1`,
`::ffff:169.254.169.254`, `fe80::1` and `fd00::1`; step 0's classifier test adds literals for
every range above. A test policy admits named loopback ports only.

**What the hook does not prevent, stated plainly.** The hook runs after the connection is set
up: after the TCP connect, and for `https` after the TLS handshake, since the factory completes
the connection only once `tlsEstablishedFuture` has fired (`HTTPConnectionPool+Factory.swift:532`).
So a refused address still receives a TCP connection, and for `https` a TLS ClientHello with the
requested host as SNI. Only the HTTP request is blocked: no request line, headers or signature
reach it. The spike measured the plain-`http` case; the `https` ordering is from the source.

**Deadline.** The middleware runs each hop's `next` raced against the remaining time and cancels
it on expiry; AHC's `execute` honours task cancellation (`AsyncAwait/HTTPClient+execute.swift:170-173`).
That covers the response head only: `execute` returns once the head arrives ("the `body` of the
response may not yet have been fully received", `:38`). The body wrapper checks the deadline on
every chunk, which stops a slow drip. A body that stalls completely sends no chunk to check, so
it is bounded by `timeout.read`; whether cancelling the task also ends a pending body read is
[unverified], and the stall test measures it.

**Dependencies.** One new package entry, `swift-server/swift-openapi-async-http-client`
(product `OpenAPIAsyncHTTPClient`), declared `from: "1.5.0"`, its latest release tag
(github.com/swift-server/swift-openapi-async-http-client/releases/tag/1.5.0, read 2026-10-20).
It is new to FAP's dependency graph and is a third-party package; it follows from decision 14
as set out there, and the step 0 PR's review covers it. `swift-server/async-http-client`
becomes a direct dependency; it is already resolved through `smithy-swift`, and the spike's
`Package.swift` change left the resolved pins unchanged (#283). `swift-openapi-runtime` and the
generator are already declared (`Package.swift:36-38`). Nothing imports `APIClient` today (only
`Package.swift:240` names it), so `OpenAPIRuntime`, `AsyncHTTPClient` and the generator plugin
reach the deployed Lambdas, and the plugin runs in the Lambda archive build, for the first time.
Every handler links `ActivityPubCore`, so every handler links AHC.

**Deployed build (C4, not yet measured).** The deploy build is
`swift package --allow-network-connections docker archive --base-docker-image swift-al2023:6.3`
(`deploy-stage.yml:326`): a glibc Amazon Linux 2023 image with the UBI9 Swift toolchain
(`docker/Dockerfile.al2023-swift`), with `libcrypto.so.3` and `libssl.so.3` copied into each
zip's `lib/` (`deploy-stage.yml:334-350`). It is not the static Linux SDK. No deployed handler
links AHC today (#283: 0 `AsyncHTTPClient` symbols in each of the 19 handler binaries), so the
existing deploy build says nothing about it. The step 0 PR's archive build on that image is the
measurement, before merge.

### 0.3 Behaviour changes

- **Quote path.** A `quoted_status_id` that is `http://`, redirects too often, is oversize, has a
  non-AP type or resolves to a refused address now fails. The quote is then marked `failed`,
  through the existing path (`PostHandler/main.swift:282-287`). Quote-path fetches are signed as
  the posting actor, which closes FederatedActivityPublisher#280 for `PostHandler`; the
  QuoteRequest actor lookup in `InboxHandler` (`InboxHandler/main.swift:1598`) is signed as the
  inbox owner, with the key #279 already loads.
- **Inbound key fetch.** Verifying an inbound signature now fetches the key through
  `fetchRemoteObject`: only status 200 and the two ActivityStreams content types are accepted,
  with at most 3 redirects, a 1 MB cap and the address check. The deadline is an absolute
  10 seconds. Today's 10 seconds (`KeyManager.swift:75`) is an idle timeout, so a slow response
  that keeps sending bytes now fails where it used to succeed. A remote server whose actor
  document fails these checks can no longer deliver to FAP.
- **No connection retries.** `retryConnectionEstablishment = false` (§0.2) applies to every
  fetch, not only refused addresses. A key fetch whose first connection attempt fails for an
  ordinary reason, such as a refused or reset connect, now fails at once where AHC's default would
  have retried it. `keyManager.getPublicKey` then throws and the inbound delivery fails
  (`InboxHandler/main.swift:125`). Only keys not already cached in `REMOTE_ACTOR#` (24 h TTL) are
  fetched, and the remote server's own delivery retry is then the only retry.
- **Release notes:** all three behaviour changes.
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

Signing itself ships in step 0: `fetchRemoteObject` takes a `FetchSigningKey` and the middleware
re-signs every hop with FederatedActivityPublisher#279's
`HTTPSignature.signGet(privateKeyPem:keyId:path:host:date:)`. That helper signs
`(request-target) host date`, with the query string in the request target, which is what
`signed_request.rb:54-57,113` requires. Phase 3a only adds signers:
- **Search** signs as the caller, with keyId `https://{serverDomain}/users/{u}#main-key`.
  Mastodon accepts any verifying account key (`signature_verification.rb:45` onward).
- **`DeliverHandler`** signs its actor fetch (§3.5) as the job's `actorUsername`, with the key it
  already reads (`DeliverHandler/main.swift:52-58`).
- **Keys** come from `{SSM_KEY_PREFIX}/{u}`, cached per container in a dictionary keyed by
  username.
- **IAM.** `SearchHandler`'s grant widens to the actor keys. If FederatedActivityPublisher#282 has
  landed, that is `activity/${Stage}/keys/actors/*`. If not, it is `activity/${Stage}/keys/*`
  with #279's pattern: an explicit `Deny` on `jwt-signing-key` and on `ssm:GetParametersByPath`
  (it still needs `session-signing-key` and `client-token` for auth).

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
| Signers for search and `DeliverHandler` | Callers of the step 0 signer support (§3.2) |
| `SearchHandler` SSM widening | Actor keys added to its grant (§3.2) |
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

**Step 0**, against local test servers, run on Linux as well as macOS.

The harness uses real sockets, not a stub transport, because a stub skips the layer under test.

- **Test servers.** Written in the test target on SwiftNIO, as the spike's is (#283): listening
  on `127.0.0.1:0`, counting connections, bytes received and closes. They serve fixed responses,
  redirects, oversize bodies, a slow drip and a stall. `NIOCore`, `NIOPosix`, `NIOSSL` and
  `NIOHTTP2` are already resolved through `async-http-client` (its `Package.swift` depends on
  `swift-nio-ssl` and `swift-nio-http2`), so they become direct test-target dependencies and no
  new package is added. None of them pulls `libxml2-dev` or `libicu-dev` onto the runner, which
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
  count, body cap, content type, deadline), the control is the production construction with that one
  check switched off, everything else unchanged. The switch is an `internal` option set on
  `RemoteFetchMiddleware`'s initializer, defaulted to every check, so production code can't reach it
  and tests set it through `@testable import ActivityPubCore`. For a setting of the `HTTPClient`
  (hook, close, retries, HTTP version, trust), the control is the production construction with that
  one setting changed. The test asserts the control gets the response the FAP client refuses.
- **The bare client is a fixture check, not a control.** The same request through an
  `HTTPClient` with AHC defaults and no generated layer or middleware, called with `execute`,
  shows that the test server serves what the test claims. It runs beside the control and does
  not replace it.
- **Every refusal test checks which control refused.** Each control throws its own error case.
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
- **Content type:** `text/html`, `text/html; charset=utf-8` and bare `application/ld+json` fail
  with the decode error, on a body that is a valid JSON object, so the content type is the only
  thing that can refuse it; `application/activity+json; charset=utf-8` and
  `application/ld+json; profile="https://www.w3.org/ns/activitystreams"` (the exact profile
  string, since values compare case-sensitively) pass. [The bare client accepts the refused
  ones; the runtime owns this check, so there is no FAP flag to switch off.]
- **Non-concrete content type:** a 200 with no `Content-Type`, one with `*/*` and one with
  `text/*` each fail with the middleware's content-type error. [The generated client without the
  middleware accepts all three, which is the runtime behaviour §0.1 names.]
- **Status:** a 404 and a 204 fail. [The bare client returns them; the runtime owns this check.]
- **Deadline, slow drip:** with a 2 s deadline, a body that sends one byte every 100 ms for 5 s
  fails with the deadline error between 2 s and 2.5 s. [With the deadline check off, it
  completes after about 5 s; `timeout.read` never fires, because bytes keep arriving.]
- **Deadline, stall:** with a 2 s deadline and a test client built with `timeout.read =
  .seconds(3)`, a server that sends the response head and then nothing fails by 2 s + 3 s = 5 s,
  plus 0.5 s of scheduling margin. The test records whether it ended at the deadline (cancellation
  ended the body read) or at `timeout.read`, which settles the §0.2 [unverified] item. [A client
  with no `timeout.read` and the deadline check off is still waiting at 10 s, when the test cancels
  it.]
- **Key fetch:** `fetchActorDocument(actorUri:signingKey:client:)`, through
  `@testable import ActivityPubCore`, fetches a valid key document from the test server; a
  4-redirect chain ending at a valid document fails with the redirect error; a valid document
  padded past 1 MB fails with the size error. [On the parent commit (with #279, before step 0),
  `fetchActorDocument(actorUri:signingKey: nil)` returns a key for both, because that code has
  no redirect or size cap and both fixtures parse.]
- **Address check, end to end:** a redirect from port A (admitted) to `127.0.0.1` on port C (not
  admitted) fails with the address error; server C records a connection, 0 bytes and a close.
  [A client built without the hook delivers the request to C.]
- **Address classifier:** the policy refuses every literal in §0.2, including the IPv4-mapped
  forms, `169.254.169.254` and `10.0.0.1`, and admits a public address. These are unit tests on
  literals: an end-to-end connect to the metadata address would reach a real service on a cloud
  runner. [An allow-all policy turns every refusal case red.]
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
  refuses it.]
- **Request target:** a URI with a query string and percent-encoded characters reaches the test
  server byte for byte. [The same URI through a plain `/{path}` template does not.]
- **Signing:** a signed fetch carries a `Signature` over `(request-target) host date` that
  verifies against the actor's public key, and a redirected fetch is signed again with the
  second hop's path. [An unsigned call carries no `Signature`; reusing the first hop's headers
  fails verification on the second.]
- **One client, concurrent:** two fetches to servers A and B run concurrently through one
  `RemoteFetchClient`, and server A holds its response until B has received its request; each
  reaches its own server. A fetch with no context bound throws the no-target error before any
  connection. [A test-only middleware variant that keeps the target in a stored property on the
  shared middleware sends one fetch to the wrong server.]

**Phases 1 to 3b: what the controls are.** Most tests below exercise symbols their step
introduces, so on the step's parent commit they don't compile; that is not a capability-removed
red, and no blanket parent-commit control is claimed. The control for each test is the case it
lists as "negative control": an input on the other side of the rule that the same code must
tell apart, so a test that passes on both sides fails. Two tests come closest to a
parent-commit run and still don't have one: the `buildNoteJSON` test sets `inReplyToId`, which
phase 1 adds, so it doesn't compile on the parent; and the `signGet` test exercises #279's
function, which exists before phase 3a, so on the parent it is expected to pass and acts as a
regression guard. The capability-removed controls for phases 1 and 2 are the integration
tests' runs against the pre-change stage build (Integration, below).

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

- Build every target the way the deploy does:
  `swift package --allow-network-connections docker archive --base-docker-image swift-al2023:6.3`
  (`deploy-stage.yml:326`), on the glibc Amazon Linux 2023 image from
  `docker/Dockerfile.al2023-swift`, with OpenSSL's shared libraries bundled into each zip's `lib/`.
  The deployed binary is that build, and a macOS `swift build` doesn't catch Linux-only compile
  errors. For step 0 this is also the C4 measurement (§0.2).
- Run the Step 0 and 3b unit tests on Linux.
- Build the generated consumers against the branch's `openapi.yaml`.

## Unverified

- **C4: AsyncHTTPClient in the deployed build.** No deployed handler links it today (#283). The
  step 0 PR's archive build on `swift-al2023:6.3` and a stage key fetch are the measurement.
- **Hook ordering for `https`.** Read in source: the hook runs after the TLS handshake
  (`HTTPConnectionPool+Factory.swift:532`). The spike measured plain `http` only. The Step 0
  "Address check over TLS" test measures it.
- **TaskLocal isolation on one client.** [inferred] from `UniversalClient.send` awaiting the chain
  inline. The concurrent "One client" test measures it.
- **Cancelling a pending body read.** Whether task cancellation ends an AHC body read that is
  waiting for bytes. The stall test measures it; `timeout.read` bounds it either way.
- **Pooled connections across a Lambda freeze.** The long-lived client keeps idle keep-alive
  connections in its pool, and a frozen container can thaw after the server has closed them.
  Whether AHC's pool detects that before reuse, or the first fetch after a long freeze fails, is
  not known. `connectionPool.idleTimeout` defaults to 60 s (`HTTPClient.swift:1383`). A stage
  fetch after an idle period longer than the remote server's keep-alive measures it.
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
| Connection-level address check | Step 0 | None. Security control |
| Hook closes the rejected channel itself | §0.2 | Yes, in the spike: without the close the connection stayed open, `closes=0` (FederatedActivityPublisher#283, T1 vs T1c) |
| `retryConnectionEstablishment = false` | §0.2 | Yes, in the spike: with retries on, a refused host got 7 connections in 2 s on macOS and 9 on Linux (FederatedActivityPublisher#283, T1b) |
| `httpVersion = .http1Only` | §0.2 | Not observed. FederatedActivityPublisher#283 notes the hook is HTTP/1.1-only as a source reading (its finding 3), and every spike client was `.http1Only`; the step 0 "HTTP/1.1 only" test is the first observation |
| `timeout.connect` / `timeout.read`, and the transport's 10 s `timeout` backstop | §0.1, §0.2 | None. Bounds on stalls the deadline race can't interrupt |
| Middleware throws with no target bound | §0.1 | None |
| Missing or non-concrete `Content-Type` refused | §0.1 | None. Closes a gap read in the runtime |
| 10 s search deadline | §3.3 | None. Rests on the documented 29 s API Gateway limit |
| `repliesCount` failure logged and swallowed | §1.6 | None |
| Safe-link scheme check and fallback | §2.7 | None. Security control |
| Remote validation (`id`, `attributedTo` host, actor `id`) | §3.3 | None. Matches Mastodon |
| Search returns empty and writes nothing on any failure | §3.3 | None |
| `DeliverHandler` requires the fetched actor's `id == targetActorUri` | §3.5 | None. Matches Mastodon's actor check (`fetch_remote_actor_service.rb:16`) |
| Read-time `ttl` comparison on `REF#` entries | §3.1 | None |
| Legacy `inReplyTo` without `inReplyToId` ignored | §1.3 | None. No legacy item has been observed |
| `META` deleted when a re-search derives `private` | §3.1 | None. Security control |
| Never change `visibility` from an Update | §3.1 | None. Security control |
| Delete/Update invalidation only from the object's origin | §3.1 | None. Security control |
| Unsigned delivery when LD signing fails | §3.6 | None |

## Decisions (2026-10-20)

The maintainer decided the following on 2026-10-20. Each item states his decision; where his
own words are known they are quoted. Section references, function and type names, and anything
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
      (`OpenAPIURLSession`, `integration-tests/Package.swift:18,29`). It can't host a
      connection-level hook on Linux. Its `Configuration` takes only a `URLSession` and a
      body-processing mode (`Sources/OpenAPIURLSession/URLSessionTransport.swift:67-81`,
      swift-openapi-urlsession 1.2.0), so a hook would have to come from `URLSession` itself, and
      FoundationNetworking's `URLSession` offers no callback that runs per connection with the
      connected address before the request is sent [unverified: not checked in
      swift-corelibs-foundation source; the transport choice rests on the accepted hook, not on
      this point]. The address check the maintainer accepted is AsyncHTTPClient's
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
    - **What the generated layer contributes and costs.** It contributes status dispatch (the
      `.undocumented` case), the concrete content-type match, and JSON decoding into
      `OpenAPIObjectContainer`, in place of about three hand-written checks; it costs an OpenAPI
      document that describes no real API (a placeholder `.invalid` origin, rewritten per hop), a
      `@TaskLocal` side channel because the operation has no real input, a middleware check for
      the content types the runtime lets through, and the generator plugin in every Lambda build.
    - **Structure** (§0.1, §0.2). One client per container; one `@TaskLocal`
      `RemoteFetchContext` carrying target, signer, deadline and scheme policy; the address policy
      and trust roots set when the client is built; the client injected into `fetchRemoteObject`
      with `.shared` as the default; one middleware that does the URL rewrite and every per-hop
      control; the generated client `internal` to `ActivityPubCore`; the placeholder origin
      `https://remote-fetch.invalid`.

## Open questions

1. **Guards without an observed failure.** Most rows in "Guards and fallbacks" rest on no
   observed failure. They fall in two groups.
   - **a. Security controls:** the step 0 scheme, redirect, body, content-type, status and
     deadline controls; the connection-level address check; the non-concrete `Content-Type`
     refusal; the safe-link check; remote validation; the `DeliverHandler` actor-`id` check;
     deleting `META` on a re-derived `private`; never changing `visibility` from an Update; and
     origin-only invalidation. Are these exempt from the observed-failure rule, or should any of
     them be dropped?
   - **b. Other guards and fallbacks:** the `repliesCount` swallow; unsigned delivery when LD
     signing fails; the no-target throw; the 10 s search deadline; search's empty-on-failure
     result; the `timeout.connect`/`timeout.read` and transport backstops; the read-time `ttl`
     comparison; and ignoring legacy `inReplyTo`. Should any of these be dropped, or kept only
     once a failure is observed?
2. **"List them as contributors."** This spec reads it as a new `CONTRIBUTORS.md` plus a README
   Acknowledgements section (decision 13). Confirm, or name another place (for example GitHub's
   co-author trailers on the vendoring commit).
