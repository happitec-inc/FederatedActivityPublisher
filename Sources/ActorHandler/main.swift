import AWSLambdaEvents
import AWSLambdaRuntime
import ActivityPubCore
import Foundation

let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] ?? "activity.happitec.com"
let handleDomain = ProcessInfo.processInfo.environment["HANDLE_DOMAIN"] ?? "happitec.com"

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
                ]
            )
        }

        let actorUrl = "https://\(serverDomain)/users/\(username)"
        let body = buildActorJSON(actor: actor, actorUrl: actorUrl)

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

func buildActorJSON(actor: Actor, actorUrl: String) -> String {
    // Build the icon block if avatarUrl is present
    var iconBlock = ""
    if let avatarUrl = actor.avatarUrl {
        iconBlock = """
        ,"icon":{"type":"Image","url":"\(avatarUrl)"}
        """
    }

    // Build the full Actor JSON-LD matching PROJECT-PLAN.md lines 349-394 exactly
    let json = """
    {
      "@context": [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1",
        {
          "toot": "http://joinmastodon.org/ns#",
          "discoverable": "toot:discoverable",
          "indexable": "toot:indexable",
          "featured": {"@id": "toot:featured", "@type": "@id"},
          "featuredTags": {"@id": "toot:featuredTags", "@type": "@id"},
          "attributionDomains": {"@id": "toot:attributionDomains", "@type": "@id"},
          "schema": "http://schema.org#",
          "PropertyValue": "schema:PropertyValue",
          "value": "schema:value",
          "manuallyApprovesFollowers": "as:manuallyApprovesFollowers",
          "sensitive": "as:sensitive"
        }
      ],
      "id": "\(actorUrl)",
      "type": "Service",
      "preferredUsername": "\(actor.username)",
      "name": "\(actor.displayName)",
      "summary": "\(actor.summary)",
      "inbox": "\(actorUrl)/inbox",
      "outbox": "\(actorUrl)/outbox",
      "followers": "\(actorUrl)/followers",
      "following": "\(actorUrl)/following",
      "url": "https://\(serverDomain)/@\(actor.username)"\(iconBlock),
      "publicKey": {
        "id": "\(actorUrl)#main-key",
        "owner": "\(actorUrl)",
        "publicKeyPem": \(escapeJSONString(actor.publicKeyPem))
      },
      "discoverable": \(actor.discoverable),
      "indexable": false,
      "manuallyApprovesFollowers": \(actor.manuallyApprovesFollowers),
      "published": "\(actor.createdAt)",
      "featured": "\(actorUrl)/collections/featured",
      "featuredTags": "\(actorUrl)/collections/tags",
      "attributionDomains": ["\(handleDomain)"]
    }
    """
    return json
}

/// Escape a string for safe inclusion as a JSON string value.
func escapeJSONString(_ value: String) -> String {
    // Use JSONEncoder to produce a properly escaped JSON string
    if let data = try? JSONEncoder().encode(value),
       let str = String(data: data, encoding: .utf8) {
        return str
    }
    // Fallback: manual escaping
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(escaped)\""
}

try await runtime.run()
