# Mastodon Quoting Integration Gaps

After reviewing the current implementation of quoting in the `FederatedActivityPublisher` repository, three major gaps prevent proper interaction with Mastodon clients regarding Quote Posts.

## 1. Mastodon API Version Requirement

Mastodon API clients evaluate the server's API compatibility before enabling certain features. The quote functionality requires **Mastodon API version 7 or higher**.

Currently, the `InstanceHandler` reports `api_versions.mastodon` as `2`:

```json
"api_versions": {"mastodon": 2}
```

To enable quoting in compliant Mastodon clients, this value must be incremented to at least `7` in `Sources/InstanceHandler/main.swift`.

## 2. CloudFront API Path Proxying

The ActivityPub implementation provides both `/api/v1/instance` and `/api/v2/instance` endpoints for instance metadata. However, these endpoints are not currently proxied through the primary `happitec.com` CloudFront distribution.

In `Sources/ActivityPubCore/Documentation.docc/BuildingAndDeploying.md`, under "6. happitec.com CloudFront Behaviors", the proxied paths are documented as:
- `/.well-known/webfinger*`
- `/.well-known/nodeinfo`
- `/nodeinfo/*`
- `/users/*`

This means that requests for instance metadata at `https://happitec.com/api/v1/instance` and `https://happitec.com/api/v2/instance` are not reaching the backend API. They likely result in the root HTML SPA being returned instead of the expected JSON response.

To resolve this, the `/api/v1/instance` and `/api/v2/instance` cache behaviors must be added to the proxy configuration in the `happitec.com` CloudFront distribution.

## 3. Account Verification (Bonus)

While not strictly required for quoting, the `verified_at` property is not included in `PropertyValue` attachments in the Actor's JSON-LD representation (generated in `Sources/ActivityPubCore/ActorSerializer.swift`).

Mastodon displays a green checkmark indicating verified links based on the `verified_at` field being present. The current implementation outputs the rel="me" backlinks, but without checking them or reporting the verification result.
