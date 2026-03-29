import AWSLambdaEvents
import AWSLambdaRuntime
import Foundation

let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] ?? "activity.happitec.com"

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    let path = event.path

    if path == "/nodeinfo/2.1" {
        // NodeInfo 2.1 document
        let body = """
        {
          "version": "2.1",
          "software": {"name": "activity-happitec", "version": "0.1.0"},
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
