/// Lambda handler for passkey (WebAuthn) authentication and session management.
///
/// This handler owns all user-facing auth surfaces: the login page, the passkey
/// registration page, and the JSON API endpoints the browser's WebAuthn JS calls
/// during both ceremonies. It is invoked by API Gateway for the `/auth/*` and
/// `/api/internal/auth/*` and `/api/internal/passkeys/*` paths.
///
/// ## Authentication flow
///
/// Login follows the standard WebAuthn authentication ceremony:
/// 1. Browser hits `POST /api/internal/auth/challenge` to get a server-generated
///    challenge stored in DynamoDB with a short TTL.
/// 2. Browser calls `navigator.credentials.get()` with the challenge and sends the
///    assertion to `POST /api/internal/auth/verify`.
/// 3. This handler consumes the challenge (atomic DynamoDB delete to prevent replay),
///    verifies the ES256 signature against the stored public key, checks the sign
///    count for cloned-authenticator detection, and issues a JWT session cookie signed
///    with a key loaded from SSM Parameter Store.
///
/// ## Registration flow
///
/// New passkeys require a pre-issued registration token (created via the
/// `provision-actor` GitHub Actions workflow):
/// 1. Admin shares the one-time token URL (`GET /auth/register?token=...`).
/// 2. Browser hits `POST /api/internal/passkeys/register-challenge` with the token
///    to get a `navigator.credentials.create()` challenge.
/// 3. Browser completes the ceremony and posts to `POST /api/internal/passkeys/register`,
///    which consumes the token atomically, parses the CBOR attestation object, extracts
///    the COSE public key, and stores the passkey in DynamoDB.
///
/// ## Key dependencies
/// - `ActivityPubCore.DynamoDBStore` — challenge, passkey, and registration token storage
/// - `ActivityPubCore.JWTSession` — JWT signing and parsing
/// - `AWSSSM` — retrieves the session signing key at cold start, cached for reuse
/// - `Elementary` — HTML rendering for the login, registration, and error pages
/// - `Crypto` (swift-crypto) — P-256 ECDSA signature verification
///
/// Required environment variables:
/// - `SERVER_DOMAIN`: the ActivityPub server domain (e.g. `activity.happitec.com`)
/// - `SSM_KEY_PREFIX`: SSM path prefix where `session-signing-key` lives
///
/// Optional environment variables:
/// - `INSTANCE_TITLE`: display name shown in page titles
import AWSLambdaEvents
import AWSLambdaRuntime
import AWSSSM
import ActivityPubCore
import Elementary
import Foundation
import Crypto

guard let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] else {
    fatalError("SERVER_DOMAIN environment variable is required")
}
let instanceTitle = ProcessInfo.processInfo.environment["INSTANCE_TITLE"] ?? "FederatedActivityPublisher"
let ssmKeyPrefixRaw = ProcessInfo.processInfo.environment["SSM_KEY_PREFIX"] ?? "/activity/stage/keys/"
let ssmKeyPrefix = ssmKeyPrefixRaw.hasSuffix("/") ? String(ssmKeyPrefixRaw.dropLast()) : ssmKeyPrefixRaw

let store = try await DynamoDBStore()
let ssmClient = try await SSMClient()

/// Cached signing key -- initialized once per Lambda cold start.
nonisolated(unsafe) var cachedSigningKey: String?

/// Returns the session signing key, loading it from SSM on the first call and
/// caching it for the lifetime of the Lambda execution environment.
///
/// The key lives at `{ssmKeyPrefix}/session-signing-key` as a SecureString parameter.
/// A missing or empty value is a fatal misconfiguration — the handler cannot issue
/// sessions without it.
///
/// - Returns: The plaintext signing key string.
/// - Throws: Any error from the SSM `GetParameter` call.
func getSigningKey() async throws -> String {
    if let key = cachedSigningKey { return key }
    let output = try await ssmClient.getParameter(input: .init(
        name: "\(ssmKeyPrefix)/session-signing-key",
        withDecryption: true
    ))
    guard let key = output.parameter?.value, !key.isEmpty else {
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
        case (.get, "/auth/login"):
            return renderLoginPage()
        case (.get, "/auth/register"):
            return try await handleRegisterPage(event: event)
        case (.post, "/api/internal/auth/challenge"):
            return try await handleAuthChallenge()
        case (.post, "/api/internal/auth/verify"):
            return try await handleAuthVerify(event: event, context: context)
        case (.post, "/api/internal/passkeys/register-challenge"):
            return try await handleRegisterChallenge(event: event)
        case (.post, "/api/internal/passkeys/register"):
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

// MARK: - Auth Challenge

/// Generates a WebAuthn authentication challenge and stores it in DynamoDB.
///
/// Called by the login page before invoking `navigator.credentials.get()`. The
/// returned JSON includes a `challengeId` (used to retrieve and consume the stored
/// record during verification) and the base64url-encoded challenge bytes the browser
/// passes to the authenticator.
///
/// The challenge has a 5-minute TTL enforced by DynamoDB's TTL attribute; it is also
/// atomically deleted on first use in ``handleAuthVerify(event:context:)`` to prevent replay.
///
/// - Returns: A 200 response with JSON containing `challengeId`, `challenge`, `rpId`, `timeout`,
///   and `userVerification`.
/// - Throws: DynamoDB errors from ``DynamoDBStore/storeChallenge(challengeId:challenge:type:username:)``.
func handleAuthChallenge() async throws -> APIGatewayResponse {
    let challengeId = generateRandomHex(byteCount: 16)
    let challengeBytes = generateRandomBytes(count: 32)
    let challenge = base64urlEncode(Data(challengeBytes))

    try await store.storeChallenge(
        challengeId: challengeId,
        challenge: challenge,
        type: "authentication",
        username: nil
    )

    let json = """
    {"challengeId":"\(challengeId)","challenge":"\(challenge)","rpId":"\(serverDomain)","timeout":300000,"userVerification":"preferred"}
    """

    return APIGatewayResponse(
        statusCode: .ok,
        headers: ["content-type": "application/json"],
        body: json
    )
}

// MARK: - Auth Verify

/// Verifies a WebAuthn authentication assertion and issues a session cookie on success.
///
/// This is the second half of the login ceremony. It performs the full WebAuthn
/// authentication verification sequence:
/// 1. Consumes the stored challenge atomically (preventing replay).
/// 2. Decodes and validates `clientDataJSON`: checks origin, ceremony type (`webauthn.get`),
///    and challenge value.
/// 3. Retrieves the stored passkey by credential ID.
/// 4. Verifies the ES256 signature over `authenticatorData || SHA-256(clientDataJSON)`.
/// 5. Detects potentially cloned authenticators by comparing sign counts.
/// 6. Issues a 24-hour JWT session cookie (`session=...`; HttpOnly, Secure, SameSite=Lax).
///
/// - Parameters:
///   - event: The API Gateway request containing the JSON body with `challengeId` and
///     the WebAuthn credential assertion object.
///   - context: Lambda context used for structured logging.
/// - Returns: 200 with `{"ok":true,"username":"..."}` and a `set-cookie` header on success,
///   or an appropriate 4xx/5xx JSON error response.
/// - Throws: DynamoDB or SSM errors that escape the outer do/catch in the runtime closure.
func handleAuthVerify(event: APIGatewayRequest, context: LambdaContext) async throws -> APIGatewayResponse {
    guard let bodyString = event.body else {
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Missing request body"}"#
        )
    }

    let bodyData = Data(bodyString.utf8)

    guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
          let challengeId = json["challengeId"] as? String,
          let credential = json["credential"] as? [String: Any],
          let credentialId = credential["id"] as? String,
          let credResponse = credential["response"] as? [String: Any],
          let clientDataJSONB64 = credResponse["clientDataJSON"] as? String,
          let authenticatorDataB64 = credResponse["authenticatorData"] as? String,
          let signatureB64 = credResponse["signature"] as? String
    else {
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Invalid request format"}"#
        )
    }

    // 1. Consume the challenge (atomic delete)
    guard let challengeRecord = try await store.consumeChallenge(challengeId: challengeId),
          challengeRecord.type == "authentication"
    else {
        return APIGatewayResponse(
            statusCode: .unauthorized,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Invalid or expired challenge"}"#
        )
    }

    // 2. Decode clientDataJSON and verify
    guard let clientDataJSONData = base64urlDecode(clientDataJSONB64),
          let clientData = try? JSONSerialization.jsonObject(with: clientDataJSONData) as? [String: Any],
          let origin = clientData["origin"] as? String,
          let cdType = clientData["type"] as? String,
          let cdChallenge = clientData["challenge"] as? String
    else {
        return APIGatewayResponse(
            statusCode: .unauthorized,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Invalid clientDataJSON"}"#
        )
    }

    guard origin == "https://\(serverDomain)" else {
        context.logger.error("Origin mismatch: \(origin) != https://\(serverDomain)")
        return APIGatewayResponse(
            statusCode: .unauthorized,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Origin mismatch"}"#
        )
    }

    guard cdType == "webauthn.get" else {
        return APIGatewayResponse(
            statusCode: .unauthorized,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Wrong ceremony type"}"#
        )
    }

    guard cdChallenge == challengeRecord.challenge else {
        return APIGatewayResponse(
            statusCode: .unauthorized,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Challenge mismatch"}"#
        )
    }

    // 3. Look up passkey
    guard let passkey = try await store.getPasskey(credentialId: credentialId) else {
        return APIGatewayResponse(
            statusCode: .unauthorized,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Unknown credential"}"#
        )
    }

    // 4. Verify signature
    guard let authenticatorData = base64urlDecode(authenticatorDataB64),
          let signatureData = base64urlDecode(signatureB64)
    else {
        return APIGatewayResponse(
            statusCode: .unauthorized,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Invalid authenticator data"}"#
        )
    }

    // Compute hash of clientDataJSON
    let clientDataHash = SHA256.hash(data: clientDataJSONData)

    // Signed data = authenticatorData + SHA256(clientDataJSON)
    var signedData = authenticatorData
    signedData.append(contentsOf: clientDataHash)

    // Verify with stored public key
    guard let publicKeyData = base64urlDecode(passkey.publicKey) else {
        return APIGatewayResponse(
            statusCode: .internalServerError,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Invalid stored public key"}"#
        )
    }

    let verified = verifyES256Signature(
        signature: signatureData,
        data: Data(signedData),
        publicKeyData: publicKeyData
    )

    guard verified else {
        return APIGatewayResponse(
            statusCode: .unauthorized,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Signature verification failed"}"#
        )
    }

    // 5. Check and update sign count
    let newSignCount = extractSignCount(from: authenticatorData)
    if newSignCount > 0 && passkey.signCount > 0 && newSignCount <= passkey.signCount {
        context.logger.warning("Possible cloned authenticator: signCount \(newSignCount) <= stored \(passkey.signCount)")
    }

    try await store.updatePasskeySignCount(credentialId: credentialId, signCount: newSignCount)

    // 6. Issue JWT session cookie
    let signingKey = try await getSigningKey()
    let claims = JWTSession.Claims(sub: passkey.username, iss: serverDomain)
    let jwt = try JWTSession.sign(claims: claims, key: signingKey)

    let setCookie = "session=\(jwt); HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=86400"

    return APIGatewayResponse(
        statusCode: .ok,
        headers: [
            "content-type": "application/json",
            "set-cookie": setCookie,
        ],
        body: #"{"ok":true,"username":"\#(escapeJSON(passkey.username))"}"#
    )
}

// MARK: - Registration Challenge

/// Generates a WebAuthn registration challenge for a validated registration token.
///
/// Called by the registration page before invoking `navigator.credentials.create()`.
/// The registration token (a one-time value provisioned via the `provision-actor` workflow)
/// is validated but not yet consumed here — consumption happens in ``handleRegisterPasskey(event:context:)``
/// to allow the browser to retry the authenticator step without needing a new token.
///
/// The challenge is stored in DynamoDB with the username from the token, so the
/// registration step can verify that the same user is completing the ceremony.
///
/// - Parameter event: The API Gateway request containing a JSON body with a `token` field.
/// - Returns: 200 with WebAuthn `PublicKeyCredentialCreationOptions`-shaped JSON, or
///   a 400/401 JSON error response.
/// - Throws: DynamoDB errors.
func handleRegisterChallenge(event: APIGatewayRequest) async throws -> APIGatewayResponse {
    guard let bodyString = event.body,
          let bodyData = bodyString.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
          let token = json["token"] as? String
    else {
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Missing token"}"#
        )
    }

    // Validate token (read-only -- not consumed yet)
    guard let regToken = try await store.getRegistrationToken(token: token) else {
        return APIGatewayResponse(
            statusCode: .unauthorized,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Invalid or expired registration token"}"#
        )
    }

    let challengeId = generateRandomHex(byteCount: 16)
    let challengeBytes = generateRandomBytes(count: 32)
    let challenge = base64urlEncode(Data(challengeBytes))

    // Store challenge with username so we can verify ownership during registration
    try await store.storeChallenge(
        challengeId: challengeId,
        challenge: challenge,
        type: "registration",
        username: regToken.username
    )

    // Encode username as user.id (base64url)
    let userId = base64urlEncode(Data(regToken.username.utf8))

    let json2 = """
    {"challengeId":"\(challengeId)","challenge":"\(challenge)","rp":{"name":"\(escapeJSON(instanceTitle))","id":"\(serverDomain)"},"user":{"id":"\(userId)","name":"\(escapeJSON(regToken.username))","displayName":"\(escapeJSON(regToken.username))"},"pubKeyCredParams":[{"type":"public-key","alg":-7}],"timeout":300000,"attestation":"none","authenticatorSelection":{"residentKey":"preferred","userVerification":"preferred"}}
    """

    return APIGatewayResponse(
        statusCode: .ok,
        headers: ["content-type": "application/json"],
        body: json2
    )
}

// MARK: - Register Passkey

/// Completes the WebAuthn registration ceremony and stores the new passkey.
///
/// Expects the attestation object from `navigator.credentials.create()`, along with the
/// registration token and challenge ID from the earlier steps. The sequence is:
/// 1. Consumes the challenge atomically.
/// 2. Consumes the registration token atomically, verifying it matches the username
///    in the challenge record.
/// 3. Validates `clientDataJSON` (origin, ceremony type `webauthn.create`, challenge).
/// 4. Parses the CBOR-encoded attestation object to extract `authData`.
/// 5. Extracts the COSE public key (EC2 / ES256) from `authData`.
/// 6. Stores the credential ID, public key, algorithm, and initial sign count in DynamoDB.
///
/// After this call succeeds, the user can log in with the registered passkey.
///
/// - Parameters:
///   - event: The API Gateway request containing `token`, `challengeId`, and a WebAuthn
///     credential object with `clientDataJSON` and `attestationObject`.
///   - context: Lambda context used for structured logging.
/// - Returns: 200 with `{"ok":true}` on success, or a 4xx JSON error response.
/// - Throws: DynamoDB errors.
func handleRegisterPasskey(event: APIGatewayRequest, context: LambdaContext) async throws -> APIGatewayResponse {
    guard let bodyString = event.body,
          let bodyData = bodyString.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
          let token = json["token"] as? String,
          let challengeId = json["challengeId"] as? String,
          let credential = json["credential"] as? [String: Any],
          let credentialId = credential["id"] as? String,
          let credResponse = credential["response"] as? [String: Any],
          let clientDataJSONB64 = credResponse["clientDataJSON"] as? String,
          let attestationObjectB64 = credResponse["attestationObject"] as? String
    else {
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Invalid request format"}"#
        )
    }

    // 1. Consume challenge
    guard let challengeRecord = try await store.consumeChallenge(challengeId: challengeId),
          challengeRecord.type == "registration",
          let challengeUsername = challengeRecord.username
    else {
        return APIGatewayResponse(
            statusCode: .unauthorized,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Invalid or expired challenge"}"#
        )
    }

    // 2. Consume registration token atomically
    guard let regToken = try await store.consumeRegistrationToken(token: token),
          regToken.username == challengeUsername
    else {
        return APIGatewayResponse(
            statusCode: .unauthorized,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Invalid or expired registration token"}"#
        )
    }

    // 3. Verify clientDataJSON
    guard let clientDataJSONData = base64urlDecode(clientDataJSONB64),
          let clientData = try? JSONSerialization.jsonObject(with: clientDataJSONData) as? [String: Any],
          let origin = clientData["origin"] as? String,
          let cdType = clientData["type"] as? String,
          let cdChallenge = clientData["challenge"] as? String
    else {
        return APIGatewayResponse(
            statusCode: .unauthorized,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Invalid clientDataJSON"}"#
        )
    }

    guard origin == "https://\(serverDomain)",
          cdType == "webauthn.create",
          cdChallenge == challengeRecord.challenge
    else {
        context.logger.error("Registration clientDataJSON validation failed: origin=\(origin), type=\(cdType)")
        return APIGatewayResponse(
            statusCode: .unauthorized,
            headers: ["content-type": "application/json"],
            body: #"{"error":"ClientDataJSON validation failed"}"#
        )
    }

    // 4. Parse attestation object to extract public key
    guard let attestationData = base64urlDecode(attestationObjectB64) else {
        return APIGatewayResponse(
            statusCode: .unauthorized,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Invalid attestation object"}"#
        )
    }

    // The attestation object is CBOR-encoded. We parse the authData from it.
    // For "none" attestation, we just need the authData.
    guard let authData = extractAuthDataFromAttestation(attestationData) else {
        return APIGatewayResponse(
            statusCode: .unauthorized,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Failed to parse attestation"}"#
        )
    }

    // Extract the credential public key from authData
    guard let (publicKeyBytes, algorithm) = extractPublicKeyFromAuthData(authData) else {
        return APIGatewayResponse(
            statusCode: .unauthorized,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Failed to extract public key"}"#
        )
    }

    let publicKeyB64 = base64urlEncode(Data(publicKeyBytes))
    let signCount = extractSignCount(from: authData)

    // 5. Store passkey
    try await store.storePasskey(
        credentialId: credentialId,
        username: regToken.username,
        publicKey: publicKeyB64,
        publicKeyAlg: algorithm,
        signCount: signCount
    )

    context.logger.info("Passkey registered for user \(regToken.username), credentialId=\(credentialId)")

    return APIGatewayResponse(
        statusCode: .ok,
        headers: ["content-type": "application/json"],
        body: #"{"ok":true}"#
    )
}

// MARK: - Registration Page

/// Renders the passkey registration HTML page for a given one-time registration token.
///
/// The token is passed as the `token` query parameter. If absent or invalid, an error
/// page is returned instead. The page's inline JavaScript drives the registration
/// ceremony against the `/api/internal/passkeys/*` endpoints.
///
/// - Parameter event: The API Gateway request; reads `event.queryStringParameters["token"]`.
/// - Returns: 200 with the registration page HTML, 400 if no token was provided,
///   or 401 if the token is invalid or expired.
/// - Throws: DynamoDB errors.
func handleRegisterPage(event: APIGatewayRequest) async throws -> APIGatewayResponse {
    let token = event.queryStringParameters["token"] ?? ""

    guard !token.isEmpty else {
        return renderAuthErrorPage(title: "Invalid Link", message: "No registration token provided.", badRequest: true)
    }

    guard let regToken = try await store.getRegistrationToken(token: token) else {
        return renderAuthErrorPage(title: "Invalid or Expired Link", message: "This registration link is invalid or has expired. Please request a new one.")
    }

    let page = RegisterPage(username: regToken.username, token: token, domain: serverDomain)
    let html = page.render()

    return APIGatewayResponse(
        statusCode: .ok,
        headers: [
            "content-type": "text/html; charset=utf-8",
            "cache-control": "no-store",
        ],
        body: html
    )
}

// MARK: - Login Page

/// Renders the passkey login HTML page.
///
/// The page's inline JavaScript drives the authentication ceremony against
/// `/api/internal/auth/challenge` and `/api/internal/auth/verify`. On success it
/// redirects to `/compose`.
func renderLoginPage() -> APIGatewayResponse {
    let page = LoginPage(domain: serverDomain)
    let html = page.render()

    return APIGatewayResponse(
        statusCode: .ok,
        headers: [
            "content-type": "text/html; charset=utf-8",
            "cache-control": "no-store",
        ],
        body: html
    )
}

/// Renders an HTML error page with the given title and message.
///
/// - Parameters:
///   - title: Heading text displayed on the page and in the browser tab.
///   - message: Body text describing the error.
///   - badRequest: If `true`, returns HTTP 400; otherwise returns HTTP 401.
func renderAuthErrorPage(title: String, message: String, badRequest: Bool = false) -> APIGatewayResponse {
    let page = AuthErrorPage(errorTitle: title, message: message, domain: serverDomain)
    let html = page.render()

    return APIGatewayResponse(
        statusCode: badRequest ? .badRequest : .unauthorized,
        headers: [
            "content-type": "text/html; charset=utf-8",
            "cache-control": "no-store",
        ],
        body: html
    )
}

// MARK: - WebAuthn Crypto Helpers

/// Verify an ES256 (ECDSA P-256 SHA-256) signature.
/// publicKeyData is the raw uncompressed public key (65 bytes: 0x04 + X + Y)
/// or the COSE-decoded X+Y coordinates (64 bytes).
func verifyES256Signature(signature: Data, data: Data, publicKeyData: Data) -> Bool {
    do {
        // The public key from COSE is the raw X||Y coordinates (64 bytes)
        // or uncompressed format (65 bytes starting with 0x04)
        let rawKey: P256.Signing.PublicKey
        if publicKeyData.count == 65 && publicKeyData[publicKeyData.startIndex] == 0x04 {
            rawKey = try P256.Signing.PublicKey(x963Representation: publicKeyData)
        } else if publicKeyData.count == 64 {
            var x963 = Data([0x04])
            x963.append(publicKeyData)
            rawKey = try P256.Signing.PublicKey(x963Representation: x963)
        } else {
            return false
        }

        // WebAuthn signature is DER-encoded, swift-crypto expects DER
        let ecdsaSignature = try P256.Signing.ECDSASignature(derRepresentation: signature)
        return rawKey.isValidSignature(ecdsaSignature, for: data)
    } catch {
        return false
    }
}

/// Extracts the sign count from authenticator data (bytes 33–36, big-endian UInt32).
///
/// Returns 0 if `authData` is shorter than 37 bytes, which is treated as a
/// counter-not-supported authenticator.
///
/// - Parameter authData: Raw authenticator data bytes from the WebAuthn assertion.
/// - Returns: The sign count as an `Int`, or 0 if unavailable.
func extractSignCount(from authData: Data) -> Int {
    guard authData.count >= 37 else { return 0 }
    let offset = authData.startIndex + 33
    let sc = UInt32(authData[offset]) << 24
        | UInt32(authData[offset + 1]) << 16
        | UInt32(authData[offset + 2]) << 8
        | UInt32(authData[offset + 3])
    return Int(sc)
}

/// Extracts the `authData` field from a CBOR-encoded WebAuthn attestation object.
///
/// The attestation object is a CBOR map with string keys `"fmt"`, `"attStmt"`, and
/// `"authData"`. This function parses that map and returns the raw bytes stored under
/// `"authData"`.
///
/// - Parameter data: The raw attestation object bytes from the WebAuthn registration response.
/// - Returns: The `authData` bytes, or `nil` if parsing fails.
func extractAuthDataFromAttestation(_ data: Data) -> Data? {
    // Parse CBOR map
    guard let (map, _) = parseCBORMap(data, at: data.startIndex) else { return nil }
    return map["authData"]
}

/// Extracts the public key and algorithm identifier from WebAuthn authenticator data.
///
/// The `authData` layout is: `rpIdHash(32) + flags(1) + signCount(4) +
/// aaguid(16) + credIdLen(2) + credId(credIdLen) + COSE_Key(CBOR)`.
/// This function reads the attested credential data section (present when the AT flag,
/// bit 6, is set) and parses the COSE public key map to get the raw X and Y
/// coordinates of the EC2 key.
///
/// - Parameter authData: Raw authenticator data bytes from the attestation response.
/// - Returns: A tuple of `(X||Y bytes, COSE algorithm identifier)`, or `nil` if the
///   data is malformed or the AT flag is not set.
func extractPublicKeyFromAuthData(_ authData: Data) -> (Data, Int)? {
    guard authData.count > 37 else { return nil }

    let flags = authData[authData.startIndex + 32]
    // Bit 6 (AT): attested credential data included
    guard flags & 0x40 != 0 else { return nil }

    var offset = authData.startIndex + 37  // past rpIdHash + flags + signCount

    // Skip AAGUID (16 bytes)
    offset += 16
    guard offset + 2 <= authData.endIndex else { return nil }

    // Credential ID length (big-endian uint16)
    let credIdLen = Int(authData[offset]) << 8 | Int(authData[offset + 1])
    offset += 2

    // Skip credential ID
    offset += credIdLen
    guard offset < authData.endIndex else { return nil }

    // Parse COSE public key (CBOR)
    guard let (coseMap, _) = parseCBORMapInt(authData, at: offset) else { return nil }

    // COSE key type 2 = EC2, algorithm -7 = ES256
    guard let ktyData = coseMap[1], cborToInt(ktyData) == 2 else { return nil }
    let algorithm = coseMap[3].flatMap { cborToInt($0) } ?? -7

    // -1 = curve (1 = P-256), -2 = x, -3 = y
    guard let xCoord = coseMap[-2], let yCoord = coseMap[-3] else { return nil }

    var publicKey = Data()
    publicKey.append(xCoord)
    publicKey.append(yCoord)

    return (publicKey, algorithm)
}

// MARK: - Minimal CBOR Parser

/// Parses a CBOR map with text-string keys, returning each value as its raw CBOR bytes.
///
/// Only major type 5 (map) is accepted at `startOffset`. Values are returned as raw
/// `Data` slices so callers can further decode them with type-specific parsers.
///
/// - Parameters:
///   - data: The full CBOR-encoded buffer.
///   - startOffset: Byte offset within `data` where the map starts.
/// - Returns: A dictionary mapping string keys to raw value bytes, and the offset
///   immediately after the map, or `nil` if parsing fails.
func parseCBORMap(_ data: Data, at startOffset: Int) -> ([String: Data], Int)? {
    guard startOffset < data.endIndex else { return nil }

    let majorByte = data[startOffset]
    let majorType = majorByte >> 5
    guard majorType == 5 else { return nil }  // Map

    let additionalInfo = majorByte & 0x1F
    var offset = startOffset + 1
    let count: Int

    if additionalInfo < 24 {
        count = Int(additionalInfo)
    } else if additionalInfo == 24 {
        guard offset < data.endIndex else { return nil }
        count = Int(data[offset])
        offset += 1
    } else {
        return nil
    }

    var result: [String: Data] = [:]

    for _ in 0..<count {
        // Parse key (text string)
        guard let (key, nextOffset) = parseCBORString(data, at: offset) else { return nil }
        offset = nextOffset

        // Parse value (we'll capture the raw bytes)
        guard let (value, valueEnd) = parseCBORRawValue(data, at: offset) else { return nil }
        result[key] = value
        offset = valueEnd
    }

    return (result, offset)
}

/// Parses a CBOR map with integer keys, returning each value as its raw CBOR bytes.
///
/// Used specifically to decode COSE key maps, where keys are signed integers (e.g.
/// 1 = kty, 3 = alg, -2 = x, -3 = y).
///
/// - Parameters:
///   - data: The full CBOR-encoded buffer.
///   - startOffset: Byte offset within `data` where the map starts.
/// - Returns: A dictionary mapping integer keys to raw value bytes, and the offset
///   immediately after the map, or `nil` if parsing fails.
func parseCBORMapInt(_ data: Data, at startOffset: Int) -> ([Int: Data], Int)? {
    guard startOffset < data.endIndex else { return nil }

    let majorByte = data[startOffset]
    let majorType = majorByte >> 5
    guard majorType == 5 else { return nil }

    let additionalInfo = majorByte & 0x1F
    var offset = startOffset + 1
    let count: Int

    if additionalInfo < 24 {
        count = Int(additionalInfo)
    } else if additionalInfo == 24 {
        guard offset < data.endIndex else { return nil }
        count = Int(data[offset])
        offset += 1
    } else {
        return nil
    }

    var result: [Int: Data] = [:]

    for _ in 0..<count {
        // Parse key (integer - positive or negative)
        guard let (key, nextOffset) = parseCBORInt(data, at: offset) else { return nil }
        offset = nextOffset

        // Parse value as raw bytes
        guard let (value, valueEnd) = parseCBORRawValue(data, at: offset) else { return nil }
        result[key] = value
        offset = valueEnd
    }

    return (result, offset)
}

/// Parses a CBOR text string (major type 3) at the given offset.
///
/// - Parameters:
///   - data: The full CBOR-encoded buffer.
///   - offset: Byte offset within `data` where the text string starts.
/// - Returns: The decoded UTF-8 string and the offset immediately after it,
///   or `nil` if the byte at `offset` is not major type 3 or the data is truncated.
func parseCBORString(_ data: Data, at offset: Int) -> (String, Int)? {
    guard offset < data.endIndex else { return nil }
    let majorByte = data[offset]
    let majorType = majorByte >> 5
    guard majorType == 3 else { return nil }  // Text string

    let additionalInfo = majorByte & 0x1F
    var pos = offset + 1
    let length: Int

    if additionalInfo < 24 {
        length = Int(additionalInfo)
    } else if additionalInfo == 24 {
        guard pos < data.endIndex else { return nil }
        length = Int(data[pos])
        pos += 1
    } else if additionalInfo == 25 {
        guard pos + 2 <= data.endIndex else { return nil }
        length = Int(data[pos]) << 8 | Int(data[pos + 1])
        pos += 2
    } else {
        return nil
    }

    guard pos + length <= data.endIndex else { return nil }
    let strData = data[pos..<(pos + length)]
    guard let str = String(data: strData, encoding: .utf8) else { return nil }
    return (str, pos + length)
}

/// Parses a CBOR integer (major type 0 = unsigned, major type 1 = negative) at the given offset.
///
/// - Parameters:
///   - data: The full CBOR-encoded buffer.
///   - offset: Byte offset within `data` where the integer starts.
/// - Returns: The decoded `Int` value and the offset immediately after it,
///   or `nil` if the major type is not 0 or 1 or the data is truncated.
func parseCBORInt(_ data: Data, at offset: Int) -> (Int, Int)? {
    guard offset < data.endIndex else { return nil }
    let majorByte = data[offset]
    let majorType = majorByte >> 5
    let additionalInfo = majorByte & 0x1F
    var pos = offset + 1

    let rawValue: UInt64

    if additionalInfo < 24 {
        rawValue = UInt64(additionalInfo)
    } else if additionalInfo == 24 {
        guard pos < data.endIndex else { return nil }
        rawValue = UInt64(data[pos])
        pos += 1
    } else if additionalInfo == 25 {
        guard pos + 2 <= data.endIndex else { return nil }
        rawValue = UInt64(data[pos]) << 8 | UInt64(data[pos + 1])
        pos += 2
    } else if additionalInfo == 26 {
        guard pos + 4 <= data.endIndex else { return nil }
        rawValue = UInt64(data[pos]) << 24 | UInt64(data[pos + 1]) << 16
            | UInt64(data[pos + 2]) << 8 | UInt64(data[pos + 3])
        pos += 4
    } else {
        return nil
    }

    switch majorType {
    case 0: return (Int(rawValue), pos)  // Unsigned integer
    case 1: return (-1 - Int(rawValue), pos)  // Negative integer
    default: return nil
    }
}

/// Parses any CBOR value at the given offset and returns its raw bytes.
///
/// For byte strings (major type 2), the returned `Data` contains the decoded payload
/// bytes (not the CBOR header). For all other types the full CBOR encoding including
/// the header byte is returned. This lets callers pass the result to ``cborToInt(_:)``
/// or recurse into nested structures.
///
/// - Parameters:
///   - data: The full CBOR-encoded buffer.
///   - offset: Byte offset within `data` where the value starts.
/// - Returns: The raw bytes for the value and the offset immediately after it,
///   or `nil` if the data is truncated or the major type is unsupported.
func parseCBORRawValue(_ data: Data, at offset: Int) -> (Data, Int)? {
    guard offset < data.endIndex else { return nil }
    let majorByte = data[offset]
    let majorType = majorByte >> 5
    let additionalInfo = majorByte & 0x1F

    switch majorType {
    case 0, 1:  // Unsigned/Negative integer
        if additionalInfo < 24 {
            return (Data([majorByte]), offset + 1)
        } else if additionalInfo == 24 {
            guard offset + 2 <= data.endIndex else { return nil }
            return (Data(data[offset..<(offset + 2)]), offset + 2)
        } else if additionalInfo == 25 {
            guard offset + 3 <= data.endIndex else { return nil }
            return (Data(data[offset..<(offset + 3)]), offset + 3)
        } else if additionalInfo == 26 {
            guard offset + 5 <= data.endIndex else { return nil }
            return (Data(data[offset..<(offset + 5)]), offset + 5)
        } else if additionalInfo == 27 {
            guard offset + 9 <= data.endIndex else { return nil }
            return (Data(data[offset..<(offset + 9)]), offset + 9)
        }
        return nil

    case 2:  // Byte string - return the raw bytes
        var pos = offset + 1
        let length: Int
        if additionalInfo < 24 {
            length = Int(additionalInfo)
        } else if additionalInfo == 24 {
            guard pos < data.endIndex else { return nil }
            length = Int(data[pos])
            pos += 1
        } else if additionalInfo == 25 {
            guard pos + 2 <= data.endIndex else { return nil }
            length = Int(data[pos]) << 8 | Int(data[pos + 1])
            pos += 2
        } else {
            return nil
        }
        guard pos + length <= data.endIndex else { return nil }
        return (Data(data[pos..<(pos + length)]), pos + length)

    case 3:  // Text string
        var pos = offset + 1
        let length: Int
        if additionalInfo < 24 {
            length = Int(additionalInfo)
        } else if additionalInfo == 24 {
            guard pos < data.endIndex else { return nil }
            length = Int(data[pos])
            pos += 1
        } else if additionalInfo == 25 {
            guard pos + 2 <= data.endIndex else { return nil }
            length = Int(data[pos]) << 8 | Int(data[pos + 1])
            pos += 2
        } else {
            return nil
        }
        guard pos + length <= data.endIndex else { return nil }
        return (Data(data[pos..<(pos + length)]), pos + length)

    case 4:  // Array
        var pos = offset + 1
        let count: Int
        if additionalInfo < 24 {
            count = Int(additionalInfo)
        } else if additionalInfo == 24 {
            guard pos < data.endIndex else { return nil }
            count = Int(data[pos])
            pos += 1
        } else {
            return nil
        }
        for _ in 0..<count {
            guard let (_, nextPos) = parseCBORRawValue(data, at: pos) else { return nil }
            pos = nextPos
        }
        return (Data(data[offset..<pos]), pos)

    case 5:  // Map
        var pos = offset + 1
        let count: Int
        if additionalInfo < 24 {
            count = Int(additionalInfo)
        } else if additionalInfo == 24 {
            guard pos < data.endIndex else { return nil }
            count = Int(data[pos])
            pos += 1
        } else {
            return nil
        }
        for _ in 0..<count {
            guard let (_, keyEnd) = parseCBORRawValue(data, at: pos) else { return nil }
            guard let (_, valEnd) = parseCBORRawValue(data, at: keyEnd) else { return nil }
            pos = valEnd
        }
        return (Data(data[offset..<pos]), pos)

    case 7:  // Simple/float
        if additionalInfo < 24 {
            return (Data([majorByte]), offset + 1)
        } else if additionalInfo == 24 {
            guard offset + 2 <= data.endIndex else { return nil }
            return (Data(data[offset..<(offset + 2)]), offset + 2)
        } else if additionalInfo == 25 {
            guard offset + 3 <= data.endIndex else { return nil }
            return (Data(data[offset..<(offset + 3)]), offset + 3)
        }
        return nil

    default:
        return nil
    }
}

/// Decodes a CBOR integer from raw bytes previously returned by ``parseCBORRawValue(_:at:)``.
///
/// - Parameter data: Raw CBOR bytes beginning with the major-type/additional-info byte.
/// - Returns: The decoded integer, or `nil` if the data is not a CBOR integer type.
func cborToInt(_ data: Data) -> Int? {
    guard !data.isEmpty else { return nil }
    let majorByte = data[data.startIndex]
    let majorType = majorByte >> 5
    let additionalInfo = majorByte & 0x1F

    let rawValue: UInt64
    if additionalInfo < 24 {
        rawValue = UInt64(additionalInfo)
    } else if additionalInfo == 24, data.count >= 2 {
        rawValue = UInt64(data[data.startIndex + 1])
    } else if additionalInfo == 25, data.count >= 3 {
        rawValue = UInt64(data[data.startIndex + 1]) << 8 | UInt64(data[data.startIndex + 2])
    } else if additionalInfo == 26, data.count >= 5 {
        rawValue = UInt64(data[data.startIndex + 1]) << 24 | UInt64(data[data.startIndex + 2]) << 16
            | UInt64(data[data.startIndex + 3]) << 8 | UInt64(data[data.startIndex + 4])
    } else {
        return nil
    }

    switch majorType {
    case 0: return Int(rawValue)
    case 1: return -1 - Int(rawValue)
    default: return nil
    }
}

// MARK: - Random Helpers

/// Generates a random hex string by producing `byteCount` random bytes.
///
/// - Parameter byteCount: Number of random bytes to generate; the returned string
///   is `byteCount * 2` characters long.
/// - Returns: A lowercase hexadecimal string.
func generateRandomHex(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

/// Generates an array of `count` cryptographically random bytes.
func generateRandomBytes(count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
    return bytes
}

// MARK: - Login Page

/// The passkey login page rendered by ``renderLoginPage()``.
///
/// Contains inline JavaScript that drives the full WebAuthn authentication ceremony
/// against `/api/internal/auth/challenge` and `/api/internal/auth/verify`.
/// On successful authentication the browser is redirected to `/compose`.
struct LoginPage: HTMLDocument {
    /// The server domain, used to construct the stylesheet URL and as the WebAuthn RP ID.
    var domain: String

    var title: String { "Sign in - \(instanceTitle)" }
    var lang: String { "en" }

    var bodyAttributes: [HTMLAttribute<HTMLTag.body>] {
        [.class("latex-dark-auto")]
    }

    var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
        link(.rel("stylesheet"), .href("https://\(domain)/media/frontend/latex.min.css"))
        HTMLRaw("""
        <style>
            .auth-container { max-width: 400px; margin: 4rem auto; text-align: center; }
            .auth-btn { display: inline-block; padding: 0.8rem 2rem; font-size: 1.1rem; cursor: pointer; border: 1px solid #333; background: #fff; border-radius: 4px; }
            .auth-btn:hover { background: #f0f0f0; }
            .auth-status { margin-top: 1rem; min-height: 1.5rem; }
            .error { color: #c00; }
            .success { color: #080; }
            @media (prefers-color-scheme: dark) {
                .auth-btn { background: #2a2a2a; color: #ddd; border-color: #555; }
                .auth-btn:hover { background: #333; }
            }
        </style>
        """)
    }

    var body: some HTML {
        article(.class("auth-container")) {
            h1 { "Sign in to \(instanceTitle)" }
            p { "Use your passkey to sign in." }

            button(.class("auth-btn"), .id("login-btn")) { "Sign in with passkey" }

            p(.class("auth-status"), .id("status")) { "" }
        }

        HTMLRaw("""
        <script>
        const BASE = window.location.pathname.replace(/\\/auth\\/login.*/, '');
        document.getElementById('login-btn').addEventListener('click', async () => {
            const status = document.getElementById('status');
            const btn = document.getElementById('login-btn');
            btn.disabled = true;
            status.textContent = 'Starting authentication...';
            status.className = 'auth-status';
            try {
                const challengeResp = await fetch(BASE + '/api/internal/auth/challenge', { method: 'POST' });
                if (!challengeResp.ok) throw new Error('Failed to get challenge');
                const challengeData = await challengeResp.json();

                const challengeBytes = Uint8Array.from(atob(challengeData.challenge.replace(/-/g,'+').replace(/_/g,'/')), c => c.charCodeAt(0));

                const assertion = await navigator.credentials.get({
                    publicKey: {
                        challenge: challengeBytes,
                        rpId: challengeData.rpId,
                        timeout: challengeData.timeout,
                        userVerification: challengeData.userVerification,
                    }
                });

                const verifyResp = await fetch(BASE + '/api/internal/auth/verify', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        challengeId: challengeData.challengeId,
                        credential: {
                            id: assertion.id,
                            rawId: btoa(String.fromCharCode(...new Uint8Array(assertion.rawId))).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=/g,''),
                            type: assertion.type,
                            response: {
                                clientDataJSON: btoa(String.fromCharCode(...new Uint8Array(assertion.response.clientDataJSON))).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=/g,''),
                                authenticatorData: btoa(String.fromCharCode(...new Uint8Array(assertion.response.authenticatorData))).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=/g,''),
                                signature: btoa(String.fromCharCode(...new Uint8Array(assertion.response.signature))).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=/g,''),
                            }
                        }
                    })
                });

                if (!verifyResp.ok) {
                    const err = await verifyResp.json();
                    throw new Error(err.error || 'Authentication failed');
                }

                status.textContent = 'Authenticated! Redirecting...';
                status.className = 'auth-status success';
                window.location.href = '/compose';
            } catch (e) {
                status.textContent = e.message || 'Authentication failed';
                status.className = 'auth-status error';
                btn.disabled = false;
            }
        });
        </script>
        """)
    }
}

// MARK: - Register Page

/// The passkey registration page rendered by ``handleRegisterPage(event:)``.
///
/// Contains inline JavaScript that drives the WebAuthn registration ceremony against
/// `/api/internal/passkeys/register-challenge` and `/api/internal/passkeys/register`.
/// The one-time registration token is embedded directly in the page's JavaScript so
/// the browser can include it in both API calls.
struct RegisterPage: HTMLDocument {
    /// The username being registered, displayed on the page.
    var username: String
    /// The one-time registration token, embedded in the page's JavaScript.
    var token: String
    /// The server domain, used to construct the stylesheet URL and as the WebAuthn RP ID.
    var domain: String

    var title: String { "Register passkey - \(instanceTitle)" }
    var lang: String { "en" }

    var bodyAttributes: [HTMLAttribute<HTMLTag.body>] {
        [.class("latex-dark-auto")]
    }

    var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
        link(.rel("stylesheet"), .href("https://\(domain)/media/frontend/latex.min.css"))
        HTMLRaw("""
        <style>
            .auth-container { max-width: 400px; margin: 4rem auto; text-align: center; }
            .auth-btn { display: inline-block; padding: 0.8rem 2rem; font-size: 1.1rem; cursor: pointer; border: 1px solid #333; background: #fff; border-radius: 4px; }
            .auth-btn:hover { background: #f0f0f0; }
            .auth-status { margin-top: 1rem; min-height: 1.5rem; }
            .error { color: #c00; }
            .success { color: #080; }
            @media (prefers-color-scheme: dark) {
                .auth-btn { background: #2a2a2a; color: #ddd; border-color: #555; }
                .auth-btn:hover { background: #333; }
            }
        </style>
        """)
    }

    var body: some HTML {
        article(.class("auth-container")) {
            h1 { "Register a passkey" }
            p { "Registering passkey for " }
            p { strong { username } }

            button(.class("auth-btn"), .id("register-btn")) { "Register passkey" }

            p(.class("auth-status"), .id("status")) { "" }
        }

        HTMLRaw("""
        <script>
        const TOKEN = '\(escapeJSON(token))';
        // Detect API base path (handles /Prod prefix on API Gateway direct access)
        const BASE = window.location.pathname.replace(/\\/auth\\/register.*/, '');
        document.getElementById('register-btn').addEventListener('click', async () => {
            const status = document.getElementById('status');
            const btn = document.getElementById('register-btn');
            btn.disabled = true;
            status.textContent = 'Starting registration...';
            status.className = 'auth-status';
            try {
                const challengeResp = await fetch(BASE + '/api/internal/passkeys/register-challenge', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ token: TOKEN })
                });
                if (!challengeResp.ok) {
                    const err = await challengeResp.json();
                    throw new Error(err.error || 'Failed to get challenge');
                }
                const options = await challengeResp.json();

                const challengeBytes = Uint8Array.from(atob(options.challenge.replace(/-/g,'+').replace(/_/g,'/')), c => c.charCodeAt(0));
                const userIdBytes = Uint8Array.from(atob(options.user.id.replace(/-/g,'+').replace(/_/g,'/')), c => c.charCodeAt(0));

                const credential = await navigator.credentials.create({
                    publicKey: {
                        challenge: challengeBytes,
                        rp: options.rp,
                        user: { id: userIdBytes, name: options.user.name, displayName: options.user.displayName },
                        pubKeyCredParams: options.pubKeyCredParams,
                        timeout: options.timeout,
                        attestation: options.attestation,
                        authenticatorSelection: options.authenticatorSelection,
                    }
                });

                const regResp = await fetch(BASE + '/api/internal/passkeys/register', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        token: TOKEN,
                        challengeId: options.challengeId,
                        credential: {
                            id: credential.id,
                            rawId: btoa(String.fromCharCode(...new Uint8Array(credential.rawId))).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=/g,''),
                            type: credential.type,
                            response: {
                                clientDataJSON: btoa(String.fromCharCode(...new Uint8Array(credential.response.clientDataJSON))).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=/g,''),
                                attestationObject: btoa(String.fromCharCode(...new Uint8Array(credential.response.attestationObject))).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=/g,''),
                            }
                        }
                    })
                });

                if (!regResp.ok) {
                    const err = await regResp.json();
                    throw new Error(err.error || 'Registration failed');
                }

                status.textContent = '';
                status.appendChild(document.createTextNode('Passkey registered! '));
                const link = document.createElement('a');
                link.href = '/auth/login';
                link.textContent = 'Sign in now';
                status.appendChild(link);
                status.className = 'auth-status success';
            } catch (e) {
                status.textContent = e.message || 'Registration failed';
                status.className = 'auth-status error';
                btn.disabled = false;
            }
        });
        </script>
        """)
    }
}

// MARK: - Error Page

/// A minimal error page rendered when authentication or registration fails.
struct AuthErrorPage: HTMLDocument {
    /// Heading text displayed in the page body and browser tab.
    var errorTitle: String
    /// Body text describing the error.
    var message: String
    /// The server domain, used to construct the stylesheet URL.
    var domain: String

    var title: String { "\(errorTitle) - \(instanceTitle)" }
    var lang: String { "en" }

    var bodyAttributes: [HTMLAttribute<HTMLTag.body>] {
        [.class("latex-dark-auto")]
    }

    var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
        link(.rel("stylesheet"), .href("https://\(domain)/media/frontend/latex.min.css"))
    }

    var body: some HTML {
        article {
            h1 { errorTitle }
            p { message }
        }
    }
}

// MARK: - Shared Helpers

/// Escapes a string for safe embedding in a JSON string literal.
///
/// Handles backslash, double-quote, newline, carriage return, and tab. Used when
/// building JSON responses by string interpolation rather than `JSONEncoder`.
///
/// - Parameter str: The raw string to escape.
/// - Returns: The escaped string, safe to place between JSON double quotes.
func escapeJSON(_ str: String) -> String {
    str.replacingOccurrences(of: "\\", with: "\\\\")
       .replacingOccurrences(of: "\"", with: "\\\"")
       .replacingOccurrences(of: "\n", with: "\\n")
       .replacingOccurrences(of: "\r", with: "\\r")
       .replacingOccurrences(of: "\t", with: "\\t")
}
