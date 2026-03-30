# HTML Representations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Server-rendered HTML profile pages and post pages using Elementary (Swift HTML rendering library) with latex.css styling, OG meta tags, and content negotiation.

**Architecture:** Rewrite ProfileHandler to use Elementary for HTML rendering. Add post page support via greedy path. Add content negotiation to ActorHandler and ObjectHandler. Self-host latex.css in S3.

**Tech Stack:** Swift 6.3, Elementary (swift HTML rendering), latex.css, AWS Lambda, CloudFront

---

## Task 1: Add Elementary dependency to Package.swift + ProfileHandler target

- [x] Add Elementary package dependency: `.package(url: "https://github.com/elementary-swift/elementary.git", from: "0.7.0")`
- [x] Add `.product(name: "Elementary", package: "elementary")` to ProfileHandler target dependencies
- [x] Build ProfileHandler on Linux VM to verify Elementary resolves and compiles with Swift 6.3

**Files:** `Package.swift`

---

## Task 2: Document latex.css self-hosting (deploy step)

- [x] Document that `latex.min.css` should be uploaded to the S3 media bucket at key `frontend/latex.min.css`
- [x] This makes it accessible at `https://happitec.com/media/frontend/latex.min.css` via CloudFront
- [x] Use `latex-dark-auto` class on `<body>` for automatic dark mode support
- [x] Do NOT upload now -- this will be done during deploy

**Note:** No code changes. This is a deploy-time manual step.

---

## Task 3: Rewrite ProfileHandler with Elementary -- profile page (`/@username`)

- [x] Replace the string-concatenated HTML in `Sources/ProfileHandler/main.swift` with Elementary DSL
- [x] Change path parameter from `event.pathParameters["username"]` to `event.pathParameters["proxy"]` and parse the proxy path
- [x] Create `ProfilePage` struct conforming to `HTML` with:
  - `<html lang="en">` root element
  - `<head>` with charset, viewport, title, latex.css link, OG meta tags, Twitter Card meta tags, `<link rel="alternate">` for ActivityPub
  - `<body class="latex-dark-auto">` with semantic `<article>` layout
- [x] Profile page content:
  - Avatar image (with alt text) + display name + handle (`@username@happitec.com`)
  - "Service account" type badge
  - Bio/summary (rendered as HTML -- use `HTMLRaw` since summary is already HTML)
  - Profile fields table (parsed from JSON using `parseProfileFields`)
  - Stats line: N followers, N following, N posts
- [x] Fetch recent statuses using `store.listStatuses(username:limit:)` -- latest 20, filter to public/unlisted only
- [x] Display recent posts section with each post showing content, timestamp, likes/boosts counts
- [x] Content warnings displayed prominently above post content (no JS toggle)
- [x] OG meta tags per spec: `og:type=profile`, `og:site_name=Happitec`, `og:title`, `og:description`, `og:image` (avatar), `og:url`, `twitter:card=summary`
- [x] Error pages (404, 500) also use Elementary + latex.css
- [x] Minimal inline `<style>` for avatar sizing, fields table, post metadata (latex.css does most work)
- [x] Build on Linux VM

**Files:** `Sources/ProfileHandler/main.swift`

---

## Task 4: Add post page rendering (`/@username/{statusId}`)

- [x] In the same ProfileHandler, when proxy path has 2 parts (`username/statusId`), render post page
- [x] Fetch actor + status from DynamoDB
- [x] Return 404 for private/direct visibility posts
- [x] Create `PostPage` struct conforming to `HTML` with:
  - Same `<head>` structure as profile page but with post-specific OG tags
  - Author info: avatar + display name + handle (linked to profile page)
  - Full post content (HTML via `HTMLRaw`)
  - Content warning displayed prominently if present
  - Media attachments (images with alt text, max-width styling)
  - Timestamp + visibility label
  - Interaction counts: N likes, N boosts, N replies
  - "View profile" link back to `/@username`
- [x] OG meta tags per spec: `og:type=article`, `og:title="{DisplayName} on Happitec"`, `og:description` (first 200 chars of text), `og:image` (first attachment or avatar), `twitter:card=summary_large_image` if image attachment else `summary`
- [x] `<link rel="alternate" type="application/activity+json">` pointing to `/users/{username}/statuses/{statusId}`
- [x] Build on Linux VM

**Files:** `Sources/ProfileHandler/main.swift`

---

## Task 5: Update API Gateway route to greedy path

- [x] In `activity-app/template.yaml`, change ProfileFunction event path from `/profile/{username}` to `/profile/{proxy+}`
- [x] No other SAM template changes needed -- environment variables and policies remain the same

**Files:** `activity-app/template.yaml`

---

## Task 6: Add content negotiation to ActorHandler

- [x] ActorHandler already has content negotiation (checking Accept header, redirecting to `/@username` for `text/html`)
- [x] Verify it includes `Vary: Accept` in ALL responses (both redirect and JSON-LD)
- [x] Add `Vary: Accept` header to the JSON-LD response if missing
- [x] Add `Vary: Accept` header to the redirect response if missing
- [x] Build on Linux VM

**Files:** `Sources/ActorHandler/main.swift`

---

## Task 7: Add content negotiation to ObjectHandler

- [x] Add Accept header check: if `text/html` and NOT `application/activity+json` or `application/ld+json`, redirect to `https://{serverDomain}/@{username}/{statusId}`
- [x] Construct redirect URL from `event.pathParameters["username"]` and `event.pathParameters["id"]`
- [x] Include `Vary: Accept` header in ALL responses (redirect and JSON-LD)
- [x] Fetch the status first and return 404 for private/direct visibility (before redirecting)
- [x] Build on Linux VM

**Files:** `Sources/ObjectHandler/main.swift`

---

## Task 8: Document happitec.com CloudFront `/profile/*` cache behavior

- [x] **Do NOT modify the happitec.com repo** -- only document what needs to change
- [x] The happitec.com CloudFront distribution needs a new `/profile/*` cache behavior targeting `activityApiOrigin` (the activity.happitec.com API Gateway)
- [x] Without this, requests to `/profile/*` fall through to the default S3 origin and return 404
- [x] The happitec.com CloudFront Function (`ProfileRewriteFunction`) already rewrites `/@username` to `/profile/username` and `/@username/anything` to `/profile/username/anything` -- verify this handles the post page path
- [x] Cache policy: MediumCachePolicy (24h TTL) for profile pages
- [x] Note: the `/profile/*` behavior on the **activity.happitec.com** CloudFront does not exist yet either, but that distribution currently has no `/profile/*` behavior -- it falls through to the default ApiGateway origin which already routes to ProfileHandler. So on activity.happitec.com it already works. The change is needed on **happitec.com**.

**Files:** None in this repo. Document in commit message.

---

## Task 9: Smoke test documentation

- [x] Document curl commands for manual smoke testing after deploy:
  - `curl -s https://happitec.com/@randomforms` -- should return HTML with latex.css, OG tags
  - `curl -s https://happitec.com/@randomforms/{statusId}` -- should return post HTML
  - `curl -H "Accept: text/html" https://activity.happitec.com/users/randomforms` -- should 302 to `/@randomforms`
  - `curl -H "Accept: application/activity+json" https://activity.happitec.com/users/randomforms` -- should return JSON-LD
  - `curl -H "Accept: text/html" https://activity.happitec.com/users/randomforms/statuses/{id}` -- should 302 to `/@randomforms/{id}`
  - `curl -H "Accept: application/activity+json" https://activity.happitec.com/users/randomforms/statuses/{id}` -- should return JSON-LD
- [x] No automated tests in this PR (would require DynamoDB mocking infrastructure)

**Note:** These tests can only run after deploy.
