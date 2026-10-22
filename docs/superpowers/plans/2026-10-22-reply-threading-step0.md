# Reply Threading Step 0 (Fetch Hardening) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route every remote `GET` through one long-lived, generated OpenAPI client on `AsyncHTTPClientTransport`, with FAP's per-hop controls in one `ClientMiddleware`, Mastodon's private-address check on every connection, typed actor and object documents, signed fetches, and an `ActorKeyCache`.

**Architecture:** A FAP-authored OpenAPI document inside `ActivityPubCore` generates an `internal` client. One `RemoteFetchClient.shared` per Lambda container holds that client, an `HTTPClient` configured as in §0.2 of the spec (connection hook, no retries, HTTP/1.1 only, no proxy, no redirects, connect/read timeouts) and `RemoteFetchMiddleware`, which rewrites the placeholder origin to each hop and applies scheme, redirect, signing, deadline, status, content-type and body-size controls. `fetchRemoteObject` and `fetchRemoteActor` bind a `@TaskLocal` context per call and map generated types to two public structs.

**Tech Stack:** Swift 6.3, swift-openapi-generator/runtime, swift-openapi-async-http-client, async-http-client, SwiftNIO (test target only), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-20-reply-threading-design.md`, "Step 0 — Fetch hardening (security)" (§0.1–§0.3), "Testing → Unit → Step 0", "Build gate", "Unverified", "Guards and fallbacks" and decisions 14–17. Decisions 1–17 in the spec are settled; this plan does not reopen them. Where the spec and this plan differ, the section "Changes since the spec" below says why.

## Global Constraints

- Swift tools and toolchain 6.3 (`Package.swift:1`); platform floor `.macOS(.v15)` (`Package.swift:7`).
- New package entries, exactly: `swift-server/swift-openapi-async-http-client` `from: "1.5.0"`; `swift-server/async-http-client` `from: "1.33.1"`; `apple/swift-nio` `from: "2.97.1"`; `apple/swift-nio-ssl` `from: "2.36.1"`; `apple/swift-nio-http2` `from: "1.42.0"`.
- Raised floors: `swift-openapi-generator` `from: "1.11.1"`, `swift-openapi-runtime` `from: "1.11.0"` (today `1.6.0` and `1.7.0`, `Package.swift:36-37`).
- `NIOCore`, `NIOPosix`, `NIOSSL`, `NIOHTTP2` are dependencies of `ActivityPubCoreTests` only. No production target names them, and no production source file imports them (decision 16 in the spec).
- `Package.resolved` is regenerated only by the Resolve Packages workflow (`resolve-packages` label), never by a local toolchain (`AGENTS.md:271`).
- Placeholder origin `https://remote-fetch.invalid`, written once, in the document's `servers:`; never a literal in Swift.
- Per-fetch deadline at every non-search call site: `ContinuousClock.now + .seconds(10)`, computed at that fetch's call.
- Transport `timeout`: 10 s. `HTTPClient` `timeout.connect = .seconds(5)`, `timeout.read = .seconds(10)`.
- Redirects: at most 3 hops. Body cap: 1 MB, `1_048_576` bytes (Mastodon's `body_with_limit(limit = 1.megabyte)`, `app/lib/request.rb` at `2c540e4`); a body of exactly 1_048_576 bytes passes, one more byte fails.
- Declared content types, exactly: `application/activity+json` and `application/ld+json; profile="https://www.w3.org/ns/activitystreams"`.
- Only status 200 succeeds.
- The generated client is `internal` (`accessModifier: internal`). Public surface added: `fetchRemoteObject(uri:signer:deadline:)`, `fetchRemoteActor(uri:signer:deadline:)`, `RemoteObjectDocument`, `RemoteActorDocument`, `RemoteFetchError`, `ActorKeyCache`.
- Every `HTTPClient` and `RemoteFetchClient` a test builds runs inside `withTestClient(_:body:)`.
- Every test names its negative control; a test counts only after its control has been seen red. Record each control's observed output in the implementation PR description.
- Commit messages: short, code-focused, ending with the `Co-Authored-By:` trailer the repository's other commits use.

## Changes since the spec

These follow from the repository at `6d02908` (current `main`) and are not design changes.

1. **Pinned dependencies.** The spec says `Package.resolved` is gitignored (§0.2, "Versions behind the line references"). Since FederatedActivityPublisher#289 it is committed (`.gitignore` no longer lists it; `AGENTS.md:271`), every build resolves with `--force-resolved-versions` (`scripts/build-all-lambdas.sh:37`), and the file is regenerated only by `.github/workflows/resolve-packages.yml`. So the implementation PR commits a regenerated `Package.resolved` (Task 1), and the spec's "record the versions CI resolved" becomes "record the versions the committed file pins". At `6d02908` the file already pins versions newer than the spec's line references: `async-http-client` 1.36.2, `swift-openapi-runtime` 1.13.3, `swift-openapi-generator` 1.14.2, `swift-nio` 2.104.0, `swift-nio-ssl` 2.37.5, `swift-nio-http2` 1.46.0, `swift-http-types` 1.8.0. Spot checks at those tags: AHC 1.36.2 `HTTPClient.swift` still declares `http1_1ConnectionDebugInitializer`, `connectionPool.retryConnectionEstablishment` (default `true`), `httpVersion`, `.http1Only`, `proxy`, `redirectConfiguration`, `.disallow`, `timeout.connect`/`timeout.read`, `HTTPClientError.readTimeout` and the debug `deinit` precondition; runtime 1.13.3 `Base/OpenAPIMIMEType.swift` still declares `@_spi(Generated) public struct OpenAPIMIMEType`, `Kind.concrete`, `public var parameters` and an `internal` `static func evaluate(`. Task 1 re-checks every remaining cited line.
2. **The Lambda build.** The spec's C4 text names `swift package … docker archive` (`deploy-stage.yml:326` at the time). The build is now `scripts/build-all-lambdas.sh`, run in the AL2023 image by `scripts/in-build-image.sh`, and the `lambda-build` label runs it on a PR (`.github/workflows/lambda-build.yml:58-65`). So C4's build half moves before merge (Task 15). Its runtime half stays on stage after merge. The build links with `-Xlinker -s` (`scripts/build-all-lambdas.sh:106`), so the deployed binaries carry no symbol table and FederatedActivityPublisher#283's `nm` count cannot be repeated on them; Task 15's control is a deliberate compile break instead.
3. **TLS fixtures.** The spec commits the test CA and leaf as fixtures. `.gitignore:25-26` ignores `*.pem` and `*.key`, and no FAP target uses SwiftPM resources (spec, "Current FAP behaviour"). The fixtures are therefore committed as string literals in a test source file (Task 3).
4. **No NIO type names in production code.** The connection hook works on NIO's `Channel` and `SocketAddress`, which `ActivityPubCore` may not import (Global Constraints). The hook is a closure literal assigned to `HTTPClient.Configuration.http1_1ConnectionDebugInitializer`, so its parameter type is inferred, and it reads `channel.remoteAddress?.ipAddress` and `?.port` by member access. A member of a type from a transitively imported module is in scope unless the `MemberImportVisibility` upcoming feature is on (SE-0444, "Implemented (Swift 6.1)", opt-in); `Package.swift` sets no `swiftSettings`. The address classifier therefore takes the address as a `String`. Task 4 has a stop condition if this does not compile on Linux CI.
5. **`HTTPTypes`.** The middleware's `intercept` names `HTTPRequest`/`HTTPResponse`. Generated code imports `HTTPTypes` itself (generator `Translator/CommonTypes/Constants.swift:27`), and the existing `APIClient` target compiles generated code without declaring a `swift-http-types` product (`Package.swift:240-249`). Step 0 follows that and adds no `swift-http-types` entry.
6. **Line numbers.** The spec's FAP line references are at `8a78008`. This plan cites `6d02908`: for example `KeyManager` is `Sources/ActivityPubCore/Crypto/KeyManager.swift:27`, InboxHandler's `let keyManager = KeyManager()` is `Sources/InboxHandler/main.swift:62`, and the QuoteRequest actor lookup is `:1734`.
7. **`actorDocumentRequest`.** FederatedActivityPublisher#279's `KeyManager.actorDocumentRequest(url:signingKey:date:)` (`KeyManager.swift:85-117`) builds a `URLRequest`; after step 0 nothing sends one. Its path-and-query and `host[:port]` derivation moves to `HTTPSignature.signedGetHeaders(url:signer:date:)`, which the middleware calls, and `SignedFetchTests` move to it (Task 9). `KeyManagerError.invalidActorUri`, which the spec does not mention, is kept.
8. **`contentMap`.** "No schema sets `additionalProperties`" (§0.1) concerns the object schemas, so that unknown fields are tolerated. `contentMap`, "an object whose values are strings", is expressed as `additionalProperties: {type: string}`, the OpenAPI form for a string map. No schema uses `additionalProperties: false`.

## Review Focus

Inputs the spec implies that no spec-listed test exercises, most likely first. Each has a test in the owning task.

1. **A 3xx without `Location`** (a `304`, or a `302` with the header missing). Expected: not followed; fails with the status error. Test: Task 5, `redirectWithoutLocationFailsWithStatus`.
2. **A body of exactly 1 MB.** Expected: 1_048_576 bytes decode; 1_048_577 fail with the size error. Test: Task 7, `bodyAtExactlyOneMegabytePasses`.
3. **Mixed-case content type** (`Application/Activity+JSON`). Expected: accepted (type and subtype compare case-insensitively). Test: Task 6, `contentTypeTypeAndSubtypeAreCaseInsensitive`.
4. **A deadline already past when the fetch is called.** Expected: deadline error, 0 connections. Test: Task 7, `expiredDeadlineFailsBeforeConnecting`.
5. **A URI whose path begins with `//`** (`https://host:A//other/x`). The transport parses the request path with `URLComponents(string:)` before appending it to the base URL (`AsyncHTTPClientTransport.convertRequest`, swift-openapi-async-http-client 1.5.0), so `//other` could be read as an authority. Expected: the request goes to `host:A`, never to `other`. Test: Task 9, `pathStartingWithDoubleSlashStaysOnTheURIHost`.

---

## File structure

| File | Responsibility |
|---|---|
| `Package.swift` | Dependencies, floors, target products, generator plugin on `ActivityPubCore` |
| `Package.resolved` | Regenerated by the Resolve Packages workflow |
| `Sources/ActivityPubCore/openapi.yaml` | Remote-fetch document: placeholder server, `getObject`, `getActor`, schemas |
| `Sources/ActivityPubCore/openapi-generator-config.yaml` | `types`, `client`, `accessModifier: internal` |
| `Sources/ActivityPubCore/RemoteFetch/RemoteFetchError.swift` | `RemoteFetchError`, `UndocumentedStatusError`, the error-mapping order |
| `Sources/ActivityPubCore/RemoteFetch/RemoteFetchContext.swift` | `RemoteFetchContext` (`@TaskLocal`), `SchemePolicy` |
| `Sources/ActivityPubCore/RemoteFetch/PrivateAddressCheck.swift` | Address classifier, `AddressPolicy` |
| `Sources/ActivityPubCore/RemoteFetch/RemoteFetchMiddleware.swift` | `RemoteFetchChecks`, `RemoteFetchMiddleware`, the capped body sequence |
| `Sources/ActivityPubCore/RemoteFetch/RemoteFetchClient.swift` | Client construction, `shared`, `shutdown()` |
| `Sources/ActivityPubCore/RemoteFetch/RemoteDocuments.swift` | `RemoteObjectDocument`, `RemoteActorDocument`, mapping from generated types |
| `Sources/ActivityPubCore/FetchRemoteObject.swift` | `fetchRemoteObject`, `fetchRemoteActor` (public + internal overloads) |
| `Sources/ActivityPubCore/Crypto/ActorKeyCache.swift` | Per-container private-key cache |
| `Sources/ActivityPubCore/Crypto/KeyManager.swift` | Stored client, `fetchActorDocument` on `fetchRemoteActor`, deadlines |
| `Sources/ActivityPubCore/Crypto/HTTPSignature.swift` | `signedGetHeaders(url:signer:date:)` |
| `Sources/InboxHandler/main.swift` | `ActorKeyCache`, deadlines, signed QuoteRequest actor lookup |
| `Sources/PostHandler/main.swift` | `ActorKeyCache`, signed quote-path fetches |
| `Sources/ActivityPubCore/Documentation.docc/ActivityPubCore.md`, `AuthenticationOverview.md` | New public symbols |
| `Tests/ActivityPubCoreTests/RemoteFetch/TestServer.swift` | NIO HTTP/1.1 and TLS test servers that record connections, bytes, closes, handshakes, requests |
| `Tests/ActivityPubCoreTests/RemoteFetch/TestCertificates.swift` | Test CA and leaf as string literals |
| `Tests/ActivityPubCoreTests/RemoteFetch/TestSupport.swift` | `withTestClient`, `makeTestClient`, `bareFetch`, `expectFetchError`, fixtures |
| `Tests/ActivityPubCoreTests/RemoteFetch/*Tests.swift` | One file per task below |

---

### Task 1: Dependencies and pinned versions

**Files:**
- Modify: `Package.swift:30-43` (package entries), `:46-57` (`ActivityPubCore`), `:252-260` (`ActivityPubCoreTests`)
- Modify: `Package.resolved` (from the workflow artifact)

**Interfaces:**
- Produces: products available to later tasks. `ActivityPubCore`: `AsyncHTTPClient`, `OpenAPIRuntime`, `OpenAPIAsyncHTTPClient`. `ActivityPubCoreTests`: `AsyncHTTPClient`, `OpenAPIRuntime`, `NIOCore`, `NIOPosix`, `NIOSSL`, `NIOHTTP2`.

- [ ] **Step 1: Branch from main.** `git switch -c feat/fetch-hardening origin/main`.

- [ ] **Step 2: Edit `Package.swift`.** Raise the two floors (Global Constraints). Add the five package entries. Add to `ActivityPubCore.dependencies`: `.product(name: "AsyncHTTPClient", package: "async-http-client")`, `.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")`, `.product(name: "OpenAPIAsyncHTTPClient", package: "swift-openapi-async-http-client")`. Add to `ActivityPubCoreTests.dependencies`: `AsyncHTTPClient`, `OpenAPIRuntime`, `NIOCore`, `NIOPosix` (package `swift-nio`), `NIOSSL` (`swift-nio-ssl`), `NIOHTTP2` (`swift-nio-http2`). Do not add the generator plugin yet (it fails without the document; Task 4).

- [ ] **Step 3: Open a draft PR and regenerate the pins.** Push, open the implementation PR as a draft, add the `resolve-packages` label. When the Resolve Packages run finishes: `gh run download <run-id> -n Package.resolved`, then review `git diff Package.resolved`.
  Expected: one new pin, `swift-openapi-async-http-client` at `1.5.0` or later; every pin for `async-http-client`, `swift-nio`, `swift-nio-ssl`, `swift-nio-http2`, `swift-openapi-generator`, `swift-openapi-runtime` at or above its floor; no pin removed.

- [ ] **Step 4: Re-check every cited third-party line at the pinned versions.** For each third-party file:line the spec's §0.1, §0.2 and Testing cite (AHC, runtime, generator, transport, NIOSSL), read the file at the pinned tag (read-only, e.g. `https://raw.githubusercontent.com/<org>/<repo>/<tag>/<path>`) and confirm the cited behaviour. Record a table `cited | pinned tag | still holds (yes/no, new line)` in the PR description. If any cited behaviour no longer holds, stop and report it; do not adapt the design.

- [ ] **Step 5: Run tests.** CI's Test job on the pushed commit. Expected: green; nothing uses the new products yet.

- [ ] **Step 6: Commit.**

```bash
git add Package.swift Package.resolved
git commit -m "build: add AsyncHTTPClient transport and NIO test dependencies"
```

---

### Task 2: Private-address classifier

**Files:**
- Create: `Sources/ActivityPubCore/RemoteFetch/PrivateAddressCheck.swift`
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/PrivateAddressCheckTests.swift`

**Interfaces:**
- Produces:
  - `enum PrivateAddressCheck` with `struct Checks: OptionSet, Sendable { static let unwrapEmbeddedIPv4, cidrList, namedRanges; static let all }` and `static func isPrivate(_ ipAddress: String, checks: Checks = .all) -> Bool`.
  - `enum AddressPolicy: Sendable { case mastodonPrivateAddressCheck; case loopbackPorts(Set<Int>); case allowAll }` with `func refuses(ipAddress: String?, port: Int?) -> Bool`.

- [ ] **Step 1: Write the failing tests.**

```swift
@Suite("Private address classifier") struct PrivateAddressCheckTests {
    static let cidrList = ["0.1.2.3", "100.64.0.1", "172.16.0.1", "192.0.0.1", "192.0.2.1",
        "192.88.99.1", "198.18.0.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "240.0.0.1",
        "255.255.255.255", "::", "64:ff9b::1", "64:ff9b:1::1", "100::1", "2001::1", "2001:10::1",
        "2001:20::1", "2001:db8::1", "2002::1", "fd00::1", "3fff::1", "ff02::1"]
    static let namedRanges = ["10.0.0.1", "192.168.0.1", "127.0.0.1", "::1", "169.254.0.1", "fe80::1"]
    static let embedded = ["64:ff9b::a9fe:a9fe", "2002:a9fe:a9fe::1", "::ffff:169.254.169.254",
        "::169.254.169.254", "::ffff:127.0.0.1", "169.254.169.254"]

    @Test(arguments: cidrList + namedRanges + embedded)
    func refused(_ ip: String) { #expect(PrivateAddressCheck.isPrivate(ip)) }

    @Test(arguments: ["1.1.1.1", "2606:4700:4700::1111"])
    func admitted(_ ip: String) { #expect(!PrivateAddressCheck.isPrivate(ip)) }

    @Test func unparsableOrMissingAddressIsRefused() {
        #expect(PrivateAddressCheck.isPrivate("not-an-ip"))
        #expect(AddressPolicy.mastodonPrivateAddressCheck.refuses(ipAddress: nil, port: 443))
    }

    // Controls
    @Test(arguments: cidrList + namedRanges + embedded)
    func allowAllAdmitsEveryRefusedLiteral(_ ip: String) {
        #expect(!AddressPolicy.allowAll.refuses(ipAddress: ip, port: 443))
    }
    @Test func withoutUnwrappingIPv4CompatibleMetadataIsAdmitted() {
        #expect(!PrivateAddressCheck.isPrivate("::169.254.169.254",
            checks: .all.subtracting(.unwrapEmbeddedIPv4)))
    }
    @Test func withoutCIDRListNAT64MetadataIsAdmitted() {
        #expect(!PrivateAddressCheck.isPrivate("64:ff9b::a9fe:a9fe", checks: .all.subtracting(.cidrList)))
    }
    @Test func loopbackPolicyAdmitsOnlyNamedPorts() {
        #expect(!AddressPolicy.loopbackPorts([8080]).refuses(ipAddress: "127.0.0.1", port: 8080))
        #expect(AddressPolicy.loopbackPorts([8080]).refuses(ipAddress: "127.0.0.1", port: 8081))
        #expect(AddressPolicy.loopbackPorts([8080]).refuses(ipAddress: "1.1.1.1", port: 8080))
    }
}
```

- [ ] **Step 2: Run.** `swift test --filter PrivateAddressCheckTests`. Expected: fails to compile (`PrivateAddressCheck` undefined).

- [ ] **Step 3: Implement `PrivateAddressCheck.swift`.** Parse with `inet_pton` (`AF_INET`, then `AF_INET6`; Foundation provides it on Darwin and Glibc); a string that parses as neither is private (fail closed). Order, per §0.2: `::` and `::1` checked first as IPv6; then, with `.unwrapEmbeddedIPv4`, an IPv4-mapped (`::ffff:0:0/96`) or IPv4-compatible (`::/96`) address is checked as its embedded IPv4 address; then `.namedRanges` (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7`, `127.0.0.0/8`, `::1`, `169.254.0.0/16`, `fe80::/10`); then `.cidrList`, the 24 entries of §0.2 verbatim, as a `static let` array of `(bytes, prefixLength)`. `AddressPolicy.mastodonPrivateAddressCheck` refuses `nil` and every private address; `.loopbackPorts(p)` admits only `127.0.0.1` with a port in `p`; `.allowAll` admits everything (tests only). Doc comment cites `app/lib/private_address_check.rb` at commit `467c933`.

- [ ] **Step 4: Run.** Same command. Expected: all pass. Then remove `cidrList` handling locally and confirm `withoutCIDRList…` alone stays green while `refused("64:ff9b::a9fe:a9fe")` goes red; restore. Record the output.

- [ ] **Step 5: Commit.** `git commit -m "feat: private-address classifier with Mastodon's CIDR list"`

---

### Task 3: Test servers, TLS fixtures and the legacy key-fetch control

**Files:**
- Create: `Tests/ActivityPubCoreTests/RemoteFetch/TestServer.swift`, `TestCertificates.swift`, `TestSupport.swift`, `LegacyFetchControlTests.swift`

**Interfaces:**
- Produces (test target only):
  - `final class TestServer: Sendable` with `static func start(tls: TestTLS? = nil, respond: @escaping @Sendable (RecordedRequest) -> TestResponse) async throws -> TestServer`, `var port: Int`, `func url(_ pathAndQuery: String, scheme: String = "http") -> String`, `var stats: ServerStats`, `func stop() async throws`.
  - `ServerStats`: `connections`, `bytes` (HTTP bytes after TLS), `closes`, `tlsHandshakes`, `requests: [RecordedRequest]`.
  - `struct RecordedRequest: Sendable { let method: String; let target: String; let headers: [String: String] }` (header names lowercased).
  - `enum TestResponse: Sendable { case document(contentType: String?, body: String, status: Int = 200); case redirect(status: Int = 302, location: String?); case drip(contentType: String, every: Duration, totalBytes: Int); case stallAfterHead(contentType: String); case holdUntil(TestBarrier, then: TestResponse) }`.
  - `struct TestTLS { var alpn: [String] = ["http/1.1"]; var http2: Bool = false }`.
  - `enum TestCertificates { static let caPEM, leafPEM, leafKeyPEM: String }`.
  - `func bareFetch(_ url: String) async throws -> (status: Int, headers: [(String, String)], bodyBytes: Int)` (AHC defaults, `execute`, no middleware, inside `withTestClient`).
  - `enum Fixtures { static func actor(id: String, inbox: String, publicKeyPem: String, extra: String = "") -> String; static func note(id: String, attributedTo: String) -> String; static func padded(_ json: String, toAtLeast bytes: Int) -> String }`.

- [ ] **Step 1: Generate the TLS fixtures once.** With `openssl`: a test CA (`CN=FAP Test CA`, 100-year validity) and a leaf signed by it with `subjectAltName = IP:127.0.0.1, DNS:localhost`, 100-year validity. Paste the three PEM blocks into `TestCertificates.swift` as raw string literals, with a header comment: test-only, not secrets, regenerated by the commands in the comment. Do not commit `.pem`/`.key` files (`.gitignore:25-26`).

- [ ] **Step 2: Write `TestServer`.** Model it on FederatedActivityPublisher#283's `RecordingHandler` (`ServerBootstrap` on `MultiThreadedEventLoopGroup.singleton`, bind `127.0.0.1:0`, counters in a `Mutex`). It parses the request head, records it, and writes the `TestResponse`. With `tls`, the child pipeline starts with `NIOSSLServerHandler(context:)` built from `TLSConfiguration.makeServerConfiguration(certificateChain:privateKey:)` and `applicationProtocols = tls.alpn`; a handshake is counted when a user inbound event whose `String(describing:)` begins with `handshakeCompleted` arrives (this avoids naming `TLSUserEvent`, which lives in `NIOTLS`, not a declared test dependency). With `tls.http2`, the pipeline after TLS is `configureHTTP2Pipeline(mode: .server, inboundStreamInitializer:)` with `HTTP2FramePayloadToHTTP1ServerCodec()` and the same responder. `.drip` writes a head with `Content-Length: totalBytes`, then one `a` byte every `every`. `.stallAfterHead` writes a head with `Content-Length: 10` and nothing else. `.holdUntil` waits on the barrier before responding.

- [ ] **Step 3: Write `withTestClient` for `HTTPClient` and `bareFetch`.** `func withTestClient<T>(_ client: HTTPClient, body: (HTTPClient) async throws -> T) async throws -> T` awaits `client.shutdown()` on the returning and the throwing path. (The `RemoteFetchClient` overload comes in Task 4.)

- [ ] **Step 4: Fixture checks.**

```swift
@Test func fixtureRedirectChainServesFourRedirects() async throws {
    // servers R1→R2→R3→R4→D; bareFetch with AHC defaults follows them
    let r = try await bareFetch(r1.url("/start"))
    #expect(r.status == 200)
    #expect(d.stats.requests.count == 1)
}
@Test func fixtureOversizeServesMoreThanOneMegabyte() async throws {
    let r = try await bareFetch(big.url("/actor"))
    #expect(r.bodyBytes > 1_048_576)
}
```

- [ ] **Step 5: The legacy control for the key-fetch test (spec, "Key fetch").** In `LegacyFetchControlTests.swift`, against the parent code: `KeyManager().fetchActorDocument(actorUri: r1.url("/start"), signingKey: nil)` through a 4-redirect chain ending at `Fixtures.actor`, and against a valid actor padded past 1 MB. Assert both return a `RemoteActor` with the fixture's `publicKeyPem`.

- [ ] **Step 6: Run.** `swift test --filter "fixture|LegacyFetchControl"`. Expected: PASS; the legacy fetch has no redirect or size cap. Record the output in the PR description: it is the key-fetch control's red (capability absent).

- [ ] **Step 7: Commit.** `git commit -m "test: NIO test servers, TLS fixtures, legacy key-fetch control"`

---

### Task 4: Document, generated client, client construction and the fetch pipe

**Files:**
- Create: `Sources/ActivityPubCore/openapi.yaml`, `Sources/ActivityPubCore/openapi-generator-config.yaml`, `RemoteFetch/RemoteFetchError.swift`, `RemoteFetch/RemoteFetchContext.swift`, `RemoteFetch/RemoteFetchClient.swift`, `RemoteFetch/RemoteFetchMiddleware.swift`, `RemoteFetch/RemoteDocuments.swift`
- Modify: `Package.swift` (`ActivityPubCore` gains `plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]`), `Sources/ActivityPubCore/FetchRemoteObject.swift` (add the new functions beside the legacy one, which Task 14 deletes)
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/RemoteFetchClientTests.swift`, `TestSupport.swift`

**Interfaces:**
- Produces:
  - `public enum RemoteFetchError: Error` with exactly the cases of §0.1 "The error type": `invalidURI(String)`, `noContext`, `schemeRefused(URL)`, `tooManyRedirects(URL)`, `deadlineExceeded`, `status(Int)`, `contentType(String?)`, `bodyTooLarge`, `addressRefused(String)`, `invalidDocument(DecodingError)`, `generatedLayerRefused(underlying: any Error)`, `transportFailed(underlying: any Error)`.
  - `struct UndocumentedStatusError: Error { let statusCode: Int }`.
  - `extension RemoteFetchError { static func from(_ error: any Error) -> RemoteFetchError }`: unwrap `ClientError.underlyingError`, then the spec's order 1–5 (§0.1, "Telling the generated layer from the transport"), using `ClientError.response != nil` for rule 4.
  - `struct RemoteFetchContext: Sendable { let target: URL; let signer: FetchSigningKey?; let deadline: ContinuousClock.Instant; let schemePolicy: SchemePolicy; @TaskLocal static var current: RemoteFetchContext? }`.
  - `enum SchemePolicy: Sendable { case httpsOnly; case allowingHTTP(ports: Set<Int>); func admits(_ url: URL) -> Bool }` (`allowingHTTP` admits `https` everywhere and `http` only on the listed ports; scheme compared case-insensitively).
  - `struct RemoteFetchClient: Sendable { let client: Client; let httpClient: HTTPClient; static let shared: RemoteFetchClient; static func make(addressPolicy: AddressPolicy = .mastodonPrivateAddressCheck, checks: RemoteFetchChecks = .all, closesRefusedChannel: Bool = true, middleware: (any ClientMiddleware)? = nil, adjust: (inout HTTPClient.Configuration) -> Void = { _ in }) -> RemoteFetchClient; func shutdown() async throws }`.
  - `struct RemoteFetchChecks: OptionSet, Sendable` with `scheme`, `redirectLimit`, `bodyCap`, `contentType`, `status`, `deadline`, `verbatimRequestTarget`, `resignEachHop`, and `static let all`. (This task implements only the no-context throw and the single-hop rewrite; Tasks 5–9 add the rest.)
  - `struct RemoteFetchMiddleware: ClientMiddleware { init(checks: RemoteFetchChecks = .all) }`.
  - `public struct RemoteObjectDocument: Sendable { public let id: String; public let types: [String]; public let attributedTo: String?; public let to: [String]; public let cc: [String]; public let url: String?; public let content: String?; public let summary: String?; public let sensitive: Bool?; public let published: String?; public let language: String? }`.
  - `public struct RemoteActorDocument: Sendable { public let id: String; public let inbox: String; public let sharedInbox: String?; public let publicKeyPem: String?; public let followers: String?; public let url: String?; public let preferredUsername: String? }`.
  - `public func fetchRemoteObject(uri: String, signer: FetchSigningKey? = nil, deadline: ContinuousClock.Instant) async throws -> RemoteObjectDocument` and the internal overload `fetchRemoteObject(uri:signer:deadline:schemePolicy:client:)`; the same pair for `fetchRemoteActor` returning `RemoteActorDocument`.
  - Test support: `func withTestClient<T>(_ client: RemoteFetchClient, body: (RemoteFetchClient) async throws -> T) async throws -> T`; `func makeTestClient(admitting ports: Set<Int>, checks: RemoteFetchChecks = .all, closesRefusedChannel: Bool = true, middleware: (any ClientMiddleware)? = nil, adjust: @escaping (inout HTTPClient.Configuration) -> Void = { _ in }) -> RemoteFetchClient` (calls `RemoteFetchClient.make` with `.loopbackPorts(ports)` and an `adjust` that first sets `tlsConfiguration` with `trustRoots = .certificates([try! NIOSSLCertificate(bytes: Array(TestCertificates.caPEM.utf8), format: .pem)])`, then applies the caller's); `func expectFetchError(_ matches: (RemoteFetchError) -> Bool, _ body: () async throws -> some Any) async`.

- [ ] **Step 1: Write the document.** `Sources/ActivityPubCore/openapi.yaml`:

```yaml
openapi: 3.1.0
info:
  title: FAP remote fetch
  version: 1.0.0
  description: >
    Remote ActivityPub documents FAP reads. The origin and paths are placeholders:
    RemoteFetchMiddleware replaces them with each hop's origin, path and query.
servers:
  - url: https://remote-fetch.invalid
paths:
  /object:
    get:
      operationId: getObject
      responses:
        '200':
          description: An ActivityStreams object.
          content:
            application/activity+json:
              schema: { $ref: '#/components/schemas/RemoteObject' }
            'application/ld+json; profile="https://www.w3.org/ns/activitystreams"':
              schema: { $ref: '#/components/schemas/RemoteObject' }
  /actor:
    get:
      operationId: getActor
      responses:
        '200':
          description: An ActivityStreams actor.
          content:
            application/activity+json:
              schema: { $ref: '#/components/schemas/RemoteActor' }
            'application/ld+json; profile="https://www.w3.org/ns/activitystreams"':
              schema: { $ref: '#/components/schemas/RemoteActor' }
components:
  schemas:
    RemoteActor:
      type: object
      required: [id, inbox]
      properties:
        id: { type: string }
        inbox: { type: string }
        endpoints: { $ref: '#/components/schemas/Endpoints' }
        publicKey: { $ref: '#/components/schemas/PublicKeyValue' }
        followers: { type: string }
        url: { $ref: '#/components/schemas/UrlValue' }
        preferredUsername: { type: string }
    Endpoints:
      type: object
      properties:
        sharedInbox: { type: string }
    PublicKey:
      type: object
      required: [publicKeyPem]
      properties:
        publicKeyPem: { type: string }
        id: { type: string }
        owner: { type: string }
    PublicKeyValue:
      oneOf:
        - { $ref: '#/components/schemas/PublicKey' }
        - { type: array, items: { $ref: '#/components/schemas/PublicKey' } }
    RemoteObject:
      type: object
      required: [id, type]
      properties:
        id: { type: string }
        type: { $ref: '#/components/schemas/TypeValue' }
        attributedTo: { $ref: '#/components/schemas/IdRefs' }
        to: { $ref: '#/components/schemas/IdRefs' }
        cc: { $ref: '#/components/schemas/IdRefs' }
        url: { $ref: '#/components/schemas/UrlValue' }
        content: { type: string }
        summary: { type: string }
        sensitive: { type: boolean }
        published: { type: string }
        contentMap:
          type: object
          additionalProperties: { type: string }
    TypeValue:
      oneOf:
        - { type: string }
        - { type: array, items: { type: string } }
    IdRef:
      oneOf:
        - { type: string }
        - { type: object, required: [id], properties: { id: { type: string } } }
    IdRefs:
      oneOf:
        - { $ref: '#/components/schemas/IdRef' }
        - { type: array, items: { $ref: '#/components/schemas/IdRef' } }
    Link:
      type: object
      required: [href]
      properties:
        href: { type: string }
    UrlValue:
      oneOf:
        - { type: string }
        - { $ref: '#/components/schemas/Link' }
        - type: array
          items:
            oneOf:
              - { type: string }
              - { $ref: '#/components/schemas/Link' }
```

  `openapi-generator-config.yaml`:

```yaml
generate:
  - types
  - client
accessModifier: internal
```

- [ ] **Step 2: Write the failing tests.**

```swift
@Test func clientConstructionCompletes() async throws {
    // The production construction, as RemoteFetchClient.shared uses it; runs the try! on Servers.Server1.url()
    // Passes when construction completes without trapping; there is nothing else to assert.
    try await withTestClient(RemoteFetchClient.make()) { _ in }
}
@Test func fetchesAValidObjectAndActor() async throws {
    // server A serves Fixtures.note at /n and Fixtures.actor at /a with application/activity+json
    try await withTestClient(makeTestClient(admitting: [a.port])) { client in
        let note = try await fetchRemoteObject(uri: a.url("/n"), deadline: .now + .seconds(10),
            schemePolicy: .allowingHTTP(ports: [a.port]), client: client)
        #expect(note.id == a.url("/n")); #expect(note.attributedTo == a.url("/a"))
        let actor = try await fetchRemoteActor(uri: a.url("/a"), deadline: .now + .seconds(10),
            schemePolicy: .allowingHTTP(ports: [a.port]), client: client)
        #expect(actor.inbox == a.url("/a/inbox"))
    }
}
@Test func unboundCallThrowsNoContextBeforeConnecting() async throws {
    try await withTestClient(makeTestClient(admitting: [a.port])) { client in
        var caught: (any Error)?
        do { _ = try await client.client.getObject() } catch { caught = error }
        let error = try #require(caught)
        guard case .noContext = RemoteFetchError.from(error) else { Issue.record("\(error)"); return }
        #expect(a.stats.connections == 0)
    }
}
@Test func invalidURIFails() async { await expectFetchError({ if case .invalidURI = $0 { true } else { false } }) {
    try await fetchRemoteObject(uri: "not a url", deadline: .now + .seconds(10)) } }
```

- [ ] **Step 3: Run.** `swift test --filter RemoteFetchClientTests`. Expected: compile failure.

- [ ] **Step 4: Implement.**
  - `RemoteFetchClient.make`: `var config = HTTPClient.Configuration(redirectConfiguration: .disallow, timeout: .init(connect: .seconds(5), read: .seconds(10)))`; `config.httpVersion = .http1Only`; `config.proxy = nil`; `config.connectionPool.retryConnectionEstablishment = false`; `config.http1_1ConnectionDebugInitializer = { channel in … }`: read `channel.remoteAddress?.ipAddress` and `?.port`; if `addressPolicy.refuses(...)`, call `channel.close(promise: nil)` when `closesRefusedChannel`, and return `channel.eventLoop.makeFailedFuture(RemoteFetchError.addressRefused(<address description>))`; else `channel.eventLoop.makeSucceededVoidFuture()`. Then `adjust(&config)`. `HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)`. Transport: `AsyncHTTPClientTransport(configuration: .init(client: httpClient, timeout: .seconds(10)))`. Client: `Client(serverURL: try! Servers.Server1.url(), transport: transport, middlewares: [middleware ?? RemoteFetchMiddleware(checks: checks)])`. `static let shared = RemoteFetchClient.make()`. `shutdown()` awaits `httpClient.shutdown()`. Write no NIO type name in this file.
  - `RemoteFetchMiddleware.intercept`: throw `.noContext` when `RemoteFetchContext.current` is `nil`; otherwise set the base URL to the target's origin (scheme, host, port; IPv6 hosts bracketed) and `request.path` to the target's `percentEncodedPath` (`/` when empty) plus `?` + `percentEncodedQuery`, then call `next`.
  - `fetchRemoteObject`/`fetchRemoteActor`: parse `uri` with `URL(string:)` and require a scheme and a host, else `invalidURI(uri)`; bind `RemoteFetchContext` with `$current.withValue`; call `getObject()`/`getActor()`; on `.ok`, switch over both body cases (read the two case names from the generated `Types.swift` under `.build/plugins/outputs/`) and map with `RemoteDocuments.swift`; on `.undocumented(statusCode:_:)` throw `.generatedLayerRefused(underlying: UndocumentedStatusError(statusCode:))`; catch every other error and throw `RemoteFetchError.from(error)`.
  - `RemoteDocuments.swift`: mapping per §0.1 "How the typed results are consumed": `attributedTo` = first entry, as its string or its `id`; `to`/`cc` = every entry the same way (absent → `[]`); `types` = the string or the array; `url` = the string, or the `Link`'s `href`, or for an array the first `Link`'s `href`, else the first string; `language` = `contentMap`'s key when it has exactly one; actor `publicKeyPem` = the object's, or the first array entry's; actor `sharedInbox` = `endpoints.sharedInbox`.
  - **Stop condition:** if `RemoteFetchClient.swift` does not compile on Linux CI without importing a NIO module (Changes since the spec, item 4), stop and report; do not add an import or a product dependency.

- [ ] **Step 5: Run.** Same filter, locally and in CI. Expected: PASS.

- [ ] **Step 6: Construction control.** On a throwaway branch (never merged), change `servers: url:` to `https://[remote-fetch.invalid` and run `swift test --filter clientConstructionCompletes` in CI. Expected: red, the test process trapping at the `try!` with `invalidServerURL` in the log. Record the run URL. If the failure is anything else (for example the generator rejecting the document), the control is not discharged: report it.

- [ ] **Step 7: Commit.** `git commit -m "feat: generated remote-fetch client on AsyncHTTPClientTransport"`

---

### Task 5: Scheme, redirects and `Location`

**Files:**
- Modify: `RemoteFetch/RemoteFetchMiddleware.swift`
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/RedirectAndSchemeTests.swift`

**Interfaces:**
- Consumes: Task 4's middleware, context, `makeTestClient`, `expectFetchError`.
- Produces: the hop loop. Later tasks add per-hop signing (Task 9), deadline (Task 7) and response checks (Tasks 6, 7) inside it.

- [ ] **Step 1: Write the failing tests** (each with its bracketed control as its own `@Test`):

```swift
@Test func threeRedirectsPass() async throws { /* R1→R2→R3→D: document returned; D got 1 request */ }
@Test func fourthRedirectFails() async {      /* R1→R2→R3→R4→D */
    await expectFetchError({ if case .tooManyRedirects = $0 { true } else { false } }) { … }
    #expect(d.stats.connections == 0) }
@Test func fourthRedirectFollowedWithLimitOff() async throws {   // control
    // makeTestClient(…, checks: .all.subtracting(.redirectLimit)): document returned, D got 1 request
}
@Test func unparsableLocationFailsWithInvalidURI() async { /* 302, Location: "http://[" → .invalidURI */ }
@Test func validLocationIsFollowed() async throws { /* control: same server, Location: D's URL → document */ }
@Test func relativeLocationResolvesAgainstTheHop() async throws { /* Location: "/doc" on R1 → R1 serves /doc */ }
@Test func redirectWithoutLocationFailsWithStatus() async { /* 302 no Location → .status(302); 304 → .status(304) */ }
@Test func httpInitialURIFailsUnderDefaultPolicy() async { /* schemePolicy .httpsOnly, http URI → .schemeRefused, 0 connections */ }
@Test func redirectToUnadmittedHTTPPortFails() async { /* policy .allowingHTTP([A]); A→B → .schemeRefused(B url), B 0 connections */ }
@Test func httpsToHTTPHopFails() async { /* TLS server T redirects to http B; .httpsOnly → .schemeRefused */ }
@Test func schemeControlsSucceedWhenAdmitted() async throws {
    // control: .allowingHTTP([A, B]) for A→B, and .allowingHTTP([B]) for T→B, both return the document
}
```

  Every server-behaviour fixture here is also checked once with `bareFetch` (the 4-redirect chain already in Task 3).

- [ ] **Step 2: Run.** `swift test --filter RedirectAndSchemeTests`. Expected: the refusal tests fail (no limit, no scheme check).

- [ ] **Step 3: Implement the hop loop** in `intercept`, per §0.1 "One middleware" steps 2–3: for hop 0…3, check the scheme against `context.schemePolicy` (`.scheme`), rewrite base URL and path, call `next`; on a 3xx with a `Location`, drain and discard the body (collect at most 1_048_576 bytes; Task 7 moves this onto `CappedBody`), resolve `URL(string: location, relativeTo: hopURL)?.absoluteURL`, require scheme and host else `.invalidURI(location)`, and loop; a 4th redirect throws `.tooManyRedirects(url)` when `.redirectLimit` is on. With `.redirectLimit` off, follow up to 16 hops.

- [ ] **Step 4: Run.** Expected: PASS, every control green and every refusal red-then-green as above. Record outputs.

- [ ] **Step 5: Commit.** `git commit -m "feat: per-hop scheme check and redirect limit in the fetch middleware"`

---

### Task 6: Status and content type

**Files:**
- Modify: `RemoteFetch/RemoteFetchMiddleware.swift` (add `@_spi(Generated) import OpenAPIRuntime`)
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/StatusAndContentTypeTests.swift`

**Interfaces:**
- Produces: `static let declaredContentTypes: [OpenAPIMIMEType]` (the two Global Constraints values, parsed with `OpenAPIMIMEType(_:)`); `static func admitsContentType(_ raw: String?) -> Bool`.

- [ ] **Step 1: Write the failing tests.**

```swift
static let refusedConcrete = ["text/html", "text/html; charset=utf-8", "application/ld+json",
    #"application/ld+json; profile="https://www.w3.org/ns/activitystreams https://example.org/p""#]
static let nonConcrete: [String?] = [nil, "", "*/*", "text/*", "html", "*/html"]
static let accepted = ["application/activity+json; charset=utf-8",
    #"application/ld+json; profile="https://www.w3.org/ns/activitystreams""#]

@Test(arguments: refusedConcrete) func concreteUndeclaredRefusedByMiddleware(_ ct: String) async {
    // valid document, 200, Content-Type ct → .contentType(ct)
}
@Test(arguments: refusedConcrete) func concreteUndeclaredRefusedByGeneratedLayerWhenCheckOff(_ ct: String) async throws {
    // control: checks .all.subtracting(.contentType); bind RemoteFetchContext and call client.client.getObject()
    // directly; catch ClientError: #expect(error.response != nil); #expect(!(error.underlyingError is DecodingError))
    // and #expect(RemoteFetchError.from(error) is .generatedLayerRefused)
}
@Test(arguments: nonConcrete) func nonConcreteRefusedByMiddleware(_ ct: String?) async { /* → .contentType(ct) */ }
@Test(arguments: nonConcrete) func nonConcreteAcceptedWhenCheckOff(_ ct: String?) async throws {
    // control: checks .all.subtracting(.contentType) → document returned (the runtime picks options[0])
}
@Test(arguments: accepted) func declaredTypesPass(_ ct: String) async throws { /* document returned */ }
@Test func contentTypeTypeAndSubtypeAreCaseInsensitive() async throws { /* "Application/Activity+JSON" → document */ }
@Test(arguments: [404, 204]) func non200RefusedByMiddleware(_ code: Int) async {
    // valid document (404) / empty (204), Content-Type application/activity+json → .status(code)
}
@Test(arguments: [404, 204]) func non200UndocumentedWhenCheckOff(_ code: Int) async {
    // control: checks .all.subtracting(.status) → .generatedLayerRefused(underlying: UndocumentedStatusError)
    // with statusCode == code
}
```

  Fixture check: `bareFetch` on one refused and one non-concrete server shows the header as configured.

- [ ] **Step 2: Run.** Expected: middleware-refusal tests fail.

- [ ] **Step 3: Implement** §0.1 "One middleware" step 4 and "Content type and status": after the last hop, `.status` requires 200 else `.status(code)`; `.contentType` parses `response.headerFields[.contentType]` with `OpenAPIMIMEType(_:)`, requires `.concrete`, and matches a declared type: type and subtype case-insensitive, every declared parameter present with name compared case-insensitively and value case-sensitively (the runtime keeps the quotes in parameter values, so the declared `profile` value is compared with its quotes), extra received parameters ignored. Else `.contentType(raw)`.

- [ ] **Step 4: Run.** Expected: PASS. Record controls.

- [ ] **Step 5: Commit.** `git commit -m "feat: status and content-type checks in the fetch middleware"`

---

### Task 7: Body cap and deadline

**Files:**
- Modify: `RemoteFetch/RemoteFetchMiddleware.swift`
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/BodyAndDeadlineTests.swift` (`@Suite(.serialized)`: timing windows)

**Interfaces:**
- Produces: `static let maxBodyBytes = 1_048_576`; `struct CappedBody: AsyncSequence, Sendable` over `HTTPBody` chunks (`ArraySlice<UInt8>`), throwing `.bodyTooLarge` past `maxBodyBytes` (when `.bodyCap`) and `.deadlineExceeded` when a chunk arrives at or after the deadline (when `.deadline`); returned as `HTTPBody(capped, length: original.length, iterationBehavior: .single)`.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func oversizeBodyFails() async { /* Fixtures.padded(note, toAtLeast: 1_048_577) → .bodyTooLarge */ }
@Test func oversizeBodyReadInFullWithCapOff() async throws { /* control: .all.subtracting(.bodyCap) → document */ }
@Test func bodyAtExactlyOneMegabytePasses() async throws {
    // body of exactly 1_048_576 bytes → document; 1_048_577 → .bodyTooLarge
}
@Test func slowDripFailsAtDeadline() async {
    // .drip(every: .milliseconds(100), totalBytes: 50), deadline now+2s → .deadlineExceeded,
    // elapsed in 2s...2.5s
}
@Test func slowDripCompletesWithDeadlineOff() async throws {
    // control: .all.subtracting(.deadline) → completes (decode error is fine: the body is not JSON;
    // assert the error is .invalidDocument, not .deadlineExceeded or .transportFailed) after ≈5 s
}
@Test func stallFailsWithReadTimeout() async {
    // makeTestClient(…, adjust: { $0.timeout.read = .seconds(3) }), .stallAfterHead, deadline now+2s
    // → .transportFailed(underlying:) whose underlying is HTTPClientError.readTimeout, elapsed in 3s...3.5s
}
@Test func stallStillWaitingWithoutReadTimeout() async throws {
    // control: adjust { $0.timeout.read = nil }; start the fetch in a child task; at 10 s it has not
    // completed; call shutdown() inside withTestClient; assert it had not completed before shutdown
}
@Test func expiredDeadlineFailsBeforeConnecting() async {
    // deadline = .now - .seconds(1) → .deadlineExceeded, server connections == 0
}
@Test func slowHeadFailsAtDeadline() async {
    // .holdUntil(barrier never released) with deadline now+2s → .deadlineExceeded in 2s...2.5s
}
```

  Fixture checks with `bareFetch`: the drip sends 50 bytes over ≈5 s; the stall sends a head and no body bytes (bare call with a 1 s read timeout fails with `readTimeout`).

- [ ] **Step 2: Run.** Expected: refusal tests fail.

- [ ] **Step 3: Implement.** Before each hop: if `.deadline` and `ContinuousClock.now >= deadline`, throw `.deadlineExceeded` without calling `next`. Run `next` in a `withThrowingTaskGroup` raced against `Task.sleep(until: deadline, clock: .continuous)`; the first to finish wins, the group cancels the other; the sleep winning throws `.deadlineExceeded`. Wrap the final body in `CappedBody`; drain 3xx bodies through the same wrapper.

- [ ] **Step 4: Run.** Expected: PASS. Record the elapsed times.

- [ ] **Step 5: Commit.** `git commit -m "feat: body cap and per-fetch deadline in the fetch middleware"`

---

### Task 8: Typed documents

**Files:**
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/DocumentTests.swift`
- Modify (only if a test shows a mapping bug): `RemoteFetch/RemoteDocuments.swift`

**Interfaces:**
- Consumes: Task 4's mapping and documents.

- [ ] **Step 1: Write the tests.**

```swift
@Test(arguments: [#"{"a":"#,
    #"{"id":"https://x/a","type":"Person"}"#,                           // actor without inbox
    #"{"id":"https://x/a","type":"Person","inbox":5}"#])               // numeric inbox
func invalidActorDocument(_ body: String) async { /* getActor → .invalidDocument */ }
@Test func objectWithNumericAttributedToIsInvalid() async { /* → .invalidDocument */ }
@Test func validDocumentReturned() async throws { /* control: same responses with a valid document */ }

@Test func unknownFieldsAreTolerated() async throws {
    // Fixtures.actor with Mastodon's full field set plus 40 invented fields (strings, numbers,
    // nested objects, arrays): every declared field reads back
}
@Test func sameDocumentWithoutInboxFails() async { /* control → .invalidDocument */ }

@Test func valueOrArrayFormsAgree() async throws {
    // attributedTo: "u", {"id":"u"}, [{"id":"u"}] → "u"
    // to: "u", ["u"] → ["u"];   url: "w", {"href":"w"}, [{"href":"w"}] → "w"
    // publicKey: {…pem}, [{…pem}] → same publicKeyPem
}
@Test(arguments: ["attributedTo", "to", "url"]) func numericValueFails(_ field: String) async { /* → .invalidDocument */ }
@Test func numericPublicKeyFails() async { /* actor publicKey: 5 → .invalidDocument */ }
@Test func nullOptionalFieldReadsAsAbsent() async throws { /* "summary": null → summary == nil */ }
@Test func singleContentMapKeyIsTheLanguage() async throws { /* {"en":"…"} → "en"; two keys → nil */ }
```

- [ ] **Step 2: Run.** `swift test --filter DocumentTests`. Expected: PASS if Task 4's mapping is right; the controls prove the decode checks declared fields. Fix any mapping mismatch in `RemoteDocuments.swift` and re-run.

- [ ] **Step 3: Commit.** `git commit -m "test: typed remote documents, value-or-array and unknown fields"`

---

### Task 9: Request target and signing

**Files:**
- Modify: `Sources/ActivityPubCore/Crypto/HTTPSignature.swift` (add `signedGetHeaders`), `RemoteFetch/RemoteFetchMiddleware.swift`, `Sources/ActivityPubCore/Crypto/KeyManager.swift` (delete `actorDocumentRequest`, `:81-117`)
- Modify: `Tests/ActivityPubCoreTests/SignedFetchTests.swift` (move from `actorDocumentRequest` to `signedGetHeaders`)
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/SigningAndTargetTests.swift`

**Interfaces:**
- Produces: `extension HTTPSignature { static func signedGetHeaders(url: URL, signer: FetchSigningKey, date: Date = Date()) throws -> [String: String] }`: path = `percentEncodedPath` (`/` if empty) + `?query`, host = `host[:port]`, then `signGet(privateKeyPem:keyId:path:host:date:)` (`HTTPSignature.swift:172-200`); throws `RemoteFetchError.invalidURI` for a URL without a host.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func requestTargetReachesServerByteForByte() async throws {
    // uri A + "/users/al%20ice?x=1&y=%2F" → A.stats.requests[0].target == "/users/al%20ice?x=1&y=%2F"
}
@Test func plainPathTemplateDoesNotPreserveTarget() async throws {
    // control: .all.subtracting(.verbatimRequestTarget): the middleware sets the path with
    // Converter(configuration: .init()).renderedPath(template: "/{}", parameters: [pathAndQuery]),
    // what a "/{path}" template produces → recorded target != the URI's
}
@Test func pathStartingWithDoubleSlashStaysOnTheURIHost() async throws {
    // uri A + "//other/x" → A records 1 request; nothing else is contacted
}
@Test func signedFetchVerifies() async throws {
    // signer = FetchSigningKey(test RSA key); uri with query; recorded headers: signature params
    // headers == "(request-target) host date"; HTTPSignature.verify(method: "get",
    // path: recorded.target, headers: recorded.headers, body: Data(), publicKeyPem:) == true
}
@Test func redirectedFetchIsSignedAgainForTheSecondHop() async throws {
    // A 302 → B "/b?q=1": B's recorded Signature verifies for "/b?q=1" with B's host:port
}
@Test func unsignedCallCarriesNoSignature() async throws { /* control: signer nil → no "signature" header */ }
@Test func signatureFailsForPathWithoutQuery() async throws { /* control: verify with path minus query == false */ }
@Test func reusedFirstHopHeadersFailOnSecondHop() async throws {
    // control: .all.subtracting(.resignEachHop) → B's Signature does not verify for B's target
}
```

- [ ] **Step 2: Run.** Expected: fail (no signing in the middleware).

- [ ] **Step 3: Implement.** In each hop, with `context.signer`, add the `signedGetHeaders` output to `request.headerFields` (`HTTPField.Name("Signature")!`, `"Date"`, `"Host"`), replacing any from the previous hop; AHC keeps a `Host` header already present (`RequestValidation.swift` `addHostIfNeeded`, AHC 1.33.1). With `.resignEachHop` off, reuse hop 0's headers. With `.verbatimRequestTarget` off, use the `renderedPath` form above.

- [ ] **Step 4: Run** the new tests and `SignedFetchTests`. Expected: PASS.

- [ ] **Step 5: Commit.** `git commit -m "feat: sign every hop of a remote fetch"`

---

### Task 10: Connection-level address check

**Files:**
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/ConnectionTests.swift` (`@Suite(.serialized)`)
- Modify (only on a failing test): `RemoteFetch/RemoteFetchClient.swift`

**Interfaces:**
- Consumes: `RemoteFetchClient.make(…, closesRefusedChannel:, adjust:)`, `TestServer` with `TestTLS`.

- [ ] **Step 1: Write the tests.** Every fetch here passes `schemePolicy: .allowingHTTP(ports: [A, C])`, so the scheme check admits the hop and only the address policy (`.loopbackPorts([A])`, or `[A, T]` with a TLS server T) can refuse it.

```swift
@Test func redirectToRefusedPortFailsWithAddressError() async {
    // client admits [A]; A 302 → http://127.0.0.1:C → .addressRefused; C: connections == 1, bytes == 0, closes == 1
}
@Test func withoutHookRequestReachesRefusedPort() async throws {
    // control: adjust { $0.http1_1ConnectionDebugInitializer = nil } → C.stats.bytes > 0
}
@Test func refusedTLSPeerSeesHandshakeButNoHTTP() async {
    // C is a TLS server: C.tlsHandshakes == 1, C.bytes == 0, C.closes == 1, fetch → .addressRefused
}
@Test func withoutHookTLSRequestReachesRefusedPort() async throws { /* control: C.bytes > 0 */ }
@Test func hookWithoutCloseLeavesConnectionOpen() async {
    // control for "closes == 1": closesRefusedChannel: false → after 300 ms settle, C.closes == 0
}
@Test func refusedAddressGetsExactlyOneConnection() async { /* C.connections == 1 */ }
@Test func retriesOnReconnectRefusedAddress() async {
    // control: adjust { $0.connectionPool.retryConnectionEstablishment = true }, deadline now+2s
    // → C.connections > 1
}
@Test func http2CapableRefusedPeerIsRefused() async {
    // C: TLS, alpn ["h2", "http/1.1"], http2: true, port not admitted → .addressRefused, C.bytes == 0
}
@Test func automaticHTTPVersionNegotiatesH2AndBypassesHook() async throws {
    // control: adjust { $0.httpVersion = .automatic } → C answered the request over h2 (C.requests.count == 1)
}
@Test func testClientTrustsTestCA() async throws { /* TLS server admitted → document */ }
@Test func systemTrustStoreRefusesTestCA() async throws {
    // control: adjust { $0.tlsConfiguration = .makeClientConfiguration() } (system roots); bind the context and
    // call client.client.getObject(); the ClientError has response == nil, and RemoteFetchError.from(error)
    // is .transportFailed
}
```

- [ ] **Step 2: Run.** `swift test --filter ConnectionTests`. Expected: PASS with Task 4's hook; each control green showing the setting matters. If a production-side test fails, fix `make` and re-run. Record every server count.

- [ ] **Step 3: Commit.** `git commit -m "test: connection hook, close, retries, HTTP/1.1 and trust"`

---

### Task 11: One client, concurrent fetches

**Files:**
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/ConcurrencyTests.swift`

**Interfaces:**
- Consumes: `makeTestClient(…, middleware:)`, `TestResponse.holdUntil`.
- Produces (test target): `final class StoredTargetMiddleware: ClientMiddleware`, which stores `RemoteFetchContext.current` in a `Mutex` property on entry, awaits a `TestBarrier`, then re-binds the stored context and calls `RemoteFetchMiddleware().intercept`.

- [ ] **Step 1: Write the tests.**

```swift
@Test func concurrentFetchesReachTheirOwnServers() async throws {
    // A holds its response until B has recorded a request; async let a = fetch(A), b = fetch(B)
    // → each document's id is its own server's; A and B each recorded 1 request
}
@Test func storedTargetMiddlewareMisroutes() async throws {
    // control: StoredTargetMiddleware → one server records 2 requests, the other 0
}
@Test func unboundFetchThrowsBeforeConnecting() async { /* Task 4's noContext test, repeated with both servers: 0 connections */ }
```

- [ ] **Step 2: Run.** Expected: PASS; the control misroutes. This is the measurement for spec "Unverified → TaskLocal isolation on one client".

- [ ] **Step 3: Commit.** `git commit -m "test: per-task fetch context on one shared client"`

---

### Task 12: `ActorKeyCache`

**Files:**
- Create: `Sources/ActivityPubCore/Crypto/ActorKeyCache.swift`
- Test: `Tests/ActivityPubCoreTests/ActorKeyCacheTests.swift`

**Interfaces:**
- Produces: `public final class ActorKeyCache: Sendable { public init(loader: @escaping @Sendable (String) async throws -> String); public func signingKey(for username: String) async throws -> String }` (returns the private key PEM). Stored: `Mutex<[String: String]>` (`import Synchronization`) and the loader.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func loadsOncePerUsername() async throws {
    // counting loader; signingKey(for: "a") twice → loader called once for "a"; "b" → once more
}
@Test func loaderErrorIsNotCached() async {
    // loader throws on first call, succeeds after → first throws, second returns the key
}
@Test func concurrentMissesBothLoadAndAgree() async throws {
    // two concurrent misses for "a" → both return the same PEM; loader called 1 or 2 times
}
```

  Control for `loadsOncePerUsername`: a cache whose store step is removed (locally, not committed) calls the loader twice. Record it.

- [ ] **Step 2: Run** → compile failure. **Step 3: Implement** per §0.1 "Signing keys: `ActorKeyCache`": read inside `withLock`; on a miss, await the loader outside the lock, then store inside a second `withLock`; no lock across an `await`; never invalidated. **Step 4: Run** → PASS.

- [ ] **Step 5: Commit.** `git commit -m "feat: ActorKeyCache for per-container signing keys"`

---

### Task 13: `KeyManager` and `InboxHandler`

**Files:**
- Modify: `Sources/ActivityPubCore/Crypto/KeyManager.swift:27-207`, `Sources/InboxHandler/main.swift:62-90,165-169,197-201,519-528,1731-1739`
- Delete: `Tests/ActivityPubCoreTests/RemoteFetch/LegacyFetchControlTests.swift`
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/KeyFetchTests.swift`

**Interfaces:**
- Consumes: `fetchRemoteActor` internal overload, `RemoteFetchClient`, `ActorKeyCache`.
- Produces: `KeyManager { let client: RemoteFetchClient; public init(); init(client: RemoteFetchClient); public func getPublicKey(keyId:store:signingKey:deadline: ContinuousClock.Instant) async throws -> String; public func refreshKey(keyId:store:signingKey:deadline:) async throws -> String; func fetchActorDocument(actorUri: String, signingKey: FetchSigningKey?, deadline: ContinuousClock.Instant) async throws -> RemoteActor }`. `KeyManagerError` keeps `invalidActorUri` and `missingPublicKey`; `fetchFailed`, `invalidJSON`, `missingInbox` are removed.

- [ ] **Step 1: Write the failing tests** (replacing Task 3's legacy control file, whose recorded output is the control):

```swift
@Test func keyFetchReturnsKey() async throws {
    // KeyManager(client: makeTestClient(admitting: [A])) .fetchActorDocument(actorUri: A/a, signingKey: nil,
    // deadline: .now + .seconds(10)) — schemePolicy for http test ports comes from an internal
    // fetchActorDocument(…, schemePolicy:) overload → publicKeyPem, inbox, sharedInbox, preferredUsername
}
@Test func keyFetchFourRedirectsFails() async { /* → RemoteFetchError.tooManyRedirects */ }
@Test func keyFetchOversizeFails() async { /* → RemoteFetchError.bodyTooLarge */ }
@Test func actorWithoutPublicKeyFails() async { /* → KeyManagerError.missingPublicKey */ }
```

  `fetchActorDocument` gets an internal overload with `schemePolicy:` (default `.httpsOnly`) so tests can reach `http` test ports, as `fetchRemoteActor` does.

- [ ] **Step 2: Run** → compile failure (signatures).

- [ ] **Step 3: Implement `KeyManager`.** `fetchActorDocument` calls `fetchRemoteActor(uri:signer:deadline:schemePolicy:client: self.client)` and builds `RemoteActor(actorUri:publicKeyPem:preferredUsername:inbox:sharedInbox:fetchedAt:)`; throws `missingPublicKey` when `publicKeyPem` is `nil`; lets `RemoteFetchError` through unchanged. Delete the hand parser (`:139-155`) and the `FoundationNetworking` import. `getPublicKey`/`refreshKey` pass `deadline` through.

- [ ] **Step 4: Implement `InboxHandler`.** Replace `nonisolated(unsafe) var cachedActorKeys` (`:66`) with `let actorKeys = ActorKeyCache { username in … }`, whose loader is today's SSM read (`:80-87`) and throws `InboxError.missingActorKey`; `fetchSigningKey(for:)` builds `FetchSigningKey(keyId:privateKeyPem: try await actorKeys.signingKey(for: username))`. Pass `deadline: .now + .seconds(10)` at `:165`, `:197`, `:522`. At `:1734`, replace `fetchRemoteObject(uri: actorUri)` and `["inbox"] as? String` with `try await fetchRemoteActor(uri: actorUri, signer: try await fetchSigningKey(for: username), deadline: .now + .seconds(10)).inbox`, inside the existing `do/catch`.

- [ ] **Step 5: Run** `swift test --filter "KeyFetchTests|SignedFetchTests"` and `swift build --product InboxHandler`. Expected: PASS, builds.

- [ ] **Step 6: Commit.** `git commit -m "feat: key fetches and QuoteRequest lookups through the hardened client"`

---

### Task 14: `PostHandler` quote path, legacy removal, docs

**Files:**
- Modify: `Sources/PostHandler/main.swift:36-60,262-280`, `Sources/ActivityPubCore/FetchRemoteObject.swift` (delete the legacy `fetchRemoteObject(uri:)` and `FetchRemoteObjectError`, `:14-58`), `Sources/ActivityPubCore/Documentation.docc/ActivityPubCore.md:64-75`, `AuthenticationOverview.md:13`

**Interfaces:**
- Consumes: `fetchRemoteObject(uri:signer:deadline:)`, `fetchRemoteActor(uri:signer:deadline:)`, `ActorKeyCache`.

- [ ] **Step 1: Implement `PostHandler`.** Add `let actorKeys = ActorKeyCache { username in … }` reading SSM `"\(ssmKeyPrefix)/\(username)"` (PostFunction already reads `activity/${Stage}/*`, `activity-app/functions/template.yaml:134-135`). Inside the existing `do` at `:263`: `let signer = FetchSigningKey(keyId: "https://\(serverDomain)/users/\(username)#main-key", privateKeyPem: try await actorKeys.signingKey(for: username))`; `fetchRemoteObject(uri: quotedId, signer: signer, deadline: .now + .seconds(10)).attributedTo`; on a `REMOTE_ACTOR#` miss, `fetchRemoteActor(uri: attributedTo, signer: signer, deadline: .now + .seconds(10)).inbox`. The `failed` path (`:284-287`) is unchanged.

- [ ] **Step 2: Remove the legacy fetch.** Delete the legacy function and error. `grep -rn "FetchRemoteObjectError\|URLSession" Sources/ActivityPubCore` → no hits.

- [ ] **Step 3: Docs.** Under "Authentication and Cryptography" add `ActorKeyCache`; add a "Remote Fetch" topic group with `fetchRemoteObject(uri:signer:deadline:)`, `fetchRemoteActor(uri:signer:deadline:)`, `RemoteObjectDocument`, `RemoteActorDocument`, `RemoteFetchError`. In `AuthenticationOverview.md:13`, say key documents are fetched through the hardened client and refused with `RemoteFetchError` or `KeyManagerError.missingPublicKey`.

- [ ] **Step 4: Run.** CI Test job (`swift test --filter ActivityPubCoreTests`, `.github/workflows/test.yml:65`). Expected: green on Linux.

- [ ] **Step 5: Commit.** `git commit -m "feat: signed, hardened quote-path fetches; drop the URLSession fetch"`

---

### Task 15: Lambda build (C4) and the implementation PR

**Files:** none in the repository except a throwaway commit (Step 2), reverted.

- [ ] **Step 1: C4, build half, before merge.** Mark the PR ready and add the `lambda-build` label. Expected: the Lambda Build job is green: `scripts/build-all-lambdas.sh` compiles every product in `swift-al2023:6.3` against the committed pins, "Package.resolved unchanged by the build" passes, and `scripts/verify-lambda-zips.sh` passes. This is the first AL2023 build that compiles and links AsyncHTTPClient into the handlers.

- [ ] **Step 2: Control for Step 1.** Push one commit that adds `config.notARealSetting = true` to `RemoteFetchClient.make`, re-add the `lambda-build` label, and see the job go red at the build phase with that line in the error. Revert with a new commit and re-run until green. This shows the job compiles the AHC-using file in the deploy image. Record both run URLs.

- [ ] **Step 3: PR description.** Include: the Task 1 version table; every negative control's observed output (Tasks 2–13), the construction control's run URL (Task 4) and both Lambda Build run URLs; "Refs FederatedActivityPublisher#280" and "Refs FederatedActivityPublisher#292" (no closing keywords; #280 closes only after Step 5); and draft release notes naming every behaviour change in §0.3 of the spec (quote path refusals and signing; inbound key fetch checks and the absolute deadline; typed documents with both consequences; no connection retries).

- [ ] **Step 4: Review.** Request review per the repository's process. Do not merge without it.

- [ ] **Step 5: C4, runtime half, after merge.** The `deploy-stage` run for the merge commit builds and deploys every handler. Pass: on stage, an inbound delivery signed by an actor not cached in `REMOTE_ACTOR#` (for example a first Follow from a remote account) verifies; that key fetch ran on AHC in the deployed binary. Fail: a handler fails to start, or that key fetch fails with `transportFailed`. Fix forward. No prod release containing step 0 is cut until this has passed (spec, §0.2 "Release").
