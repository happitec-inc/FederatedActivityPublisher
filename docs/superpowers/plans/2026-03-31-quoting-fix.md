# Quoting Fix Plan

Cross-referenced against the public Mastodon spec and live mastodon.social responses.
Researched 2026-03-29.

---

## Spec Sources Used

| Source | URL | Status |
|--------|-----|--------|
| Instance entity (v2) | https://docs.joinmastodon.org/entities/Instance/ | Live |
| Instance API methods | https://docs.joinmastodon.org/methods/instance/ | Live |
| Status entity | https://docs.joinmastodon.org/entities/Status/ | Live |
| Quote entity | https://docs.joinmastodon.org/entities/Quote/ | Live |
| QuoteApproval entity | https://docs.joinmastodon.org/entities/QuoteApproval/ | Live |
| Implementing quote posts (client guide) | https://docs.joinmastodon.org/client/quotes/ | Live |
| Quote spec (FEP-044f) | https://docs.joinmastodon.org/spec/quote/ | 404 (not published yet) |
| Mastodon source: version.rb | https://github.com/mastodon/mastodon/blob/main/lib/mastodon/version.rb | `api_versions: { mastodon: 9 }` |
| mastodon.social live v2 instance | https://mastodon.social/api/v2/instance | `"api_versions": {"mastodon": 9}` |

---

## Key Spec Findings

### api_versions.mastodon

The client guide at `https://docs.joinmastodon.org/client/quotes/` states:

> "The new APIs described below are available starting with `mastodon` API version 7."

The Mastodon source (`lib/mastodon/version.rb`) currently sets `mastodon: 9`. PR #35939 (merged 2025-08-29) conditionally bumped the API version when the quote post feature flag was enabled. The current Mastodon nightly (`4.6.0-nightly.2026-03-30`) returns `9` from mastodon.social.

Clients (Ivory, Ice Cubes, etc.) check `api_versions.mastodon >= 7` before enabling the quote button.

### v1 Instance entity

The v1 instance response (`GET /api/v1/instance`) does NOT include `api_versions`. It is a deprecated endpoint. No quote-specific fields are needed in v1. It exists for legacy client compatibility only.

mastodon.social v1 response notable fields:
- No `api_versions`
- `configuration` contains only `accounts`, `statuses`, `media_attachments`, `polls` (no quotes section)

### v2 Instance entity

The v2 instance response (`GET /api/v2/instance`) includes `api_versions` (added in Mastodon 4.3.0). The `configuration` object on mastodon.social does NOT contain a `configuration.quotes` key. Quote capability is signaled solely through `api_versions.mastodon >= 7`.

mastodon.social v2 response structure:
```
keys: domain, title, version, source_url, description, usage, thumbnail, icon,
      languages, configuration, registrations, api_versions, wrapstodon, contact, rules
```

Configuration keys: `urls, vapid, accounts, statuses, media_attachments, polls, translation, timelines_access, limited_federation`

No `quotes` key in configuration.

### Status entity quote fields

Added in Mastodon 4.4.0-4.5.0:

| Field | Type | Added | Description |
|-------|------|-------|-------------|
| `quote` | nullable Quote or ShallowQuote | 4.4.0 | Information about the quoted status |
| `quote_approval` | QuoteApproval | 4.5.0 | Quote approval policy and current user status |
| `quotes_count` | Integer | 4.5.0 | Number of accepted quotes |

**Quote entity** has two fields:
- `state`: enum (`pending`, `accepted`, `rejected`, `revoked`, `deleted`, `unauthorized`, `blocked_account`, `blocked_domain`, `muted_account`)
- `quoted_status`: nullable Status (populated when `state` is `accepted`, `blocked_account`, `blocked_domain`, or `muted_account`)

**QuoteApproval entity** has three fields:
- `automatic`: array of strings (`public`, `followers`, `following`, `unsupported_policy`)
- `manual`: array of strings (same values)
- `current_user`: string (`automatic`, `manual`, `denied`, `unknown`)

### ActivityPub wire format for quotes

Per the Mastodon ActivityPub spec and FEP-044f:
- `quoteUri` (in toot namespace: `"quoteUri": "toot:quoteUri"`)
- `_misskey_quote` (compatibility with Misskey/Calckey)
- `QuoteRequest` activity type for consent-based quoting (FEP-044f)

---

## Fix 1: api_versions.mastodon value

### What's wrong

`Sources/InstanceHandler/main.swift` line 37 returns:
```json
"api_versions": {"mastodon": 2}
```

This tells clients "we support Mastodon API version 2" which predates quote support entirely.

### What the spec says

From https://docs.joinmastodon.org/client/quotes/:
> "The new APIs described below are available starting with `mastodon` API version 7."

mastodon.social currently returns `9`. The minimum for quote support is `7`.

### The fix

**File:** `/Users/spar/web-local/activity.happitec.com/Sources/InstanceHandler/main.swift`
**Line 37:** Change `"api_versions": {"mastodon": 2}` to `"api_versions": {"mastodon": 7}`

Why 7 and not 9: We should advertise only the API level we actually support. Version 7 signals quote support. Versions 8-9 may imply features we do not implement (e.g., media deletion methods from PR #34035, notification grouping from PR #31840). We can bump to higher values as we implement more features.

However, there is a risk: if a client interprets version 7 as "supports everything up to and including version 7" and some version 7 features are unrelated to quotes, those calls may fail. Since we only implement a subset of the Mastodon API (no OAuth, no timelines, no notifications), there is no perfect version number. The pragmatic choice is `7` to unlock quoting in clients that gate on it.

### Verification

```bash
# After deploy:
curl -s "https://activity.happitec.com/api/v2/instance" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('api_versions:', d.get('api_versions'))
assert d['api_versions']['mastodon'] >= 7, 'FAIL: api_versions too low'
print('PASS')
"
```

---

## Fix 2: /api/* proxy on happitec.com

### What's wrong

The happitec.com CloudFront distribution (`/Users/spar/web-local/happitec.com/template.yml`) has no cache behaviors for `/api/v1/instance` or `/api/v2/instance`. These paths fall through to the default SPA behavior, which rewrites all extensionless paths to `/index.html` and serves HTML from S3.

Evidence:
```
$ curl -sI "https://happitec.com/api/v1/instance"
content-type: text/html    # <-- SPA HTML, not JSON
```

Mastodon clients resolve the instance API on the actor's domain. Since actor URIs are `https://happitec.com/users/{username}`, clients fetch `https://happitec.com/api/v2/instance` -- which currently returns HTML.

### What the spec says

The instance API methods at https://docs.joinmastodon.org/methods/instance/ define:
- `GET /api/v1/instance` - deprecated, returns V1::Instance
- `GET /api/v2/instance` - current, returns Instance

These must be served on the domain where actors live. For our setup, that is `happitec.com`.

### The fix

**File:** `/Users/spar/web-local/happitec.com/template.yml`

Add two new cache behaviors to the `CacheBehaviors` array in the CloudFront distribution, BEFORE the `/@*` behavior (which has a `FunctionAssociations` for profile rewrite). They should be conditional on `HasActivityApi` like the other activity behaviors.

Add after the `/nodeinfo/*` behavior (around line 386) and before the `/users/*/inbox` behavior:

```yaml
          - !If
            - HasActivityApi
            - PathPattern: /api/v1/instance
              TargetOriginId: activityApiOrigin
              ViewerProtocolPolicy: redirect-to-https
              CachePolicyId: !Ref MediumCachePolicy
              AllowedMethods: [GET, HEAD]
              Compress: true
            - !Ref AWS::NoValue
          - !If
            - HasActivityApi
            - PathPattern: /api/v2/instance
              TargetOriginId: activityApiOrigin
              ViewerProtocolPolicy: redirect-to-https
              CachePolicyId: !Ref MediumCachePolicy
              AllowedMethods: [GET, HEAD]
              Compress: true
            - !Ref AWS::NoValue
```

**Should we proxy ALL `/api/*`?** No. The only `/api/*` routes on the federation API Gateway are `/api/v1/instance` and `/api/v2/instance` (served by InstanceHandler). The client API routes (`/api/v1/statuses`, `/api/v2/media`, `/api/v1/accounts/update_credentials`) are on a separate API Gateway (ClientApi) and are accessed directly via its own URL -- they should NOT be proxied through happitec.com's CloudFront. Adding a blanket `/api/*` behavior would either route to the wrong origin or expose the client API unintentionally.

### Verification

```bash
# After deploy:
curl -s "https://happitec.com/api/v2/instance" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('domain:', d.get('domain'))
print('api_versions:', d.get('api_versions'))
assert d.get('domain') == 'happitec.com', 'FAIL: wrong domain or not JSON'
print('PASS')
"

curl -s "https://happitec.com/api/v1/instance" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('uri:', d.get('uri'))
assert d.get('uri') == 'happitec.com', 'FAIL: wrong uri or not JSON'
print('PASS')
"
```

---

## Fix 3: Instance response completeness

### What's wrong

Our v2 instance response is missing several fields that mastodon.social includes. While not all are required for quoting, missing fields may cause client parsing errors or degraded experiences.

### What the spec says

The Instance entity at https://docs.joinmastodon.org/entities/Instance/ defines required fields. Comparing our response against mastodon.social:

**v2 response gaps:**

| Field | Our value | mastodon.social | Impact |
|-------|-----------|-----------------|--------|
| `api_versions.mastodon` | `2` | `9` | **Breaks quoting** (see Fix 1) |
| `configuration.urls` | missing | `{streaming, status, about, ...}` | Low -- we have no streaming API |
| `configuration.vapid` | missing | `{public_key: "..."}` | Low -- we have no push notifications |
| `configuration.accounts` | missing | `{max_display_name_length, max_note_length, max_featured_tags, ...}` | Medium -- clients may use defaults |
| `configuration.polls` | missing | `{max_options, ...}` | Low -- we don't support polls |
| `configuration.translation` | missing | `{enabled: true}` | Low |
| `configuration.timelines_access` | missing | `{live_feeds, ...}` | Low |
| `configuration.limited_federation` | missing | `false` | Low |
| `registrations.approval_required` | missing | `false` | Low |
| `registrations.reason_required` | missing | `false` | Low |
| `registrations.min_age` | missing | `16` | Low |
| `icon` | missing | array of InstanceIcon | Low |
| `source_url` | present | present | OK |
| `usage` | `{users: {active_month: 4}}` | present | OK |

**v1 response gaps:**

| Field | Our value | mastodon.social | Impact |
|-------|-----------|-----------------|--------|
| `configuration.accounts` | missing | `{max_featured_tags: 10}` | Low |
| `configuration.polls` | missing | full polls config | Low |

**No quote-specific configuration is needed in either response.** Quote capability is signaled solely via `api_versions.mastodon >= 7` in the v2 response. There is no `configuration.quotes` key in the spec or in mastodon.social's response.

### The fix

Minimum required change: bump `api_versions.mastodon` (Fix 1). The other missing fields are cosmetic and can be addressed in a separate enhancement pass.

Optional improvement for the v2 response (not blocking for quoting):

**File:** `/Users/spar/web-local/activity.happitec.com/Sources/InstanceHandler/main.swift`

Add to the configuration block inside the v2 response:
```json
"accounts": {
  "max_featured_tags": 10,
  "max_pinned_statuses": 0
},
"polls": {
  "max_options": 0,
  "max_characters_per_option": 0,
  "min_expiration": 0,
  "max_expiration": 0
},
"translation": {
  "enabled": false
}
```

Add to the registrations block:
```json
"registrations": {
  "enabled": false,
  "approval_required": false,
  "reason_required": false,
  "message": null,
  "url": null
}
```

### Verification

```bash
# Compare field-by-field:
curl -s "https://activity.happitec.com/api/v2/instance" | python3 -c "
import json, sys
d = json.load(sys.stdin)
config = d.get('configuration', {})
print('config keys:', sorted(config.keys()))
reg = d.get('registrations', {})
print('registrations keys:', sorted(reg.keys()) if isinstance(reg, dict) else type(reg))
print('api_versions:', d.get('api_versions'))
"
```

---

## Fix 4: Verification (file as issue, do not implement here)

### What the spec says

Mastodon profile verification works via rel="me" mutual links. When a user sets a URL in their profile fields, the Mastodon server:
1. Fetches the URL
2. Scans for `<a>` or `<link>` tags with `rel="me"`
3. Checks if any `href` matches the user's profile URL
4. If matched, sets `verified_at` on the ProfileValue attachment in the actor document

Remote instances display the green checkmark based on the `verified_at` timestamp in the federated actor JSON. Mastodon trusts the remote server's self-asserted `verified_at` for display purposes.

### What's wrong

Our `ActorSerializer` emits `PropertyValue` attachments without `verified_at`. Our server never performs the rel="me" check. Remote instances therefore show all our profile links as unverified.

### What to file

Open an issue with:
- Title: "Add rel=me verification and verified_at to actor attachments"
- Body: Implement server-side verification in ProfileUpdateHandler. When profile fields are set/updated, fetch each href URL, scan for rel="me" backlinks to the actor's profile URL (`https://{domain}/@{username}`), and if found, store `verified_at` timestamp in DynamoDB. Include `verified_at` in the actor JSON serialization via ActorSerializer. Reverify periodically or on profile update.
- Labels: enhancement
- References: https://docs.joinmastodon.org/user/profile/#verification

---

## Deployment Order

1. **Fix 1** (api_versions bump) and **Fix 3** (optional response completeness) -- deploy activity.happitec.com changes
2. **Fix 2** (happitec.com proxy) -- deploy happitec.com CloudFront template
3. Invalidate CloudFront caches on both distributions:
   ```bash
   # activity.happitec.com distribution
   aws cloudfront create-invalidation --distribution-id $ACTIVITY_DIST_ID \
     --paths "/api/v1/instance" "/api/v2/instance"

   # happitec.com distribution
   aws cloudfront create-invalidation --distribution-id ECA8TWLFT6NO9 \
     --paths "/api/v1/instance" "/api/v2/instance"
   ```
4. Verify both domains return correct JSON with `api_versions.mastodon >= 7`
5. **Fix 4** -- file issue, implement separately

## Files to Change

| File | Repo | Change |
|------|------|--------|
| `Sources/InstanceHandler/main.swift` | activity.happitec.com | Bump `api_versions.mastodon` from `2` to `7`; optionally flesh out configuration and registrations |
| `template.yml` | happitec.com | Add `/api/v1/instance` and `/api/v2/instance` cache behaviors pointing to `activityApiOrigin` |
