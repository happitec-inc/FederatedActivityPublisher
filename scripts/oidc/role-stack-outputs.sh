#!/usr/bin/env bash
# role-stack-outputs.sh
#
# Appends the role stack's outputs (the five role names) to the step summary.
#
# Usage:
#   scripts/oidc/role-stack-outputs.sh
#
# Environment:
#   REGION   AWS region
#   GH_REPO  github.event.repository.name; the stack is <GH_REPO>-oidc

set -euo pipefail

: "${REGION:?}" "${GH_REPO:?}" "${GITHUB_STEP_SUMMARY:?}"

{
  echo "## Role stack outputs"
  echo '```json'
  aws cloudformation describe-stacks \
    --stack-name "$GH_REPO-oidc" \
    --query "Stacks[0].Outputs" \
    --region "$REGION"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
