import Testing
import Foundation
@testable import ActivityPubCore

@Test func actorRoundTrip() throws {
    let actor = Actor(
        username: "testuser",
        displayName: "Test User",
        summary: "A test account",
        publicKeyPem: "-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----",
        privateKeyArn: "/activity/stage/keys/testuser",
        createdAt: "2026-03-28T00:00:00Z"
    )
    let data = try JSONEncoder().encode(actor)
    let decoded = try JSONDecoder().decode(Actor.self, from: data)
    #expect(decoded.username == "testuser")
    #expect(decoded.displayName == "Test User")
    #expect(decoded.publicKeyPem.contains("BEGIN PUBLIC KEY"))
    #expect(decoded.privateKeyArn == "/activity/stage/keys/testuser")
    #expect(decoded.followerCount == 0)
    #expect(decoded.discoverable == true)
    #expect(decoded.manuallyApprovesFollowers == false)
}

@Test func actorDefaultValues() throws {
    let actor = Actor(
        username: "bot",
        displayName: "Bot",
        summary: "",
        publicKeyPem: "key",
        privateKeyArn: "/keys/bot",
        createdAt: "2026-01-01T00:00:00Z"
    )
    #expect(actor.avatarUrl == nil)
    #expect(actor.headerUrl == nil)
    #expect(actor.discoverable == true)
    #expect(actor.manuallyApprovesFollowers == false)
    #expect(actor.followerCount == 0)
    #expect(actor.followingCount == 0)
    #expect(actor.statusCount == 0)
}

@Test func actorWithOptionalFields() throws {
    let actor = Actor(
        username: "testuser",
        displayName: "Test",
        summary: "summary",
        avatarUrl: "https://example.com/avatar.png",
        headerUrl: "https://example.com/header.png",
        publicKeyPem: "key",
        privateKeyArn: "/keys/test",
        createdAt: "2026-01-01T00:00:00Z"
    )
    let data = try JSONEncoder().encode(actor)
    let decoded = try JSONDecoder().decode(Actor.self, from: data)
    #expect(decoded.avatarUrl == "https://example.com/avatar.png")
    #expect(decoded.headerUrl == "https://example.com/header.png")
}
