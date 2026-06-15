import ArgumentParser
import AWSDynamoDB
import Foundation

struct RotateToken: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rotate-token",
        abstract: "Mint a new token for a username, then revoke all of its older tokens"
    )

    @Option(help: "Deployment stage (e.g. stage, prod); used to derive the table name")
    var stage: String?

    @Option(name: .customLong("table-name"), help: "DynamoDB table name (default: activity-{stage})")
    var tableName: String?

    @Option(help: "Actor username whose token is being rotated")
    var username: String

    @Option(help: "Token scope for the new token")
    var scope: String = "read write"

    @Option(name: .customLong("ttl-days"), help: "New token lifetime in days")
    var ttlDays: Int = 365

    @Option(help: "AWS region")
    var region: String = "us-east-1"

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
