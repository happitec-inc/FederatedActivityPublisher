import ArgumentParser
import AWSDynamoDB
import Foundation

struct ListTokens: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-tokens",
        abstract: "List bearer-token items (hashes only, never plaintext) for auditing"
    )

    @Option(help: "Deployment stage (e.g. stage, prod); used to derive the table name")
    var stage: String?

    @Option(name: .customLong("table-name"), help: "DynamoDB table name (default: activity-{stage})")
    var tableName: String?

    @Option(help: "AWS region")
    var region: String = "us-east-1"

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
