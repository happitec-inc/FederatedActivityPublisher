import AWSLambdaEvents
import AWSLambdaRuntime
import ActivityPubCore
import Foundation

let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] ?? "activity.happitec.com"

let store = try await DynamoDBStore()

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    guard let username = event.pathParameters?["username"] else {
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Missing username path parameter"}"#
        )
    }

    do {
        guard try await store.actorExists(username: username) else {
            return APIGatewayResponse(
                statusCode: .notFound,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Actor not found"}"#
            )
        }

        let collection = OrderedCollection.emptyWithItems(
            id: "https://\(serverDomain)/users/\(username)/collections/featured"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(collection)
        let body = String(data: data, encoding: .utf8) ?? "{}"

        return APIGatewayResponse(
            statusCode: .ok,
            headers: ["content-type": "application/activity+json"],
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
