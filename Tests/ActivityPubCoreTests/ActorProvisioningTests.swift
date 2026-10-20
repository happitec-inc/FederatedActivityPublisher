import Testing
import AWSDynamoDB
import AWSSSM
@testable import ActivityPubCore

/// In-memory stand-ins for the SSM key parameter and the DynamoDB profile, each refusing
/// to replace an existing record (as the conditional writes do).
private final class FakeActorRecords {
    var key: String?
    var profile: String?

    func provision(newKey: String, newProfile: String) async throws {
        try await provisionActorRecords(
            keyPath: "/activity/stage/keys/memes",
            username: "memes",
            writeKey: {
                guard key == nil else { return false }
                key = newKey
                return true
            },
            writeProfile: {
                guard profile == nil else { return false }
                profile = newProfile
                return true
            },
            deleteKey: { key = nil }
        )
    }
}

@Test func provisioningNewActorWritesKeyAndProfile() async throws {
    let records = FakeActorRecords()
    try await records.provision(newKey: "new-key", newProfile: "new-profile")
    #expect(records.key == "new-key")
    #expect(records.profile == "new-profile")
}

@Test func provisioningExistingActorFailsAndChangesNothing() async throws {
    let records = FakeActorRecords()
    records.key = "old-key"
    records.profile = "old-profile"

    await #expect(throws: ActorProvisioningError.keyExists(path: "/activity/stage/keys/memes")) {
        try await records.provision(newKey: "new-key", newProfile: "new-profile")
    }
    #expect(records.key == "old-key")
    #expect(records.profile == "old-profile")
}

@Test func provisioningOverExistingProfileRemovesTheNewKey() async throws {
    // A profile without a key: the key write succeeds, the profile write is refused, and
    // the new key must not be left behind next to a profile holding a different public key.
    let records = FakeActorRecords()
    records.profile = "old-profile"

    await #expect(throws: ActorProvisioningError.profileExists(username: "memes")) {
        try await records.provision(newKey: "new-key", newProfile: "new-profile")
    }
    #expect(records.key == nil)
    #expect(records.profile == "old-profile")
}

@Test func actorKeyWriteNeverOverwrites() throws {
    let input = actorKeyParameterInput(path: "/activity/stage/keys/memes", privateKeyPem: "pem")
    #expect(input.overwrite == false)
    #expect(input.name == "/activity/stage/keys/memes")
    #expect(input.type == .secureString)
}

@Test func actorProfileWriteNeverOverwrites() throws {
    let input = actorProfileInput(
        tableName: "activity-stage",
        username: "memes",
        displayName: "Memes",
        summary: "",
        publicKeyPem: "pub",
        privateKeyPath: "/activity/stage/keys/memes",
        createdAt: "2026-10-20T00:00:00Z"
    )
    #expect(input.conditionExpression == "attribute_not_exists(SK)")
    #expect(input.item?["PK"] == .s("ACTOR#memes"))
    #expect(input.item?["SK"] == .s("PROFILE"))
    #expect(input.item?["privateKeyArn"] == .s("/activity/stage/keys/memes"))
}
