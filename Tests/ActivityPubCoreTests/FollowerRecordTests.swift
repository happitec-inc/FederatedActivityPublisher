import Testing
import AWSDynamoDB
@testable import ActivityPubCore

// Follow / Undo(Follow) storage. Scenario: a remote user follows (Follow#1), unfollows and
// refollows (Follow#2), and Undo(Follow#1) is processed after Follow#2. The follower must
// stay. That holds when a repeated Follow records its own id, and Undo deletes only when
// its object id matches the stored one.

private func stringValue(_ value: DynamoDBClientTypes.AttributeValue?) -> String? {
    if case .s(let string) = value { return string }
    return nil
}

private func follower(followActivityId: String, sharedInboxUrl: String? = "https://remote.example/inbox") -> Follower {
    Follower(
        actorUri: "https://remote.example/users/alice",
        inboxUrl: "https://remote.example/users/alice/inbox",
        sharedInboxUrl: sharedInboxUrl,
        followActivityId: followActivityId,
        acceptedAt: "2026-10-20T00:00:00Z"
    )
}

@Test func repeatedFollowRecordsNewestFollowId() throws {
    let input = DynamoDBStore.storeFollowerInput(
        tableName: "t",
        username: "memes",
        follower: follower(followActivityId: "https://remote.example/follows/2"),
        now: "2026-10-20T00:00:00Z"
    )
    // No condition: the write must also apply when the follower record already exists
    #expect(input.conditionExpression == nil)
    #expect(input.updateExpression?.contains("followActivityId = :followActivityId") == true)
    #expect(stringValue(input.expressionAttributeValues?[":followActivityId"]) == "https://remote.example/follows/2")
    #expect(input.updateExpression?.contains("acceptedAt = :acceptedAt") == true)
    #expect(stringValue(input.key?["SK"]) == "FOLLOWER#https://remote.example/users/alice")
}

@Test func repeatedFollowReportsWhetherRecordIsNew() throws {
    let input = DynamoDBStore.storeFollowerInput(
        tableName: "t",
        username: "memes",
        follower: follower(followActivityId: "https://remote.example/follows/2"),
        now: "2026-10-20T00:00:00Z"
    )
    // The previous item comes back, so only the first Follow increments the count
    #expect(input.returnValues == .allOld)
    #expect(input.updateExpression?.contains("createdAt = if_not_exists(createdAt, :now)") == true)
}

@Test func followWithoutSharedInboxClearsStoredSharedInbox() throws {
    let input = DynamoDBStore.storeFollowerInput(
        tableName: "t",
        username: "memes",
        follower: follower(followActivityId: "https://remote.example/follows/2", sharedInboxUrl: nil),
        now: "2026-10-20T00:00:00Z"
    )
    #expect(input.updateExpression?.hasSuffix(" REMOVE sharedInboxUrl") == true)
    #expect(input.expressionAttributeValues?[":sharedInboxUrl"] == nil)
}

@Test func undoFollowDeletesOnlyMatchingFollow() throws {
    let input = DynamoDBStore.removeFollowerInput(
        tableName: "t",
        username: "memes",
        actorUri: "https://remote.example/users/alice",
        followActivityId: "https://remote.example/follows/1"
    )
    #expect(input.conditionExpression == "attribute_exists(SK) AND followActivityId = :followActivityId")
    #expect(stringValue(input.expressionAttributeValues?[":followActivityId"]) == "https://remote.example/follows/1")
    #expect(stringValue(input.key?["SK"]) == "FOLLOWER#https://remote.example/users/alice")
}

@Test func undoObjectIdFromBareUri() throws {
    let undo: [String: Any] = [
        "type": "Undo",
        "actor": "https://remote.example/users/alice",
        "object": "https://remote.example/follows/1",
    ]
    #expect(extractObjectUri(from: undo) == "https://remote.example/follows/1")
}

@Test func undoObjectIdFromInlineFollow() throws {
    let undo: [String: Any] = [
        "type": "Undo",
        "actor": "https://remote.example/users/alice",
        "object": [
            "id": "https://remote.example/follows/1",
            "type": "Follow",
            "object": "https://activity.example/users/memes",
        ] as [String: Any],
    ]
    #expect(extractObjectUri(from: undo) == "https://remote.example/follows/1")
}

@Test func undoObjectIdMissing() throws {
    let undo: [String: Any] = [
        "type": "Undo",
        "object": ["type": "Follow"] as [String: Any],
    ]
    #expect(extractObjectUri(from: undo) == nil)
}
