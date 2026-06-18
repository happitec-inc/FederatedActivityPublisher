/// `rotate-token` subcommand: replaces an actor's bearer token with a fresh one.
///
/// The rotation is ordered to avoid a window with zero valid tokens: the new token is written
/// to DynamoDB first, then all other tokens for the same username are deleted. Any in-flight
/// request carrying an old token will succeed until the delete completes — there is no
/// intentional gap in authentication coverage.
///
/// The raw new token is printed to stdout (and optionally written to a file) exactly once.
/// Copy it before the process exits; the plaintext cannot be recovered from the stored hash.
import ArgumentParser
import AWSDynamoDB
import Foundation

/// Mints a replacement token for an actor and revokes all of that actor's older tokens.
struct RotateToken: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rotate-token",
        abstract: "Mint a new token for a username, then revoke all of its older tokens"
    )

    /// Deployment stage used to derive the table name. Required if `--table-name` is not given.
    @Option(help: "Deployment stage (e.g. stage, prod); used to derive the table name")
    var stage: String?

    /// Overrides the default table name of `activity-{stage}`.
    @Option(name: .customLong("table-name"), help: "DynamoDB table name (default: activity-{stage})")
    var tableName: String?

    /// The actor username whose tokens are being rotated.
    @Option(help: "Actor username whose token is being rotated")
    var username: String

    /// OAuth-style scope string for the new token. Defaults to `read write`.
    @Option(help: "Token scope for the new token")
    var scope: String = "read write"

    /// Number of days until the new token's DynamoDB TTL attribute expires the item.
    @Option(name: .customLong("ttl-days"), help: "New token lifetime in days")
    var ttlDays: Int = 365

    /// AWS region for the DynamoDB client.
    @Option(help: "AWS region")
    var region: String = "us-east-1"

    /// If set, the raw new token is also written to this path. The file should be
    /// `chmod 600` immediately after creation.
    @Option(help: "Optional path to write ONLY the raw new token (chmod 600 it afterwards)")
    var out: String?

    func run() async throws {
        let resolvedTable = try TokenSupport.resolveTableName(tableName: tableName, stage: stage)
        let client = try DynamoDBClient(region: region)

        // 1. Mint the new token FIRST so there is never a window with zero valid tokens.
        let (token, newHash) = try await TokenSupport.mint(
            client: client,
            tableName: resolvedTable,
            username: username,
            scope: scope,
            ttlDays: ttlDays,
            description: "rotated via ActivityProvisioner CLI"
        )

        print("TOKEN: \(token)")
        if let out {
            try Data(token.utf8).write(to: URL(fileURLWithPath: out))
            print("Wrote raw token to: \(out) (run: chmod 600 \(out))")
        }
        print("New token minted for \(username).")
        print("  New hash: \(newHash)")
        print("  PK:       TOKEN#\(newHash)")
        print("  Table:    \(resolvedTable)")

        // 2. Revoke all OTHER tokens for this username (everything except the new one).
        let allTokens = try await TokenSupport.scanTokens(client: client, tableName: resolvedTable)
        let stale = allTokens.filter { $0.username == username && $0.hash != newHash }

        if stale.isEmpty {
            print("No older tokens to revoke for \(username).")
            return
        }

        try await TokenSupport.deleteTokens(client: client, tableName: resolvedTable, items: stale)
        print("Revoked \(stale.count) older token item(s) for \(username):")
        for token in stale {
            print("  TOKEN#\(token.hash)")
        }
    }
}
