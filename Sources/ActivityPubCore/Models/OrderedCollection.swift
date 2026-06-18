/// An ActivityPub OrderedCollection or OrderedCollectionPage, returned by the outbox, followers,
/// following, featured, and featured-tags endpoints.
///
/// The type is reused for both the root collection (which carries `totalItems` and a `first` page
/// link) and individual pages (which carry `orderedItems` inline). Nil fields are omitted from the
/// encoded JSON so the output is valid JSON-LD without null values. This struct is not persisted to
/// DynamoDB; it is assembled on the fly by the relevant handler Lambda from data read from the
/// ``Status`` or ``Follower`` tables.
import Foundation

/// An ActivityPub `OrderedCollection` or `OrderedCollectionPage`.
///
/// Used for the outbox, followers, following, featured, and featured-tags endpoints.
/// Nil fields are omitted during encoding so the JSON-LD output contains no null values.
public struct OrderedCollection: Codable, Sendable {
    /// The JSON-LD context URI.
    public let context: String
    /// The collection's canonical URI.
    public let id: String
    /// The ActivityPub type (`OrderedCollection` or `OrderedCollectionPage`).
    public let type: String
    /// Total number of items in the collection.
    public let totalItems: Int
    /// URI of the first page, for paginated collections.
    public let first: String?
    /// URI of the last page, for paginated collections.
    public let last: String?
    /// Inline items, used for non-paginated collections.
    public let orderedItems: [String]?

    enum CodingKeys: String, CodingKey {
        case context = "@context"
        case id, type, totalItems, first, last, orderedItems
    }

    /// Create an OrderedCollection.
    ///
    /// - Parameters:
    ///   - context: JSON-LD context URI (typically `"https://www.w3.org/ns/activitystreams"`).
    ///   - id: Canonical URI for this collection or page.
    ///   - type: `"OrderedCollection"` for root collections, `"OrderedCollectionPage"` for pages.
    ///   - totalItems: Total item count across all pages.
    ///   - first: URI of the first page; `nil` for inline collections.
    ///   - last: URI of the last page; `nil` for inline collections.
    ///   - orderedItems: Inline items for non-paginated or page responses; `nil` for root collections.
    public init(
        context: String, id: String, type: String, totalItems: Int,
        first: String?, last: String?, orderedItems: [String]?
    ) {
        self.context = context
        self.id = id
        self.type = type
        self.totalItems = totalItems
        self.first = first
        self.last = last
        self.orderedItems = orderedItems
    }

    /// Encode to JSON, omitting nil optional fields so the output contains no null values.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(context, forKey: .context)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(totalItems, forKey: .totalItems)
        if let first { try container.encode(first, forKey: .first) }
        if let last { try container.encode(last, forKey: .last) }
        if let orderedItems { try container.encode(orderedItems, forKey: .orderedItems) }
    }

    /// An empty root collection with no inline items, used for outbox stubs.
    ///
    /// Produces `totalItems: 0`, no `orderedItems` field, and no page links. Mastodon fetches the
    /// outbox root only to discover `totalItems`; it does not require inline items here.
    ///
    /// - Parameter id: Canonical URI for the outbox collection.
    /// - Returns: An `OrderedCollection` suitable for the outbox root response.
    public static func emptyRoot(id: String) -> OrderedCollection {
        OrderedCollection(
            context: "https://www.w3.org/ns/activitystreams",
            id: id, type: "OrderedCollection", totalItems: 0,
            first: nil, last: nil, orderedItems: nil
        )
    }

    /// An empty collection with an explicit empty `orderedItems` array, used for `featured` and
    /// `featuredTags` endpoints.
    ///
    /// Some ActivityPub clients expect `orderedItems` to be present (even if empty) on these
    /// endpoints. Unlike ``emptyRoot(id:)``, this variant includes `"orderedItems":[]` in the output.
    ///
    /// - Parameter id: Canonical URI for the collection.
    /// - Returns: An `OrderedCollection` with `orderedItems: []`.
    public static func emptyWithItems(id: String) -> OrderedCollection {
        OrderedCollection(
            context: "https://www.w3.org/ns/activitystreams",
            id: id, type: "OrderedCollection", totalItems: 0,
            first: nil, last: nil, orderedItems: []
        )
    }
}
