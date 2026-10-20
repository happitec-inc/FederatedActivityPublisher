import Testing
import Foundation
import AWSDynamoDB
@testable import ActivityPubCore

/// In-memory stand-in for the `ACTIVITY_DEDUP` records, with the same claim / complete /
/// release transitions as `DynamoDBStore` (lease expiry is not modelled).
private final class FakeActivityLedger {
    enum State { case pending, processed }
    var records: [String: State] = [:]

    func claim(_ id: String) -> ActivityClaim {
        switch records[id] {
        case nil:
            records[id] = .pending
            return .claimed
        case .pending:
            return .inProgress
        case .processed:
            return .alreadyProcessed
        }
    }

    func complete(_ id: String) { records[id] = .processed }

    func release(_ id: String) {
        if records[id] == .pending { records[id] = nil }
    }
}

private struct HandlerFailure: Error {}

/// Deliver one activity through `processActivityOnce`, with a handler that adds the
/// activity's follower to `followers` unless `failWith` says otherwise.
private func deliver(
    _ id: String,
    ledger: FakeActivityLedger,
    followers: inout Set<String>,
    handlerRuns: inout Int,
    failWith failure: Int? = nil,
    throwing: Bool = false
) async throws -> ActivityDelivery<Int> {
    var added: String?
    let delivery = try await processActivityOnce(
        claim: { ledger.claim(id) },
        complete: { ledger.complete(id) },
        release: { ledger.release(id) },
        succeeded: { (200..<300).contains($0) },
        handle: { () async throws -> Int in
            handlerRuns += 1
            if throwing { throw HandlerFailure() }
            if let failure { return failure }
            added = "https://remote.example/users/alice"
            return 202
        }
    )
    if let added { followers.insert(added) }
    return delivery
}

@Test func failedHandlerRunsAgainOnRedelivery() async throws {
    let ledger = FakeActivityLedger()
    var followers: Set<String> = []
    var runs = 0

    await #expect(throws: HandlerFailure.self) {
        _ = try await deliver("follow-1", ledger: ledger, followers: &followers, handlerRuns: &runs, throwing: true)
    }
    #expect(followers.isEmpty)

    // The sender retries the same activity: it must be processed, not reported as a duplicate
    let retry = try await deliver("follow-1", ledger: ledger, followers: &followers, handlerRuns: &runs)
    guard case .handled(202) = retry else {
        Issue.record("Redelivery was not handled: \(retry)")
        return
    }
    #expect(runs == 2)
    #expect(followers == ["https://remote.example/users/alice"])
    #expect(ledger.records["follow-1"] == .processed)
}

@Test func failureResponseRunsAgainOnRedelivery() async throws {
    let ledger = FakeActivityLedger()
    var followers: Set<String> = []
    var runs = 0

    let first = try await deliver("follow-1", ledger: ledger, followers: &followers, handlerRuns: &runs, failWith: 500)
    guard case .handled(500) = first else {
        Issue.record("First delivery: \(first)")
        return
    }
    #expect(ledger.records["follow-1"] == nil)

    let retry = try await deliver("follow-1", ledger: ledger, followers: &followers, handlerRuns: &runs)
    guard case .handled(202) = retry else {
        Issue.record("Redelivery was not handled: \(retry)")
        return
    }
    #expect(followers == ["https://remote.example/users/alice"])
}

@Test func processedActivityIsNotHandledAgain() async throws {
    let ledger = FakeActivityLedger()
    var followers: Set<String> = []
    var runs = 0

    _ = try await deliver("like-1", ledger: ledger, followers: &followers, handlerRuns: &runs)
    let duplicate = try await deliver("like-1", ledger: ledger, followers: &followers, handlerRuns: &runs)
    guard case .alreadyProcessed = duplicate else {
        Issue.record("Duplicate was handled: \(duplicate)")
        return
    }
    #expect(runs == 1)
}

@Test func deliveryDuringProcessingIsNotHandled() async throws {
    let ledger = FakeActivityLedger()
    ledger.records["like-1"] = .pending // another delivery holds the claim
    var followers: Set<String> = []
    var runs = 0

    let concurrent = try await deliver("like-1", ledger: ledger, followers: &followers, handlerRuns: &runs)
    guard case .inProgress = concurrent else {
        Issue.record("Concurrent duplicate was handled: \(concurrent)")
        return
    }
    #expect(runs == 0)
    #expect(ledger.records["like-1"] == .pending)
}

@Test func claimTakesOnlyAbsentOrExpiredRecords() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let input = DynamoDBStore.claimReceivedActivityInput(
        tableName: "t",
        activityId: "https://remote.example/follows/1",
        type: "Follow",
        actorUri: "https://remote.example/users/alice",
        now: now
    )
    #expect(input.conditionExpression
        == "attribute_not_exists(SK) OR (processingState = :pending AND claimExpiresAt < :now)")
    #expect(input.expressionAttributeValues?[":now"] == .n("1800000000"))
    #expect(input.item?["processingState"] == .s("pending"))
    #expect(input.item?["claimExpiresAt"] == .n("1800000300"))
    // The existing record comes back on a refused claim, to tell pending from processed
    #expect(input.returnValuesOnConditionCheckFailure == .allOld)
}

@Test func completeAndReleaseTargetTheDedupRecord() throws {
    let complete = DynamoDBStore.completeReceivedActivityInput(tableName: "t", activityId: "a1")
    #expect(complete.updateExpression == "SET processingState = :processed REMOVE claimExpiresAt")
    #expect(complete.key?["PK"] == .s("ACTIVITY_DEDUP"))
    #expect(complete.key?["SK"] == .s("a1"))

    let release = DynamoDBStore.releaseReceivedActivityInput(tableName: "t", activityId: "a1")
    // Never drop a record that has been marked processed
    #expect(release.conditionExpression == "processingState = :pending")
    #expect(release.key?["SK"] == .s("a1"))
}
