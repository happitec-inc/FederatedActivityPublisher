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

    /// Remove a follower record. Returns true if the follower existed, false if not found.
    public func removeFollower(username: String, actorUri: String) async throws -> Bool {
        let input = DeleteItemInput(
            conditionExpression: "attribute_exists(SK)",
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("FOLLOWER#\(actorUri)"),
            ],
            tableName: tableName
        )
        do {
            _ = try await client.deleteItem(input: input)
            return true
        } catch is ConditionalCheckFailedException {
            return false
        }
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

    // MARK: - Status Storage

    /// Store a status in DynamoDB.
    public func storeStatus(_ status: Status) async throws {
        let item = status.toDynamoDB()
        let input = PutItemInput(
            item: item,
            tableName: tableName
        )
        _ = try await client.putItem(input: input)
    }

    /// Atomically increment the status count for an actor.
    public func incrementStatusCount(username: String, by amount: Int = 1) async throws {
        let input = UpdateItemInput(
            expressionAttributeNames: ["#sc": "statusCount"],
            expressionAttributeValues: [":val": .n(String(amount))],
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("PROFILE"),
            ],
            tableName: tableName,
            updateExpression: "SET #sc = #sc + :val"
        )
        _ = try await client.updateItem(input: input)
    }

    /// Fetch a single status by username and ID.
    public func getStatus(username: String, id: String) async throws -> Status? {
        let input = GetItemInput(
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("STATUS#\(id)"),
            ],
            tableName: tableName
        )
        let output = try await client.getItem(input: input)
        guard let item = output.item else { return nil }
        return Status.fromDynamoDB(item)
    }

    /// List statuses for a user, newest first, with cursor-based pagination.
    /// Queries main table (PK=ACTOR#{username}, SK begins_with STATUS#) in reverse order.
    /// ULIDs sort lexicographically by time so reverse SK order = newest first.
    /// `maxId` is the ULID of the last status seen — statuses older than this are returned.
    /// Uses ExclusiveStartKey to skip past maxId when provided.
    /// Returns (statuses, hasMore).
    public func listStatuses(username: String, limit: Int = 20, maxId: String? = nil) async throws -> ([Status], Bool) {
        let keyCondition = "#pk = :pk AND begins_with(#sk, :prefix)"
        let exprValues: [String: DynamoDBClientTypes.AttributeValue] = [
            ":pk": .s("ACTOR#\(username)"),
            ":prefix": .s("STATUS#"),
        ]

        // When maxId is provided, set ExclusiveStartKey so DynamoDB starts scanning
        // just before STATUS#{maxId} (exclusive). Since we scan in reverse, this means
        // "give me items with SK < STATUS#{maxId}" within the begins_with range.
        var exclusiveStartKey: [String: DynamoDBClientTypes.AttributeValue]?
        if let maxId {
            exclusiveStartKey = [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("STATUS#\(maxId)"),
            ]
        }

        let input = QueryInput(
            exclusiveStartKey: exclusiveStartKey,
            expressionAttributeNames: ["#pk": "PK", "#sk": "SK"],
            expressionAttributeValues: exprValues,
            keyConditionExpression: keyCondition,
            limit: limit,
            scanIndexForward: false,
            tableName: tableName
        )

        let output = try await client.query(input: input)
        let items = output.items ?? []

        let statuses = items.compactMap { Status.fromDynamoDB($0) }
        let hasMore = output.lastEvaluatedKey != nil

        return (statuses, hasMore)
    }

    // MARK: - Follower Listing (for delivery fan-out)

    /// Fetch ALL followers for a user (paginated internally). Used for delivery fan-out.
    public func listAllFollowers(username: String) async throws -> [Follower] {
        var followers: [Follower] = []
        var exclusiveStartKey: [String: DynamoDBClientTypes.AttributeValue]?

        repeat {
            let input = QueryInput(
                exclusiveStartKey: exclusiveStartKey,
                expressionAttributeNames: ["#gsi1pk": "GSI1PK"],
                expressionAttributeValues: [":pk": .s("FOLLOWERS#\(username)")],
                indexName: "GSI1",
                keyConditionExpression: "#gsi1pk = :pk",
                tableName: tableName
            )

            let output = try await client.query(input: input)
            let items = output.items ?? []

            for item in items {
                guard
                    case .s(let actorUri) = item["actorUri"],
                    case .s(let inboxUrl) = item["inboxUrl"],
                    case .s(let followActivityId) = item["followActivityId"],
                    case .s(let acceptedAt) = item["acceptedAt"]
                else {
                    continue
                }

                var sharedInboxUrl: String?
                if case .s(let url) = item["sharedInboxUrl"] {
                    sharedInboxUrl = url
                }

                followers.append(Follower(
                    actorUri: actorUri,
                    inboxUrl: inboxUrl,
                    sharedInboxUrl: sharedInboxUrl,
                    followActivityId: followActivityId,
                    acceptedAt: acceptedAt
                ))
            }

            exclusiveStartKey = output.lastEvaluatedKey
        } while exclusiveStartKey != nil

        return followers
    }

    // MARK: - Media Metadata

    /// Store media attachment metadata.
    public func storeMediaMetadata(
        id: String, username: String, s3Key: String, contentType: String,
        description: String?, blurhash: String?,
        width: Int?, height: Int?, size: Int?
    ) async throws {
        var item: [String: DynamoDBClientTypes.AttributeValue] = [
            "PK": .s("MEDIA#\(id)"),
            "SK": .s("META"),
            "id": .s(id),
            "username": .s(username),
            "s3Key": .s(s3Key),
            "contentType": .s(contentType),
        ]

        if let description { item["description"] = .s(description) }
        if let blurhash { item["blurhash"] = .s(blurhash) }
        if let width { item["width"] = .n(String(width)) }
        if let height { item["height"] = .n(String(height)) }
        if let size { item["size"] = .n(String(size)) }

        let input = PutItemInput(item: item, tableName: tableName)
        _ = try await client.putItem(input: input)
    }

    /// Fetch media metadata by ID. Returns a MediaAttachmentRef with the CloudFront URL populated.
    public func getMediaMetadata(id: String, serverDomain: String) async throws -> MediaAttachmentRef? {
        let input = GetItemInput(
            key: [
                "PK": .s("MEDIA#\(id)"),
                "SK": .s("META"),
            ],
            tableName: tableName
        )
        let output = try await client.getItem(input: input)
        guard let item = output.item else { return nil }

        guard
            case .s(let mediaId) = item["id"],
            case .s(let s3Key) = item["s3Key"],
            case .s(let contentType) = item["contentType"]
        else {
            return nil
        }

        let url = "https://\(serverDomain)/\(s3Key)"

        var description: String?
        if case .s(let desc) = item["description"] { description = desc }

        var blurhash: String?
        if case .s(let bh) = item["blurhash"] { blurhash = bh }

        return MediaAttachmentRef(
            id: mediaId,
            url: url,
            contentType: contentType,
            description: description,
            blurhash: blurhash
        )
    }

    // MARK: - ULID Generation

    /// Generate a simple ULID-like identifier (timestamp + random).
    public func generateULID() -> String {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let random = UInt64.random(in: 0...UInt64.max)
        return String(format: "%016llX%016llX", timestamp, random)
    }
}
