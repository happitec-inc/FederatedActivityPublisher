#!/usr/bin/env bash
# build-selective.sh
#
# Builds specified Swift Lambda targets inside the Docker container and packages
# each as a zip file in the format expected by `sam package`.
#
# Usage:
#   bash scripts/build-selective.sh ComposeHandler PostHandler
#   bash scripts/build-selective.sh all
#
# Output layout (per target):
#   .build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager/{Target}/{Target}.zip
#
# This matches the output of `swift package archive` so that `sam package`
# works unchanged.
#
# Notes:
#   - Skips ActivityProvisioner (CLI tool, not a Lambda)
#   - Exits non-zero if any target fails to build
#   - Prints timing for each target

set -euo pipefail

# All Lambda handler targets (sorted alphabetically)
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
# Parse arguments
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <target1> [target2 ...] | all"
  echo "  all    Build all Lambda handler targets"
  exit 1
fi

TARGETS=()
if [[ "$1" == "all" ]]; then
  TARGETS=("${ALL_LAMBDA_HANDLERS[@]}")
else
  for arg in "$@"; do
    # Skip ActivityProvisioner if someone passes it
    if [[ "$arg" == "ActivityProvisioner" ]]; then
      echo "Skipping ActivityProvisioner (CLI tool, not a Lambda)"
      continue
    fi
    TARGETS+=("$arg")
  done
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No targets to build."
  exit 0
fi

echo "========================================="
echo "Building ${#TARGETS[@]} target(s):"
printf '  %s\n' "${TARGETS[@]}"
echo "========================================="

OUTPUT_BASE=".build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager"
STAGING_DIR=".build/lambda-staging"
FAILED=0
TOTAL_START=$SECONDS

for target in "${TARGETS[@]}"; do
  echo ""
  echo "-----------------------------------------"
  echo "Building: $target"
  echo "-----------------------------------------"
  TARGET_START=$SECONDS

  # Build the target
  if ! swift build -c release --product "$target" --static-swift-stdlib -Xlinker -s; then
    echo "FAILED: $target"
    FAILED=1
    continue
  fi

  # Stage the binary as 'bootstrap' (AWS Lambda custom runtime convention)
  STAGE_PATH="$STAGING_DIR/$target"
  mkdir -p "$STAGE_PATH"
  cp ".build/release/$target" "$STAGE_PATH/bootstrap"

  # Create the zip in the expected output location
  OUTPUT_DIR="$OUTPUT_BASE/$target"
  mkdir -p "$OUTPUT_DIR"
  (cd "$STAGE_PATH" && zip -j "$OLDPWD/$OUTPUT_DIR/$target.zip" bootstrap)

  TARGET_ELAPSED=$((SECONDS - TARGET_START))
  echo "Completed: $target (${TARGET_ELAPSED}s)"
done

TOTAL_ELAPSED=$((SECONDS - TOTAL_START))
echo ""
echo "========================================="
echo "Build complete in ${TOTAL_ELAPSED}s"
if [[ $FAILED -ne 0 ]]; then
  echo "WARNING: One or more targets failed to build!"
  exit 1
fi
echo "All targets built successfully."
echo "========================================="
