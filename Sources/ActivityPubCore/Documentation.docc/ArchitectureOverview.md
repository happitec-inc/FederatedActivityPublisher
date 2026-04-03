# Architecture Overview

The nested stack architecture, request flows, and domain consolidation strategy.

## Overview

The server is split into three AWS SAM templates with different lifecycles. The app template itself uses nested CloudFormation stacks -- a root orchestrator delegates to a functions stack and a CDN stack. This article covers the full architecture with diagrams showing how requests flow through the system.

See <doc:NestedStacksOverview> for details on why the app stack is split into nested stacks and how the fast-deploy pipeline works.

### Stack Architecture

```mermaid
flowchart TB
    subgraph "Internet"
        FED["Remote Fediverse Servers"]
        AUTHOR["Author<br/>(REST client / Mastodon app)"]
    end

    subgraph "activity-bootstrap (shared, manual deploy)"
        R53["Route 53<br/>Hosted Zone<br/>activity.happitec.com"]
        ACM["ACM<br/>*.activity.happitec.com + apex"]
    end

    subgraph "activity-environment-{stage}"
        S3["S3 Media Bucket<br/>(private, zero public access)"]
        DDB["DynamoDB<br/>(on-demand, single-table)"]
        SQS["SQS<br/>(delivery queue + DLQ)"]
        SM["SSM Parameter Store<br/>RSA Keypairs"]
    end

    subgraph "activity-app-{stage} (root orchestrator)"
        subgraph "CdnStack (cdn/template.yaml)"
            CF["CloudFront<br/>(OAC for S3, cache-until-invalidated)"]
        end
        subgraph "FunctionsStack (functions/template.yaml)"
            APIGW_S["API Gateway<br/>(federation)"]
            NI["nodeinfo"]
            WF["webfinger"]
            ACTOR["actor"]
            OBJECT["object"]
            INBOX["inbox"]
            OUTBOX["outbox"]
            FOLLOWERS["followers"]
            FOLLOWING["following"]
            FEATURED["featured"]
            FEATUREDTAGS["featuredTags"]
            PROFILE["profile<br/>(HTML pages)"]
            DELIVER["deliver<br/>(SQS consumer)"]
            APIGW_C["API Gateway<br/>(client, authed)"]
            POST["post"]
            MEDIA["media-upload"]
            PROFILE_UPDATE["profile-update"]
        end
    end

    FED -->|"GET /.well-known/webfinger"| CF
    FED -->|"GET /users/:name"| CF
    FED -->|"POST /users/:name/inbox"| APIGW_S

    AUTHOR -->|"POST /api/v1/statuses"| APIGW_C
    AUTHOR -->|"POST /api/v2/media"| APIGW_C

    CF -->|"OAC (read-only)"| S3
    CF --> APIGW_S
    APIGW_S --> NI
    APIGW_S --> WF
    APIGW_S --> ACTOR
    APIGW_S --> OBJECT
    APIGW_S --> INBOX
    APIGW_S --> OUTBOX
    APIGW_S --> FOLLOWERS
    APIGW_S --> FOLLOWING
    APIGW_S --> FEATURED
    APIGW_S --> FEATUREDTAGS
    APIGW_S --> PROFILE

    WF --> DDB
    ACTOR --> DDB
    OBJECT --> DDB
    INBOX --> DDB
    INBOX --> SQS
    OUTBOX --> DDB
    FOLLOWERS --> DDB
    FOLLOWING --> DDB
    FEATURED --> DDB
    FEATUREDTAGS --> DDB
    PROFILE --> DDB

    SQS --> DELIVER
    DELIVER --> DDB
    DELIVER --> SM
    DELIVER -->|"Signed HTTP POST"| FED

    APIGW_C --> POST
    APIGW_C --> MEDIA
    APIGW_C --> PROFILE_UPDATE
    POST --> DDB
    POST --> SQS
    POST -.->|"CloudFront invalidation"| CF
    MEDIA -->|"PutObject (write-only)"| S3
    MEDIA --> DDB
```

### Request Flow: Posting a Status

When an author posts content through the client API, the status is written to DynamoDB, delivery jobs are enqueued to SQS for each follower, and the CloudFront cache is invalidated so the outbox reflects the new post.

```mermaid
sequenceDiagram
    participant U as Author
    participant CG as Client API Gateway
    participant P as post Lambda
    participant DB as DynamoDB
    participant Q as SQS
    participant CF as CloudFront
    participant D as deliver Lambda
    participant SM as SSM Parameter Store
    participant R as Remote Server

    U->>CG: POST /api/v1/statuses {text, media_ids}
    CG->>P: Invoke
    P->>DB: Write Status record
    P->>DB: Read follower inbox URLs
    P->>Q: Enqueue delivery jobs
    P->>CF: CreateInvalidation /users/{name}/outbox*
    P-->>U: 200 Status JSON

    Q->>D: Delivery job {status_id, inbox_url}
    D->>DB: Read status + follower record
    D->>SM: Read actor private key
    D->>D: Build Create-Note, sign with HTTP Signatures
    D->>R: POST /inbox (signed)
    R-->>D: 202 Accepted
```

### Request Flow: Receiving a Follow

When a remote server sends a Follow activity, the inbox Lambda verifies the HTTP Signature, stores the follower record, and enqueues an Accept delivery.

```mermaid
sequenceDiagram
    participant R as Remote Server
    participant CF as CloudFront
    participant APIGW as Server API Gateway
    participant I as inbox Lambda
    participant DB as DynamoDB
    participant Q as SQS
    participant D as deliver Lambda

    R->>CF: POST /users/randomforms/inbox {Follow}
    CF->>APIGW: Pass through (POST, no cache)
    APIGW->>I: Invoke
    I->>I: Verify HTTP Signature (fetch remote actor key)
    I->>DB: Store follower record
    I->>Q: Enqueue Accept-Follow delivery
    I-->>R: 202 Accepted

    Q->>D: Deliver Accept
    D->>R: POST /inbox {Accept-Follow} (signed)
```

### Request Flow: Media Upload

Media uploads flow through the Lambda -- the client never gets a presigned URL or direct S3 access. The bucket remains completely dark to the public internet.

```mermaid
sequenceDiagram
    participant U as Author
    participant CG as Client API Gateway
    participant M as media-upload Lambda
    participant S3 as S3 Media Bucket
    participant DB as DynamoDB

    U->>CG: POST /api/v2/media (multipart)
    CG->>M: Invoke (body passthrough)
    M->>M: Validate content type, generate media ID
    M->>S3: PutObject (write-only IAM)
    M->>DB: Write media metadata
    M-->>U: 200 {id, type, url, preview_url}
```

### Domain Consolidation

The happitec.com apex domain has its own CloudFront distribution that serves the main website. ActivityPub federation endpoints live at `activity.happitec.com` with a separate CloudFront distribution. WebFinger discovery is delegated from `happitec.com` to `activity.happitec.com` so that handles like `@randomforms@happitec.com` resolve correctly.

The client API (for posting and media uploads) runs on a separate API Gateway domain, not behind CloudFront. This keeps the public-facing CDN purely read-only.

### CloudFront Cache Strategy

The server uses a cache-until-invalidated strategy. Between posts, all federation reads are served from the CloudFront edge at zero compute cost.

| Path Pattern | TTL | Invalidation Trigger |
|---|---|---|
| `/.well-known/nodeinfo`, `/nodeinfo/*` | 24h | Actor create/delete |
| `/.well-known/webfinger*` | 24h | Actor create/delete |
| `/users/*/outbox*` | 365d | New post |
| `/users/*/statuses/*` | 365d | Post edit/delete |
| `/users/*` (actor profile) | 24h | Profile update |
| `/users/*/followers*` | 1h | Follow/unfollow |
| `/media/*` | 365d (immutable) | Never |
| `POST /users/*/inbox` | No cache | -- |
