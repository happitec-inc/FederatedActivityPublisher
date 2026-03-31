import Testing
@testable import ActivityPubCore

@Suite("QuoteRequest Approval Policy")
struct QuoteRequestTests {

    // MARK: - Public policy

    @Test("Public policy accepts any actor for public status")
    func publicPolicyPublicStatus() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "public",
            quoteApprovalPolicy: "public",
            isFollower: false
        ) == true)
    }

    @Test("Public policy accepts any actor for unlisted status")
    func publicPolicyUnlistedStatus() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "unlisted",
            quoteApprovalPolicy: "public",
            isFollower: false
        ) == true)
    }

    @Test("Public policy rejects private status")
    func publicPolicyPrivateStatus() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "private",
            quoteApprovalPolicy: "public",
            isFollower: false
        ) == false)
    }

    @Test("Public policy rejects direct status")
    func publicPolicyDirectStatus() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "direct",
            quoteApprovalPolicy: "public",
            isFollower: false
        ) == false)
    }

    // MARK: - Followers policy

    @Test("Followers policy accepts follower for public status")
    func followersPolicyAcceptsFollower() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "public",
            quoteApprovalPolicy: "followers",
            isFollower: true
        ) == true)
    }

    @Test("Followers policy rejects non-follower for public status")
    func followersPolicyRejectsNonFollower() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "public",
            quoteApprovalPolicy: "followers",
            isFollower: false
        ) == false)
    }

    @Test("Followers policy rejects follower for private status")
    func followersPolicyRejectsPrivateStatus() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "private",
            quoteApprovalPolicy: "followers",
            isFollower: true
        ) == false)
    }

    // MARK: - Nobody policy

    @Test("Nobody policy rejects everyone")
    func nobodyPolicyRejectsAll() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "public",
            quoteApprovalPolicy: "nobody",
            isFollower: true
        ) == false)
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "public",
            quoteApprovalPolicy: "nobody",
            isFollower: false
        ) == false)
    }

    // MARK: - Unknown policy defaults to nobody

    @Test("Unknown policy defaults to reject")
    func unknownPolicyRejects() {
        #expect(shouldAcceptQuoteRequest(
            quotedStatusVisibility: "public",
            quoteApprovalPolicy: "some_future_value",
            isFollower: true
        ) == false)
    }
}
