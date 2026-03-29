import Foundation

public struct WebFingerResponse: Codable, Sendable {
    public let subject: String
    public let links: [WebFingerLink]

    public init(subject: String, links: [WebFingerLink]) {
        self.subject = subject
        self.links = links
    }
}

public struct WebFingerLink: Codable, Sendable {
    public let rel: String
    public let type: String?
    public let href: String?
    public let template: String?

    public init(rel: String, type: String? = nil, href: String? = nil, template: String? = nil) {
        self.rel = rel
        self.type = type
        self.href = href
        self.template = template
    }

    // Custom encoding to omit nil optional fields (no null values in JRD output)
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rel, forKey: .rel)
        if let type { try container.encode(type, forKey: .type) }
        if let href { try container.encode(href, forKey: .href) }
        if let template { try container.encode(template, forKey: .template) }
    }
}
