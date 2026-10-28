#!/usr/bin/env bash
# boundary-policy-control.sh
#
# Infrastructure job of the trust check: the infra role can write both
# boundary policies. For each, reads the default version's document, creates
# a non-default version with the same document, then deletes it. The
# effective boundary never changes. Created versions are recorded so
# cleanup.sh deletes them again if this script stops early.
#
# Usage:
#   scripts/oidc/boundary-policy-control.sh
#
# With EXPECT_BOUNDARY=none, a NoSuchEntity from get-policy (the boundary
# does not exist yet) is reported, not failed.

source "$(dirname "$0")/lib.sh"

for s in stage prod; do
  b="$(boundary_arn "$s")"
  if ! v="$(aws iam get-policy --policy-arn "$b" \
      --query Policy.DefaultVersionId --output text 2> "$RUNNER_TEMP/err")"; then
    code="$(err_code)"
    if [ "$code" = NoSuchEntity ] && [ "$EXPECT_BOUNDARY" = none ]; then
      note "get-policy on the $s boundary: NoSuchEntity, the policy does not exist yet (reported, not failed)"
    else
      fail "get-policy on the $s boundary: expected success, got ${code:-an error without a code}"
    fi
    continue
  fi
  ok "get-policy on the $s boundary: default version $v"
  if ! aws iam get-policy-version --policy-arn "$b" --version-id "$v" \
      --query PolicyVersion.Document --output json \
      > "$RUNNER_TEMP/boundary-$s.json" 2> "$RUNNER_TEMP/err"; then
    fail "get-policy-version $v on the $s boundary: expected success, got $(err_code)"
    continue
  fi
  if ! new="$(aws iam create-policy-version --policy-arn "$b" \
      --policy-document "file://$RUNNER_TEMP/boundary-$s.json" \
      --query PolicyVersion.VersionId --output text 2> "$RUNNER_TEMP/err")"; then
    code="$(err_code)"
    if [ "$code" = LimitExceeded ]; then
      fail "create-policy-version on the $s boundary: LimitExceeded, the policy is already at the version limit"
    else
      fail "create-policy-version on the $s boundary: expected success, got ${code:-an error without a code}"
    fi
    continue
  fi
  record version "$b $new"
  ok "create-policy-version on the $s boundary: created non-default version $new"
  expect_allowed "delete-policy-version $new on the $s boundary" \
    aws iam delete-policy-version --policy-arn "$b" --version-id "$new"
done
finish
