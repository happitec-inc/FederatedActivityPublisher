/// Lambda handler for outbound ActivityPub delivery, triggered by SQS.
///
/// DeliverHandler is the second half of the federation pipeline. When any other handler
/// needs to send an activity to a remote server (Accept a Follow, fan-out a new post,
/// send an Update after quote approval, etc.), it enqueues a `DeliveryJob` onto SQS via
/// `SQSDeliveryClient`. This Lambda processes those jobs.
///
/// For each SQS record the handler:
/// 1. Decodes the `DeliveryJob` (target inbox URL, activity JSON, actor username).
/// 2. Reads the actor's RSA private key from SSM Parameter Store (encrypted, per-actor).
/// 3. Signs the outbound HTTP POST with an HTTP Signature using that private key.
/// 4. Posts the activity JSON to the remote inbox.
/// 5. On a 5xx response, throws so SQS retries; on a 4xx, logs and moves on (not retryable).
///
/// The SQS queue has a dead-letter queue for jobs that exhaust retries.
///
/// Key dependencies: `AWSSSM` (private key storage), `ActivityPubCore.HTTPSignature`
/// (outbound signing), `ActivityPubCore.DeliveryJob` (job schema).
import AWSLambdaEvents
import AWSLambdaRuntime
import AWSSSM
import ActivityPubCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

guard let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] else {
    fatalError("SERVER_DOMAIN environment variable is required")
}
let ssmKeyPrefixRaw = ProcessInfo.processInfo.environment["SSM_KEY_PREFIX"] ?? "/activity/stage/keys/"
/// SSM path prefix for actor private keys, with any trailing slash stripped.
let ssmKeyPrefix = ssmKeyPrefixRaw.hasSuffix("/") ? String(ssmKeyPrefixRaw.dropLast()) : ssmKeyPrefixRaw

let ssmClient = try await SSMClient()

let runtime = LambdaRuntime {
    (event: SQSEvent, context: LambdaContext) in

    for record in event.records {
        let body = record.body

        do {
            // Parse delivery job
            let jobData = Data(body.utf8)
            let job = try JSONDecoder().decode(DeliveryJob.self, from: jobData)

            context.logger.info("Delivering to \(job.targetInbox) for actor \(job.actorUsername)")

            // Read the actor's private key from SSM
            let parameterName = "\(ssmKeyPrefix)/\(job.actorUsername)"
            let ssmInput = GetParameterInput(
                name: parameterName,
                withDecryption: true
            )
            let ssmOutput = try await ssmClient.getParameter(input: ssmInput)
            guard let privateKeyPem = ssmOutput.parameter?.value else {
                context.logger.error("SSM parameter \(parameterName) has no value")
                continue
            }

            // Parse the target URL
            guard let targetUrl = URL(string: job.targetInbox) else {
                context.logger.error("Invalid target inbox URL: \(job.targetInbox)")
                continue
            }

            guard let host = targetUrl.host else {
                context.logger.error("No host in target inbox URL: \(job.targetInbox)")
                continue
            }

            let path = targetUrl.path.isEmpty ? "/" : targetUrl.path
            let bodyData = Data(job.activityJSON.utf8)

            // Sign the outbound request
            let keyId = "https://\(serverDomain)/users/\(job.actorUsername)#main-key"
            let signedHeaders = try HTTPSignature.sign(
                privateKeyPem: privateKeyPem,
                keyId: keyId,
                method: "POST",
                path: path,
                host: host,
                body: bodyData
            )

            // Build and send the HTTP request
            var request = URLRequest(url: targetUrl)
            request.httpMethod = "POST"
            request.httpBody = bodyData
            request.timeoutInterval = 30

            for (key, value) in signedHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            context.logger.info("Delivery to \(job.targetInbox) returned HTTP \(statusCode)")

            if statusCode >= 500 {
                // Server error — throw to let SQS retry
                throw DeliverError.serverError(statusCode, job.targetInbox)
            } else if statusCode >= 400 {
                // Client error — not retryable, log and move on
                context.logger.warning("Non-retryable \(statusCode) from \(job.targetInbox)")
            }

        } catch let error as DeliverError {
            // Re-throw server errors to let SQS retry
            throw error
        } catch let error as DecodingError {
            context.logger.error("Failed to decode delivery job: \(error)")
            // Bad message — don't retry
        } catch {
            context.logger.error("Delivery failed: \(error)")
            // Network or other transient error — throw to let SQS retry
            throw error
        }
    }
}

/// Errors thrown by the delivery handler.
enum DeliverError: Error {
    /// The remote server returned a 5xx status code. SQS will retry the job.
    case serverError(Int, String)
}

try await runtime.run()
