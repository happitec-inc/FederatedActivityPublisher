import AWSLambdaEvents
import AWSLambdaRuntime
import ActivityPubCore
import Foundation

let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] ?? "happitec.com"

let store = try await DynamoDBStore()

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    guard let username = event.pathParameters["username"],
          let statusId = event.pathParameters["id"] else {
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Missing path parameters"}"#
        )
    }

    do {
        guard let status = try await store.getStatus(username: username, id: statusId) else {
            return APIGatewayResponse(
                statusCode: .notFound,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Status not found"}"#
            )
        }

        // Content negotiation: redirect browsers to post page
        let accept = event.headers["accept"] ?? event.headers["Accept"] ?? ""
        if accept.contains("text/html") && !accept.contains("application/activity+json") && !accept.contains("application/ld+json") {
            // Private/direct posts return 404 for HTML requests
            if status.visibility == "private" || status.visibility == "direct" {
                return APIGatewayResponse(
                    statusCode: .notFound,
                    headers: [
                        "content-type": "application/json",
                        "vary": "Accept",
                    ],
                    body: #"{"error":"Status not found"}"#
                )
            }

            return APIGatewayResponse(
                statusCode: .found,
                headers: [
                    "location": "https://\(serverDomain)/@\(username)/\(statusId)",
                    "content-type": "text/html",
                    "vary": "Accept",
                ]
            )
        }

        let noteJSON = buildNoteJSON(status: status, serverDomain: serverDomain, username: username)

        return APIGatewayResponse(
            statusCode: .ok,
            headers: [
                "content-type": "application/activity+json",
                "cache-control": "public, max-age=31536000",
                "vary": "Accept",
            ],
            body: noteJSON
        )
    } catch {
        context.logger.error("ObjectHandler error: \(error)")
        return APIGatewayResponse(
            statusCode: .internalServerError,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Internal server error"}"#
        )
    }
}

try await runtime.run()
