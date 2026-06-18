/// A one-time token that authorizes passkey enrollment for a specific user.
///
/// The `ProvisionHandler` (or the `provision-actor` workflow) generates a registration token
/// and returns it to the operator. The operator hands it to the user out-of-band. When the user
/// starts passkey registration, the `RegistrationStartHandler` validates the token against a
/// DynamoDB record under `PK=REG_TOKEN#{token}`, creates a ``ChallengeRecord``, and deletes the
/// token so it cannot be reused.
import Foundation

/// A one-time registration token for passkey enrollment.
public struct RegistrationToken: Sendable {
    /// The raw token string. This is the value exchanged out-of-band with the user.
    public let token: String
    /// The username the token permits registering a passkey for.
    public let username: String

    /// Create a RegistrationToken.
    ///
    /// - Parameters:
    ///   - token: The raw token string (typically a random hex or base64url value).
    ///   - username: The username this token is scoped to.
    public init(token: String, username: String) {
        self.token = token
        self.username = username
    }
}
