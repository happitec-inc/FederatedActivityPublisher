#!/usr/bin/env bash
# deploy-role-stack.sh
#
# Deploys activity-oidc/template.yaml as <repository name>-oidc, with the
# trust parameters taken from the run context, so a fork gets roles that
# trust the fork. The deploy output goes to $RUNNER_TEMP/deploy.log and is
# never printed; failure detail is in the stack events in the CloudFormation
# console.
#
# Usage:
#   scripts/oidc/deploy-role-stack.sh
#
# Environment:
#   REGION                     AWS region
#   GH_OWNER, GH_OWNER_ID      github.repository_owner, github.repository_owner_id
#   GH_REPO, GH_REPO_ID        github.event.repository.name, github.repository_id
#   STAGE_DISTRIBUTION_ID      vars.ACTIVITY_DISTRIBUTION_ID_STAGE (may be empty)
#   PROD_DISTRIBUTION_ID       vars.ACTIVITY_DISTRIBUTION_ID_PROD (may be empty)
#   ALLOW_DISTRIBUTION_CREATE  true or false

set -euo pipefail

: "${REGION:?}" "${GH_OWNER:?}" "${GH_OWNER_ID:?}" "${GH_REPO:?}" "${GH_REPO_ID:?}" "${ALLOW_DISTRIBUTION_CREATE:?}"

# Each value is wrapped in double quotes. SAM CLI 1.166.2 parses
# --parameter-overrides with the space-delimited pattern in samcli.cli.types,
#   (?:(?: )([A-Za-z0-9\"]+)=(\"(?:\\.|[^\"\\]+)*\"|(?:\\.|[^ \"\\]+)+))
# whose unquoted branch needs one or more characters, so `Key=` is dropped
# while `Key=""` parses as an empty value.
q() { printf '%s="%s"' "$1" "$2"; }

if sam deploy \
    --template-file activity-oidc/template.yaml \
    --stack-name "$GH_REPO-oidc" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-confirm-changeset \
    --no-fail-on-empty-changeset \
    --region "$REGION" \
    --parameter-overrides \
      "$(q GitHubOrg "$GH_OWNER")" \
      "$(q GitHubRepo "$GH_REPO")" \
      "$(q GitHubOrgId "$GH_OWNER_ID")" \
      "$(q GitHubRepoId "$GH_REPO_ID")" \
      "$(q StageDistributionId "${STAGE_DISTRIBUTION_ID:-}")" \
      "$(q ProdDistributionId "${PROD_DISTRIBUTION_ID:-}")" \
      "$(q AllowDistributionCreate "$ALLOW_DISTRIBUTION_CREATE")" \
    > "$RUNNER_TEMP/deploy.log" 2>&1; then
  echo "role stack: ok"
else
  echo "role stack: failed (see the stack events in the CloudFormation console)"
  exit 1
fi
