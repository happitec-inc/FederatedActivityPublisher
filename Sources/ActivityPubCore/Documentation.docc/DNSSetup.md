# DNS Setup

This project supports two DNS architectures. Choose one before deploying.

## Simple Mode (Recommended)

**Your domain points directly to the ActivityPub server.**

- Handle: `@user@example.com`
- Server: `https://example.com`
- WebFinger: served directly at `example.com/.well-known/webfinger`
- Profile pages: served directly at `example.com/@user`

This is the default. One domain, one CloudFront distribution, one hosted zone.

### Setup

1. Deploy the bootstrap stack with `DnsMode=simple` and `DomainName=example.com`
2. The stack outputs four NS records
3. Go to your domain registrar and set the nameservers to these four values
4. Wait for DNS propagation (can take up to 48 hours, usually minutes)
5. Deploy the environment and app stacks
6. Set `ServerDomain=example.com` and `HandleDomain=example.com` in your app workflow

### Diagram

```
Browser/Fediverse
    |
    v
example.com (Route 53 -> CloudFront -> API Gateway -> Lambda)
```

## Split Mode (Advanced)

**Your handle domain is different from your server domain.**

- Handle: `@user@example.com`
- Server: `https://activity.example.com`
- WebFinger: must be proxied from `example.com/.well-known/webfinger` to `activity.example.com`
- Profile pages: `example.com/@user` must rewrite/redirect to `activity.example.com/profile/user`

This mode is useful when your ActivityPub server runs on a subdomain. It requires additional infrastructure on the handle domain.

### Setup

1. Deploy the bootstrap stack with `DnsMode=split` and `DomainName=activity.example.com`
2. The stack outputs four NS records
3. In your **parent zone** (`example.com`), add an NS record delegating `activity.example.com` to these nameservers
4. Wait for DNS propagation
5. Deploy the environment and app stacks
6. Set `ServerDomain=activity.example.com` and `HandleDomain=example.com`

### Additional infrastructure on the handle domain

You need to serve these on `example.com`:

**WebFinger redirect** (`example.com/.well-known/webfinger`):

A CloudFront Function, Lambda@Edge, or reverse proxy that forwards WebFinger
requests to the server domain:

```javascript
// CloudFront Function example
function handler(event) {
    var request = event.request;
    if (request.uri === '/.well-known/webfinger') {
        return {
            statusCode: 302,
            statusDescription: 'Found',
            headers: {
                'location': {
                    value: 'https://activity.example.com/.well-known/webfinger?' +
                           Object.keys(request.querystring)
                               .map(k => k + '=' + request.querystring[k].value)
                               .join('&')
                }
            }
        };
    }
    return request;
}
```

**Profile page redirect** (`example.com/@user`):

A CloudFront Function or equivalent that redirects `/@username` paths:

```javascript
// CloudFront Function example
function handler(event) {
    var request = event.request;
    var match = request.uri.match(/^\/@([a-zA-Z0-9_]+)$/);
    if (match) {
        return {
            statusCode: 302,
            statusDescription: 'Found',
            headers: {
                'location': {
                    value: 'https://activity.example.com/profile/' + match[1]
                }
            }
        };
    }
    return request;
}
```

**Cross-distribution routing** (optional):

If you set `PROXY_DISTRIBUTION_ID` as a repository variable, it is passed to the app stack template for reference. Note that CloudFront cache expiry is now handled entirely by TTL values -- there are no programmatic invalidations from Lambda handlers.

### Diagram

```
Browser/Fediverse
    |
    +---> example.com (handle domain)
    |         |
    |         +-- /.well-known/webfinger -> 302 -> activity.example.com
    |         +-- /@user -> 302 -> activity.example.com/profile/user
    |
    +---> activity.example.com (server domain)
              |
              +-- Route 53 -> CloudFront -> API Gateway -> Lambda
```

## Important: Handle domain is permanent

Once you federate (i.e., another server discovers your actor via WebFinger), your handle domain is baked into every remote server's database. Changing it later means:

- Existing followers see a broken account
- Links to your posts from other servers break
- You cannot migrate followers to a new domain (ActivityPub has no domain migration standard)

Choose carefully. Simple mode with your primary domain is the safest default.
