import Testing
import Foundation
@testable import ActivityPubCore

@Suite("Note and Create activity builder")
struct NoteBuilderTests {

    let domain = "activity.happitec.com"
    let user = "testuser"

    func makeStatus(
        visibility: String = "public",
        attachments: [MediaAttachmentRef]? = nil,
        tags: [ActivityPubCore.Tag]? = nil,
        contentWarning: String? = nil
    ) -> Status {
        let addressing = computeAddressing(
            visibility: visibility,
            serverDomain: domain,
            username: user
        )!
        return Status(
            id: "01ABC123",
            username: user,
            content: "<p>Hello world</p>",
            contentWarning: contentWarning,
            visibility: visibility,
            sensitive: contentWarning != nil,
            language: "en",
            published: "2026-03-29T12:00:00.000Z",
            url: "https://\(domain)/@\(user)/01ABC123",
            uri: "https://\(domain)/users/\(user)/statuses/01ABC123",
            to: addressing.to,
            cc: addressing.cc,
            tags: tags,
            attachments: attachments,
            inReplyTo: nil
        )
    }

    // MARK: - Addressing tests

    @Test("Public addressing: to=[as:Public], cc=[followers]")
    func publicAddressing() {
        let result = computeAddressing(visibility: "public", serverDomain: domain, username: user)
        #expect(result != nil)
        #expect(result!.to == ["https://www.w3.org/ns/activitystreams#Public"])
        #expect(result!.cc == ["https://\(domain)/users/\(user)/followers"])
    }

    @Test("Unlisted addressing: to=[followers], cc=[as:Public]")
    func unlistedAddressing() {
        let result = computeAddressing(visibility: "unlisted", serverDomain: domain, username: user)
        #expect(result != nil)
        #expect(result!.to == ["https://\(domain)/users/\(user)/followers"])
        #expect(result!.cc == ["https://www.w3.org/ns/activitystreams#Public"])
    }

    @Test("Private addressing: to=[followers], cc=[]")
    func privateAddressing() {
        let result = computeAddressing(visibility: "private", serverDomain: domain, username: user)
        #expect(result != nil)
        #expect(result!.to == ["https://\(domain)/users/\(user)/followers"])
        #expect(result!.cc == [])
    }

    @Test("Direct addressing: returns nil (not supported)")
    func directAddressing() {
        let result = computeAddressing(visibility: "direct", serverDomain: domain, username: user)
        #expect(result == nil)
    }

    // MARK: - Note builder tests

    @Test("Note includes attributedTo")
    func noteHasAttributedTo() {
        let status = makeStatus()
        let json = buildNoteJSON(status: status, serverDomain: domain, username: user)
        #expect(json.contains("\"attributedTo\":\"https://\(domain)/users/\(user)\""))
    }

    @Test("Note includes type Note")
    func noteHasType() {
        let status = makeStatus()
        let json = buildNoteJSON(status: status, serverDomain: domain, username: user)
        #expect(json.contains("\"type\":\"Note\""))
    }

    @Test("Note includes to/cc for public visibility")
    func noteHasPublicAddressing() {
        let status = makeStatus(visibility: "public")
        let json = buildNoteJSON(status: status, serverDomain: domain, username: user)
        #expect(json.contains("\"to\":[\"https://www.w3.org/ns/activitystreams#Public\"]"))
        #expect(json.contains("\"cc\":[\"https://\(domain)/users/\(user)/followers\"]"))
    }

    @Test("Note includes attachments when present")
    func noteWithAttachments() {
        let att = MediaAttachmentRef(
            id: "media1",
            url: "https://\(domain)/media/media1/photo.jpg",
            contentType: "image/jpeg",
            description: "A test image",
            blurhash: "LEHV6nWB2yk8"
        )
        let status = makeStatus(attachments: [att])
        let json = buildNoteJSON(status: status, serverDomain: domain, username: user)
        #expect(json.contains("\"attachment\""))
        #expect(json.contains("\"type\":\"Image\""))
        #expect(json.contains("\"mediaType\":\"image/jpeg\""))
        #expect(json.contains("\"name\":\"A test image\""))
        #expect(json.contains("\"blurhash\":\"LEHV6nWB2yk8\""))
    }

    @Test("Note includes content warning as summary")
    func noteWithContentWarning() {
        let status = makeStatus(contentWarning: "Spoiler alert")
        let json = buildNoteJSON(status: status, serverDomain: domain, username: user)
        #expect(json.contains("\"summary\":\"Spoiler alert\""))
        #expect(json.contains("\"sensitive\":true"))
    }

    // MARK: - Create activity tests

    @Test("Create wrapper has correct type and actor")
    func createActivity() {
        let status = makeStatus()
        let noteJSON = buildNoteJSON(status: status, serverDomain: domain, username: user)
        let createJSON = buildCreateActivityJSON(
            status: status, noteJSON: noteJSON,
            serverDomain: domain, username: user
        )
        #expect(createJSON.contains("\"type\":\"Create\""))
        #expect(createJSON.contains("\"actor\":\"https://\(domain)/users/\(user)\""))
    }

    @Test("Create wrapper includes to/cc at activity level")
    func createActivityHasAddressing() {
        let status = makeStatus(visibility: "public")
        let noteJSON = buildNoteJSON(status: status, serverDomain: domain, username: user)
        let createJSON = buildCreateActivityJSON(
            status: status, noteJSON: noteJSON,
            serverDomain: domain, username: user
        )
        // to/cc should appear at the Create level (outside the object)
        // The Create JSON starts with the activity-level fields before "object":
        let beforeObject = createJSON.components(separatedBy: "\"object\":").first ?? ""
        #expect(beforeObject.contains("\"to\":[\"https://www.w3.org/ns/activitystreams#Public\"]"))
        #expect(beforeObject.contains("\"cc\":[\"https://\(domain)/users/\(user)/followers\"]"))
    }

    @Test("Create wrapper embeds Note as object")
    func createActivityEmbedsNote() {
        let status = makeStatus()
        let noteJSON = buildNoteJSON(status: status, serverDomain: domain, username: user)
        let createJSON = buildCreateActivityJSON(
            status: status, noteJSON: noteJSON,
            serverDomain: domain, username: user
        )
        #expect(createJSON.contains("\"object\":{"))
        #expect(createJSON.contains("\"type\":\"Note\""))
    }

    @Test("Create activity id ends with /activity")
    func createActivityId() {
        let status = makeStatus()
        let noteJSON = buildNoteJSON(status: status, serverDomain: domain, username: user)
        let createJSON = buildCreateActivityJSON(
            status: status, noteJSON: noteJSON,
            serverDomain: domain, username: user
        )
        #expect(createJSON.contains("\"id\":\"https://\(domain)/users/\(user)/statuses/01ABC123/activity\""))
    }
}
