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
        guard let actor = try await store.getActor(username: username) else {
            return APIGatewayResponse(
                statusCode: .notFound,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Actor not found"}"#
            )
        }

        let outboxUrl = "https://\(serverDomain)/users/\(username)/outbox"
        let pageParam = event.queryStringParameters["page"]

        // Root collection (no page param or page != "true")
        if pageParam != "true" {
            let json = """
            {"@context":"https://www.w3.org/ns/activitystreams","id":"\(outboxUrl)","type":"OrderedCollection","totalItems":\(actor.statusCount),"first":"\(outboxUrl)?page=true","last":"\(outboxUrl)?page=true&min_id=0"}
            """

            return APIGatewayResponse(
                statusCode: .ok,
                headers: ["content-type": "application/activity+json"],
                body: json
            )
        }

        // Paged collection
        let maxId = event.queryStringParameters["max_id"]
        let minId = event.queryStringParameters["min_id"]

        let (statuses, hasMore) = try await store.listStatuses(
            username: username,
            limit: 20,
            maxId: maxId
        )

        // Build orderedItems — each status wrapped in a Create activity
        var orderedItems: [String] = []
        for status in statuses {
            let noteJSON = buildNoteJSON(status: status, serverDomain: serverDomain, username: username)
            let createJSON = buildCreateActivityJSON(
                status: status, noteJSON: noteJSON,
                serverDomain: serverDomain, username: username
            )
            orderedItems.append(createJSON)
        }

        let itemsJSON = orderedItems.joined(separator: ",")

        // Build page URL
        var pageUrl = "\(outboxUrl)?page=true"
        if let maxId {
            pageUrl += "&max_id=\(maxId)"
        }
        if let minId {
            pageUrl += "&min_id=\(minId)"
        }

        // Build next link if there are more results
        var nextJSON = ""
        if hasMore, let lastStatus = statuses.last {
            nextJSON = ",\"next\":\"\(outboxUrl)?page=true&max_id=\(lastStatus.id)\""
        }

        // Build prev link using the first status ID
        var prevJSON = ""
        if let firstStatus = statuses.first {
            prevJSON = ",\"prev\":\"\(outboxUrl)?page=true&min_id=\(firstStatus.id)\""
        }

        let json = """
        {"@context":"https://www.w3.org/ns/activitystreams","id":"\(pageUrl)","type":"OrderedCollectionPage","partOf":"\(outboxUrl)"\(nextJSON)\(prevJSON),"orderedItems":[\(itemsJSON)]}
        """

        return APIGatewayResponse(
            statusCode: .ok,
            headers: ["content-type": "application/activity+json"],
            body: json
        )

    } catch {
        context.logger.error("OutboxHandler error: \(error)")
        return APIGatewayResponse(
            statusCode: .internalServerError,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Internal server error"}"#
        )
    }
}

try await runtime.run()
