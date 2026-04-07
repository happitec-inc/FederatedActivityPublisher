import Foundation

/// A WebFinger (RFC 7033) response for actor discovery.
///
/// Returned by `GET /.well-known/webfinger?resource=acct:user@domain`. Contains the
/// subject (acct URI) and links pointing to the actor's ActivityPub profile.
public struct WebFingerResponse: Codable, Sendable {
    /// The queried resource (e.g. `acct:myactor@example.com`).
    public let subject: String
    /// Links to the actor's representations (ActivityPub JSON-LD, profile page, etc.).
    public let links: [WebFingerLink]

    public init(subject: String, links: [WebFingerLink]) {
        self.subject = subject
        self.links = links
    }
}

/// A single link entry in a WebFinger response.
///
/// Nil optional fields are omitted during JSON encoding (no `null` values in JRD output).
public struct WebFingerLink: Codable, Sendable {
    /// Link relation type (e.g. `self`, `http://webfinger.net/rel/profile-page`).
    public let rel: String
    /// MIME type of the linked resource (e.g. `application/activity+json`).
    public let type: String?
    /// URL of the linked resource.
    public let href: String?
    /// URI template for parameterized lookups.
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
