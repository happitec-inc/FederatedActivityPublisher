import AWSDynamoDB
import Crypto
import Foundation
import Testing
@testable import ActivityPubCore

@Suite("Bearer auth types")
struct BearerAuthTests {

    @Test("BearerAuthResult stores username")
    func authResultUsername() {
        let result = BearerAuthResult(username: "testuser")
        #expect(result.username == "testuser")
        #expect(result.scope == nil)
    }

    @Test("BearerAuthResult stores username and scope")
    func authResultWithScope() {
        let result = BearerAuthResult(username: "testuser", scope: "read write")
        #expect(result.username == "testuser")
        #expect(result.scope == "read write")
    }

    @Test("BearerAuthError cases are distinct")
    func errorCases() {
        let missing = BearerAuthError.missingHeader
        let invalid = BearerAuthError.invalidToken
        let config = BearerAuthError.serverConfigError("test message")

        // Verify all cases match correctly
        switch missing {
        case .missingHeader: break
        default: #expect(Bool(false), "Expected missingHeader")
        }
        switch invalid {
        case .invalidToken: break
        default: #expect(Bool(false), "Expected invalidToken")
        }
        switch config {
        case .serverConfigError(let msg):
            #expect(msg == "test message")
        default: #expect(Bool(false), "Expected serverConfigError")
        }
    }

    @Test("BearerAuthError conforms to Error")
    func errorConformance() {
        let error: any Error = BearerAuthError.missingHeader
        #expect(error is BearerAuthError)
    }
}

@Suite("Token hashing")
struct TokenHashingTests {

    @Test("SHA-256 hash produces consistent 64-char hex string")
    func hashTokenConsistent() {
        let token = "my-secret-token-abc123"
        let hash1 = DynamoDBStore.hashToken(token)
        let hash2 = DynamoDBStore.hashToken(token)
        #expect(hash1 == hash2)
        #expect(hash1.count == 64)
        // All characters should be lowercase hex
        #expect(hash1.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test("Different tokens produce different hashes")
    func hashTokenUnique() {
        let hash1 = DynamoDBStore.hashToken("token-a")
        let hash2 = DynamoDBStore.hashToken("token-b")
        #expect(hash1 != hash2)
    }

    @Test("Empty token produces valid hash")
    func hashEmptyToken() {
        let hash = DynamoDBStore.hashToken("")
        #expect(hash.count == 64)
        // SHA-256 of empty string is well-known
        #expect(hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("Hash matches shasum -a 256 output for known input")
    func hashMatchesShasum() {
        // echo -n "test-bearer-token" | shasum -a 256
        // Known output: the SHA-256 of "test-bearer-token"
        let token = "test-bearer-token"
        let digest = SHA256.hash(data: Data(token.utf8))
        let expected = digest.map { String(format: "%02x", $0) }.joined()
        let actual = DynamoDBStore.hashToken(token)
        #expect(actual == expected)
    }
}

@Suite("BearerTokenRecord parsing")
struct BearerTokenRecordTests {
    @Test("Parse valid DynamoDB item")
    func parseValid() {
        let item: [String: AWSDynamoDB.DynamoDBClientTypes.AttributeValue] = [
            "PK": .s("TOKEN#abc123"),
            "SK": .s("META"),
            "username": .s("logos"),
            "scope": .s("read write"),
            "ttl": .n("1999999999"),
            "createdAt": .s("2026-04-09T00:00:00Z"),
            "description": .s("provisioned via workflow"),
        ]
        let record = BearerTokenRecord.fromDynamoDB(item)
        #expect(record != nil)
        #expect(record?.username == "logos")
        #expect(record?.scope == "read write")
        #expect(record?.ttl == 1_999_999_999)
        #expect(record?.createdAt == "2026-04-09T00:00:00Z")
        #expect(record?.description == "provisioned via workflow")
    }

    @Test("Parse item without optional fields")
    func parseMinimal() {
        let item: [String: AWSDynamoDB.DynamoDBClientTypes.AttributeValue] = [
            "username": .s("testuser"),
            "scope": .s("read"),
            "ttl": .n("1999999999"),
        ]
        let record = BearerTokenRecord.fromDynamoDB(item)
        #expect(record != nil)
        #expect(record?.username == "testuser")
        #expect(record?.scope == "read")
        #expect(record?.createdAt == nil)
        #expect(record?.description == nil)
    }

    @Test("Returns nil for missing required fields")
    func parseMissingUsername() {
        let item: [String: AWSDynamoDB.DynamoDBClientTypes.AttributeValue] = [
            "scope": .s("read write"),
            "ttl": .n("1999999999"),
        ]
        #expect(BearerTokenRecord.fromDynamoDB(item) == nil)
    }

    @Test("Returns nil for missing scope")
    func parseMissingScope() {
        let item: [String: AWSDynamoDB.DynamoDBClientTypes.AttributeValue] = [
            "username": .s("testuser"),
            "ttl": .n("1999999999"),
        ]
        #expect(BearerTokenRecord.fromDynamoDB(item) == nil)
    }

    @Test("Returns nil for missing ttl")
    func parseMissingTtl() {
        let item: [String: AWSDynamoDB.DynamoDBClientTypes.AttributeValue] = [
            "username": .s("testuser"),
            "scope": .s("read write"),
        ]
        #expect(BearerTokenRecord.fromDynamoDB(item) == nil)
    }

    @Test("Returns nil for invalid ttl")
    func parseInvalidTtl() {
        let item: [String: AWSDynamoDB.DynamoDBClientTypes.AttributeValue] = [
            "username": .s("testuser"),
            "scope": .s("read write"),
            "ttl": .n("not-a-number"),
        ]
        #expect(BearerTokenRecord.fromDynamoDB(item) == nil)
    }

    @Test("Returns nil for empty map")
    func parseEmpty() {
        let item: [String: AWSDynamoDB.DynamoDBClientTypes.AttributeValue] = [:]
        #expect(BearerTokenRecord.fromDynamoDB(item) == nil)
    }
}
