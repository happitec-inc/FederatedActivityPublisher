# ``ActivityPubCore``

A serverless ActivityPub federation server for happitec-inc brand accounts, built with Swift and deployed on AWS Lambda.

@Metadata {
    @DisplayName("FederatedActivityPublisher")
}

## Overview

FederatedActivityPublisher is a multi-account ActivityPub server running entirely on AWS serverless infrastructure. The `ActivityPubCore` module is the shared library that powers `activity.happitec.com`, hosting brand accounts for happitec-inc apps and federating with Mastodon, GoToSocial, Misskey, and other ActivityPub-compatible servers.

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

### Getting Started

- <doc:GettingStarted>
- <doc:DeployYourOwn>
- <doc:BuildingAndDeploying>
- <doc:ArchitectureOverview>
- <doc:DNSSetup>

### Operations

- <doc:ProvisioningAccounts>
- <doc:AWSPermissions>
- <doc:CostEstimates>

### HTML Rendering

- <doc:HTMLRendering>

### Data Store

- <doc:DataStoreOverview>
- ``DynamoDBStore``
- ``iso8601Formatter``

### Authentication and Cryptography

- <doc:AuthenticationOverview>
- ``HTTPSignature``
- ``KeyManager``
- ``KeyManagerError``
- ``BearerAuthResult``
- ``BearerAuthError``
- ``authenticateBearer(authHeader:ssmKeyPrefix:ssmClient:)``

### Content Processing

- <doc:HTMLProcessingOverview>
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

### Federation Serialization

- <doc:FederationOverview>
- <doc:QuoteSupport>
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

### Media

- <doc:MediaOverview>
- ``extractBoundary(from:)``
- ``parseMultipart(data:boundary:)``

### JSON Utilities

- ``escapeJSON(_:)``
- ``jsonString(_:)``
- ``jsonArray(_:)``
