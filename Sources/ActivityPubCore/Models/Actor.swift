import Foundation
import AWSDynamoDB

public struct Actor: Codable, Sendable {
    public let username: String
    public let displayName: String
    public let summary: String
    public let avatarUrl: String?
    public let headerUrl: String?
    public let publicKeyPem: String
    public let privateKeyArn: String
    public let createdAt: String
    public let discoverable: Bool
    public let manuallyApprovesFollowers: Bool
    public let followerCount: Int
    public let followingCount: Int
    public let statusCount: Int

    public init(
        username: String, displayName: String, summary: String,
        avatarUrl: String? = nil, headerUrl: String? = nil,
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

        return Actor(
            username: username,
            displayName: displayName,
            summary: summary,
            avatarUrl: avatarUrl,
            headerUrl: headerUrl,
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
