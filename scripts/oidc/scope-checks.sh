#!/usr/bin/env bash
# scope-checks.sh
#
# Checks that the role a trust-check job assumed is denied what it must not
# do. Anything a probe creates by mistake is recorded for cleanup.sh.
#
# Usage:
#   scripts/oidc/scope-checks.sh stage|production|infrastructure|integration|inventory

source "$(dirname "$0")/lib.sh"

case "${1:?job name}" in
  stage)
    expect_denied "describe-stacks activity-app-prod" \
      aws cloudformation describe-stacks --stack-name activity-app-prod
    expect_denied "ssm get-parameter /activity/prod/keys/client-token" \
      aws ssm get-parameter --name /activity/prod/keys/client-token
    expect_denied "iam list-roles" \
      aws iam list-roles --max-items 1
    ;;
  production)
    expect_denied "describe-stacks activity-app-stage" \
      aws cloudformation describe-stacks --stack-name activity-app-stage
    expect_denied "iam list-roles" \
      aws iam list-roles --max-items 1
    ;;
  infrastructure)
    expect_denied "describe-stacks activity-app-prod" \
      aws cloudformation describe-stacks --stack-name activity-app-prod
    expect_denied "create-policy activity-app-oidc-check-policy" \
      aws iam create-policy --policy-name activity-app-oidc-check-policy \
        --policy-document "$DENY_ALL"
    if [ "$LAST_ALLOWED" = 1 ]; then
      record policy "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/activity-app-oidc-check-policy"
    fi
    ;;
  integration)
    expect_denied "describe-stacks activity-environment-prod" \
      aws cloudformation describe-stacks --stack-name activity-environment-prod
    ;;
  inventory)
    expect_denied "create-role activity-app-stage-oidc-check-inventory" \
      aws iam create-role --role-name activity-app-stage-oidc-check-inventory \
        --assume-role-policy-document "file://$LAMBDA_TRUST"
    if [ "$LAST_ALLOWED" = 1 ]; then
      record role activity-app-stage-oidc-check-inventory
    fi
    expect_denied "describe-stacks activity-environment-prod" \
      aws cloudformation describe-stacks --stack-name activity-environment-prod
    ;;
  *)
    echo "unknown job: $1" >&2
    exit 2
    ;;
esac
finish
