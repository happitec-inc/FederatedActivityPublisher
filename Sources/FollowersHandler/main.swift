/// Lambda handler for `GET /users/{username}/followers`.
///
/// Returns the actor's followers collection as an `OrderedCollection`. This URL is
/// referenced in the actor JSON-LD's `followers` field, and AP clients fetch it to
/// determine whether an account is followable and to discover the follower count.
///
/// The collection is always returned as a root stub (no pagination, no inline items)
/// with `totalItems: 0`. The server tracks follower relationships in DynamoDB and
/// delivers activities to followers via SQS, but the follower list itself is not
/// currently exposed through this endpoint for privacy reasons.
///
/// All responses use `content-type: application/activity+json`. The handler fatally
/// exits at cold-start if `SERVER_DOMAIN` is absent.
import AWSLambdaEvents
import AWSLambdaRuntime
import ActivityPubCore
import Foundation

guard let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] else {
    fatalError("SERVER_DOMAIN environment variable is required")
}

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
        guard try await store.actorExists(username: username) else {
            return APIGatewayResponse(
                statusCode: .notFound,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Actor not found"}"#
            )
        }

        let collection = OrderedCollection.emptyRoot(
            id: "https://\(serverDomain)/users/\(username)/followers"
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
