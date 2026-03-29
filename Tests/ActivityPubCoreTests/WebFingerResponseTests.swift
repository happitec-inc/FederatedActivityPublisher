import Testing
import Foundation
@testable import ActivityPubCore

@Test func webFingerResponseEncoding() throws {
    let response = WebFingerResponse(
        subject: "acct:test@happitec.com",
        links: [
            WebFingerLink(rel: "self", type: "application/activity+json", href: "https://activity.happitec.com/users/test"),
            WebFingerLink(rel: "http://webfinger.net/rel/profile-page", type: "text/html", href: "https://activity.happitec.com/@test"),
        ]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(response)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["subject"] as? String == "acct:test@happitec.com")
    let links = json["links"] as! [[String: Any]]
    #expect(links.count == 2)
    #expect(links[0]["rel"] as? String == "self")
    #expect(links[0]["type"] as? String == "application/activity+json")
}

@Test func webFingerLinkOmitsNilFields() throws {
    let link = WebFingerLink(rel: "self", type: "application/activity+json", href: "https://example.com")
    let data = try JSONEncoder().encode(link)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["template"] == nil) // nil fields should not appear in JSON
    #expect(json["rel"] as? String == "self")
    #expect(json["type"] as? String == "application/activity+json")
    #expect(json["href"] as? String == "https://example.com")
}

@Test func webFingerLinkWithTemplate() throws {
    let link = WebFingerLink(rel: "subscribe", template: "https://example.com/authorize?uri={uri}")
    let data = try JSONEncoder().encode(link)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["template"] as? String == "https://example.com/authorize?uri={uri}")
    #expect(json["type"] == nil)
    #expect(json["href"] == nil)
}
