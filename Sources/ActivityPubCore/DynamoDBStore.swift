import AWSDynamoDB
import Foundation

/// Shared ISO8601 date formatter — reused across all DynamoDBStore methods to avoid
/// repeated allocation. ISO8601DateFormatter is thread-safe and immutable after creation.
/// Marked nonisolated(unsafe) because ISO8601DateFormatter is not Sendable, but we only
/// use it for read-only formatting after initialization.
public nonisolated(unsafe) let iso8601Formatter = ISO8601DateFormatter()

/// Persistence layer for all DynamoDB operations in the ActivityPub server.
///
/// Manages actors, statuses, followers, interactions, replies, remote actor caching,
/// and media metadata using a single-table design. All methods are async and use the
/// AWS SDK's DynamoDB client.
public struct DynamoDBStore: Sendable {
    private let client: DynamoDBClient
    private let tableName: String

    /// Create a new store, optionally overriding the table name.
    ///
    /// If `tableName` is nil, reads from the `TABLE_NAME` environment variable.
    /// Crashes with `fatalError` if no table name is available.
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

    /// Update an actor's profile fields. Only provided (non-nil) values are updated.
    public func updateActorProfile(
        username: String,
        displayName: String?,
        summary: String?,
        avatarUrl: String?,
        headerUrl: String?,
        fields: String?
    ) async throws {
        var updateParts: [String] = []
        var exprNames: [String: String] = [:]
        var exprValues: [String: DynamoDBClientTypes.AttributeValue] = [:]

        if let displayName {
            updateParts.append("#dn = :dn")
            exprNames["#dn"] = "displayName"
            exprValues[":dn"] = .s(displayName)
        }
        if let summary {
            updateParts.append("#sm = :sm")
            exprNames["#sm"] = "summary"
            exprValues[":sm"] = .s(summary)
        }
        if let avatarUrl {
            updateParts.append("#au = :au")
            exprNames["#au"] = "avatarUrl"
            exprValues[":au"] = .s(avatarUrl)
        }
        if let headerUrl {
            updateParts.append("#hu = :hu")
            exprNames["#hu"] = "headerUrl"
            exprValues[":hu"] = .s(headerUrl)
        }
        if let fields {
            updateParts.append("#fl = :fl")
            exprNames["#fl"] = "fields"
            exprValues[":fl"] = .s(fields)
        }

        guard !updateParts.isEmpty else { return }

        let updateExpression = "SET " + updateParts.joined(separator: ", ")
        let input = UpdateItemInput(
            expressionAttributeNames: exprNames,
            expressionAttributeValues: exprValues,
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("PROFILE"),
            ],
            tableName: tableName,
            updateExpression: updateExpression
        )
        _ = try await client.updateItem(input: input)
    }

    // MARK: - Follower Storage

    /// Store a follower record. Uses conditional write to prevent duplicates.
    /// Returns `true` if newly stored, `false` if the follower already exists.
    public func storeFollower(username: String, follower: Follower) async throws -> Bool {
        let now = iso8601Formatter.string(from: Date())

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

    /// Check if a remote actor is a follower of the given local actor.
    /// Uses a point read on the follower record -- no scan required.
    public func isFollower(username: String, actorUri: String) async throws -> Bool {
        let input = GetItemInput(
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("FOLLOWER#\(actorUri)"),
            ],
            projectionExpression: "PK",
            tableName: tableName
        )
        let output = try await client.getItem(input: input)
        return output.item != nil
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
        let now = iso8601Formatter.string(from: Date())
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

    // MARK: - Interaction Storage

    /// Store a Like or Announce interaction. Uses deterministic SK for direct lookup/delete.
    /// Returns `true` if newly stored, `false` if duplicate.
    public func storeInteraction(
        username: String,
        actorUri: String,
        type: String,
        objectUri: String
    ) async throws -> Bool {
        let now = iso8601Formatter.string(from: Date())

        let item: [String: DynamoDBClientTypes.AttributeValue] = [
            "PK": .s("ACTOR#\(username)"),
            "SK": .s("INTERACTION#\(type)#\(actorUri)#\(objectUri)"),
            "actorUri": .s(actorUri),
            "type": .s(type),
            "objectUri": .s(objectUri),
            "createdAt": .s(now),
        ]

        let input = PutItemInput(
            conditionExpression: "attribute_not_exists(SK)",
            item: item,
            tableName: tableName
        )

        do {
            _ = try await client.putItem(input: input)
            return true
        } catch is ConditionalCheckFailedException {
            return false
        }
    }

    /// Remove a Like or Announce interaction on Undo/Delete.
    /// Returns `true` if the interaction existed, `false` if not found.
    public func removeInteraction(
        username: String,
        actorUri: String,
        type: String,
        objectUri: String
    ) async throws -> Bool {
        let input = DeleteItemInput(
            conditionExpression: "attribute_exists(SK)",
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("INTERACTION#\(type)#\(actorUri)#\(objectUri)"),
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

    // MARK: - Reply Storage

    /// Store an inbound reply Note. Returns `true` if newly stored.
    public func storeReply(
        username: String,
        actorUri: String,
        objectUri: String,
        content: String,
        inReplyTo: String,
        raw: String
    ) async throws -> Bool {
        let now = iso8601Formatter.string(from: Date())

        let item: [String: DynamoDBClientTypes.AttributeValue] = [
            "PK": .s("ACTOR#\(username)"),
            "SK": .s("REPLY#\(objectUri)"),
            "GSI1PK": .s("REPLIES#\(inReplyTo)"),
            "GSI1SK": .s(now),
            "actorUri": .s(actorUri),
            "objectUri": .s(objectUri),
            "content": .s(content),
            "inReplyTo": .s(inReplyTo),
            "raw": .s(raw),
            "createdAt": .s(now),
        ]

        let input = PutItemInput(
            conditionExpression: "attribute_not_exists(SK)",
            item: item,
            tableName: tableName
        )

        do {
            _ = try await client.putItem(input: input)
            return true
        } catch is ConditionalCheckFailedException {
            return false
        }
    }

    /// Remove a stored reply on Delete. Returns the `inReplyTo` value if the reply existed, nil otherwise.
    /// Uses `ReturnValues: .allOld` so the Delete handler can parse the parent statusId and decrement repliesCount.
    public func removeReply(username: String, objectUri: String) async throws -> String? {
        let input = DeleteItemInput(
            conditionExpression: "attribute_exists(SK)",
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("REPLY#\(objectUri)"),
            ],
            returnValues: .allOld,
            tableName: tableName
        )
        do {
            let output = try await client.deleteItem(input: input)
            // Extract inReplyTo from the old item so caller can decrement parent reply count
            if case .s(let inReplyTo) = output.attributes?["inReplyTo"] {
                return inReplyTo
            }
            return ""  // Item existed but had no inReplyTo (shouldn't happen)
        } catch is ConditionalCheckFailedException {
            return nil
        }
    }

    /// Update a stored reply's content on Update.
    /// Verifies that the stored reply's `actorUri` matches the provided `actorUri` before updating.
    /// Returns `true` if the update succeeded, `false` if the actor ownership check failed.
    public func updateReply(
        username: String,
        objectUri: String,
        content: String,
        actorUri: String
    ) async throws -> Bool {
        let now = iso8601Formatter.string(from: Date())

        let input = UpdateItemInput(
            conditionExpression: "actorUri = :expectedActor",
            expressionAttributeNames: ["#c": "content", "#u": "updatedAt"],
            expressionAttributeValues: [
                ":c": .s(content),
                ":u": .s(now),
                ":expectedActor": .s(actorUri),
            ],
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("REPLY#\(objectUri)"),
            ],
            tableName: tableName,
            updateExpression: "SET #c = :c, #u = :u"
        )
        do {
            _ = try await client.updateItem(input: input)
            return true
        } catch is ConditionalCheckFailedException {
            return false
        }
    }

    /// Refresh a cached remote actor profile. Resets TTL to 24h.
    public func updateRemoteActor(actorUri: String, data: RemoteActor) async throws {
        // Re-use the existing storeRemoteActor method which does a full PutItem with fresh TTL
        try await storeRemoteActor(data)
    }

    // MARK: - Interaction Counts

    /// Atomically increment the likes count for a status.
    public func incrementLikesCount(username: String, statusId: String) async throws {
        let input = UpdateItemInput(
            expressionAttributeNames: ["#fc": "likesCount"],
            expressionAttributeValues: [":val": .n("1")],
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("STATUS#\(statusId)"),
            ],
            tableName: tableName,
            updateExpression: "ADD #fc :val"
        )
        _ = try await client.updateItem(input: input)
    }

    /// Atomically decrement the likes count for a status. Floors at zero.
    public func decrementLikesCount(username: String, statusId: String) async throws {
        let input = UpdateItemInput(
            conditionExpression: "#fc > :zero",
            expressionAttributeNames: ["#fc": "likesCount"],
            expressionAttributeValues: [":val": .n("-1"), ":zero": .n("0")],
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("STATUS#\(statusId)"),
            ],
            tableName: tableName,
            updateExpression: "ADD #fc :val"
        )
        do {
            _ = try await client.updateItem(input: input)
        } catch is ConditionalCheckFailedException {
            // Already at zero -- no-op
        }
    }

    /// Atomically increment the boosts count for a status.
    public func incrementBoostsCount(username: String, statusId: String) async throws {
        let input = UpdateItemInput(
            expressionAttributeNames: ["#fc": "boostsCount"],
            expressionAttributeValues: [":val": .n("1")],
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("STATUS#\(statusId)"),
            ],
            tableName: tableName,
            updateExpression: "ADD #fc :val"
        )
        _ = try await client.updateItem(input: input)
    }

    /// Atomically decrement the boosts count for a status. Floors at zero.
    public func decrementBoostsCount(username: String, statusId: String) async throws {
        let input = UpdateItemInput(
            conditionExpression: "#fc > :zero",
            expressionAttributeNames: ["#fc": "boostsCount"],
            expressionAttributeValues: [":val": .n("-1"), ":zero": .n("0")],
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("STATUS#\(statusId)"),
            ],
            tableName: tableName,
            updateExpression: "ADD #fc :val"
        )
        do {
            _ = try await client.updateItem(input: input)
        } catch is ConditionalCheckFailedException {
            // Already at zero -- no-op
        }
    }

    /// Atomically increment the replies count for a status.
    public func incrementRepliesCount(username: String, statusId: String) async throws {
        let input = UpdateItemInput(
            expressionAttributeNames: ["#fc": "repliesCount"],
            expressionAttributeValues: [":val": .n("1")],
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("STATUS#\(statusId)"),
            ],
            tableName: tableName,
            updateExpression: "ADD #fc :val"
        )
        _ = try await client.updateItem(input: input)
    }

    /// Atomically decrement the replies count for a status. Floors at zero.
    public func decrementRepliesCount(username: String, statusId: String) async throws {
        let input = UpdateItemInput(
            conditionExpression: "#fc > :zero",
            expressionAttributeNames: ["#fc": "repliesCount"],
            expressionAttributeValues: [":val": .n("-1"), ":zero": .n("0")],
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("STATUS#\(statusId)"),
            ],
            tableName: tableName,
            updateExpression: "ADD #fc :val"
        )
        do {
            _ = try await client.updateItem(input: input)
        } catch is ConditionalCheckFailedException {
            // Already at zero -- no-op
        }
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

    /// Atomically update the quote approval state on a status.
    /// Used when receiving Accept/Reject of our outbound QuoteRequest.
    public func updateQuoteApprovalState(
        username: String,
        statusId: String,
        state: String
    ) async throws {
        let input = UpdateItemInput(
            expressionAttributeNames: ["#qa": "quoteApprovalState"],
            expressionAttributeValues: [":state": .s(state)],
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("STATUS#\(statusId)"),
            ],
            tableName: tableName,
            updateExpression: "SET #qa = :state"
        )
        _ = try await client.updateItem(input: input)
    }

    /// Atomically increment the quotes count for a status.
    public func incrementQuotesCount(username: String, statusId: String, by amount: Int = 1) async throws {
        let input = UpdateItemInput(
            expressionAttributeNames: ["#qc": "quotesCount"],
            expressionAttributeValues: [":val": .n(String(amount)), ":zero": .n("0")],
            key: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("STATUS#\(statusId)"),
            ],
            tableName: tableName,
            updateExpression: "SET #qc = if_not_exists(#qc, :zero) + :val"
        )
        _ = try await client.updateItem(input: input)
    }

    /// Find a status by its ActivityPub URI.
    /// Queries statuses for the given username and filters by URI.
    /// Returns nil if not found.
    ///
    /// Note: DynamoDB `Limit` limits items *evaluated*, not items *returned*.
    /// With a `FilterExpression`, `limit: 1` would evaluate only one item and
    /// return nothing if that item doesn't match the filter. We omit the limit
    /// entirely and take the first matching result in code.
    public func findStatusByUri(username: String, uri: String) async throws -> Status? {
        let input = QueryInput(
            expressionAttributeNames: [
                "#pk": "PK",
                "#sk": "SK",
                "#uri": "uri",
            ],
            expressionAttributeValues: [
                ":pk": .s("ACTOR#\(username)"),
                ":prefix": .s("STATUS#"),
                ":uri": .s(uri),
            ],
            filterExpression: "#uri = :uri",
            keyConditionExpression: "#pk = :pk AND begins_with(#sk, :prefix)",
            tableName: tableName
        )
        let output = try await client.query(input: input)
        guard let items = output.items, let first = items.first else { return nil }
        return Status.fromDynamoDB(first)
    }

    /// Fetch a single status by username and ID.
    /// - Parameters:
    ///   - username: The local actor username.
    ///   - id: The status ULID.
    ///   - consistentRead: Use strongly consistent read (default: false). Set to true
    ///     when reading immediately after a write and the latest value is required.
    public func getStatus(username: String, id: String, consistentRead: Bool = false) async throws -> Status? {
        let input = GetItemInput(
            consistentRead: consistentRead,
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

    /// Store media attachment metadata in DynamoDB.
    ///
    /// Creates a record with `PK=MEDIA#{id}`, `SK=META` containing the S3 key,
    /// content type, and optional description/blurhash/dimensions.
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

    /// Generate a ULID-like identifier (timestamp + random).
    ///
    /// Returns a 32-character hex string: 16 hex digits of millisecond timestamp
    /// followed by 16 hex digits of random data. Sorts lexicographically by time.
    public func generateULID() -> String {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let random = UInt64.random(in: 0...UInt64.max)
        return String(format: "%016llX%016llX", timestamp, random)
    }
}
