#!/usr/bin/env bash
# prod-alias-swap.sh
#
# Atomically swaps a CloudFront distribution alias from one distribution to
# another, with automatic rollback if the second step fails.
#
# This is used during prod migration (Phase 4) to move the production domain
# alias from the old flat-stack CloudFront distribution to the new nested-stack
# distribution with minimal downtime.
#
# Usage:
#   bash scripts/prod-alias-swap.sh <OLD_CF_ID> <NEW_CF_ID> [ALIAS]
#
# Arguments:
#   OLD_CF_ID   CloudFront distribution ID currently holding the alias
#   NEW_CF_ID   CloudFront distribution ID to receive the alias
#   ALIAS       Domain alias to swap (default: activity.happitec.com)
#
# The script:
#   1. Fetches distribution configs for both distributions
#   2. Removes the alias from the old distribution
#   3. Waits briefly for CloudFront to accept the change
#   4. Adds the alias to the new distribution
#   5. If step 4 fails, automatically rolls back step 2 (re-adds alias to old)

set -euo pipefail

OLD_CF_ID="${1:?Usage: $0 <OLD_CF_ID> <NEW_CF_ID> [ALIAS]}"
NEW_CF_ID="${2:?Usage: $0 <OLD_CF_ID> <NEW_CF_ID> [ALIAS]}"
ALIAS="${3:-activity.happitec.com}"

echo "=== CloudFront Alias Swap ==="
echo "Old distribution: $OLD_CF_ID"
echo "New distribution: $NEW_CF_ID"
echo "Alias:            $ALIAS"
echo ""

# ---------------------------------------------------------------------------
# Step 0: Pre-flight — fetch both distribution configs
# ---------------------------------------------------------------------------
echo "Fetching old distribution config..."
OLD_CONFIG_JSON=$(aws cloudfront get-distribution-config --id "$OLD_CF_ID")
OLD_ETAG=$(echo "$OLD_CONFIG_JSON" | jq -r '.ETag')
OLD_CONFIG=$(echo "$OLD_CONFIG_JSON" | jq '.DistributionConfig')

echo "Fetching new distribution config..."
NEW_CONFIG_JSON=$(aws cloudfront get-distribution-config --id "$NEW_CF_ID")
NEW_ETAG=$(echo "$NEW_CONFIG_JSON" | jq -r '.ETag')
NEW_CONFIG=$(echo "$NEW_CONFIG_JSON" | jq '.DistributionConfig')

# Verify the alias exists on the old distribution
OLD_HAS_ALIAS=$(echo "$OLD_CONFIG" | jq --arg alias "$ALIAS" \
  '.Aliases.Items // [] | map(select(. == $alias)) | length')
if [[ "$OLD_HAS_ALIAS" -eq 0 ]]; then
  echo "ERROR: Alias '$ALIAS' not found on old distribution $OLD_CF_ID"
  echo "Current aliases: $(echo "$OLD_CONFIG" | jq -r '.Aliases.Items // [] | join(", ")')"
  exit 1
fi

# Verify the alias does NOT already exist on the new distribution
NEW_HAS_ALIAS=$(echo "$NEW_CONFIG" | jq --arg alias "$ALIAS" \
  '.Aliases.Items // [] | map(select(. == $alias)) | length')
if [[ "$NEW_HAS_ALIAS" -gt 0 ]]; then
  echo "ERROR: Alias '$ALIAS' already exists on new distribution $NEW_CF_ID"
  exit 1
fi

echo "Pre-flight checks passed."
echo ""

# ---------------------------------------------------------------------------
# Step 1: Remove alias from old distribution
# ---------------------------------------------------------------------------
echo "Step 1: Removing alias '$ALIAS' from old distribution $OLD_CF_ID..."

OLD_CONFIG_UPDATED=$(echo "$OLD_CONFIG" | jq --arg alias "$ALIAS" '
  .Aliases.Items = ([.Aliases.Items[] | select(. != $alias)]) |
  .Aliases.Quantity = (.Aliases.Items | length)
')

# Save to temp file for the AWS CLI
OLD_CONFIG_FILE=$(mktemp)
echo "$OLD_CONFIG_UPDATED" > "$OLD_CONFIG_FILE"

aws cloudfront update-distribution \
  --id "$OLD_CF_ID" \
  --if-match "$OLD_ETAG" \
  --distribution-config "file://$OLD_CONFIG_FILE" > /dev/null

rm -f "$OLD_CONFIG_FILE"
echo "Alias removed from old distribution."

# Save the old config + etag for potential rollback
ROLLBACK_CONFIG="$OLD_CONFIG"
# Re-fetch the etag after the update (needed for rollback)
ROLLBACK_ETAG=$(aws cloudfront get-distribution-config --id "$OLD_CF_ID" | jq -r '.ETag')

# ---------------------------------------------------------------------------
# Step 2: Brief wait for CloudFront to process the change
# ---------------------------------------------------------------------------
echo "Waiting 10 seconds for CloudFront to process..."
sleep 10

# ---------------------------------------------------------------------------
# Step 3: Add alias to new distribution
# ---------------------------------------------------------------------------
echo "Step 2: Adding alias '$ALIAS' to new distribution $NEW_CF_ID..."

# Re-fetch the new distribution config (etag may have changed)
NEW_CONFIG_JSON=$(aws cloudfront get-distribution-config --id "$NEW_CF_ID")
NEW_ETAG=$(echo "$NEW_CONFIG_JSON" | jq -r '.ETag')
NEW_CONFIG=$(echo "$NEW_CONFIG_JSON" | jq '.DistributionConfig')

NEW_CONFIG_UPDATED=$(echo "$NEW_CONFIG" | jq --arg alias "$ALIAS" '
  .Aliases.Items = (.Aliases.Items + [$alias]) |
  .Aliases.Quantity = (.Aliases.Items | length)
')

NEW_CONFIG_FILE=$(mktemp)
echo "$NEW_CONFIG_UPDATED" > "$NEW_CONFIG_FILE"

if aws cloudfront update-distribution \
  --id "$NEW_CF_ID" \
  --if-match "$NEW_ETAG" \
  --distribution-config "file://$NEW_CONFIG_FILE" > /dev/null; then

  rm -f "$NEW_CONFIG_FILE"
  echo ""
  echo "=== SUCCESS ==="
  echo "Alias '$ALIAS' moved from $OLD_CF_ID to $NEW_CF_ID"
  echo ""
  echo "Next steps:"
  echo "  1. Monitor the domain: curl -sI https://$ALIAS"
  echo "  2. Verify CloudFront propagation (may take a few minutes)"
  echo "  3. Update ACTIVITY_DISTRIBUTION_ID GitHub variable to $NEW_CF_ID"

else
  rm -f "$NEW_CONFIG_FILE"
  echo ""
  echo "!!! FAILED to add alias to new distribution !!!"
  echo "Rolling back: re-adding alias to old distribution $OLD_CF_ID..."

  # Rollback: re-add alias to old distribution using the original config
  ROLLBACK_FILE=$(mktemp)
  echo "$ROLLBACK_CONFIG" > "$ROLLBACK_FILE"

  if aws cloudfront update-distribution \
    --id "$OLD_CF_ID" \
    --if-match "$ROLLBACK_ETAG" \
    --distribution-config "file://$ROLLBACK_FILE" > /dev/null; then
    rm -f "$ROLLBACK_FILE"
    echo "Rollback successful. Alias '$ALIAS' restored on $OLD_CF_ID."
  else
    rm -f "$ROLLBACK_FILE"
    echo "!!! ROLLBACK ALSO FAILED !!!"
    echo "MANUAL INTERVENTION REQUIRED"
    echo "Re-add alias '$ALIAS' to distribution $OLD_CF_ID manually."
  fi
  exit 1
fi
