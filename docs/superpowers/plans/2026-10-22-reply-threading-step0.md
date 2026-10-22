# Reply Threading Step 0 (Fetch Hardening) Implementation Plan

**Goal:** Every remote `GET` goes through one long-lived, generated OpenAPI client on `AsyncHTTPClientTransport`. FAP's per-hop controls live in one `ClientMiddleware`, Mastodon's private-address check runs on every connection, actor and object documents are typed, fetches are signed, and signing keys come from an `ActorKeyCache`.

**Architecture:** A FAP-authored OpenAPI document inside `ActivityPubCore` generates an `internal` client. Each Lambda container has one `RemoteFetchClient.shared`. It holds that client, an `HTTPClient` configured as in §0.2 of the spec, and `RemoteFetchMiddleware`. The `HTTPClient` settings are:
- the connection hook;
- no connection retries;
- HTTP/1.1 only;
- no proxy;
- no redirects;
- connect and read timeouts.

The middleware rewrites the placeholder origin to each hop and applies these controls:
- scheme;
- redirect limit;
- signing;
- deadline;
- status;
- content type;
- body size.

`fetchRemoteObject` and `fetchRemoteActor` bind a `@TaskLocal` context for each call and map the generated types to two public structs.

**Tech Stack:** Swift 6.3, swift-openapi-generator and swift-openapi-runtime, swift-openapi-async-http-client, async-http-client, swift-http-types, SwiftNIO (`NIOCore` in production; `NIOPosix`, `NIOSSL`, `NIOHTTP2` in tests), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-20-reply-threading-design.md`. The relevant parts are:
- "Step 0 — Fetch hardening (security)" (§0.1–§0.3);
- "Testing → Unit → Step 0";
- "Build gate";
- "Unverified";
- "Guards and fallbacks";
- decisions 14–17.

Decisions 1–17 in the spec are settled, and this plan does not reopen them. Where the plan and the spec differ, "Changes since the spec" explains why.

## Global Constraints

- **Toolchain.** Swift tools and toolchain 6.3 (`Package.swift:1`). The platform floor is `.macOS(.v15)` (`Package.swift:7`).
- **New package entries.**
  - `swift-server/swift-openapi-async-http-client` `from: "1.5.0"`
  - `swift-server/async-http-client` `from: "1.33.1"`
  - `apple/swift-nio` `from: "2.97.1"`
  - `apple/swift-nio-ssl` `from: "2.36.1"`
  - `apple/swift-nio-http2` `from: "1.42.0"`
  - `apple/swift-http-types` `from: "1.8.0"`, the version `Package.resolved` pins at `6d02908`. It is resolved today only through other packages; `Package.swift` has no root entry for it.
- **Raised floors.** `swift-openapi-generator` `from: "1.11.1"` and `swift-openapi-runtime` `from: "1.11.0"`. Today they are `1.6.0` and `1.7.0` (`Package.swift:36-37`).
- **Products on `ActivityPubCore`.** `AsyncHTTPClient`, `OpenAPIRuntime`, `OpenAPIAsyncHTTPClient`, `NIOCore` (package `swift-nio`) and `HTTPTypes` (package `swift-http-types`). Each source file that uses `NIOCore` or `HTTPTypes` imports it explicitly.
- **Test-only products.** `NIOPosix`, `NIOSSL` and `NIOHTTP2` are products of `ActivityPubCoreTests` only. No production target names them (decision 16 in the spec).
- **Pins.** `Package.resolved` is regenerated only by the Resolve Packages workflow (the `resolve-packages` label), never with a local toolchain (`AGENTS.md:271`).
- **Placeholder origin.** `https://remote-fetch.invalid` is written once, in the document's `servers:`. It never appears as a literal in Swift.
- **Deadlines.** Each fetch at a non-search call site gets `.now + .seconds(10)` (a `ContinuousClock.Instant`), computed when that fetch is called.
- **Timeouts.** The transport `timeout` is 10 s. `HTTPClient` uses `timeout.connect = .seconds(5)` and `timeout.read = .seconds(10)`.
- **Redirects.** At most 3 hops.
- **Body cap.** 1 MB, which is `1_048_576` bytes. This is Mastodon's `body_with_limit(limit = 1.megabyte)` (`app/lib/request.rb` at `2c540e4`). A body of exactly 1_048_576 bytes passes, and one byte more fails.
- **Declared content types.** Exactly `application/activity+json` and `application/ld+json; profile="https://www.w3.org/ns/activitystreams"`.
- **Status.** Only 200 succeeds.
- **Request target.** The request target reaches the server byte for byte, a path that starts with `//` included. The Task 9 tests measure this; it is not assumed.
- **Access.** The generated client is `internal`. The public surface this step adds is:
  - `fetchRemoteObject(uri:signer:deadline:)`
  - `fetchRemoteActor(uri:signer:deadline:)`
  - `RemoteObjectDocument`
  - `RemoteActorDocument`
  - `RemoteFetchError`
  - `ActorKeyCache`
- **Test clients.** Every `HTTPClient` and `RemoteFetchClient` a test builds runs inside `withTestClient(_:body:)`. Tests stop their servers before they return. A server left open by a failed assertion only holds a loopback port until the test process exits.
- **Negative controls.** Each test names its negative control, and counts only after that control has been seen red. The implementation PR description records what each control showed.
- **Commit messages.** Short and about the code, ending with the `Co-Authored-By:` trailer the repository's other commits use.

## Changes since the spec

These changes follow from the repository at `6d02908` (current `main`). None of them is a design change.

1. **Pinned dependencies.**
   - **What the spec says.** `Package.resolved` is gitignored (§0.2, "Versions behind the line references").
   - **What changed.** Since FederatedActivityPublisher#289 the file is committed. Every build resolves with `--force-resolved-versions` (`scripts/build-all-lambdas.sh:37`). `scripts/resolve-packages.sh` regenerates the file from scratch (`rm -f Package.resolved`, then `swift package resolve`), so any pin can move.
   - **What it means for the PR.** The implementation PR commits a regenerated file and lists every pin that changed (Task 1).
   - **Pins at `6d02908`.** They are already newer than the versions the spec's line references were read at:
     - `async-http-client` 1.36.2
     - `swift-openapi-runtime` 1.13.3
     - `swift-openapi-generator` 1.14.2
     - `swift-nio` 2.104.0
     - `swift-nio-ssl` 2.37.5
     - `swift-nio-http2` 1.46.0
     - `swift-http-types` 1.8.0
   - **AHC 1.36.2 `HTTPClient.swift` still declares:**
     - `http1_1ConnectionDebugInitializer`
     - `connectionPool.retryConnectionEstablishment` (default `true`)
     - `httpVersion` and `.http1Only`
     - `proxy`
     - `redirectConfiguration` and `.disallow`
     - `timeout.connect` and `timeout.read`
     - `HTTPClientError.readTimeout`
     - the debug `deinit` precondition
   - **Runtime 1.13.3 `Base/OpenAPIMIMEType.swift` still declares:**
     - `@_spi(Generated) public struct OpenAPIMIMEType`
     - `Kind.concrete`
     - `public var parameters`
     - an `internal` `static func evaluate(`
   - **The rest.** Task 1 re-checks every other cited line.
2. **The Lambda build.**
   - **What the spec says.** C4 names `swift package … docker archive`.
   - **What changed.** The build is now `scripts/build-all-lambdas.sh`, and the `lambda-build` label runs it on a PR (`.github/workflows/lambda-build.yml:58-65`).
   - **What it means for the PR.** C4's build half moves before merge (Task 15). Its runtime half stays on stage after merge.
   - **The control.** The build links with `-Xlinker -s` (`scripts/build-all-lambdas.sh:106`), so FederatedActivityPublisher#283's `nm` count cannot be repeated. Task 15's control is a deliberate compile break instead.
3. **TLS fixtures.**
   - **Why they are Swift literals.** `.gitignore:25-26` ignores `*.pem` and `*.key`, and no FAP target uses SwiftPM resources. So the CA certificate, the leaf certificate and the leaf private key are string literals in `TestOnlyTLS.swift`.
   - **The keys.** The CA's private key is deleted as soon as it has signed the leaf, so nothing else can ever be issued under the test CA. The leaf is limited to `IP:127.0.0.1, DNS:localhost`. Its key constant is named `loopbackLeafPrivateKeyPEM_testOnly`.
4. **NIOCore in `ActivityPubCore`.** Settled 2026-10-22: production code declares NIOCore and HTTPTypes explicitly.
   - **Why it is needed.** The connection hook uses NIOCore API: `Channel.remoteAddress`, `SocketAddress.ipAddress`, `SocketAddress.port`, `Channel.close(promise:)`, `EventLoop.makeFailedFuture(_:)` and `makeSucceededVoidFuture()`.
   - **What it means for the PR.** `ActivityPubCore` declares `.product(name: "NIOCore", package: "swift-nio")`, and `RemoteFetchClient.swift` has `import NIOCore`. The hook doesn't rely on transitive member visibility (SE-0444).
   - **Relation to the spec.** This extends decision 16 in the spec, which approved the NIO products for the test target only. `NIOPosix`, `NIOSSL` and `NIOHTTP2` stay test-only.
   - **What it adds to the build.** Nothing: `NIOCore` is already resolved and linked through `async-http-client`.
5. **HTTPTypes in `ActivityPubCore`.** Part of the same settled point.
   - **Why it is needed.** `RemoteFetchMiddleware` names `HTTPRequest`, `HTTPResponse` and `HTTPField`.
   - **What it means for the PR.** `ActivityPubCore` declares `.product(name: "HTTPTypes", package: "swift-http-types")`, and the middleware's file has `import HTTPTypes`.
   - **The package entry.** `Package.swift` has no root entry for `swift-http-types` at `6d02908`, where it is resolved only through `swift-openapi-runtime` and the transport. Task 1 adds one at `from: "1.8.0"`, the version pinned at `6d02908`.
   - **Generated code.** Its own `import HTTPTypes` is covered by the same declaration.
6. **Line numbers.** The spec's FAP line references are at `8a78008`. This plan cites `6d02908`. For example:
   - `KeyManager` is at `Sources/ActivityPubCore/Crypto/KeyManager.swift:27`.
   - `let keyManager = KeyManager()` is at `Sources/InboxHandler/main.swift:62`.
   - The QuoteRequest actor lookup is at `:1734`.
7. **`actorDocumentRequest`.**
   - **What happens to it.** FederatedActivityPublisher#279's `KeyManager.actorDocumentRequest(url:signingKey:date:)` (`KeyManager.swift:85-117`) builds a `URLRequest`, and nothing sends one after step 0. Its path and query and its `host[:port]` derivation move to `HTTPSignature.signedGetHeaders(url:signer:date:)`. `SignedFetchTests` move to that function (Task 9).
   - **What kept the `Accept` header.** The deleted code also set `Accept: application/activity+json`. The generated client now sends `Accept` from the declared response types, and Task 4 asserts it.
   - **`KeyManagerError.invalidActorUri`.** The spec doesn't mention it, and it is kept.
8. **`contentMap`.** "No schema sets `additionalProperties`" (§0.1) is about the object schemas, so that unknown fields are tolerated. `contentMap` is "an object whose values are strings", which is written `additionalProperties: {type: string}`. No schema uses `additionalProperties: false`.
9. **The request target and the transport.**
   - **The transport code.** `AsyncHTTPClientTransport.convertRequest` (swift-openapi-async-http-client 1.5.0, `Sources/OpenAPIAsyncHTTPClient/AsyncHTTPClientTransport.swift`) does this:
     - `guard var baseUrlComponents = URLComponents(string: baseURL.absoluteString),`
     - `let requestUrlComponents = URLComponents(string: request.path ?? "")`
     - `baseUrlComponents.percentEncodedPath += requestUrlComponents.percentEncodedPath`
     - `baseUrlComponents.percentEncodedQuery = requestUrlComponents.percentEncodedQuery`
   - **The problem.** A request path of `//other/x` would parse as authority `other` and path `/x`.
   - **The fix.** The middleware puts the hop's origin and path in `baseURL`, where `//other/x` follows an authority and stays a path. It passes only `?query`, or `""`, as `request.path`.
   - **What AHC does next.** It derives the target from the URL as `percentEncodedPath` plus `"?" + query` (`HTTPHandler.swift:861-877` and `DeconstructedURL.swift:45-69`, AHC 1.33.1).
   - **How it is checked.** Task 1 re-checks both files at the pinned versions, and the Task 9 tests measure the byte-for-byte result.
   - **Receipts.** The quoted lines come from a read of the file at tag 1.5.0. That package is not in any local checkout until Task 1 resolves it, so no line numbers are given.
10. **`withoutActuallyEscaping`.** `ClientMiddleware.intercept` receives `next` as a non-escaping `@Sendable` closure (`Interface/ClientTransport.swift:224-230`, runtime 1.11.0). The deadline race runs `next` in a task group, so it uses `withoutActuallyEscaping(next)`. The group finishes before `intercept` returns, so the closure never outlives the call.

## Known limitations

- **TLS handshake detection.** The test server recognises a completed handshake from the event's description (`handshakeCompleted…`). `TLSUserEvent` is in `NIOTLS`, which `NIOSSL` imports without re-exporting. Adding the `NIOTLS` product needs a dependency decision this plan does not take.
- **The h2 test server.** For the same reason, the h2 test server sets up HTTP/2 after TLS whatever ALPN negotiated. It does not follow the negotiated protocol. This doesn't matter for its two tests: in the refusal test no HTTP bytes arrive, and in the control the client negotiates `h2`.
- **The PostHandler key prefix.** `PostHandler` falls back to the stage `SSM_KEY_PREFIX` when the variable is unset (`PostHandler/main.swift:33`). After Task 14 that prefix is also where quote-fetch signing keys come from. This is tracked in FederatedActivityPublisher#295 and is not changed here.

## Review Focus

These inputs follow from the spec, but no test the spec lists exercises them. The most likely to occur comes first. Each one has a test in the task that owns the code.

1. **A 3xx without `Location`.** Expected: it is not followed, and the fetch fails with the status error. Test: Task 5, `redirectWithoutLocationFailsWithStatus`.
2. **A body of exactly 1 MB.** Expected: it decodes, and one byte more fails with the size error. Test: Task 7, `bodyAtExactlyOneMegabytePasses`.
3. **A mixed-case content type.** Expected: it is accepted. Test: Task 6, `contentTypeTypeAndSubtypeAreCaseInsensitive`.
4. **A deadline that has already passed.** Expected: the deadline error, with 0 connections. Test: Task 7, `expiredDeadlineFailsBeforeConnecting`.
5. **A path that starts with `//`.** Expected: the server named in the URI receives the target `//other/x`, and no other host is contacted. Test: Task 9, `pathStartingWithDoubleSlashIsSentVerbatim`.

---

## File structure

| File | Responsibility |
|---|---|
| `Package.swift`, `Package.resolved` | Dependencies, floors, products, generator plugin |
| `Sources/ActivityPubCore/openapi.yaml`, `openapi-generator-config.yaml` | Remote-fetch document and generator config |
| `Sources/ActivityPubCore/RemoteFetch/RemoteFetchError.swift` | `RemoteFetchError`, `UndocumentedStatusError`, the mapping order |
| `Sources/ActivityPubCore/RemoteFetch/RemoteFetchContext.swift` | `RemoteFetchContext` (`@TaskLocal`), `SchemePolicy` |
| `Sources/ActivityPubCore/RemoteFetch/PrivateAddressCheck.swift` | Address classifier, `AddressPolicy` |
| `Sources/ActivityPubCore/RemoteFetch/RemoteFetchMiddleware.swift` | `RemoteFetchChecks`, `RemoteFetchMiddleware`, `CappedBody` |
| `Sources/ActivityPubCore/RemoteFetch/RemoteFetchClient.swift` | Client construction, `shared`, `shutdown()` |
| `Sources/ActivityPubCore/RemoteFetch/RemoteDocuments.swift` | `RemoteObjectDocument`, `RemoteActorDocument`, mapping |
| `Sources/ActivityPubCore/FetchRemoteObject.swift` | `fetchRemoteObject`, `fetchRemoteActor` |
| `Sources/ActivityPubCore/Crypto/ActorKeyCache.swift` | Private-key cache for each container |
| `Sources/ActivityPubCore/Crypto/KeyManager.swift`, `HTTPSignature.swift` | Stored client, `fetchActorDocument` on `fetchRemoteActor`, `signedGetHeaders` |
| `Sources/InboxHandler/main.swift`, `Sources/PostHandler/main.swift` | Call sites |
| `Tests/ActivityPubCoreTests/RemoteFetch/TestServer.swift` | NIO test servers and `TestBarrier` |
| `Tests/ActivityPubCoreTests/RemoteFetch/TestOnlyTLS.swift` | CA and leaf certificates, and the leaf key, as literals |
| `Tests/ActivityPubCoreTests/RemoteFetch/TestSupport.swift` | Clients, fetch helpers, error helpers, fixtures |
| `Tests/ActivityPubCoreTests/RemoteFetch/*Tests.swift` | One file for each task below |

---

### Task 1: Dependencies and pinned versions

**Files:**
- Modify: `Package.swift:30-43` (package entries), `:46-57` (`ActivityPubCore`), `:252-260` (`ActivityPubCoreTests`)
- Modify: `Package.resolved` (taken from the workflow artifact)

**Interfaces:**
- Produces these products:
  - **`ActivityPubCore`:** `AsyncHTTPClient`, `OpenAPIRuntime`, `OpenAPIAsyncHTTPClient`, `NIOCore`, `HTTPTypes`.
  - **`ActivityPubCoreTests`:** `AsyncHTTPClient`, `OpenAPIRuntime`, `HTTPTypes`, `NIOCore`, `NIOPosix`, `NIOSSL`, `NIOHTTP2`.

- [ ] **Step 1: Branch.** Run `git switch -c feat/fetch-hardening origin/main`.

- [ ] **Step 2: Edit `Package.swift`.**
  - Raise the two floors and add the six package entries (Global Constraints), including `.package(url: "https://github.com/apple/swift-http-types", from: "1.8.0")`.
  - Add the products listed under Interfaces.
  - Leave the generator plugin out for now: it fails while the target has no document (Task 4).

- [ ] **Step 3: Regenerate the pins.**
  1. Push, open the implementation PR as a draft, and add the `resolve-packages` label.
  2. When the run finishes, run `gh run download <run-id> -n Package.resolved`.
  3. Commit the file.
  4. Run `git diff origin/main -- Package.resolved` and write a table with one row per pin: identity, old version, new version.
  - **Expected:** one new pin, `swift-openapi-async-http-client` at `1.5.0` or later. Each new entry's pin is at or above its floor, and no pin is removed.
  - **Other pins can move,** because the script resolves from scratch. List every moved pin in the PR description. A moved pin is not a reason to stop, but every one is listed.

- [ ] **Step 4: Re-check the cited lines.** For every third-party file:line in this plan, and every one cited in §0.1, §0.2 or the Testing section of the spec, read the file at the pinned tag. Read it read-only, from `https://raw.githubusercontent.com/<org>/<repo>/<tag>/<path>`.
  - **This includes:**
    - runtime `Base/OpenAPIMIMEType.swift`: `init?(_:)`, `==` (`:87-88`) and `evaluate` (`:206-251`, the `Dictionary(uniqueKeysWithValues:)` at `:239`);
    - runtime `Conversion/Converter+Common.swift:25-76`, `Conversion/ServerVariable.swift:29-43`, `Conversion/URLExtensions.swift:33-36`, `Conversion/Converter+Client.swift:42` and `Interface/ClientTransport.swift:224-230`;
    - AHC `HTTPClient.swift:1334-1343`, `HTTPHandler.swift:861-877`, `DeconstructedURL.swift:45-69` and `RequestValidation.swift:166-179`;
    - the transport's `convertRequest`;
    - the NIO, NIOSSL and NIOHTTP2 symbols listed under Task 3, Step 2;
    - generator `Translator/CommonTypes/Constants.swift:27`.
  - Add a table to the PR description: `cited | pinned tag | holds (yes/no, new line)`.
  - If any cited behaviour no longer holds, stop and report it. The exception is `evaluate`: if its trap is gone at the pinned version, record that, and keep Task 6's refusal anyway.

- [ ] **Step 5: CI.** The Test job on the pushed commit. **Expected:** green.

- [ ] **Step 6: Commit.** Run `git add Package.swift Package.resolved && git commit -m "build: add AsyncHTTPClient transport and NIO test dependencies"`.

---

### Task 2: Private-address classifier

**Files:**
- Create: `Sources/ActivityPubCore/RemoteFetch/PrivateAddressCheck.swift`
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/PrivateAddressCheckTests.swift`

**Interfaces:**
- Produces:
  - `enum PrivateAddressCheck`, with `struct Checks: OptionSet, Sendable { static let unwrapEmbeddedIPv4, cidrList, namedRanges; static let all }` and `static func isPrivate(_ ipAddress: String, checks: Checks = .all) -> Bool`.
  - `enum AddressPolicy: Sendable { case mastodonPrivateAddressCheck; case loopbackPorts(Set<Int>); case allowAll }`, with `func refuses(ipAddress: String?, port: Int?) -> Bool`.

- [ ] **Step 1: Write the failing tests.**

```swift
import Testing
@testable import ActivityPubCore

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

- [ ] **Step 2: Run.** `swift test --filter PrivateAddressCheckTests`. **Expected:** it fails to compile, because `PrivateAddressCheck` is undefined.

- [ ] **Step 3: Implement.**
  - **Parsing.** Parse with `inet_pton`, trying `AF_INET` first and then `AF_INET6`. A string that parses as neither is private.
  - **Order** (§0.2):
    1. Check `::` and `::1` as IPv6.
    2. With `.unwrapEmbeddedIPv4`, check an IPv4-mapped (`::ffff:0:0/96`) or IPv4-compatible (`::/96`) address as the IPv4 address it embeds.
    3. With `.namedRanges`, refuse `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7`, `127.0.0.0/8`, `::1`, `169.254.0.0/16` and `fe80::/10`.
    4. With `.cidrList`, refuse the 24 entries of §0.2, copied verbatim into a `static let` of `(bytes, prefixLength)`.
  - **Policies.**
    - `.mastodonPrivateAddressCheck` refuses `nil` and every private address.
    - `.loopbackPorts(p)` admits only `127.0.0.1` on a port in `p`.
    - `.allowAll` admits everything.
  - **Doc comment.** Cite `app/lib/private_address_check.rb` at commit `467c933`.

- [ ] **Step 4: Run.** **Expected:** PASS.

- [ ] **Step 5: Commit.** `git commit -m "feat: private-address classifier with Mastodon's CIDR list"`

---

### Task 3: Test servers, TLS fixtures and the legacy key-fetch control

**Files:**
- Create: `Tests/ActivityPubCoreTests/RemoteFetch/TestServer.swift`, `TestOnlyTLS.swift`, `TestSupport.swift`, `LegacyFetchControlTests.swift`

**Interfaces:**
- Produces (test target only). Each of these is defined in a step below:
  - `TestServer`, `ServerStats`, `RecordedRequest`, `TestResponse`, `TestTLS`, `TestBarrier`
  - `TestOnlyTLS`
  - `withTestClient(_: HTTPClient, body:)`, `testTLSClientConfiguration()`, `bareFetch(_:readTimeout:)`, `settle()`
  - `Fixtures`, `redirectChain(_:to:)`, `stopAll(_:)`

- [ ] **Step 1: Generate the TLS fixtures once.** Run these in a new empty temporary directory:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 36500 \
  -subj "/CN=FAP test-only CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj "/CN=localhost"
printf '%s\n' "subjectAltName=IP:127.0.0.1,DNS:localhost" "basicConstraints=critical,CA:FALSE" \
  "keyUsage=critical,digitalSignature,keyEncipherment" "extendedKeyUsage=serverAuth" > leaf.ext
openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 36500 \
  -extfile leaf.ext -out leaf.pem
rm ca.key ca.srl leaf.csr leaf.ext   # the CA key is never kept
```

  Paste `ca.pem`, `leaf.pem` and `leaf.key` into `TestOnlyTLS.swift`, then delete the directory:

```swift
/// TLS material for the remote-fetch tests only. Not secrets: the CA's private key was deleted
/// after it signed the leaf, so the CA can issue nothing else, and the leaf is valid only for
/// IP:127.0.0.1 and DNS:localhost. Regenerate with the commands in the implementation plan,
/// docs/superpowers/plans/2026-10-22-reply-threading-step0.md, Task 3.
enum TestOnlyTLS {
    static let caCertificatePEM = """
        -----BEGIN CERTIFICATE-----
        …
        """
    static let leafCertificatePEM = """
        …
        """
    static let loopbackLeafPrivateKeyPEM_testOnly = """
        …
        """
}
```

- [ ] **Step 2: Write `TestServer.swift`.**

```swift
import Foundation
import NIOCore
import NIOHTTP2
import NIOPosix
import NIOSSL
import Synchronization

struct RecordedRequest: Sendable {
    let method: String
    let target: String
    let headers: [String: String]   // names lowercased
}

indirect enum TestResponse: Sendable {
    case document(contentType: String?, body: String, status: Int = 200)
    case redirect(status: Int = 302, location: String?)
    case drip(contentType: String, body: String, chunks: Int, every: TimeAmount)
    case stallAfterHead(contentType: String)
    case holdUntil(TestBarrier, then: TestResponse)
    case never
}

struct TestTLS: Sendable {
    var alpn: [String] = ["http/1.1"]
    var http2 = false
}

/// Opens once; every waiter, earlier or later, then proceeds.
actor TestBarrier {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

final class ServerStats: Sendable {
    struct Snapshot: Sendable {
        var connections = 0, bytes = 0, closes = 0, tlsHandshakes = 0, h2Streams = 0
        var requests: [RecordedRequest] = []
    }
    private let state = Mutex(Snapshot())
    func update(_ change: (inout Snapshot) -> Void) { state.withLock { change(&$0) } }
    var snapshot: Snapshot { state.withLock { $0 } }
    var connections: Int { snapshot.connections }
    var bytes: Int { snapshot.bytes }            // HTTP bytes, after TLS
    var closes: Int { snapshot.closes }
    var tlsHandshakes: Int { snapshot.tlsHandshakes }
    var h2Streams: Int { snapshot.h2Streams }
    var requests: [RecordedRequest] { snapshot.requests }
}

/// After TLS (or first): counts connections, closes, handshakes and HTTP bytes; passes reads on.
final class ConnectionCounter: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let stats: ServerStats
    init(stats: ServerStats) { self.stats = stats }
    func channelActive(context: ChannelHandlerContext) {
        stats.update { $0.connections += 1 }
        context.fireChannelActive()
    }
    func channelInactive(context: ChannelHandlerContext) {
        stats.update { $0.closes += 1 }
        context.fireChannelInactive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let count = Self.unwrapInboundIn(data).readableBytes
        stats.update { $0.bytes += count }
        context.fireChannelRead(data)
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // Known limitation: TLSUserEvent is in NIOTLS, not a declared test dependency.
        if String(describing: event).hasPrefix("handshakeCompleted") {
            stats.update { $0.tlsHandshakes += 1 }
        }
        context.fireUserInboundEventTriggered(event)
    }
}

final class Responder: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let stats: ServerStats
    let respond: @Sendable (RecordedRequest) -> TestResponse
    private var received = ByteBuffer()
    private var answered = false
    init(stats: ServerStats, respond: @escaping @Sendable (RecordedRequest) -> TestResponse) {
        self.stats = stats
        self.respond = respond
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var chunk = Self.unwrapInboundIn(data)
        received.writeBuffer(&chunk)
        guard !answered, let request = Self.parseHead(String(buffer: received)) else { return }
        answered = true
        stats.update { $0.requests.append(request) }
        send(respond(request), context: context)
    }

    static func parseHead(_ text: String) -> RecordedRequest? {
        guard let end = text.range(of: "\r\n\r\n") else { return nil }
        let lines = text[..<end.lowerBound].components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return RecordedRequest(method: parts[0], target: parts[1], headers: headers)
    }

    static func head(_ status: Int, contentType: String?, length: Int, location: String? = nil) -> String {
        var head = "HTTP/1.1 \(status) Test\r\nContent-Length: \(length)\r\nConnection: close\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        if let location { head += "Location: \(location)\r\n" }
        return head + "\r\n"
    }

    func send(_ response: TestResponse, context: ChannelHandlerContext) {
        switch response {
        case .document(let contentType, let body, let status):
            write(Self.head(status, contentType: contentType, length: body.utf8.count) + body, context)
        case .redirect(let status, let location):
            write(Self.head(status, contentType: nil, length: 0, location: location), context)
        case .drip(let contentType, let body, let chunks, let every):
            let bytes = Array(body.utf8)
            write(Self.head(200, contentType: contentType, length: bytes.count), context)
            drip(bytes[...], size: max(1, (bytes.count + chunks - 1) / chunks), every: every, context: context)
        case .stallAfterHead(let contentType):
            write(Self.head(200, contentType: contentType, length: 10), context)
        case .holdUntil(let barrier, let then):
            let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
            let loop = context.eventLoop
            Task {
                await barrier.wait()
                loop.execute { let (handler, ctx) = bound.value; handler.send(then, context: ctx) }
            }
        case .never:
            break
        }
    }

    private func drip(_ rest: ArraySlice<UInt8>, size: Int, every: TimeAmount, context: ChannelHandlerContext) {
        guard !rest.isEmpty else { return }
        context.eventLoop.assumeIsolated().scheduleTask(in: every) {
            context.writeAndFlush(Self.wrapOutboundOut(ByteBuffer(bytes: rest.prefix(size))), promise: nil)
            self.drip(rest.dropFirst(size), size: size, every: every, context: context)
        }
    }

    private func write(_ text: String, _ context: ChannelHandlerContext) {
        context.writeAndFlush(Self.wrapOutboundOut(ByteBuffer(string: text)), promise: nil)
    }
}

final class TestServer: Sendable {
    let channel: any Channel
    let stats: ServerStats
    let scheme: String
    init(channel: any Channel, stats: ServerStats, scheme: String) {
        self.channel = channel; self.stats = stats; self.scheme = scheme
    }
    var port: Int { channel.localAddress!.port! }
    func url(_ pathAndQuery: String) -> String { "\(scheme)://127.0.0.1:\(port)\(pathAndQuery)" }
    func stop() async throws { try await channel.close() }

    static func start(
        tls: TestTLS? = nil,
        respond: @escaping @Sendable (RecordedRequest) -> TestResponse = { _ in .never }
    ) async throws -> TestServer {
        let stats = ServerStats()
        let sslContext: NIOSSLContext? = try tls.map { tls in
            var config = TLSConfiguration.makeServerConfiguration(
                certificateChain: [.certificate(try NIOSSLCertificate(
                    bytes: Array(TestOnlyTLS.leafCertificatePEM.utf8), format: .pem))],
                privateKey: .privateKey(try NIOSSLPrivateKey(
                    bytes: Array(TestOnlyTLS.loopbackLeafPrivateKeyPEM_testOnly.utf8), format: .pem)))
            config.applicationProtocols = tls.alpn
            return try NIOSSLContext(configuration: config)
        }
        let http2 = tls?.http2 ?? false
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ops = channel.pipeline.syncOperations
                    if let sslContext { try ops.addHandler(NIOSSLServerHandler(context: sslContext)) }
                    try ops.addHandler(ConnectionCounter(stats: stats))
                    if !http2 { try ops.addHandler(Responder(stats: stats, respond: respond)) }
                }.flatMap {
                    guard http2 else { return channel.eventLoop.makeSucceededVoidFuture() }
                    // A new inbound stream means the client sent a request's HEADERS.
                    return channel.configureHTTP2Pipeline(mode: .server, inboundStreamInitializer: { stream in
                        stats.update { $0.h2Streams += 1 }
                        return stream.eventLoop.makeSucceededVoidFuture()
                    }).map { _ in }
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return TestServer(channel: channel, stats: stats, scheme: tls == nil ? "http" : "https")
    }
}
```

  The construction follows FederatedActivityPublisher#283's `TestServer`. The NIO symbols it uses are:
  - `ServerBootstrap`, `childChannelInitializer`, `syncOperations`, `.socketOption(.so_reuseaddr)`
  - `NIOLoopBound(_:eventLoop:)` (`NIOCore/NIOLoopBound.swift:41`)
  - `assumeIsolated().scheduleTask(in:_:)` (`NIOCore/EventLoopFuture+AssumeIsolated.swift:84-87`)
  - `TLSConfiguration.makeServerConfiguration(certificateChain:privateKey:)` (`NIOSSL/TLSConfiguration.swift:623`)
  - `NIOSSLCertificate(bytes:format:)` and `NIOSSLPrivateKey(bytes:format:)`
  - `NIOSSLServerHandler(context:)`
  - `configureHTTP2Pipeline(mode:…:inboundStreamInitializer:)` (`NIOHTTP2/HTTP2PipelineHelpers.swift:205-211`, swift-nio-http2 1.42.0)

- [ ] **Step 3: Write `TestSupport.swift` (part 1).**

```swift
import AsyncHTTPClient
import Crypto
import _CryptoExtras
import Foundation
import NIOCore
import NIOSSL
import Testing
@testable import ActivityPubCore

let activityJSON = "application/activity+json"

func testTLSClientConfiguration() -> TLSConfiguration {
    var tls = TLSConfiguration.makeClientConfiguration()
    tls.trustRoots = .certificates([try! NIOSSLCertificate(
        bytes: Array(TestOnlyTLS.caCertificatePEM.utf8), format: .pem)])
    return tls
}

/// Runs `body`, then awaits `shutdown()` on the returning and the throwing path. A body may shut
/// the client down itself (Task 7's stall control); the second shutdown's `alreadyShutdown` is ignored.
func withTestClient<T>(_ client: HTTPClient, body: (HTTPClient) async throws -> T) async throws -> T {
    func shutdown() async throws {
        do { try await client.shutdown() } catch let error as HTTPClientError where error == .alreadyShutdown {}
    }
    do {
        let result = try await body(client)
        try await shutdown()
        return result
    } catch {
        try? await shutdown()
        throw error
    }
}

/// AHC defaults (follows up to 5 redirects, AHC 1.33.1 HTTPClient.swift:1334-1343), no middleware,
/// no generated layer: shows what a test server serves.
func bareFetch(_ url: String, readTimeout: TimeAmount? = nil)
    async throws -> (status: Int, headers: [(String, String)], bodyBytes: Int)
{
    var config = HTTPClient.Configuration()
    config.tlsConfiguration = testTLSClientConfiguration()
    config.timeout.read = readTimeout
    return try await withTestClient(HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)) {
        let response = try await $0.execute(HTTPClientRequest(url: url), timeout: .seconds(30))
        let body = try await response.body.collect(upTo: 16 * 1_048_576)
        return (Int(response.status.code), response.headers.map { ($0.name, $0.value) }, body.readableBytes)
    }
}

/// Lets in-flight bytes and closes land on a server before counting.
func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

func stopAll(_ servers: TestServer...) async { for server in servers { try? await server.stop() } }

/// `hops` servers, each answering 302 to the next; the last redirects to `final`.
func redirectChain(_ hops: Int, to final: String) async throws -> [TestServer] {
    var next = final
    var servers: [TestServer] = []
    for _ in 0..<hops {
        let location = next
        let server = try await TestServer.start { _ in .redirect(location: location) }
        servers.insert(server, at: 0)
        next = server.url("/hop")
    }
    return servers
}

enum Fixtures {
    static let signingKey = try! _RSA.Signing.PrivateKey(keySize: .bits2048)
    static var publicKeyPem: String { signingKey.publicKey.pemRepresentation }

    /// The URL the request was made to, from its Host header and target.
    static func selfURL(_ request: RecordedRequest) -> String {
        "http://\(request.headers["host"] ?? "")\(request.target)"
    }
    static func note(id: String, attributedTo: String) -> String {
        #"{"@context":"https://www.w3.org/ns/activitystreams","id":"\#(id)","type":"Note","attributedTo":"\#(attributedTo)","to":["https://www.w3.org/ns/activitystreams#Public"],"cc":[],"content":"<p>hi</p>"}"#
    }
    static func actor(id: String, publicKeyPem: String = Fixtures.publicKeyPem, extra: String = "") -> String {
        let pem = publicKeyPem.replacingOccurrences(of: "\n", with: "\\n")
        return #"{"@context":["https://www.w3.org/ns/activitystreams","https://w3id.org/security/v1"],"id":"\#(id)","type":"Person","preferredUsername":"alice","inbox":"\#(id)/inbox","endpoints":{"sharedInbox":"\#(id)/shared"},"publicKey":{"id":"\#(id)#main-key","owner":"\#(id)","publicKeyPem":"\#(pem)"}\#(extra)}"#
    }
    /// `json` with a "padding" member added so the result is exactly `bytes` UTF-8 bytes.
    static func padded(_ json: String, to bytes: Int) -> String {
        let open = String(json.dropLast()) + #","padding":""#
        let close = #""}"#
        let fill = bytes - open.utf8.count - close.utf8.count
        precondition(fill >= 0, "Fixtures.padded: target \(bytes) bytes is smaller than the fixture plus padding member (\(open.utf8.count + close.utf8.count) bytes)")
        return open + String(repeating: "x", count: fill) + close
    }
}
```

- [ ] **Step 4: Fixture checks** (they go in `LegacyFetchControlTests.swift`).

```swift
// LegacyFetchControlTests.swift
import Foundation
import Testing
@testable import ActivityPubCore

@Test func fixtureFourRedirectsAreServed() async throws {
    let d = try await TestServer.start { .document(contentType: activityJSON,
                                                   body: Fixtures.actor(id: Fixtures.selfURL($0))) }
    let chain = try await redirectChain(4, to: d.url("/a"))
    let result = try await bareFetch(chain[0].url("/hop"))
    #expect(result.status == 200)
    #expect(d.stats.requests.count == 1)
    await stopAll(d); for s in chain { await stopAll(s) }
}
@Test func fixtureOversizeBodyIsServed() async throws {
    let big = try await TestServer.start { .document(contentType: activityJSON,
        body: Fixtures.padded(Fixtures.actor(id: Fixtures.selfURL($0)), to: 1_048_577)) }
    #expect(try await bareFetch(big.url("/a")).bodyBytes == 1_048_577)
    await stopAll(big)
}
```

- [ ] **Step 5: The key-fetch test's legacy control** (spec, "Key fetch"). These run against the code before step 0 changes it.

```swift
@Test func legacyKeyFetchFollowsFourRedirects() async throws {
    let d = try await TestServer.start { .document(contentType: activityJSON,
                                                   body: Fixtures.actor(id: Fixtures.selfURL($0))) }
    let chain = try await redirectChain(4, to: d.url("/a"))
    let actor = try await KeyManager().fetchActorDocument(actorUri: chain[0].url("/hop"), signingKey: nil)
    #expect(actor.publicKeyPem == Fixtures.publicKeyPem)
    await stopAll(d); for s in chain { await stopAll(s) }
}
@Test func legacyKeyFetchReadsPastOneMegabyte() async throws {
    let big = try await TestServer.start { .document(contentType: activityJSON,
        body: Fixtures.padded(Fixtures.actor(id: Fixtures.selfURL($0)), to: 1_048_577)) }
    let actor = try await KeyManager().fetchActorDocument(actorUri: big.url("/a"), signingKey: nil)
    #expect(actor.publicKeyPem == Fixtures.publicKeyPem)
    await stopAll(big)
}
```

- [ ] **Step 6: Run.** `swift test --filter LegacyFetchControlTests`. **Expected:** PASS. The code before step 0 has no redirect limit and no size cap. Record the output: it is the key-fetch control's red, with the capability absent.

- [ ] **Step 7: Commit.** `git commit -m "test: NIO test servers, TLS fixtures, legacy key-fetch control"`

---

### Task 4: Document, generated client, client construction and the fetch pipe

**Files:**
- Create:
  - `Sources/ActivityPubCore/openapi.yaml` and `openapi-generator-config.yaml`
  - `RemoteFetch/RemoteFetchError.swift`, `RemoteFetchContext.swift`, `RemoteFetchClient.swift`, `RemoteFetchMiddleware.swift`, `RemoteDocuments.swift`
- Modify:
  - `Package.swift`: `plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]` on `ActivityPubCore`.
  - `Sources/ActivityPubCore/FetchRemoteObject.swift`: add the new functions beside the legacy one, which Task 14 deletes.
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/RemoteFetchClientTests.swift`, and `TestSupport.swift` (part 2)

**Interfaces:**
- Produces:
  - **`public enum RemoteFetchError: Error`.** Exactly the cases in §0.1, "The error type": `invalidURI(String)`, `noContext`, `schemeRefused(URL)`, `tooManyRedirects(URL)`, `deadlineExceeded`, `status(Int)`, `contentType(String?)`, `bodyTooLarge`, `addressRefused(String)`, `invalidDocument(DecodingError)`, `generatedLayerRefused(underlying: any Error)`, `transportFailed(underlying: any Error)`.
  - **`struct UndocumentedStatusError: Error { let statusCode: Int }`.**
  - **`extension RemoteFetchError { static func from(_ error: any Error) -> RemoteFetchError }`.** It unwraps `ClientError.underlyingError`, then applies the order in §0.1, "Telling the generated layer from the transport", rules 1–5. Rule 4 tests `ClientError.response != nil`.
  - **`RemoteFetchContext`.** `struct RemoteFetchContext: Sendable { let target: URL; let signer: FetchSigningKey?; let deadline: ContinuousClock.Instant; let schemePolicy: SchemePolicy; @TaskLocal static var current: RemoteFetchContext? }`.
  - **`SchemePolicy`.** `enum SchemePolicy: Sendable { case httpsOnly; case allowingHTTP(ports: Set<Int>); func admits(_ url: URL) -> Bool }`. `allowingHTTP` admits `https` on any port and `http` only on the listed ports. The scheme compares case-insensitively.
  - **`RemoteFetchChecks`.** `struct RemoteFetchChecks: OptionSet, Sendable`, with `scheme`, `redirectLimit`, `bodyCap`, `contentType`, `status`, `deadline`, `verbatimRequestTarget`, `resignEachHop` and `static let all`.
  - **`RemoteFetchMiddleware`.** `struct RemoteFetchMiddleware: ClientMiddleware { init(checks: RemoteFetchChecks = .all) }`. Its constants are `static let maxRedirects = 3` and `static let maxBodyBytes = 1_048_576`.
  - **`RemoteFetchClient`.** `struct RemoteFetchClient: Sendable { let client: Client; let httpClient: HTTPClient; static let shared: RemoteFetchClient; static func make(addressPolicy: AddressPolicy = .mastodonPrivateAddressCheck, checks: RemoteFetchChecks = .all, closesRefusedChannel: Bool = true, middleware: (any ClientMiddleware)? = nil, adjust: (inout HTTPClient.Configuration) -> Void = { _ in }) -> RemoteFetchClient; func shutdown() async throws }`.
  - **`RemoteObjectDocument` and `RemoteActorDocument`.** Public structs whose fields are those of §0.1 ("How the typed results are consumed"), as `public let`s.
  - **The fetch functions:**
    - `public func fetchRemoteObject(uri: String, signer: FetchSigningKey? = nil, deadline: ContinuousClock.Instant) async throws -> RemoteObjectDocument`
    - `func fetchRemoteObject(uri: String, signer: FetchSigningKey? = nil, deadline: ContinuousClock.Instant, schemePolicy: SchemePolicy, client: RemoteFetchClient) async throws -> RemoteObjectDocument`
    - the same pair for `fetchRemoteActor`, returning `RemoteActorDocument`.
  - **Test support,** defined in Step 2.

- [ ] **Step 1: The document and the config.**

  `Sources/ActivityPubCore/openapi.yaml`:

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

  `Sources/ActivityPubCore/openapi-generator-config.yaml`:

```yaml
generate:
  - types
  - client
accessModifier: internal
```

- [ ] **Step 2: Write `TestSupport.swift` (part 2) and the failing tests.**

```swift
// TestSupport.swift, part 2
import OpenAPIRuntime

func withTestClient<T>(_ client: RemoteFetchClient, body: (RemoteFetchClient) async throws -> T) async throws -> T {
    try await withTestClient(client.httpClient) { _ in try await body(client) }
}

/// The production construction with a loopback address policy and the test CA.
func makeTestClient(
    admitting ports: Set<Int>,
    checks: RemoteFetchChecks = .all,
    closesRefusedChannel: Bool = true,
    middleware: (any ClientMiddleware)? = nil,
    adjust: @escaping (inout HTTPClient.Configuration) -> Void = { _ in }
) -> RemoteFetchClient {
    RemoteFetchClient.make(addressPolicy: .loopbackPorts(ports), checks: checks,
                           closesRefusedChannel: closesRefusedChannel, middleware: middleware,
                           adjust: { $0.tlsConfiguration = testTLSClientConfiguration(); adjust(&$0) })
}

func object(_ uri: String, via client: RemoteFetchClient, http ports: Set<Int> = [],
            signer: FetchSigningKey? = nil, deadline: ContinuousClock.Instant = .now + .seconds(10))
    async throws -> RemoteObjectDocument
{
    try await fetchRemoteObject(uri: uri, signer: signer, deadline: deadline,
        schemePolicy: ports.isEmpty ? .httpsOnly : .allowingHTTP(ports: ports), client: client)
}

func actor(_ uri: String, via client: RemoteFetchClient, http ports: Set<Int> = [],
           signer: FetchSigningKey? = nil, deadline: ContinuousClock.Instant = .now + .seconds(10))
    async throws -> RemoteActorDocument
{
    try await fetchRemoteActor(uri: uri, signer: signer, deadline: deadline,
        schemePolicy: ports.isEmpty ? .httpsOnly : .allowingHTTP(ports: ports), client: client)
}

/// The RemoteFetchError `body` throws; records an issue if it returns or throws something else.
func fetchError(_ body: () async throws -> Void) async -> RemoteFetchError? {
    do { try await body(); Issue.record("expected a RemoteFetchError, got success"); return nil }
    catch let error as RemoteFetchError { return error }
    catch { Issue.record("expected a RemoteFetchError, got \(error)"); return nil }
}

/// Calls the generated client directly under a bound context; returns the ClientError it throws.
func generatedCallError(_ uri: String, via client: RemoteFetchClient, http ports: Set<Int>) async -> ClientError? {
    let context = RemoteFetchContext(target: URL(string: uri)!, signer: nil, deadline: .now + .seconds(10),
                                     schemePolicy: .allowingHTTP(ports: ports))
    do {
        _ = try await RemoteFetchContext.$current.withValue(context) { try await client.client.getObject() }
        Issue.record("expected a ClientError"); return nil
    } catch let error as ClientError { return error }
    catch { Issue.record("expected a ClientError, got \(error)"); return nil }
}

extension RemoteFetchError {
    var name: String {
        switch self {
        case .invalidURI: "invalidURI"
        case .noContext: "noContext"
        case .schemeRefused: "schemeRefused"
        case .tooManyRedirects: "tooManyRedirects"
        case .deadlineExceeded: "deadlineExceeded"
        case .status: "status"
        case .contentType: "contentType"
        case .bodyTooLarge: "bodyTooLarge"
        case .addressRefused: "addressRefused"
        case .invalidDocument: "invalidDocument"
        case .generatedLayerRefused: "generatedLayerRefused"
        case .transportFailed: "transportFailed"
        }
    }
}

/// A server that answers every request with a note whose id is the request's own URL.
func noteServer(contentType: String? = activityJSON, status: Int = 200) async throws -> TestServer {
    try await TestServer.start {
        .document(contentType: contentType,
                  body: Fixtures.note(id: Fixtures.selfURL($0), attributedTo: "https://remote.example/users/a"),
                  status: status)
    }
}
```

```swift
// RemoteFetchClientTests.swift
import Foundation
import OpenAPIRuntime
import Testing
@testable import ActivityPubCore

@Suite("Remote fetch client") struct RemoteFetchClientTests {
    @Test func clientConstructionCompletes() async throws {
        // The construction RemoteFetchClient.shared uses; it runs the try! on Servers.Server1.url().
        try await withTestClient(RemoteFetchClient.make()) { _ in }
    }

    @Test func fetchesObjectAndActorAndSendsAccept() async throws {
        let a = try await TestServer.start {
            $0.target == "/a"
                ? .document(contentType: activityJSON, body: Fixtures.actor(id: Fixtures.selfURL($0)))
                : .document(contentType: activityJSON,
                            body: Fixtures.note(id: Fixtures.selfURL($0), attributedTo: "x"))
        }
        try await withTestClient(makeTestClient(admitting: [a.port])) { client in
            let note = try await object(a.url("/n"), via: client, http: [a.port])
            #expect(note.id == a.url("/n"))
            let person = try await actor(a.url("/a"), via: client, http: [a.port])
            #expect(person.inbox == a.url("/a") + "/inbox")
            #expect(person.publicKeyPem == Fixtures.publicKeyPem)
            #expect(a.stats.requests[0].headers["accept"]?.contains("application/activity+json") == true)
        }
        await stopAll(a)
    }

    @Test func unboundCallThrowsNoContextBeforeConnecting() async throws {
        let a = try await noteServer()
        try await withTestClient(makeTestClient(admitting: [a.port])) { client in
            var caught: (any Error)?
            do { _ = try await client.client.getObject() } catch { caught = error }
            let error = try #require(caught)
            #expect(RemoteFetchError.from(error).name == "noContext")
            #expect(a.stats.connections == 0)
        }
        await stopAll(a)
    }

    @Test func boundCallConnects() async throws {                         // control
        let a = try await noteServer()
        try await withTestClient(makeTestClient(admitting: [a.port])) { client in
            let context = RemoteFetchContext(target: URL(string: a.url("/n"))!, signer: nil,
                                             deadline: .now + .seconds(10), schemePolicy: .allowingHTTP(ports: [a.port]))
            _ = try await RemoteFetchContext.$current.withValue(context) { try await client.client.getObject() }
            #expect(a.stats.connections == 1)
        }
        await stopAll(a)
    }

    @Test func unparsableURIFailsWithInvalidURI() async throws {
        try await withTestClient(makeTestClient(admitting: [])) { client in
            #expect(await fetchError { _ = try await object("not a url", via: client) }?.name == "invalidURI")
        }
    }
}
```

- [ ] **Step 3: Run.** `swift test --filter RemoteFetchClientTests`. **Expected:** it fails to compile.

- [ ] **Step 4: Implement.**
  - **`RemoteFetchClient.make`.**
    - Configuration:

      ```swift
      var config = HTTPClient.Configuration()
      config.redirectConfiguration = .disallow
      config.timeout.connect = .seconds(5)
      config.timeout.read = .seconds(10)
      config.httpVersion = .http1Only
      config.proxy = nil
      config.connectionPool.retryConnectionEstablishment = false
      config.http1_1ConnectionDebugInitializer = { channel in … }
      ```

    - The hook reads `channel.remoteAddress?.ipAddress` and `?.port`. If `addressPolicy.refuses(...)`, it calls `channel.close(promise: nil)` when `closesRefusedChannel` is set, and returns `channel.eventLoop.makeFailedFuture(RemoteFetchError.addressRefused("\(address)"))`. Otherwise it returns `channel.eventLoop.makeSucceededVoidFuture()`.
    - Then call `adjust(&config)`, and build `HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)`.
    - The transport is `AsyncHTTPClientTransport(configuration: .init(client: httpClient, timeout: .seconds(10)))`.
    - The client is `Client(serverURL: try! Servers.Server1.url(), transport: transport, middlewares: [middleware ?? RemoteFetchMiddleware(checks: checks)])`.
    - `static let shared = RemoteFetchClient.make()`.
    - `shutdown()` awaits `httpClient.shutdown()`.
    - The hook's NIOCore calls resolve through the file's explicit `import NIOCore` (import headers below).
  - **`RemoteFetchMiddleware.intercept`** (only this much in this task).
    - With no context bound, throw `.noContext`.
    - Otherwise build the hop's request as "Changes since the spec", item 9 describes:
      - `var parts = URLComponents(url: hop, resolvingAgainstBaseURL: false)!`
      - keep `let query = parts.percentEncodedQuery`
      - set `parts.percentEncodedQuery = nil` and `parts.fragment = nil`
      - set the path to `"/"` when it is empty
      - pass `parts.url!` as the base URL to `next`, and set `request.path = query.map { "?" + $0 } ?? ""`
  - **`fetchRemoteObject` and `fetchRemoteActor`.**
    - Parse `uri` with `URL(string:)` and require a scheme and a host, or throw `invalidURI(uri)`.
    - Bind the context with `RemoteFetchContext.$current.withValue`, then call `getObject()` or `getActor()`.
    - On `.ok`, switch over both body cases and map the document. The two case names are in the generated `Types.swift` under `.build/plugins/outputs/`.
    - On `.undocumented(statusCode:_:)`, throw `.generatedLayerRefused(underlying: UndocumentedStatusError(statusCode:))`.
    - Catch any other error and throw `RemoteFetchError.from(error)`.
  - **`RemoteDocuments.swift`** maps as §0.1 says:
    - `attributedTo` is the first entry, as its string or its `id`.
    - `to` and `cc` map every entry the same way; an absent field is `[]`.
    - `types` is the string, or the array.
    - `url` is the string, or the `Link`'s `href`. For an array it is the first `Link`'s `href`, and if there is none, the first string.
    - `language` is `contentMap`'s key when it has exactly one.
    - The actor's `publicKeyPem` comes from the object, or from the array's first entry.
    - The actor's `sharedInbox` is `endpoints.sharedInbox`.
  - **Import header of each production file:**
    - `RemoteFetchError.swift`: `import AsyncHTTPClient` (for `HTTPClientError`, rule 3), `import Foundation`, `import OpenAPIRuntime` (for `ClientError`).
    - `RemoteFetchContext.swift`: `import Foundation`.
    - `PrivateAddressCheck.swift` (Task 2): `import Foundation` (for `inet_pton`).
    - `RemoteFetchClient.swift`: `import AsyncHTTPClient`, `import Foundation`, `import NIOCore`, `import OpenAPIAsyncHTTPClient`, `import OpenAPIRuntime`.
    - `RemoteFetchMiddleware.swift`: `import Foundation`, `import HTTPTypes`, `import OpenAPIRuntime` (Task 6 changes the last to `@_spi(Generated) import OpenAPIRuntime`).
    - `RemoteDocuments.swift`: `import Foundation`.
    - `FetchRemoteObject.swift`: `import Foundation`, `import OpenAPIRuntime`.
    - `ActorKeyCache.swift` (Task 12): `import Synchronization`.
  - `TestSupport.swift` part 2 adds `import OpenAPIRuntime` to part 1's import list.

- [ ] **Step 5: Run.** The same filter, locally and in CI. **Expected:** PASS.

- [ ] **Step 6: The construction control.** On a throwaway branch that is never merged, set `servers: - url:` to `https://[remote-fetch.invalid` and run `swift test --filter clientConstructionCompletes` in CI.
  - **Expected:** red. The test process traps at the `try!`, and the log contains `invalidServerURL`.
  - **If the build fails before the test runs** (the generator or OpenAPIKit rejects the URL), use the fallback document instead: `servers: [{url: "https://{host}", variables: {host: {default: "["}}}]`. The generated `url()` substitutes the variable at runtime (`Conversion/ServerVariable.swift:29-43`, runtime 1.11.0). `URL(validatingOpenAPIServerURL:)` then throws `invalidServerURL` for `https://[` (`Conversion/URLExtensions.swift:33-36`).
  - Record the run URL of whichever form discharged the control.

- [ ] **Step 7: Commit.** `git commit -m "feat: generated remote-fetch client on AsyncHTTPClientTransport"`

---

### Task 5: Scheme, redirects and `Location`

**Files:**
- Modify: `RemoteFetch/RemoteFetchMiddleware.swift`
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/RedirectAndSchemeTests.swift`

**Interfaces:**
- Consumes: Task 4.
- Produces: the hop loop. Tasks 6, 7 and 9 add to it.

- [ ] **Step 1: Write the failing tests.**

```swift
import Foundation
import Testing
@testable import ActivityPubCore

@Suite("Redirects and scheme") struct RedirectAndSchemeTests {
    @Test func threeRedirectsPass() async throws {
        let d = try await noteServer()
        let chain = try await redirectChain(3, to: d.url("/n"))
        let ports = Set(chain.map(\.port) + [d.port])
        try await withTestClient(makeTestClient(admitting: ports)) { client in
            #expect(try await object(chain[0].url("/hop"), via: client, http: ports).id == d.url("/n"))
        }
        await stopAll(d); for s in chain { await stopAll(s) }
    }

    @Test func fourthRedirectFails() async throws {
        let d = try await noteServer()
        let chain = try await redirectChain(4, to: d.url("/n"))
        let ports = Set(chain.map(\.port) + [d.port])
        try await withTestClient(makeTestClient(admitting: ports)) { client in
            let error = await fetchError { _ = try await object(chain[0].url("/hop"), via: client, http: ports) }
            #expect(error?.name == "tooManyRedirects")
            #expect(d.stats.connections == 0)
        }
        await stopAll(d); for s in chain { await stopAll(s) }
    }

    @Test func fourthRedirectFollowedWithLimitOff() async throws {      // control
        let d = try await noteServer()
        let chain = try await redirectChain(4, to: d.url("/n"))
        let ports = Set(chain.map(\.port) + [d.port])
        try await withTestClient(makeTestClient(admitting: ports, checks: .all.subtracting(.redirectLimit))) {
            #expect(try await object(chain[0].url("/hop"), via: $0, http: ports).id == d.url("/n"))
            #expect(d.stats.requests.count == 1)
        }
        await stopAll(d); for s in chain { await stopAll(s) }
    }

    @Test func unparsableLocationFailsWithInvalidURI() async throws {
        let r = try await TestServer.start { _ in .redirect(location: "http://[") }
        try await withTestClient(makeTestClient(admitting: [r.port])) { client in
            #expect(await fetchError { _ = try await object(r.url("/x"), via: client, http: [r.port]) }?
                .name == "invalidURI")
        }
        await stopAll(r)
    }

    @Test func validLocationIsFollowed() async throws {                  // control
        let d = try await noteServer()
        let r = try await TestServer.start { _ in .redirect(location: d.url("/n")) }
        try await withTestClient(makeTestClient(admitting: [r.port, d.port])) {
            #expect(try await object(r.url("/x"), via: $0, http: [r.port, d.port]).id == d.url("/n"))
        }
        await stopAll(r, d)
    }

    @Test func relativeLocationResolvesAgainstTheHop() async throws {
        let r = try await TestServer.start {
            $0.target == "/start" ? .redirect(location: "/doc")
                : .document(contentType: activityJSON, body: Fixtures.note(id: Fixtures.selfURL($0), attributedTo: "x"))
        }
        try await withTestClient(makeTestClient(admitting: [r.port])) {
            #expect(try await object(r.url("/start"), via: $0, http: [r.port]).id == r.url("/doc"))
        }
        await stopAll(r)
    }

    @Test(arguments: [302, 304]) func redirectWithoutLocationFailsWithStatus(_ code: Int) async throws {
        let r = try await TestServer.start { _ in .redirect(status: code, location: nil) }
        try await withTestClient(makeTestClient(admitting: [r.port])) { client in
            let error = await fetchError { _ = try await object(r.url("/x"), via: client, http: [r.port]) }
            guard case .status(let got)? = error else { Issue.record("\(String(describing: error))"); return }
            #expect(got == code)
        }
        await stopAll(r)
    }

    @Test func httpInitialURIFailsUnderDefaultPolicy() async throws {
        let a = try await noteServer()
        try await withTestClient(makeTestClient(admitting: [a.port])) { client in
            #expect(await fetchError { _ = try await object(a.url("/n"), via: client) }?.name == "schemeRefused")
            #expect(a.stats.connections == 0)
        }
        await stopAll(a)
    }

    @Test func redirectToUnadmittedHTTPPortFails() async throws {
        let b = try await noteServer()
        let a = try await TestServer.start { _ in .redirect(location: b.url("/n")) }
        try await withTestClient(makeTestClient(admitting: [a.port, b.port])) { client in
            #expect(await fetchError { _ = try await object(a.url("/x"), via: client, http: [a.port]) }?
                .name == "schemeRefused")
            #expect(b.stats.connections == 0)
        }
        await stopAll(a, b)
    }

    @Test func httpsToHTTPHopFails() async throws {
        let b = try await noteServer()
        let t = try await TestServer.start(tls: TestTLS()) { _ in .redirect(location: b.url("/n")) }
        try await withTestClient(makeTestClient(admitting: [t.port, b.port])) { client in
            #expect(await fetchError { _ = try await object(t.url("/x"), via: client) }?.name == "schemeRefused")
            #expect(b.stats.connections == 0)
        }
        await stopAll(t, b)
    }

    @Test func schemeControlsSucceedWhenAdmitted() async throws {        // control for the three above
        let b = try await noteServer()
        let a = try await TestServer.start { _ in .redirect(location: b.url("/n")) }
        let t = try await TestServer.start(tls: TestTLS()) { _ in .redirect(location: b.url("/n")) }
        try await withTestClient(makeTestClient(admitting: [a.port, b.port, t.port])) { client in
            #expect(try await object(b.url("/n"), via: client, http: [b.port]).id == b.url("/n"))
            #expect(try await object(a.url("/x"), via: client, http: [a.port, b.port]).id == b.url("/n"))
            #expect(try await object(t.url("/x"), via: client, http: [b.port]).id == b.url("/n"))
        }
        await stopAll(a, b, t)
    }
}
```

- [ ] **Step 2: Run.** `swift test --filter RedirectAndSchemeTests`. **Expected:** the refusal tests fail.

- [ ] **Step 3: Implement the hop loop** (§0.1, "One middleware", steps 2–3). For each hop, from 0 to `maxRedirects`:
  1. With `.scheme`, check `context.schemePolicy.admits(hop)`, or throw `.schemeRefused(hop)`.
  2. Build the request as in Task 4, then call `next`.
  3. On a 3xx with a `Location`:
     - drain and discard the body, collecting at most `maxBodyBytes` (Task 7 moves this onto `CappedBody`);
     - resolve `URL(string: location, relativeTo: hop)?.absoluteURL`, and require a scheme and a host, or throw `.invalidURI(location)`;
     - loop.
  4. With `.redirectLimit`, a 4th redirect throws `.tooManyRedirects(url)`. With it off, follow up to 16 hops.
  5. A 3xx without `Location` falls through to the status check (Task 6). Until Task 6 lands, throw `.status(code)` for it.

- [ ] **Step 4: Run.** **Expected:** PASS. Record each control's output.

- [ ] **Step 5: Commit.** `git commit -m "feat: per-hop scheme check and redirect limit in the fetch middleware"`

---

### Task 6: Status and content type

**Files:**
- Modify: `RemoteFetch/RemoteFetchMiddleware.swift`. It adds `@_spi(Generated) import OpenAPIRuntime`.
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/StatusAndContentTypeTests.swift`

**Interfaces:**
- Produces: `static let declaredContentTypes: [OpenAPIMIMEType]` (the two values in Global Constraints, parsed with `OpenAPIMIMEType(_:)`) and `static func admitsContentType(_ raw: String?) -> Bool`.

- [ ] **Step 1: Write the failing tests.**

```swift
import AsyncHTTPClient
import Foundation
import OpenAPIRuntime
import Testing
@testable import ActivityPubCore

@Suite("Status and content type") struct StatusAndContentTypeTests {
    static let refusedConcrete = ["text/html", "text/html; charset=utf-8", "application/ld+json",
        #"application/ld+json; profile="https://www.w3.org/ns/activitystreams https://example.org/p""#]
    /// Parameter names that collide case-insensitively. Admitted, they would reach the runtime's
    /// `OpenAPIMIMEType.evaluate`, which builds `Dictionary(uniqueKeysWithValues:)` from lowercased
    /// names and traps on the duplicate (`Base/OpenAPIMIMEType.swift:239`, runtime 1.11.0).
    static let collidingParameters = ["application/activity+json; a=1; A=2",
                                      "application/activity+json; charset=utf-8; Charset=utf-8"]
    static let nonConcrete: [String?] = [nil, "", "*/*", "text/*", "html", "*/html"]
    static let accepted = ["application/activity+json; charset=utf-8",
        #"application/ld+json; profile="https://www.w3.org/ns/activitystreams""#, "Application/Activity+JSON"]

    @Test(arguments: refusedConcrete) func concreteUndeclaredRefusedByMiddleware(_ ct: String) async throws {
        let s = try await noteServer(contentType: ct)
        try await withTestClient(makeTestClient(admitting: [s.port])) { client in
            let error = await fetchError { _ = try await object(s.url("/n"), via: client, http: [s.port]) }
            guard case .contentType(let got)? = error else { Issue.record("\(String(describing: error))"); return }
            #expect(got == ct)
        }
        await stopAll(s)
    }

    @Test(arguments: refusedConcrete) func concreteUndeclaredRefusedByGeneratedLayerWhenCheckOff(_ ct: String) async throws {
        let s = try await noteServer(contentType: ct)                     // control
        try await withTestClient(makeTestClient(admitting: [s.port], checks: .all.subtracting(.contentType))) { client in
            let error = try #require(await generatedCallError(s.url("/n"), via: client, http: [s.port]))
            #expect(error.response != nil)
            #expect(!(error.underlyingError is DecodingError))
            #expect(RemoteFetchError.from(error).name == "generatedLayerRefused")
        }
        await stopAll(s)
    }

    @Test(arguments: nonConcrete) func nonConcreteRefusedByMiddleware(_ ct: String?) async throws {
        let s = try await noteServer(contentType: ct)
        try await withTestClient(makeTestClient(admitting: [s.port])) { client in
            #expect(await fetchError { _ = try await object(s.url("/n"), via: client, http: [s.port]) }?
                .name == "contentType")
        }
        await stopAll(s)
    }

    @Test(arguments: nonConcrete) func nonConcreteAcceptedWhenCheckOff(_ ct: String?) async throws {
        let s = try await noteServer(contentType: ct)                     // control
        try await withTestClient(makeTestClient(admitting: [s.port], checks: .all.subtracting(.contentType))) {
            #expect(try await object(s.url("/n"), via: $0, http: [s.port]).id == s.url("/n"))
        }
        await stopAll(s)
    }

    @Test(arguments: accepted) func declaredTypesPass(_ ct: String) async throws {
        let s = try await noteServer(contentType: ct)
        try await withTestClient(makeTestClient(admitting: [s.port])) {
            #expect(try await object(s.url("/n"), via: $0, http: [s.port]).id == s.url("/n"))
        }
        await stopAll(s)
    }

    @Test func contentTypeTypeAndSubtypeAreCaseInsensitive() async throws {
        #expect(RemoteFetchMiddleware.admitsContentType("Application/Activity+JSON"))
        #expect(!RemoteFetchMiddleware.admitsContentType("Application/Activity+XML"))
    }

    @Test(arguments: collidingParameters) func collidingParameterNamesRefusedByMiddleware(_ ct: String) async throws {
        let s = try await noteServer(contentType: ct)
        try await withTestClient(makeTestClient(admitting: [s.port])) { client in
            let error = await fetchError { _ = try await object(s.url("/n"), via: client, http: [s.port]) }
            guard case .contentType(let got)? = error else { Issue.record("\(String(describing: error))"); return }
            #expect(got == ct)
        }
        await stopAll(s)
    }

    @Test func collidingParameterNamesAreNotAdmitted() {
        for ct in Self.collidingParameters { #expect(!RemoteFetchMiddleware.admitsContentType(ct)) }
        #expect(RemoteFetchMiddleware.admitsContentType("application/activity+json; a=1; b=2"))
    }

    // Exit tests: each body runs in a child process and captures nothing. A thrown error is caught
    // and the body returns, so the child exits successfully; only a trap makes it exit with failure.

    @Test func collidingParameterNamesTrapInRuntimeWithCheckOff() async {   // control, in a child process
        await #expect(processExitsWith: .failure) {
            let s = try await noteServer(contentType: "application/activity+json; a=1; A=2")
            try await withTestClient(makeTestClient(admitting: [s.port], checks: .all.subtracting(.contentType))) {
                do { _ = try await object(s.url("/n"), via: $0, http: [s.port]) } catch {}
            }
        }
    }

    @Test func collidingParameterNamesDoNotTrapWithCheckOn() async {
        await #expect(processExitsWith: .success) {
            let s = try await noteServer(contentType: "application/activity+json; a=1; A=2")
            try await withTestClient(makeTestClient(admitting: [s.port])) {
                do { _ = try await object(s.url("/n"), via: $0, http: [s.port]) } catch {}
            }
        }
    }

    /// 404 with a valid document; 204 with an empty body (a 204 must not carry one).
    func statusServer(_ code: Int) async throws -> TestServer {
        code == 204 ? try await TestServer.start { _ in .document(contentType: activityJSON, body: "", status: 204) }
                    : try await noteServer(status: code)
    }

    @Test(arguments: [404, 204]) func non200RefusedByMiddleware(_ code: Int) async throws {
        let s = try await statusServer(code)
        try await withTestClient(makeTestClient(admitting: [s.port])) { client in
            let error = await fetchError { _ = try await object(s.url("/n"), via: client, http: [s.port]) }
            guard case .status(let got)? = error else { Issue.record("\(String(describing: error))"); return }
            #expect(got == code)
        }
        await stopAll(s)
    }

    @Test(arguments: [404, 204]) func non200UndocumentedWhenCheckOff(_ code: Int) async throws {
        let s = try await statusServer(code)                              // control
        try await withTestClient(makeTestClient(admitting: [s.port], checks: .all.subtracting(.status))) { client in
            let error = await fetchError { _ = try await object(s.url("/n"), via: client, http: [s.port]) }
            guard case .generatedLayerRefused(let underlying)? = error,
                  let undocumented = underlying as? UndocumentedStatusError
            else { Issue.record("\(String(describing: error))"); return }
            #expect(undocumented.statusCode == code)
        }
        await stopAll(s)
    }

    @Test func fixtureServesTheConfiguredHeader() async throws {
        let s = try await noteServer(contentType: "text/html")
        let result = try await bareFetch(s.url("/n"))
        #expect(result.headers.contains { $0.0.lowercased() == "content-type" && $0.1 == "text/html" })
        await stopAll(s)
    }
}
```

  **The trap's control runs in a child process.** With the content-type check off, a colliding header traps in the runtime.
  - **How the trap happens.** `OpenAPIMIMEType.init?(_:)` dedups parameters on exact keys only (`Dictionary(_:uniquingKeysWith:)`). `evaluate` then builds `Dictionary(uniqueKeysWithValues: receivedParameters.map { ($0.key.lowercased(), $0.value) })` (`Base/OpenAPIMIMEType.swift:239`, runtime 1.11.0). `Converter.bestContentType` calls `evaluate` for every concrete received type (`Conversion/Converter+Common.swift:43-76`).
  - **The control.** `collidingParameterNamesTrapInRuntimeWithCheckOff` measures the trap at the pinned runtime with a Swift Testing exit test, and `collidingParameterNamesDoNotTrapWithCheckOn` shows that the middleware's refusal prevents it.
  - **Receipts for exit tests** (swiftlang/swift-testing at tag `swift-6.3-RELEASE`):
    - `Sources/Testing/Expectations/Expectation+Macro.swift` declares `@freestanding(expression) @discardableResult macro expect(processExitsWith expectedExitCondition: ExitTest.Condition, observing: [any PartialKeyPath<ExitTest.Result> & Sendable] = [], _ comment:, sourceLocation:, performing expression: @escaping @Sendable () async throws -> Void) -> ExitTest.Result?`. It is unavailable only under `SWT_NO_EXIT_TESTS`.
    - `Package.swift` defines `SWT_NO_EXIT_TESTS` only for Embedded Swift and for iOS, watchOS, tvOS, visionOS, WASI and Android, so exit tests run on Linux and macOS.
    - `Sources/Testing/ExitTests/ExitTest.Condition.swift` declares `public static var success: Self` and `public static var failure: Self` (available from Swift 6.2). `failure` "matches any exit code other than `EXIT_SUCCESS` or any signal that causes the process to exit", so the test body catches thrown errors to keep a transport failure from counting as the trap.
  - **If the trap is gone at the pinned runtime,** `collidingParameterNamesTrapInRuntimeWithCheckOff` goes red. Record that in the PR, delete that one test, and keep the refusal and the other tests.

- [ ] **Step 2: Run.** **Expected:** the tests that expect the middleware to refuse fail.

- [ ] **Step 3: Implement** step 4 of "One middleware" in §0.1, and "Content type and status".
  - After the last hop, with `.status`, require 200, or throw `.status(code)`.
  - With `.contentType`:
    1. Parse `response.headerFields[.contentType]` with `OpenAPIMIMEType(_:)`, and require `.concrete`.
    2. Refuse when any two received parameter names are equal case-insensitively. Check with a `Set` of lowercased names, comparing its count with the parameter count.
    3. Match a declared type. Type and subtype compare case-insensitively.
    4. Every declared parameter must be present. Its name compares case-insensitively and its value case-sensitively. The runtime keeps the quotes in parameter values, so the `profile` value is compared with its quotes.
    5. Ignore extra received parameters.
    - Otherwise throw `.contentType(raw)`.
  - **No trap in FAP's own comparison.** The middleware never calls `Dictionary(uniqueKeysWithValues:)` and never compares two `OpenAPIMIMEType` values with `==`, which builds the same kind of dictionary (`Base/OpenAPIMIMEType.swift:87-88`, runtime 1.11.0). For each declared parameter it looks the name up by iterating the received parameters with a case-insensitive comparison.

- [ ] **Step 4: Run.** **Expected:** PASS. Record the controls.

- [ ] **Step 5: Commit.** `git commit -m "feat: status and content-type checks in the fetch middleware"`

---

### Task 7: Body cap and deadline

**Files:**
- Modify: `RemoteFetch/RemoteFetchMiddleware.swift`
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/BodyAndDeadlineTests.swift`

**Interfaces:**
- Produces: `struct CappedBody: AsyncSequence, Sendable` over `HTTPBody` chunks (`ArraySlice<UInt8>`).
  - With `.bodyCap`, it throws `.bodyTooLarge` once the running total passes `maxBodyBytes`.
  - With `.deadline`, it throws `.deadlineExceeded` for a chunk that arrives at or after the deadline.
  - It is returned as `HTTPBody(capped, length: original.length, iterationBehavior: .single)`.

- [ ] **Step 1: Write the failing tests.**

```swift
import AsyncHTTPClient
import Foundation
import Synchronization
import Testing
@testable import ActivityPubCore

@Suite("Body and deadline", .serialized) struct BodyAndDeadlineTests {
    func sized(_ bytes: Int) async throws -> TestServer {
        try await TestServer.start { .document(contentType: activityJSON,
            body: Fixtures.padded(Fixtures.note(id: Fixtures.selfURL($0), attributedTo: "x"), to: bytes)) }
    }

    @Test func oversizeBodyFails() async throws {
        let s = try await sized(1_048_577)
        try await withTestClient(makeTestClient(admitting: [s.port])) { client in
            #expect(await fetchError { _ = try await object(s.url("/n"), via: client, http: [s.port]) }?
                .name == "bodyTooLarge")
        }
        await stopAll(s)
    }

    @Test func oversizeBodyReadInFullWithCapOff() async throws {          // control
        let s = try await sized(1_048_577)
        try await withTestClient(makeTestClient(admitting: [s.port], checks: .all.subtracting(.bodyCap))) {
            #expect(try await object(s.url("/n"), via: $0, http: [s.port]).id == s.url("/n"))
        }
        await stopAll(s)
    }

    @Test func bodyAtExactlyOneMegabytePasses() async throws {
        let s = try await sized(1_048_576)
        try await withTestClient(makeTestClient(admitting: [s.port])) {
            #expect(try await object(s.url("/n"), via: $0, http: [s.port]).id == s.url("/n"))
        }
        await stopAll(s)
    }

    func dripServer() async throws -> TestServer {    // 50 chunks, one every 100 ms: ≈ 5 s
        try await TestServer.start { .drip(contentType: activityJSON,
            body: Fixtures.note(id: Fixtures.selfURL($0), attributedTo: "x"), chunks: 50, every: .milliseconds(100)) }
    }

    @Test func slowDripFailsAtDeadline() async throws {
        let s = try await dripServer()
        try await withTestClient(makeTestClient(admitting: [s.port])) { client in
            let start = ContinuousClock.now
            let error = await fetchError {
                _ = try await object(s.url("/n"), via: client, http: [s.port], deadline: start + .seconds(2))
            }
            let elapsed = ContinuousClock.now - start
            #expect(error?.name == "deadlineExceeded")
            #expect(elapsed >= .seconds(2) && elapsed < .milliseconds(2500))
        }
        await stopAll(s)
    }

    @Test func slowDripCompletesWithDeadlineOff() async throws {          // control
        let s = try await dripServer()
        try await withTestClient(makeTestClient(admitting: [s.port], checks: .all.subtracting(.deadline))) { client in
            let start = ContinuousClock.now
            let note = try await object(s.url("/n"), via: client, http: [s.port], deadline: start + .seconds(2))
            #expect(note.id == s.url("/n"))
            #expect(ContinuousClock.now - start >= .milliseconds(4500))
        }
        await stopAll(s)
    }

    @Test func stallFailsWithReadTimeout() async throws {
        let s = try await TestServer.start { _ in .stallAfterHead(contentType: activityJSON) }
        try await withTestClient(makeTestClient(admitting: [s.port], adjust: { $0.timeout.read = .seconds(3) })) { client in
            let start = ContinuousClock.now
            let error = await fetchError {
                _ = try await object(s.url("/n"), via: client, http: [s.port], deadline: start + .seconds(2))
            }
            let elapsed = ContinuousClock.now - start
            guard case .transportFailed(let underlying)? = error else { Issue.record("\(String(describing: error))"); return }
            #expect((underlying as? HTTPClientError) == .readTimeout)
            #expect(elapsed >= .seconds(3) && elapsed < .milliseconds(3500))
        }
        await stopAll(s)
    }

    @Test func stallStillWaitingWithoutReadTimeout() async throws {      // control
        let s = try await TestServer.start { _ in .stallAfterHead(contentType: activityJSON) }
        let done = Mutex(false)
        try await withTestClient(makeTestClient(admitting: [s.port], adjust: { $0.timeout.read = nil })) { client in
            let fetch = Task {
                _ = try? await object(s.url("/n"), via: client, http: [s.port], deadline: .now + .seconds(2))
                done.withLock { $0 = true }
            }
            try await Task.sleep(for: .seconds(10))
            #expect(done.withLock { $0 } == false)
            try await client.httpClient.shutdown()   // nothing in the design cancels a pending body read
            _ = await fetch.result
        }
        await stopAll(s)
    }

    @Test func expiredDeadlineFailsBeforeConnecting() async throws {
        let s = try await sized(1024)
        try await withTestClient(makeTestClient(admitting: [s.port])) { client in
            #expect(await fetchError {
                _ = try await object(s.url("/n"), via: client, http: [s.port], deadline: .now - .seconds(1))
            }?.name == "deadlineExceeded")
            #expect(s.stats.connections == 0)
        }
        await stopAll(s)
    }

    @Test func expiredDeadlineConnectsWithDeadlineOff() async throws {    // control
        let s = try await sized(1024)
        try await withTestClient(makeTestClient(admitting: [s.port], checks: .all.subtracting(.deadline))) {
            _ = try await object(s.url("/n"), via: $0, http: [s.port], deadline: .now - .seconds(1))
            #expect(s.stats.connections == 1)
        }
        await stopAll(s)
    }

    /// The only test that exercises the head race (`withoutActuallyEscaping` + task group): the
    /// server accepts the request and never answers.
    @Test func slowHeadFailsAtDeadline() async throws {
        let s = try await TestServer.start { _ in .never }
        try await withTestClient(makeTestClient(admitting: [s.port])) { client in
            let start = ContinuousClock.now
            #expect(await fetchError {
                _ = try await object(s.url("/n"), via: client, http: [s.port], deadline: start + .seconds(2))
            }?.name == "deadlineExceeded")
            #expect(ContinuousClock.now - start < .milliseconds(2500))
        }
        await stopAll(s)
    }

    @Test func slowHeadOutlivesDeadlineWithDeadlineOff() async throws {   // control
        let s = try await TestServer.start { _ in .never }
        try await withTestClient(makeTestClient(admitting: [s.port], checks: .all.subtracting(.deadline))) { client in
            let start = ContinuousClock.now
            let error = await fetchError {
                _ = try await object(s.url("/n"), via: client, http: [s.port], deadline: start + .seconds(2))
            }
            // Ended by the transport's 10 s timeout (or the 10 s read timeout), not by the deadline.
            #expect(error?.name != "deadlineExceeded")
            #expect(ContinuousClock.now - start >= .milliseconds(2500))
        }
        await stopAll(s)
    }

    @Test func fixturesDripAndStallAsClaimed() async throws {
        let drip = try await dripServer()
        let start = ContinuousClock.now
        _ = try await bareFetch(drip.url("/n"))
        #expect(ContinuousClock.now - start >= .milliseconds(4500))
        let stall = try await TestServer.start { _ in .stallAfterHead(contentType: activityJSON) }
        await #expect(throws: HTTPClientError.readTimeout) { _ = try await bareFetch(stall.url("/n"), readTimeout: .seconds(1)) }
        await stopAll(drip, stall)
    }
}
```

- [ ] **Step 2: Run.** **Expected:** the tests that expect a refusal fail.

- [ ] **Step 3: Implement.**
  - **Before each hop.** With `.deadline`, if `ContinuousClock.now >= deadline`, throw `.deadlineExceeded` without calling `next`.
  - **The race** (with `.deadline` on; with it off, call `next` directly). Inside `withoutActuallyEscaping(next)`, run `next` in a `withThrowingTaskGroup` against `try await Task.sleep(until: deadline, clock: .continuous)`. The first child to finish wins, and the group cancels the other. If the sleep finishes first, throw `.deadlineExceeded`.
  - **Bodies.** Wrap the final body in `CappedBody`, and drain 3xx bodies through it as well.

- [ ] **Step 4: Run.** **Expected:** PASS. Record the elapsed times.

- [ ] **Step 5: Commit.** `git commit -m "feat: body cap and per-fetch deadline in the fetch middleware"`

---

### Task 8: Typed documents

**Files:**
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/DocumentTests.swift`
- Modify (only if a test shows a mapping bug): `RemoteFetch/RemoteDocuments.swift`

**Interfaces:**
- Consumes: Task 4's mapping.

- [ ] **Step 1: Write the tests.**

```swift
import Foundation
import Testing
@testable import ActivityPubCore

@Suite("Typed documents") struct DocumentTests {
    func serving(_ body: String) async throws -> TestServer {
        try await TestServer.start { _ in .document(contentType: activityJSON, body: body) }
    }
    func actorResult(_ body: String) async throws -> Result<RemoteActorDocument, RemoteFetchError> {
        let s = try await serving(body)
        defer { Task { await stopAll(s) } }
        return try await withTestClient(makeTestClient(admitting: [s.port])) { client in
            do { return .success(try await actor(s.url("/a"), via: client, http: [s.port])) }
            catch let error as RemoteFetchError { return .failure(error) }
        }
    }
    func objectResult(_ body: String) async throws -> Result<RemoteObjectDocument, RemoteFetchError> {
        let s = try await serving(body)
        defer { Task { await stopAll(s) } }
        return try await withTestClient(makeTestClient(admitting: [s.port])) { client in
            do { return .success(try await object(s.url("/n"), via: client, http: [s.port])) }
            catch let error as RemoteFetchError { return .failure(error) }
        }
    }
    static let valid = Fixtures.actor(id: "https://remote.example/users/a")

    @Test(arguments: [#"{"a":"#,
                      #"{"id":"https://x/a","type":"Person"}"#,
                      #"{"id":"https://x/a","type":"Person","inbox":5}"#])
    func invalidActorDocument(_ body: String) async throws {
        guard case .failure(.invalidDocument) = try await actorResult(body) else { Issue.record(body); return }
    }
    @Test func objectWithNumericAttributedToIsInvalid() async throws {
        guard case .failure(.invalidDocument) = try await objectResult(#"{"id":"x","type":"Note","attributedTo":5}"#)
        else { Issue.record("accepted"); return }
    }
    @Test func validDocumentReturned() async throws {                     // control
        #expect(try await actorResult(Self.valid).get().inbox == "https://remote.example/users/a/inbox")
    }

    @Test func unknownFieldsAreTolerated() async throws {
        let extra = (1...40).map { i in
            switch i % 4 {
            case 0: #","x\#(i)":"s""#
            case 1: #","x\#(i)":\#(i)"#
            case 2: #","x\#(i)":{"n":{"m":[1,"a",null]}}"#
            default: #","x\#(i)":[{"a":1},"b",2]"#
            }
        }.joined()
        let mastodon = #","following":"f","followers":"https://remote.example/users/a/followers","featured":"f","manuallyApprovesFollowers":false,"discoverable":true,"published":"2024-01-01T00:00:00Z","url":"https://remote.example/@a","icon":{"type":"Image","url":"i"},"attachment":[],"tag":[]"#
        let document = try await actorResult(Fixtures.actor(id: "https://remote.example/users/a",
                                                            extra: mastodon + extra)).get()
        #expect(document.id == "https://remote.example/users/a")
        #expect(document.inbox == "https://remote.example/users/a/inbox")
        #expect(document.sharedInbox == "https://remote.example/users/a/shared")
        #expect(document.publicKeyPem == Fixtures.publicKeyPem)
        #expect(document.followers == "https://remote.example/users/a/followers")
        #expect(document.url == "https://remote.example/@a")
        #expect(document.preferredUsername == "alice")
    }
    @Test func sameDocumentWithoutInboxFails() async throws {             // control
        let noInbox = Self.valid.replacingOccurrences(of: #""inbox":"https://remote.example/users/a/inbox","#, with: "")
        guard case .failure(.invalidDocument) = try await actorResult(noInbox) else { Issue.record("accepted"); return }
    }

    static func note(_ member: String) -> String { #"{"id":"https://x/n","type":"Note",\#(member)}"# }

    @Test(arguments: [#""attributedTo":"u""#, #""attributedTo":{"id":"u"}"#, #""attributedTo":[{"id":"u"},"v"]"#])
    func attributedToForms(_ member: String) async throws {
        #expect(try await objectResult(Self.note(member)).get().attributedTo == "u")
    }
    @Test(arguments: [#""to":"u""#, #""to":["u"]"#])
    func toForms(_ member: String) async throws {
        #expect(try await objectResult(Self.note(member)).get().to == ["u"])
    }
    @Test(arguments: [#""url":"w""#, #""url":{"href":"w"}"#, #""url":[{"href":"w"}]"#])
    func urlForms(_ member: String) async throws {
        #expect(try await objectResult(Self.note(member)).get().url == "w")
    }
    @Test func publicKeyForms() async throws {
        let object = try await actorResult(Self.valid).get().publicKeyPem
        let array = try await actorResult(Self.valid
            .replacingOccurrences(of: #""publicKey":{"#, with: #""publicKey":[{"#)
            .replacingOccurrences(of: #"}}"#, with: #"}]}"#)).get().publicKeyPem
        #expect(object == array)
    }
    @Test(arguments: [#""attributedTo":5"#, #""to":5"#, #""url":5"#])     // control
    func numericValueFails(_ member: String) async throws {
        guard case .failure(.invalidDocument) = try await objectResult(Self.note(member)) else { Issue.record(member); return }
    }
    @Test func numericPublicKeyFails() async throws {                     // control
        guard case .failure(.invalidDocument) = try await actorResult(
            #"{"id":"https://x/a","type":"Person","inbox":"i","publicKey":5}"#) else { Issue.record("accepted"); return }
    }
    @Test func nullOptionalFieldReadsAsAbsent() async throws {
        #expect(try await objectResult(Self.note(#""summary":null"#)).get().summary == nil)
    }
    @Test func singleContentMapKeyIsTheLanguage() async throws {
        #expect(try await objectResult(Self.note(#""contentMap":{"en":"hi"}"#)).get().language == "en")
        #expect(try await objectResult(Self.note(#""contentMap":{"en":"hi","de":"hallo"}"#)).get().language == nil)
    }
}
```

  `defer { Task { … } }` stops each server after the helper returns, without blocking it. The helpers return a `Result`, so each assertion can match the error case.

- [ ] **Step 2: Run.** `swift test --filter DocumentTests`. **Expected:** PASS, with every control red where it is marked. If a mapping is wrong, fix `RemoteDocuments.swift` and run again.

- [ ] **Step 3: Commit.** `git commit -m "test: typed remote documents, value-or-array and unknown fields"`

---

### Task 9: Request target and signing

**Files:**
- Modify:
  - `Sources/ActivityPubCore/Crypto/HTTPSignature.swift`: add `signedGetHeaders`.
  - `RemoteFetch/RemoteFetchMiddleware.swift`.
  - `Sources/ActivityPubCore/Crypto/KeyManager.swift`: delete `actorDocumentRequest`, `:81-117`.
  - `Tests/ActivityPubCoreTests/SignedFetchTests.swift`: `:33-117` move from `actorDocumentRequest` to `signedGetHeaders`.
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/SigningAndTargetTests.swift`

**Interfaces:**
- Produces: `extension HTTPSignature { static func signedGetHeaders(url: URL, signer: FetchSigningKey, date: Date = Date()) throws -> [String: String] }`.
  - The path is `percentEncodedPath` (`/` when empty) plus `?` and the query, and the host is `host[:port]`.
  - It then calls `signGet(privateKeyPem:keyId:path:host:date:)` (`HTTPSignature.swift:172-200`).
  - A URL without a host throws `RemoteFetchError.invalidURI`.

- [ ] **Step 1: Write the failing tests.**

```swift
import Foundation
import Testing
@testable import ActivityPubCore

@Suite("Request target and signing") struct SigningAndTargetTests {
    static let signer = FetchSigningKey(keyId: "https://activity.example/users/memes#main-key",
                                        privateKeyPem: Fixtures.signingKey.pemRepresentation)

    func verifies(_ request: RecordedRequest, path: String) throws -> Bool {
        try HTTPSignature.verify(signatureHeader: request.headers["signature"] ?? "", method: "get", path: path,
                                 headers: request.headers, body: Data(), publicKeyPem: Fixtures.publicKeyPem)
    }

    @Test func requestTargetReachesServerByteForByte() async throws {
        let a = try await noteServer()
        try await withTestClient(makeTestClient(admitting: [a.port])) {
            _ = try await object(a.url("/users/al%20ice?x=1&y=%2F"), via: $0, http: [a.port])
        }
        #expect(a.stats.requests[0].target == "/users/al%20ice?x=1&y=%2F")
        await stopAll(a)
    }

    @Test func plainPathTemplateDoesNotPreserveTarget() async throws {    // control
        let a = try await noteServer()
        try await withTestClient(makeTestClient(admitting: [a.port], checks: .all.subtracting(.verbatimRequestTarget))) {
            _ = try? await object(a.url("/users/al%20ice?x=1&y=%2F"), via: $0, http: [a.port])
        }
        #expect(a.stats.requests.first?.target != "/users/al%20ice?x=1&y=%2F")
        await stopAll(a)
    }

    @Test func pathStartingWithDoubleSlashIsSentVerbatim() async throws {
        let a = try await noteServer()
        try await withTestClient(makeTestClient(admitting: [a.port])) {
            _ = try? await object(a.url("//other/x"), via: $0, http: [a.port])
        }
        #expect(a.stats.requests.count == 1)
        #expect(a.stats.requests.first?.target == "//other/x")
        await stopAll(a)
    }

    @Test func doubleSlashPathChangesWithoutVerbatimTarget() async throws {   // control
        let a = try await noteServer()
        try await withTestClient(makeTestClient(admitting: [a.port], checks: .all.subtracting(.verbatimRequestTarget))) {
            _ = try? await object(a.url("//other/x"), via: $0, http: [a.port])
        }
        #expect(a.stats.requests.count == 1)
        #expect(a.stats.requests.first?.target != "//other/x")
        await stopAll(a)
    }

    @Test func signedFetchVerifies() async throws {
        let a = try await noteServer()
        try await withTestClient(makeTestClient(admitting: [a.port])) {
            _ = try await object(a.url("/users/b?page=1"), via: $0, http: [a.port], signer: Self.signer)
        }
        let request = try #require(a.stats.requests.first)
        let params = HTTPSignature.parseSignatureHeader(try #require(request.headers["signature"]))
        #expect(params["keyId"] == Self.signer.keyId)
        #expect(params["headers"] == "(request-target) host date")
        #expect(request.headers["host"] == "127.0.0.1:\(a.port)")
        #expect(try verifies(request, path: "/users/b?page=1"))
        #expect(try !verifies(request, path: "/users/b"))                // control: query is signed
        await stopAll(a)
    }

    @Test func redirectedFetchIsSignedAgainForTheSecondHop() async throws {
        let b = try await noteServer()
        let a = try await TestServer.start { _ in .redirect(location: b.url("/b?q=1")) }
        try await withTestClient(makeTestClient(admitting: [a.port, b.port])) {
            _ = try await object(a.url("/a"), via: $0, http: [a.port, b.port], signer: Self.signer)
        }
        #expect(try verifies(try #require(b.stats.requests.first), path: "/b?q=1"))
        #expect(b.stats.requests.first?.headers["host"] == "127.0.0.1:\(b.port)")
        await stopAll(a, b)
    }

    @Test func unsignedCallCarriesNoSignature() async throws {            // control
        let a = try await noteServer()
        try await withTestClient(makeTestClient(admitting: [a.port])) {
            _ = try await object(a.url("/n"), via: $0, http: [a.port])
        }
        #expect(a.stats.requests.first?.headers["signature"] == nil)
        await stopAll(a)
    }

    @Test func reusedFirstHopHeadersFailOnSecondHop() async throws {      // control
        let b = try await noteServer()
        let a = try await TestServer.start { _ in .redirect(location: b.url("/b?q=1")) }
        try await withTestClient(makeTestClient(admitting: [a.port, b.port], checks: .all.subtracting(.resignEachHop))) {
            _ = try await object(a.url("/a"), via: $0, http: [a.port, b.port], signer: Self.signer)
        }
        #expect(try !verifies(try #require(b.stats.requests.first), path: "/b?q=1"))
        await stopAll(a, b)
    }
}
```

  `SignedFetchTests` keep their assertions, with `KeyManager.actorDocumentRequest(url:signingKey:)` replaced by `HTTPSignature.signedGetHeaders(url:signer:)`. `actorFetchWithoutSigningKeyIsUnsigned` moves here as `unsignedCallCarriesNoSignature`.

- [ ] **Step 2: Run.** **Expected:** the signing tests fail.

- [ ] **Step 3: Implement.**
  - **Signing.** On each hop with `context.signer`, set the `signedGetHeaders` output on `request.headerFields`, replacing what the previous hop set. The headers are `HTTPField.Name("Signature")!`, `"Date"` and `"Host"`.
  - **AHC and `Host`.** AHC keeps a `Host` header that is already present (`addHostIfNeeded`, `RequestValidation.swift:166-179`, AHC 1.33.1).
  - **Switches.** With `.resignEachHop` off, reuse hop 0's headers. With `.verbatimRequestTarget` off, set the base URL to the hop's origin only and `request.path` to `try Converter(configuration: .init()).renderedPath(template: "/{}", parameters: [pathAndQuery])` (`Conversion/Converter+Client.swift:42`, runtime 1.11.0), which is what a `/{path}` template produces.
  - **If `pathStartingWithDoubleSlashIsSentVerbatim` fails,** the transport or AHC rewrites the target under the item 9 mechanism. Stop and report with the recorded target. Do not weaken the assertion.

- [ ] **Step 4: Run** the new tests and `SignedFetchTests`. **Expected:** PASS.

- [ ] **Step 5: Commit.** `git commit -m "feat: sign every hop of a remote fetch and keep the request target verbatim"`

---

### Task 10: Connection-level address check

**Files:**
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/ConnectionTests.swift`
- Modify (only if a test fails): `RemoteFetch/RemoteFetchClient.swift`

**Interfaces:**
- Consumes: `RemoteFetchClient.make` with its `closesRefusedChannel:` and `adjust:` parameters, and `TestServer` with `TestTLS`.

- [ ] **Step 1: Write the tests.**
  - **Scheme policy.** Every fetch admits `http` on the ports it uses, so the address policy is the only thing that can refuse a hop.
  - **Address policy.** `.loopbackPorts([A])`, or `[A, T]` with a TLS server T.
  - **Server C.** It is never admitted.

```swift
import AsyncHTTPClient
import Foundation
import NIOSSL
import OpenAPIRuntime
import Testing
@testable import ActivityPubCore

@Suite("Connection-level address check", .serialized) struct ConnectionTests {
    /// A admits; A redirects to C, which the policy refuses.
    func redirectToC(_ c: TestServer) async throws -> TestServer {
        try await TestServer.start { _ in .redirect(location: c.url("/x")) }
    }

    @Test func redirectToRefusedPortFailsWithAddressError() async throws {
        let c = try await TestServer.start()
        let a = try await redirectToC(c)
        try await withTestClient(makeTestClient(admitting: [a.port])) { client in
            #expect(await fetchError { _ = try await object(a.url("/a"), via: client, http: [a.port, c.port]) }?
                .name == "addressRefused")
            try await settle()
            #expect(c.stats.connections == 1)       // also the "no retries" assertion
            #expect(c.stats.bytes == 0)
            #expect(c.stats.closes == 1)            // the hook closed the channel
        }
        await stopAll(a, c)
    }

    @Test func withoutHookRequestReachesRefusedPort() async throws {      // control
        let c = try await TestServer.start()
        let a = try await redirectToC(c)
        try await withTestClient(makeTestClient(admitting: [a.port], adjust: { $0.http1_1ConnectionDebugInitializer = nil })) {
            _ = try? await object(a.url("/a"), via: $0, http: [a.port, c.port], deadline: .now + .seconds(2))
            try await settle()
            #expect(c.stats.bytes > 0)
        }
        await stopAll(a, c)
    }

    @Test func refusedTLSPeerSeesHandshakeButNoHTTP() async throws {
        let c = try await TestServer.start(tls: TestTLS())
        let a = try await redirectToC(c)
        try await withTestClient(makeTestClient(admitting: [a.port])) { client in
            #expect(await fetchError { _ = try await object(a.url("/a"), via: client, http: [a.port]) }?
                .name == "addressRefused")
            try await settle()
            #expect(c.stats.tlsHandshakes == 1)
            #expect(c.stats.bytes == 0)
            #expect(c.stats.closes == 1)
        }
        await stopAll(a, c)
    }

    @Test func withoutHookTLSRequestReachesRefusedPort() async throws {   // control
        let c = try await TestServer.start(tls: TestTLS())
        let a = try await redirectToC(c)
        try await withTestClient(makeTestClient(admitting: [a.port], adjust: { $0.http1_1ConnectionDebugInitializer = nil })) {
            _ = try? await object(a.url("/a"), via: $0, http: [a.port], deadline: .now + .seconds(2))
            try await settle()
            #expect(c.stats.bytes > 0)
        }
        await stopAll(a, c)
    }

    @Test func hookWithoutCloseLeavesConnectionOpen() async throws {      // control for closes == 1
        let c = try await TestServer.start()
        let a = try await redirectToC(c)
        try await withTestClient(makeTestClient(admitting: [a.port], closesRefusedChannel: false)) {
            _ = try? await object(a.url("/a"), via: $0, http: [a.port, c.port])
            try await settle()
            #expect(c.stats.closes == 0)
        }
        await stopAll(a, c)
    }

    @Test func retriesOnReconnectRefusedAddress() async throws {          // control for connections == 1
        let c = try await TestServer.start()
        let a = try await redirectToC(c)
        try await withTestClient(makeTestClient(admitting: [a.port],
                                                adjust: { $0.connectionPool.retryConnectionEstablishment = true })) {
            _ = try? await object(a.url("/a"), via: $0, http: [a.port, c.port], deadline: .now + .seconds(2))
            try await settle()
            #expect(c.stats.connections > 1)
            #expect(c.stats.bytes == 0)
        }
        await stopAll(a, c)
    }

    @Test func http2CapableRefusedPeerIsRefused() async throws {
        let c = try await TestServer.start(tls: TestTLS(alpn: ["h2", "http/1.1"], http2: true))
        try await withTestClient(makeTestClient(admitting: [])) { client in
            #expect(await fetchError { _ = try await object(c.url("/x"), via: client) }?.name == "addressRefused")
            try await settle()
            #expect(c.stats.h2Streams == 0)
            #expect(c.stats.bytes == 0)
        }
        await stopAll(c)
    }

    @Test func automaticHTTPVersionNegotiatesH2AndBypassesHook() async throws {   // control
        let c = try await TestServer.start(tls: TestTLS(alpn: ["h2", "http/1.1"], http2: true))
        try await withTestClient(makeTestClient(admitting: [], adjust: { $0.httpVersion = .automatic })) { client in
            let error = await fetchError { _ = try await object(c.url("/x"), via: client, deadline: .now + .seconds(2)) }
            #expect(error?.name != "addressRefused")   // the server never answers; the deadline ends the fetch
            #expect(c.stats.h2Streams == 1)            // the request reached the server over h2
        }
        await stopAll(c)
    }

    @Test func testClientTrustsTestCA() async throws {
        let t = try await TestServer.start(tls: TestTLS()) {
            .document(contentType: activityJSON, body: Fixtures.note(id: "https://\($0.headers["host"]!)\($0.target)", attributedTo: "x"))
        }
        try await withTestClient(makeTestClient(admitting: [t.port])) {
            #expect(try await object(t.url("/n"), via: $0).id == t.url("/n"))
        }
        await stopAll(t)
    }

    @Test func systemTrustStoreRefusesTestCA() async throws {             // control
        let t = try await TestServer.start(tls: TestTLS()) { _ in .document(contentType: activityJSON, body: "{}") }
        try await withTestClient(makeTestClient(admitting: [t.port],
                                                adjust: { $0.tlsConfiguration = .makeClientConfiguration() })) { client in
            let error = try #require(await generatedCallError(t.url("/n"), via: client, http: []))
            #expect(error.response == nil)
            #expect(RemoteFetchError.from(error).name == "transportFailed")
        }
        await stopAll(t)
    }
}
```

- [ ] **Step 2: Run.** `swift test --filter ConnectionTests`. **Expected:** PASS with Task 4's hook. Each control should show that its setting matters. If a production-side test fails, fix `make` and run again. Record every server count.

- [ ] **Step 3: Commit.** `git commit -m "test: connection hook, close, retries, HTTP/1.1 and trust"`

---

### Task 11: One client, concurrent fetches

**Files:**
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/ConcurrencyTests.swift`

**Interfaces:**
- Consumes: the `middleware:` parameter of `makeTestClient`, and `TestBarrier`.

- [ ] **Step 1: Write the tests.**

```swift
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Synchronization
import Testing
@testable import ActivityPubCore

/// Control only: keeps the context in a stored property on the one shared middleware, so a
/// later call's target overwrites an earlier call's.
final class StoredTargetMiddleware: ClientMiddleware, Sendable {
    let stored = Mutex<RemoteFetchContext?>(nil)
    let entered = Mutex(0)
    let bothEntered = TestBarrier()
    let inner = RemoteFetchMiddleware()

    func intercept(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
                   next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?))
        async throws -> (HTTPResponse, HTTPBody?)
    {
        stored.withLock { $0 = RemoteFetchContext.current }
        if entered.withLock({ $0 += 1; return $0 }) == 2 { await bothEntered.open() }
        await bothEntered.wait()
        let shared = stored.withLock { $0 }
        return try await RemoteFetchContext.$current.withValue(shared) {
            try await inner.intercept(request, body: body, baseURL: baseURL, operationID: operationID, next: next)
        }
    }
}

@Suite("One client, concurrent fetches") struct ConcurrencyTests {
    @Test func concurrentFetchesReachTheirOwnServers() async throws {
        let bReceived = TestBarrier()
        let a = try await TestServer.start {
            .holdUntil(bReceived, then: .document(contentType: activityJSON,
                                                   body: Fixtures.note(id: Fixtures.selfURL($0), attributedTo: "x")))
        }
        let b = try await TestServer.start {
            let request = $0
            Task { await bReceived.open() }
            return .document(contentType: activityJSON, body: Fixtures.note(id: Fixtures.selfURL(request), attributedTo: "x"))
        }
        try await withTestClient(makeTestClient(admitting: [a.port, b.port])) { client in
            async let fromA = object(a.url("/n"), via: client, http: [a.port, b.port])
            async let fromB = object(b.url("/n"), via: client, http: [a.port, b.port])
            #expect(try await fromA.id == a.url("/n"))
            #expect(try await fromB.id == b.url("/n"))
        }
        #expect(a.stats.requests.count == 1)
        #expect(b.stats.requests.count == 1)
        await stopAll(a, b)
    }

    @Test func storedTargetMiddlewareMisroutes() async throws {           // control
        let a = try await noteServer()
        let b = try await noteServer()
        try await withTestClient(makeTestClient(admitting: [a.port, b.port], middleware: StoredTargetMiddleware())) { client in
            async let fromA = try? object(a.url("/n"), via: client, http: [a.port, b.port])
            async let fromB = try? object(b.url("/n"), via: client, http: [a.port, b.port])
            _ = await (fromA, fromB)
        }
        let counts = [a.stats.requests.count, b.stats.requests.count].sorted()
        #expect(counts == [0, 2])
        await stopAll(a, b)
    }
}
```

  `StoredTargetMiddleware` names HTTPTypes types. The test target declares the `HTTPTypes` product (Task 1).

- [ ] **Step 2: Run.** **Expected:** PASS, and the control misroutes. This test is the measurement for "TaskLocal isolation on one client" in the spec's "Unverified" section.

- [ ] **Step 3: Commit.** `git commit -m "test: per-task fetch context on one shared client"`

---

### Task 12: `ActorKeyCache`

**Files:**
- Create: `Sources/ActivityPubCore/Crypto/ActorKeyCache.swift`
- Test: `Tests/ActivityPubCoreTests/ActorKeyCacheTests.swift`

**Interfaces:**
- Produces: `public final class ActorKeyCache: Sendable { public init(loader: @escaping @Sendable (String) async throws -> String); public func signingKey(for username: String) async throws -> String }`. It returns the private key PEM. Its stored state is a `Mutex<[String: String]>` (`import Synchronization`) and the loader.

- [ ] **Step 1: Write the failing tests.**

```swift
import Synchronization
import Testing
@testable import ActivityPubCore

@Suite("ActorKeyCache") struct ActorKeyCacheTests {
    @Test func loadsOncePerUsername() async throws {
        let calls = Mutex<[String]>([])
        let cache = ActorKeyCache { username in calls.withLock { $0.append(username) }; return "pem-\(username)" }
        #expect(try await cache.signingKey(for: "a") == "pem-a")
        #expect(try await cache.signingKey(for: "a") == "pem-a")
        #expect(try await cache.signingKey(for: "b") == "pem-b")
        #expect(calls.withLock { $0 } == ["a", "b"])
    }

    @Test func loaderErrorIsNotCached() async throws {
        struct Boom: Error {}
        let calls = Mutex(0)
        let cache = ActorKeyCache { _ in
            if calls.withLock({ $0 += 1; return $0 }) == 1 { throw Boom() }
            return "pem"
        }
        await #expect(throws: Boom.self) { try await cache.signingKey(for: "a") }
        #expect(try await cache.signingKey(for: "a") == "pem")
    }

    @Test func concurrentMissesAgree() async throws {
        let calls = Mutex(0)
        let cache = ActorKeyCache { _ in
            calls.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(50))
            return "pem"
        }
        async let first = cache.signingKey(for: "a")
        async let second = cache.signingKey(for: "a")
        #expect(try await [first, second] == ["pem", "pem"])
        #expect((1...2).contains(calls.withLock { $0 }))
    }
}
```

  The control for `loadsOncePerUsername` is a local edit that is never committed: remove the store step, see `calls == ["a", "a", "b"]`, and record that output.

- [ ] **Step 2: Run.** **Expected:** it fails to compile.

- [ ] **Step 3: Implement** as §0.1, "Signing keys: `ActorKeyCache`" describes.
  - Read inside `withLock`.
  - On a miss, await the loader outside the lock, then store the key inside a second `withLock`.
  - Never hold the lock across an `await`, and never invalidate an entry.

- [ ] **Step 4: Run.** **Expected:** PASS.

- [ ] **Step 5: Commit.** `git commit -m "feat: ActorKeyCache for per-container signing keys"`

---

### Task 13: `KeyManager` and `InboxHandler`

**Files:**
- Modify:
  - `Sources/ActivityPubCore/Crypto/KeyManager.swift`:
    - the file doc comment, `:1-15`, which describes URLSession, the 10 s idle timeout and `FoundationNetworking`;
    - the code, `:27-207`.
  - `Sources/InboxHandler/main.swift`: `:62-90`, `:165-169`, `:197-201`, `:519-528`, `:1731-1739`.
  - `Sources/ActivityPubCore/Documentation.docc/AuthenticationOverview.md:13`.
- Delete: `Tests/ActivityPubCoreTests/RemoteFetch/LegacyFetchControlTests.swift`. Its fixture checks move to `KeyFetchTests.swift`.
- Test: `Tests/ActivityPubCoreTests/RemoteFetch/KeyFetchTests.swift`

**Interfaces:**
- Consumes: `fetchRemoteActor` (the internal overload), `RemoteFetchClient`, `ActorKeyCache`.
- Produces:

  ```swift
  KeyManager {
      let client: RemoteFetchClient
      public init()
      init(client: RemoteFetchClient)
      public func getPublicKey(keyId: String, store: DynamoDBStore, signingKey: (() async throws -> FetchSigningKey)? = nil, deadline: ContinuousClock.Instant) async throws -> String
      public func refreshKey(keyId: String, store: DynamoDBStore, signingKey: (() async throws -> FetchSigningKey)? = nil, deadline: ContinuousClock.Instant) async throws -> String
      func fetchActorDocument(actorUri: String, signingKey: FetchSigningKey? = nil, deadline: ContinuousClock.Instant, schemePolicy: SchemePolicy = .httpsOnly) async throws -> RemoteActor
  }
  ```

  `KeyManagerError` keeps `invalidActorUri` and `missingPublicKey`. It drops `fetchFailed`, `invalidJSON` and `missingInbox`.

- [ ] **Step 1: Write the failing tests.**

```swift
import Foundation
import Testing
@testable import ActivityPubCore

@Suite("Key fetch") struct KeyFetchTests {
    func actorServer() async throws -> TestServer {
        try await TestServer.start { .document(contentType: activityJSON, body: Fixtures.actor(id: Fixtures.selfURL($0))) }
    }

    @Test func keyFetchReturnsKey() async throws {
        let a = try await actorServer()
        try await withTestClient(makeTestClient(admitting: [a.port])) { client in
            let actor = try await KeyManager(client: client).fetchActorDocument(
                actorUri: a.url("/a"), signingKey: nil, deadline: .now + .seconds(10),
                schemePolicy: .allowingHTTP(ports: [a.port]))
            #expect(actor.publicKeyPem == Fixtures.publicKeyPem)
            #expect(actor.inbox == a.url("/a") + "/inbox")
            #expect(actor.sharedInbox == a.url("/a") + "/shared")
            #expect(actor.preferredUsername == "alice")
        }
        await stopAll(a)
    }

    @Test func keyFetchFourRedirectsFails() async throws {
        let d = try await actorServer()
        let chain = try await redirectChain(4, to: d.url("/a"))
        let ports = Set(chain.map(\.port) + [d.port])
        try await withTestClient(makeTestClient(admitting: ports)) { client in
            #expect(await fetchError {
                _ = try await KeyManager(client: client).fetchActorDocument(actorUri: chain[0].url("/hop"),
                    deadline: .now + .seconds(10), schemePolicy: .allowingHTTP(ports: ports))
            }?.name == "tooManyRedirects")
        }
        await stopAll(d); for s in chain { await stopAll(s) }
    }

    @Test func keyFetchOversizeFails() async throws {
        let big = try await TestServer.start { .document(contentType: activityJSON,
            body: Fixtures.padded(Fixtures.actor(id: Fixtures.selfURL($0)), to: 1_048_577)) }
        try await withTestClient(makeTestClient(admitting: [big.port])) { client in
            #expect(await fetchError {
                _ = try await KeyManager(client: client).fetchActorDocument(actorUri: big.url("/a"),
                    deadline: .now + .seconds(10), schemePolicy: .allowingHTTP(ports: [big.port]))
            }?.name == "bodyTooLarge")
        }
        await stopAll(big)
    }

    @Test func actorWithoutPublicKeyFails() async throws {
        let a = try await TestServer.start { .document(contentType: activityJSON,
            body: #"{"id":"\#(Fixtures.selfURL($0))","type":"Person","inbox":"i"}"#) }
        try await withTestClient(makeTestClient(admitting: [a.port])) { client in
            await #expect(throws: KeyManagerError.self) {
                _ = try await KeyManager(client: client).fetchActorDocument(actorUri: a.url("/a"),
                    deadline: .now + .seconds(10), schemePolicy: .allowingHTTP(ports: [a.port]))
            }
        }
        await stopAll(a)
    }
}
```

  The redirect and size tests are controlled by the legacy run Task 3 recorded, where the code before step 0 returned a key in both cases.

- [ ] **Step 2: Run.** **Expected:** compile failures, because the signatures have changed.

- [ ] **Step 3: Implement `KeyManager`.**
  - **`fetchActorDocument`.** It calls `fetchRemoteActor(uri:signer:deadline:schemePolicy:client: self.client)` and builds `RemoteActor(actorUri:publicKeyPem:preferredUsername:inbox:sharedInbox:fetchedAt:)`.
  - **Errors.** It throws `missingPublicKey` when `publicKeyPem` is `nil`, and lets `RemoteFetchError` through unchanged.
  - **Cleanup.** Delete the hand parser (`:139-155`) and the `FoundationNetworking` import.
  - **Deadlines.** `getPublicKey` and `refreshKey` pass `deadline` through.
  - **Docs.** Rewrite the file doc comment (`:1-15`): the fetch goes through `fetchRemoteActor`, with every step 0 control. Update `AuthenticationOverview.md:13` to match.

- [ ] **Step 4: Implement `InboxHandler`.**
  - **The key cache.** Replace `nonisolated(unsafe) var cachedActorKeys` (`:66`) with `let actorKeys = ActorKeyCache { username in … }`. The loader is today's SSM read (`:80-87`) and throws `InboxError.missingActorKey`.
  - **`fetchSigningKey(for:)`.** It returns `FetchSigningKey(keyId:privateKeyPem: try await actorKeys.signingKey(for: username))`.
  - **Deadlines.** Pass `deadline: .now + .seconds(10)` at `:165`, `:197` and `:522`.
  - **The QuoteRequest actor lookup at `:1734`.** Replace `fetchRemoteObject(uri: actorUri)` and `["inbox"] as? String` with `try await fetchRemoteActor(uri: actorUri, signer: try await fetchSigningKey(for: username), deadline: .now + .seconds(10)).inbox`, inside the existing `do/catch`.

- [ ] **Step 5: Run.** `swift test --filter "KeyFetchTests|SignedFetchTests"` and `swift build --product InboxHandler`. **Expected:** the tests pass and the build succeeds.

- [ ] **Step 6: Commit.** `git commit -m "feat: key fetches and QuoteRequest lookups through the hardened client"`

---

### Task 14: `PostHandler` quote path, legacy removal, docs

**Files:**
- Modify:
  - `Sources/PostHandler/main.swift`: `:36-60` and `:262-280`.
  - `Sources/ActivityPubCore/FetchRemoteObject.swift`:
    - the file doc comment, `:1-12`, which describes URLSession, the 10 s timeout and that the request is unsigned;
    - the legacy `fetchRemoteObject(uri:)` and `FetchRemoteObjectError`, `:14-58`, which are deleted.
  - `Sources/ActivityPubCore/Documentation.docc/ActivityPubCore.md:64-75`.

**Interfaces:**
- Consumes: `fetchRemoteObject(uri:signer:deadline:)`, `fetchRemoteActor(uri:signer:deadline:)`, `ActorKeyCache`.

- [ ] **Step 1: Implement `PostHandler`.**
  - **The key cache.** Add `let actorKeys = ActorKeyCache { username in … }`, reading SSM `"\(ssmKeyPrefix)/\(username)"`. PostFunction already reads `activity/${Stage}/*` (`activity-app/functions/template.yaml:134-135`). The stage-prefix fallback at `:33` is FederatedActivityPublisher#295 and is left as it is.
  - **The signer.** Inside the existing `do` at `:263`: `let signer = FetchSigningKey(keyId: "https://\(serverDomain)/users/\(username)#main-key", privateKeyPem: try await actorKeys.signingKey(for: username))`.
  - **The fetches.**
    - `fetchRemoteObject(uri: quotedId, signer: signer, deadline: .now + .seconds(10)).attributedTo`.
    - On a `REMOTE_ACTOR#` miss: `fetchRemoteActor(uri: attributedTo, signer: signer, deadline: .now + .seconds(10)).inbox`.
  - **The `failed` path** (`:284-287`) is unchanged.

- [ ] **Step 2: Remove the legacy fetch.** Delete the legacy function and error, and rewrite the file doc comment.
  - Check: `grep -rn "FetchRemoteObjectError\|URLSession" Sources/ActivityPubCore`.
  - **Expected:** no hits.

- [ ] **Step 3: Docs.**
  - Under "Authentication and Cryptography", add `ActorKeyCache`.
  - Add a "Remote Fetch" topic group with `fetchRemoteObject(uri:signer:deadline:)`, `fetchRemoteActor(uri:signer:deadline:)`, `RemoteObjectDocument`, `RemoteActorDocument` and `RemoteFetchError`.

- [ ] **Step 4: CI.** The Test job (`.github/workflows/test.yml:65`). **Expected:** green on Linux.

- [ ] **Step 5: Commit.** `git commit -m "feat: signed, hardened quote-path fetches; drop the URLSession fetch"`

---

### Task 15: Lambda build (C4) and the implementation PR

**Files:** none in the repository, apart from the throwaway commit in Step 2, which is reverted.

- [ ] **Step 1: C4, the build half, before merge.**
  - Mark the PR ready and add the `lambda-build` label.
  - **Expected:** the Lambda Build job is green:
    - `scripts/build-all-lambdas.sh` compiles every product in `swift-al2023:6.3` against the committed pins;
    - the "Package.resolved unchanged by the build" step passes;
    - `scripts/verify-lambda-zips.sh` passes.

- [ ] **Step 2: The control for Step 1.**
  1. Push a commit that adds `config.notARealSetting = true` in `RemoteFetchClient.make`, and add the `lambda-build` label again.
  2. **Expected:** the job goes red at the build phase, and the error names that line.
  3. Revert with a new commit and run the job again until it is green.
  - Record both run URLs.

- [ ] **Step 3: The PR description.** It includes:
  - the Task 1 tables: every pin that changed, and every cited line re-checked;
  - what every negative control showed (Tasks 2–13), the construction control's run URL (Task 4), and both Lambda Build run URLs;
  - "Refs FederatedActivityPublisher#280" and "Refs FederatedActivityPublisher#292", with no closing keywords;
  - draft release notes naming every behaviour change in §0.3 of the spec:
    - the quote path's new refusals, and its signing;
    - the inbound key fetch's checks and its absolute deadline;
    - typed documents, with both of their consequences;
    - no connection retries.

- [ ] **Step 4: Review.** Request review the way the repository requires, and don't merge without it.

- [ ] **Step 5: C4, the runtime half, after merge.**
  - **What runs.** The `deploy-stage` run for the merge commit builds and deploys every handler.
  - **Pass.** On stage, an inbound delivery verifies when it is signed by an actor not cached in `REMOTE_ACTOR#` (a first Follow from a remote account, for example). That key fetch ran on AHC in the deployed binary.
  - **Fail.** A handler fails to start, or that key fetch fails with `transportFailed`. Fix forward.
  - **Release.** No prod release containing step 0 is cut until this has passed (spec, §0.2, "Release").
