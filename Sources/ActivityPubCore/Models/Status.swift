import AWSDynamoDB
import Foundation

/// A status (post) record stored in DynamoDB.
public struct Status: Codable, Sendable {
    public let id: String           // ULID
    public let username: String
    public let content: String      // HTML
    public let contentWarning: String?
    public let visibility: String   // public, unlisted, private, direct
    public let sensitive: Bool
    public let language: String?
    public let published: String    // ISO 8601
    public let url: String          // human-readable permalink
    public let uri: String          // ActivityPub URI
    public let to: [String]
    public let cc: [String]
    public let tags: [Tag]?
    public let attachments: [MediaAttachmentRef]?
    public let inReplyTo: String?
    public let likesCount: Int
    public let boostsCount: Int
    public let repliesCount: Int

    public init(
        id: String, username: String, content: String, contentWarning: String?,
        visibility: String, sensitive: Bool, language: String?,
        published: String, url: String, uri: String,
        to: [String], cc: [String], tags: [Tag]?,
        attachments: [MediaAttachmentRef]?, inReplyTo: String?,
        likesCount: Int = 0, boostsCount: Int = 0, repliesCount: Int = 0
    ) {
        self.id = id
        self.username = username
        self.content = content
        self.contentWarning = contentWarning
        self.visibility = visibility
        self.sensitive = sensitive
        self.language = language
        self.published = published
        self.url = url
        self.uri = uri
        self.to = to
        self.cc = cc
        self.tags = tags
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.likesCount = likesCount
        self.boostsCount = boostsCount
        self.repliesCount = repliesCount
    }

    /// Convert a DynamoDB attribute map to a Status, returning nil if required fields are missing.
    public static func fromDynamoDB(_ attributes: [String: DynamoDBClientTypes.AttributeValue]) -> Status? {
        guard
            case .s(let id) = attributes["id"],
            case .s(let username) = attributes["username"],
            case .s(let content) = attributes["content"],
            case .s(let visibility) = attributes["visibility"],
            case .bool(let sensitive) = attributes["sensitive"],
            case .s(let published) = attributes["published"],
            case .s(let url) = attributes["url"],
            case .s(let uri) = attributes["uri"],
            case .s(let toJSON) = attributes["toRecipients"],
            case .s(let ccJSON) = attributes["ccRecipients"]
        else {
            return nil
        }

        let decoder = JSONDecoder()

        let to = (try? decoder.decode([String].self, from: Data(toJSON.utf8))) ?? []
        let cc = (try? decoder.decode([String].self, from: Data(ccJSON.utf8))) ?? []

        var contentWarning: String?
        if case .s(let cw) = attributes["contentWarning"] {
            contentWarning = cw
        }

        var language: String?
        if case .s(let lang) = attributes["language"] {
            language = lang
        }

        var inReplyTo: String?
        if case .s(let reply) = attributes["inReplyTo"] {
            inReplyTo = reply
        }

        var tags: [Tag]?
        if case .s(let tagsJSON) = attributes["tags"] {
            tags = try? decoder.decode([Tag].self, from: Data(tagsJSON.utf8))
        }

        var attachments: [MediaAttachmentRef]?
        if case .s(let attachJSON) = attributes["attachments"] {
            attachments = try? decoder.decode([MediaAttachmentRef].self, from: Data(attachJSON.utf8))
        }

        var likesCount = 0
        if case .n(let n) = attributes["likesCount"], let v = Int(n) { likesCount = v }
        var boostsCount = 0
        if case .n(let n) = attributes["boostsCount"], let v = Int(n) { boostsCount = v }
        var repliesCount = 0
        if case .n(let n) = attributes["repliesCount"], let v = Int(n) { repliesCount = v }

        return Status(
            id: id, username: username, content: content, contentWarning: contentWarning,
            visibility: visibility, sensitive: sensitive, language: language,
            published: published, url: url, uri: uri,
            to: to, cc: cc, tags: tags,
            attachments: attachments, inReplyTo: inReplyTo,
            likesCount: likesCount, boostsCount: boostsCount, repliesCount: repliesCount
        )
    }

    /// Convert to DynamoDB attribute map for storage.
    public func toDynamoDB() -> [String: DynamoDBClientTypes.AttributeValue] {
        let encoder = JSONEncoder()

        var item: [String: DynamoDBClientTypes.AttributeValue] = [
            "PK": .s("ACTOR#\(username)"),
            "SK": .s("STATUS#\(id)"),
            "GSI1PK": .s("ACTOR#\(username)"),
            "GSI1SK": .s("PUBLISHED#\(published)"),
            "id": .s(id),
            "username": .s(username),
            "content": .s(content),
            "visibility": .s(visibility),
            "sensitive": .bool(sensitive),
            "published": .s(published),
            "url": .s(url),
            "uri": .s(uri),
            "toRecipients": .s(String(data: (try? encoder.encode(to)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"),
            "ccRecipients": .s(String(data: (try? encoder.encode(cc)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"),
            "likesCount": .n(String(likesCount)),
            "boostsCount": .n(String(boostsCount)),
            "repliesCount": .n(String(repliesCount)),
        ]

        if let contentWarning {
            item["contentWarning"] = .s(contentWarning)
        }
        if let language {
            item["language"] = .s(language)
        }
        if let inReplyTo {
            item["inReplyTo"] = .s(inReplyTo)
        }
        if let tags, let data = try? encoder.encode(tags) {
            item["tags"] = .s(String(data: data, encoding: .utf8) ?? "[]")
        }
        if let attachments, let data = try? encoder.encode(attachments) {
            item["attachments"] = .s(String(data: data, encoding: .utf8) ?? "[]")
        }

        return item
    }
}

/// A tag entry (Hashtag, Mention, Emoji) on a status.
public struct Tag: Codable, Sendable {
    public let type: String         // "Hashtag", "Mention", "Emoji"
    public let name: String         // "#tag" or "@user@domain"
    public let href: String?        // URL

    public init(type: String, name: String, href: String?) {
        self.type = type
        self.name = name
        self.href = href
    }
}

/// A media attachment reference on a status.
public struct MediaAttachmentRef: Codable, Sendable {
    public let id: String
    public let url: String          // CloudFront URL
    public let contentType: String
    public let description: String? // alt text
    public let blurhash: String?

    public init(id: String, url: String, contentType: String, description: String?, blurhash: String?) {
        self.id = id
        self.url = url
        self.contentType = contentType
        self.description = description
        self.blurhash = blurhash
    }
}
