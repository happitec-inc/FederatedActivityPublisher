# Provisioning a New Account

This guide covers creating a new ActivityPub actor account from scratch, verifying it works, and setting up automated posting.

## Step 1: Provision the actor

Provisioning is done with the `ActivityProvisioner` CLI, run locally (requires Swift 6.3 and AWS credentials with DynamoDB and SSM write access). `provision` is the default subcommand, so it may be omitted:

```bash
swift run ActivityProvisioner \
  --stage prod \
  --username dailydigest \
  --display-name "Daily Digest" \
  --summary "Posts a daily summary" \
  --server-domain {{SERVER_DOMAIN}} \
  --handle-domain {{HANDLE_DOMAIN}}
```

This creates:
- A 2048-bit RSA keypair (private key stored in SSM at `/activity/{stage}/keys/{username}`)
- An actor record in DynamoDB with the profile, inbox/outbox URLs, and public key

Minting the bearer token is a separate CLI step (see Step 3). This repository is public, so token issuance never runs in CI.

## Step 2: Verify the actor

After provisioning, verify the actor is accessible:

```bash
# WebFinger (replace domain and username)
curl -s "https://{{SERVER_DOMAIN}}/.well-known/webfinger?resource=acct:dailydigest@{{HANDLE_DOMAIN}}" | jq .

# Actor JSON-LD
curl -s -H "Accept: application/activity+json" "https://{{SERVER_DOMAIN}}/users/dailydigest" | jq .id

# HTML profile page
curl -s -o /dev/null -w "%{http_code}" "https://{{SERVER_DOMAIN}}/@dailydigest"
```

CloudFront caching may delay visibility by up to an hour. If you get 404s, wait and retry.

## Step 3: Mint the bearer token

Mint a token with the `mint-token` subcommand. The raw token is printed to your terminal once and, with `--out`, also written to the named file. Only its SHA-256 hash is stored in DynamoDB, so the raw token cannot be retrieved later.

```bash
swift run ActivityProvisioner mint-token \
  --stage prod \
  --username dailydigest \
  --out token.txt
chmod 600 token.txt
```

The defaults are `--scope "read write"` and `--ttl-days 365`. Each account gets its own independent token, and provisioning a new actor does not affect existing accounts' tokens. See <doc:ManagingActorsAndTokens> for listing, rotating, and revoking tokens.

## Step 4: Test posting

Post a test status:

```bash
TOKEN="your-bearer-token-here"
API_URL="https://your-client-api-domain.execute-api.us-east-1.amazonaws.com/prod"

curl -X POST "$API_URL/api/v1/statuses" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status": "Hello from my new account!", "visibility": "public"}'
```

The `API_URL` is the Client API Gateway URL, not the CloudFront domain. Find it in the stack outputs:

```bash
aws cloudformation describe-stacks \
  --stack-name activity-app-prod \
  --query "Stacks[0].Outputs[?OutputKey=='ClientApiUrl'].OutputValue" \
  --output text --region us-east-1
```

Or, if the same-origin CloudFront routing is configured, you can post through the CloudFront domain:

```bash
curl -X POST "https://{{SERVER_DOMAIN}}/api/v1/statuses" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status": "Hello!", "visibility": "public"}'
```

## Step 5: Post with an image

Upload an image first, then reference it in the post:

```bash
# Upload image
MEDIA_RESPONSE=$(curl -s -X POST "$API_URL/api/v2/media" \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@/path/to/image.png;type=image/png" \
  -F "description=Alt text for the image")

MEDIA_ID=$(echo "$MEDIA_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")

# Post with image
curl -X POST "$API_URL/api/v1/statuses" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"status\": \"Check out this image!\", \"media_ids\": [\"$MEDIA_ID\"], \"visibility\": \"public\"}"
```

## Sample cron script

Here's a template for an automated posting bot. Save as `post.sh` and add to crontab.

```bash
#!/bin/bash
set -euo pipefail

# Config — edit these
API_URL="https://your-client-api-domain.execute-api.us-east-1.amazonaws.com/prod"
TOKEN="your-bearer-token"

# Generate your content
POST_TEXT="Automated post at $(date '+%Y-%m-%d %H:%M')"

# Post
RESPONSE=$(curl -s -X POST "$API_URL/api/v1/statuses" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"status\": \"$POST_TEXT\", \"visibility\": \"public\"}")

POST_URL=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('url','UNKNOWN'))" 2>/dev/null)
echo "$(date '+%Y-%m-%d %H:%M:%S') Posted: $POST_URL"
```

Add to crontab (e.g. every hour):

```bash
0 * * * * /path/to/post.sh >> /path/to/post.log 2>&1
```

## Updating the profile later

Update display name, bio, avatar, or header:

```bash
# Update display name and bio
curl -X PATCH "$API_URL/api/v1/accounts/update_credentials" \
  -H "Authorization: Bearer $TOKEN" \
  -F "display_name=New Display Name" \
  -F "note=Updated bio text"

# Update avatar
curl -X PATCH "$API_URL/api/v1/accounts/update_credentials" \
  -H "Authorization: Bearer $TOKEN" \
  -F "avatar=@/path/to/avatar.png;type=image/png"
```
