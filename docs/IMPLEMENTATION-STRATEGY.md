# Implementation Strategy

Agreed 2026-03-27 during post-spec-review discussion.

## Approach

Build incrementally by SAM stack, validating each layer before moving to the next. Don't build everything at once.

## Sequence

1. **Bootstrap stack** -- Route 53 hosted zone, ACM cert. Deploy, validate DNS/ACM.
2. **Environment stack** -- DynamoDB, SQS, S3, SSM. Deploy to stage, validate resources are live.
3. **App PoC** -- Single Lambda (WebFinger) end-to-end through SAM + CloudFront + GitHub Actions. Proves the Swift-on-Lambda toolchain (ARM64, custom runtime, static linking, SAM packaging, CI pipeline). WebFinger chosen because it's the simplest handler and maps to the Phase 0 milestone ("resolves in Mastodon search").
4. **Shared library** -- Build common code that handlers import. Exact shape TBD: could be a single `ActivityPubCore` library target, could be a collection of focused modules. Decide based on what steps 1-3 reveal about actual shared concerns (DynamoDB models, HTTP Signatures, AP serialization, JSON-LD context construction).
5. **Parallel Lambda agents** -- Each handler built by a separate agent, working in its own `Sources/` subdirectory. Minimal file overlap since the Swift package structure isolates handlers. Depends on shared library existing first.

## Open decisions (deferred until step 4)

- Is the shared code a single library or multiple focused modules?
- Which concerns are truly shared vs. handler-specific?
