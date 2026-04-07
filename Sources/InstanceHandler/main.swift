import AWSLambdaEvents
import AWSLambdaRuntime
import Foundation

guard let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] else {
    fatalError("SERVER_DOMAIN environment variable is required")
}

let instanceTitle = ProcessInfo.processInfo.environment["INSTANCE_TITLE"] ?? "FederatedActivityPublisher"

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    let path = event.path

    if path == "/api/v2/instance" {
        let body = """
        {
          "domain": "\(serverDomain)",
          "title": "\(instanceTitle)",
          "version": "4.5.0 (compatible; FederatedActivityPublisher 0.4.2)",
          "source_url": "https://github.com/happitec-inc/FederatedActivityPublisher",
          "description": "A serverless ActivityPub server powered by FederatedActivityPublisher. A project by Happitec.",
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
          "short_description": "A serverless ActivityPub server powered by FederatedActivityPublisher",
          "description": "A serverless ActivityPub server powered by FederatedActivityPublisher. A project by Happitec.",
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
