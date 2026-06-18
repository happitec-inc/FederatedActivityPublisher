/// Lambda handler for the WebFinger discovery endpoint (`/.well-known/webfinger`).
///
/// WebFinger is the entry point to federation. When a Mastodon user searches for
/// `@user@happitec.com`, their server hits `happitec.com/.well-known/webfinger` first.
/// A CloudFront Function on `happitec.com` proxies that request here. This handler
/// resolves the `acct:` URI to the actor's ActivityPub profile URL on the server domain.
///
/// The handle domain (`happitec.com`) and server domain (`activity.happitec.com`) are
/// intentionally different: users are addressed as `@user@happitec.com` but their
/// ActivityPub actor document lives at `activity.happitec.com/users/{username}`.
///
/// Required environment variables:
/// - `SERVER_DOMAIN`: the ActivityPub server domain (e.g. `activity.happitec.com`)
/// - `HANDLE_DOMAIN`: the user-facing handle domain (e.g. `happitec.com`)
import AWSLambdaEvents
import AWSLambdaRuntime
import ActivityPubCore
import Foundation

guard let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] else {
    fatalError("SERVER_DOMAIN environment variable is required")
}
guard let handleDomain = ProcessInfo.processInfo.environment["HANDLE_DOMAIN"] else {
    fatalError("HANDLE_DOMAIN environment variable is required")
}

/// DynamoDB-backed store used to check whether a given username actually exists
/// before returning a WebFinger response.
let store = try await DynamoDBStore()

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    guard let resource = event.queryStringParameters["resource"] else {
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Missing required query parameter: resource"}"#
        )
    }

    // Validate format: acct:{username}@{handle_domain}
    let prefix = "acct:"
    let suffix = "@\(handleDomain)"
    guard resource.hasPrefix(prefix), resource.hasSuffix(suffix) else {
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Invalid resource format. Expected acct:{username}@\#(handleDomain)"}"#
        )
    }

    let username = String(resource.dropFirst(prefix.count).dropLast(suffix.count))
    guard !username.isEmpty else {
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Username cannot be empty"}"#
        )
    }

    do {
        guard let _ = try await store.getActor(username: username) else {
            return APIGatewayResponse(
                statusCode: .notFound,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Resource not found"}"#
            )
        }

        let response = WebFingerResponse(
            subject: "acct:\(username)@\(handleDomain)",
            links: [
                WebFingerLink(
                    rel: "self",
                    type: "application/activity+json",
                    href: "https://\(serverDomain)/users/\(username)"
                ),
                WebFingerLink(
                    rel: "http://webfinger.net/rel/profile-page",
                    type: "text/html",
                    href: "https://\(serverDomain)/@\(username)"
                ),
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(response)
        let body = String(data: data, encoding: .utf8) ?? "{}"

        return APIGatewayResponse(
            statusCode: .ok,
            headers: ["content-type": "application/jrd+json"],
            body: body
        )
    } catch {
        context.logger.error("DynamoDB error: \(error)")
        return APIGatewayResponse(
            statusCode: .internalServerError,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Internal server error"}"#
        )
    }
}

try await runtime.run()
