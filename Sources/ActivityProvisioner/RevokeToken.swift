import ArgumentParser
import AWSDynamoDB
import Foundation

struct RevokeToken: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revoke-token",
        abstract: "Revoke (delete) bearer-token items by username or by hash"
    )

    @Option(help: "Deployment stage (e.g. stage, prod); used to derive the table name")
    var stage: String?

    @Option(name: .customLong("table-name"), help: "DynamoDB table name (default: activity-{stage})")
    var tableName: String?

    @Option(help: "AWS region")
    var region: String = "us-east-1"

    @Option(help: "Revoke ALL token items for this username")
    var username: String?

    @Option(help: "Revoke the single token item with this hash (TOKEN#<hash>)")
    var hash: String?

    @Flag(name: .customLong("dry-run"), help: "List what WOULD be deleted without deleting")
    var dryRun: Bool = false

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
