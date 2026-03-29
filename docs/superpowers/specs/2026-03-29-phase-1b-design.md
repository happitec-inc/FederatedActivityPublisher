# Phase 1b Design — CloudFront + Custom Domains

## Goal

Put CloudFront in front of the federation API with full cache behaviors, custom domains with Route 53 records, and S3 media serving via OAC. Add a WebFinger redirect on happitec.com so Mastodon can discover `@user@happitec.com` handles.

## What This Builds

- CloudFront distribution with 11 cache behaviors + 2 origins (API Gateway custom domain + S3)
- Origin Access Control for S3 media bucket
- API Gateway custom domain for the federation API
- Route 53 alias records
- Custom cache policies (WebFinger query string whitelist, outbox pagination)
- Custom origin request policy for inbox (forwards HTTP Signature headers)
- WebFinger redirect on happitec.com (separate PR to happitec.com repo)

## What This Does NOT Include

- PR ephemeral environments (deferred)
- Client API Gateway / client domain (Phase 3)
- Inbox / posting / delivery (Phase 2-3)

## SAM Template Changes (`activity-app/template.yaml`)

### New Parameters

```yaml
BootstrapStackName:
  Type: String
  Default: activity-bootstrap
  Description: Bootstrap stack for HostedZoneId and CertificateArn
```

### New Resources

**CloudFront Distribution:**
- Two origins:
  1. API Gateway (federation) — uses the **API Gateway custom domain** (`ServerDomainName`) as origin, NOT the default execute-api URL. This avoids stage-prefix stripping issues (PROJECT-PLAN.md line 1298).
  2. S3 media bucket (from environment stack) — via OAC, read-only
- Viewer certificate: ACM wildcard cert imported from bootstrap stack
- Aliases: `{stage}.activity.happitec.com` (stage) or `activity.happitec.com` (prod)
- Default cache behavior: no cache (POST passthrough for inbox), with a custom origin request policy that forwards all headers needed for HTTP Signature verification (`Host`, `Date`, `Digest`, `Signature`, `Signature-Input`, `Content-Type`, `Content-Digest`)

**Cache Behaviors (11 patterns — matches PROJECT-PLAN.md lines 194-206):**

| Path Pattern | TTL | Cache Key Extras | Origin |
|---|---|---|---|
| `/.well-known/nodeinfo` | 24h | — | API Gateway |
| `/nodeinfo/*` | 24h | — | API Gateway |
| `/.well-known/webfinger*` | 24h | `resource` query param | API Gateway |
| `/users/*/outbox*` | 365d | `page`, `min_id`, `max_id` query params | API Gateway |
| `/users/*/statuses/*` | 365d | — | API Gateway |
| `/users/*/collections/featured` | 24h | — | API Gateway |
| `/users/*/collections/tags` | 24h | — | API Gateway |
| `/users/*/followers*` | 1h | — | API Gateway |
| `/users/*/following*` | 1h | — | API Gateway |
| `/users/*` | 24h | — (catch-all GET for actor profiles) | API Gateway |
| `/media/*` | 365d, immutable | — | S3 via OAC |

Note: `/users/*/following*` is explicit at 1h (same as followers) rather than falling through to the 24h catch-all. Even though following is always empty for now, it should match the followers TTL for consistency.

Custom cache policies needed:
- **WebFingerCachePolicy**: whitelist `resource` query param in cache key
- **OutboxCachePolicy**: whitelist `page`, `min_id`, `max_id` query params
- Default managed policies for the rest (CachingOptimized for long TTL, CachingDisabled for POST passthrough)

Custom origin request policy for inbox (default behavior):
- **InboxOriginRequestPolicy**: forwards `Host`, `Date`, `Digest`, `Signature`, `Signature-Input`, `Content-Type`, `Content-Digest` headers to the origin. Required for HTTP Signature verification in Phase 2.

`Cache-Control: immutable` for `/media/*`: The S3 objects themselves should be stored with `Cache-Control: public, max-age=31536000, immutable` metadata (set at upload time by `λ media-upload` in Phase 3). CloudFront respects the origin's `Cache-Control` header. The cache behavior TTL (365d) acts as a backstop.

**CloudFront OAC:**
```yaml
CloudFrontOAC:
  Type: AWS::CloudFront::OriginAccessControl
  Properties:
    OriginAccessControlConfig:
      Name: !Sub "activity-media-oac-${Stage}"
      OriginAccessControlOriginType: s3
      SigningBehavior: always
      SigningProtocol: sigv4
```

**Media Bucket Policy:**
Grants the CloudFront distribution read-only access to the environment's S3 media bucket. References the environment stack's bucket ARN via `Fn::ImportValue`.

**API Gateway Custom Domain:**
```yaml
ServerDomainName:
  Type: AWS::ApiGateway::DomainName
  Properties:
    DomainName: !If [IsProd, !Ref ServerDomain, !Sub "${Stage}.${ServerDomain}"]
    RegionalCertificateArn: !ImportValue
      Fn::Sub: "${BootstrapStackName}-CertificateArn"
    EndpointConfiguration:
      Types: [REGIONAL]
```

Note: Using REGIONAL endpoint type because CloudFront is the edge — the API Gateway custom domain is only accessed by CloudFront as an origin, not directly by clients.

**Base Path Mapping:**
Maps the custom domain to the API Gateway's deployment stage.

**Route 53 Records:**
```yaml
FederationDnsRecord:
  Type: AWS::Route53::RecordSet
  Properties:
    HostedZoneId: !ImportValue
      Fn::Sub: "${BootstrapStackName}-HostedZoneId"
    Name: !If [IsProd, !Ref ServerDomain, !Sub "${Stage}.${ServerDomain}"]
    Type: A
    AliasTarget:
      DNSName: !GetAtt CloudFrontDistribution.DomainName
      HostedZoneId: Z2FDTNDATAQYW2  # CloudFront global hosted zone ID
```

### New Conditions

```yaml
IsProd: !Equals [!Ref Stage, prod]
```

### New Outputs

```yaml
CloudFrontDistributionId:
  Value: !Ref CloudFrontDistribution
CloudFrontDomainName:
  Value: !GetAtt CloudFrontDistribution.DomainName
ServerApiUrl:
  Value: !Sub "https://${ServerDomainName}"
ServerDomain:
  Value: !If [IsProd, !Ref ServerDomain, !Sub "${Stage}.${ServerDomain}"]
```

## happitec.com Changes (Separate PR)

Add a CloudFront Function to the existing happitec.com CloudFront distribution that redirects WebFinger requests:

```javascript
function handler(event) {
  var request = event.request;
  if (request.uri === '/.well-known/webfinger') {
    // Reconstruct query string, preserving URL encoding
    // CloudFront decodes query values — re-encode special chars like @
    var qs = request.querystring;
    var pairs = [];
    for (var key in qs) {
      var val = qs[key].value;
      pairs.push(encodeURIComponent(key) + '=' + encodeURIComponent(val));
    }
    var qsString = pairs.join('&');
    return {
      statusCode: 302,
      statusDescription: 'Found',
      headers: {
        location: { value: 'https://activity.happitec.com/.well-known/webfinger?' + qsString }
      }
    };
  }
  return request;
}
```

Note: `encodeURIComponent` is used because CloudFront decodes query string values before passing them to the function. The `resource` parameter contains `acct:user@domain` — the `@` and `:` need to be re-encoded in the redirect URL.

This lives in the happitec.com SAM template as a `AWS::CloudFront::Function` associated with the existing distribution's viewer-request event for the `/.well-known/webfinger` path.

## Workflow Changes

No workflow changes needed for Phase 1b — the existing `app.yml` workflow deploys the updated SAM template automatically on merge to main. The new CloudFront resources are part of the same `activity-app-{stage}` stack.

CloudFront distribution creation takes ~15 minutes on first deploy. Subsequent deploys (cache behavior changes, etc.) are faster.

## Success Criteria

1. `curl https://stage.activity.happitec.com/.well-known/webfinger?resource=acct:randomforms@happitec.com` → 200, valid WebFinger JSON
2. Second identical request → response includes `X-Cache: Hit from CloudFront` header
3. `curl https://stage.activity.happitec.com/users/randomforms` → 200, Actor JSON-LD via CloudFront
4. `curl -v https://stage.activity.happitec.com/media/test.png` → S3 origin confirmed (or 403/404 if no media — confirms OAC origin is wired)
5. `curl -X POST https://stage.activity.happitec.com/users/randomforms/inbox -d '{}' -H 'Content-Type: application/activity+json'` → passes through CloudFront to Lambda (401 or 404, not cached)
6. `curl -L "https://happitec.com/.well-known/webfinger?resource=acct:randomforms@happitec.com"` → follows 302 redirect, returns WebFinger JSON from activity.happitec.com
