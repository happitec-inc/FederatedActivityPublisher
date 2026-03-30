import AWSLambdaEvents
import AWSLambdaRuntime
import ActivityPubCore
import Foundation

let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] ?? "activity.happitec.com"
let handleDomain = ProcessInfo.processInfo.environment["HANDLE_DOMAIN"] ?? "happitec.com"

let store = try await DynamoDBStore()

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    guard let username = event.pathParameters["username"] else {
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Missing username path parameter"}"#
        )
    }

    do {
        guard let actor = try await store.getActor(username: username) else {
            return APIGatewayResponse(
                statusCode: .notFound,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Actor not found"}"#
            )
        }

        // Content negotiation: redirect browsers to profile page
        let accept = event.headers["accept"] ?? event.headers["Accept"] ?? ""
        if accept.contains("text/html") && !accept.contains("application/activity+json") && !accept.contains("application/ld+json") {
            return APIGatewayResponse(
                statusCode: .found,
                headers: [
                    "location": "https://\(serverDomain)/@\(username)",
                    "content-type": "text/html",
                    "vary": "Accept",
                ]
            )
        }

        let body = buildActorJSONLD(actor: actor, serverDomain: serverDomain, handleDomain: handleDomain)

        return APIGatewayResponse(
            statusCode: .ok,
            headers: [
                "content-type": "application/activity+json",
                "vary": "Accept",
            ],
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
