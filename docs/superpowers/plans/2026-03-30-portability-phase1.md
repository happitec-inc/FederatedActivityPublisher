# Portability Phase 1: Quick Fixes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Remove all private-repo dependencies from deploy workflows, make optional workflows fail gracefully, update misleading fallback defaults in Swift source, and document every required secret/variable so an external deployer can fork and deploy without access to `happitec-inc` private repos.

**Estimated time:** ~2 hours

**Audit reference:** [Issue #99 -- Portability Audit](https://github.com/happitec-inc/FederatedActivityPublisher/issues/99)

**What changed since the original plan (2026-03-30):**

- PR #98 merged: all workflows now use flexible runners via `RUNNER_LABELS_LINUX` / `RUNNER_LABELS_MACOS` repository variables with fallback defaults. No work needed for runner flexibility itself.
- PR #100 review feedback: macOS fallback must be `macos-26` (Swift 6.3 requires it), and the `setup-sam-portable` action should be **copied** into this repo rather than inlined.
- The `.env` file pattern for macOS runner PATH is already established.
- DocC workflow already uses `vars.RUNNER_LABELS_MACOS` for flexible runners.

---

## Task 1: Copy `setup-sam-portable` action into this repo

The private `happitec-inc/happitec-logo-generator/.github/actions/setup-sam-portable@main` composite action is the only **required** blocker -- without SAM CLI, nothing deploys. Per PR #100 feedback, copy the action into this repo rather than inlining it.

### 1.1 Create `.github/actions/setup-sam-portable/action.yml`

- [ ] Create the directory `.github/actions/setup-sam-portable/`
- [ ] Copy the composite action from `happitec-logo-generator` into `.github/actions/setup-sam-portable/action.yml`. The action content is:

  ```yaml
  name: Setup AWS SAM CLI (Portable)
  description: |
    Installs the AWS SAM CLI, portable across GitHub-hosted and self-hosted
    macOS runners. Tries in order: existing install, brew, pip, then the
    official setup-sam action (Linux-only installer).

  inputs:
    use-installer:
      description: Allow the setup-sam action's Linux installer as a fallback
      required: false
      default: 'true'
    token:
      description: GitHub token for setup-sam action
      required: false
      default: ${{ github.token }}

  runs:
    using: composite
    steps:
      - name: Check for existing SAM CLI
        id: check
        shell: bash
        run: |
          eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
          if sam --version 2>/dev/null; then
            echo "method=existing" >> "$GITHUB_OUTPUT"
            echo "SAM CLI already installed: $(sam --version)"
          elif command -v brew &>/dev/null; then
            echo "method=brew" >> "$GITHUB_OUTPUT"
            echo "Will install SAM CLI via Homebrew"
          elif command -v pip3 &>/dev/null; then
            echo "method=pip" >> "$GITHUB_OUTPUT"
            echo "Will install SAM CLI via pip"
          else
            echo "method=action" >> "$GITHUB_OUTPUT"
            echo "Will fall back to setup-sam action"
          fi

      - name: Install SAM CLI via Homebrew
        if: steps.check.outputs.method == 'brew'
        shell: bash
        run: |
          eval "$(/opt/homebrew/bin/brew shellenv)"
          brew install aws-sam-cli
          echo "Installed: $(sam --version)"

      - name: Install SAM CLI via pip
        if: steps.check.outputs.method == 'pip'
        shell: bash
        run: |
          pip3 install --break-system-packages aws-sam-cli 2>/dev/null \
            || pip3 install aws-sam-cli
          echo "$HOME/.local/bin" >> "$GITHUB_PATH"
          export PATH="$HOME/.local/bin:$PATH"
          echo "Installed: $(sam --version)"

      - name: Install SAM CLI via setup-sam action
        if: steps.check.outputs.method == 'action' && inputs.use-installer == 'true'
        uses: aws-actions/setup-sam@v2
        with:
          use-installer: true
          token: ${{ inputs.token }}

      - name: Verify SAM CLI
        shell: bash
        run: |
          eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
          export PATH="$HOME/.local/bin:$PATH"
          sam --version
  ```

### 1.2 Update `app.yml` to use local action

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
    uses: ./.github/actions/setup-sam-portable
  ```

### 1.3 Update `bootstrap.yml` to use local action

- [ ] In `.github/workflows/bootstrap.yml`, replace lines 16-19 with:
  ```yaml
  - name: Install SAM CLI
    uses: ./.github/actions/setup-sam-portable
  ```

### 1.4 Update `environment.yml` to use local action

- [ ] In `.github/workflows/environment.yml`, replace lines 25-28 with:
  ```yaml
  - name: Install SAM CLI
    uses: ./.github/actions/setup-sam-portable
  ```

### 1.5 Verify on self-hosted runner

- [ ] Trigger a manual `workflow_dispatch` of `bootstrap.yml` (it is idempotent with `--no-fail-on-empty-changeset`) to confirm SAM CLI installs and runs correctly on the self-hosted Linux runner

**Files:** `.github/actions/setup-sam-portable/action.yml`, `.github/workflows/app.yml`, `.github/workflows/bootstrap.yml`, `.github/workflows/environment.yml`

---

## Task 2: Update macOS fallback to `macos-26`

Swift 6.3 requires macOS 26. All macOS runner fallbacks currently say `macos-15`. Update them to `macos-26`.

### 2.1 Update `deploy-docc.yml` build job

- [ ] In `.github/workflows/deploy-docc.yml` line 28, change:
  ```yaml
  runs-on: ${{ vars.RUNNER_LABELS_MACOS && fromJSON(vars.RUNNER_LABELS_MACOS) || 'macos-15' }}
  ```
  to:
  ```yaml
  runs-on: ${{ vars.RUNNER_LABELS_MACOS && fromJSON(vars.RUNNER_LABELS_MACOS) || 'macos-26' }}
  ```

### 2.2 Update `deploy-docc.yml` deploy job

- [ ] In `.github/workflows/deploy-docc.yml` line 102, apply the same change from `macos-15` to `macos-26`

### 2.3 Verify no other macOS fallbacks remain

- [ ] Search all workflow files for `macos-1` to confirm no other occurrences exist

**Files:** `.github/workflows/deploy-docc.yml`

---

## Task 3: Make DocC workflow optional and fork-friendly

The `deploy-docc.yml` workflow depends on four private-repo resources. The flexible runners are already handled (PR #98). The remaining work is making private-repo features skip gracefully.

### 3.1 Make OG image generation conditional

- [ ] Wrap the `generate-og-image` job in a condition that checks for the PAT:
  ```yaml
  generate-og-image:
    if: vars.ENABLE_DOCC_DEPLOY == 'true'
    uses: happitec-inc/happitec-logo-generator/.github/workflows/generate-og-image.yml@main
  ```
- [ ] Note: reusable workflow calls cannot use `secrets.*` in `if:` conditions, so use a repository variable `vars.ENABLE_DOCC_DEPLOY` as the gate

### 3.2 Make the build job work without OG image

- [ ] Change `needs: [generate-og-image]` to `needs: []` (remove the dependency)
- [ ] Make the "Download OG image" step conditional:
  ```yaml
  - name: Download OG image
    if: vars.ENABLE_DOCC_DEPLOY == 'true'
    uses: actions/download-artifact@v6
  ```

### 3.3 Fall back to upstream swift-docc-render

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

### 3.4 Make OG post-processing conditional

- [ ] Wrap the `docc-og-postprocess` action step in `if: vars.ENABLE_DOCC_DEPLOY == 'true'`

### 3.5 Gate the entire workflow for forks

- [ ] Add a top-level condition on the `build` and `deploy` jobs so the workflow is always active for the upstream repo but forks can opt in:
  ```yaml
  build:
    if: vars.ENABLE_DOCC_DEPLOY == 'true' || github.repository == 'happitec-inc/FederatedActivityPublisher'
  ```

**Files:** `.github/workflows/deploy-docc.yml`

---

## Task 4: Remove Claude code review workflows

The `claude.yml` and `claude-code-review.yml` workflows are org-specific (require `CLAUDE_CODE_OAUTH_TOKEN`) and not needed in CI — code reviews are triggered manually via Claude Code. Remove them entirely.

### 4.1 Delete workflow files

- [ ] `git rm .github/workflows/claude.yml .github/workflows/claude-code-review.yml`

### 4.2 Commit

- [ ] `git commit -m "Remove automated Claude review workflows (manually triggered instead)"`

**Files:** `.github/workflows/claude.yml`, `.github/workflows/claude-code-review.yml` (deleted)

---

## Task 5: Update fallback defaults in Swift source

20 Lambda handler files have `?? "activity.happitec.com"` or `?? "happitec.com"` fallbacks. These are always overridden by environment variables in production, but they are misleading for someone reading the code. Replace with `fatalError` calls that clearly indicate misconfiguration.

### 5.1 Replace `serverDomain` fallbacks

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

### 5.2 Replace `handleDomain` fallbacks

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

### 5.3 Build on Linux VM

- [ ] SSH to the Linux runner VM and build to verify all handlers compile:
  ```bash
  swift build --build-tests 2>&1 | tail -20
  ```

**Files:** All handler `main.swift` files listed above

---

## Task 6: Document all required secrets and variables

Add a comprehensive configuration reference to `README.md` so external deployers know exactly what to set up before running any workflow.

### 6.1 Add secrets and variables table to README

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
  | `CLAUDE_CODE_OAUTH_TOKEN` | _(removed)_ | Automated Claude reviews removed; trigger manually via Claude Code |

  **Repository Variables:**

  | Variable | Used by | Default | Description |
  |----------|---------|---------|-------------|
  | `RUNNER_LABELS_LINUX` | app, bootstrap, environment | `"ubuntu-latest"` | JSON array of runner labels, e.g. `["self-hosted", "linux"]` |
  | `RUNNER_LABELS_MACOS` | deploy-docc | `"macos-26"` | JSON array of runner labels for macOS jobs |
  | `PROXY_DISTRIBUTION_ID` | app | _(empty)_ | CloudFront distribution ID for cross-distribution cache invalidation; leave empty if not using a parent domain proxy |
  | `ENABLE_DOCC_DEPLOY` | deploy-docc | _(unset)_ | Set to `true` to enable private-repo DocC features (OG images, Mermaid diagrams) |

### 6.2 Add SAM parameter overrides reference

- [ ] In the same `## Configuration` section, add a sub-section documenting the key SAM parameter overrides:

  | Parameter | Stack | Description |
  |-----------|-------|-------------|
  | `ServerDomain` | app | The domain the ActivityPub server runs on (e.g. `activity.example.com`) |
  | `HandleDomain` | app | The domain used in ActivityPub handles (e.g. `example.com` for `@user@example.com`) |
  | `ProxyDistributionId` | app | Optional cross-distribution invalidation target; empty string to skip |
  | `Stage` | app, environment | `stage` or `prod` |

### 6.3 Remove hardcoded API Gateway URLs from AGENTS.md

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

- [ ] Trigger `bootstrap.yml` via `workflow_dispatch` -- should install SAM CLI via local action and succeed
- [ ] Trigger `environment.yml` via `workflow_dispatch` with stage `stage` -- should succeed
- [ ] Push to `main` to trigger `app.yml` -- should succeed (or trigger manually)
- [ ] Confirm `deploy-docc.yml` runs without errors when `ENABLE_DOCC_DEPLOY` is unset (fork scenario)
- [ ] Confirm `claude.yml` and `claude-code-review.yml` skip cleanly on a fork
- [ ] Confirm Swift build passes on Linux after fallback removal

---

## Already completed (PR #98)

The following items from the original audit are done and do not need further work:

- **Flexible runners**: All workflows use `RUNNER_LABELS_LINUX` / `RUNNER_LABELS_MACOS` repository variables with GitHub-hosted fallbacks
- **Self-hosted runner cleanup**: Conditional cleanup steps gated on `vars.RUNNER_LABELS_LINUX`
- **PATH workaround for macOS**: `.env` file pattern established for self-hosted macOS runners
