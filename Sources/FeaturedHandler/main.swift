/// Lambda handler for `GET /users/{username}/collections/featured`.
///
/// Returns the actor's featured posts collection, which Mastodon uses to populate
/// the pinned-posts section of a profile. This server doesn't yet support pinned
/// posts, so the response is always an empty `OrderedCollection` with `totalItems: 0`
/// and an empty `orderedItems` array.
///
/// Mastodon fetches this URL when it discovers an actor and looks for featured
/// (pinned) posts in the actor JSON-LD's `featured` field. Returning an empty
/// collection rather than 404 prevents discovery errors on some clients.
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
