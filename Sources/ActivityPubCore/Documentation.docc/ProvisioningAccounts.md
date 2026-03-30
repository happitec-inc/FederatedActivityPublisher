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
  --summary "Official account for the Random Forms app by happitec-inc." \
  --stage prod
```

This will:

1. Generate a 2048-bit RSA keypair
2. Store the private key at `/activity/prod/keys/randomforms` in SSM Parameter Store (SecureString, KMS-encrypted)
3. Write the actor profile to DynamoDB with the public key PEM embedded
4. Set initial follower/following/status counts to zero

### Setting Up Bearer Tokens

The client posting API (`POST /api/v1/statuses`, `POST /api/v2/media`, `PATCH /api/v1/accounts/update_credentials`) uses bearer token authentication. Tokens are stored in SSM Parameter Store in the format `username:token`:

```bash
aws ssm put-parameter \
  --name "/activity/prod/keys/client-token" \
  --type SecureString \
  --value "randomforms:your-secret-token-here"
```

When calling the client API, include the token in the Authorization header:

```
Authorization: Bearer your-secret-token-here
```

The server validates the token against SSM using constant-time comparison to prevent timing attacks.

### Updating Profile Fields

Profile metadata fields (displayed as key-value pairs on the actor's profile) can be set via the `ProfileUpdateHandler` API endpoint:

```bash
curl -X PATCH \
  -H "Authorization: Bearer your-token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d 'fields_attributes[0][name]=Website&fields_attributes[0][value]=https://happitec.com' \
  "https://your-client-api-url/api/v1/accounts/update_credentials"
```

URL values are automatically converted to links with `rel="me"` for verification. Avatar and header images can be updated via the same endpoint using `multipart/form-data`.
