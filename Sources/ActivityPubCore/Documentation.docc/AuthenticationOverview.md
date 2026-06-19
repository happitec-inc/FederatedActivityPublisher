# Authentication and Cryptography

How the server verifies inbound federation requests and authenticates client API calls.

## Overview

FederatedActivityPublisher uses two distinct authentication mechanisms: HTTP Signatures for federation traffic between servers, and bearer tokens for the client posting API. Both are implemented in `ActivityPubCore` so that individual Lambda handlers stay focused on business logic.

### HTTP Signatures (Federation)

When a remote Mastodon or GoToSocial server sends a Follow, Like, or other activity to an actor's inbox, the request carries an HTTP Signature header signed with the remote actor's RSA private key. The ``HTTPSignature`` enum provides methods to verify these signatures by fetching the remote actor's public key from their actor document.

``KeyManager`` handles the key resolution step. Given a `keyId` URI from the signature header, it fetches and caches the remote actor document, extracts the public key PEM, and returns it for verification. If the fetch fails or the document is malformed, it throws a descriptive ``KeyManagerError``.

For outbound delivery, the deliver Lambda signs each request using the local actor's RSA private key stored in AWS SSM Parameter Store. This is the Cavage HTTP Signature draft, which is the de facto standard across the fediverse.

### Bearer Token Authentication (Client API)

The client API endpoints (posting statuses, uploading media, updating profiles) require a bearer token in the Authorization header. The ``authenticateBearer(authHeader:store:ssmKeyPrefix:ssmClient:)`` function validates the token using a two-phase lookup:

1. **DynamoDB lookup (primary)**: The raw token is hashed with SHA-256, and the hash is used to query a `TOKEN#<hash>` record in DynamoDB. The raw token is never stored -- only its hash appears in the database. Each token record includes the username, scope, creation timestamp, and an optional TTL for automatic expiry.

2. **SSM fallback (legacy)**: If no DynamoDB token record is found, the function falls back to checking the legacy `client-token` SSM parameter in `username:token` format. SSM fallback hits are logged so that migration progress can be monitored.

The ``BearerAuthResult`` returned on success includes the authenticated username and scope (e.g., `"read write"`). Invalid or missing tokens produce a ``BearerAuthError``.

Per-account tokens stored in DynamoDB mean multiple actors can post independently without sharing or swapping a single SSM parameter. Token records are created locally with the `ActivityProvisioner` CLI's `mint-token` subcommand; see <doc:ManagingActorsAndTokens>.

### Session Authentication (Web UI)

The ``authenticateRequest(authHeader:cookies:store:ssmKeyPrefix:ssmClient:signingKey:serverDomain:)`` function supports both bearer tokens and session cookies. It checks the Authorization header first (bearer token via the DynamoDB/SSM path above), then falls back to a `session` cookie containing a signed JWT. The ``RequestAuthResult`` includes the ``AuthMethod`` (`.bearer` or `.session`) so callers can vary their response format -- JSON for API clients, redirects for browsers.
