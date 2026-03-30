# Portability Phase 1: Quick Fixes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Remove all private-repo dependencies from deploy workflows, make optional workflows fail gracefully, update misleading fallback defaults in Swift source, and document every required secret/variable so an external deployer can fork and deploy without access to `happitec-inc` private repos.

**Estimated time:** ~1.5 hours

**Audit reference:** [Issue #99 -- Portability Audit](https://github.com/happitec-inc/FederatedActivityPublisher/issues/99)

---

## Task 1: Inline SAM CLI installation in all deploy workflows

Replace the private `happitec-inc/happitec-logo-generator/.github/actions/setup-sam-portable@main` composite action with inline `pip install` steps. This is the only **required** blocker -- without SAM CLI, nothing deploys.

### 1.1 Replace SAM CLI step in `app.yml`

- [ ] In `.github/workflows/app.yml`, replace lines 46-49:
  ```yaml
  - name: Install SAM CLI
    uses: happitec-inc/happitec-logo-generator/.github/actions/setup-sam-portable@main
    with:
      token: ${{ secrets.GITHUB_TOKEN }}
  ```
  with:
  ```yaml
  - name: Install SAM CLI
    run: |
      pip install --quiet aws-sam-cli
      sam --version
  ```

### 1.2 Replace SAM CLI step in `bootstrap.yml`

- [ ] In `.github/workflows/bootstrap.yml`, replace lines 16-19 with the same inline `pip install` step

### 1.3 Replace SAM CLI step in `environment.yml`

- [ ] In `.github/workflows/environment.yml`, replace lines 25-28 with the same inline `pip install` step

### 1.4 Verify on self-hosted runner

- [ ] Trigger a manual `workflow_dispatch` of `bootstrap.yml` (it is idempotent with `--no-fail-on-empty-changeset`) to confirm SAM CLI installs and runs correctly on the self-hosted Linux runner

**Files:** `.github/workflows/app.yml`, `.github/workflows/bootstrap.yml`, `.github/workflows/environment.yml`

---

## Task 2: Make DocC workflow optional and fork-friendly

The `deploy-docc.yml` workflow depends on four private-repo resources. Make each one skip gracefully so the workflow still produces standard DocC output when run from a fork.

### 2.1 Make OG image generation conditional

- [ ] Wrap the `generate-og-image` job in a condition that checks for the PAT:
  ```yaml
  generate-og-image:
    if: vars.ENABLE_DOCC_DEPLOY == 'true'
    uses: happitec-inc/happitec-logo-generator/.github/workflows/generate-og-image.yml@main
  ```
- [ ] Note: reusable workflow calls cannot use `secrets.*` in `if:` conditions, so use a repository variable `vars.ENABLE_DOCC_DEPLOY` as the gate

### 2.2 Make the build job work without OG image

- [ ] Change `needs: [generate-og-image]` to `needs: []` (remove the dependency)
- [ ] Make the "Download OG image" step conditional:
  ```yaml
  - name: Download OG image
    if: vars.ENABLE_DOCC_DEPLOY == 'true'
    uses: actions/download-artifact@v6
  ```

### 2.3 Fall back to upstream swift-docc-render

- [ ] Make the private fork checkout conditional, and add a fallback:
  ```yaml
  - name: Checkout swift-docc-render fork (Mermaid support)
    if: vars.ENABLE_DOCC_DEPLOY == 'true'
    uses: actions/checkout@v6
    with:
      repository: happitec-inc/swift-docc-render
      ref: feature/mermaid-diagrams
      path: swift-docc-render-fork

  - name: Checkout upstream swift-docc-render (fallback)
    if: vars.ENABLE_DOCC_DEPLOY != 'true'
    uses: actions/checkout@v6
    with:
      repository: apple/swift-docc-render
      path: swift-docc-render-fork
  ```

### 2.4 Make OG post-processing conditional

- [ ] Wrap the `docc-og-postprocess` action step in `if: vars.ENABLE_DOCC_DEPLOY == 'true'`

### 2.5 Gate the entire workflow

- [ ] Add a top-level condition on the `build` and `deploy` jobs so the entire workflow is skippable:
  ```yaml
  build:
    if: vars.ENABLE_DOCC_DEPLOY == 'true' || github.repository == 'happitec-inc/FederatedActivityPublisher'
  ```
  This ensures it always runs for the upstream repo but forks can opt in via the variable.

**Files:** `.github/workflows/deploy-docc.yml`

---

## Task 3: Make Claude code review workflows optional

Both `claude.yml` and `claude-code-review.yml` require `secrets.CLAUDE_CODE_OAUTH_TOKEN`. They should skip gracefully when the secret is absent.

### 3.1 Guard `claude.yml`

- [ ] Add a secret presence check. GitHub does not expose secret names in `if:` conditions, but the action itself will fail if the token is empty. Add a job-level condition:
  ```yaml
  claude:
    if: |
      github.repository == 'happitec-inc/FederatedActivityPublisher' &&
      ((github.event_name == 'issue_comment' && contains(github.event.comment.body, '@claude')) || ...)
  ```
  Alternatively, check if the token is non-empty in a preliminary step and skip the rest.

### 3.2 Guard `claude-code-review.yml`

- [ ] Add `if: github.repository == 'happitec-inc/FederatedActivityPublisher'` to the `claude-review` job, so forks do not attempt to run it without the required secret

**Files:** `.github/workflows/claude.yml`, `.github/workflows/claude-code-review.yml`

---

## Task 4: Update fallback defaults in Swift source

20 Lambda handler files have `?? "activity.happitec.com"` or `?? "happitec.com"` fallbacks. These are always overridden by environment variables in production, but they are misleading for someone reading the code. Replace with `fatalError` calls that clearly indicate misconfiguration.

### 4.1 Replace `serverDomain` fallbacks

- [ ] In all 17 handler files that have `ProcessInfo.processInfo.environment["SERVER_DOMAIN"] ?? "activity.happitec.com"` or `?? "happitec.com"`, replace with:
  ```swift
  guard let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] else {
      fatalError("SERVER_DOMAIN environment variable is required")
  }
  ```

  **Files (serverDomain, 17 handlers):**
  - `Sources/NodeInfoHandler/main.swift`
  - `Sources/WebFingerHandler/main.swift`
  - `Sources/FeaturedHandler/main.swift`
  - `Sources/PostHandler/main.swift`
  - `Sources/InboxHandler/main.swift`
  - `Sources/ActorHandler/main.swift`
  - `Sources/MediaUploadHandler/main.swift`
  - `Sources/OutboxHandler/main.swift`
  - `Sources/FollowersHandler/main.swift`
  - `Sources/FollowingHandler/main.swift`
  - `Sources/ProfileUpdateHandler/main.swift`
  - `Sources/FeaturedTagsHandler/main.swift`
  - `Sources/ObjectHandler/main.swift`
  - `Sources/DeliverHandler/main.swift`
  - `Sources/ProfileHandler/main.swift`

### 4.2 Replace `handleDomain` fallbacks

- [ ] In the 5 handlers that also have `HANDLE_DOMAIN` fallbacks, apply the same `guard`/`fatalError` pattern:
  ```swift
  guard let handleDomain = ProcessInfo.processInfo.environment["HANDLE_DOMAIN"] else {
      fatalError("HANDLE_DOMAIN environment variable is required")
  }
  ```

  **Files (handleDomain):**
  - `Sources/WebFingerHandler/main.swift`
  - `Sources/PostHandler/main.swift`
  - `Sources/InboxHandler/main.swift`
  - `Sources/ActorHandler/main.swift`
  - `Sources/ProfileUpdateHandler/main.swift`

### 4.3 Build on Linux VM

- [ ] SSH to the Linux runner VM and build to verify all handlers compile:
  ```bash
  swift build --build-tests 2>&1 | tail -20
  ```

**Files:** All handler `main.swift` files listed above

---

## Task 5: Document all required secrets and variables

Add a comprehensive configuration reference to `README.md` so external deployers know exactly what to set up before running any workflow.

### 5.1 Add secrets and variables table to README

- [ ] Add a new `## Configuration` section to `README.md` (after the "Architecture" section) with the following content:

  **Required GitHub Secrets** (must be set for deployment):

  | Secret | Used by | Description |
  |--------|---------|-------------|
  | `AWS_ACCESS_KEY_ID` | app, bootstrap, environment | IAM access key for SAM deployments |
  | `AWS_SECRET_ACCESS_KEY` | app, bootstrap, environment | IAM secret key for SAM deployments |

  **Optional GitHub Secrets:**

  | Secret | Used by | Description |
  |--------|---------|-------------|
  | `HAPPITEC_READ_ONLY_PAT` | deploy-docc | PAT for private repo access (OG image generation) |
  | `CLAUDE_CODE_OAUTH_TOKEN` | claude, claude-code-review | OAuth token for Claude AI code review |

  **Repository Variables:**

  | Variable | Used by | Default | Description |
  |----------|---------|---------|-------------|
  | `RUNNER_LABELS_LINUX` | app, bootstrap, environment | `"ubuntu-latest"` | JSON array of runner labels, e.g. `["self-hosted", "linux"]` |
  | `RUNNER_LABELS_MACOS` | deploy-docc | `"macos-15"` | JSON array of runner labels for macOS jobs |
  | `HAPPITEC_DISTRIBUTION_ID` | app | _(empty)_ | CloudFront distribution ID for cross-distribution cache invalidation; leave empty if not using a parent domain proxy |
  | `ENABLE_DOCC_DEPLOY` | deploy-docc | _(unset)_ | Set to `true` to enable private-repo DocC features (OG images, Mermaid diagrams) |

### 5.2 Add SAM parameter overrides reference

- [ ] In the same `## Configuration` section, add a sub-section documenting the key SAM parameter overrides:

  | Parameter | Stack | Description |
  |-----------|-------|-------------|
  | `ServerDomain` | app | The domain the ActivityPub server runs on (e.g. `activity.example.com`) |
  | `HandleDomain` | app | The domain used in ActivityPub handles (e.g. `example.com` for `@user@example.com`) |
  | `HappitecDistributionId` | app | Optional cross-distribution invalidation target; empty string to skip |
  | `Stage` | app, environment | `stage` or `prod` |

### 5.3 Remove hardcoded API Gateway URLs from AGENTS.md

- [ ] In `AGENTS.md`, replace the hardcoded API Gateway URLs (`https://dwfiioehgc.execute-api...` and `https://r8rlalgizh.execute-api...`) with a note directing readers to check stack outputs:
  ```
  Check your deployed stack outputs for the API Gateway URL:
  aws cloudformation describe-stacks --stack-name activity-app-{stage} \
    --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text
  ```

**Files:** `README.md`, `AGENTS.md`

---

## Verification

After all tasks are complete:

- [ ] Trigger `bootstrap.yml` via `workflow_dispatch` -- should install SAM CLI via pip and succeed
- [ ] Trigger `environment.yml` via `workflow_dispatch` with stage `stage` -- should succeed
- [ ] Push to `main` to trigger `app.yml` -- should succeed (or trigger manually)
- [ ] Confirm `deploy-docc.yml` runs without errors when `ENABLE_DOCC_DEPLOY` is unset (fork scenario)
- [ ] Confirm `claude.yml` and `claude-code-review.yml` skip cleanly on a fork
- [ ] Confirm Swift build passes on Linux after fallback removal
