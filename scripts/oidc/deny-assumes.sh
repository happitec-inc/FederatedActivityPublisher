#!/usr/bin/env bash
# deny-assumes.sh
#
# Checks that each named OIDC role refuses this job's token. Requests a token
# for audience sts.amazonaws.com and calls sts assume-role-with-web-identity
# by hand, so AccessDenied can be told apart from any other failure; the
# configure-aws-credentials action reports every failure the same way.
#
# Usage:
#   scripts/oidc/deny-assumes.sh deploy-prod infra integration-read trust-check
#
# Each argument is a role name suffix after $ROLE_PREFIX-. Needs the job's
# id-token: write permission (ACTIONS_ID_TOKEN_REQUEST_URL and _TOKEN).

source "$(dirname "$0")/lib.sh"

: "${ACTIONS_ID_TOKEN_REQUEST_URL:?}" "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?}"

token="$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" \
  | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')"
if [ -z "$token" ]; then
  fail "could not obtain an OIDC token"
  finish
fi
echo "::add-mask::$token"
printf '%s' "$token" > "$RUNNER_TEMP/oidc-token"

for r in "$@"; do
  expect_denied "assume $r" aws sts assume-role-with-web-identity \
    --role-arn "$(role_arn "$r")" \
    --role-session-name oidc-trust-check \
    --web-identity-token "file://$RUNNER_TEMP/oidc-token"
done
rm -f "$RUNNER_TEMP/oidc-token"
finish
