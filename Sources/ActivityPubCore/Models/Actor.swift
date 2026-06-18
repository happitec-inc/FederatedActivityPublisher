/// A local ActivityPub actor (account) stored in DynamoDB and serialized to ActivityPub JSON-LD.
///
/// Each actor corresponds to a Mastodon-compatible account on this server. Actor records live in the
/// single-table DynamoDB design under `PK=ACTOR#{username}`, `SK=PROFILE`. The `ActorHandler` reads
/// this record to produce the AP `Person` object served at `/users/{username}`, and the profile-edit
/// handlers write back updated fields. The RSA private key used for HTTP Signature signing is kept
/// separately in SSM Parameter Store; only the public key is stored here.
import Foundation
import AWSDynamoDB

/// A local ActivityPub actor (account) stored in DynamoDB.
///
/// Holds profile metadata, follower/following/status counters, and the public half of the
/// RSA keypair. The private key lives in SSM Parameter Store under ``privateKeyArn``.
public struct Actor: Codable, Sendable {
    /// The unique username (e.g. `randomforms`). Used in URIs like `/users/randomforms`.
    public let username: String
    /// Human-readable display name shown on the profile.
    public let displayName: String
    /// HTML biography/description for the actor profile.
    public let summary: String
    /// CloudFront URL for the avatar image, if set.
    public let avatarUrl: String?
    /// CloudFront URL for the header/banner image, if set.
    public let headerUrl: String?
    /// JSON-encoded array of ``ProfileField`` key-value pairs.
    public let fields: String?
    /// PEM-encoded RSA public key for HTTP Signature verification.
    public let publicKeyPem: String
    /// SSM Parameter Store path for the RSA private key.
    public let privateKeyArn: String
    /// ISO 8601 timestamp of when the actor was created.
    public let createdAt: String
    /// Raw user-typed bio text (Markdown/plain). Internal only — never serialized into
    /// public ActivityPub JSON-LD or federated Update activities.
    public let sourceNote: String?
    /// Whether the actor appears in server directory listings.
    public let discoverable: Bool
    /// Whether follow requests require manual approval.
    public let manuallyApprovesFollowers: Bool
    /// Current number of followers.
    public let followerCount: Int
    /// Current number of accounts being followed.
    public let followingCount: Int
    /// Total number of statuses posted.
    public let statusCount: Int

    /// Create an Actor with the given profile data and key references.
    ///
    /// - Parameters:
    ///   - username: Unique username used in all URI paths (e.g. `randomforms`).
    ///   - displayName: Human-readable display name for the profile.
    ///   - summary: HTML biography shown on the actor profile.
    ///   - avatarUrl: CloudFront URL for the avatar image.
    ///   - headerUrl: CloudFront URL for the header/banner image.
    ///   - fields: JSON-encoded array of ``ProfileField`` key-value pairs.
    ///   - sourceNote: Raw (non-HTML) bio text for editing; not federated.
    ///   - publicKeyPem: PEM-encoded RSA public key.
    ///   - privateKeyArn: SSM Parameter Store path for the corresponding private key.
    ///   - createdAt: ISO 8601 creation timestamp.
    ///   - discoverable: Whether the actor appears in directory listings. Defaults to `true`.
    ///   - manuallyApprovesFollowers: Whether follow requests require approval. Defaults to `false`.
    ///   - followerCount: Number of current followers. Defaults to `0`.
    ///   - followingCount: Number of accounts being followed. Defaults to `0`.
    ///   - statusCount: Total statuses posted. Defaults to `0`.
    public init(
        username: String, displayName: String, summary: String,
        avatarUrl: String? = nil, headerUrl: String? = nil,
        fields: String? = nil, sourceNote: String? = nil,
        publicKeyPem: String, privateKeyArn: String,
        createdAt: String, discoverable: Bool = true,
        manuallyApprovesFollowers: Bool = false,
        followerCount: Int = 0, followingCount: Int = 0, statusCount: Int = 0
    ) {
        self.username = username
        self.displayName = displayName
        self.summary = summary
        self.avatarUrl = avatarUrl
        self.headerUrl = headerUrl
        self.fields = fields
        self.sourceNote = sourceNote
        self.publicKeyPem = publicKeyPem
        self.privateKeyArn = privateKeyArn
        self.createdAt = createdAt
        self.discoverable = discoverable
        self.manuallyApprovesFollowers = manuallyApprovesFollowers
        self.followerCount = followerCount
        self.followingCount = followingCount
        self.statusCount = statusCount
    }

    /// Parse an Actor from a DynamoDB attribute map.
    ///
    /// Returns `nil` when any required field is absent or has the wrong type. Optional fields
    /// (`avatarUrl`, `headerUrl`, `fields`, `sourceNote`) are decoded when present and silently
    /// omitted otherwise.
    ///
    /// - Parameter attributes: The raw DynamoDB item returned from a `GetItem` or `Query` call.
    /// - Returns: A fully-populated `Actor`, or `nil` if the item is missing required attributes.
    public static func fromDynamoDB(_ attributes: [String: DynamoDBClientTypes.AttributeValue]) -> Actor? {
        guard
            case .s(let username) = attributes["username"],
            case .s(let displayName) = attributes["displayName"],
            case .s(let summary) = attributes["summary"],
            case .s(let publicKeyPem) = attributes["publicKeyPem"],
            case .s(let privateKeyArn) = attributes["privateKeyArn"],
            case .s(let createdAt) = attributes["createdAt"],
            case .bool(let discoverable) = attributes["discoverable"],
            case .bool(let manuallyApprovesFollowers) = attributes["manuallyApprovesFollowers"],
            case .n(let followerCountStr) = attributes["followerCount"],
            case .n(let followingCountStr) = attributes["followingCount"],
            case .n(let statusCountStr) = attributes["statusCount"],
            let followerCount = Int(followerCountStr),
            let followingCount = Int(followingCountStr),
            let statusCount = Int(statusCountStr)
        else {
            return nil
        }

        var avatarUrl: String?
        if case .s(let url) = attributes["avatarUrl"] {
            avatarUrl = url
        }

        var headerUrl: String?
        if case .s(let url) = attributes["headerUrl"] {
            headerUrl = url
        }

        var fields: String?
        if case .s(let f) = attributes["fields"] {
            fields = f
        }

        var sourceNote: String?
        if case .s(let note) = attributes["sourceNote"] {
            sourceNote = note
        }

        return Actor(
            username: username,
            displayName: displayName,
            summary: summary,
            avatarUrl: avatarUrl,
            headerUrl: headerUrl,
            fields: fields,
            sourceNote: sourceNote,
            publicKeyPem: publicKeyPem,
            privateKeyArn: privateKeyArn,
            createdAt: createdAt,
            discoverable: discoverable,
            manuallyApprovesFollowers: manuallyApprovesFollowers,
            followerCount: followerCount,
            followingCount: followingCount,
            statusCount: statusCount
        )
    }
}
