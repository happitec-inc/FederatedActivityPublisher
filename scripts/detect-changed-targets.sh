#!/usr/bin/env bash
# detect-changed-targets.sh
#
# Reads a list of changed file paths from stdin (one per line, as produced by
# `git diff --name-only`) and prints the Swift targets that need rebuilding.
#
# Output:
#   "all"   — if global build inputs changed (Package.swift, Package.resolved, Dockerfile)
#   "none"  — if no Swift source files changed
#   Otherwise, a sorted, deduplicated list of handler target names, one per line.
#
# Usage:
#   git diff --name-only deploy-stage HEAD | bash scripts/detect-changed-targets.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Dependency matrix (from Package.swift / Appendix B of the design spec)
# ---------------------------------------------------------------------------
# Handlers that depend on ActivityPubCore (all except NodeInfoHandler, InstanceHandler):
ACTIVITYPUBCORE_DEPENDENTS=(
  ActorHandler
  AuthHandler
  ComposeHandler
  DeliverHandler
  FeaturedHandler
  FeaturedTagsHandler
  FollowersHandler
  FollowingHandler
  InboxHandler
  MediaUploadHandler
  ObjectHandler
  OutboxHandler
  PostHandler
  ProfileHandler
  ProfileUpdateHandler
  WebFingerHandler
)

# All Lambda handler targets (everything except ActivityProvisioner, which is a CLI tool):
ALL_LAMBDA_HANDLERS=(
  ActorHandler
  AuthHandler
  ComposeHandler
  DeliverHandler
  FeaturedHandler
  FeaturedTagsHandler
  FollowersHandler
  FollowingHandler
  InboxHandler
  InstanceHandler
  MediaUploadHandler
  NodeInfoHandler
  ObjectHandler
  OutboxHandler
  PostHandler
  ProfileHandler
  ProfileUpdateHandler
  WebFingerHandler
)

# ---------------------------------------------------------------------------
# Read changed file paths from stdin
# ---------------------------------------------------------------------------
CHANGED_FILES=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  CHANGED_FILES+=("$line")
done

if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
  echo "none"
  exit 0
fi

# ---------------------------------------------------------------------------
# Check for global build-input changes that require a full rebuild
# ---------------------------------------------------------------------------
for file in "${CHANGED_FILES[@]}"; do
  case "$file" in
    Package.swift|Package.resolved|docker/Dockerfile.al2023-swift)
      echo "all"
      exit 0
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Map changed source files to targets
# ---------------------------------------------------------------------------
TARGETS_LIST=""

for file in "${CHANGED_FILES[@]}"; do
  # Check if this is under Sources/
  if [[ "$file" == Sources/* ]]; then
    # Skip DocC documentation files — they don't affect compiled Lambda binaries.
    # DocC builds run in a separate workflow (deploy-docc.yml).
    if [[ "$file" == */Documentation.docc/* ]]; then
      continue
    fi

    # Extract the target directory name: Sources/{TargetName}/...
    target_dir="${file#Sources/}"
    target_name="${target_dir%%/*}"

    if [[ "$target_name" == "ActivityPubCore" ]]; then
      # ActivityPubCore changed — all its dependents need rebuilding
      for dep in "${ACTIVITYPUBCORE_DEPENDENTS[@]}"; do
        TARGETS_LIST="${TARGETS_LIST}${dep}"$'\n'
      done
    elif [[ "$target_name" == "ActivityProvisioner" ]]; then
      # CLI tool, not a Lambda — skip
      continue
    elif [[ "$target_name" == "APIClient" ]]; then
      # Generated client, not a Lambda — skip
      continue
    else
      # Individual handler changed
      TARGETS_LIST="${TARGETS_LIST}${target_name}"$'\n'
    fi
  fi
  # Non-source files (templates, docs, workflows, etc.) are ignored
done

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -z "$TARGETS_LIST" ]]; then
  echo "none"
  exit 0
fi

# Print sorted, deduplicated target names
echo "$TARGETS_LIST" | grep -v '^$' | sort -u
