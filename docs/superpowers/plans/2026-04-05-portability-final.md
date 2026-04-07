# Portability Final: Make FederatedActivityPublisher Fully Forkable

**Date:** 2026-04-05 (revised after user review)
**Status:** Ready for execution
**Scope:** Remove all hardcoded happitec.com values, parameterize runner labels and AWS region, decouple from private repos

## Overview

This plan addresses 12 audit findings (4 blockers, 8 friction items) that prevent external users from forking and deploying FederatedActivityPublisher without manual find-and-replace. Every change is a no-op for the happitec-inc deployment when the correct repo variables are set. No functionality changes.

**Key design decision:** Rather than replacing hardcoded domains with `example.com` (which makes the project unusable for everyone), we use **build-time variable substitution**. Template files contain `{{SERVER_DOMAIN}}` / `{{HANDLE_DOMAIN}}` placeholders that get substituted from repo variables before compile/deploy. The project stays functional for happitec-inc without changes, and forks set their own variables.

## Prerequisites

- Repository variables `SERVER_DOMAIN` and `HANDLE_DOMAIN` must already be set (they are)
- Familiarity with the existing variable fallback pattern commented out in workflows

---

## Task 0: Build-Time Variable Substitution Script

**Goal:** Create a script that substitutes domain placeholders in template files before build/deploy.

### Create `scripts/substitute-variables.sh`

```bash
#!/usr/bin/env bash
# substitute-variables.sh
#
# Replaces {{SERVER_DOMAIN}} and {{HANDLE_DOMAIN}} placeholders in specified
# files with values from environment variables or arguments.
#
# Usage:
#   SERVER_DOMAIN=happitec.com HANDLE_DOMAIN=happitec.com bash scripts/substitute-variables.sh
#   bash scripts/substitute-variables.sh --server-domain happitec.com --handle-domain happitec.com

set -euo pipefail

SERVER_DOMAIN="${SERVER_DOMAIN:-${1:-}}"
HANDLE_DOMAIN="${HANDLE_DOMAIN:-${2:-}}"

if [ -z "$SERVER_DOMAIN" ] || [ -z "$HANDLE_DOMAIN" ]; then
  echo "Error: SERVER_DOMAIN and HANDLE_DOMAIN must be set"
  echo "Usage: SERVER_DOMAIN=x HANDLE_DOMAIN=y bash scripts/substitute-variables.sh"
  exit 1
fi

# Files that contain placeholders
FILES=(
  "openapi.yaml"
  "Sources/ActivityPubCore/Documentation.docc/GettingStarted.md"
  "Sources/ActivityPubCore/Documentation.docc/ArchitectureOverview.md"
  "Sources/ActivityPubCore/Documentation.docc/BuildingAndDeploying.md"
  "Sources/ActivityPubCore/Documentation.docc/DeployYourOwn.md"
  "Sources/ActivityPubCore/Documentation.docc/DNSSetup.md"
  "Sources/ActivityPubCore/Documentation.docc/NestedStacksOverview.md"
  "Sources/ActivityPubCore/Documentation.docc/ProvisioningAccounts.md"
  "AGENTS.md"
)

for file in "${FILES[@]}"; do
  if [ -f "$file" ]; then
    sed -i.bak \
      -e "s/{{SERVER_DOMAIN}}/$SERVER_DOMAIN/g" \
      -e "s/{{HANDLE_DOMAIN}}/$HANDLE_DOMAIN/g" \
      "$file"
    rm -f "$file.bak"
    echo "Substituted: $file"
  fi
done
```

### Integration into workflows

Add a step early in `build.yml` and `deploy-docc.yml`:

```yaml
- name: Substitute domain variables
  run: |
    SERVER_DOMAIN="${{ vars.SERVER_DOMAIN }}" \
    HANDLE_DOMAIN="${{ vars.HANDLE_DOMAIN }}" \
    bash scripts/substitute-variables.sh
```

The OpenAPI spec needs substitution before `swift package archive` since the code generator reads it. The DocC articles need substitution before `docc` runs.

### Important: the substituted files are NOT committed

The substitution happens in the CI workspace only. The repo always contains the `{{SERVER_DOMAIN}}` placeholders. `.gitignore` doesn't need changes since the files are modified in-place during the build, not generated.

---

## Task 1: Uncomment Runner Label Variable Fallback (BLOCKER)

Replace hardcoded `linux_large` with the variable fallback pattern that already exists in comments.

### Linux workflows

Every Linux workflow has this commented out:
```yaml
# runs-on: ${{ vars.RUNNER_LABELS_LINUX && fromJSON(vars.RUNNER_LABELS_LINUX) || 'ubuntu-latest' }}
runs-on: linux_large
```

Change to:
```yaml
runs-on: ${{ vars.RUNNER_LABELS_LINUX && fromJSON(vars.RUNNER_LABELS_LINUX) || 'ubuntu-latest' }}
```

Also uncomment the associated "Clean workspace (self-hosted)" steps where present.

| File | Has clean step? |
|------|-----------------|
| `.github/workflows/build.yml` | Yes |
| `.github/workflows/fast-stage-deploy.yml` | No |
| `.github/workflows/integration-tests.yml` | No |
| `.github/workflows/provision-actor.yml` | Yes |
| `.github/workflows/bootstrap.yml` | No |
| `.github/workflows/environment.yml` | No |
| `.github/workflows/test.yml` | Yes |
| `.github/workflows/run-integration-tests.yml` | Yes |

### macOS workflows (deploy-docc.yml)

`deploy-docc.yml` has two jobs that use macOS. These must use `RUNNER_LABELS_MACOS`, NOT `RUNNER_LABELS_LINUX`:

```yaml
runs-on: ${{ vars.RUNNER_LABELS_MACOS && fromJSON(vars.RUNNER_LABELS_MACOS) || 'macos-26' }}
```

### Post-change variable setup

Set on happitec-inc repo before merging:
```bash
gh variable set RUNNER_LABELS_LINUX --body '["linux_large"]' --repo happitec-inc/FederatedActivityPublisher
gh variable set RUNNER_LABELS_MACOS --body '["macos-26"]' --repo happitec-inc/FederatedActivityPublisher
```

### Documentation

Add to README and DeployYourOwn.md:
- `RUNNER_LABELS_LINUX`: JSON array of runner labels for Linux jobs. Default: `ubuntu-latest`. Set to `["self-hosted", "linux"]` for self-hosted.
- `RUNNER_LABELS_MACOS`: JSON array of runner labels for macOS jobs. Default: `macos-26`.

---

## Task 2: Parameterize AWS Region (FRICTION)

Replace all hardcoded `us-east-1` with `${{ vars.AWS_REGION || 'us-east-1' }}` in workflows.

### Approach

For `aws-region:` in credential steps:
```yaml
aws-region: ${{ vars.AWS_REGION || 'us-east-1' }}
```

For `--region` in shell commands, add job-level env:
```yaml
env:
  AWS_REGION: ${{ vars.AWS_REGION || 'us-east-1' }}
```
Then replace `--region us-east-1` with `--region $AWS_REGION`.

### Files: all 10 workflow files (including deploy.yml which has 6 occurrences) + 2 samconfig.toml files

Remove `region = "us-east-1"` from `activity-bootstrap/samconfig.toml` and `activity-environment/samconfig.toml`, replace with a comment explaining region is set by workflows.

---

## Task 3: Parameterize OpenAPI Spec (BLOCKER)

### Consolidate to one copy

There are currently two copies of the OpenAPI spec:
- `openapi.yaml` (root — source of truth)
- `Sources/APIClient/openapi.yaml` (consumed by swift-openapi-generator)

Delete `Sources/APIClient/openapi.yaml` and configure the openapi-generator plugin to read from the root copy. If the plugin requires the file at a specific path, add a build step that copies root → Sources/APIClient/ before compile.

### Replace domains with placeholders

In `openapi.yaml`:

- Title: `activity.happitec.com` → `FederatedActivityPublisher`
- Description: `Serverless ActivityPub server for happitec-inc` → `Serverless ActivityPub server. A project by Happitec.`
- Server URLs: Use `{{SERVER_DOMAIN}}` placeholders:
  ```yaml
  servers:
    - url: https://{{SERVER_DOMAIN}}
      description: Production (federation)
    - url: https://stage.{{SERVER_DOMAIN}}
      description: Stage (federation)
  ```
- WebFinger examples: `acct:myactor@{{HANDLE_DOMAIN}}`
- NodeInfo software name example: `federated-activity-publisher`

The `scripts/substitute-variables.sh` script (Task 0) substitutes these before build.

---

## Task 4: Remove Hardcoded Domains from ActivityProvisioner (BLOCKER)

### RegisterPasskey.swift

Make `--domain` a required argument instead of defaulting to `happitec.com`.

```swift
// Before:
@Option(help: "Server domain")
var domain: String = "happitec.com"

// After:
@Option(help: "Server domain (e.g. example.com)")
var domain: String
```

### ActivityProvisioner.swift

Make `--server-domain` and `--handle-domain` required arguments (no defaults):

```swift
// Before:
var serverDomain: String = "activity.happitec.com"
var handleDomain: String = "happitec.com"
var region: String = "us-east-1"

// After:
var serverDomain: String  // required
var handleDomain: String  // required
var region: String = "us-east-1"  // keep default
```

The `provision-actor.yml` workflow already passes both via `${{ vars.SERVER_DOMAIN }}` and `${{ vars.HANDLE_DOMAIN }}`.

### bootstrap.yml workflow input default

Line 12 has `default: "activity.happitec.com"`. Remove the default to force explicit input.

---

## Task 5: Decouple deploy-docc.yml from Private Repos (BLOCKER)

The workflow already has conditional logic gating private features. Fix remaining issues:

1. **base-url:** Change hardcoded `docs.happitec.com` to:
   ```yaml
   base-url: ${{ vars.DOCC_BASE_URL || format('https://{0}.github.io/FederatedActivityPublisher', github.repository_owner) }}
   ```

2. **Build/deploy conditions:** Remove `github.repository == 'happitec-inc/FederatedActivityPublisher'` special case. Use `vars.ENABLE_DOCC_DEPLOY` consistently.

---

## Task 6: Rename Package and Software Identifiers (FRICTION)

| File | Change |
|------|--------|
| `Package.swift` line 6 | `"activity-happitec"` → `"federated-activity-publisher"` |
| `Sources/NodeInfoHandler/main.swift` | `"activity-happitec"` → `"federated-activity-publisher"` |

---

## Task 7: Parameterize Instance Metadata (FRICTION)

Remove generic "happitec-inc" references from `Sources/InstanceHandler/main.swift`.

- Title: Read `INSTANCE_TITLE` from env, default `"FederatedActivityPublisher"`
- Description: `"A serverless ActivityPub server powered by FederatedActivityPublisher. A project by Happitec."`
- `source_url`: Keep pointing to upstream repo (forks should credit upstream)

No SAM parameter changes needed — use environment variable with sensible default in code.

---

## Task 8: Update SAM Template Parameters (FRICTION)

Replace `happitec.com` defaults in SAM parameters. Since these are always overridden by workflow parameter-overrides, the defaults are just documentation. Remove defaults and make required where appropriate:

| File | Parameter | Change |
|------|-----------|--------|
| `activity-app/template.yaml` | `ServerDomain` | Remove default, add description "Required. Your server domain." |
| `activity-app/template.yaml` | `HandleDomain` | Remove default, add description "Required. Your handle domain." |
| `activity-app/template.yaml` | Description | `FederatedActivityPublisher App Stack — Root Orchestrator` |
| `activity-app/functions/template.yaml` | descriptions | Remove happitec.com references |
| `activity-app/cdn/template.yaml` | descriptions | Remove happitec.com references |
| `activity-bootstrap/template.yaml` | `DomainName` | Remove default (already required via workflow input) |

---

## Task 9: Update Documentation with Placeholders (FRICTION)

Replace hardcoded domains in documentation with `{{SERVER_DOMAIN}}` / `{{HANDLE_DOMAIN}}` placeholders where the content is build-substituted, or with generic descriptions where it's purely instructional.

### Files that get build-time substitution (use `{{placeholders}}`)

These are listed in the `substitute-variables.sh` FILES array:
- `AGENTS.md`
- DocC articles: GettingStarted, ArchitectureOverview, BuildingAndDeploying, DeployYourOwn, DNSSetup, NestedStacksOverview, ProvisioningAccounts

Replace `happitec.com` → `{{SERVER_DOMAIN}}`, `@logos@happitec.com` → `@myapp@{{HANDLE_DOMAIN}}`, etc.

### Files that stay as-is (no substitution needed)

- `README.md` — Keep as the canonical project README. Attribution to Happitec is fine. Update the description to be welcoming to forks: "Originally built for Happitec brand accounts. Fork it to run your own."
- `ActivityPubCore.md` — Keep "A project by Happitec" attribution.
- DocC articles that don't reference specific domains (AuthenticationOverview, CostEstimates, DataStoreOverview, etc.)

### Global approach for documentation

| Find | Replace with |
|------|-------------|
| `activity.happitec.com` (as example domain) | `{{SERVER_DOMAIN}}` |
| `happitec.com` (as example handle domain) | `{{HANDLE_DOMAIN}}` |
| `@logos@happitec.com` | `@myapp@{{HANDLE_DOMAIN}}` |
| `happitec-inc` (as org name in instructions) | `your-org` or keep as Happitec attribution |
| `docs.happitec.com/FederatedActivityPublisher` | `your-org.github.io/FederatedActivityPublisher` |

Do NOT change:
- `source_url` pointing to the canonical GitHub repo
- Attribution lines ("A project by Happitec")
- The README project description (keep Happitec branding, add fork-friendly language)

---

## Pre-merge: Set Repo Variables

Before merging, set these variables on the happitec-inc repo so workflows don't break:

```bash
gh variable set RUNNER_LABELS_LINUX --body '["linux_large"]' --repo happitec-inc/FederatedActivityPublisher
gh variable set RUNNER_LABELS_MACOS --body '["macos-26"]' --repo happitec-inc/FederatedActivityPublisher
gh variable set AWS_REGION --body 'us-east-1' --repo happitec-inc/FederatedActivityPublisher
```

`ENABLE_DOCC_DEPLOY` should already be set to `true`. Verify with `gh variable list`.

## Execution Order

1. Task 0 (substitution script) — new script, no dependencies
2. Task 1 (runner labels) — standalone YAML, split Linux/macOS correctly
3. Task 2 (region) — standalone YAML
4. Task 6 (package rename) — Package.swift + NodeInfo
5. Task 4 (ActivityProvisioner + bootstrap defaults) — Swift files + workflow
6. Task 7 (instance metadata) — single Swift file
7. Task 3 (OpenAPI — consolidate + placeholders) — spec file + build config
8. Task 8 (template defaults) — multiple YAML
9. Task 5 (deploy-docc) — single workflow
10. Task 9 (documentation placeholders) — many files, do last

---

## Testing / Verification

### Pre-merge

1. Run `scripts/substitute-variables.sh` with test values and verify output
2. `swift test --filter ActivityPubCoreTests` — verifies package rename
3. `swift test --filter IntegrationTests` — verifies no runtime breakage
4. YAML syntax check on all modified workflows
5. `sam validate` on all templates

### Post-merge (happitec-inc)

1. Verify repo variables: `RUNNER_LABELS_LINUX`, `RUNNER_LABELS_MACOS`, `AWS_REGION`
2. Trigger full build+deploy to stage — verify substitution runs and OpenAPI spec has correct domains
3. Verify federation endpoints return correct data
4. Verify NodeInfo software name: `curl -s https://activity.happitec.com/nodeinfo/2.1 | jq .software.name`
5. Verify DocC documentation renders with correct domains

### Fork validation checklist

A fresh fork should be able to:
- [ ] `swift build` without any find-and-replace (placeholders only in docs/OpenAPI, not Swift source)
- [ ] `swift test` without any find-and-replace
- [ ] Set `SERVER_DOMAIN` and `HANDLE_DOMAIN` repo variables
- [ ] Run Test workflow on `ubuntu-latest`
- [ ] Run Bootstrap/Environment/Build workflows with their own domain
- [ ] Deploy to their own AWS account
- [ ] See their domain in OpenAPI spec, documentation, and instance metadata

---

## Summary: ~37 files modified

- 1 new script (`scripts/substitute-variables.sh`)
- 5 Swift source files (Package.swift, RegisterPasskey.swift, ActivityProvisioner.swift, NodeInfoHandler, InstanceHandler)
- 1 OpenAPI spec (consolidate to root only)
- 10 GitHub workflows
- 4 SAM templates + 2 SAM configs
- ~14 documentation files (README, AGENTS, DocC articles with placeholders)
