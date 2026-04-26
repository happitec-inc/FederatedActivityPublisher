#!/usr/bin/env bash
# test-detect-changed-targets.sh
# Smoke tests for scripts/detect-changed-targets.sh.
# Run from the repo root: bash scripts/test-detect-changed-targets.sh

set -euo pipefail

SCRIPT="$(dirname "$0")/detect-changed-targets.sh"
FAIL=0

assert_eq() {
  local name=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then
    echo "ok  - $name"
  else
    echo "FAIL - $name"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual:   $(printf '%q' "$actual")"
    FAIL=$((FAIL + 1))
  fi
}

# Empty input -> none
assert_eq "empty input -> none" \
  "none" \
  "$(printf "" | bash "$SCRIPT")"

# DocC-only change -> none (regression for issue #223)
assert_eq "docc-only change -> none" \
  "none" \
  "$(echo "Sources/ActivityPubCore/Documentation.docc/DNSSetup.md" | bash "$SCRIPT")"

# Multiple docc files -> none
assert_eq "multiple docc files -> none" \
  "none" \
  "$(printf "Sources/ActivityPubCore/Documentation.docc/A.md\nSources/ActivityPubCore/Documentation.docc/B.md\n" | bash "$SCRIPT")"

# Single handler change -> that handler
assert_eq "PostHandler change -> PostHandler" \
  "PostHandler" \
  "$(echo "Sources/PostHandler/main.swift" | bash "$SCRIPT")"

# ActivityPubCore swift change -> all 16 dependents
ACTIVITYPUBCORE_DEPS=$(printf "ActorHandler\nAuthHandler\nComposeHandler\nDeliverHandler\nFeaturedHandler\nFeaturedTagsHandler\nFollowersHandler\nFollowingHandler\nInboxHandler\nMediaUploadHandler\nObjectHandler\nOutboxHandler\nPostHandler\nProfileHandler\nProfileUpdateHandler\nWebFingerHandler")
assert_eq "ActivityPubCore swift change -> dependents" \
  "$ACTIVITYPUBCORE_DEPS" \
  "$(echo "Sources/ActivityPubCore/BearerAuth.swift" | bash "$SCRIPT")"

# DocC + real swift change -> dependents (docc files don't suppress real changes)
assert_eq "docc + swift change -> dependents" \
  "$ACTIVITYPUBCORE_DEPS" \
  "$(printf "Sources/ActivityPubCore/Documentation.docc/Foo.md\nSources/ActivityPubCore/BearerAuth.swift\n" | bash "$SCRIPT")"

# ActivityProvisioner is a CLI tool, not a Lambda -> none
assert_eq "ActivityProvisioner change -> none" \
  "none" \
  "$(echo "Sources/ActivityProvisioner/main.swift" | bash "$SCRIPT")"

# APIClient is generated, not a Lambda -> none
assert_eq "APIClient change -> none" \
  "none" \
  "$(echo "Sources/APIClient/Generated.swift" | bash "$SCRIPT")"

# Package.swift -> all
assert_eq "Package.swift -> all" \
  "all" \
  "$(echo "Package.swift" | bash "$SCRIPT")"

# Package.resolved -> all
assert_eq "Package.resolved -> all" \
  "all" \
  "$(echo "Package.resolved" | bash "$SCRIPT")"

# Dockerfile -> all
assert_eq "Dockerfile -> all" \
  "all" \
  "$(echo "docker/Dockerfile.al2023-swift" | bash "$SCRIPT")"

# Non-source file (workflow) -> none (filtered upstream by deploy-stage.yml,
# but the script should not emit a target for these either)
assert_eq "workflow change -> none" \
  "none" \
  "$(echo ".github/workflows/deploy-stage.yml" | bash "$SCRIPT")"

# Multiple distinct handlers -> sorted, deduplicated
assert_eq "multiple handlers -> sorted unique" \
  "$(printf "AuthHandler\nPostHandler")" \
  "$(printf "Sources/PostHandler/main.swift\nSources/AuthHandler/main.swift\nSources/PostHandler/other.swift\n" | bash "$SCRIPT")"

if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "$FAIL test(s) failed"
  exit 1
fi

echo ""
echo "All tests passed"
