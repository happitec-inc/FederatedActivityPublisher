#!/usr/bin/env bash
# inventory.sh
#
# Inventory job of the trust check, for each of stage and prod: lists every
# role named activity-app-<S>-*, fails on any trust other than the Lambda
# service, reports whether each carries its stage's boundary, checks that
# every FunctionsStack role is in that list, prints the AWS managed policies
# the FunctionsStack uses, and compares the stack's distribution ID with the
# repository variable.
#
# Usage:
#   scripts/oidc/inventory.sh
#
# Environment (besides lib.sh's):
#   STAGE_DISTRIBUTION_ID, PROD_DISTRIBUTION_ID  vars.ACTIVITY_DISTRIBUTION_ID_*
#
# With EXPECT_BOUNDARY=stage, a stage role without the stage boundary fails
# the run; with all, a role of either stage without its boundary does.

source "$(dirname "$0")/lib.sh"

# Count of trust statements whose principal is not exactly the Lambda
# service, as a string or a one-element array, and the boundary ARN (None
# when the role has none).
# shellcheck disable=SC2016  # backticks are JMESPath literals, not command substitution
LAMBDA_STR='`{"Service": "lambda.amazonaws.com"}`'
# shellcheck disable=SC2016
LAMBDA_ARR='`{"Service": ["lambda.amazonaws.com"]}`'
ROLE_QUERY="[length(to_array(Role.AssumeRolePolicyDocument.Statement)[?Principal != $LAMBDA_STR && Principal != $LAMBDA_ARR]), Role.PermissionsBoundary.PermissionsBoundaryArn]"

for s in stage prod; do
  echo "== activity-app-$s =="
  case "$s" in
    stage) want_var=ACTIVITY_DISTRIBUTION_ID_STAGE; want_dist="${STAGE_DISTRIBUTION_ID:-}" ;;
    prod) want_var=ACTIVITY_DISTRIBUTION_ID_PROD; want_dist="${PROD_DISTRIBUTION_ID:-}" ;;
  esac
  enforce=no
  if [ "$EXPECT_BOUNDARY" = all ] || { [ "$EXPECT_BOUNDARY" = stage ] && [ "$s" = stage ]; }; then
    enforce=yes
  fi

  # Role list. The filter runs inside the CLI, so only matching names leave
  # it; the unfiltered response is never printed or saved.
  if ! listed="$(aws iam list-roles \
      --query "Roles[?starts_with(RoleName, 'activity-app-$s-')].RoleName" \
      --output text 2> "$RUNNER_TEMP/err")"; then
    fail "list-roles: $(err_code)"
    continue
  fi
  listed="$(printf '%s\n' "$listed" | lines)"
  echo "roles named activity-app-$s-*: $(printf '%s\n' "$listed" | sed '/^$/d' | wc -l | tr -d ' ')"

  for r in $listed; do
    if ! res="$(aws iam get-role --role-name "$r" --query "$ROLE_QUERY" \
        --output text 2> "$RUNNER_TEMP/err")"; then
      fail "$r: get-role $(err_code)"
      continue
    fi
    others="$(printf '%s' "$res" | cut -f1)"
    barn="$(printf '%s' "$res" | cut -f2)"
    trust=lambda
    if [ "$others" != 0 ]; then
      trust=OTHER
      fail "$r: trusts a principal other than lambda.amazonaws.com"
    fi
    case "$barn" in
      *":policy/activity-app-$s-function-boundary") boundary=yes ;;
      *) boundary=no ;;
    esac
    echo "$r trust=$trust boundary=$boundary"
    if [ "$boundary" = no ] && [ "$enforce" = yes ]; then
      fail "$r: does not carry activity-app-$s-function-boundary"
    fi
  done

  # Every role in the FunctionsStack must be in the role list.
  if ! nested="$(aws cloudformation describe-stack-resource --stack-name "activity-app-$s" \
      --logical-resource-id FunctionsStack \
      --query StackResourceDetail.PhysicalResourceId --output text 2> "$RUNNER_TEMP/err")"; then
    fail "describe-stack-resource FunctionsStack of activity-app-$s: $(err_code)"
  else
    if ! stack_roles="$(aws cloudformation list-stack-resources --stack-name "$nested" \
        --query "StackResourceSummaries[?ResourceType=='AWS::IAM::Role'].PhysicalResourceId" \
        --output text 2> "$RUNNER_TEMP/err")"; then
      fail "list-stack-resources of the activity-app-$s FunctionsStack: $(err_code)"
    else
      for sr in $(printf '%s\n' "$stack_roles" | lines); do
        if printf '%s\n' "$listed" | grep -qxF -- "$sr"; then
          ok "$sr is in the role list"
        else
          fail "$sr is in the activity-app-$s FunctionsStack but not in the role list"
        fi
      done
    fi

    # Distinct AWS managed policy ARNs in the processed template.
    if ! body="$(aws cloudformation get-template --stack-name "$nested" \
        --template-stage Processed --query TemplateBody --output json 2> "$RUNNER_TEMP/err")"; then
      fail "get-template of the activity-app-$s FunctionsStack: $(err_code)"
    else
      echo "managed policies:"
      printf '%s' "$body" \
        | { grep -oE 'arn:(aws|\$\{AWS::Partition\}):iam::aws:policy/[A-Za-z0-9/_+=,.@-]+' || true; } \
        | sort -u | sed 's/^/  /'
    fi
  fi

  # Distribution IDs are not secrets.
  if ! dist="$(aws cloudformation describe-stacks --stack-name "activity-app-$s" \
      --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDistributionId'].OutputValue" \
      --output text 2> "$RUNNER_TEMP/err")"; then
    fail "describe-stacks activity-app-$s: $(err_code)"
  elif [ -n "$dist" ] && [ "$dist" = "$want_dist" ]; then
    ok "CloudFrontDistributionId of activity-app-$s matches $want_var"
  else
    fail "CloudFrontDistributionId of activity-app-$s is '$dist', $want_var is '$want_dist'"
  fi
done
finish
