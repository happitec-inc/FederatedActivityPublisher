/// `register-passkey` subcommand: generates a one-time URL for passkey registration.
///
/// Passkeys are a WebAuthn credential tied to an actor account. This command:
/// 1. Verifies the actor exists in DynamoDB.
/// 2. Generates a 32-byte random registration token (hex-encoded).
/// 3. Writes the token to DynamoDB via `DynamoDBStore.storeRegistrationToken`, where it
///    expires after 15 minutes.
/// 4. Prints the full registration URL to stdout.
///
/// The registration token in the URL is single-use and time-limited. The actor must complete
/// the passkey registration flow at the printed URL before it expires. The table name defaults
/// to the `TABLE_NAME` environment variable, which the operator sets when running the CLI.
import ArgumentParser
import ActivityPubCore
import Foundation

/// Generates a one-time passkey registration URL for an existing actor.
struct RegisterPasskey: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "register-passkey",
        abstract: "Generate a one-time passkey registration URL"
    )

    /// The actor username to register a passkey for. Must already exist in DynamoDB.
    @Option(help: "Actor username")
    var username: String

    /// The server domain used to construct the registration URL, e.g. `activity.happitec.com`.
    @Option(help: "Server domain (e.g. example.com)")
    var domain: String

    /// Overrides the `TABLE_NAME` environment variable when set.
    @Option(name: .customLong("table-name"), help: "DynamoDB table name (overrides TABLE_NAME env)")
    var tableName: String?

    mutating func run() async throws {
        let store = try await DynamoDBStore(tableName: tableName)

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
