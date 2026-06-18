/// `list-tokens` subcommand: reads all bearer-token metadata from DynamoDB for auditing.
///
/// Because tokens are stored as SHA-256 hashes, this command can only show hashes and
/// associated metadata (username, scope, TTL, creation time) — never the raw token values.
/// Use this to verify which tokens exist before revoking or rotating them.
///
/// Output is sorted by username then creation time and printed as a fixed-width table.
import ArgumentParser
import AWSDynamoDB
import Foundation

/// Lists bearer-token items stored in DynamoDB, showing hashes and metadata only.
struct ListTokens: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-tokens",
        abstract: "List bearer-token items (hashes only, never plaintext) for auditing"
    )

    /// Deployment stage used to derive the table name. Required if `--table-name` is not given.
    @Option(help: "Deployment stage (e.g. stage, prod); used to derive the table name")
    var stage: String?

    /// Overrides the default table name of `activity-{stage}`.
    @Option(name: .customLong("table-name"), help: "DynamoDB table name (default: activity-{stage})")
    var tableName: String?

    /// AWS region for the DynamoDB client.
    @Option(help: "AWS region")
    var region: String = "us-east-1"

    /// When set, only tokens belonging to this username are returned.
    @Option(help: "Filter to a single username")
    var username: String?

    func run() async throws {
        let resolvedTable = try TokenSupport.resolveTableName(tableName: tableName, stage: stage)
        let client = try DynamoDBClient(region: region)

        let tokens = try await TokenSupport.scanTokens(
            client: client,
            tableName: resolvedTable,
            username: username
        )

        if tokens.isEmpty {
            print("No token items found in \(resolvedTable).")
            return
        }

        // Plaintext is never stored, so only hashes/metadata are ever shown.
        print("Tokens in \(resolvedTable) (\(tokens.count)):")
        print("")
        print("USERNAME             PK                                                                     CREATEDAT             SCOPE        TTL")
        for token in tokens.sorted(by: { ($0.username, $0.createdAt) < ($1.username, $1.createdAt) }) {
            let user = token.username.padding(toLength: 20, withPad: " ", startingAt: 0)
            let pk = token.pk.padding(toLength: 70, withPad: " ", startingAt: 0)
            let createdAt = token.createdAt.padding(toLength: 21, withPad: " ", startingAt: 0)
            let scope = token.scope.padding(toLength: 12, withPad: " ", startingAt: 0)
            print("\(user) \(pk) \(createdAt) \(scope) \(token.ttl)")
        }
    }
}
