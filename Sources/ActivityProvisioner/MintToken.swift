import ArgumentParser
import AWSDynamoDB
import Foundation

struct MintToken: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mint-token",
        abstract: "Mint a new bearer token locally and store its hash in DynamoDB"
    )

    @Option(help: "Deployment stage (e.g. stage, prod); used to derive the table name")
    var stage: String?

    @Option(name: .customLong("table-name"), help: "DynamoDB table name (default: activity-{stage})")
    var tableName: String?

    @Option(help: "Actor username the token authenticates")
    var username: String

    @Option(help: "Token scope")
    var scope: String = "read write"

    @Option(name: .customLong("ttl-days"), help: "Token lifetime in days")
    var ttlDays: Int = 365

    @Option(help: "AWS region")
    var region: String = "us-east-1"

    @Option(help: "Optional path to write ONLY the raw token (chmod 600 it afterwards)")
    var out: String?

    func run() async throws {
        let resolvedTable = try TokenSupport.resolveTableName(tableName: tableName, stage: stage)
        let client = try DynamoDBClient(region: region)

        let (token, hash) = try await TokenSupport.mint(
            client: client,
            tableName: resolvedTable,
            username: username,
            scope: scope,
            ttlDays: ttlDays,
            description: "minted via ActivityProvisioner CLI"
        )

        // The raw token is printed to stdout (and optionally a file) ONLY.
        print("TOKEN: \(token)")
        if let out {
            try Data(token.utf8).write(to: URL(fileURLWithPath: out))
            print("Wrote raw token to: \(out) (run: chmod 600 \(out))")
        }
        print("Token minted successfully.")
        print("  Username: \(username)")
        print("  Hash:     \(hash)")
        print("  PK:       TOKEN#\(hash)")
        print("  Scope:    \(scope)")
        print("  TTL:      \(ttlDays) days")
        print("  Table:    \(resolvedTable)")
    }
}
