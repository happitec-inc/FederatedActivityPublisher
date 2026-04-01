# Phase 6: Passkey Web Posting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Web-based posting at `happitec.com/compose` where operators authenticate with passkeys (WebAuthn) and publish posts through the existing Mastodon-compatible API endpoints.

**Architecture:** Two new Lambda handlers (AuthHandler, ComposeHandler), JWT session cookies, dual auth migration in BearerAuth.swift, DynamoDB passkey/challenge/token entities, Elementary + latex.css UI.

**Tech Stack:** Swift 6.3, swift-crypto, webauthn-swift (swift-server), Elementary, AWS Lambda, DynamoDB, SSM, API Gateway, CloudFront

**Spec:** `docs/superpowers/specs/2026-03-31-phase6-passkey-web-posting-design.md`

---

## Task 1: OpenAPI spec updates (new endpoints)

Add the Phase 6 auth and compose endpoints to `openapi.yaml` so the generated `APIClient` can be used for integration tests.

- [ ] Add `cookieAuth` security scheme to `components/securitySchemes`:

```yaml
cookieAuth:
  type: apiKey
  in: cookie
  name: session
  description: JWT session token issued after passkey authentication
```

- [ ] Add auth challenge endpoint:

```yaml
/api/internal/auth/challenge:
  post:
    operationId: createAuthChallenge
    summary: Generate WebAuthn assertion challenge
    tags: [auth]
    description: |
      Returns a random challenge for WebAuthn authentication.
      The challenge is stored in DynamoDB with a 5-minute TTL.
    responses:
      "200":
        description: Authentication challenge
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/AuthChallenge"
```

- [ ] Add auth verify endpoint:

```yaml
/api/internal/auth/verify:
  post:
    operationId: verifyAuth
    summary: Verify WebAuthn assertion and issue session
    tags: [auth]
    requestBody:
      required: true
      content:
        application/json:
          schema:
            $ref: "#/components/schemas/AuthVerifyRequest"
    responses:
      "200":
        description: Authentication successful (Set-Cookie header included)
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/AuthVerifyResponse"
      "401":
        description: Invalid credential or challenge
```

- [ ] Add registration challenge endpoint:

```yaml
/api/internal/passkeys/register-challenge:
  post:
    operationId: createRegistrationChallenge
    summary: Generate WebAuthn creation challenge
    tags: [auth]
    requestBody:
      required: true
      content:
        application/json:
          schema:
            type: object
            required: [token]
            properties:
              token:
                type: string
    responses:
      "200":
        description: Registration challenge (WebAuthn creation options)
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/RegistrationChallenge"
      "401":
        description: Invalid or expired registration token
```

- [ ] Add register passkey endpoint:

```yaml
/api/internal/passkeys/register:
  post:
    operationId: registerPasskey
    summary: Store new passkey credential
    tags: [auth]
    requestBody:
      required: true
      content:
        application/json:
          schema:
            $ref: "#/components/schemas/RegisterPasskeyRequest"
    responses:
      "200":
        description: Passkey registered
        content:
          application/json:
            schema:
              type: object
              properties:
                ok:
                  type: boolean
      "401":
        description: Invalid token, challenge, or credential
```

- [ ] Add compose page endpoint:

```yaml
/compose:
  get:
    operationId: getComposePage
    summary: Compose page (requires session)
    tags: [web]
    security:
      - cookieAuth: []
    responses:
      "200":
        description: Compose page HTML
        content:
          text/html:
            schema:
              type: string
      "302":
        description: Redirect to /auth/login (no valid session)
```

- [ ] Add schema definitions for `AuthChallenge`, `AuthVerifyRequest`, `AuthVerifyResponse`, `RegistrationChallenge`, `RegisterPasskeyRequest`:

```yaml
AuthChallenge:
  type: object
  required: [challengeId, challenge, rpId, timeout, userVerification]
  properties:
    challengeId:
      type: string
    challenge:
      type: string
      description: Base64url-encoded random bytes
    rpId:
      type: string
    timeout:
      type: integer
    userVerification:
      type: string

AuthVerifyRequest:
  type: object
  required: [challengeId, credential]
  properties:
    challengeId:
      type: string
    credential:
      $ref: "#/components/schemas/WebAuthnCredential"

AuthVerifyResponse:
  type: object
  properties:
    ok:
      type: boolean
    username:
      type: string

RegistrationChallenge:
  type: object
  required: [challenge, rp, user, pubKeyCredParams, timeout, attestation, authenticatorSelection]
  properties:
    challenge:
      type: string
    rp:
      type: object
      properties:
        name:
          type: string
        id:
          type: string
    user:
      type: object
      properties:
        id:
          type: string
        name:
          type: string
        displayName:
          type: string
    pubKeyCredParams:
      type: array
      items:
        type: object
        properties:
          type:
            type: string
          alg:
            type: integer
    timeout:
      type: integer
    attestation:
      type: string
    authenticatorSelection:
      type: object
      properties:
        residentKey:
          type: string
        userVerification:
          type: string

RegisterPasskeyRequest:
  type: object
  required: [token, challengeId, credential]
  properties:
    token:
      type: string
    challengeId:
      type: string
    credential:
      $ref: "#/components/schemas/WebAuthnCredential"

WebAuthnCredential:
  type: object
  required: [id, rawId, type, response]
  properties:
    id:
      type: string
    rawId:
      type: string
    type:
      type: string
    response:
      type: object
      description: AttestationResponse or AssertionResponse depending on context
      additionalProperties: true
```

- [ ] Copy updated `openapi.yaml` to `Sources/APIClient/openapi.yaml` (symlink or copy, matching existing pattern)
- [ ] Build on linux-runner-3 to verify generated client compiles

**Files:** `openapi.yaml`, `Sources/APIClient/openapi.yaml`

**Build verification:**
```bash
sshpass -p admin scp -o StrictHostKeyChecking=no openapi.yaml admin@$(tart ip linux-runner-3):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/openapi.yaml
sshpass -p admin scp -o StrictHostKeyChecking=no openapi.yaml admin@$(tart ip linux-runner-3):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Sources/APIClient/openapi.yaml
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner-3) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

---

## Task 2: DynamoDB schema (passkey entities in DynamoDBStore)

Add passkey, challenge, and registration token operations to `DynamoDBStore.swift`.

- [ ] Add `MARK: - Passkey Storage` section with these methods:

```swift
// MARK: - Passkey Storage

/// Store a passkey credential after successful WebAuthn registration.
public func storePasskey(
    credentialId: String,
    username: String,
    publicKey: String,
    publicKeyAlg: Int,
    signCount: Int
) async throws {
    let now = iso8601Formatter.string(from: Date())
    let item: [String: DynamoDBClientTypes.AttributeValue] = [
        "PK": .s("PASSKEY#\(credentialId)"),
        "SK": .s("META"),
        "username": .s(username),
        "publicKey": .s(publicKey),
        "publicKeyAlg": .n(String(publicKeyAlg)),
        "signCount": .n(String(signCount)),
        "createdAt": .s(now),
        "lastUsedAt": .s(now),
    ]
    let input = PutItemInput(
        conditionExpression: "attribute_not_exists(PK)",
        item: item,
        tableName: tableName
    )
    _ = try await client.putItem(input: input)
}

/// Fetch a passkey credential by credential ID. Returns nil if not found.
public func getPasskey(credentialId: String) async throws -> PasskeyCredential? {
    let input = GetItemInput(
        key: [
            "PK": .s("PASSKEY#\(credentialId)"),
            "SK": .s("META"),
        ],
        tableName: tableName
    )
    let output = try await client.getItem(input: input)
    guard let item = output.item else { return nil }
    return PasskeyCredential.fromDynamoDB(item)
}

/// Update sign count and lastUsedAt after successful authentication.
public func updatePasskeySignCount(credentialId: String, signCount: Int) async throws {
    let now = iso8601Formatter.string(from: Date())
    let input = UpdateItemInput(
        expressionAttributeNames: ["#sc": "signCount", "#lu": "lastUsedAt"],
        expressionAttributeValues: [":sc": .n(String(signCount)), ":lu": .s(now)],
        key: [
            "PK": .s("PASSKEY#\(credentialId)"),
            "SK": .s("META"),
        ],
        tableName: tableName,
        updateExpression: "SET #sc = :sc, #lu = :lu"
    )
    _ = try await client.updateItem(input: input)
}
```

- [ ] Add `MARK: - WebAuthn Challenges` section:

```swift
// MARK: - WebAuthn Challenges

/// Store a WebAuthn challenge with a 5-minute TTL.
public func storeChallenge(
    challengeId: String,
    challenge: String,
    type: String,
    username: String?
) async throws {
    let ttl = Int(Date().timeIntervalSince1970) + 300 // 5 minutes
    var item: [String: DynamoDBClientTypes.AttributeValue] = [
        "PK": .s("PASSKEY_CHALLENGE#\(challengeId)"),
        "SK": .s("META"),
        "challenge": .s(challenge),
        "type": .s(type),
        "TTL": .n(String(ttl)),
    ]
    if let username {
        item["username"] = .s(username)
    }
    let input = PutItemInput(item: item, tableName: tableName)
    _ = try await client.putItem(input: input)
}

/// Fetch and delete a challenge atomically (prevents replay).
public func consumeChallenge(challengeId: String) async throws -> ChallengeRecord? {
    let input = DeleteItemInput(
        conditionExpression: "attribute_exists(PK)",
        key: [
            "PK": .s("PASSKEY_CHALLENGE#\(challengeId)"),
            "SK": .s("META"),
        ],
        returnValues: .allOld,
        tableName: tableName
    )
    do {
        let output = try await client.deleteItem(input: input)
        guard let item = output.attributes else { return nil }
        return ChallengeRecord.fromDynamoDB(item)
    } catch is ConditionalCheckFailedException {
        return nil
    }
}
```

- [ ] Add `MARK: - Registration Tokens` section:

```swift
// MARK: - Registration Tokens

/// Store a one-time registration token with 15-minute TTL.
public func storeRegistrationToken(token: String, username: String) async throws {
    let ttl = Int(Date().timeIntervalSince1970) + 900 // 15 minutes
    let item: [String: DynamoDBClientTypes.AttributeValue] = [
        "PK": .s("REGISTRATION_TOKEN#\(token)"),
        "SK": .s("META"),
        "username": .s(username),
        "TTL": .n(String(ttl)),
    ]
    let input = PutItemInput(item: item, tableName: tableName)
    _ = try await client.putItem(input: input)
}

/// Validate a registration token (read-only, does not consume it).
public func getRegistrationToken(token: String) async throws -> RegistrationToken? {
    let input = GetItemInput(
        key: [
            "PK": .s("REGISTRATION_TOKEN#\(token)"),
            "SK": .s("META"),
        ],
        tableName: tableName
    )
    let output = try await client.getItem(input: input)
    guard let item = output.item else { return nil }

    // Check TTL manually (DynamoDB TTL deletion is eventually consistent)
    if case .n(let ttlStr) = item["TTL"], let ttl = Int(ttlStr) {
        if ttl < Int(Date().timeIntervalSince1970) { return nil }
    }

    guard case .s(let username) = item["username"] else { return nil }
    return RegistrationToken(token: token, username: username)
}

/// Atomically consume (delete) a registration token. Returns the token if it existed.
/// Uses conditional delete to prevent race conditions with concurrent tabs.
public func consumeRegistrationToken(token: String) async throws -> RegistrationToken? {
    let input = DeleteItemInput(
        conditionExpression: "attribute_exists(PK)",
        key: [
            "PK": .s("REGISTRATION_TOKEN#\(token)"),
            "SK": .s("META"),
        ],
        returnValues: .allOld,
        tableName: tableName
    )
    do {
        let output = try await client.deleteItem(input: input)
        guard let item = output.attributes,
              case .s(let username) = item["username"] else { return nil }
        return RegistrationToken(token: token, username: username)
    } catch is ConditionalCheckFailedException {
        return nil
    }
}
```

- [ ] Add model types to `Sources/ActivityPubCore/Models/`:

```swift
// Sources/ActivityPubCore/Models/PasskeyCredential.swift
public struct PasskeyCredential: Sendable {
    public let credentialId: String
    public let username: String
    public let publicKey: String
    public let publicKeyAlg: Int
    public let signCount: Int
    public let createdAt: String
    public let lastUsedAt: String

    public static func fromDynamoDB(_ item: [String: DynamoDBClientTypes.AttributeValue]) -> PasskeyCredential? {
        guard case .s(let pk) = item["PK"],
              pk.hasPrefix("PASSKEY#"),
              case .s(let username) = item["username"],
              case .s(let publicKey) = item["publicKey"],
              case .n(let algStr) = item["publicKeyAlg"], let alg = Int(algStr),
              case .n(let scStr) = item["signCount"], let sc = Int(scStr),
              case .s(let createdAt) = item["createdAt"],
              case .s(let lastUsedAt) = item["lastUsedAt"]
        else { return nil }
        let credentialId = String(pk.dropFirst("PASSKEY#".count))
        return PasskeyCredential(
            credentialId: credentialId, username: username,
            publicKey: publicKey, publicKeyAlg: alg, signCount: sc,
            createdAt: createdAt, lastUsedAt: lastUsedAt
        )
    }
}

// Sources/ActivityPubCore/Models/ChallengeRecord.swift
public struct ChallengeRecord: Sendable {
    public let challengeId: String
    public let challenge: String
    public let type: String // "registration" or "authentication"
    public let username: String?

    public static func fromDynamoDB(_ item: [String: DynamoDBClientTypes.AttributeValue]) -> ChallengeRecord? {
        guard case .s(let pk) = item["PK"],
              pk.hasPrefix("PASSKEY_CHALLENGE#"),
              case .s(let challenge) = item["challenge"],
              case .s(let type) = item["type"]
        else { return nil }
        let challengeId = String(pk.dropFirst("PASSKEY_CHALLENGE#".count))
        var username: String?
        if case .s(let u) = item["username"] { username = u }
        return ChallengeRecord(challengeId: challengeId, challenge: challenge, type: type, username: username)
    }
}

// Sources/ActivityPubCore/Models/RegistrationToken.swift
public struct RegistrationToken: Sendable {
    public let token: String
    public let username: String
}
```

- [ ] Build on linux-runner-3

**Files:** `Sources/ActivityPubCore/DynamoDBStore.swift`, `Sources/ActivityPubCore/Models/PasskeyCredential.swift`, `Sources/ActivityPubCore/Models/ChallengeRecord.swift`, `Sources/ActivityPubCore/Models/RegistrationToken.swift`

**Build verification:**
```bash
sshpass -p admin scp -o StrictHostKeyChecking=no -r Sources/ActivityPubCore/ admin@$(tart ip linux-runner-3):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Sources/ActivityPubCore/
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner-3) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

---

## Task 3: JWT signing/verification utility (ActivityPubCore)

Add `JWTSession.swift` to `Sources/ActivityPubCore/` for stateless JWT session management.

- [ ] Create `Sources/ActivityPubCore/JWTSession.swift`:

```swift
import Crypto
import Foundation

/// Stateless JWT session token management using HMAC-SHA256.
public struct JWTSession: Sendable {

    /// JWT claims for a session token.
    public struct Claims: Codable, Sendable {
        public let sub: String
        public let iat: Int
        public let exp: Int
        public let iss: String

        public init(sub: String, iss: String, duration: TimeInterval = 86400) {
            self.sub = sub
            self.iat = Int(Date().timeIntervalSince1970)
            self.exp = self.iat + Int(duration)
            self.iss = iss
        }
    }

    /// Sign a JWT with HMAC-SHA256.
    /// Returns the complete JWT string (header.payload.signature).
    public static func sign(claims: Claims, key: String) throws -> String {
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        let encoder = JSONEncoder()
        let payloadData = try encoder.encode(claims)

        let headerB64 = base64urlEncode(Data(header.utf8))
        let payloadB64 = base64urlEncode(payloadData)
        let signingInput = "\(headerB64).\(payloadB64)"

        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(signingInput.utf8),
            using: symmetricKey
        )
        let signatureB64 = base64urlEncode(Data(signature))
        return "\(signingInput).\(signatureB64)"
    }

    /// Verify a JWT and return its claims.
    /// Throws if the signature is invalid, the token is expired, or the issuer is wrong.
    public static func verify(jwt: String, key: String, expectedIssuer: String) throws -> Claims {
        let parts = jwt.split(separator: ".", maxSplits: 2)
        guard parts.count == 3 else {
            throw JWTError.malformed
        }
        let headerB64 = String(parts[0])
        let payloadB64 = String(parts[1])
        let signatureB64 = String(parts[2])

        // Verify signature
        let signingInput = "\(headerB64).\(payloadB64)"
        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        guard let signatureData = base64urlDecode(signatureB64) else {
            throw JWTError.malformed
        }
        guard HMAC<SHA256>.isValidAuthenticationCode(
            signatureData,
            authenticating: Data(signingInput.utf8),
            using: symmetricKey
        ) else {
            throw JWTError.invalidSignature
        }

        // Decode payload
        guard let payloadData = base64urlDecode(payloadB64) else {
            throw JWTError.malformed
        }
        let decoder = JSONDecoder()
        let claims = try decoder.decode(Claims.self, from: payloadData)

        // Check expiry
        guard claims.exp > Int(Date().timeIntervalSince1970) else {
            throw JWTError.expired
        }

        // Check issuer
        guard claims.iss == expectedIssuer else {
            throw JWTError.invalidIssuer
        }

        return claims
    }

    /// Derive a CSRF token from the signing key and session claims.
    /// HMAC-SHA256(key: signingKey, message: sub + iat), truncated to 32 hex chars.
    public static func csrfToken(signingKey: String, sub: String, iat: Int) -> String {
        let key = SymmetricKey(data: Data(signingKey.utf8))
        let message = "\(sub)\(iat)"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: key
        )
        return Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Verify a CSRF token against the expected value.
    public static func verifyCSRF(token: String, signingKey: String, sub: String, iat: Int) -> Bool {
        let expected = csrfToken(signingKey: signingKey, sub: sub, iat: iat)
        // Constant-time comparison
        guard token.count == expected.count else { return false }
        var result: UInt8 = 0
        for (a, b) in zip(token.utf8, expected.utf8) {
            result |= a ^ b
        }
        return result == 0
    }
}

public enum JWTError: Error, Sendable {
    case malformed
    case invalidSignature
    case expired
    case invalidIssuer
}

// MARK: - Base64URL helpers

func base64urlEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func base64urlDecode(_ string: String) -> Data? {
    var base64 = string
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 {
        base64 += "="
    }
    return Data(base64Encoded: base64)
}
```

- [ ] Build on linux-runner-3

**Files:** `Sources/ActivityPubCore/JWTSession.swift`

**Build verification:**
```bash
sshpass -p admin scp -o StrictHostKeyChecking=no Sources/ActivityPubCore/JWTSession.swift admin@$(tart ip linux-runner-3):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Sources/ActivityPubCore/JWTSession.swift
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner-3) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

---

## Task 4: WebAuthn challenge/verify endpoints (AuthHandler)

Add the AuthHandler Lambda with WebAuthn challenge generation and verification.

### Task 4a: Evaluate webauthn-swift library

- [ ] Add `webauthn-swift` dependency to `Package.swift`:

```swift
.package(url: "https://github.com/swift-server/webauthn-swift.git", from: "1.0.0"),
```

- [ ] Build on linux-runner-3 to verify it compiles with Swift 6.3 on Linux
- [ ] If it fails to compile or has API issues, fall back to the hand-rolled CBOR approach described in the spec (create `Sources/ActivityPubCore/WebAuthn/CBORDecoder.swift`, `WebAuthnRegistration.swift`, `WebAuthnAuthentication.swift`, `WebAuthnTypes.swift`)

### Task 4b: Create AuthHandler target

- [ ] Add AuthHandler executable target to `Package.swift`:

```swift
.executableTarget(
    name: "AuthHandler",
    dependencies: [
        "ActivityPubCore",
        .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
        .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
        .product(name: "AWSSSM", package: "aws-sdk-swift"),
        .product(name: "Elementary", package: "elementary"),
        .product(name: "WebAuthn", package: "webauthn-swift"),  // or remove if hand-rolling
    ]
),
```

- [ ] Add to `products` array: `.executable(name: "AuthHandler", targets: ["AuthHandler"])`

- [ ] Create `Sources/AuthHandler/main.swift` with route dispatch:

```swift
import AWSLambdaEvents
import AWSLambdaRuntime
import AWSSSM
import ActivityPubCore
import Foundation

guard let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] else {
    fatalError("SERVER_DOMAIN environment variable is required")
}
let ssmKeyPrefixRaw = ProcessInfo.processInfo.environment["SSM_KEY_PREFIX"] ?? "/activity/stage/keys/"
let ssmKeyPrefix = ssmKeyPrefixRaw.hasSuffix("/") ? String(ssmKeyPrefixRaw.dropLast()) : ssmKeyPrefixRaw

let store = try await DynamoDBStore()
let ssmClient = try await SSMClient()

/// Cached signing key -- initialized once per Lambda cold start.
var cachedSigningKey: String?

func getSigningKey() async throws -> String {
    if let key = cachedSigningKey { return key }
    let output = try await ssmClient.getParameter(input: .init(
        name: "\(ssmKeyPrefix)/session-signing-key",
        withDecryption: true
    ))
    guard let key = output.parameter?.value else {
        fatalError("Session signing key not configured at \(ssmKeyPrefix)/session-signing-key")
    }
    cachedSigningKey = key
    return key
}

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    let path = event.path
    let method = event.httpMethod

    do {
        switch (method, path) {
        case (.GET, "/auth/login"):
            return renderLoginPage()
        case (.GET, "/auth/register"):
            return try await handleRegisterPage(event: event)
        case (.POST, "/api/internal/auth/challenge"):
            return try await handleAuthChallenge()
        case (.POST, "/api/internal/auth/verify"):
            return try await handleAuthVerify(event: event, context: context)
        case (.POST, "/api/internal/passkeys/register-challenge"):
            return try await handleRegisterChallenge(event: event)
        case (.POST, "/api/internal/passkeys/register"):
            return try await handleRegisterPasskey(event: event, context: context)
        default:
            return APIGatewayResponse(statusCode: .notFound, body: "Not Found")
        }
    } catch {
        context.logger.error("AuthHandler error: \(error)")
        return APIGatewayResponse(
            statusCode: .internalServerError,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Internal server error"}"#
        )
    }
}

try await runtime.run()
```

- [ ] Implement `handleAuthChallenge()` -- generate random challenge, store in DynamoDB, return JSON
- [ ] Implement `handleAuthVerify()` -- consume challenge, look up passkey, verify clientDataJSON (origin = `https://{SERVER_DOMAIN}`, type = `webauthn.get`), verify signature, verify sign count, update passkey, issue JWT cookie
- [ ] Implement `handleRegisterChallenge()` -- validate registration token (read-only), generate challenge, store in DynamoDB, return WebAuthn creation options
- [ ] Implement `handleRegisterPasskey()` -- consume challenge, atomically consume registration token, parse attestation, validate clientDataJSON (origin, type = `webauthn.create`), extract public key, store passkey in DynamoDB
- [ ] Build on linux-runner-3

**Files:** `Package.swift`, `Sources/AuthHandler/main.swift`

---

## Task 5: Passkey registration flow (AuthHandler + CLI)

### Task 5a: Registration page HTML

- [ ] Implement `renderRegisterPage()` and `handleRegisterPage()` in AuthHandler
- [ ] Elementary HTML page with:
  - "Register a passkey" heading
  - Status text showing username from the token
  - "Register passkey" button
  - Vanilla JS (~50 lines): calls register-challenge endpoint, triggers `navigator.credentials.create()`, sends attestation to register endpoint, shows success/failure message with link to `/auth/login`
- [ ] Error page for invalid/expired token (401 with HTML)

### Task 5b: CLI register-passkey command

- [ ] Add `RegisterPasskey` subcommand to `Sources/ActivityProvisioner/`:

```swift
import ArgumentParser
import AWSDynamoDB
import ActivityPubCore
import Foundation

struct RegisterPasskey: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "register-passkey",
        abstract: "Generate a one-time passkey registration URL"
    )

    @Option(help: "Actor username")
    var username: String

    @Option(help: "Server domain")
    var domain: String = "happitec.com"

    mutating func run() async throws {
        let store = try await DynamoDBStore()

        // Verify actor exists
        guard try await store.actorExists(username: username) else {
            print("Error: Actor '\(username)' does not exist.")
            throw ExitCode.failure
        }

        // Generate token (32 random bytes, hex-encoded)
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        // Store in DynamoDB
        try await store.storeRegistrationToken(token: token, username: username)

        let url = "https://\(domain)/auth/register?token=\(token)"
        print("Registration URL (expires in 15 minutes):")
        print(url)
    }
}
```

- [ ] Register the subcommand in the main CLI entry point
- [ ] Build on linux-runner-3

**Files:** `Sources/AuthHandler/main.swift` (registration pages), `Sources/ActivityProvisioner/RegisterPasskey.swift`

---

## Task 6: Passkey authentication flow (AuthHandler)

- [ ] Implement `renderLoginPage()` -- Elementary HTML with:
  - "Sign in to Happitec" heading
  - "Sign in with passkey" button
  - Vanilla JS (~40 lines): calls `/api/internal/auth/challenge`, triggers `navigator.credentials.get()`, sends assertion to `/api/internal/auth/verify`, on success redirects to `/compose`
- [ ] The `handleAuthVerify()` endpoint (from Task 4) sets the session cookie:
  - `Set-Cookie: session={jwt}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=86400`
  - Returns JSON `{"ok": true, "username": "..."}`
- [ ] Build on linux-runner-3

**Files:** `Sources/AuthHandler/main.swift`

---

## Task 7: Dual auth migration (BearerAuth.swift)

Extend `BearerAuth.swift` to support both bearer token and JWT session cookie authentication.

- [ ] Add new types to `Sources/ActivityPubCore/BearerAuth.swift`:

```swift
/// The method used for authentication.
public enum AuthMethod: Sendable {
    case bearer
    case session
}

/// Extended auth result that includes the method used.
public struct RequestAuthResult: Sendable {
    public let username: String
    public let method: AuthMethod

    public init(username: String, method: AuthMethod) {
        self.username = username
        self.method = method
    }
}
```

- [ ] Add `sessionExpired` case to `BearerAuthError`
- [ ] Add `authenticateRequest` function:

```swift
/// Authenticate a request using either bearer token or session cookie.
///
/// Checks Authorization header first (bearer token), then falls back to
/// session cookie (JWT). Returns the auth method used so callers can vary
/// response format (401 JSON for API clients, 302 redirect for browsers).
public func authenticateRequest(
    authHeader: String,
    cookies: String?,
    ssmKeyPrefix: String,
    ssmClient: SSMClient,
    signingKey: String,
    serverDomain: String
) async throws -> RequestAuthResult {
    // 1. Try bearer token first
    if authHeader.lowercased().hasPrefix("bearer ") {
        let result = try await authenticateBearer(
            authHeader: authHeader,
            ssmKeyPrefix: ssmKeyPrefix,
            ssmClient: ssmClient
        )
        return RequestAuthResult(username: result.username, method: .bearer)
    }

    // 2. Try session cookie
    if let cookies, let sessionJWT = extractCookie(name: "session", from: cookies) {
        do {
            let claims = try JWTSession.verify(
                jwt: sessionJWT,
                key: signingKey,
                expectedIssuer: serverDomain
            )
            return RequestAuthResult(username: claims.sub, method: .session)
        } catch JWTError.expired {
            throw BearerAuthError.sessionExpired
        } catch {
            throw BearerAuthError.invalidToken
        }
    }

    // 3. Neither method present
    throw BearerAuthError.missingHeader
}

/// Extract a named cookie value from a Cookie header string.
func extractCookie(name: String, from cookieHeader: String) -> String? {
    let pairs = cookieHeader.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    for pair in pairs {
        let parts = pair.split(separator: "=", maxSplits: 1)
        if parts.count == 2 && parts[0] == name {
            return String(parts[1])
        }
    }
    return nil
}
```

- [ ] Update `Sources/PostHandler/main.swift` to use `authenticateRequest` instead of `authenticateBearer`:
  - Pass `event.headers["cookie"]` or `event.headers["Cookie"]`
  - On `.session` method auth, verify CSRF token for POST requests: check `X-CSRF-Token` header
  - On `sessionExpired` error: check Accept header, return 302 redirect if `text/html`, else 401 JSON
  - On `missingHeader`: same Accept-header-based response

- [ ] Update `Sources/MediaUploadHandler/main.swift` with the same dual-auth pattern

- [ ] Build on linux-runner-3

**Files:** `Sources/ActivityPubCore/BearerAuth.swift`, `Sources/PostHandler/main.swift`, `Sources/MediaUploadHandler/main.swift`

**Build verification:**
```bash
sshpass -p admin scp -o StrictHostKeyChecking=no -r Sources/ admin@$(tart ip linux-runner-3):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Sources/
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner-3) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

---

## Task 8: Compose page (ComposeHandler, Elementary + vanilla JS)

- [ ] Add ComposeHandler executable target to `Package.swift`:

```swift
.executableTarget(
    name: "ComposeHandler",
    dependencies: [
        "ActivityPubCore",
        .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
        .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
        .product(name: "AWSSSM", package: "aws-sdk-swift"),
        .product(name: "Elementary", package: "elementary"),
    ]
),
```

- [ ] Add to `products` array: `.executable(name: "ComposeHandler", targets: ["ComposeHandler"])`

- [ ] Create `Sources/ComposeHandler/main.swift`:

```swift
import AWSLambdaEvents
import AWSLambdaRuntime
import AWSSSM
import ActivityPubCore
import Elementary
import Foundation

guard let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] else {
    fatalError("SERVER_DOMAIN environment variable is required")
}
let ssmKeyPrefixRaw = ProcessInfo.processInfo.environment["SSM_KEY_PREFIX"] ?? "/activity/stage/keys/"
let ssmKeyPrefix = ssmKeyPrefixRaw.hasSuffix("/") ? String(ssmKeyPrefixRaw.dropLast()) : ssmKeyPrefixRaw

let ssmClient = try await SSMClient()

/// Cached signing key
var cachedSigningKey: String?

func getSigningKey() async throws -> String {
    if let key = cachedSigningKey { return key }
    let output = try await ssmClient.getParameter(input: .init(
        name: "\(ssmKeyPrefix)/session-signing-key",
        withDecryption: true
    ))
    guard let key = output.parameter?.value else {
        fatalError("Session signing key not configured")
    }
    cachedSigningKey = key
    return key
}

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    do {
        let signingKey = try await getSigningKey()
        let cookies = event.headers["cookie"] ?? event.headers["Cookie"] ?? ""

        guard let sessionJWT = extractCookie(name: "session", from: cookies) else {
            return redirectToLogin()
        }

        let claims: JWTSession.Claims
        do {
            claims = try JWTSession.verify(jwt: sessionJWT, key: signingKey, expectedIssuer: serverDomain)
        } catch {
            return redirectToLogin()
        }

        let csrfToken = JWTSession.csrfToken(signingKey: signingKey, sub: claims.sub, iat: claims.iat)
        let page = ComposePage(username: claims.sub, csrfToken: csrfToken, domain: serverDomain)
        let html = page.render()

        return APIGatewayResponse(
            statusCode: .ok,
            headers: [
                "content-type": "text/html; charset=utf-8",
                "cache-control": "no-store",
            ],
            body: html
        )
    } catch {
        context.logger.error("ComposeHandler error: \(error)")
        return redirectToLogin()
    }
}

func redirectToLogin() -> APIGatewayResponse {
    APIGatewayResponse(
        statusCode: .found,
        headers: ["location": "/auth/login"],
        body: nil
    )
}

try await runtime.run()
```

- [ ] Create `ComposePage` struct conforming to `HTMLDocument` (Elementary):
  - Header with site name, logged-in username, logout link
  - `<meta name="csrf-token" content="{token}">` in head
  - Text area with character count (5000 max, live counter)
  - File input for image upload (drag-and-drop via JS)
  - Alt text field (appears after image selected)
  - Image preview (client-side `URL.createObjectURL()`)
  - Visibility selector (public/unlisted/followers-only radio buttons)
  - Content warning toggle + spoiler text input
  - "Post" button (disabled when over character limit or during submission)
  - Client-side file size check (reject > 5.5MB before upload attempt)

- [ ] Create inline vanilla JS (~150 lines) for:
  - Reading CSRF token from meta tag
  - Image upload via `POST /api/v2/media` with `fetch()` + multipart/form-data
  - Status posting via `POST /api/v1/statuses` with `fetch()` + JSON body
  - `X-CSRF-Token` header on all fetch requests
  - Character count updates on input
  - Image preview and remove
  - Success confirmation with link to new post
  - Error display inline

- [ ] Build on linux-runner-3

**Files:** `Package.swift`, `Sources/ComposeHandler/main.swift`

---

## Task 9: SAM template + Package.swift changes

Update the SAM template with new Lambda functions, CloudFront behaviors, and origin request policy.

- [ ] Add `AuthFunction` resource to `activity-app/template.yaml`:

```yaml
AuthFunction:
  Type: AWS::Serverless::Function
  Properties:
    FunctionName: !Sub "activity-app-auth-${Stage}"
    CodeUri: ../.build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager/AuthHandler/AuthHandler.zip
    Timeout: 30
    Policies:
      - DynamoDBCrudPolicy:
          TableName: !ImportValue
            Fn::Sub: "${EnvironmentStackName}-TableName"
      - SSMParameterReadPolicy:
          ParameterName: !Sub "activity/${Stage}/*"
      - Statement:
          - Effect: Allow
            Action: kms:Decrypt
            Resource: !Sub "arn:aws:kms:${AWS::Region}:${AWS::AccountId}:alias/aws/ssm"
    Events:
      LoginPage:
        Type: Api
        Properties:
          Path: /auth/login
          Method: GET
      RegisterPage:
        Type: Api
        Properties:
          Path: /auth/register
          Method: GET
      AuthChallenge:
        Type: Api
        Properties:
          Path: /api/internal/auth/challenge
          Method: POST
      AuthVerify:
        Type: Api
        Properties:
          Path: /api/internal/auth/verify
          Method: POST
      RegisterChallenge:
        Type: Api
        Properties:
          Path: /api/internal/passkeys/register-challenge
          Method: POST
      RegisterPasskey:
        Type: Api
        Properties:
          Path: /api/internal/passkeys/register
          Method: POST
```

- [ ] Add `ComposeFunction` resource:

```yaml
ComposeFunction:
  Type: AWS::Serverless::Function
  Properties:
    FunctionName: !Sub "activity-app-compose-${Stage}"
    CodeUri: ../.build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager/ComposeHandler/ComposeHandler.zip
    Timeout: 30
    Policies:
      - SSMParameterReadPolicy:
          ParameterName: !Sub "activity/${Stage}/*"
      - Statement:
          - Effect: Allow
            Action: kms:Decrypt
            Resource: !Sub "arn:aws:kms:${AWS::Region}:${AWS::AccountId}:alias/aws/ssm"
    Events:
      ComposePage:
        Type: Api
        Properties:
          Path: /compose
          Method: GET
```

- [ ] Add `SessionOriginRequestPolicy` resource for CloudFront cookie forwarding:

```yaml
SessionOriginRequestPolicy:
  Type: AWS::CloudFront::OriginRequestPolicy
  Properties:
    OriginRequestPolicyConfig:
      Name: !Sub "activity-session-origin-${Stage}"
      CookiesConfig:
        CookieBehavior: whitelist
        Cookies:
          - session
      HeadersConfig:
        HeaderBehavior: whitelist
        Headers:
          - Content-Type
      QueryStringsConfig:
        QueryStringBehavior: all
```

- [ ] Add CloudFront cache behaviors for `/auth/*`, `/api/internal/*`, `/compose` to existing `CloudFrontDistribution` (CachingDisabled, forward session cookie via `SessionOriginRequestPolicy`)

- [ ] Document proxy distribution changes needed (manual step -- add matching behaviors on `happitec.com` CloudFront)

- [ ] Build on linux-runner-3

**Files:** `activity-app/template.yaml`, `Package.swift`

---

## Task 10: Integration tests

Write integration tests using the generated APIClient, following the existing `Tests/IntegrationTests/` pattern.

- [ ] Create `Tests/IntegrationTests/AuthChallengeTests.swift`:
  - Test `POST /api/internal/auth/challenge` returns valid challenge JSON
  - Test two consecutive challenges return different values

- [ ] Create `Tests/IntegrationTests/RegistrationTests.swift`:
  - Test `POST /api/internal/passkeys/register-challenge` with invalid token returns 401
  - Test `POST /api/internal/passkeys/register-challenge` with expired token returns 401

- [ ] Create `Tests/IntegrationTests/ComposePageTests.swift`:
  - Test `GET /compose` without session cookie returns 302 redirect to `/auth/login`

- [ ] Create `Tests/IntegrationTests/DualAuthTests.swift`:
  - Test `POST /api/v1/statuses` with bearer token continues to work
  - Test `POST /api/v1/statuses` with no auth returns 401

- [ ] Create `Tests/ActivityPubCoreTests/JWTSessionTests.swift`:
  - Sign and verify round-trip
  - Reject expired tokens
  - Reject tampered tokens
  - Reject wrong issuer
  - Reject wrong key
  - CSRF token derivation is deterministic
  - CSRF token changes with different session
  - CSRF verification rejects tampered tokens

- [ ] Build and run unit tests on linux-runner-3:

```bash
sshpass -p admin scp -o StrictHostKeyChecking=no -r Tests/ admin@$(tart ip linux-runner-3):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Tests/
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner-3) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift test --filter ActivityPubCoreTests 2>&1"
```

**Files:** `Tests/ActivityPubCoreTests/JWTSessionTests.swift`, `Tests/IntegrationTests/AuthChallengeTests.swift`, `Tests/IntegrationTests/RegistrationTests.swift`, `Tests/IntegrationTests/ComposePageTests.swift`, `Tests/IntegrationTests/DualAuthTests.swift`

---

## Deploy Checklist (post-implementation)

After all tasks are complete and merged:

1. [ ] Create SSM parameter `{ssmKeyPrefix}/session-signing-key` with a random 64-byte hex value
2. [ ] Run `swift run ActivityProvisioner register-passkey --username happitec` to generate a registration URL
3. [ ] Deploy with `gh workflow run deploy-app-stack.yml`
4. [ ] Add proxy CloudFront behaviors for `/auth/*`, `/api/internal/*`, `/compose`
5. [ ] Open the registration URL and register a passkey (Touch ID)
6. [ ] Log in at `/auth/login` and post from `/compose`
7. [ ] Verify bearer token API still works
8. [ ] Run integration tests via `gh workflow run run-integration-tests.yml`
