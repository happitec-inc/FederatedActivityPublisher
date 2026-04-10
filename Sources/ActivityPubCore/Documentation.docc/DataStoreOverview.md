# Data Store

How FederatedActivityPublisher persists actors, statuses, followers, and media metadata in DynamoDB.

## Overview

All persistent state lives in a single DynamoDB table using a single-table design. The ``DynamoDBStore`` struct is the sole interface to this table, providing typed methods for reading and writing every entity in the system.

### Single-Table Design

Rather than creating a separate table for each entity type, the server stores actors, statuses, followers, remote actors, and delivery jobs in one table differentiated by partition key prefixes. This keeps the CloudFormation footprint minimal and allows DynamoDB's on-demand billing to scale from zero cost at rest to whatever throughput is needed during activity spikes.

The primary entity types stored in the table are:

- **Actors** (`ACTOR#<username>`) -- local accounts with their display name, summary, avatar URL, keypair reference, and profile fields
- **Statuses** (`ACTOR#<username>`, `STATUS#<id>`) -- posts authored by local actors, including content HTML, visibility, media attachment references, and reply metadata
- **Followers** -- records linking a remote actor's inbox URL to a local actor, created when a Follow is accepted
- **Remote Actors** -- cached copies of remote actor documents fetched during signature verification, avoiding repeated HTTP lookups
- **Bearer Tokens** (`TOKEN#<sha256-hash>`) -- per-account authentication tokens for the client API. The raw token is never stored; only its SHA-256 hash appears as the partition key. Each record includes the username, scope, creation timestamp, and an optional TTL for automatic expiry via DynamoDB's TTL mechanism
- **Registration Tokens** (`REGISTRATION_TOKEN#<token>`) -- short-lived tokens (15-minute TTL) used during the web registration flow

### Timestamps and Ordering

All timestamps are stored as ISO 8601 strings using ``iso8601Formatter``. Statuses use a sort key that orders them reverse-chronologically so that outbox queries return the most recent posts first without requiring a scan.
