#!/usr/bin/env bash
# cleanup.sh
#
# Last step of each trust-check job that can create something: removes what
# the probes recorded in $RUNNER_TEMP/created-{role,policy,version}. Anything
# already gone counts as removed. Anything the job's role cannot remove fails
# the step and is named, so a maintainer can remove it.
#
# Usage:
#   scripts/oidc/cleanup.sh [stage]
#
# With "stage", the stage job's check role names are also looked up, in case
# an earlier, cancelled run left one behind.

source "$(dirname "$0")/lib.sh"

roles=()
if [ -f "$RUNNER_TEMP/created-role" ]; then
  while read -r r; do roles+=("$r"); done < "$RUNNER_TEMP/created-role"
fi
if [ "${1:-}" = stage ]; then
  roles+=(activity-app-stage-oidc-check-unbounded
          activity-app-stage-oidc-check-prod-boundary
          activity-app-stage-oidc-check-bounded
          "$ROLE_PREFIX-oidc-check")
fi

for r in $(printf '%s\n' "${roles[@]+"${roles[@]}"}" | sort -u); do
  if run aws iam get-role --role-name "$r"; then
    if run aws iam delete-role --role-name "$r"; then
      echo "removed role $r"
    else
      fail "could not remove role $r: $(err_code); a maintainer removes it"
    fi
  else
    code="$(err_code)"
    case "$code" in
      NoSuchEntity) ;;
      *) note "role $r: get-role returned ${code:-an error without a code}; not removed" ;;
    esac
  fi
done

if [ -f "$RUNNER_TEMP/created-policy" ]; then
  while read -r p; do
    if run aws iam delete-policy --policy-arn "$p"; then
      echo "removed policy ${p##*/}"
    elif [ "$(err_code)" = NoSuchEntity ]; then
      echo "policy ${p##*/} was already removed"
    else
      fail "could not remove policy ${p##*/}: $(err_code); a maintainer removes it"
    fi
  done < "$RUNNER_TEMP/created-policy"
fi

if [ -f "$RUNNER_TEMP/created-version" ]; then
  while read -r p v; do
    if run aws iam delete-policy-version --policy-arn "$p" --version-id "$v"; then
      echo "removed $v from ${p##*/}"
    elif [ "$(err_code)" = NoSuchEntity ]; then
      echo "$v on ${p##*/} was already removed"
    else
      fail "could not remove $v from ${p##*/}: $(err_code); a maintainer removes it"
    fi
  done < "$RUNNER_TEMP/created-version"
fi
finish
