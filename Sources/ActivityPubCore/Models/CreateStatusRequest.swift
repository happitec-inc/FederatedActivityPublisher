import Foundation

/// API request model for creating a new status (`POST /api/v1/statuses`).
///
/// Follows the Mastodon-compatible API schema. The `status` field contains plain text
/// which is converted to HTML by ``convertTextToHTML(_:)`` before storage.
public struct CreateStatusRequest: Codable, Sendable {
    /// Plain text content of the status. Converted to HTML before federation.
    public let status: String
    /// IDs of previously uploaded media attachments to include.
    public let mediaIds: [String]?
    /// Whether the status contains sensitive content (shows behind a content warning).
    public let sensitive: Bool?
    /// Content warning / spoiler text displayed above the content.
    public let spoilerText: String?
    /// Visibility level. Defaults to `public` if not specified.
    public let visibility: String?
    /// ISO 639-1 language code for the status content.
    public let language: String?
    /// ID of the status being replied to, if this is a reply.
    public let inReplyToId: String?
    /// ID of the status being quoted (Mastodon 4.5+ API).
    public let quotedStatusId: String?

    enum CodingKeys: String, CodingKey {
        case status
        case mediaIds = "media_ids"
        case sensitive
        case spoilerText = "spoiler_text"
        case visibility
        case language
        case inReplyToId = "in_reply_to_id"
        case quotedStatusId = "quoted_status_id"
    }

    public init(
        status: String, mediaIds: [String]? = nil, sensitive: Bool? = nil,
        spoilerText: String? = nil, visibility: String? = nil,
        language: String? = nil, inReplyToId: String? = nil,
        quotedStatusId: String? = nil
    ) {
        self.status = status
        self.mediaIds = mediaIds
        self.sensitive = sensitive
        self.spoilerText = spoilerText
        self.visibility = visibility
        self.language = language
        self.inReplyToId = inReplyToId
        self.quotedStatusId = quotedStatusId
    }
}
