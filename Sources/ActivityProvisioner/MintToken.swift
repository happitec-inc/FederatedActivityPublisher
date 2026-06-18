/// `mint-token` subcommand: generates a new bearer token and stores its hash in DynamoDB.
///
/// The raw token (64 hex characters, 32 random bytes) is printed to stdout exactly once and
/// optionally written to a file. Only its SHA-256 hash is stored in DynamoDB. There is no
/// way to recover the raw token after this command exits, so copy it immediately.
///
/// The Lambda API handlers authenticate requests by hashing the `Authorization: Bearer`
/// header value and comparing it against the stored hash. Tokens minted here follow the
/// same DynamoDB schema as those created by the `provision-actor.yml` workflow.
import ArgumentParser
import AWSDynamoDB
import Foundation

/// Mints a new bearer token, stores its SHA-256 hash in DynamoDB, and prints the raw token once.
struct MintToken: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mint-token",
        abstract: "Mint a new bearer token locally and store its hash in DynamoDB"
    )

    /// Deployment stage used to derive the table name. Required if `--table-name` is not given.
    @Option(help: "Deployment stage (e.g. stage, prod); used to derive the table name")
    var stage: String?

    /// Overrides the default table name of `activity-{stage}`.
    @Option(name: .customLong("table-name"), help: "DynamoDB table name (default: activity-{stage})")
    var tableName: String?

    /// The actor username this token authenticates. Stored as metadata on the token item.
    @Option(help: "Actor username the token authenticates")
    var username: String

    /// OAuth-style scope string stored alongside the token hash. Defaults to `read write`.
    @Option(help: "Token scope")
    var scope: String = "read write"

    /// Number of days until the DynamoDB TTL attribute expires the item. Defaults to 365.
    @Option(name: .customLong("ttl-days"), help: "Token lifetime in days")
    var ttlDays: Int = 365

    /// AWS region for the DynamoDB client.
    @Option(help: "AWS region")
    var region: String = "us-east-1"

    /// If set, the raw token is also written to this path. The file should be `chmod 600`
    /// immediately after creation.
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
