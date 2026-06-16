import Testing
import Foundation
import AWSDynamoDB
@testable import ActivityPubCore

// Minimal DynamoDB attribute map for a valid Actor record.
private func sampleActorItem(sourceNote: String? = nil) -> [String: DynamoDBClientTypes.AttributeValue] {
    var item: [String: DynamoDBClientTypes.AttributeValue] = [
        "username": .s("testbot"),
        "displayName": .s("Test Bot"),
        "summary": .s("<p>Hello world</p>"),
        "publicKeyPem": .s("-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----"),
        "privateKeyArn": .s("/activity/stage/keys/testbot"),
        "createdAt": .s("2026-01-01T00:00:00Z"),
        "discoverable": .bool(true),
        "manuallyApprovesFollowers": .bool(false),
        "followerCount": .n("0"),
        "followingCount": .n("0"),
        "statusCount": .n("0"),
    ]
    if let sourceNote {
        item["sourceNote"] = .s(sourceNote)
    }
    return item
}

@Test func actorSourceNoteDecodesWhenPresent() {
    let item = sampleActorItem(sourceNote: "Hello **world**")
    let actor = Actor.fromDynamoDB(item)
    #expect(actor != nil)
    #expect(actor?.sourceNote == "Hello **world**")
}

@Test func actorSourceNoteIsNilWhenAbsent() {
    let item = sampleActorItem()
    let actor = Actor.fromDynamoDB(item)
    #expect(actor != nil)
    #expect(actor?.sourceNote == nil)
}

/// Regression guard: the public ActivityPub actor JSON-LD must never expose
/// the raw `sourceNote` value or the key name "sourceNote".
@Test func actorJSONLDDoesNotLeakSourceNote() {
    let actor = Actor(
        username: "testbot",
        displayName: "Test Bot",
        summary: "<p>Rendered bio</p>",
        sourceNote: "RAW_SECRET_BIO_DO_NOT_LEAK",
        publicKeyPem: "-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----",
        privateKeyArn: "/activity/stage/keys/testbot",
        createdAt: "2026-01-01T00:00:00Z"
    )
    let json = buildActorJSONLD(
        actor: actor,
        serverDomain: "activity.example.com",
        handleDomain: "example.com"
    )
    #expect(!json.contains("RAW_SECRET_BIO_DO_NOT_LEAK"))
    #expect(!json.contains("sourceNote"))
}
