# Authentication and Cryptography

How the server verifies inbound federation requests and authenticates client API calls.

## Overview

FederatedActivityPublisher uses two distinct authentication mechanisms: HTTP Signatures for federation traffic between servers, and bearer tokens for the client posting API. Both are implemented in `ActivityPubCore` so that individual Lambda handlers stay focused on business logic.

### HTTP Signatures (Federation)

When a remote Mastodon or GoToSocial server sends a Follow, Like, or other activity to an actor's inbox, the request carries an HTTP Signature header signed with the remote actor's RSA private key. The ``HTTPSignature`` enum provides methods to verify these signatures by fetching the remote actor's public key from their actor document.

``KeyManager`` handles the key resolution step. Given a `keyId` URI from the signature header, it fetches and caches the remote actor document, extracts the public key PEM, and returns it for verification. If the fetch fails or the document is malformed, it throws a descriptive ``KeyManagerError``.

For outbound delivery, the deliver Lambda signs each request using the local actor's RSA private key stored in AWS SSM Parameter Store. This is the Cavage HTTP Signature draft, which is the de facto standard across the fediverse.

### Bearer Token Authentication (Client API)

The client API endpoints (posting statuses, uploading media, updating profiles) require a bearer token in the Authorization header. The ``authenticateBearer(authHeader:ssmKeyPrefix:ssmClient:)`` function validates the token against a per-actor secret stored in SSM Parameter Store and returns a ``BearerAuthResult`` identifying the authenticated username. Invalid or missing tokens produce a ``BearerAuthError``.
