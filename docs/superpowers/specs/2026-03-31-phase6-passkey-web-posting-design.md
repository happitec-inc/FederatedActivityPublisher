# Phase 6 Design -- Passkey Web Posting

## Goal

Provide a web-based posting interface at `happitec.com/compose` where brand account operators authenticate with a passkey (WebAuthn) and publish posts. No OAuth2, no Cognito -- just passkeys, signed JWT session tokens, and the existing posting APIs.

## Evolutionary Path

This is the first of two authentication phases:

1. **Phase 6 (this spec):** Passkey auth + web posting UI. Operators register a passkey via a CLI-generated one-time link, authenticate via WebAuthn, and post through a server-rendered compose page.
2. **Phase $oauth (deferred):** Wrap the passkey authentication in an OAuth2 authorize flow so that standard Mastodon client apps (Ivory, Ice Cubes, Elk) can obtain bearer tokens. The passkey login becomes the identity verification step inside the OAuth2 authorization code grant.

Phase 6 is self-contained. Phase $oauth builds on top of it without replacing it.

## Success Criteria

1. An operator can register a passkey on their device by opening a CLI-generated one-time URL.
2. The operator can log in at `happitec.com/auth/login` using their passkey.
3. After login, the operator can compose and publish a post (text + images + alt text + visibility) from `happitec.com/compose`.
4. The compose page uses the existing `POST /api/v1/statuses` and `POST /api/v2/media` endpoints for actual posting.
5. Existing bearer token API access continues working unchanged.
6. All new handlers are written in Swift, rendered with Elementary + latex.css.

## What This Does NOT Include

- OAuth2 authorization server (deferred to Phase $oauth)
- Cognito integration
- Multi-user login (one passkey set per actor)
- Post editing or deletion from the web UI
- Scheduling posts
- Dashboard or analytics views
- Streaming / WebSocket support

---

## Architecture Overview

```
Browser (operator)
      |
      |  1. GET /auth/register?token=<one-time>
      |     -> WebAuthn navigator.credentials.create()
      |     -> POST /api/internal/passkeys/register
      |
      |  2. GET /auth/login
      |     -> POST /api/internal/auth/challenge
      |     -> WebAuthn navigator.credentials.get()
      |     -> POST /api/internal/auth/verify
      |     <- Set-Cookie: session=<JWT> (HttpOnly, Secure, SameSite=Lax)
      |
      |  3. GET /compose  (session cookie required)
      |     -> POST /api/v2/media   (via fetch, session cookie)
      |     -> POST /api/v1/statuses (via fetch, session cookie)
      |
      +---> AuthHandler Lambda
      |       - Serves login/register HTML pages
      |       - Handles WebAuthn challenge/verify JSON endpoints
      |       - Handles passkey registration JSON endpoints
      |       - Issues JWT session tokens
      |
      +---> ComposeHandler Lambda
      |       - Serves the compose page (Elementary HTML + vanilla JS)
      |       - Auth-gated via session cookie
      |
      +---> PostHandler Lambda (existing)
      |       - POST /api/v1/statuses
      |       - Now accepts session JWT cookie OR bearer token
      |
      +---> MediaUploadHandler Lambda (existing)
              - POST /api/v2/media
              - Now accepts session JWT cookie OR bearer token
```

### Key Architectural Decisions

**D1: Passkeys over passwords.** Passkeys (WebAuthn/FIDO2) provide phishing-resistant authentication without managing password hashes, account lockouts, or 2FA. The browser's platform authenticator (Touch ID, Windows Hello, phone biometric) handles the credential. No secrets are stored server-side -- only the public key.

**D2: JWT session tokens over server-side sessions.** JWTs signed with an HMAC key stored in SSM are stateless and work naturally across Lambda invocations. No session table, no sticky sessions. The JWT contains the username and expiry; the signing key is shared across all auth-aware Lambdas via the existing SSM key prefix pattern.

**D3: Dual auth path (cookie + bearer).** BearerAuth.swift gains a second code path: if no Authorization header is present, check for a `session` cookie containing a JWT. Both paths resolve to the same `BearerAuthResult`. This keeps the existing CLI/script bearer token workflow intact while letting the web UI use cookies.

**D4: Server-rendered with Elementary.** The compose page follows the same pattern as ProfileHandler: Elementary for HTML generation, latex.css for styling, minimal vanilla JavaScript for WebAuthn API calls, image upload preview, and form submission via fetch(). No frontend framework.

**D5: Registration requires a one-time token.** Passkey enrollment is gated by a short-lived token generated via the ActivityProvisioner CLI. This prevents unauthorized passkey registration -- only an operator with CLI access can initiate enrollment.

---

## Passkey Registration

### Flow

1. Operator runs a CLI command (ActivityProvisioner or a new subcommand):
   ```
   swift run ActivityProvisioner register-passkey --username happitec
   ```
2. CLI generates a one-time registration token, stores it in DynamoDB (`REGISTRATION_TOKEN#{token}` with 15-minute TTL), and prints a URL:
   ```
   https://happitec.com/auth/register?token=abc123def456
   ```
3. Operator opens the URL in their browser.
4. AuthHandler serves a registration page that:
   - Validates the one-time token (fetches from DynamoDB, checks expiry)
   - Calls `POST /api/internal/passkeys/register-challenge` to get a WebAuthn creation challenge
   - Triggers `navigator.credentials.create()` with the challenge
   - Sends the attestation response to `POST /api/internal/passkeys/register`
   - Server verifies:
     - `clientDataJSON.type` equals `"webauthn.create"`
     - `clientDataJSON.origin` equals `https://happitec.com` (from `SERVER_DOMAIN` env var)
     - Challenge matches the stored challenge
   - Server extracts the public key and credential ID from the CBOR-encoded attestation
   - Stores the credential in DynamoDB (`PASSKEY#{credentialId}`)
   - Atomically deletes the one-time token using DynamoDB conditional delete (`attribute_exists(PK)`) to prevent race conditions with concurrent tabs
   - Deletes the challenge (`PASSKEY_CHALLENGE#{challengeId}`) to prevent replay within the 5-minute TTL window
   - Shows a success message and a link to `/auth/login`
5. Multiple passkeys can be registered per account (different devices).

### Registration Endpoints

**`POST /api/internal/passkeys/register-challenge`**

Request:
```json
{
  "token": "abc123def456"
}
```

Response:
```json
{
  "challenge": "<base64url-encoded random bytes>",
  "rp": { "name": "Happitec", "id": "happitec.com" },
  "user": {
    "id": "<base64url-encoded username hash>",
    "name": "happitec",
    "displayName": "Happitec"
  },
  "pubKeyCredParams": [
    { "type": "public-key", "alg": -7 },
    { "type": "public-key", "alg": -257 }
  ],
  "timeout": 60000,
  "attestation": "none",
  "authenticatorSelection": {
    "residentKey": "preferred",
    "userVerification": "preferred"
  }
}
```

The challenge is stored in DynamoDB (`PASSKEY_CHALLENGE#{challengeId}`) with a 5-minute TTL.

**RP ID configuration:** The `rp.id` value (`happitec.com`) is derived from the `SERVER_DOMAIN` environment variable, not hardcoded. This ensures the staging environment (`stage.activity.happitec.com`) uses the correct RP ID. The `origin` validation during verification also uses this environment variable (`https://{SERVER_DOMAIN}`).

**`POST /api/internal/passkeys/register`**

Request:
```json
{
  "token": "abc123def456",
  "challengeId": "<challengeId>",
  "credential": {
    "id": "<base64url credential ID>",
    "rawId": "<base64url raw ID>",
    "type": "public-key",
    "response": {
      "attestationObject": "<base64url CBOR>",
      "clientDataJSON": "<base64url JSON>"
    }
  }
}
```

Response:
```json
{ "ok": true }
```

---

## Passkey Authentication

### Flow

1. Operator visits `happitec.com/auth/login`.
2. AuthHandler serves a login page with a "Sign in with passkey" button.
3. On button click, JavaScript calls `POST /api/internal/auth/challenge` to get a WebAuthn assertion challenge.
4. Browser triggers `navigator.credentials.get()` with the challenge. The platform authenticator prompts for biometric/PIN.
5. JavaScript sends the assertion response to `POST /api/internal/auth/verify`.
6. Server:
   - Looks up the credential ID in DynamoDB (`PASSKEY#{credentialId}`)
   - Verifies `clientDataJSON.type` equals `"webauthn.get"`
   - Verifies `clientDataJSON.origin` equals `https://happitec.com` (derived from `SERVER_DOMAIN` env var, not hardcoded)
   - Verifies the signature against the stored public key
   - Verifies the challenge matches the stored challenge
   - Deletes the challenge (`PASSKEY_CHALLENGE#{challengeId}`) after successful verification
   - Updates `lastUsedAt` and `signCount` on the passkey record
   - Issues a JWT session token
7. Response sets `Set-Cookie: session=<JWT>; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=86400`.
8. Browser redirects to `/compose`.

### Authentication Endpoints

**`POST /api/internal/auth/challenge`**

Request: `{}` (empty body or no body)

Response:
```json
{
  "challengeId": "<opaque ID>",
  "challenge": "<base64url random bytes>",
  "rpId": "happitec.com",
  "timeout": 60000,
  "userVerification": "preferred"
}
```

**`POST /api/internal/auth/verify`**

Request:
```json
{
  "challengeId": "<challengeId>",
  "credential": {
    "id": "<base64url credential ID>",
    "rawId": "<base64url raw ID>",
    "type": "public-key",
    "response": {
      "authenticatorData": "<base64url>",
      "clientDataJSON": "<base64url>",
      "signature": "<base64url>"
    }
  }
}
```

Response:
```json
{ "ok": true, "username": "happitec" }
```

Plus `Set-Cookie` header with the JWT.

### JWT Session Token

Structure:
```json
{
  "sub": "happitec",
  "iat": 1743379200,
  "exp": 1743465600,
  "iss": "happitec.com"
}
```

- Signed with HMAC-SHA256 using a key stored in SSM at `{ssmKeyPrefix}/session-signing-key`
- 24-hour expiry
- No refresh token -- operator re-authenticates with passkey after expiry

---

## Auth Migration (BearerAuth.swift)

The existing `authenticateBearer` function gains an overload or extended signature that also checks for a JWT session cookie.

### New Function: `authenticateRequest`

```swift
/// The method used for authentication, so callers can vary response format.
public enum AuthMethod: Sendable {
    case bearer   // API client -- errors should be 401 JSON
    case session  // Browser session -- errors should be 302 redirect to /auth/login
}

/// Extended auth result that includes the method used.
public struct RequestAuthResult: Sendable {
    public let username: String
    public let method: AuthMethod
}

public func authenticateRequest(
    authHeader: String,
    cookies: String?,
    ssmKeyPrefix: String,
    ssmClient: SSMClient
) async throws -> RequestAuthResult
```

Logic:
1. If `authHeader` starts with `Bearer `, use the existing SSM token lookup (unchanged). Return `.bearer` method.
2. Else if `cookies` contains a `session=` value, decode and verify the JWT:
   - Fetch the signing key from SSM (`{ssmKeyPrefix}/session-signing-key`), **cached in the Lambda execution context** (module-level variable initialized once, same pattern as `ssmClient`/`store` in PostHandler)
   - Verify HMAC-SHA256 signature
   - Check `exp` claim is in the future
   - Check `iss` matches expected domain
   - Return `RequestAuthResult(username: jwt.sub, method: .session)`
3. If a cookie IS present but the JWT is expired or invalid, throw `BearerAuthError.sessionExpired` (not `missingHeader`).
4. If neither auth method is present, throw `BearerAuthError.missingHeader`.

**Error response format depends on the auth method attempted:**
- Bearer token errors (no token, invalid token): return 401 JSON `{"error": "..."}` -- same as today.
- Session cookie errors (expired, invalid JWT): return 302 redirect to `/auth/login`. Callers check the `Accept` header as a secondary signal: if `Accept` contains `text/html`, prefer redirect; otherwise return JSON.
- No auth at all: return 401 JSON for API callers, 302 for requests with `Accept: text/html`.

The existing `authenticateBearer` function remains unchanged for backward compatibility. PostHandler and MediaUploadHandler switch to calling `authenticateRequest`, passing both the Authorization header and the Cookie header from the request.

### SSM Signing Key Caching

Every JWT verification requires the signing key from SSM. To avoid an SSM `GetParameter` call on every request, the signing key is cached in the Lambda execution context using a module-level variable:

```swift
/// Cached signing key -- initialized once per Lambda cold start.
/// SSM calls are expensive relative to JWT verification; this avoids
/// one SSM call per page load and per API call from the compose page.
var cachedSigningKey: String?

func getSigningKey(ssmKeyPrefix: String, ssmClient: SSMClient) async throws -> String {
    if let key = cachedSigningKey { return key }
    let output = try await ssmClient.getParameter(input: .init(
        name: "\(ssmKeyPrefix)/session-signing-key",
        withDecryption: true
    ))
    guard let key = output.parameter?.value else {
        throw BearerAuthError.serverConfigError("Session signing key not configured")
    }
    cachedSigningKey = key
    return key
}
```

**Key rotation note:** Rotating the signing key in SSM invalidates all active sessions immediately (operators must re-authenticate). This is acceptable for a single-operator system. Cold-starting a new Lambda instance picks up the new key automatically; warm instances continue using the cached (old) key until they are recycled.

---

## Web Posting UI

### Compose Page (`GET /compose`)

Server-rendered by ComposeHandler using Elementary + latex.css.

**Layout:**
- Header with site name and logged-in username
- Text area for post content (Markdown-like plain text, converted to HTML by PostHandler)
- File input for image upload (supports drag-and-drop via JS)
- Alt text field (appears after image is selected)
- Image preview (rendered client-side via JS after file selection)
- Visibility selector: public / unlisted / followers-only (radio buttons or dropdown)
- Content warning toggle + spoiler text input
- "Post" button
- Logout link

**Posting flow (client-side JS):**
1. If image is attached, `POST /api/v2/media` via fetch (multipart/form-data). Cookie is sent automatically (same origin).
2. On media upload success, store the returned `media_id`.
3. `POST /api/v1/statuses` via fetch with JSON body including `status`, `visibility`, `media_ids[]`, `spoiler_text`. Cookie sent automatically.
4. On success, show confirmation with link to the new post.
5. On error, show error message inline.

**API Gateway payload limit:** The SAM `Api` (REST API) has a 6MB payload limit for request bodies. The existing `MediaUploadHandler` already operates within this constraint (binary media types are configured on `ClientApi`). The compose page should enforce a client-side file size check (reject files > 5.5MB before upload) and show a clear error message. The `InstanceHandler` already advertises `image_size_limit: 6291456` (6MB).

**Character count:** The compose page should display a character count indicator. The existing `POST /api/v1/statuses` and `InstanceHandler` both reference a 5000-character limit (`max_characters: 5000`). Show remaining characters and disable the Post button when over the limit.

**JavaScript requirements (vanilla, no framework):**
- WebAuthn API calls (only on login/register pages, not compose)
- File selection + drag-and-drop handling
- Image preview via `URL.createObjectURL()`
- Form submission via `fetch()`
- CSRF token inclusion in requests
- Approximately 100-200 lines total

### CSRF Protection

The compose page includes a CSRF token as a `<meta>` tag in the HTML head. JavaScript reads this token and includes it as an `X-CSRF-Token` header on fetch requests. The server validates the token on POST endpoints accessed via the session cookie.

The CSRF token is derived from the session JWT using HMAC: `HMAC-SHA256(key: signing_key, message: jwt_payload)`, truncated to 32 hex characters. The signing key (from SSM) is the HMAC key; the JWT payload (the `sub` + `iat` claims concatenated) is the message. This avoids storing CSRF tokens server-side while binding them to the session. The token does not change for the lifetime of the session, which is acceptable since `SameSite=Lax` provides the primary CSRF defense and the token is a defense-in-depth measure.

---

## New Lambda Handlers

### AuthHandler

**Routes:**
| Method | Path | Purpose |
|--------|------|---------|
| GET | `/auth/login` | Login page (Elementary HTML + vanilla JS) |
| GET | `/auth/register` | Passkey registration page (requires `?token=` param) |
| POST | `/api/internal/auth/challenge` | Generate WebAuthn assertion challenge |
| POST | `/api/internal/auth/verify` | Verify WebAuthn assertion, issue JWT cookie |
| POST | `/api/internal/passkeys/register-challenge` | Generate WebAuthn creation challenge |
| POST | `/api/internal/passkeys/register` | Store new passkey credential |

**Dependencies:**
- DynamoDB (read/write passkeys, challenges, registration tokens)
- SSM (read session signing key)
- KMS (decrypt SSM parameters)

**Pages (Elementary + latex.css):**

Login page:
- "Sign in to Happitec" heading
- "Sign in with passkey" button
- Vanilla JS: calls challenge endpoint, triggers `navigator.credentials.get()`, sends assertion to verify endpoint, handles cookie and redirect

Registration page:
- "Register a passkey" heading
- Status text showing username from the one-time token
- "Register passkey" button
- Vanilla JS: calls register-challenge endpoint, triggers `navigator.credentials.create()`, sends attestation to register endpoint, shows success/failure

### ComposeHandler

**Routes:**
| Method | Path | Purpose |
|--------|------|---------|
| GET | `/compose` | Compose page (requires authenticated session) |

**Dependencies:**
- SSM (read session signing key for JWT verification)
- KMS (decrypt SSM parameters)

The handler verifies the session cookie JWT before rendering. If invalid or missing, it redirects to `/auth/login`.

---

## DynamoDB Schema Additions

All new entities use the existing single-table design.

### `PASSKEY#{credentialId}` / `META`

| Attribute | Type | Description |
|-----------|------|-------------|
| PK | S | `PASSKEY#{credentialId}` (base64url credential ID) |
| SK | S | `META` |
| username | S | Associated actor username |
| publicKey | S | Base64-encoded public key (COSE format) |
| publicKeyAlg | N | COSE algorithm identifier (-7 for ES256, -257 for RS256) |
| signCount | N | Authenticator signature counter (for clone detection) |
| createdAt | S | ISO 8601 timestamp |
| lastUsedAt | S | ISO 8601 timestamp (updated on each login) |

### `PASSKEY_CHALLENGE#{challengeId}` / `META`

| Attribute | Type | Description |
|-----------|------|-------------|
| PK | S | `PASSKEY_CHALLENGE#{challengeId}` (UUID) |
| SK | S | `META` |
| challenge | S | Base64url-encoded challenge bytes |
| username | S | Username (optional, set for registration challenges) |
| type | S | `registration` or `authentication` |
| TTL | N | Unix timestamp, 5 minutes from creation |

### `REGISTRATION_TOKEN#{token}` / `META`

| Attribute | Type | Description |
|-----------|------|-------------|
| PK | S | `REGISTRATION_TOKEN#{token}` (random token) |
| SK | S | `META` |
| username | S | Actor username this token is for |
| TTL | N | Unix timestamp, 15 minutes from creation |

### GSI for Passkey-by-Username Lookup -- DEFERRED

During authentication, the browser sends the credential ID as part of the assertion response, so the server performs a direct `PASSKEY#{credentialId}` point read. No GSI is needed for the authentication flow.

A GSI would only be needed for passkey management (listing all passkeys for a user, revoking specific passkeys). This is deferred until a passkey management UI is built. When needed:

- **GSI name:** `username-passkey-index`
- **Partition key:** `username`
- **Sort key:** `PK` (filtered to `PASSKEY#` prefix)
- **Projected attributes:** ALL

---

## SAM Template Changes (`activity-app/template.yaml`)

### New Parameters

```yaml
JwtSigningKeyParam:
  Type: String
  Default: ""
  Description: >-
    SSM parameter name for the JWT session signing key.
    If empty, defaults to {SSM_KEY_PREFIX}/session-signing-key.
```

### New Resources

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

### CloudFront Behavior Additions

New cache behaviors on the existing `CloudFrontDistribution`, inserted before the default behavior:

```yaml
# Auth pages -- no caching, pass cookies
- PathPattern: /auth/*
  TargetOriginId: ApiGateway
  ViewerProtocolPolicy: redirect-to-https
  CachePolicyId: 4135ea2d-6df8-44a3-9df3-4b5a84be39ad  # CachingDisabled
  AllowedMethods: [GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE]
  Compress: true

# Internal API -- no caching, pass cookies
- PathPattern: /api/internal/*
  TargetOriginId: ApiGateway
  ViewerProtocolPolicy: redirect-to-https
  CachePolicyId: 4135ea2d-6df8-44a3-9df3-4b5a84be39ad  # CachingDisabled
  AllowedMethods: [GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE]
  Compress: true

# Compose page -- no caching, pass cookies
- PathPattern: /compose
  TargetOriginId: ApiGateway
  ViewerProtocolPolicy: redirect-to-https
  CachePolicyId: 4135ea2d-6df8-44a3-9df3-4b5a84be39ad  # CachingDisabled
  AllowedMethods: [GET, HEAD]
  Compress: true
```

These behaviors need an origin request policy that forwards the `Cookie` header to the origin. A new origin request policy is required:

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

### happitec.com CloudFront (Proxy Distribution)

The proxy CloudFront distribution (managed outside this SAM template) needs matching behaviors added:

- `/auth/*` -> activityApiOrigin (CachingDisabled, forward `session` cookie)
- `/api/internal/*` -> activityApiOrigin (CachingDisabled, forward `session` cookie)
- `/compose` -> activityApiOrigin (CachingDisabled, forward `session` cookie)

---

## Swift WebAuthn Implementation

### Library Evaluation

The WebAuthn server-side verification requires:
1. Parsing CBOR-encoded attestation objects and authenticator data
2. Extracting the public key (in COSE format) from the credential
3. Verifying ECDSA or RSA signatures

**Options:**

| Library | Status | Notes |
|---------|--------|-------|
| [webauthn-swift](https://github.com/swift-server/webauthn-swift) | Swift Server Workgroup | Actively maintained; depends on swift-crypto (already in our tree). **Preferred option.** |
| Roll our own with swift-crypto | Known-good dependency | swift-crypto already in `Package.swift`; need CBOR parsing |
| [SwiftCBOR](https://github.com/unrelentingtech/SwiftCBOR) + swift-crypto | Two dependencies | SwiftCBOR for CBOR decoding, swift-crypto for signature verification |

**Recommendation:** Evaluate `swift-server/webauthn-swift` first. It is under the Swift Server Workgroup umbrella, actively maintained, targets server-side Swift on Linux, and depends on swift-crypto which is already in our dependency tree. If it compiles on Linux with Swift 6.3 and covers our use case (registration + authentication with `attestation: "none"`), adopt it and skip the hand-rolled CBOR decoder.

**Fallback:** If `webauthn-swift` proves unsuitable (API mismatch, missing Linux support, excessive transitive dependencies), fall back to swift-crypto + a minimal CBOR decoder. This should be validated against real attestation objects from Safari (Touch ID) and Chrome before committing -- treat this as a hard gate per Open Question 1.

### Implementation Modules

**`Sources/ActivityPubCore/WebAuthn/`:**
- `CBORDecoder.swift` -- Minimal CBOR decoder (maps, arrays, byte strings, integers, text strings)
- `WebAuthnRegistration.swift` -- Parse attestation object, extract credential ID + public key
- `WebAuthnAuthentication.swift` -- Parse authenticator data, verify assertion signature
- `WebAuthnTypes.swift` -- Shared types (`PublicKeyCredential`, `AuthenticatorData`, etc.)

**`Sources/ActivityPubCore/JWTSession.swift`:**
- JWT creation (HMAC-SHA256 signing)
- JWT verification (signature check, expiry check)
- CSRF token derivation

---

## Security Considerations

### Passkey Registration

- Registration is gated by a one-time token with a 15-minute TTL.
- The token is consumed atomically during `POST /api/internal/passkeys/register` using a DynamoDB conditional delete (`conditionExpression: "attribute_exists(PK)"`). If two browser tabs race to complete registration with the same token, only one succeeds. The initial page load and `register-challenge` endpoint validate the token non-destructively (read-only check); consumption happens only on successful credential storage.
- Only the CLI operator (who has AWS credentials) can generate tokens.
- The registration page validates the token server-side before showing the WebAuthn prompt.

### Session Security

- JWT stored as `HttpOnly` cookie (not accessible to JavaScript).
- `Secure` flag ensures transmission only over HTTPS.
- `SameSite=Lax` prevents the cookie from being sent in cross-origin POST requests while still allowing it on top-level GET navigations (e.g., clicking a bookmark or email link to `/compose`). This avoids the usability issue where `SameSite=Strict` would effectively log out the user when navigating from an external link.
- 24-hour expiry limits the window if a session is compromised.
- No refresh tokens -- re-authentication requires the passkey.

### CSRF Protection

- All state-changing requests from the compose page include an `X-CSRF-Token` header.
- The token is derived deterministically: `HMAC-SHA256(key: signing_key, message: sub + iat)`, so it is bound to the session and cannot be forged without the signing key.
- The server verifies the CSRF token on all POST requests that use cookie authentication.
- Bearer token requests (from scripts/CLI) are exempt from CSRF checks since they do not use cookies.

### Rate Limiting

- API Gateway throttling on `/api/internal/*` endpoints (10 requests/second per IP).
- Challenge endpoints are stateless-ish (stored in DynamoDB with TTL) so replaying old challenges does not work.
- Failed authentication attempts are logged but not currently rate-limited beyond API Gateway throttling. Future hardening: add AWS WAF rate-based rules on `/api/internal/auth/*` endpoints (e.g., 5 failed attempts per minute per IP triggers a temporary block).

### Clone Detection

- The `signCount` field on the passkey record is updated on each authentication.
- If the authenticator reports a sign count less than or equal to the stored count, the authentication fails and an alert is logged. This detects cloned authenticators.

---

## Portability

- No AWS-specific authentication services (no Cognito, no IAM auth on API Gateway).
- WebAuthn is a W3C standard implemented by all modern browsers.
- JWT signing uses HMAC-SHA256 -- no AWS KMS dependency for the signing operation itself.
- The SSM dependency for the signing key follows the same pattern as the existing RSA actor keys.
- DynamoDB is the only data store, consistent with the rest of the system.
- All new SSM parameters are provisioned via SAM, all config flows through repo variables.

---

## Testing Plan

### Step 0: OpenAPI Spec Updates (prerequisite for integration tests)

Before writing integration tests, update `openapi.yaml` with the new endpoints so the generated `APIClient` can be used:

**New auth endpoints:**
- `POST /api/internal/auth/challenge` -- `operationId: createAuthChallenge`
- `POST /api/internal/auth/verify` -- `operationId: verifyAuth`
- `POST /api/internal/passkeys/register-challenge` -- `operationId: createRegistrationChallenge`
- `POST /api/internal/passkeys/register` -- `operationId: registerPasskey`

**New compose endpoint:**
- `GET /compose` -- `operationId: getComposePage` (returns `text/html`)

**New security scheme:**
- `cookieAuth` -- cookie-based JWT session (in addition to existing `bearerAuth`)

The generated `APIClient` target will be used for all integration tests, following the existing pattern in `Sources/APIClient/` and `Tests/IntegrationTests/`.

### Unit Tests (`Tests/ActivityPubCoreTests/`)

**JWT signing and verification:**
- `JWTSessionTests.swift`:
  - Sign and verify round-trip with known key and payload
  - Reject expired tokens (`exp` in the past)
  - Reject tampered tokens (modified payload, original signature)
  - Reject tokens with wrong issuer
  - Reject tokens signed with a different key

**WebAuthn challenge generation:**
- `WebAuthnChallengeTests.swift`:
  - Challenge bytes are cryptographically random (no two calls produce the same value)
  - Challenge ID is a valid UUID
  - Registration challenge includes correct RP ID and user info
  - Authentication challenge includes correct RP ID

**CSRF token validation:**
- `CSRFTokenTests.swift`:
  - Token derivation is deterministic for the same session
  - Token changes when session changes (different `sub` or `iat`)
  - Verification accepts valid token
  - Verification rejects tampered token
  - Verification rejects token from a different session

**WebAuthn verification (if hand-rolling):**
- `CBORDecoderTests.swift` -- decode known attestation objects, edge cases
- `WebAuthnRegistrationTests.swift` -- extract credential ID and public key from known attestation
- `WebAuthnAuthenticationTests.swift` -- verify known assertion signature, reject bad signatures

### Integration Tests (`Tests/IntegrationTests/`)

Uses the generated `APIClient` and follows the existing `run-integration-tests.yml` workflow pattern (`TEST_API_URL` env var pointing at deployed stack).

**Auth challenge flow:**
- `AuthChallengeTests.swift`:
  - `POST /api/internal/auth/challenge` returns valid challenge JSON with `challengeId`, `challenge`, `rpId`
  - Challenge has correct `rpId` matching the deployed domain
  - Two consecutive challenge requests return different challenges

**Registration flow:**
- `RegistrationTests.swift`:
  - `POST /api/internal/passkeys/register-challenge` with valid token returns creation options
  - `POST /api/internal/passkeys/register-challenge` with invalid/expired token returns 401
  - `POST /api/internal/passkeys/register-challenge` with already-consumed token returns 401

**Compose page:**
- `ComposePageTests.swift`:
  - `GET /compose` without session cookie returns 302 redirect to `/auth/login`
  - `GET /compose` with expired JWT returns 302 redirect to `/auth/login`

**Dual auth (cookie + bearer):**
- `DualAuthTests.swift`:
  - `POST /api/v1/statuses` with bearer token continues to work (existing behavior)
  - `POST /api/v1/statuses` with valid session cookie + CSRF token works
  - `POST /api/v1/statuses` with valid session cookie but missing CSRF token returns 403
  - `POST /api/v1/statuses` with neither auth method returns 401

**Note:** Full WebAuthn registration and authentication flows cannot be tested via HTTP integration tests because they require browser-side `navigator.credentials` API calls. These are covered by manual testing.

### Manual Testing Checklist

- [ ] Register passkey on macOS Safari (Touch ID)
- [ ] Register passkey on iOS Safari (Face ID)
- [ ] Login from each registered device
- [ ] Compose and post with text only
- [ ] Compose and post with image + alt text
- [ ] Compose and post with content warning
- [ ] Verify visibility options work (public, unlisted, followers-only)
- [ ] Verify character count indicator works (shows remaining, disables Post at limit)
- [ ] Verify file size check rejects images > 5.5MB before upload
- [ ] Verify post appears in profile and is federated
- [ ] Verify session expires after 24 hours
- [ ] Verify bearer token API still works from CLI
- [ ] Verify navigating to `/compose` from an external bookmark works (SameSite=Lax test)

---

## Implementation Order

1. **WebAuthn core** -- `CBORDecoder`, `WebAuthnRegistration`, `WebAuthnAuthentication` in ActivityPubCore, with unit tests
2. **JWT session** -- `JWTSession` in ActivityPubCore, with unit tests
3. **Auth migration** -- `authenticateRequest` in BearerAuth.swift, update PostHandler and MediaUploadHandler
4. **DynamoDB schema** -- Add passkey, challenge, and registration token entity types to DynamoDBStore
5. **AuthHandler** -- Registration and login pages + API endpoints
6. **ComposeHandler** -- Compose page with Elementary rendering
7. **SAM template** -- New functions, CloudFront behaviors, origin request policy
8. **CLI update** -- `register-passkey` subcommand in ActivityProvisioner
9. **End-to-end testing** -- Manual passkey registration and posting flow

---

## Open Questions

1. **Which Swift WebAuthn library to use?** Recommendation is to roll our own with swift-crypto + a minimal CBOR decoder, but this should be validated against real attestation objects from Safari and Chrome before committing to the approach.

2. **Should the compose page support scheduling posts?** Not in this phase. Scheduling requires a new DynamoDB entity, a scheduled Lambda trigger, and UI for datetime picking. Defer to a future phase.

3. **Should we add a dashboard view?** Not in this phase. A dashboard showing recent posts and stats is useful but orthogonal to the core posting flow. The compose page can link to the profile page for viewing published posts.

4. **How does passkey registration work for existing seeded actors?** The CLI `register-passkey` command works for any actor that already exists in DynamoDB. It generates a one-time token keyed to that actor's username. The actor's existing bearer token continues to work; passkey auth is additive.

5. **GSI vs. secondary entity for passkey-by-username lookup?** **RESOLVED: Deferred.** During authentication, the browser sends a credential ID, so we do a direct `PASSKEY#{credentialId}` point read. No GSI is needed for Phase 6. The GSI will be added when we build passkey management (listing/revoking passkeys).

6. **Should the `/api/internal/*` routes be on the ClientApi or the federation API Gateway?** They need to be on the same origin as the compose page (for cookie SameSite to work). Since `happitec.com` routes through the federation CloudFront, these routes should be on the federation API Gateway (ServerlessRestApi), not the ClientApi.
