#!/usr/bin/env bash
# lib.sh
#
# Shared helpers for the OIDC trust check (oidc-trust-check.yml). Every AWS
# call sends stdout to /dev/null or into a variable that is never printed
# whole; only the error code of a failed call is kept, in $RUNNER_TEMP/err.
#
# Usage:
#   source "$(dirname "$0")/lib.sh"
#
# Environment:
#   RUNNER_TEMP      scratch directory (set by the runner)
#   AWS_ACCOUNT_ID   account that holds the roles (a secret; masked in logs)
#   ROLE_PREFIX      role name prefix, <repository name>-github-actions
#   EXPECT_BOUNDARY  none, stage or all

# shellcheck disable=SC2034  # LAST_ALLOWED, DENY_ALL, LAMBDA_TRUST are read by the sourcing scripts
set -euo pipefail

: "${RUNNER_TEMP:?}" "${AWS_ACCOUNT_ID:?}" "${ROLE_PREFIX:?}"
EXPECT_BOUNDARY="${EXPECT_BOUNDARY:-none}"

FAILS=0
LAST_ALLOWED=0
fail() { echo "::error::$*"; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $*"; }
note() { echo "::notice::$*"; }
err_code() { sed -n 's/.*An error occurred (\([^)]*\)).*/\1/p' "$RUNNER_TEMP/err" | head -n 1; }
run() { "$@" < /dev/null > /dev/null 2> "$RUNNER_TEMP/err"; }
finish() {
  if [ "$FAILS" -gt 0 ]; then echo "$FAILS check(s) failed"; exit 1; fi
  echo "all checks passed"
}

# expect_denied LABEL CMD...: passes only on AccessDenied/AccessDeniedException.
# Sets LAST_ALLOWED=1 if the call succeeded, so the caller can record what
# it created for the cleanup step.
expect_denied() {
  local label="$1" code
  shift
  LAST_ALLOWED=0
  if run "$@"; then
    LAST_ALLOWED=1
    fail "$label: allowed, expected AccessDenied"
    return 0
  fi
  code="$(err_code)"
  case "$code" in
    AccessDenied|AccessDeniedException) ok "$label: denied" ;;
    *) fail "$label: expected AccessDenied, got ${code:-an error without a code}" ;;
  esac
}

expect_allowed() {
  local label="$1"
  shift
  if run "$@"; then ok "$label: allowed"; else fail "$label: expected success, got $(err_code)"; fi
}

# record KIND VALUE: note something a probe created, for cleanup.sh.
record() { echo "$2" >> "$RUNNER_TEMP/created-$1"; }

role_arn() { echo "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_PREFIX}-$1"; }
boundary_arn() { echo "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/activity-app-$1-function-boundary"; }
lines() { tr '\t' '\n' | sed '/^$/d; /^None$/d'; }

DENY_ALL='{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"*","Resource":"*"}]}'
LAMBDA_TRUST="$RUNNER_TEMP/lambda-trust.json"
printf '%s' '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' > "$LAMBDA_TRUST"
