/// A post authored by a local actor, stored in DynamoDB and serialized to ActivityPub via ``Note``.
///
/// Statuses are written by `PostHandler` after the plain-text content from a
/// ``CreateStatusRequest`` is converted to HTML. They live in the single-table design under
/// `PK=ACTOR#{username}`, `SK=STATUS#{ulid}`, with a GSI on `PUBLISHED#{timestamp}` for
/// time-ordered queries. `StatusHandler` reads the record to build the Mastodon-compatible
/// API response, and `NoteHandler` reads it to serve the AP Note JSON to federated servers.
/// Engagement counters (`likesCount`, `boostsCount`, `repliesCount`, `quotesCount`) are
/// incremented by `InboxHandler` when the corresponding AP activities arrive.
import AWSDynamoDB
import Foundation

/// A post authored by a local actor.
///
/// Keyed by `PK=ACTOR#{username}`, `SK=STATUS#{ulid}`. The ULID provides lexicographic
/// time ordering so reverse-scanning the SK yields newest-first pagination.
public struct Status: Codable, Sendable {
    /// ULID identifier for the status. Sorts lexicographically by creation time.
    public let id: String
    /// Username of the actor who authored this status.
    public let username: String
    /// HTML content of the status.
    public let content: String
    /// Content warning / spoiler text, if any.
    public let contentWarning: String?
    /// Visibility level: `public`, `unlisted`, `private`, or `direct`.
    public let visibility: String
    /// Whether the status contains sensitive content.
    public let sensitive: Bool
    /// ISO 639-1 language code (e.g. `en`), if specified.
    public let language: String?
    /// ISO 8601 publication timestamp.
    public let published: String
    /// Human-readable permalink URL.
    public let url: String
    /// ActivityPub object URI.
    public let uri: String
    /// ActivityPub `to` addressing recipients.
    public let to: [String]
    /// ActivityPub `cc` addressing recipients.
    public let cc: [String]
    /// Hashtags, mentions, and emoji tags attached to the status.
    public let tags: [Tag]?
    /// Media attachments (images, video, audio) referenced by this status.
    public let attachments: [MediaAttachmentRef]?
    /// URI of the status this is replying to, if any.
    public let inReplyTo: String?
    /// Number of likes received from remote actors.
    public let likesCount: Int
    /// Number of boosts (announces) received from remote actors.
    public let boostsCount: Int
    /// Number of replies received from remote actors.
    public let repliesCount: Int
    /// URI of the remote status being quoted by this status, if any.
    public let quotedStatusUri: String?
    /// Quote approval state for outbound quotes: `pending`, `accepted`, `rejected`, or `failed`.
    public let quoteApprovalState: String?
    /// Number of accepted inbound quotes of this status.
    public let quotesCount: Int

    /// Create a Status.
    ///
    /// - Parameters:
    ///   - id: ULID identifier; sorts lexicographically by creation time.
    ///   - username: Authoring actor's username.
    ///   - content: HTML body of the post.
    ///   - contentWarning: Spoiler text shown in place of content, if any.
    ///   - visibility: One of `"public"`, `"unlisted"`, `"private"`, or `"direct"`.
    ///   - sensitive: When `true`, media and content are hidden behind a disclosure.
    ///   - language: ISO 639-1 language code, if specified.
    ///   - published: ISO 8601 publication timestamp.
    ///   - url: Human-readable permalink (e.g. `https://activity.happitec.com/@username/123`).
    ///   - uri: ActivityPub object URI (e.g. `https://activity.happitec.com/users/username/statuses/123`).
    ///   - to: ActivityPub `to` recipients.
    ///   - cc: ActivityPub `cc` recipients.
    ///   - tags: Hashtags, mentions, and emojis attached to this status.
    ///   - attachments: Media attachment references.
    ///   - inReplyTo: URI of the status being replied to, if this is a reply.
    ///   - likesCount: Running total of AP Like activities received.
    ///   - boostsCount: Running total of AP Announce activities received.
    ///   - repliesCount: Running total of replies received.
    ///   - quotedStatusUri: URI of the status being quoted, if any.
    ///   - quoteApprovalState: Outbound quote approval state: `"pending"`, `"accepted"`, `"rejected"`, or `"failed"`.
    ///   - quotesCount: Number of accepted inbound quotes of this status.
    public init(
        id: String, username: String, content: String, contentWarning: String?,
        visibility: String, sensitive: Bool, language: String?,
        published: String, url: String, uri: String,
        to: [String], cc: [String], tags: [Tag]?,
        attachments: [MediaAttachmentRef]?, inReplyTo: String?,
        likesCount: Int = 0, boostsCount: Int = 0, repliesCount: Int = 0,
        quotedStatusUri: String? = nil, quoteApprovalState: String? = nil,
        quotesCount: Int = 0
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
        self.quotedStatusUri = quotedStatusUri
        self.quoteApprovalState = quoteApprovalState
        self.quotesCount = quotesCount
    }

    /// Parse a Status from a DynamoDB attribute map.
    ///
    /// `to` and `cc` are stored as JSON-encoded strings in `toRecipients` and `ccRecipients`
    /// respectively; they are decoded here and default to empty arrays on parse failure. Tags and
    /// attachments are also JSON-encoded strings and are `nil` when absent.
    ///
    /// - Parameter attributes: The raw DynamoDB item from a `GetItem` or `Query` call.
    /// - Returns: A fully-populated `Status`, or `nil` if any required attribute is missing.
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

        var quotedStatusUri: String?
        if case .s(let qs) = attributes["quotedStatusUri"] {
            quotedStatusUri = qs
        }

        var quoteApprovalState: String?
        if case .s(let qa) = attributes["quoteApprovalState"] {
            quoteApprovalState = qa
        }

        var quotesCount = 0
        if case .n(let n) = attributes["quotesCount"], let v = Int(n) { quotesCount = v }

        return Status(
            id: id, username: username, content: content, contentWarning: contentWarning,
            visibility: visibility, sensitive: sensitive, language: language,
            published: published, url: url, uri: uri,
            to: to, cc: cc, tags: tags,
            attachments: attachments, inReplyTo: inReplyTo,
            likesCount: likesCount, boostsCount: boostsCount, repliesCount: repliesCount,
            quotedStatusUri: quotedStatusUri, quoteApprovalState: quoteApprovalState,
            quotesCount: quotesCount
        )
    }

    /// Serialize to a DynamoDB attribute map for a `PutItem` call.
    ///
    /// Sets both the primary key (`PK`/`SK`) and the GSI key (`GSI1PK`/`GSI1SK`) so that
    /// time-ordered queries work out of the box. `to` and `cc` are stored as JSON-encoded
    /// strings (keyed `toRecipients`/`ccRecipients`) because DynamoDB has no native array-of-strings
    /// type that sorts well here. Tags and attachments are similarly JSON-encoded. Optional fields
    /// are omitted when nil.
    ///
    /// - Returns: A DynamoDB attribute map ready to pass to `PutItem`.
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
        if let quotedStatusUri {
            item["quotedStatusUri"] = .s(quotedStatusUri)
        }
        if let quoteApprovalState {
            item["quoteApprovalState"] = .s(quoteApprovalState)
        }
        if quotesCount > 0 {
            item["quotesCount"] = .n(String(quotesCount))
        }

        return item
    }
}

/// A tag entry (Hashtag, Mention, or Emoji) attached to a status.
public struct Tag: Codable, Sendable {
    /// Tag type: `Hashtag`, `Mention`, or `Emoji`.
    public let type: String
    /// Tag name (e.g. `#swift` for hashtags, `@user@domain` for mentions).
    public let name: String
    /// URL for the tag target, if applicable.
    public let href: String?

    /// Create a Tag.
    ///
    /// - Parameters:
    ///   - type: One of `"Hashtag"`, `"Mention"`, or `"Emoji"`.
    ///   - name: The display name of the tag.
    ///   - href: URL pointing to the tag's profile or search page; `nil` for emojis.
    public init(type: String, name: String, href: String?) {
        self.type = type
        self.name = name
        self.href = href
    }
}

/// A media attachment reference on a status.
///
/// Stores the CloudFront URL, MIME type, alt text, and optional blurhash for
/// image/video/audio attachments.
public struct MediaAttachmentRef: Codable, Sendable {
    /// Unique identifier for the media attachment.
    public let id: String
    /// CloudFront URL where the media is served.
    public let url: String
    /// MIME type (e.g. `image/png`, `video/mp4`).
    public let contentType: String
    /// Alt text description for accessibility.
    public let description: String?
    /// Blurhash placeholder string for the media.
    public let blurhash: String?

    /// Create a MediaAttachmentRef.
    ///
    /// - Parameters:
    ///   - id: Unique ID for the attachment, used to correlate with upload records.
    ///   - url: CloudFront URL where the media is served.
    ///   - contentType: MIME type (e.g. `"image/png"`, `"video/mp4"`).
    ///   - description: Alt text for accessibility; `nil` when not provided.
    ///   - blurhash: Blurhash placeholder string; `nil` when not computed.
    public init(id: String, url: String, contentType: String, description: String?, blurhash: String?) {
        self.id = id
        self.url = url
        self.contentType = contentType
        self.description = description
        self.blurhash = blurhash
    }
}
