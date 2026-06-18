/// Lambda handler for NodeInfo discovery and the NodeInfo 2.1 document.
///
/// NodeInfo is a cross-platform standard (used by Mastodon, Pleroma, Misskey, and others)
/// for advertising basic server capabilities. Federation software queries NodeInfo to
/// determine whether a server speaks ActivityPub, whether registrations are open, and
/// rough usage counts.
///
/// This handler covers two paths:
/// - `GET /.well-known/nodeinfo` — discovery document that points to the versioned
///   NodeInfo URL. Clients fetch this first to find the canonical NodeInfo link.
/// - `GET /nodeinfo/2.1` — the NodeInfo 2.1 document with software identity, protocol
///   list, and usage statistics.
///
/// Both responses are static JSON. No database access is required.
///
/// Required environment variables:
/// - `SERVER_DOMAIN`: the ActivityPub server domain (e.g. `activity.happitec.com`)
import AWSLambdaEvents
import AWSLambdaRuntime
import Foundation

guard let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] else {
    fatalError("SERVER_DOMAIN environment variable is required")
}

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    let path = event.path

    if path == "/nodeinfo/2.1" {
        // NodeInfo 2.1 document
        let body = """
        {
          "version": "2.1",
          "software": {"name": "federated-activity-publisher", "version": "0.1.0"},
          "protocols": ["activitypub"],
          "services": {"inbound": [], "outbound": []},
          "openRegistrations": false,
          "usage": {"users": {"total": 0, "activeMonth": 0, "activeHalfyear": 0}, "localPosts": 0},
          "metadata": {}
        }
        """
        return APIGatewayResponse(
            statusCode: .ok,
            headers: ["content-type": "application/json"],
            body: body
        )
    } else {
        // /.well-known/nodeinfo discovery document
        let body = """
        {
          "links": [{
            "rel": "http://nodeinfo.diaspora.software/ns/schema/2.1",
            "href": "https://\(serverDomain)/nodeinfo/2.1"
          }]
        }
        """
        return APIGatewayResponse(
            statusCode: .ok,
            headers: ["content-type": "application/json"],
            body: body
        )
    }
}

try await runtime.run()
