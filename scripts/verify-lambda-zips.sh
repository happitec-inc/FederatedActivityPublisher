#!/usr/bin/env bash
# verify-lambda-zips.sh
#
# Checks the output of scripts/build-all-lambdas.sh. Runs inside the
# swift-al2023:6.3 image (it needs unzip and readelf).
#
# Usage:
#   scripts/in-build-image.sh scripts/verify-lambda-zips.sh
#
# Asserts:
#   - the set of produced zips equals the set of CodeUri zips in
#     activity-app/functions/template.yaml (same names, same count);
#   - there is no ActivityProvisioner zip;
#   - each zip has an executable `bootstrap` at its root that is an ELF binary
#     for this machine's architecture with no libswiftCore.so dependency
#     (the Swift stdlib is linked statically);
#   - each zip has lib/libcrypto.so.3 and lib/libssl.so.3.
#
# This parses the template separately from build-all-lambdas.sh on purpose, so
# a parsing mistake in one is caught by the other.

set -euo pipefail

TEMPLATE="activity-app/functions/template.yaml"
OUTPUT_BASE=".build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
err() { echo "FAIL: $*"; fail=1; }

case "$(uname -m)" in
  aarch64) EXPECT_MACHINE="AArch64" ;;
  x86_64)  EXPECT_MACHINE="X86-64" ;;
  *)       EXPECT_MACHINE="" ;;
esac

# Expected: basename of every CodeUri path, minus .zip.
grep -E '^[[:space:]]*CodeUri:' "$TEMPLATE" \
  | awk '{ print $2 }' \
  | xargs -n1 basename \
  | sed 's/\.zip$//' \
  | sort > "$WORK/expected"

# Produced: every {T}/{T}.zip under the output tree, plus anything else there.
( cd "$OUTPUT_BASE" 2>/dev/null && find . -name '*.zip' -type f ) \
  | sed 's#^\./##' | sort > "$WORK/all-zips"
awk -F/ 'NF == 2 && $2 == $1 ".zip" { print $1 }' "$WORK/all-zips" | sort > "$WORK/produced"

echo "Template CodeUri entries: $(wc -l < "$WORK/expected")"
echo "Produced zips:            $(wc -l < "$WORK/all-zips")"

if [[ ! -s "$WORK/expected" ]]; then
  err "no CodeUri entries in $TEMPLATE"
fi
if ! diff -u "$WORK/expected" "$WORK/produced"; then
  err "produced zip set differs from the template's CodeUri set (diff above: - template, + produced)"
fi
if [[ "$(wc -l < "$WORK/all-zips")" -ne "$(wc -l < "$WORK/expected")" ]]; then
  err "unexpected files in $OUTPUT_BASE:"
  cat "$WORK/all-zips"
fi
if grep -qx 'ActivityProvisioner' "$WORK/produced" || grep -q 'ActivityProvisioner' "$WORK/all-zips"; then
  err "an ActivityProvisioner zip was produced"
fi

while IFS= read -r h; do
  z="$OUTPUT_BASE/$h/$h.zip"
  machine=""
  needed=""
  [[ -f "$z" ]] || continue
  d="$WORK/x/$h"
  mkdir -p "$d"
  if ! unzip -q "$z" -d "$d"; then
    err "$h: unzip failed"
    continue
  fi

  b="$d/bootstrap"
  if [[ ! -f "$b" ]]; then
    err "$h: no bootstrap at the zip root"
  else
    [[ -x "$b" ]] || err "$h: bootstrap is not executable"
    if ! machine=$(readelf -h "$b" 2>/dev/null | awk -F: '/Machine:/ { gsub(/^[ \t]+/, "", $2); print $2 }'); then
      machine=""
    fi
    if [[ -z "$machine" ]]; then
      err "$h: bootstrap is not an ELF binary"
    elif [[ -n "$EXPECT_MACHINE" && "$machine" != *"$EXPECT_MACHINE"* ]]; then
      err "$h: bootstrap machine is '$machine', expected $EXPECT_MACHINE"
    fi
    needed=$(readelf -d "$b" 2>/dev/null | awk '/\(NEEDED\)/ { print $NF }' | tr -d '[]' | tr '\n' ' ')
    if [[ "$needed" == *libswiftCore.so* ]]; then
      err "$h: bootstrap depends on libswiftCore.so (stdlib not static): $needed"
    fi
  fi

  for lib in libcrypto.so.3 libssl.so.3; do
    [[ -s "$d/lib/$lib" ]] || err "$h: lib/$lib missing"
  done

  printf '  %-28s machine=%-8s needed=%s\n' "$h" "${machine:-?}" "${needed:-?}"
done < "$WORK/produced"

if [[ $fail -ne 0 ]]; then
  echo "Lambda zip verification FAILED"
  exit 1
fi
echo "Lambda zip verification passed: $(wc -l < "$WORK/produced") zips."
