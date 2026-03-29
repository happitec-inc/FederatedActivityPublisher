import AWSDynamoDB
import Foundation

public struct DynamoDBStore: Sendable {
    private let client: DynamoDBClient
    private let tableName: String

    public init(tableName: String? = nil) async throws {
        let resolvedTableName = tableName ?? ProcessInfo.processInfo.environment["TABLE_NAME"]
        guard let resolvedTableName, !resolvedTableName.isEmpty else {
            fatalError("TABLE_NAME environment variable is not set")
        }
        self.tableName = resolvedTableName
        self.client = try await DynamoDBClient()
    }

    /// Fetch an actor profile by username. Returns nil if not found.
    public func getActor(username: String) async throws -> Actor? {
        let input = GetItemInput(
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("PROFILE"),
            ],
            tableName: tableName
        )
        let output = try await client.getItem(input: input)
        guard let item = output.item else { return nil }
        return Actor.fromDynamoDB(item)
    }

    /// Check if an actor exists without fetching the full profile.
    public func actorExists(username: String) async throws -> Bool {
        let input = GetItemInput(
            expressionAttributeNames: ["#pk": "PK"],
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("PROFILE"),
            ],
            projectionExpression: "#pk",
            tableName: tableName
        )
        let output = try await client.getItem(input: input)
        return output.item != nil
    }
}
