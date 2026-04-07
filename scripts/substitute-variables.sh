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

# Parse named arguments if provided
while [[ $# -gt 0 ]]; do
  case $1 in
    --server-domain) SERVER_DOMAIN="$2"; shift 2 ;;
    --handle-domain) HANDLE_DOMAIN="$2"; shift 2 ;;
    *) shift ;;
  esac
done

SERVER_DOMAIN="${SERVER_DOMAIN:-}"
HANDLE_DOMAIN="${HANDLE_DOMAIN:-}"

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
  "Sources/ActivityPubCore/Documentation.docc/ProvisioningAccounts.md"
  "AGENTS.md"
)

for file in "${FILES[@]}"; do
  if [ -f "$file" ]; then
    sed -i.bak \
      -e "s|{{SERVER_DOMAIN}}|$SERVER_DOMAIN|g" \
      -e "s|{{HANDLE_DOMAIN}}|$HANDLE_DOMAIN|g" \
      -e "s|api.example.com|$SERVER_DOMAIN|g" \
      -e "s|myactor@example.com|myactor@$HANDLE_DOMAIN|g" \
      "$file"
    rm -f "$file.bak"
    echo "Substituted: $file"
  fi
done
