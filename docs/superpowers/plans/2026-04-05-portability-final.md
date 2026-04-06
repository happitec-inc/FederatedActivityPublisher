# Portability Final: Make FederatedActivityPublisher Fully Forkable

**Date:** 2026-04-05
**Status:** Ready for execution
**Scope:** Remove all hardcoded happitec.com values, parameterize runner labels and AWS region, decouple from private repos

## Overview

This plan addresses 12 audit findings (4 blockers, 8 friction items) that prevent external users from forking and deploying FederatedActivityPublisher without manual find-and-replace. Every change is a no-op for the happitec-inc deployment when the correct repo variables are set. No functionality changes.

## Prerequisites

- Repository variables `SERVER_DOMAIN` and `HANDLE_DOMAIN` must already be set (they are)
- Familiarity with the existing variable fallback pattern commented out in workflows

---

## Task 1: Uncomment Runner Label Variable Fallback (BLOCKER)

Replace hardcoded `linux_large` with the variable fallback pattern that already exists in comments.

Every workflow has this commented out:
```yaml
# runs-on: ${{ vars.RUNNER_LABELS_LINUX && fromJSON(vars.RUNNER_LABELS_LINUX) || 'ubuntu-latest' }}
runs-on: linux_large
```

Change to:
```yaml
runs-on: ${{ vars.RUNNER_LABELS_LINUX && fromJSON(vars.RUNNER_LABELS_LINUX) || 'ubuntu-latest' }}
```

Also uncomment the associated "Clean workspace (self-hosted)" steps where present.

### Files to modify

| File | Runner type | Has clean step? |
|------|------------|-----------------|
| `.github/workflows/build.yml` | Linux | Yes |
| `.github/workflows/fast-stage-deploy.yml` | Linux | No |
| `.github/workflows/integration-tests.yml` | Linux | No |
| `.github/workflows/provision-actor.yml` | Linux | Yes |
| `.github/workflows/bootstrap.yml` | Linux | No |
| `.github/workflows/environment.yml` | Linux | No |
| `.github/workflows/test.yml` | Linux | Yes |
| `.github/workflows/run-integration-tests.yml` | Linux | Yes |
| `.github/workflows/deploy-docc.yml` (2 jobs) | macOS | No |

**Post-change:** Set `RUNNER_LABELS_LINUX` to `["linux_large"]` as a repo variable for happitec-inc. Forks without this variable use `ubuntu-latest`.

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

### Files: all 10 workflow files + 2 samconfig.toml files

Remove `region = "us-east-1"` from `activity-bootstrap/samconfig.toml` and `activity-environment/samconfig.toml`, replace with a comment explaining region is set by workflows.

---

## Task 3: Parameterize OpenAPI Server URLs (BLOCKER)

Replace hardcoded happitec.com URLs in `openapi.yaml` with `example.com` placeholders.

### Changes

- Title: `activity.happitec.com` -> `FederatedActivityPublisher`
- Description: Remove "happitec-inc" reference
- Server URLs: Use `activity.example.com` with description "replace with your SERVER_DOMAIN"
- WebFinger examples: Use `acct:myactor@example.com`
- NodeInfo software name example: `federated-activity-publisher`

---

## Task 4: Remove Hardcoded Domain from RegisterPasskey.swift (BLOCKER)

Make `--domain` a required argument instead of defaulting to `happitec.com`.

```swift
// Before:
@Option(help: "Server domain")
var domain: String = "happitec.com"

// After:
@Option(help: "Server domain (e.g. example.com)")
var domain: String
```

The `provision-actor.yml` workflow already passes the domain explicitly.

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
| `Package.swift` line 6 | `"activity-happitec"` -> `"federated-activity-publisher"` |
| `Sources/NodeInfoHandler/main.swift` | `"activity-happitec"` -> `"federated-activity-publisher"` |

---

## Task 7: Parameterize Instance Metadata (FRICTION)

Remove "happitec-inc" references from `Sources/InstanceHandler/main.swift`.

Read `INSTANCE_TITLE` from env with default `"FederatedActivityPublisher"`. Change description to generic text. Keep `source_url` pointing to upstream repo (forks should credit upstream).

No SAM parameter changes needed — use environment variable with a sensible default in code.

---

## Task 8: Update SAM Template Default Parameters (FRICTION)

Replace `happitec.com` defaults with `example.com` in all template parameters.

| File | Parameter | New Default |
|------|-----------|-------------|
| `activity-app/template.yaml` | `ServerDomain` | `example.com` |
| `activity-app/template.yaml` | `HandleDomain` | `example.com` |
| `activity-app/template.yaml` | Description | `FederatedActivityPublisher App Stack` |
| `activity-app/functions/template.yaml` | descriptions | Use `example.com` |
| `activity-app/cdn/template.yaml` | descriptions | Use `example.com` |
| `activity-bootstrap/template.yaml` | `DomainName` | Remove default (make required) |
| `activity-bootstrap/template.yaml` | descriptions | Generic wording |

---

## Task 9: Update Documentation Examples (FRICTION)

Replace happitec.com with example.com across all documentation.

### Global substitutions

| Find | Replace |
|------|---------|
| `activity.happitec.com` | `activity.example.com` |
| `happitec.com` (as domain) | `example.com` |
| `@logos@happitec.com` | `@myapp@example.com` |
| `@randomforms@happitec.com` | `@myactor@example.com` |
| `happitec-inc` (as org name) | `your-org` |
| `docs.happitec.com/FederatedActivityPublisher` | `your-org.github.io/FederatedActivityPublisher` |

Do NOT change `source_url` pointing to the canonical GitHub repo.

### Files: README.md, AGENTS.md, all 14 DocC articles

---

## Execution Order

1. Task 1 (runner labels) — standalone YAML
2. Task 2 (region) — standalone YAML
3. Task 6 (package rename) — Package.swift + NodeInfo
4. Task 4 (RegisterPasskey) — single Swift file
5. Task 7 (instance metadata) — single Swift file
6. Task 3 (OpenAPI) — single file
7. Task 8 (template defaults) — multiple YAML
8. Task 5 (deploy-docc) — single workflow
9. Task 9 (documentation) — many files, do last
10. Task 11 (README config table) — part of Task 9

---

## Testing / Verification

### Pre-merge

1. `swift test --filter ActivityPubCoreTests` — verifies package rename
2. `swift test --filter IntegrationTests` — verifies no runtime breakage
3. YAML syntax check on all modified workflows
4. `sam validate` on all templates

### Post-merge (happitec-inc)

1. Set repo variables: `RUNNER_LABELS_LINUX=["linux_large"]`, `AWS_REGION=us-east-1`
2. Trigger full build+deploy to stage
3. Verify federation endpoints return correct data
4. Verify NodeInfo software name: `curl -s https://activity.happitec.com/nodeinfo/2.1 | jq .software.name`

### Fork validation checklist

A fresh fork should be able to:
- [ ] `swift build` without any find-and-replace
- [ ] `swift test` without any find-and-replace
- [ ] Run Test workflow on `ubuntu-latest`
- [ ] Run Bootstrap/Environment/Build workflows with their own domain
- [ ] Deploy to their own AWS account

---

## Summary: ~36 files modified

- 4 Swift source files
- 1 OpenAPI spec
- 10 GitHub workflows
- 4 SAM templates + 2 SAM configs
- 16 documentation files (README, AGENTS, 14 DocC articles)
