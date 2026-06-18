/// Lambda handler for the Mastodon instance metadata endpoints.
///
/// Remote fediverse software (Mastodon, Akkoma, Misskey, etc.) queries these endpoints
/// to learn about this server's capabilities, limits, and identity before attempting
/// federation. This handler covers both the v1 and v2 Mastodon instance APIs:
///
/// - `GET /api/v1/instance` — legacy format, used by older Mastodon clients and some
///   third-party apps for initial discovery.
/// - `GET /api/v2/instance` — current format, includes structured configuration blocks
///   for statuses, media, and polls.
///
/// Both responses are static JSON payloads assembled from environment variables.
/// No database access is required. CloudFront caches these responses; the TTL is
/// controlled by the `Cache-Control` header set in the CloudFront distribution config.
///
/// Required environment variables:
/// - `SERVER_DOMAIN`: the ActivityPub server domain (e.g. `activity.happitec.com`)
///
/// Optional environment variables (all have defaults):
/// - `INSTANCE_TITLE`: display name of the instance
/// - `INSTANCE_DESCRIPTION`: short description shown in federation UIs
/// - `SOURCE_URL`: URL to the server's source code (shown in Mastodon's about page)
import AWSLambdaEvents
import AWSLambdaRuntime
import Foundation

guard let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] else {
    fatalError("SERVER_DOMAIN environment variable is required")
}

let instanceTitle = ProcessInfo.processInfo.environment["INSTANCE_TITLE"] ?? "FederatedActivityPublisher"
let instanceDescription = ProcessInfo.processInfo.environment["INSTANCE_DESCRIPTION"]
    ?? "A serverless ActivityPub server powered by FederatedActivityPublisher."
let sourceUrl = ProcessInfo.processInfo.environment["SOURCE_URL"]
    ?? "https://github.com/happitec-inc/FederatedActivityPublisher"

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    let path = event.path

    if path == "/api/v2/instance" {
        let body = """
        {
          "domain": "\(serverDomain)",
          "title": "\(instanceTitle)",
          "version": "4.5.0 (compatible; FederatedActivityPublisher 0.4.2)",
          "source_url": "\(sourceUrl)",
          "description": "\(instanceDescription)",
          "usage": {"users": {"active_month": 4}},
          "thumbnail": null,
          "icon": [],
          "languages": ["en"],
          "configuration": {
            "urls": {},
            "accounts": {
              "max_featured_tags": 10,
              "max_pinned_statuses": 0
            },
            "statuses": {
              "max_characters": 5000,
              "max_media_attachments": 4,
              "characters_reserved_per_url": 23
            },
            "media_attachments": {
              "supported_mime_types": ["image/jpeg", "image/png", "image/gif"],
              "image_size_limit": 6291456
            },
            "polls": {
              "max_options": 0,
              "max_characters_per_option": 0,
              "min_expiration": 0,
              "max_expiration": 0
            },
            "translation": {
              "enabled": false
            }
          },
          "registrations": {
            "enabled": false,
            "approval_required": false,
            "reason_required": false,
            "message": null,
            "url": null,
            "min_age": null
          },
          "api_versions": {"mastodon": 7},
          "contact": {"email": "", "account": null},
          "rules": []
        }
        """
        return APIGatewayResponse(
            statusCode: .ok,
            headers: ["content-type": "application/json; charset=utf-8"],
            body: body
        )
    } else {
        // Default: /api/v1/instance
        let body = """
        {
          "uri": "\(serverDomain)",
          "title": "\(instanceTitle)",
          "short_description": "\(instanceDescription)",
          "description": "\(instanceDescription)",
          "email": "",
          "version": "4.5.0 (compatible; FederatedActivityPublisher 0.4.2)",
          "urls": {
            "streaming_api": ""
          },
          "stats": {
            "user_count": 4,
            "status_count": 0,
            "domain_count": 0
          },
          "thumbnail": null,
          "languages": ["en"],
          "registrations": false,
          "approval_required": false,
          "invites_enabled": false,
          "configuration": {
            "accounts": {
              "max_featured_tags": 10
            },
            "statuses": {
              "max_characters": 5000,
              "max_media_attachments": 4,
              "characters_reserved_per_url": 23
            },
            "media_attachments": {
              "supported_mime_types": ["image/jpeg", "image/png", "image/gif"],
              "image_size_limit": 6291456,
              "image_matrix_limit": 33177600
            },
            "polls": {
              "max_options": 0,
              "max_characters_per_option": 0,
              "min_expiration": 0,
              "max_expiration": 0
            }
          },
          "contact_account": null,
          "rules": []
        }
        """
        return APIGatewayResponse(
            statusCode: .ok,
            headers: ["content-type": "application/json; charset=utf-8"],
            body: body
        )
    }
}

try await runtime.run()
