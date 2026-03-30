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

        let noteJSON = buildNoteJSON(status: status, serverDomain: serverDomain, username: username)

        return APIGatewayResponse(
            statusCode: .ok,
            headers: [
                "content-type": "application/activity+json",
                "cache-control": "public, max-age=31536000",
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
