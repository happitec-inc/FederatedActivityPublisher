import AWSSSM
import Foundation

/// Result of bearer token authentication.
public struct BearerAuthResult: Sendable {
    public let username: String

    public init(username: String) {
        self.username = username
    }
}

/// Error type for bearer auth failures.
public enum BearerAuthError: Error, Sendable {
    case missingHeader
    case serverConfigError(String)
    case invalidToken
}

/// Validate a bearer token from an Authorization header against SSM-stored credentials.
///
/// Token format in SSM: "username:token" stored at `{ssmKeyPrefix}/client-token`.
///
/// - Parameters:
///   - authHeader: The raw Authorization header value (e.g. "Bearer abc123").
///   - ssmKeyPrefix: The SSM parameter path prefix (e.g. "/activity/stage/keys").
///   - ssmClient: An initialized SSM client.
/// - Returns: A `BearerAuthResult` containing the authenticated username.
/// - Throws: `BearerAuthError` on failure.
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
    // Always iterate over stored length to keep timing constant
    for i in 0..<storedBytes.count {
        result |= storedBytes[i] ^ (i < tokenBytes.count ? tokenBytes[i] : ~storedBytes[i])
    }
    guard tokenBytes.count == storedBytes.count, result == 0 else {
        throw BearerAuthError.invalidToken
    }

    return BearerAuthResult(username: username)
}
