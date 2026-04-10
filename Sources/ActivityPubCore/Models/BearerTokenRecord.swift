import AWSDynamoDB
import Foundation

/// A stored bearer token record from DynamoDB.
///
/// Maps to the `TOKEN#<sha256-hex>` entity in the single-table design.
/// The raw token is never stored; only its SHA-256 hash appears as the partition key.
public struct BearerTokenRecord: Sendable {
    /// The authenticated username this token belongs to.
    public let username: String
    /// Space-separated OAuth-compatible scopes (e.g. "read write").
    public let scope: String
    /// TTL as Unix epoch seconds. Used for manual expiry checks since
    /// DynamoDB TTL deletion is eventually consistent.
    public let ttl: Int
    /// ISO 8601 timestamp of when the token was created.
    public let createdAt: String?
    /// Human-readable description (e.g. "provisioned via workflow").
    public let description: String?

    public init(
        username: String,
        scope: String,
        ttl: Int,
        createdAt: String? = nil,
        description: String? = nil
    ) {
        self.username = username
        self.scope = scope
        self.ttl = ttl
        self.createdAt = createdAt
        self.description = description
    }

    /// Parse a BearerTokenRecord from a DynamoDB item.
    public static func fromDynamoDB(
        _ item: [String: DynamoDBClientTypes.AttributeValue]
    ) -> BearerTokenRecord? {
        guard case .s(let username) = item["username"],
              case .s(let scope) = item["scope"],
              case .n(let ttlStr) = item["ttl"],
              let ttl = Int(ttlStr)
        else { return nil }

        var createdAt: String?
        if case .s(let c) = item["createdAt"] { createdAt = c }
        var description: String?
        if case .s(let d) = item["description"] { description = d }

        return BearerTokenRecord(
            username: username,
            scope: scope,
            ttl: ttl,
            createdAt: createdAt,
            description: description
        )
    }
}
