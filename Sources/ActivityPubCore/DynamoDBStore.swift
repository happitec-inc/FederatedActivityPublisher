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

    // MARK: - Follower Storage

    /// Store a follower record. Uses conditional write to prevent duplicates.
    /// Returns `true` if newly stored, `false` if the follower already exists.
    public func storeFollower(username: String, follower: Follower) async throws -> Bool {
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())

        var item: [String: DynamoDBClientTypes.AttributeValue] = [
            "PK": .s("ACTOR#\(username)"),
            "SK": .s("FOLLOWER#\(follower.actorUri)"),
            "GSI1PK": .s("FOLLOWERS#\(username)"),
            "GSI1SK": .s(follower.acceptedAt),
            "actorUri": .s(follower.actorUri),
            "inboxUrl": .s(follower.inboxUrl),
            "followActivityId": .s(follower.followActivityId),
            "acceptedAt": .s(follower.acceptedAt),
            "createdAt": .s(now),
        ]
        if let sharedInboxUrl = follower.sharedInboxUrl {
            item["sharedInboxUrl"] = .s(sharedInboxUrl)
        }

        let input = PutItemInput(
            conditionExpression: "attribute_not_exists(SK)",
            item: item,
            tableName: tableName
        )

        do {
            _ = try await client.putItem(input: input)
            return true
        } catch let error as ConditionalCheckFailedException {
            // Duplicate follower — already exists
            _ = error
            return false
        }
    }

    /// Remove a follower record.
    public func removeFollower(username: String, actorUri: String) async throws {
        let input = DeleteItemInput(
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("FOLLOWER#\(actorUri)"),
            ],
            tableName: tableName
        )
        _ = try await client.deleteItem(input: input)
    }

    /// Atomically increment the follower count for an actor.
    public func incrementFollowerCount(username: String, by amount: Int = 1) async throws {
        let input = UpdateItemInput(
            expressionAttributeNames: ["#fc": "followerCount"],
            expressionAttributeValues: [":val": .n(String(amount))],
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("PROFILE"),
            ],
            tableName: tableName,
            updateExpression: "SET #fc = #fc + :val"
        )
        _ = try await client.updateItem(input: input)
    }

    /// Atomically decrement the follower count for an actor.
    public func decrementFollowerCount(username: String) async throws {
        let input = UpdateItemInput(
            expressionAttributeNames: ["#fc": "followerCount"],
            expressionAttributeValues: [":one": .n("1"), ":zero": .n("0")],
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("PROFILE"),
            ],
            tableName: tableName,
            updateExpression: "SET #fc = if_not_exists(#fc, :zero) - :one"
        )
        _ = try await client.updateItem(input: input)
    }

    // MARK: - Activity Idempotency

    /// Store a received activity with deduplication.
    /// Returns `true` if newly stored, `false` if duplicate (activity already processed).
    public func storeReceivedActivity(
        username: String,
        activityId: String,
        type: String,
        actorUri: String,
        objectUri: String?,
        raw: String
    ) async throws -> Bool {
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        let ulid = generateULID()

        // Write dedup record with conditional check
        var dedupItem: [String: DynamoDBClientTypes.AttributeValue] = [
            "PK": .s("ACTIVITY_DEDUP"),
            "SK": .s(activityId),
            "actorUri": .s(actorUri),
            "type": .s(type),
            "receivedAt": .s(now),
        ]

        // Set TTL to 30 days for dedup records
        let ttl = Int(Date().timeIntervalSince1970) + (30 * 24 * 3600)
        dedupItem["ttl"] = .n(String(ttl))

        let dedupInput = PutItemInput(
            conditionExpression: "attribute_not_exists(SK)",
            item: dedupItem,
            tableName: tableName
        )

        do {
            _ = try await client.putItem(input: dedupInput)
        } catch is ConditionalCheckFailedException {
            // Duplicate activity
            return false
        }

        // Store the full activity record
        var activityItem: [String: DynamoDBClientTypes.AttributeValue] = [
            "PK": .s("ACTOR#\(username)"),
            "SK": .s("ACTIVITY#\(type)#\(ulid)"),
            "activityId": .s(activityId),
            "type": .s(type),
            "actorUri": .s(actorUri),
            "raw": .s(raw),
            "receivedAt": .s(now),
        ]
        if let objectUri {
            activityItem["objectUri"] = .s(objectUri)
        }

        let activityInput = PutItemInput(
            item: activityItem,
            tableName: tableName
        )
        _ = try await client.putItem(input: activityInput)

        return true
    }

    // MARK: - Remote Actor Cache

    /// Store a remote actor in the cache with a 24h TTL.
    public func storeRemoteActor(_ actor: RemoteActor) async throws {
        var item = actor.toDynamoDB()
        item["PK"] = .s("REMOTE_ACTOR#\(actor.actorUri)")
        item["SK"] = .s("PROFILE")

        // 24-hour TTL
        let ttl = Int(Date().timeIntervalSince1970) + (24 * 3600)
        item["ttl"] = .n(String(ttl))

        let input = PutItemInput(
            item: item,
            tableName: tableName
        )
        _ = try await client.putItem(input: input)
    }

    /// Fetch a cached remote actor. Returns nil if not found or if TTL has expired.
    public func getRemoteActor(actorUri: String) async throws -> RemoteActor? {
        let input = GetItemInput(
            key: [
                "PK": .s("REMOTE_ACTOR#\(actorUri)"),
                "SK": .s("PROFILE"),
            ],
            tableName: tableName
        )
        let output = try await client.getItem(input: input)
        guard let item = output.item else { return nil }

        // Check TTL manually (DynamoDB TTL deletion is eventually consistent)
        if case .n(let ttlStr) = item["ttl"], let ttl = Int(ttlStr) {
            if ttl < Int(Date().timeIntervalSince1970) {
                return nil
            }
        }

        return RemoteActor.fromDynamoDB(item)
    }

    // MARK: - ULID Generation

    /// Generate a simple ULID-like identifier (timestamp + random).
    public func generateULID() -> String {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let random = UInt64.random(in: 0...UInt64.max)
        return String(format: "%016llX%016llX", timestamp, random)
    }
}
