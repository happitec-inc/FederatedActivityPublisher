# HTML Rendering

Server-side HTML rendering for profile pages and post pages using Elementary.

## Overview

FederatedActivityPublisher serves human-readable HTML pages alongside its ActivityPub JSON-LD responses. When a browser visits an actor URL or a status URL, content negotiation detects the `text/html` Accept header and returns a fully rendered HTML page instead of JSON. This is handled by the ProfileHandler Lambda and the content negotiation logic in ActorHandler and ObjectHandler.

### Content Negotiation

The ActorHandler and ObjectHandler Lambdas inspect the request's Accept header. If the client prefers `text/html` and is not requesting `application/activity+json` or `application/ld+json`, the handler returns a 302 redirect to the corresponding profile page URL under `/profile/`. Federation clients that request ActivityPub JSON-LD get the standard actor or note document. This means the same URL (`/users/randomforms`) serves both Mastodon federation traffic and browser visitors.

### Elementary Framework

The HTML pages are built using [Elementary](https://github.com/sliemeobn/elementary), a Swift library for composing HTML as type-safe Swift structures. Each page is a struct conforming to `HTMLDocument` that defines its `head` (meta tags, stylesheets) and `body` (semantic HTML elements) as computed properties. There is no client-side JavaScript framework -- the pages are pure server-side rendered HTML returned directly from the Lambda.

The two page types are:

- **ProfilePage** -- renders an actor's display name, handle, avatar, bio, profile metadata fields, and a reverse-chronological list of recent public and unlisted statuses
- **PostPage** -- renders a single status with its author info, content, media attachments, and metadata (timestamp, visibility, reply context)

### Styling

All pages use [latex.css](https://latex.now.sh) with the `latex-dark-auto` body class, which provides a clean typographic style that automatically switches between light and dark themes based on the user's system preference. Additional custom styles handle profile-specific layout (avatars, metadata tables, post cards) and are inlined in the response.

### Open Graph and Twitter Cards

Both page types include Open Graph (`og:`) meta tags and Twitter Card meta tags in their `<head>`. Profile pages set `og:type` to `profile` and use the actor's avatar as the image. Post pages set `og:type` to `article` and include the post content as the description. This means links to your server's profiles and posts render rich previews when shared on social media, chat apps, or link aggregators.

### Not a Client-Side Framework

It is worth emphasizing that this is not a single-page application or client-side rendering setup. There is no JavaScript bundle, no hydration step, and no virtual DOM. Each page request hits a Lambda, which queries DynamoDB, builds an HTML string using Elementary's DSL, and returns it. The pages are static from the browser's perspective and are cached by CloudFront for up to one hour.
