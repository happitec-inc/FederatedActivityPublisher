import Foundation

/// API request model for creating a new status (POST /api/v1/statuses).
/// Matches the Mastodon-compatible OpenAPI schema.
public struct CreateStatusRequest: Codable, Sendable {
    public let status: String       // plain text
    public let mediaIds: [String]?
    public let sensitive: Bool?
    public let spoilerText: String?
    public let visibility: String?  // default: "public"
    public let language: String?
    public let inReplyToId: String?

    enum CodingKeys: String, CodingKey {
        case status
        case mediaIds = "media_ids"
        case sensitive
        case spoilerText = "spoiler_text"
        case visibility
        case language
        case inReplyToId = "in_reply_to_id"
    }

    public init(
        status: String, mediaIds: [String]? = nil, sensitive: Bool? = nil,
        spoilerText: String? = nil, visibility: String? = nil,
        language: String? = nil, inReplyToId: String? = nil
    ) {
        self.status = status
        self.mediaIds = mediaIds
        self.sensitive = sensitive
        self.spoilerText = spoilerText
        self.visibility = visibility
        self.language = language
        self.inReplyToId = inReplyToId
    }
}
