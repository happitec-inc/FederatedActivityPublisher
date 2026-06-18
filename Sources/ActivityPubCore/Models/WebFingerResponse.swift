/// The JSON Resource Descriptor (JRD) returned by the WebFinger endpoint, and the link type it contains.
///
/// `WebFingerHandler` constructs a ``WebFingerResponse`` for each `GET /.well-known/webfinger`
/// request. It always includes a `self` link pointing to the AP actor JSON and a profile-page
/// link pointing to the HTML profile. The `happitec.com` CloudFront Function proxies the request
/// here from the handle domain; see the project architecture notes for the two-domain setup.
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

    /// Create a WebFingerResponse.
    ///
    /// - Parameters:
    ///   - subject: The `acct:` URI that was queried (e.g. `acct:alice@happitec.com`).
    ///   - links: One or more links describing the actor's representations.
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

    /// Create a WebFingerLink.
    ///
    /// - Parameters:
    ///   - rel: Link relation type (e.g. `"self"`, `"http://webfinger.net/rel/profile-page"`).
    ///   - type: MIME type of the linked resource (e.g. `"application/activity+json"`).
    ///   - href: Absolute URL of the linked resource.
    ///   - template: URI template string, used for OStatus subscription links; mutually exclusive with `href`.
    public init(rel: String, type: String? = nil, href: String? = nil, template: String? = nil) {
        self.rel = rel
        self.type = type
        self.href = href
        self.template = template
    }

    /// Encode to JSON, omitting nil fields so the JRD output contains no null values.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rel, forKey: .rel)
        if let type { try container.encode(type, forKey: .type) }
        if let href { try container.encode(href, forKey: .href) }
        if let template { try container.encode(template, forKey: .template) }
    }
}
