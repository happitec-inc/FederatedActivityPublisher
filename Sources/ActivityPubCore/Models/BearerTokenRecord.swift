/// A bearer token stored in DynamoDB, used to authenticate API requests.
///
/// Token records live under `PK=TOKEN#<sha256-hex>`, `SK=META` in the single-table design.
/// They are written by the `ActivityProvisioner` CLI (and the `provision-actor` workflow) and
/// read by the authentication middleware on every protected API call. The raw token string is
/// never stored; only its SHA-256 hex digest appears in the key. Expiry is enforced by comparing
/// `ttl` against the current time; DynamoDB's TTL deletion is eventually consistent and cannot be
/// used as a hard gate.
import AWSDynamoDB
import Foundation

/// A stored bearer token record.
///
/// Keyed by `PK=TOKEN#{sha256-hex}`, `SK=META`. The raw token string is never stored;
/// only its SHA-256 hex digest appears in the partition key.
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

    /// Create a BearerTokenRecord with the given fields.
    ///
    /// - Parameters:
    ///   - username: The username this token authenticates.
    ///   - scope: Space-separated OAuth-compatible scope string (e.g. `"read write"`).
    ///   - ttl: Expiry as Unix epoch seconds.
    ///   - createdAt: ISO 8601 creation timestamp.
    ///   - description: Free-text note about how the token was issued.
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
    ///
    /// - Parameter item: The raw DynamoDB attribute map from a `GetItem` call.
    /// - Returns: A populated record, or `nil` if `username`, `scope`, or `ttl` are missing.
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
