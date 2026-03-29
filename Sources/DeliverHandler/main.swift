import AWSLambdaEvents
import AWSLambdaRuntime
import AWSSSM
import ActivityPubCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] ?? "activity.happitec.com"
let ssmKeyPrefixRaw = ProcessInfo.processInfo.environment["SSM_KEY_PREFIX"] ?? "/activity/stage/keys/"
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

enum DeliverError: Error {
    case serverError(Int, String)
}

try await runtime.run()
