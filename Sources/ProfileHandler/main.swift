/// Lambda handler for `GET /profile/{proxy+}`.
///
/// This is the human-readable side of the server. It renders HTML for browsers
/// and is the destination for the 302 redirect that `ActorHandler` sends when
/// it detects a browser request.
///
/// The proxy path has two shapes:
/// - `/{username}` — renders `ProfilePage`, which shows the actor's bio, profile
///   fields, stats, and recent public/unlisted posts.
/// - `/{username}/{statusId}` — renders `PostPage`, which shows a single post.
///   Private and direct-visibility posts return 404 rather than their content.
///
/// HTML is produced using the `Elementary` DSL. Both page types include Open Graph
/// and Twitter Card meta tags so link previews work in social apps. The actor JSON-LD
/// URL is emitted as a `<link rel="alternate">` so AP clients that encounter the
/// profile URL can still find the machine-readable actor document.
///
/// `SERVER_DOMAIN` is required. `INSTANCE_TITLE` is optional and defaults to
/// `"FederatedActivityPublisher"`.
import AWSLambdaEvents
import AWSLambdaRuntime
import ActivityPubCore
import Elementary
import Foundation

guard let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] else {
    fatalError("SERVER_DOMAIN environment variable is required")
}
let instanceTitle = ProcessInfo.processInfo.environment["INSTANCE_TITLE"] ?? "FederatedActivityPublisher"

let store = try await DynamoDBStore()

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    // Parse proxy path: /profile/{proxy+}
    // proxy = "username" -> profile page
    // proxy = "username/statusId" -> post page
    guard let proxyPath = event.pathParameters["proxy"] else {
        return notFoundResponse(title: "Not Found", message: "Page not found.")
    }

    let parts = proxyPath.split(separator: "/", maxSplits: 1)
    guard !parts.isEmpty else {
        return notFoundResponse(title: "Not Found", message: "Page not found.")
    }

    let username = String(parts[0])
    let statusId = parts.count > 1 ? String(parts[1]) : nil

    do {
        guard let actor = try await store.getActor(username: username) else {
            return notFoundResponse(title: "Not Found", message: "This profile does not exist.")
        }

        if let statusId {
            // Post page
            return try await renderPostPage(actor: actor, statusId: statusId, context: context)
        } else {
            // Profile page
            return try await renderProfilePage(actor: actor, context: context)
        }
    } catch {
        context.logger.error("ProfileHandler error: \(error)")
        return serverErrorResponse(title: "Error", message: "Something went wrong.")
    }
}

// MARK: - Profile Page

/// Fetch and render the actor's profile page, showing recent public and unlisted posts.
///
/// - Parameters:
///   - actor: The actor whose profile is being rendered.
///   - context: The Lambda execution context, used for logging.
/// - Returns: A 200 response with `text/html` content and a 5-minute public cache TTL.
/// - Throws: Any DynamoDB error from `store.listStatuses`.
func renderProfilePage(actor: Actor, context: LambdaContext) async throws -> APIGatewayResponse {
    // Fetch recent public/unlisted statuses
    let (allStatuses, _) = try await store.listStatuses(username: actor.username, limit: 20)
    let statuses = allStatuses.filter { $0.visibility == "public" || $0.visibility == "unlisted" }

    let page = ProfilePage(actor: actor, statuses: statuses, domain: serverDomain)
    let html = page.render()

    return APIGatewayResponse(
        statusCode: .ok,
        headers: [
            "content-type": "text/html; charset=utf-8",
            "cache-control": "public, max-age=300",
        ],
        body: html
    )
}

// MARK: - Post Page

/// Render a single-post page for the given status ID.
///
/// Private and direct-visibility posts return 404 rather than their content,
/// so this endpoint never exposes non-public content to browsers. The post page
/// uses a one-year cache TTL because post content is immutable once published.
///
/// - Parameters:
///   - actor: The actor who owns the status.
///   - statusId: The ID of the status to render.
///   - context: The Lambda execution context, used for logging.
/// - Returns: A 200 response with `text/html`, or a 404 response if the status
///   doesn't exist or is private/direct.
/// - Throws: Any DynamoDB error from `store.getStatus`.
func renderPostPage(actor: Actor, statusId: String, context: LambdaContext) async throws -> APIGatewayResponse {
    guard let status = try await store.getStatus(username: actor.username, id: statusId) else {
        return notFoundResponse(title: "Not Found", message: "This post does not exist.")
    }

    // Private and direct posts are not accessible via HTML
    if status.visibility == "private" || status.visibility == "direct" {
        return notFoundResponse(title: "Not Found", message: "This post does not exist.")
    }

    let page = PostPage(actor: actor, status: status, domain: serverDomain)
    let html = page.render()

    return APIGatewayResponse(
        statusCode: .ok,
        headers: [
            "content-type": "text/html; charset=utf-8",
            "cache-control": "public, max-age=31536000",
        ],
        body: html
    )
}

// MARK: - Error Response

/// Returns a 404 HTML response using `ErrorPage`. The response is not cached (`no-cache`).
func notFoundResponse(title: String, message: String) -> APIGatewayResponse {
    let page = ErrorPage(title: title, message: message, domain: serverDomain)
    let html = page.render()
    return APIGatewayResponse(
        statusCode: .notFound,
        headers: [
            "content-type": "text/html; charset=utf-8",
            "cache-control": "no-cache",
        ],
        body: html
    )
}

/// Returns a 500 HTML response using `ErrorPage`. The response is not cached (`no-cache`).
func serverErrorResponse(title: String, message: String) -> APIGatewayResponse {
    let page = ErrorPage(title: title, message: message, domain: serverDomain)
    let html = page.render()
    return APIGatewayResponse(
        statusCode: .internalServerError,
        headers: [
            "content-type": "text/html; charset=utf-8",
            "cache-control": "no-cache",
        ],
        body: html
    )
}

// MARK: - Shared Styles

let sharedStyles = """
    .profile-header { display: flex; gap: 1.2rem; align-items: flex-start; margin-bottom: 1.5rem; }
    .avatar { width: 80px; height: 80px; border-radius: 4px; object-fit: cover; }
    .avatar-large { width: 100px; height: 100px; border-radius: 4px; object-fit: cover; }
    .handle { color: #666; font-size: 0.9rem; }
    .type-badge { display: inline-block; font-size: 0.8rem; padding: 0.1rem 0.5rem; border-radius: 3px; background: #e8f0fe; color: #1967d2; margin-top: 0.3rem; }
    .fields-table { width: 100%; border-collapse: collapse; margin: 1rem 0; }
    .fields-table td { padding: 0.4rem 0.8rem; border: 1px solid #ddd; }
    .fields-table td:first-child { font-weight: bold; width: 30%; background: #f8f8f8; }
    .stats { font-size: 0.9rem; color: #666; margin: 1rem 0; }
    .stats strong { color: inherit; }
    .post-entry { margin-bottom: 2rem; }
    .post-meta { font-size: 0.85rem; color: #888; margin-top: 0.5rem; }
    .post-cw { background: #fff3cd; border: 1px solid #ffc107; padding: 0.5rem 0.8rem; border-radius: 4px; margin-bottom: 0.8rem; font-weight: bold; }
    .post-media img { max-width: 100%; height: auto; border-radius: 4px; margin-top: 0.5rem; }
    .post-content { overflow-wrap: break-word; }
    .visibility-label { text-transform: capitalize; }
    @media (prefers-color-scheme: dark) {
        .handle { color: #aaa; }
        .type-badge { background: #1e3a5f; color: #6db3f2; }
        .fields-table td { border-color: #444; }
        .fields-table td:first-child { background: #2a2a2a; }
        .stats { color: #aaa; }
        .post-meta { color: #999; }
        .post-cw { background: #4a3c00; border-color: #997a00; color: #ffd54f; }
    }
    """

// MARK: - Profile Page Component

/// Full-page HTML document for an actor's profile.
///
/// Shows the actor's avatar, display name, bio, profile fields, follower/following/post
/// counts, and up to 20 recent public or unlisted posts. Open Graph and Twitter Card
/// meta tags are included for link previews. A `<link rel="alternate">` points AP
/// clients to the machine-readable actor JSON-LD at `/users/{username}`.
struct ProfilePage: HTMLDocument {
    var actor: Actor
    var statuses: [Status]
    var domain: String

    var title: String {
        "\(actor.displayName) (@\(actor.username)@\(domain))"
    }

    var lang: String { "en" }

    var bodyAttributes: [HTMLAttribute<HTMLTag.body>] {
        [.class("latex-dark-auto")]
    }

    var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
        link(.rel("stylesheet"), .href("https://\(domain)/media/frontend/latex.min.css"))
        link(.rel("alternate"), .custom(name: "type", value: "application/activity+json"),
             .href("https://\(domain)/users/\(actor.username)"))

        // OG meta tags
        meta(.property("og:type"), .content("profile"))
        meta(.property("og:site_name"), .content(instanceTitle))
        meta(.property("og:title"), .content("\(actor.displayName) (@\(actor.username)@\(domain))"))
        meta(.property("og:description"), .content(stripHTML(actor.summary)))
        meta(.property("og:url"), .content("https://\(domain)/@\(actor.username)"))
        if let avatarUrl = actor.avatarUrl {
            meta(.property("og:image"), .content(avatarUrl))
        }

        // Twitter Card
        meta(.name("twitter:card"), .content("summary"))
        meta(.name("twitter:title"), .content("\(actor.displayName) (@\(actor.username)@\(domain))"))
        meta(.name("twitter:description"), .content(stripHTML(actor.summary)))
        if let avatarUrl = actor.avatarUrl {
            meta(.name("twitter:image"), .content(avatarUrl))
        }

        HTMLRaw("<style>\(sharedStyles)</style>")
    }

    var body: some HTML {
        article {
            // Profile header
            header(.class("profile-header")) {
                if let avatarUrl = actor.avatarUrl {
                    img(.src(avatarUrl), .alt("Avatar of \(actor.displayName)"), .class("avatar-large"))
                }
                div {
                    h1 { actor.displayName }
                    p(.class("handle")) { "@\(actor.username)@\(domain)" }
                    span(.class("type-badge")) { "Service Account" }
                }
            }

            // Bio
            if !actor.summary.isEmpty {
                section {
                    HTMLRaw(actor.summary)
                }
            }

            // Profile fields
            if let fieldsJSON = actor.fields {
                let fields = parseProfileFields(fieldsJSON)
                if !fields.isEmpty {
                    table(.class("fields-table")) {
                        tbody {
                            for field in fields {
                                tr {
                                    td { field.name }
                                    td { HTMLRaw(formatFieldValueForActivityPub(field.value)) }
                                }
                            }
                        }
                    }
                }
            }

            // Stats
            p(.class("stats")) {
                strong { "\(actor.followerCount)" }
                " followers \u{00B7} "
                strong { "\(actor.followingCount)" }
                " following \u{00B7} "
                strong { "\(actor.statusCount)" }
                " posts"
            }

            hr()

            // Recent posts
            if !statuses.isEmpty {
                section {
                    h2 { "Recent Posts" }
                    for status in statuses {
                        StatusEntry(status: status, domain: domain)
                    }
                }
            }
        }

        footer {
            p {
                small {
                    "Part of the "
                    a(.href("https://www.w3.org/TR/activitypub/")) { "ActivityPub" }
                    " federation"
                }
            }
        }
    }
}

// MARK: - Status Entry Component (for profile page)

/// A single post entry rendered on the profile page.
///
/// Shows the content warning (if any), post HTML content, image attachments, and a
/// metadata line with the publication date, like count, boost count, and quote count.
/// The timestamp links to the individual post page.
struct StatusEntry: HTML {
    var status: Status
    var domain: String

    var body: some HTML {
        div(.class("post-entry")) {
            // Content warning
            if let cw = status.contentWarning, !cw.isEmpty {
                div(.class("post-cw")) {
                    "Content Warning: \(cw)"
                }
            }

            // Post content
            div(.class("post-content")) {
                HTMLRaw(status.content)
            }

            // Media attachments
            if let attachments = status.attachments, !attachments.isEmpty {
                div(.class("post-media")) {
                    for attachment in attachments {
                        if attachment.isImage {
                            figure {
                                img(.src(attachment.url), .alt(attachment.description ?? "Media attachment"))
                                if let desc = attachment.description, !desc.isEmpty {
                                    figcaption { desc }
                                }
                            }
                        }
                    }
                }
            }

            // Metadata line
            p(.class("post-meta")) {
                a(.href("https://\(domain)/@\(status.username)/\(status.id)")) {
                    time(.custom(name: "datetime", value: status.published)) { formatDate(status.published) }
                }
                " \u{00B7} \(status.likesCount) likes \u{00B7} \(status.boostsCount) boosts \u{00B7} \(status.quotesCount) quotes"
            }
        }
    }
}

// MARK: - Post Page Component

/// Full-page HTML document for a single post.
///
/// Shows the author header (avatar + handle), content warning, post content, image
/// attachments, publication timestamp, visibility label, and interaction counts.
/// Open Graph and Twitter Card meta tags are included. The `og:image` is the first
/// image attachment if present, falling back to the actor's avatar. The Twitter card
/// type is `summary_large_image` when any image attachment is present.
///
/// A `<link rel="alternate">` points AP clients to the machine-readable status at
/// `/users/{username}/statuses/{id}`.
struct PostPage: HTMLDocument {
    var actor: Actor
    var status: Status
    var domain: String

    var title: String {
        "\(actor.displayName) on \(instanceTitle)"
    }

    var lang: String { "en" }

    var bodyAttributes: [HTMLAttribute<HTMLTag.body>] {
        [.class("latex-dark-auto")]
    }

    /// The URL to use for `og:image` and `twitter:image`.
    ///
    /// Prefers the first image attachment, falls back to the actor's avatar.
    /// An empty string means no image tag is emitted.
    var ogImage: String {
        // Use first image attachment if available, otherwise avatar
        if let attachments = status.attachments,
           let firstImage = attachments.first(where: { $0.isImage }) {
            return firstImage.url
        }
        return actor.avatarUrl ?? ""  // Empty string handled below — og:image only emitted if non-empty
    }

    /// `"summary_large_image"` when the status has image attachments, `"summary"` otherwise.
    var twitterCardType: String {
        if let attachments = status.attachments,
           attachments.contains(where: { $0.isImage }) {
            return "summary_large_image"
        }
        return "summary"
    }

    /// Post content stripped of HTML tags, truncated to 200 characters for use in meta descriptions.
    var descriptionText: String {
        let stripped = stripHTML(status.content)
        if stripped.count > 200 {
            return String(stripped.prefix(200)) + "..."
        }
        return stripped
    }

    var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
        link(.rel("stylesheet"), .href("https://\(domain)/media/frontend/latex.min.css"))
        link(.rel("alternate"), .custom(name: "type", value: "application/activity+json"),
             .href("https://\(domain)/users/\(actor.username)/statuses/\(status.id)"))

        // OG meta tags
        meta(.property("og:type"), .content("article"))
        meta(.property("og:site_name"), .content(instanceTitle))
        meta(.property("og:title"), .content("\(actor.displayName) on \(instanceTitle)"))
        meta(.property("og:description"), .content(descriptionText))
        meta(.property("og:url"), .content("https://\(domain)/@\(actor.username)/\(status.id)"))
        if !ogImage.isEmpty {
            meta(.property("og:image"), .content(ogImage))
        }
        meta(.property("article:published_time"), .content(status.published))
        meta(.property("article:author"), .content("https://\(domain)/@\(actor.username)"))

        // Twitter Card
        meta(.name("twitter:card"), .content(twitterCardType))
        meta(.name("twitter:title"), .content("\(actor.displayName) on \(instanceTitle)"))
        meta(.name("twitter:description"), .content(descriptionText))
        if !ogImage.isEmpty {
            meta(.name("twitter:image"), .content(ogImage))
        }

        HTMLRaw("<style>\(sharedStyles)</style>")
    }

    var body: some HTML {
        article {
            // Author info
            header(.class("profile-header")) {
                if let avatarUrl = actor.avatarUrl {
                    a(.href("https://\(domain)/@\(actor.username)")) {
                        img(.src(avatarUrl), .alt("Avatar of \(actor.displayName)"), .class("avatar"))
                    }
                }
                div {
                    h1 {
                        a(.href("https://\(domain)/@\(actor.username)")) { actor.displayName }
                    }
                    p(.class("handle")) { "@\(actor.username)@\(domain)" }
                }
            }

            // Content warning
            if let cw = status.contentWarning, !cw.isEmpty {
                div(.class("post-cw")) {
                    "Content Warning: \(cw)"
                }
            }

            // Post content
            section(.class("post-content")) {
                HTMLRaw(status.content)
            }

            // Media attachments
            if let attachments = status.attachments, !attachments.isEmpty {
                div(.class("post-media")) {
                    for attachment in attachments {
                        if attachment.isImage {
                            figure {
                                img(.src(attachment.url), .alt(attachment.description ?? "Media attachment"))
                                if let desc = attachment.description, !desc.isEmpty {
                                    figcaption { desc }
                                }
                            }
                        }
                    }
                }
            }

            // Timestamp and visibility
            p(.class("post-meta")) {
                time(.custom(name: "datetime", value: status.published)) { formatDate(status.published) }
                " \u{00B7} "
                span(.class("visibility-label")) { status.visibility }
            }

            // Interaction counts
            p(.class("post-meta")) {
                "\(status.likesCount) likes \u{00B7} \(status.boostsCount) boosts \u{00B7} \(status.quotesCount) quotes \u{00B7} \(status.repliesCount) replies"
            }

            hr()

            nav {
                a(.href("https://\(domain)/@\(actor.username)")) {
                    "View \(actor.displayName)'s profile"
                }
            }
        }
    }
}

// MARK: - Error Page Component

/// Minimal error page used for 404 and 500 responses.
struct ErrorPage: HTMLDocument {
    var errorTitle: String
    var message: String
    var domain: String

    init(title: String, message: String, domain: String) {
        self.errorTitle = title
        self.message = message
        self.domain = domain
    }

    var title: String { "\(errorTitle) - \(instanceTitle)" }
    var lang: String { "en" }

    var bodyAttributes: [HTMLAttribute<HTMLTag.body>] {
        [.class("latex-dark-auto")]
    }

    var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
        link(.rel("stylesheet"), .href("https://\(domain)/media/frontend/latex.min.css"))
    }

    var body: some HTML {
        article {
            h1 { errorTitle }
            p { message }
        }
    }
}

// MARK: - Helpers

/// Strip HTML tags for use in meta descriptions.
func stripHTML(_ html: String) -> String {
    html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&apos;", with: "'")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Format an ISO 8601 date string into a human-readable format.
func formatDate(_ isoDate: String) -> String {
    // Return just the date portion: "2026-03-30"
    if isoDate.count >= 10 {
        return String(isoDate.prefix(10))
    }
    return isoDate
}

try await runtime.run()
