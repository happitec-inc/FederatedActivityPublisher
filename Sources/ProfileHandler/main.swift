import AWSLambdaEvents
import AWSLambdaRuntime
import ActivityPubCore
import Foundation

let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] ?? "happitec.com"

let store = try await DynamoDBStore()

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    // Extract username from path parameter (/profile/{username})
    guard let username = event.pathParameters["username"] else {
        return APIGatewayResponse(
            statusCode: .notFound,
            headers: ["content-type": "text/html"],
            body: "<html><body><h1>Not Found</h1></body></html>"
        )
    }

    do {
        guard let actor = try await store.getActor(username: username) else {
            return APIGatewayResponse(
                statusCode: .notFound,
                headers: ["content-type": "text/html"],
                body: "<html><body><h1>Not Found</h1></body></html>"
            )
        }

        let html = buildProfileHTML(actor: actor, domain: serverDomain)

        return APIGatewayResponse(
            statusCode: .ok,
            headers: [
                "content-type": "text/html; charset=utf-8",
                "cache-control": "public, max-age=3600",
            ],
            body: html
        )
    } catch {
        context.logger.error("ProfileHandler error: \(error)")
        return APIGatewayResponse(
            statusCode: .internalServerError,
            headers: ["content-type": "text/html"],
            body: "<html><body><h1>Internal Server Error</h1></body></html>"
        )
    }
}

func buildProfileHTML(actor: Actor, domain: String) -> String {
    let escapedName = actor.displayName
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    let escapedSummary = actor.summary
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    let handle = "@\(actor.username)@\(domain)"
    let profileUrl = "https://\(domain)/@\(actor.username)"
    let actorUrl = "https://\(domain)/users/\(actor.username)"

    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapedName) (\(handle))</title>
        <meta property="og:title" content="\(escapedName)">
        <meta property="og:description" content="\(escapedSummary)">
        <meta property="og:type" content="profile">
        <meta property="og:url" content="\(profileUrl)">
        <link rel="alternate" type="application/activity+json" href="\(actorUrl)">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                max-width: 600px;
                margin: 80px auto;
                padding: 0 20px;
                color: #1a1a1a;
                background: #fafafa;
            }
            @media (prefers-color-scheme: dark) {
                body { background: #1a1a1a; color: #e0e0e0; }
                .card { background: #2a2a2a; border-color: #333; }
                a { color: #6db3f2; }
            }
            .card {
                background: #fff;
                border: 1px solid #e0e0e0;
                border-radius: 12px;
                padding: 32px;
            }
            .name { font-size: 24px; font-weight: 700; margin-bottom: 4px; }
            .handle { font-size: 15px; color: #666; margin-bottom: 16px; }
            .summary { font-size: 16px; line-height: 1.5; margin-bottom: 20px; }
            .stats { display: flex; gap: 24px; font-size: 14px; color: #666; margin-bottom: 20px; }
            .stats span { font-weight: 600; color: inherit; }
            .type-badge {
                display: inline-block;
                font-size: 12px;
                padding: 2px 8px;
                border-radius: 4px;
                background: #e8f0fe;
                color: #1967d2;
                margin-bottom: 16px;
            }
            @media (prefers-color-scheme: dark) {
                .handle { color: #999; }
                .stats { color: #999; }
                .type-badge { background: #1e3a5f; color: #6db3f2; }
            }
            .footer { margin-top: 24px; font-size: 13px; color: #999; text-align: center; }
        </style>
    </head>
    <body>
        <div class="card">
            <div class="type-badge">Service Account</div>
            <div class="name">\(escapedName)</div>
            <div class="handle">\(handle)</div>
            <div class="summary">\(escapedSummary)</div>
            <div class="stats">
                <div><span>\(actor.followerCount)</span> followers</div>
                <div><span>\(actor.followingCount)</span> following</div>
                <div><span>\(actor.statusCount)</span> posts</div>
            </div>
        </div>
        <div class="footer">
            Part of the <a href="https://www.w3.org/TR/activitypub/">ActivityPub</a> federation
        </div>
    </body>
    </html>
    """
}

try await runtime.run()
