/// Shared helpers used by the token-management subcommands (mint, list, revoke, rotate).
///
/// `TokenSupport` centralizes the DynamoDB item schema for bearer tokens so that tokens
/// minted by this CLI validate against the same schema the `provision-actor.yml` workflow
/// produces and the Lambda handlers verify against.
///
/// Token storage model: a raw 64-character hex token (32 random bytes) is generated locally
/// and shown to the operator once. Only its lowercase SHA-256 hex hash is written to DynamoDB
/// as `TOKEN#{hash}` / `META`. The Lambda handlers authenticate by hashing the incoming
/// `Authorization: Bearer` value and doing a `GetItem` on the resulting primary key.
import ArgumentParser
import AWSDynamoDB
import Crypto
import Foundation

/// DynamoDB item schema for token items (matches what `provision-actor.yml` writes):
///
///     PK          = "TOKEN#<sha256hex>"
///     SK          = "META"
///     username    = <username>
///     scope       = "read write" (default)
///     createdAt   = ISO8601 "%Y-%m-%dT%H:%M:%SZ"
///     ttl         = Number, epoch seconds = now + ttlDays * 86400
///     description = free-form provenance string
enum TokenSupport {
    /// A single token META item read back from DynamoDB.
    struct TokenItem {
        let hash: String       // the bare hash (no "TOKEN#" prefix)
        let pk: String         // "TOKEN#<hash>"
        let username: String
        let createdAt: String
        let scope: String
        let ttl: String
    }

    /// Resolve the table name from an explicit override or the stage.
    static func resolveTableName(tableName: String?, stage: String?) throws -> String {
        if let tableName, !tableName.isEmpty {
            return tableName
        }
        guard let stage, !stage.isEmpty else {
            throw ValidationError(
                "Provide either --table-name or --stage to determine the DynamoDB table."
            )
        }
        return "activity-\(stage)"
    }

    /// Generate a cryptographically secure 32-byte token, hex-encoded (64 chars),
    /// equivalent to `openssl rand -hex 32`.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices {
            bytes[i] = rng.next()
        }
        return hexEncode(bytes)
    }

    /// Lowercase hex SHA-256 of the raw token's UTF-8 bytes, matching `shasum -a 256`.
    static func tokenHash(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return hexEncode(Array(digest))
    }

    /// Encodes a byte sequence as lowercase hex, two characters per byte.
    static func hexEncode<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Current timestamp formatted as the workflow writes it: "%Y-%m-%dT%H:%M:%SZ" (UTC).
    static func iso8601Now() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: Date())
    }

    /// Build the DynamoDB item for a minted token, matching the workflow schema.
    static func tokenItem(
        hash: String,
        username: String,
        scope: String,
        ttlDays: Int,
        description: String
    ) -> [String: DynamoDBClientTypes.AttributeValue] {
        let ttl = Int(Date().timeIntervalSince1970) + ttlDays * 86400
        return [
            "PK": .s("TOKEN#\(hash)"),
            "SK": .s("META"),
            "username": .s(username),
            "scope": .s(scope),
            "createdAt": .s(iso8601Now()),
            "ttl": .n(String(ttl)),
            "description": .s(description),
        ]
    }

    /// Mint a new token: writes the item and returns the raw token plus its hash.
    @discardableResult
    static func mint(
        client: DynamoDBClient,
        tableName: String,
        username: String,
        scope: String,
        ttlDays: Int,
        description: String
    ) async throws -> (token: String, hash: String) {
        let token = generateToken()
        let hash = tokenHash(token)
        let input = PutItemInput(
            item: tokenItem(
                hash: hash,
                username: username,
                scope: scope,
                ttlDays: ttlDays,
                description: description
            ),
            tableName: tableName
        )
        _ = try await client.putItem(input: input)
        return (token, hash)
    }

    /// Scan the table for all `TOKEN#...` / `SK = META` items, handling pagination.
    /// Optionally filter by username (server-side).
    static func scanTokens(
        client: DynamoDBClient,
        tableName: String,
        username: String? = nil
    ) async throws -> [TokenItem] {
        var results: [TokenItem] = []
        var lastEvaluatedKey: [String: DynamoDBClientTypes.AttributeValue]? = nil

        var filterExpression = "begins_with(PK, :tokenPrefix) AND SK = :meta"
        var expressionValues: [String: DynamoDBClientTypes.AttributeValue] = [
            ":tokenPrefix": .s("TOKEN#"),
            ":meta": .s("META"),
        ]
        if let username, !username.isEmpty {
            filterExpression += " AND username = :username"
            expressionValues[":username"] = .s(username)
        }

        repeat {
            let input = ScanInput(
                exclusiveStartKey: lastEvaluatedKey,
                expressionAttributeValues: expressionValues,
                filterExpression: filterExpression,
                tableName: tableName
            )
            let output = try await client.scan(input: input)
            for item in output.items ?? [] {
                guard case let .s(pk)? = item["PK"], pk.hasPrefix("TOKEN#") else { continue }
                let hash = String(pk.dropFirst("TOKEN#".count))
                let user = stringValue(item["username"]) ?? ""
                let createdAt = stringValue(item["createdAt"]) ?? ""
                let scope = stringValue(item["scope"]) ?? ""
                let ttl = numberValue(item["ttl"]) ?? ""
                results.append(
                    TokenItem(
                        hash: hash,
                        pk: pk,
                        username: user,
                        createdAt: createdAt,
                        scope: scope,
                        ttl: ttl
                    )
                )
            }
            lastEvaluatedKey = output.lastEvaluatedKey
        } while lastEvaluatedKey != nil

        return results
    }

    /// Delete the given token items by PK + SK.
    static func deleteTokens(
        client: DynamoDBClient,
        tableName: String,
        items: [TokenItem]
    ) async throws {
        for item in items {
            let input = DeleteItemInput(
                key: [
                    "PK": .s(item.pk),
                    "SK": .s("META"),
                ],
                tableName: tableName
            )
            _ = try await client.deleteItem(input: input)
        }
    }

    /// Extracts a string value from a DynamoDB `.s` attribute, or returns `nil`.
    private static func stringValue(_ value: DynamoDBClientTypes.AttributeValue?) -> String? {
        if case let .s(s)? = value { return s }
        return nil
    }

    /// Extracts a number string from a DynamoDB `.n` attribute, or returns `nil`.
    private static func numberValue(_ value: DynamoDBClientTypes.AttributeValue?) -> String? {
        if case let .n(n)? = value { return n }
        return nil
    }
}
