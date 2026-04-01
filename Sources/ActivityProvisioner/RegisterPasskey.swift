import ArgumentParser
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
