#!/usr/bin/env bash
# boundary-policy-denials.sh
#
# Stage and production jobs of the trust check: the deploy roles hold no
# managed-policy write action, so every write to either boundary is denied.
#
# Usage:
#   scripts/oidc/boundary-policy-denials.sh
#
# No probe can change the effective boundary if a denial ever regresses:
#   - create-policy-version does not set the new version as default; a
#     created version is recorded for cleanup.sh;
#   - set-default-policy-version and delete-policy-version name version v999,
#     which does not exist;
#   - delete-policy names a sibling ARN that does not exist.
# IAM authorizes the request before it looks the resource up, so each call
# is expected to return AccessDenied whether or not the target exists. If it
# does not, the probe returns NoSuchEntity and fails the check.

source "$(dirname "$0")/lib.sh"

for s in stage prod; do
  b="$(boundary_arn "$s")"
  if out="$(aws iam create-policy-version --policy-arn "$b" --policy-document "$DENY_ALL" \
      --query PolicyVersion.VersionId --output text 2> "$RUNNER_TEMP/err")"; then
    record version "$b $out"
    fail "create-policy-version on the $s boundary: allowed, created non-default version $out"
  else
    code="$(err_code)"
    case "$code" in
      AccessDenied) ok "create-policy-version on the $s boundary: denied" ;;
      *) fail "create-policy-version on the $s boundary: expected AccessDenied, got ${code:-an error without a code}" ;;
    esac
  fi
  expect_denied "set-default-policy-version on the $s boundary" \
    aws iam set-default-policy-version --policy-arn "$b" --version-id v999
  expect_denied "delete-policy-version on the $s boundary" \
    aws iam delete-policy-version --policy-arn "$b" --version-id v999
  expect_denied "delete-policy on a sibling of the $s boundary" \
    aws iam delete-policy --policy-arn "$b-oidc-check"
done
finish
