import AWSSSM
import Foundation

/// Result of a successful bearer token authentication.
///
/// Contains the username and scope from the token record.
public struct BearerAuthResult: Sendable {
    /// The authenticated username.
    public let username: String
    /// Space-separated scopes granted by this token (e.g. "read write").
    /// Nil when authenticated via the legacy SSM fallback path.
    public let scope: String?

    public init(username: String, scope: String? = nil) {
        self.username = username
        self.scope = scope
    }
}

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

/// Errors thrown during bearer token authentication.
public enum BearerAuthError: Error, Sendable {
    /// The Authorization header is missing or does not start with `Bearer `.
    case missingHeader
    /// The SSM parameter storing the token is missing or malformed.
    case serverConfigError(String)
    /// The provided token does not match the stored token.
    case invalidToken
    /// The JWT session cookie has expired.
    case sessionExpired
}

/// Validate a bearer token against DynamoDB first, falling back to SSM.
///
/// **Phase 1 migration**: Tries DynamoDB token lookup (by SHA-256 hash) first.
/// On miss, falls back to the legacy SSM `username:token` parameter. SSM fallback
/// hits are logged so we know when it is safe to remove the fallback path.
///
/// - Parameters:
///   - authHeader: The raw Authorization header value (e.g. "Bearer abc123").
///   - store: The DynamoDB store for token lookup.
///   - ssmKeyPrefix: The SSM parameter path prefix (e.g. "/activity/stage/keys").
///   - ssmClient: An initialized SSM client for fallback lookup.
/// - Returns: A `BearerAuthResult` containing the authenticated username and scope.
/// - Throws: `BearerAuthError` on failure.
public func authenticateBearer(
    authHeader: String,
    store: DynamoDBStore,
    ssmKeyPrefix: String,
    ssmClient: SSMClient
) async throws -> BearerAuthResult {
    guard authHeader.lowercased().hasPrefix("bearer ") else {
        throw BearerAuthError.missingHeader
    }
    let token = String(authHeader.dropFirst(7)).trimmingCharacters(in: .whitespaces)

    // 1. Try DynamoDB token lookup (new path)
    if let record = try await store.getBearerToken(token: token) {
        return BearerAuthResult(username: record.username, scope: record.scope)
    }

    // 2. Fall back to SSM (legacy path -- log for migration tracking)
    let tokenParamName = "\(ssmKeyPrefix)/client-token"
    let tokenOutput: GetParameterOutput
    do {
        tokenOutput = try await ssmClient.getParameter(input: GetParameterInput(
            name: tokenParamName,
            withDecryption: true
        ))
    } catch {
        throw BearerAuthError.invalidToken
    }
    guard let storedValue = tokenOutput.parameter?.value else {
        throw BearerAuthError.serverConfigError("Client token not configured at \(tokenParamName)")
    }

    let parts = storedValue.split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else {
        throw BearerAuthError.serverConfigError("Invalid client token format in SSM")
    }
    let username = String(parts[0])
    let storedToken = String(parts[1])

    // Constant-time comparison to prevent timing attacks
    let tokenBytes = Array(token.utf8)
    let storedBytes = Array(storedToken.utf8)
    var result: UInt8 = 0
    // Always iterate over stored length to keep timing constant
    for i in 0..<storedBytes.count {
        result |= storedBytes[i] ^ (i < tokenBytes.count ? tokenBytes[i] : ~storedBytes[i])
    }
    guard tokenBytes.count == storedBytes.count, result == 0 else {
        throw BearerAuthError.invalidToken
    }

    // Log SSM fallback hit for migration monitoring
    print(#"{"event":"ssm_fallback_auth","username":"\#(username)","message":"Token authenticated via SSM fallback -- migrate to DynamoDB"}"#)

    return BearerAuthResult(username: username, scope: nil)
}

/// Legacy SSM-only bearer token authentication.
///
/// Preserved for backward compatibility during migration. Callers that have not
/// yet been updated to pass a `DynamoDBStore` can continue using this function.
/// New code should use the overload that accepts `store:`.
public func authenticateBearer(
    authHeader: String,
    ssmKeyPrefix: String,
    ssmClient: SSMClient
) async throws -> BearerAuthResult {
    guard authHeader.lowercased().hasPrefix("bearer ") else {
        throw BearerAuthError.missingHeader
    }
    let token = String(authHeader.dropFirst(7)).trimmingCharacters(in: .whitespaces)

    let tokenParamName = "\(ssmKeyPrefix)/client-token"
    let tokenOutput = try await ssmClient.getParameter(input: GetParameterInput(
        name: tokenParamName,
        withDecryption: true
    ))
    guard let storedValue = tokenOutput.parameter?.value else {
        throw BearerAuthError.serverConfigError("Client token not configured at \(tokenParamName)")
    }

    let parts = storedValue.split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else {
        throw BearerAuthError.serverConfigError("Invalid client token format in SSM")
    }
    let username = String(parts[0])
    let storedToken = String(parts[1])

    // Constant-time comparison to prevent timing attacks
    let tokenBytes = Array(token.utf8)
    let storedBytes = Array(storedToken.utf8)
    var result: UInt8 = 0
    for i in 0..<storedBytes.count {
        result |= storedBytes[i] ^ (i < tokenBytes.count ? tokenBytes[i] : ~storedBytes[i])
    }
    guard tokenBytes.count == storedBytes.count, result == 0 else {
        throw BearerAuthError.invalidToken
    }

    return BearerAuthResult(username: username)
}

/// Authenticate a request using either bearer token or session cookie.
///
/// Checks Authorization header first (bearer token via DynamoDB with SSM fallback),
/// then falls back to session cookie (JWT). Returns the auth method used so callers
/// can vary response format (401 JSON for API clients, 302 redirect for browsers).
public func authenticateRequest(
    authHeader: String,
    cookies: String?,
    store: DynamoDBStore,
    ssmKeyPrefix: String,
    ssmClient: SSMClient,
    signingKey: String,
    serverDomain: String
) async throws -> RequestAuthResult {
    // 1. Try bearer token first (DynamoDB -> SSM fallback)
    if authHeader.lowercased().hasPrefix("bearer ") {
        let result = try await authenticateBearer(
            authHeader: authHeader,
            store: store,
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

/// Legacy authenticateRequest without DynamoDB store parameter.
///
/// Preserved for backward compatibility. New code should use the overload
/// that accepts `store:`.
public func authenticateRequest(
    authHeader: String,
    cookies: String?,
    ssmKeyPrefix: String,
    ssmClient: SSMClient,
    signingKey: String,
    serverDomain: String
) async throws -> RequestAuthResult {
    // 1. Try bearer token first (SSM only)
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
public func extractCookie(name: String, from cookieHeader: String) -> String? {
    let pairs = cookieHeader.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    for pair in pairs {
        let parts = pair.split(separator: "=", maxSplits: 1)
        if parts.count == 2 && parts[0] == name {
            return String(parts[1])
        }
    }
    return nil
}
