# AGENTS.md — Operating the ActivityPub Server

Guide for creating and managing bot accounts on the happitec.com ActivityPub server.

## Prerequisites

- AWS CLI configured with access to the `us-east-1` region
- The `ActivityProvisioner` CLI built (or access to the Linux runner VM)
- Bearer token stored in SSM for the account you want to post as

## Creating a New Account

### 1. Provision the actor

Run the `ActivityProvisioner` CLI on a machine with AWS credentials. This generates an RSA keypair, stores the private key in SSM, and seeds the actor record in DynamoDB.

```bash
swift run ActivityProvisioner \
  --stage prod \
  --username myapp \
  --display-name "My App" \
  --summary "Official account for My App" \
  --server-domain happitec.com \
  --handle-domain happitec.com
```

This creates:
- DynamoDB actor record at `ACTOR#myapp / PROFILE`
- RSA private key in SSM at `/activity/prod/keys/myapp`
- The actor is immediately discoverable at `@myapp@happitec.com`

### 2. Create a bearer token for posting

Store a bearer token in SSM. The format is `username:token` — the token can be any random string.

```bash
TOKEN=$(openssl rand -hex 32)
aws ssm put-parameter \
  --name "/activity/prod/keys/client-token" \
  --type SecureString \
  --value "myapp:$TOKEN" \
  --overwrite \
  --region us-east-1
echo "Bearer token: $TOKEN"
```

Note: the `/activity/prod/keys/client-token` parameter is shared — it holds credentials for one account at a time. To support multiple accounts posting independently, each needs its own token parameter (requires code changes to support per-account token paths).

### 3. Verify the account

```bash
# WebFinger discovery
curl -s "https://happitec.com/.well-known/webfinger?resource=acct:myapp@happitec.com" | jq .

# Actor JSON-LD
curl -s -H "Accept: application/activity+json" "https://happitec.com/users/myapp" | jq .

# HTML profile page
open "https://happitec.com/@myapp"
```

## Updating a Profile

Use `PATCH /api/v1/accounts/update_credentials` on the client API. All fields are optional — only provided fields are updated.

**API URL:** `https://dwfiioehgc.execute-api.us-east-1.amazonaws.com/prod`

### Update display name and bio

```bash
curl -X PATCH "$API_URL/api/v1/accounts/update_credentials" \
  -H "Authorization: Bearer $TOKEN" \
  -F "display_name=My App" \
  -F "note=The official account for My App. Available on the App Store."
```

The `note` field is plain text — it gets converted to HTML for federation.

### Upload avatar

```bash
curl -X PATCH "$API_URL/api/v1/accounts/update_credentials" \
  -H "Authorization: Bearer $TOKEN" \
  -F "avatar=@/path/to/avatar.png;type=image/png"
```

Accepted formats: `image/png`, `image/jpeg`, `image/gif`. Max 2 MB.

Avatar is stored at `media/avatars/{username}` in S3 (extension-agnostic, Content-Type set via metadata).

### Upload header image

```bash
curl -X PATCH "$API_URL/api/v1/accounts/update_credentials" \
  -H "Authorization: Bearer $TOKEN" \
  -F "header=@/path/to/header.jpg;type=image/jpeg"
```

Same format/size restrictions as avatar. Stored at `media/headers/{username}`.

### Set profile fields (links)

Up to 4 key-value pairs. URLs get `rel="me"` for Mastodon verified link support (green checkmark).

```bash
curl -X PATCH "$API_URL/api/v1/accounts/update_credentials" \
  -H "Authorization: Bearer $TOKEN" \
  -F "fields_attributes[0][name]=Website" \
  -F "fields_attributes[0][value]=https://myapp.com" \
  -F "fields_attributes[1][name]=App Store" \
  -F "fields_attributes[1][value]=https://apps.apple.com/app/my-app" \
  -F "fields_attributes[2][name]=GitHub" \
  -F "fields_attributes[2][value]=https://github.com/myorg/myapp"
```

Sending `fields_attributes` replaces all fields. Omitting it preserves existing fields.

### Update everything at once

```bash
curl -X PATCH "$API_URL/api/v1/accounts/update_credentials" \
  -H "Authorization: Bearer $TOKEN" \
  -F "display_name=My App" \
  -F "note=The official account for My App" \
  -F "avatar=@avatar.png;type=image/png" \
  -F "header=@header.jpg;type=image/jpeg" \
  -F "fields_attributes[0][name]=Website" \
  -F "fields_attributes[0][value]=https://myapp.com"
```

Profile changes are automatically federated to all followers via an `Update` activity.

## Posting

### Text post

```bash
curl -X POST "$API_URL/api/v1/statuses" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status": "Hello from the fediverse!"}'
```

The response includes the post URL at `url` and the post ID at `id`.

### Post with a single image

First upload the image, then reference it in the post.

```bash
# Step 1: Upload the image
MEDIA_RESPONSE=$(curl -s -X POST "$API_URL/api/v2/media" \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@photo.jpg;type=image/jpeg" \
  -F "description=A description of the image for screen readers")

MEDIA_ID=$(echo "$MEDIA_RESPONSE" | jq -r '.id')
echo "Media ID: $MEDIA_ID"

# Step 2: Create the post with the image attached
curl -X POST "$API_URL/api/v1/statuses" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"status\": \"Check out this photo!\", \"media_ids\": [\"$MEDIA_ID\"]}"
```

### Post with multiple images

Upload each image separately, then pass all media IDs in the post.

```bash
# Upload image 1
MEDIA1=$(curl -s -X POST "$API_URL/api/v2/media" \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@photo1.jpg;type=image/jpeg" \
  -F "description=First photo: the storefront" | jq -r '.id')

# Upload image 2
MEDIA2=$(curl -s -X POST "$API_URL/api/v2/media" \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@photo2.jpg;type=image/jpeg" \
  -F "description=Second photo: the team" | jq -r '.id')

# Upload image 3
MEDIA3=$(curl -s -X POST "$API_URL/api/v2/media" \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@photo3.png;type=image/png" \
  -F "description=Third photo: the product" | jq -r '.id')

# Post with all three images
curl -X POST "$API_URL/api/v1/statuses" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"status\": \"A few photos from today\", \"media_ids\": [\"$MEDIA1\", \"$MEDIA2\", \"$MEDIA3\"]}"
```

Each image should have a unique `description` (alt text) for accessibility.

### Alt text

The `description` field on the media upload is the alt text. It appears in Mastodon clients when users hover or use screen readers. Always provide it.

```bash
curl -s -X POST "$API_URL/api/v2/media" \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@chart.png;type=image/png" \
  -F "description=Bar chart showing monthly active users growing from 1,000 in January to 5,000 in March"
```

## Viewing

### HTML pages

- Profile: `https://happitec.com/@username`
- Post: `https://happitec.com/@username/{statusId}`

### ActivityPub JSON-LD

- Actor: `curl -H "Accept: application/activity+json" https://happitec.com/users/username`
- Status: `curl -H "Accept: application/activity+json" https://happitec.com/users/username/statuses/{id}`
- Outbox: `curl -H "Accept: application/activity+json" https://happitec.com/users/username/outbox?page=true`

### Search from Mastodon

Search for `@username@happitec.com` in any Mastodon client to find and follow the account.

## Environment

| Environment | Client API URL | Stage |
|---|---|---|
| Production | `https://dwfiioehgc.execute-api.us-east-1.amazonaws.com/prod` | prod |
| Stage | `https://r8rlalgizh.execute-api.us-east-1.amazonaws.com/stage` | stage |

## Limitations

- One bearer token per environment (shared `/activity/{stage}/keys/client-token` parameter)
- No OAuth2 yet — tokens are pre-shared, not obtainable via login flow
- API Gateway payload limit is 6 MB (covers most images, not video)
- No post editing or deletion API (federation supports it, client API doesn't expose it yet)
- No scheduled posts, polls, or direct messages
