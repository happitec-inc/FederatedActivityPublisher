import Foundation

/// A one-time registration token for passkey enrollment.
public struct RegistrationToken: Sendable {
    public let token: String
    public let username: String

    public init(token: String, username: String) {
        self.token = token
        self.username = username
    }
}
