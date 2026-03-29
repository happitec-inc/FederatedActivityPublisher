import AWSSQS
import Foundation

/// Thin wrapper around SQS for enqueueing delivery jobs.
public struct SQSDeliveryClient: Sendable {
    private let client: SQSClient
    private let queueUrl: String

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
}

public enum SQSDeliveryError: Error {
    case encodingFailed
}
