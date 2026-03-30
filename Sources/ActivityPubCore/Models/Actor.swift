import Foundation
import AWSDynamoDB

/// A local ActivityPub actor (account) stored in DynamoDB.
///
/// Each actor has an RSA keypair for HTTP Signature signing, profile metadata,
/// and counters for followers/following/statuses. The private key is stored in
/// SSM Parameter Store; only the public key PEM is embedded in the actor record.
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

    public init(
        username: String, displayName: String, summary: String,
        avatarUrl: String? = nil, headerUrl: String? = nil,
        fields: String? = nil,
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
        self.publicKeyPem = publicKeyPem
        self.privateKeyArn = privateKeyArn
        self.createdAt = createdAt
        self.discoverable = discoverable
        self.manuallyApprovesFollowers = manuallyApprovesFollowers
        self.followerCount = followerCount
        self.followingCount = followingCount
        self.statusCount = statusCount
    }

    /// Convert a DynamoDB attribute map to an Actor, returning nil if required fields are missing.
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

        return Actor(
            username: username,
            displayName: displayName,
            summary: summary,
            avatarUrl: avatarUrl,
            headerUrl: headerUrl,
            fields: fields,
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
