import Foundation

public struct OrderedCollection: Codable, Sendable {
    public let context: String
    public let id: String
    public let type: String
    public let totalItems: Int
    public let first: String?
    public let last: String?
    public let orderedItems: [String]?

    enum CodingKeys: String, CodingKey {
        case context = "@context"
        case id, type, totalItems, first, last, orderedItems
    }

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

    // Custom encoding to omit nil optional fields
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

    /// Empty collection for stubs (outbox root -- no orderedItems)
    public static func emptyRoot(id: String) -> OrderedCollection {
        OrderedCollection(
            context: "https://www.w3.org/ns/activitystreams",
            id: id, type: "OrderedCollection", totalItems: 0,
            first: nil, last: nil, orderedItems: nil
        )
    }

    /// Empty collection for featured/featuredTags (includes empty orderedItems)
    public static func emptyWithItems(id: String) -> OrderedCollection {
        OrderedCollection(
            context: "https://www.w3.org/ns/activitystreams",
            id: id, type: "OrderedCollection", totalItems: 0,
            first: nil, last: nil, orderedItems: []
        )
    }
}
