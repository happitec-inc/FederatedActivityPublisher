import Testing
import AWSDynamoDB
@testable import ActivityPubCore

@Test func actorFromAttributeMap() throws {
    let attributes: [String: DynamoDBClientTypes.AttributeValue] = [
        "username": .s("testuser"),
        "displayName": .s("Test User"),
        "summary": .s("A test"),
        "publicKeyPem": .s("-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----"),
        "privateKeyArn": .s("/activity/stage/keys/testuser"),
        "createdAt": .s("2026-03-28T00:00:00Z"),
        "discoverable": .bool(true),
        "manuallyApprovesFollowers": .bool(false),
        "followerCount": .n("0"),
        "followingCount": .n("0"),
        "statusCount": .n("0"),
    ]
    let actor = Actor.fromDynamoDB(attributes)
    #expect(actor != nil)
    #expect(actor?.username == "testuser")
    #expect(actor?.displayName == "Test User")
    #expect(actor?.followerCount == 0)
    #expect(actor?.discoverable == true)
    #expect(actor?.avatarUrl == nil)
}

@Test func actorFromAttributeMapWithOptionalFields() throws {
    let attributes: [String: DynamoDBClientTypes.AttributeValue] = [
        "username": .s("testuser"),
        "displayName": .s("Test User"),
        "summary": .s("A test"),
        "publicKeyPem": .s("key"),
        "privateKeyArn": .s("/keys/test"),
        "createdAt": .s("2026-03-28T00:00:00Z"),
        "discoverable": .bool(true),
        "manuallyApprovesFollowers": .bool(false),
        "followerCount": .n("0"),
        "followingCount": .n("0"),
        "statusCount": .n("0"),
        "avatarUrl": .s("https://example.com/avatar.png"),
        "headerUrl": .s("https://example.com/header.png"),
    ]
    let actor = Actor.fromDynamoDB(attributes)
    #expect(actor != nil)
    #expect(actor?.avatarUrl == "https://example.com/avatar.png")
    #expect(actor?.headerUrl == "https://example.com/header.png")
}

@Test func actorFromIncompleteAttributeMapReturnsNil() throws {
    let attributes: [String: DynamoDBClientTypes.AttributeValue] = [
        "username": .s("testuser"),
        // Missing required fields
    ]
    let actor = Actor.fromDynamoDB(attributes)
    #expect(actor == nil)
}

@Test func actorFromEmptyAttributeMapReturnsNil() throws {
    let attributes: [String: DynamoDBClientTypes.AttributeValue] = [:]
    let actor = Actor.fromDynamoDB(attributes)
    #expect(actor == nil)
}
