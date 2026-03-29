import Testing
import Foundation
@testable import ActivityPubCore

@Test func emptyRootOmitsOrderedItems() throws {
    let collection = OrderedCollection.emptyRoot(id: "https://example.com/outbox")
    let data = try JSONEncoder().encode(collection)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["@context"] as? String == "https://www.w3.org/ns/activitystreams")
    #expect(json["type"] as? String == "OrderedCollection")
    #expect(json["totalItems"] as? Int == 0)
    #expect(json["orderedItems"] == nil) // Must NOT be present for root collections
    #expect(json["first"] == nil)
    #expect(json["last"] == nil)
}

@Test func emptyWithItemsIncludesOrderedItems() throws {
    let collection = OrderedCollection.emptyWithItems(id: "https://example.com/featured")
    let data = try JSONEncoder().encode(collection)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let items = json["orderedItems"] as? [Any]
    #expect(items != nil)
    #expect(items?.count == 0)
}

@Test func orderedCollectionCodingKeyMapping() throws {
    let collection = OrderedCollection.emptyRoot(id: "https://example.com/test")
    let data = try JSONEncoder().encode(collection)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    // Verify @context key is present (not "context")
    #expect(json["@context"] != nil)
    #expect(json["context"] == nil)
}

@Test func orderedCollectionRoundTrip() throws {
    let collection = OrderedCollection(
        context: "https://www.w3.org/ns/activitystreams",
        id: "https://example.com/outbox",
        type: "OrderedCollection",
        totalItems: 5,
        first: "https://example.com/outbox?page=1",
        last: "https://example.com/outbox?page=2",
        orderedItems: nil
    )
    let data = try JSONEncoder().encode(collection)
    let decoded = try JSONDecoder().decode(OrderedCollection.self, from: data)
    #expect(decoded.context == "https://www.w3.org/ns/activitystreams")
    #expect(decoded.id == "https://example.com/outbox")
    #expect(decoded.totalItems == 5)
    #expect(decoded.first == "https://example.com/outbox?page=1")
    #expect(decoded.last == "https://example.com/outbox?page=2")
}
