# Workstream C: HTML Representations — Design Spec

> **Prerequisite:** Workstream B (Profile Management) must be merged first — it adds the `fields` property to the Actor model and DynamoDB schema.

## Goal

Server-rendered HTML profile pages and individual post pages using Elementary (Swift HTML rendering library) with latex.css styling, matching the happitec.com aesthetic.

## Scope

**In scope:**
- Profile page at `/@username` — avatar, display name, handle, bio, profile fields, stats, recent posts
- Post page at `/@username/{statusId}` — full post content, media attachments, author info, timestamp
- OG meta tags on both pages for social sharing / link previews
- Content negotiation on ActorHandler and ObjectHandler (redirect browsers to HTML pages)
- latex.css with `latex-dark-auto` for styling
- CloudFront caching with cache-until-invalidated

**Out of scope:**
- Browsable outbox/followers pages (future)
- Client-side interactivity / JavaScript
- Vue / SPA — this is pure server-rendered HTML
- CSS customization beyond latex.css defaults

## Architecture

### Rewrite ProfileHandler Lambda

The existing ProfileHandler already serves HTML at `/profile/{username}`. Rewrite it to:
1. Use Elementary for HTML rendering instead of string concatenation
2. Handle both profile and post pages via path parsing
3. Include OG meta tags
4. Style with latex.css

### Elementary Package

[elementary-swift/elementary](https://github.com/elementary-swift/elementary) (v0.7.x) — a Swift HTML rendering library. Generates HTML strings server-side using a SwiftUI-inspired DSL. No browser runtime, no WASM. Pure server-side string rendering.

```swift
import Elementary

struct ProfilePage: HTML {
    var actor: Actor

    var content: some HTML {
        html(.lang("en")) {
            head {
                meta(.charset("utf-8"))
                meta(.name("viewport"), .content("width=device-width, initial-scale=1"))
                title { "\(actor.displayName) (@\(actor.preferredUsername)@happitec.com)" }
                link(.rel("stylesheet"), .href("https://happitec.com/media/frontend/latex.min.css"))
                link(.rel("alternate"), .type("application/activity+json"),
                     .href("https://happitec.com/users/\(actor.preferredUsername)"))
            }
            body(.class("latex-dark-auto")) {
                article {
                    // Profile content...
                }
            }
        }
    }
}
```

> **Accessibility:** Use `lang="en"` on the `<html>` tag. Provide meaningful `alt` text on avatar and header images. Use semantic HTML elements (`<article>`, `<header>`, `<time>`, `<nav>`) for screen reader compatibility.

### Routing

Two paths, one Lambda. The existing CloudFront Function on happitec.com rewrites `/@username` to `/profile/username`. Extend it to also handle `/@username/{statusId}`.

**CloudFront Function update (happitec.com):**
```javascript
function handler(event) {
    var request = event.request;
    if (request.uri.startsWith('/@')) {
        // /@username → /profile/username
        // /@username/STATUSID → /profile/username/STATUSID
        request.uri = '/profile/' + request.uri.substring(2);
    }
    return request;
}
```

**API Gateway route:** Change from `/profile/{username}` to `/profile/{proxy+}` (greedy path). The Lambda parses the path to determine profile vs post page.

**Path parsing in Lambda:**
- `/profile/{username}` → profile page
- `/profile/{username}/{statusId}` → post page

```swift
guard let proxyPath = event.pathParameters["proxy"] else { ... }
let parts = proxyPath.split(separator: "/", maxSplits: 1)
let username = String(parts[0])
let statusId = parts.count > 1 ? String(parts[1]) : nil
// statusId == nil → profile page, statusId != nil → post page
```

### Pages

#### Profile Page (`/@username`)

Research-paper style layout with latex.css:

```
┌─────────────────────────────────────┐
│ [Avatar]  Display Name              │
│           @username@happitec.com    │
│           Service account           │
│                                     │
│ Bio text here, rendered as HTML     │
│                                     │
│ ┌─────────────────────────────────┐ │
│ │ Website    → randomforms.app    │ │
│ │ App Store  → Download           │ │
│ └─────────────────────────────────┘ │
│                                     │
│ 42 followers · 0 following · 7 posts│
│                                     │
│ ─────────────────────────────────── │
│                                     │
│ Recent Posts                        │
│                                     │
│ Post content here...                │
│ 2026-03-30 · 3 likes · 1 boost     │
│                                     │
│ Another post...                     │
│ 2026-03-29 · 0 likes · 0 boosts    │
│                                     │
└─────────────────────────────────────┘
```

**Data sources:**
- Actor record from DynamoDB (display name, summary, avatar, header, fields, stats)
- Recent statuses from DynamoDB (outbox query, latest 20, **public and unlisted only** — private and direct posts are excluded)

**OG meta tags:**
```html
<meta property="og:type" content="profile">
<meta property="og:site_name" content="Happitec">
<meta property="og:title" content="Random Forms (@randomforms@happitec.com)">
<meta property="og:description" content="Generative art for iOS">
<meta property="og:image" content="https://happitec.com/media/avatars/randomforms">
<meta property="og:url" content="https://happitec.com/@randomforms">
<meta name="twitter:card" content="summary">
<meta name="twitter:title" content="Random Forms (@randomforms@happitec.com)">
<meta name="twitter:description" content="Generative art for iOS">
<meta name="twitter:image" content="https://happitec.com/media/avatars/randomforms">
<link rel="alternate" type="application/activity+json" href="https://happitec.com/users/randomforms">
```

#### Post Page (`/@username/{statusId}`)

Single post view:

```
┌─────────────────────────────────────┐
│ [Avatar]  Display Name              │
│           @username@happitec.com    │
│                                     │
│ Post content here, full HTML.       │
│                                     │
│ [Image attachment if present]       │
│                                     │
│ 2026-03-30 14:32 · Public           │
│ 3 likes · 1 boost · 0 replies      │
│                                     │
│ ─────────────────────────────────── │
│ View on Mastodon →                  │
└─────────────────────────────────────┘
```

**Data sources:**
- Actor record from DynamoDB
- Status record from DynamoDB

**OG meta tags:**
```html
<meta property="og:type" content="article">
<meta property="og:site_name" content="Happitec">
<meta property="og:title" content="Random Forms on Happitec">
<meta property="og:description" content="Post text preview (first 200 chars)...">
<meta property="og:image" content="https://happitec.com/media/{id}/image.png">
<meta property="og:url" content="https://happitec.com/@randomforms/{statusId}">
<meta property="article:published_time" content="2026-03-30T14:32:00Z">
<meta property="article:author" content="https://happitec.com/@randomforms">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="Random Forms on Happitec">
<meta name="twitter:description" content="Post text preview (first 200 chars)...">
<meta name="twitter:image" content="https://happitec.com/media/{id}/image.png">
<link rel="alternate" type="application/activity+json" href="https://happitec.com/users/randomforms/statuses/{statusId}">
```

If the post has a media attachment, use the first image as `og:image` and set `twitter:card` to `summary_large_image`. Otherwise use the actor's avatar and set `twitter:card` to `summary`.

**Content warnings:** Posts with content warnings show the warning text prominently above the content. Since there is no JavaScript for toggle behavior, both CW and content are always visible.

### Content Negotiation

Update ActorHandler and ObjectHandler to check the `Accept` header:
- If `Accept` includes `text/html` (and does NOT include `application/activity+json` or `application/ld+json`): return 302 redirect to the HTML page
- Otherwise: serve JSON-LD as usual
- **Both handlers must include `Vary: Accept` in their responses** so CloudFront does not cache the redirect for ActivityPub clients or the JSON-LD for browsers

**Post page visibility:** Requests for private or direct posts return 404 — only public and unlisted posts are accessible via HTML pages.

**ActorHandler** redirects browsers visiting `https://happitec.com/users/randomforms` to `https://happitec.com/@randomforms`.

**ObjectHandler** redirects browsers to `https://{serverDomain}/@{username}/{statusId}`, constructed from `event.pathParameters["username"]` and `event.pathParameters["id"]`. For example, `https://happitec.com/users/randomforms/statuses/abc123` redirects to `https://happitec.com/@randomforms/abc123`.

### Styling

Self-host latex.css in the S3 media bucket at `/frontend/latex.min.css` (served via `https://happitec.com/media/frontend/latex.min.css`). Upload the file during deployment. Use `latex-dark-auto` class on body for automatic dark mode.

Additional inline CSS (minimal, only what latex.css doesn't cover):
- Avatar sizing and border-radius
- Profile fields table styling
- Post metadata line styling
- Media attachment max-width

Keep inline styles minimal — latex.css should do most of the work.

### Error Pages

404 and 500 error pages should also use Elementary + latex.css styling for consistency. Return a simple page with the error code, a brief message, and a link back to the profile root.

### Package.swift Changes

> **Note:** Verify Elementary 0.7.x compiles cleanly with Swift 6.3 strict concurrency checking before starting implementation.

Add Elementary dependency:
```swift
.package(url: "https://github.com/elementary-swift/elementary.git", from: "0.7.0")
```

Add to ProfileHandler target:
```swift
.product(name: "Elementary", package: "elementary")
```

### SAM Template Changes

- Update ProfileHandler route from `/profile/{username}` to `/profile/{proxy+}`
- ProfileHandler uses the `SERVER_DOMAIN` environment variable (set to `happitec.com` at runtime) for all URLs in OG tags and page content. This is correct since pages are served on happitec.com.

### happitec.com CloudFront — `/profile/*` Cache Behavior

A new `/profile/*` cache behavior must be added to the **happitec.com** CloudFront distribution, targeting `activityApiOrigin` (the activity.happitec.com API Gateway). This is a new infrastructure change in the happitec.com repo — not this repo. Without it, requests to `/profile/*` will fall through to the default S3 origin and return 404.

### CloudFront Caching

- Profile pages: MediumCachePolicy (24h TTL). Invalidated on profile update (Workstream B's ProfileUpdateHandler already invalidates `/users/{username}*` — extend to `/@{username}*` or `/profile/{username}*`)
- Post pages: LongCachePolicy (365d TTL). Invalidated on post edit/delete.
- These are the same cache behaviors already in place — just serving HTML instead of JSON for the `/profile/*` path.

### happitec.com CloudFront Function Update

The existing `ProfileRewriteFunction` rewrites `/@username` to `/profile/username`. It already handles the `/@username/{anything}` pattern since it just strips the `/@` prefix. Verify this works for `/@username/STATUSID` → `/profile/username/STATUSID`.

### Testing

- Unit tests for HTML rendering functions (verify OG tags contain correct content, page structure)
- Curl smoke test: fetch `/@username` and `/@username/{statusId}`, verify HTML response with correct `content-type`, OG tags, and latex.css reference
- Test content negotiation: `curl -H "Accept: text/html" /users/{username}` returns 302 to `/@username`
- Test JSON-LD still works: `curl -H "Accept: application/activity+json" /users/{username}` returns JSON-LD

### Parallelization

1. Add Elementary dependency to Package.swift and ProfileHandler target
2. Rewrite ProfileHandler with Elementary (profile page)
3. Add post page rendering to ProfileHandler
4. Update API Gateway route to greedy path
5. Add content negotiation to ActorHandler and ObjectHandler
6. Update CloudFront Function on happitec.com (if needed)
7. Smoke tests

Steps 1-2 are sequential. Step 3 depends on 2. Steps 4-6 can run in parallel after 3. Step 7 is last.
