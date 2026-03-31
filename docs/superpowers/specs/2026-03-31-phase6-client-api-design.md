# Phase 6 Design -- Mastodon Client API

## Goal

Enable users to interact with FederatedActivityPublisher through standard Mastodon client apps (Ivory, Ice Cubes, Elk) by implementing the OAuth2 authorization flow and the minimum set of Mastodon REST API endpoints those clients require. Accounts remain CLI-provisioned only; there is no user registration UI.

## Success Criteria

1. A user can add their server domain in Ivory, complete the OAuth2 login flow, and see their profile.
2. The user can compose and publish posts (text, media, content warnings, visibility) from the client app.
3. The user can view their own timeline and notifications.
4. The OAuth2 flow uses AWS Cognito as the identity provider -- no custom token-signing code.
5. All new Lambda handlers are written in Swift.
6. The OpenAPI spec is updated before any implementation begins.

## What This Does NOT Include

- User registration (web signup, email verification)
- Streaming/WebSocket API (`wss://`)
- Full search (`/api/v2/search`)
- Polls, scheduled posts, bookmarks, announcements
- Admin/moderation endpoints
- Direct messages
- Relay support

---

## Architecture Overview

```
                     Ivory / Ice Cubes / Elk
                              |
                    POST /api/v1/apps
                    GET  /oauth/authorize  --> Cognito Hosted UI
                    POST /oauth/token      --> Cognito Token Endpoint
                              |
                     Bearer token (JWT)
                              |
                   API Gateway (ClientApi)
                     + Cognito Authorizer
                              |
            +-------+---------+---------+--------+
            |       |         |         |        |
          Post   Media   Profile  Account  Timeline
         Handler Handler Handler  Handler  Handler
            |       |         |         |        |
          DynamoDB  S3     DynamoDB  DynamoDB  DynamoDB
```

### Key Architectural Decisions

**D1: Cognito User Pool as OAuth2 Provider.** Cognito provides standard OAuth2/OIDC endpoints (authorize, token, revoke, userinfo) and issues JWTs that API Gateway can validate natively. This eliminates the need for custom token-signing code and gives us a standards-compliant authorization server.

**D2: Single ClientApiHandler Lambda.** The new read-only endpoints (verify_credentials, timelines, notifications, preferences, etc.) share the same data access patterns and can be routed by path within a single Lambda. This avoids 10+ cold-start-prone Lambdas for endpoints that are called frequently. The existing write handlers (PostHandler, MediaUploadHandler, ProfileUpdateHandler) remain separate due to their distinct IAM permission requirements.

**D3: Cognito Hosted UI for the authorize page.** Mastodon clients redirect the user to `/oauth/authorize`. We proxy this to Cognito's hosted UI. The user sees a login page (username + password). No signup link. After login, Cognito redirects back to the client with an authorization code.

**D4: Transition from SSM bearer tokens to Cognito JWTs.** The existing SSM-based bearer auth is replaced by Cognito JWT validation on the API Gateway authorizer. The SSM tokens remain available as a fallback during migration (controlled by a SAM parameter). Once all clients use OAuth2, the SSM path can be removed.

---

## OAuth2 Flow -- Cognito Integration

### How Mastodon OAuth2 Works (from the client's perspective)

1. Client calls `POST /api/v1/apps` with `client_name`, `redirect_uris`, `scopes`. Server returns `client_id`, `client_secret`.
2. Client opens a browser to `GET /oauth/authorize?client_id=...&redirect_uri=...&response_type=code&scope=read+write`.
3. User logs in, grants access. Server redirects to `redirect_uri?code=AUTH_CODE`.
4. Client calls `POST /oauth/token` with `grant_type=authorization_code`, `code`, `client_id`, `client_secret`, `redirect_uri`. Server returns `access_token`.
5. Client uses `Authorization: Bearer {access_token}` on all subsequent requests.

### Cognito Mapping

| Mastodon Concept | Cognito Equivalent | Notes |
|---|---|---|
| User account | Cognito User Pool user | Created via CLI (`aws cognito-idp admin-create-user`), never self-service |
| Client app registration (`/api/v1/apps`) | Cognito App Client | Created dynamically via a Lambda that calls `CreateUserPoolClient` |
| `/oauth/authorize` | Cognito Hosted UI `/authorize` | Custom domain on Cognito maps to our `/oauth/authorize` path |
| `/oauth/token` | Cognito `/oauth2/token` | Proxied or redirected |
| `/oauth/revoke` | Cognito `/oauth2/revoke` | Proxied or redirected |
| `access_token` | Cognito JWT (access token) | Validated by API Gateway Cognito Authorizer |
| Scopes (`read`, `write`, `follow`) | Cognito custom scopes on Resource Server | Mapped to Mastodon scope strings |

### Cognito Resources (added to environment template)

```yaml
# activity-environment/template.yaml additions

CognitoUserPool:
  Type: AWS::Cognito::UserPool
  Properties:
    UserPoolName: !Sub "activity-users-${Stage}"
    AdminCreateUserConfig:
      AllowAdminCreateUserOnly: true   # No self-service signup
    UsernameAttributes: []             # Username is the ActivityPub username
    AutoVerifiedAttributes: []         # No email/phone verification
    Policies:
      PasswordPolicy:
        MinimumLength: 16
        RequireLowercase: true
        RequireNumbers: true
        RequireSymbols: false
        RequireUppercase: true
    Schema:
      - Name: preferred_username
        AttributeDataType: String
        Mutable: true

CognitoUserPoolDomain:
  Type: AWS::Cognito::UserPoolDomain
  Properties:
    Domain: !Sub "auth-${Stage}-activity"  # auth-stage-activity.auth.us-east-1.amazoncognito.com
    UserPoolId: !Ref CognitoUserPool
    # Custom domain (auth.activity.happitec.com) added later if needed

CognitoResourceServer:
  Type: AWS::Cognito::UserPoolResourceServer
  Properties:
    Identifier: !Sub "https://${ServerDomain}/api"
    Name: "Mastodon API"
    UserPoolId: !Ref CognitoUserPool
    Scopes:
      - ScopeName: "read"
        ScopeDescription: "Read account data, timelines, notifications"
      - ScopeName: "write"
        ScopeDescription: "Post statuses, upload media, update profile"
      - ScopeName: "follow"
        ScopeDescription: "Follow and unfollow accounts"
      - ScopeName: "push"
        ScopeDescription: "Web push notifications (not implemented)"
```

### The `/api/v1/apps` Problem

Mastodon clients expect to dynamically register themselves via `POST /api/v1/apps`. Cognito does not have a dynamic client registration endpoint -- app clients are created via the AWS API.

**Solution:** A Lambda (`OAuthAppsHandler`) that:
1. Receives the Mastodon `POST /api/v1/apps` request.
2. Calls `cognito-idp:CreateUserPoolClient` to create a new Cognito app client with the requested redirect URIs and scopes.
3. Stores the mapping (Mastodon client_id = Cognito app client ID) in DynamoDB for later lookup.
4. Returns the `client_id`, `client_secret`, and other fields in Mastodon's expected format.

DynamoDB item:
```
PK: OAUTH_APP#{client_id}
SK: OAUTH_APP#{client_id}
client_name: "Ivory"
redirect_uri: "com.tapbots.ivory://oauth"
scopes: "read write follow push"
client_id: "{cognito-app-client-id}"
client_secret: "{cognito-app-client-secret}"
created_at: "2026-03-31T..."
```

### The `/oauth/authorize` Redirect

Mastodon clients open `/oauth/authorize?client_id=...&response_type=code&redirect_uri=...&scope=read+write`.

**Solution:** A Lambda (`OAuthAuthorizeHandler`) that:
1. Validates the `client_id` against DynamoDB.
2. Translates Mastodon scopes (`read write`) to Cognito scopes (`https://{domain}/api/read https://{domain}/api/write`).
3. Returns a 302 redirect to the Cognito Hosted UI `/authorize` endpoint with the translated parameters.
4. After login, Cognito redirects back to the client's `redirect_uri` with the authorization `code`.

### The `/oauth/token` Endpoint

Mastodon clients POST to `/oauth/token` with `grant_type=authorization_code` (or `client_credentials` for public data).

**Solution:** A Lambda (`OAuthTokenHandler`) that:
1. Receives the Mastodon token request.
2. Translates scopes back from Mastodon format.
3. Proxies the request to Cognito's `/oauth2/token` endpoint.
4. Translates the Cognito response back to Mastodon's expected format (wraps the JWT `access_token` in the Mastodon response shape: `{ "access_token": "...", "token_type": "Bearer", "scope": "read write", "created_at": ... }`).

### The `/oauth/revoke` Endpoint

**Solution:** Proxy to Cognito's `/oauth2/revoke` endpoint. Straightforward.

### Token Refresh

Cognito issues refresh tokens alongside access tokens by default. The `OAuthTokenHandler` must also handle `grant_type=refresh_token` requests, which Mastodon clients send when the access token expires. This is a standard OAuth2 flow that Cognito supports natively -- the handler proxies the request to Cognito's `/oauth2/token` endpoint with the refresh token, and returns a new access token in Mastodon's response format.

### Authentication on Client API Endpoints

**API Gateway Cognito Authorizer:**

```yaml
# activity-app/template.yaml

CognitoAuthorizer:
  Type: AWS::ApiGateway::Authorizer
  Properties:
    Name: CognitoAuth
    Type: COGNITO_USER_POOLS
    RestApiId: !Ref ClientApi
    IdentitySource: method.request.header.Authorization
    ProviderARNs:
      - !ImportValue
        Fn::Sub: "${EnvironmentStackName}-UserPoolArn"
```

All authenticated endpoints use this authorizer. The Lambda receives the decoded JWT claims in `event.requestContext.authorizer.claims`, which includes the `sub` (Cognito user ID) and `cognito:username` (the ActivityPub username).

---

## API Endpoints -- Full Inventory

### Tier 1: OAuth2 (new, unauthenticated)

| Method | Path | Handler | Description |
|---|---|---|---|
| POST | `/api/v1/apps` | OAuthAppsHandler | Register client application |
| GET | `/oauth/authorize` | OAuthAuthorizeHandler | Redirect to Cognito login |
| POST | `/oauth/token` | OAuthTokenHandler | Exchange code for token |
| POST | `/oauth/revoke` | OAuthRevokeHandler | Revoke token |

### Tier 2: Account verification (new, authenticated)

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/api/v1/accounts/verify_credentials` | ClientApiHandler | Returns the authenticated user's account. First thing every client calls after login. |
| GET | `/api/v1/accounts/:id` | ClientApiHandler | Get any account by ID (local actors only for now) |
| GET | `/api/v1/accounts/:id/statuses` | ClientApiHandler | List an account's statuses (paginated) |

### Tier 3: Timelines and notifications (new, authenticated)

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/api/v1/timelines/home` | ClientApiHandler | Home timeline. For a single-user server, this is the user's own posts plus any posts from accounts they follow (currently none, so effectively own posts). Returns newest first, supports `max_id`, `since_id`, `min_id`, `limit` pagination. |
| GET | `/api/v1/notifications` | ClientApiHandler | Notifications (likes, boosts, follows, mentions). Sourced from INTERACTION# and REPLY# records in DynamoDB. |
| GET | `/api/v1/markers` | ClientApiHandler | Read position markers. Returns empty object initially. |
| POST | `/api/v1/markers` | ClientApiHandler | Save read position markers. Store in DynamoDB. |

### Tier 4: Static/stub endpoints (new, may be unauthenticated)

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/api/v1/custom_emojis` | ClientApiHandler | Returns `[]` |
| GET | `/api/v1/filters` | ClientApiHandler | Returns `[]` (v1 filters, deprecated but still queried) |
| GET | `/api/v2/filters` | ClientApiHandler | Returns `[]` |
| GET | `/api/v1/preferences` | ClientApiHandler | Returns default preferences object |
| GET | `/api/v1/announcements` | ClientApiHandler | Returns `[]` |
| GET | `/api/v1/lists` | ClientApiHandler | Returns `[]` |
| GET | `/api/v1/followed_tags` | ClientApiHandler | Returns `[]` |
| GET | `/api/v1/conversations` | ClientApiHandler | Returns `[]` |
| GET | `/api/v1/push/subscription` | ClientApiHandler | Returns 404 (push notifications not implemented) |
| GET | `/api/v1/instance/peers` | ClientApiHandler | Returns `[]` (no peer tracking) |
| GET | `/api/v1/instance/activity` | ClientApiHandler | Returns `[]` (no activity stats) |
| GET | `/api/v1/accounts/relationships` | ClientApiHandler | Returns `[]` (no local follow relationships to report). Ivory calls this early; returning an empty array is safe. |
| GET | `/api/v1/accounts/lookup` | ClientApiHandler | Look up account by `acct` query param. Returns the Account entity if found. |
| GET | `/api/v1/statuses/:id` | ClientApiHandler | Get a single status by ID |
| GET | `/api/v1/statuses/:id/context` | ClientApiHandler | Thread context (ancestors + descendants from stored replies) |
| GET | `/api/v1/media/:id` | ClientApiHandler | Media polling endpoint (returns immediately since we process synchronously) |

### Tier 5: Already implemented (add Cognito auth gate)

| Method | Path | Handler | Change Needed |
|---|---|---|---|
| POST | `/api/v1/statuses` | PostHandler | Switch from SSM bearer to Cognito authorizer |
| POST | `/api/v2/media` | MediaUploadHandler | Switch from SSM bearer to Cognito authorizer |
| PATCH | `/api/v1/accounts/update_credentials` | ProfileUpdateHandler | Switch from SSM bearer to Cognito authorizer |

### Tier 6: Already implemented (no auth, no changes needed)

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/v1/instance` | InstanceHandler | Already done |
| GET | `/api/v2/instance` | InstanceHandler | Already done |

### Tier 7: Nice to have (defer unless Ivory requires them)

| Method | Path | Description |
|---|---|---|
| POST | `/api/v1/statuses/:id/favourite` | Like a post (local action only; does not federate a Like activity yet) |
| POST | `/api/v1/statuses/:id/unfavourite` | Unlike |
| POST | `/api/v1/statuses/:id/reblog` | Boost (does not federate an Announce activity yet) |
| POST | `/api/v1/statuses/:id/unreblog` | Unboost |
| DELETE | `/api/v1/statuses/:id` | Delete a status (federate Delete activity) |

---

## Ivory / Ice Cubes Startup Sequence

Based on network traces of what these apps do on first launch after adding a server:

1. `GET /api/v1/instance` or `GET /api/v2/instance` -- already implemented
2. `POST /api/v1/apps` -- register the client app (new)
3. Open browser to `/oauth/authorize` -- Cognito Hosted UI (new)
4. User logs in, redirected back with auth code
5. `POST /oauth/token` -- exchange code for access token (new)
6. `GET /api/v1/accounts/verify_credentials` -- critical, first authenticated call (new)
7. `GET /api/v1/preferences` -- user preferences (new, return defaults)
8. `GET /api/v1/custom_emojis` -- custom emoji (new, return `[]`)
9. `GET /api/v1/filters` or `GET /api/v2/filters` -- content filters (new, return `[]`)
10. `GET /api/v1/markers` -- read positions (new, return `{}`)
11. `GET /api/v1/announcements` -- server announcements (new, return `[]`)
12. `GET /api/v1/accounts/relationships` -- relationship info (new, return `[]`)
13. `GET /api/v1/notifications` -- notifications (new)
14. `GET /api/v1/timelines/home` -- home timeline (new)

All 14 steps must return valid responses for the app to be usable. Missing any one causes error screens or infinite loading.

---

## DynamoDB Schema Additions

### OAuth App Registrations

```
PK: OAUTH_APP#{client_id}
SK: OAUTH_APP#{client_id}
client_name: String
redirect_uri: String
scopes: String
client_secret: String
website: String (optional)
created_at: String (ISO 8601)
```

### Read Position Markers

```
PK: ACTOR#{username}
SK: MARKER#{timeline}
last_read_id: String (status ID)
updated_at: String (ISO 8601)
version: Number
```

### Notifications (new item type)

Interactions (likes, boosts) and replies are already stored as `INTERACTION#` and `REPLY#` items. For the notifications endpoint, we need a unified view. Two options:

**Option A (recommended): Query existing items.** The `INTERACTION#` and `REPLY#` items already have the actor URI, timestamp, and type. Query them by PK=`ACTOR#{username}` with SK prefix-scan, union the results, sort by timestamp. This avoids data duplication.

**Option B: Write-time fan-out to NOTIFICATION# items.** InboxHandler creates a `NOTIFICATION#` item whenever it stores an interaction or reply. Cleaner to query but doubles write volume.

Recommendation: Start with Option A. The query is slightly more complex but avoids schema changes to InboxHandler. If performance becomes an issue (unlikely given the scale), migrate to Option B.

---

## SAM Template Changes

### Environment Template (`activity-environment/template.yaml`)

New resources:
- `CognitoUserPool` -- user pool with admin-only creation
- `CognitoUserPoolDomain` -- hosted UI domain
- `CognitoResourceServer` -- defines `read`, `write`, `follow`, `push` scopes

New exports:
- `UserPoolId`
- `UserPoolArn`
- `UserPoolDomain` (the full hosted UI URL)

### App Template (`activity-app/template.yaml`)

New parameters:
- None (imports from environment stack)

New resources:
- `CognitoAuthorizer` -- API Gateway authorizer for ClientApi
- `OAuthAppsFunction` -- Lambda for `POST /api/v1/apps`
- `OAuthAuthorizeFunction` -- Lambda for `GET /oauth/authorize`
- `OAuthTokenFunction` -- Lambda for `POST /oauth/token`
- `OAuthRevokeFunction` -- Lambda for `POST /oauth/revoke`
- `ClientApiFunction` -- Lambda for all read-only Mastodon API endpoints

New IAM policies:
- `OAuthAppsFunction` needs `cognito-idp:CreateUserPoolClient`, `cognito-idp:DescribeUserPoolClient`, plus DynamoDB write for app registration
- `OAuthTokenFunction` needs outbound HTTPS to Cognito domain
- `ClientApiFunction` needs DynamoDB read

Modified resources:
- `PostFunction`, `MediaUploadFunction`, `ProfileUpdateFunction` -- switch from no authorizer to `CognitoAuthorizer`. Remove SSM token read policy (or keep for migration period).

### New Lambda Handlers

| Handler | Source Path | Routes | IAM |
|---|---|---|---|
| OAuthAppsHandler | `Sources/OAuthAppsHandler/main.swift` | `POST /api/v1/apps` | DynamoDB write, `cognito-idp:CreateUserPoolClient` |
| OAuthAuthorizeHandler | `Sources/OAuthAuthorizeHandler/main.swift` | `GET /oauth/authorize` | DynamoDB read |
| OAuthTokenHandler | `Sources/OAuthTokenHandler/main.swift` | `POST /oauth/token` | Outbound HTTPS |
| OAuthRevokeHandler | `Sources/OAuthRevokeHandler/main.swift` | `POST /oauth/revoke` | Outbound HTTPS |
| ClientApiHandler | `Sources/ClientApiHandler/main.swift` | All Tier 2-4 GET endpoints | DynamoDB read |

---

## Auth Migration Path

### Phase 6a: Add Cognito (parallel auth)

1. Deploy Cognito User Pool + domain.
2. Create Cognito users for existing actors via CLI.
3. Deploy OAuth endpoints and ClientApiHandler.
4. Add `CognitoAuthorizer` to new endpoints only.
5. Existing PostHandler/MediaUploadHandler/ProfileUpdateHandler continue using SSM bearer tokens.

### Phase 6b: Switch write endpoints to Cognito

1. Add `CognitoAuthorizer` to PostHandler/MediaUploadHandler/ProfileUpdateHandler.
2. Update handler code to extract username from JWT claims instead of SSM lookup.
3. Keep SSM bearer auth as fallback (check JWT first, fall back to SSM if no authorizer context).

### Phase 6c: Remove SSM bearer tokens

1. Remove SSM bearer auth code from all handlers.
2. Remove SSM token read policies.
3. Remove client-token SSM parameters.

### Extracting Username from JWT

In Phase 6b, handlers switch from:
```swift
let authResult = try await authenticateBearer(
    authHeader: authHeader,
    ssmKeyPrefix: ssmKeyPrefix,
    ssmClient: ssmClient
)
let username = authResult.username
```

To:
```swift
// API Gateway Cognito Authorizer populates requestContext.authorizer
let username = event.requestContext.authorizer?["cognito:username"] as? String
    ?? event.requestContext.authorizer?["claims"]?["cognito:username"] as? String
```

The exact path depends on how SAM wires the Cognito authorizer claims into the API Gateway event. This needs to be validated during implementation by inspecting the actual event payload.

---

## CLI User Management

### Creating a Cognito User (via ActivityProvisioner or standalone script)

```bash
# Create user in Cognito (no email, no phone, password set by admin)
aws cognito-idp admin-create-user \
  --user-pool-id $USER_POOL_ID \
  --username randomforms \
  --temporary-password "TempPass123!" \
  --message-action SUPPRESS

# Set permanent password (skip the forced change flow)
aws cognito-idp admin-set-user-password \
  --user-pool-id $USER_POOL_ID \
  --username randomforms \
  --password "PermanentSecurePassword123" \
  --permanent

# Link to existing actor (add custom attribute)
aws cognito-idp admin-update-user-attributes \
  --user-pool-id $USER_POOL_ID \
  --username randomforms \
  --user-attributes Name=preferred_username,Value=randomforms
```

This should be wrapped in the existing `ActivityProvisioner` CLI tool as a `create-login` subcommand, or in a new `activity-auth` CLI tool. The CLI should:

1. Accept username and password as arguments.
2. Validate the actor exists in DynamoDB.
3. Create the Cognito user.
4. Set the permanent password.
5. Output confirmation.

---

## OpenAPI Spec Additions

The following paths and schemas are added to `openapi.yaml`. The spec is designed before implementation begins.

### New Paths

```yaml
# OAuth2 endpoints
/api/v1/apps:
  post:
    operationId: createApp
    summary: Register a client application
    tags: [oauth]
    requestBody:
      required: true
      content:
        application/json:
          schema:
            $ref: "#/components/schemas/CreateAppRequest"
        application/x-www-form-urlencoded:
          schema:
            $ref: "#/components/schemas/CreateAppRequest"
    responses:
      "200":
        description: Application registered
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/Application"

/oauth/authorize:
  get:
    operationId: oauthAuthorize
    summary: Redirect to authorization page
    tags: [oauth]
    parameters:
      - name: client_id
        in: query
        required: true
        schema:
          type: string
      - name: redirect_uri
        in: query
        required: true
        schema:
          type: string
      - name: response_type
        in: query
        required: true
        schema:
          type: string
          enum: [code]
      - name: scope
        in: query
        schema:
          type: string
          default: "read"
    responses:
      "302":
        description: Redirect to Cognito Hosted UI

/oauth/token:
  post:
    operationId: oauthToken
    summary: Obtain an access token
    tags: [oauth]
    requestBody:
      required: true
      content:
        application/x-www-form-urlencoded:
          schema:
            $ref: "#/components/schemas/OAuthTokenRequest"
    responses:
      "200":
        description: Access token
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/OAuthToken"

/oauth/revoke:
  post:
    operationId: oauthRevoke
    summary: Revoke an access token
    tags: [oauth]
    requestBody:
      required: true
      content:
        application/x-www-form-urlencoded:
          schema:
            type: object
            properties:
              client_id:
                type: string
              client_secret:
                type: string
              token:
                type: string
    responses:
      "200":
        description: Token revoked

# Account endpoints
/api/v1/accounts/verify_credentials:
  get:
    operationId: verifyCredentials
    summary: Verify account credentials and return the authenticated user
    tags: [client]
    security:
      - bearerAuth: []
    responses:
      "200":
        description: The authenticated account
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/CredentialAccount"

/api/v1/accounts/{id}:
  get:
    operationId: getAccount
    summary: Get account by ID
    tags: [client]
    parameters:
      - name: id
        in: path
        required: true
        schema:
          type: string
    responses:
      "200":
        description: Account entity
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/Account"
      "404":
        description: Account not found

/api/v1/accounts/{id}/statuses:
  get:
    operationId: getAccountStatuses
    summary: Get statuses posted by an account
    tags: [client]
    parameters:
      - name: id
        in: path
        required: true
        schema:
          type: string
      - name: max_id
        in: query
        schema:
          type: string
      - name: since_id
        in: query
        schema:
          type: string
      - name: min_id
        in: query
        schema:
          type: string
      - name: limit
        in: query
        schema:
          type: integer
          default: 20
          maximum: 40
      - name: only_media
        in: query
        schema:
          type: boolean
      - name: exclude_replies
        in: query
        schema:
          type: boolean
      - name: exclude_reblogs
        in: query
        schema:
          type: boolean
      - name: pinned
        in: query
        schema:
          type: boolean
    responses:
      "200":
        description: Array of statuses
        content:
          application/json:
            schema:
              type: array
              items:
                $ref: "#/components/schemas/Status"

# Timeline endpoints
/api/v1/timelines/home:
  get:
    operationId: getHomeTimeline
    summary: View home timeline
    tags: [client]
    security:
      - bearerAuth: []
    parameters:
      - name: max_id
        in: query
        schema:
          type: string
      - name: since_id
        in: query
        schema:
          type: string
      - name: min_id
        in: query
        schema:
          type: string
      - name: limit
        in: query
        schema:
          type: integer
          default: 20
          maximum: 40
    responses:
      "200":
        description: Array of statuses
        content:
          application/json:
            schema:
              type: array
              items:
                $ref: "#/components/schemas/Status"

# Notification endpoints
/api/v1/notifications:
  get:
    operationId: getNotifications
    summary: Get notifications
    tags: [client]
    security:
      - bearerAuth: []
    parameters:
      - name: max_id
        in: query
        schema:
          type: string
      - name: since_id
        in: query
        schema:
          type: string
      - name: min_id
        in: query
        schema:
          type: string
      - name: limit
        in: query
        schema:
          type: integer
          default: 15
          maximum: 30
      - name: types[]
        in: query
        schema:
          type: array
          items:
            type: string
      - name: exclude_types[]
        in: query
        schema:
          type: array
          items:
            type: string
    responses:
      "200":
        description: Array of notifications
        content:
          application/json:
            schema:
              type: array
              items:
                $ref: "#/components/schemas/Notification"
```

### New Schemas

```yaml
CreateAppRequest:
  type: object
  required: [client_name, redirect_uris]
  properties:
    client_name:
      type: string
    redirect_uris:
      type: string
      description: Space-separated list of redirect URIs
    scopes:
      type: string
      default: "read"
    website:
      type: string

Application:
  type: object
  properties:
    id:
      type: string
    name:
      type: string
    website:
      type: string
    redirect_uri:
      type: string
    client_id:
      type: string
    client_secret:
      type: string
    vapid_key:
      type: string
      description: Empty string (push notifications not implemented)

OAuthTokenRequest:
  type: object
  required: [grant_type]
  properties:
    grant_type:
      type: string
      enum: [authorization_code, client_credentials, refresh_token]
    code:
      type: string
    client_id:
      type: string
    client_secret:
      type: string
    redirect_uri:
      type: string
    refresh_token:
      type: string
      description: Required when grant_type is refresh_token
    scope:
      type: string

OAuthToken:
  type: object
  properties:
    access_token:
      type: string
    token_type:
      type: string
      enum: [Bearer]
    scope:
      type: string
    created_at:
      type: integer
      description: Unix timestamp

CredentialAccount:
  allOf:
    - $ref: "#/components/schemas/Account"
    - type: object
      properties:
        source:
          type: object
          properties:
            privacy:
              type: string
              enum: [public, unlisted, private, direct]
            sensitive:
              type: boolean
            language:
              type: string
            note:
              type: string
              description: Plain text bio (before HTML conversion)
            fields:
              type: array
              items:
                $ref: "#/components/schemas/ProfileField"

Notification:
  type: object
  properties:
    id:
      type: string
    type:
      type: string
      enum: [mention, status, reblog, follow, follow_request, favourite, poll, update]
    created_at:
      type: string
      format: date-time
    account:
      $ref: "#/components/schemas/Account"
    status:
      $ref: "#/components/schemas/Status"
```

---

## Cognito Hosted UI -- User Experience Considerations

The Cognito Hosted UI is functional but visually basic. For Phase 6, this is acceptable because:

1. There is no user registration -- the only people who see the login page are the operator and any provisioned users.
2. The Cognito hosted UI supports custom CSS, so it can be branded later.
3. A fully custom authorize page (Lambda-rendered HTML) is an option for Phase 7 if the Cognito UI proves insufficient.

Cognito Hosted UI supports:
- Custom logo
- Custom CSS
- Custom domain (via ACM certificate)

It does NOT support:
- Arbitrary HTML changes (limited to logo, CSS, text strings)
- Passkey/WebAuthn (as of 2026-03 -- Cognito supports TOTP MFA but not passwordless WebAuthn)

---

## Portability Considerations

1. **All Cognito resources are parameterized** -- User Pool name, domain prefix, resource server identifier use `!Sub` with Stage and ServerDomain parameters.
2. **No happitec-specific values in code** -- Domain, user pool ID, and Cognito domain are passed as environment variables.
3. **SAM parameters for all config** -- A fork only needs to set their own `ServerDomain`, `HandleDomain`, and deploy the environment stack to get a working Cognito User Pool.
4. **Cognito is AWS-native** -- This is consistent with the project's AWS-only infrastructure stance (Lambda, DynamoDB, SQS, S3, CloudFront). Moving off AWS would require replacing Cognito along with everything else.
5. **The OAuth2 flow is standard** -- If someone wanted to swap Cognito for another OAuth2 provider (Auth0, Keycloak), the Lambda handlers would need updating but the API contract (Mastodon-compatible OAuth2) stays the same.

---

## Implementation Order

### Sprint 1: OAuth2 Foundation
1. Add Cognito resources to environment template.
2. Create `OAuthAppsHandler` Lambda.
3. Create `OAuthAuthorizeHandler` Lambda (redirect to Cognito).
4. Create `OAuthTokenHandler` Lambda (proxy to Cognito).
5. Create `OAuthRevokeHandler` Lambda.
6. Create Cognito user for one test actor via CLI.
7. Test: Register an app, get an auth code, exchange for token.

### Sprint 2: Core Client Endpoints
1. Create `ClientApiHandler` Lambda with path-based routing.
2. Implement `verify_credentials` (critical -- first thing after login).
3. Implement stub endpoints (custom_emojis, filters, preferences, announcements, lists, conversations).
4. Implement `GET /api/v1/accounts/:id` and `GET /api/v1/accounts/:id/statuses`.
5. Test: Ivory can log in and see the profile page.

### Sprint 3: Timeline and Notifications
1. Implement `GET /api/v1/timelines/home`.
2. Implement `GET /api/v1/notifications`.
3. Implement `GET /api/v1/markers` and `POST /api/v1/markers`.
4. Implement `GET /api/v1/statuses/:id` and `GET /api/v1/statuses/:id/context`.
5. Test: Ivory shows the home timeline and notifications tab.

### Sprint 4: Write Endpoint Migration
1. Add `CognitoAuthorizer` to PostHandler, MediaUploadHandler, ProfileUpdateHandler.
2. Update handlers to extract username from JWT claims.
3. Test: Post from Ivory, upload media from Ivory, update profile from Ivory.
4. Remove SSM bearer token fallback.

---

## Risks and Mitigations

### R1: Cognito Hosted UI too limited for Ivory's OAuth flow
**Risk:** Ivory may expect specific OAuth2 behaviors (e.g., PKCE, specific error formats) that Cognito's hosted UI does not support.
**Mitigation:** Cognito supports PKCE (S256). If the hosted UI is insufficient, replace `/oauth/authorize` with a custom Lambda-rendered HTML page that posts credentials to Cognito's `InitiateAuth` API directly. This is more work but gives full control.

### R2: Cognito JWT format incompatible with client expectations
**Risk:** Some Mastodon clients may inspect the token format (e.g., expect opaque tokens vs JWTs).
**Mitigation:** Mastodon's OAuth2 spec does not mandate token format. Clients should treat tokens as opaque strings. If a client misbehaves, the `OAuthTokenHandler` can wrap the JWT in a DynamoDB-stored opaque token with a lookup table.

### R3: Cold start latency on OAuth Lambdas
**Risk:** The OAuth flow involves multiple Lambda invocations (apps, authorize, token). If all are cold, the user waits 6-9 seconds.
**Mitigation:** The authorize redirect is fast (no DynamoDB, just a 302). The token exchange is the most latency-sensitive; consider provisioned concurrency for `OAuthTokenHandler` in production.

### R4: Scope translation complexity
**Risk:** Mastodon uses simple scopes (`read`, `write`, `follow`). Cognito uses resource-server-prefixed scopes (`https://domain/api/read`). Translation bugs could cause auth failures.
**Mitigation:** Centralize scope translation in a shared utility in ActivityPubCore. Test exhaustively with multiple clients.

### R5: Dynamic client registration abuse
**Risk:** Anyone can call `POST /api/v1/apps` and create Cognito app clients. At scale, this could hit Cognito limits (10,000 app clients per user pool by default).
**Mitigation:** Rate-limit `/api/v1/apps` aggressively (1 req/min per IP via API Gateway throttling). Monitor Cognito app client count. Clean up unused clients periodically (DynamoDB TTL on app registrations with last-used tracking).

---

## Open Questions for User Input

**Q1: Cognito custom domain?** Should we use a custom domain for the Cognito hosted UI (e.g., `auth.activity.happitec.com`) or the default Cognito domain (`auth-stage-activity.auth.us-east-1.amazoncognito.com`)? Custom domain requires an ACM certificate in us-east-1 and a CNAME record. The default domain works immediately but looks less polished. Recommendation: start with the default domain; add custom domain if the redirect URL causes issues with any clients.

**Q2: Password policy for CLI-provisioned users?** The spec proposes 16-character minimum with uppercase + lowercase + numbers. Should this be stricter or more relaxed given that accounts are admin-provisioned only?

**Q3: Scope enforcement granularity?** Should we actually enforce scopes (e.g., a token with only `read` scope cannot POST to `/api/v1/statuses`), or just validate the token and ignore scopes? Recommendation: enforce scopes from the start; it is easier to build correctly than to retrofit.

**Q4: Migration timeline for existing SSM bearer tokens?** How long should the dual-auth period last? Recommendation: keep SSM fallback for 2 weeks after OAuth2 deployment, then remove.
