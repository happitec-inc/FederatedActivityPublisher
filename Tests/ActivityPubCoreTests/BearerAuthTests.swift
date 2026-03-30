import Testing
@testable import ActivityPubCore

@Suite("Bearer auth types")
struct BearerAuthTests {

    @Test("BearerAuthResult stores username")
    func authResultUsername() {
        let result = BearerAuthResult(username: "testuser")
        #expect(result.username == "testuser")
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
