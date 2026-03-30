# ``ActivityPubCore``

A serverless ActivityPub federation server for happitec-inc brand accounts, built with Swift and deployed on AWS Lambda.

@Metadata {
    @DisplayName("ActivityPubCore")
}

## Overview

ActivityPubCore is the shared library powering `activity.happitec.com`, a multi-account ActivityPub server running entirely on AWS serverless infrastructure. It hosts brand accounts for happitec-inc apps (e.g. `@randomforms@happitec.com`, `@wishyouwerehere@happitec.com`) and federates with Mastodon, GoToSocial, Misskey, and other ActivityPub-compatible servers.

The server is designed for zero cost at rest -- you only pay when posting or receiving traffic. All compute runs on AWS Lambda, data lives in DynamoDB, media is stored in S3 and served through CloudFront, and delivery fan-out uses SQS.

### Key Features

- Multi-account support with per-actor RSA keypairs
- Full federation: follow, accept, create, like, boost, reply, delete, update
- Media attachments (images, video, audio) with S3 storage and CloudFront CDN
- HTTP Signature signing and verification (Cavage draft)
- Cache-until-invalidated CloudFront strategy for near-zero compute on reads
- Bearer token authentication for the client posting API
- HTML sanitization for inbound content

### Architecture at a Glance

The system uses a three-template SAM architecture:

- **Bootstrap** -- Route 53 hosted zone and ACM wildcard certificate (deployed once)
- **Environment** -- DynamoDB table, SQS queues, S3 media bucket, SSM key prefix (per stage)
- **App** -- All Lambda functions, API Gateways, and CloudFront distribution (per stage)

See <doc:ArchitectureOverview> for detailed diagrams.

## Topics

### Guides

- <doc:GettingStarted>
- <doc:BuildingAndDeploying>
- <doc:ProvisioningAccounts>
- <doc:ArchitectureOverview>
- <doc:AWSPermissions>
- <doc:CostEstimates>

### Data Store

- ``DynamoDBStore``
- ``iso8601Formatter``

### Authentication and Cryptography

- ``HTTPSignature``
- ``KeyManager``
- ``KeyManagerError``
- ``BearerAuthResult``
- ``BearerAuthError``
- ``authenticateBearer(authHeader:ssmKeyPrefix:ssmClient:)``

### Content Processing

- ``HTMLSanitizer``

### Delivery

- ``SQSDeliveryClient``
- ``SQSDeliveryError``

### Models

- ``Actor``
- ``Status``
- ``Follower``
- ``RemoteActor``
- ``DeliveryJob``
- ``CreateStatusRequest``
- ``OrderedCollection``
- ``WebFingerResponse``
- ``WebFingerLink``
- ``Tag``
- ``MediaAttachmentRef``
- ``MultipartPart``
- ``ProfileField``

### Serialization

- ``buildActorJSONLD(actor:serverDomain:handleDomain:)``
- ``buildNoteJSON(status:serverDomain:username:)``
- ``buildCreateActivityJSON(status:noteJSON:serverDomain:username:)``
- ``computeAddressing(visibility:serverDomain:username:)``

### Text Processing

- ``convertTextToHTML(_:)``
- ``formatFieldValueForActivityPub(_:)``
- ``formatFieldValueForAPI(_:)``
- ``parseProfileFields(_:)``
- ``encodeProfileFields(_:)``

### Multipart Parsing

- ``extractBoundary(from:)``
- ``parseMultipart(data:boundary:)``

### JSON Utilities

- ``escapeJSON(_:)``
- ``jsonString(_:)``
- ``jsonArray(_:)``
