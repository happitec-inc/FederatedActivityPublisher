/// `revoke-token` subcommand: deletes bearer-token items from DynamoDB by username or hash.
///
/// Revoking a token removes its DynamoDB item. The Lambda handlers will reject any subsequent
/// request that presents the corresponding raw token, because its hash will no longer match
/// any stored item.
///
/// Exactly one of `--username` (revokes all tokens for that actor) or `--hash` (revokes the
/// single matching item) must be provided. Use `--dry-run` to preview what would be deleted
/// before committing.
///
/// The `--hash` option accepts either the bare hash or the full `TOKEN#<hash>` primary key.
import ArgumentParser
import AWSDynamoDB
import Foundation

/// Deletes one or more bearer-token items from DynamoDB, invalidating those tokens immediately.
struct RevokeToken: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revoke-token",
        abstract: "Revoke (delete) bearer-token items by username or by hash"
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

    /// Revoke all token items whose `username` attribute matches this value.
    /// Mutually exclusive with `--hash`.
    @Option(help: "Revoke ALL token items for this username")
    var username: String?

    /// Revoke the single token item with this hash. Accepts bare hash or `TOKEN#<hash>`.
    /// Mutually exclusive with `--username`.
    @Option(help: "Revoke the single token item with this hash (TOKEN#<hash>)")
    var hash: String?

    /// When set, prints what would be deleted without making any DynamoDB changes.
    @Flag(name: .customLong("dry-run"), help: "List what WOULD be deleted without deleting")
    var dryRun: Bool = false

    /// Validates that exactly one of `--username` or `--hash` is provided.
    func validate() throws {
        let hasUsername = username != nil && !(username ?? "").isEmpty
        let hasHash = hash != nil && !(hash ?? "").isEmpty
        guard hasUsername != hasHash else {
            throw ValidationError("Provide exactly one of --username or --hash.")
        }
    }

    func run() async throws {
        let resolvedTable = try TokenSupport.resolveTableName(tableName: tableName, stage: stage)
        let client = try DynamoDBClient(region: region)

        let allTokens = try await TokenSupport.scanTokens(
            client: client,
            tableName: resolvedTable
        )

        let targets: [TokenSupport.TokenItem]
        if let username, !username.isEmpty {
            targets = allTokens.filter { $0.username == username }
        } else if let hash, !hash.isEmpty {
            let bare = hash.hasPrefix("TOKEN#") ? String(hash.dropFirst("TOKEN#".count)) : hash
            targets = allTokens.filter { $0.hash == bare }
        } else {
            targets = []
        }

        if targets.isEmpty {
            print("No matching token items found in \(resolvedTable).")
            return
        }

        if dryRun {
            print("[dry-run] Would delete \(targets.count) token item(s) from \(resolvedTable):")
        } else {
            try await TokenSupport.deleteTokens(client: client, tableName: resolvedTable, items: targets)
            print("Deleted \(targets.count) token item(s) from \(resolvedTable):")
        }
        for token in targets {
            print("  \(token.username)  TOKEN#\(token.hash)")
        }
    }
}
