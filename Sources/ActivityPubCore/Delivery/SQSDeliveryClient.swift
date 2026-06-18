/// SQS-based outbound activity delivery for federated fan-out.
///
/// When a local actor creates a post, boosts, or follows someone, the handler needs to
/// deliver a signed ActivityPub activity to each follower's inbox. Rather than making
/// those HTTP calls inline (which would time out on Lambda for large follower counts),
/// the handler enqueues ``DeliveryJob`` messages via ``SQSDeliveryClient`` and returns
/// immediately. A separate delivery Lambda reads the queue and makes the signed `POST`
/// to each remote inbox.
///
/// The queue URL is read from the `QUEUE_URL` environment variable at init time. For
/// fan-out with many followers, ``SQSDeliveryClient/enqueueBatch(jobs:)`` chunks into
/// groups of 10 to stay within the SQS `SendMessageBatch` limit.
///
/// `DeliveryJob` is defined in the `Delivery` module and contains the target inbox URL,
/// the signed activity payload, and the key material needed to sign the request.
import AWSSQS
import Foundation

/// Thin wrapper around SQS for enqueueing ``DeliveryJob`` messages.
///
/// Used by PostHandler and InboxHandler to fan out signed HTTP delivery to remote inboxes.
/// Supports both single-message and batch (up to 10 per call) enqueueing.
public struct SQSDeliveryClient: Sendable {
    private let client: SQSClient
    private let queueUrl: String

    /// Create a new delivery client, optionally overriding the queue URL.
    ///
    /// If `queueUrl` is nil, reads from the `QUEUE_URL` environment variable.
    /// Crashes with `fatalError` if no queue URL is available.
    public init(queueUrl: String? = nil) async throws {
        let resolvedQueueUrl = queueUrl ?? ProcessInfo.processInfo.environment["QUEUE_URL"]
        guard let resolvedQueueUrl, !resolvedQueueUrl.isEmpty else {
            fatalError("QUEUE_URL environment variable is not set")
        }
        self.queueUrl = resolvedQueueUrl
        self.client = try await SQSClient()
    }

    /// Enqueue a delivery job to SQS.
    public func enqueue(job: DeliveryJob) async throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(job)
        guard let body = String(data: data, encoding: .utf8) else {
            throw SQSDeliveryError.encodingFailed
        }

        let input = SendMessageInput(
            messageBody: body,
            queueUrl: queueUrl
        )
        _ = try await client.sendMessage(input: input)
    }

    /// Enqueue multiple delivery jobs to SQS using SendMessageBatch.
    /// SQS batch limit is 10 messages, so this method chunks automatically.
    public func enqueueBatch(jobs: [DeliveryJob]) async throws {
        let encoder = JSONEncoder()

        // SQS batch limit is 10 messages
        let chunkSize = 10
        for chunkStart in stride(from: 0, to: jobs.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, jobs.count)
            let chunk = jobs[chunkStart..<chunkEnd]

            var entries: [SQSClientTypes.SendMessageBatchRequestEntry] = []
            for (index, job) in chunk.enumerated() {
                let data = try encoder.encode(job)
                guard let body = String(data: data, encoding: .utf8) else {
                    throw SQSDeliveryError.encodingFailed
                }
                entries.append(SQSClientTypes.SendMessageBatchRequestEntry(
                    id: String(chunkStart + index),
                    messageBody: body
                ))
            }

            let input = SendMessageBatchInput(
                entries: entries,
                queueUrl: queueUrl
            )
            _ = try await client.sendMessageBatch(input: input)
        }
    }
}

/// Errors from the SQS delivery client.
public enum SQSDeliveryError: Error {
    /// The delivery job could not be encoded to JSON.
    case encodingFailed
}
