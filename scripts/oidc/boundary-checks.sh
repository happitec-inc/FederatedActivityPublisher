#!/usr/bin/env bash
# boundary-checks.sh
#
# Stage job of the trust check: the stage deploy role may create a role
# under activity-app-stage- only with the stage boundary, and may not remove
# a boundary. The positive control creates and deletes one bounded role.
#
# Usage:
#   scripts/oidc/boundary-checks.sh
#
# With EXPECT_BOUNDARY=none, a NoSuchEntity on the positive control (the
# stage boundary policy does not exist yet) is reported, not failed.

source "$(dirname "$0")/lib.sh"

CHECK=activity-app-stage-oidc-check

expect_denied "create-role without a boundary" \
  aws iam create-role --role-name "$CHECK-unbounded" \
    --assume-role-policy-document "file://$LAMBDA_TRUST"
if [ "$LAST_ALLOWED" = 1 ]; then record role "$CHECK-unbounded"; fi

expect_denied "create-role with the prod boundary" \
  aws iam create-role --role-name "$CHECK-prod-boundary" \
    --assume-role-policy-document "file://$LAMBDA_TRUST" \
    --permissions-boundary "$(boundary_arn prod)"
if [ "$LAST_ALLOWED" = 1 ]; then record role "$CHECK-prod-boundary"; fi

# The stage boundary is passed, so the prefix is the only reason to deny.
expect_denied "create-role outside the prefix" \
  aws iam create-role --role-name "$ROLE_PREFIX-oidc-check" \
    --assume-role-policy-document "file://$LAMBDA_TRUST" \
    --permissions-boundary "$(boundary_arn stage)"
if [ "$LAST_ALLOWED" = 1 ]; then record role "$ROLE_PREFIX-oidc-check"; fi

# Positive control: the stage boundary is the one grant that works.
if run aws iam create-role --role-name "$CHECK-bounded" \
    --assume-role-policy-document "file://$LAMBDA_TRUST" \
    --permissions-boundary "$(boundary_arn stage)"; then
  record role "$CHECK-bounded"
  ok "create-role with the stage boundary: allowed"
  expect_denied "delete-role-permissions-boundary" \
    aws iam delete-role-permissions-boundary --role-name "$CHECK-bounded"
  expect_allowed "delete-role" \
    aws iam delete-role --role-name "$CHECK-bounded"
else
  code="$(err_code)"
  if [ "$code" = NoSuchEntity ] && [ "$EXPECT_BOUNDARY" = none ]; then
    note "create-role with the stage boundary: NoSuchEntity, the stage boundary policy does not exist yet (reported, not failed)"
  else
    fail "create-role with the stage boundary: expected success, got ${code:-an error without a code}"
  fi
fi
finish
