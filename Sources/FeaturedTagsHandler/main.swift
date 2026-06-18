/// Lambda handler for `GET /users/{username}/collections/tags`.
///
/// Returns the actor's featured hashtags collection. Mastodon fetches this URL (from
/// the actor JSON-LD's `featuredTags` field) to show which hashtags an account has
/// pinned to their profile sidebar.
///
/// This server doesn't implement featured hashtags yet, so the response is always an
/// empty `OrderedCollection` with `totalItems: 0` and an empty `orderedItems` array.
/// Returning an empty collection instead of 404 keeps Mastodon's discovery flow clean.
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

        let collection = OrderedCollection.emptyWithItems(
            id: "https://\(serverDomain)/users/\(username)/collections/tags"
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
