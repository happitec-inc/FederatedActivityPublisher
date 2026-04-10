# Provisioning Accounts

Create and configure ActivityPub actor accounts using the CLI.

## Overview

Accounts are not self-service -- they are provisioned via the `ActivityProvisioner` CLI tool. This tool generates RSA keypairs, stores them in SSM Parameter Store, and seeds the actor profile in DynamoDB.

### Prerequisites

- The environment stack must be deployed (DynamoDB table and SSM key prefix must exist)
- AWS credentials configured with permissions for DynamoDB writes and SSM SecureString parameter creation
- The `ActivityProvisioner` binary built locally (not as a Lambda -- it runs on your machine or a CI runner)

### Building the CLI

```bash
swift build --product ActivityProvisioner
```

### Creating an Actor

The provisioner creates the actor's DynamoDB profile record and generates an RSA keypair stored as a SecureString in SSM Parameter Store:

```bash
.build/debug/ActivityProvisioner create \
  --username randomforms \
  --display-name "Random Forms" \
  --summary "Official account for the Random Forms app." \
  --stage prod
```

This will:

1. Generate a 2048-bit RSA keypair
2. Store the private key at `/activity/prod/keys/randomforms` in SSM Parameter Store (SecureString, KMS-encrypted)
3. Write the actor profile to DynamoDB with the public key PEM embedded
4. Set initial follower/following/status counts to zero

### Setting Up Bearer Tokens

The client posting API (`POST /api/v1/statuses`, `POST /api/v2/media`, `PATCH /api/v1/accounts/update_credentials`) uses bearer token authentication. Tokens are stored as per-account records in DynamoDB, keyed by the SHA-256 hash of the raw token:

```bash
TOKEN=$(openssl rand -hex 32)
TOKEN_HASH=$(echo -n "$TOKEN" | shasum -a 256 | cut -d' ' -f1)
TTL=$(( $(date +%s) + 31536000 ))  # 1 year
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
aws dynamodb put-item \
  --table-name "activity-prod" \
  --item "{
    \"PK\": {\"S\": \"TOKEN#${TOKEN_HASH}\"},
    \"SK\": {\"S\": \"META\"},
    \"username\": {\"S\": \"randomforms\"},
    \"scope\": {\"S\": \"read write\"},
    \"createdAt\": {\"S\": \"${NOW}\"},
    \"ttl\": {\"N\": \"${TTL}\"},
    \"description\": {\"S\": \"manual provisioning\"}
  }" \
  --region us-east-1
echo "Bearer token: $TOKEN"
```

The raw token is never stored -- only its SHA-256 hash appears in DynamoDB. Each account gets its own independent token, so multiple actors can post without interference.

> Note: The Provision Actor workflow (`provision-actor.yml`) handles token creation automatically and displays the raw token in the workflow summary. The manual approach above is only needed when provisioning via CLI.

When calling the client API, include the token in the Authorization header:

```
Authorization: Bearer your-secret-token-here
```

The server looks up the token in DynamoDB first. If not found, it falls back to the legacy SSM parameter at `/activity/{stage}/keys/client-token` for backward compatibility.

### Updating Profile Fields

Profile metadata fields (displayed as key-value pairs on the actor's profile) can be set via the `ProfileUpdateHandler` API endpoint:

```bash
curl -X PATCH \
  -H "Authorization: Bearer your-token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d 'fields_attributes[0][name]=Website&fields_attributes[0][value]=https://example.com' \
  "https://your-client-api-url/api/v1/accounts/update_credentials"
```

URL values are automatically converted to links with `rel="me"` for verification. Avatar and header images can be updated via the same endpoint using `multipart/form-data`.
