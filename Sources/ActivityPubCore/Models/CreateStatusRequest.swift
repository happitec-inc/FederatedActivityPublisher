/// The JSON body sent to `POST /api/v1/statuses` to create a new post.
///
/// This type is decoded by the `PostHandler` Lambda. After validation, `PostHandler` converts
/// the plain-text `status` field to HTML, computes ActivityPub addressing from `visibility`,
/// assigns a ULID, and writes a ``Status`` record to DynamoDB. It then enqueues ``DeliveryJob``
/// items to SQS for each follower inbox.
import Foundation

/// API request model for `POST /api/v1/statuses`.
///
/// Follows the Mastodon-compatible API schema. The plain-text `status` field is converted
/// to HTML by `PostHandler` before the content is stored or federated.
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

    /// Create a status request.
    ///
    /// - Parameters:
    ///   - status: Plain-text content. Converted to HTML before storage and federation.
    ///   - mediaIds: IDs of previously uploaded media attachments.
    ///   - sensitive: When `true`, content is hidden behind a content warning disclosure.
    ///   - spoilerText: Text shown in place of hidden content when `sensitive` is `true`.
    ///   - visibility: One of `"public"`, `"unlisted"`, `"private"`, or `"direct"`. Defaults to `"public"` if omitted.
    ///   - language: ISO 639-1 language code for the content.
    ///   - inReplyToId: ID of the status being replied to.
    ///   - quotedStatusId: ID of the status being quoted (Mastodon 4.5+).
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
