#!/usr/bin/env bash
# build-all-lambdas.sh
#
# Full Lambda build. Runs inside the swift-al2023:6.3 image.
#
# Usage:
#   scripts/in-build-image.sh scripts/build-all-lambdas.sh
#
# What it does, in order:
#   1. Prints the resources the container sees (CPUs, memory, cgroup limits).
#   2. Resolves the package once, against the committed Package.resolved.
#   3. Runs ONE `swift build -c release --static-swift-stdlib -Xlinker -s`
#      with no --product, so every product compiles and links in a single
#      parallel build graph.
#   4. Reads the deployed handler set from the CodeUri entries in
#      activity-app/functions/template.yaml (not a hand-maintained list).
#   5. Stages each handler as `bootstrap` plus lib/libcrypto.so.3 and
#      lib/libssl.so.3 from this image, and zips it once to
#      .build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager/{T}/{T}.zip,
#      the path the template's CodeUri expects.
#   6. Fails if any expected zip is missing.
#
# The binaries are glibc (Amazon Linux 2023) builds with the Swift stdlib
# linked statically. OpenSSL is NOT linked statically: the Lambda finds the
# bundled copies through LD_LIBRARY_PATH=/var/task/lib (template Globals).

set -euo pipefail

TEMPLATE="activity-app/functions/template.yaml"
OUTPUT_BASE=".build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager"
STAGING_DIR=".build/lambda-staging"
SSL_LIBS=(/lib64/libcrypto.so.3 /lib64/libssl.so.3)

# Keep dependency clones and the manifest cache inside .build so they are
# saved and restored with the Swift build cache, instead of in a per-container
# shared cache that is thrown away when the container exits.
SWIFTPM_FLAGS=(--disable-dependency-cache --manifest-cache local --force-resolved-versions)

SCRIPT_START=$SECONDS
PHASE_NAMES=()
PHASE_SECS=()
phase_start() { PHASE_NAME="$1"; PHASE_T0=$SECONDS; echo ""; echo "=== Phase: $1"; }
phase_end() {
  local secs=$((SECONDS - PHASE_T0))
  PHASE_NAMES+=("$PHASE_NAME")
  PHASE_SECS+=("$secs")
  echo "=== Phase done: $PHASE_NAME (${secs}s)"
}
fmt() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }
print_timings() {
  echo ""
  echo "========================================="
  echo "Phase timings"
  local i
  for i in "${!PHASE_NAMES[@]}"; do
    printf '  %-22s %6ss  (%s)\n' "${PHASE_NAMES[$i]}" "${PHASE_SECS[$i]}" "$(fmt "${PHASE_SECS[$i]}")"
  done
  local total=$((SECONDS - SCRIPT_START))
  printf '  %-22s %6ss  (%s)\n' "total" "$total" "$(fmt "$total")"
  echo "========================================="
}
trap print_timings EXIT

# ---------------------------------------------------------------------------
# 1. Environment
# ---------------------------------------------------------------------------
phase_start "environment"
echo "uid:gid           $(id -u):$(id -g)"
echo "arch              $(uname -m)"
echo "nproc             $(nproc)"
if [[ -r /sys/fs/cgroup/cpu.max ]]; then
  echo "cgroup cpu.max    $(cat /sys/fs/cgroup/cpu.max)"
fi
awk '/^(MemTotal|MemAvailable|SwapTotal):/ { printf "%-17s %.1f GiB\n", $1, $2 / 1048576 }' /proc/meminfo
if [[ -r /sys/fs/cgroup/memory.max ]]; then
  echo "cgroup memory.max $(cat /sys/fs/cgroup/memory.max)"
fi
swift --version
phase_end

# Handler set: every CodeUri of the form .../AWSLambdaPackager/{T}/{T}.zip.
mapfile -t HANDLERS < <(
  sed -nE 's#^[[:space:]]*CodeUri:[[:space:]]*[^[:space:]]*/AWSLambdaPackager/([A-Za-z0-9_]+)/([A-Za-z0-9_]+)\.zip[[:space:]]*$#\1 \2#p' "$TEMPLATE" \
    | awk '$1 == $2 { print $1 }' \
    | sort -u
)
if [[ ${#HANDLERS[@]} -eq 0 ]]; then
  echo "ERROR: no CodeUri entries found in $TEMPLATE"
  exit 1
fi
echo ""
echo "Handlers from $TEMPLATE (${#HANDLERS[@]}):"
printf '  %s\n' "${HANDLERS[@]}"

# ---------------------------------------------------------------------------
# 2. Resolve once, against the committed Package.resolved
# ---------------------------------------------------------------------------
phase_start "resolve"
swift package "${SWIFTPM_FLAGS[@]}" resolve
phase_end

# ---------------------------------------------------------------------------
# 3. One build for every product
# ---------------------------------------------------------------------------
phase_start "build"
BUILD_ARGS=(-c release --static-swift-stdlib -Xlinker -s "${SWIFTPM_FLAGS[@]}")
swift build "${BUILD_ARGS[@]}"
BIN_PATH=$(swift build "${BUILD_ARGS[@]}" --show-bin-path)
echo "Binaries in $BIN_PATH"
phase_end

# ---------------------------------------------------------------------------
# 4. Stage and zip each handler once (in parallel)
# ---------------------------------------------------------------------------
phase_start "stage+zip"
# Start from an empty output tree so a zip left in a restored cache can never
# ship.
rm -rf "$STAGING_DIR" "$OUTPUT_BASE"

zip_one() {
  local h="$1"
  local stage="$STAGING_DIR/$h"
  local out_dir="$OUTPUT_BASE/$h"
  local out_zip="$PWD/$out_dir/$h.zip"
  mkdir -p "$stage/lib" "$out_dir"
  cp "$BIN_PATH/$h" "$stage/bootstrap"
  chmod 755 "$stage/bootstrap"
  # -L: the /lib64 entries can be symlinks to versioned files; copy the target.
  cp -L "${SSL_LIBS[@]}" "$stage/lib/"
  (cd "$stage" && zip -q -X -r "$out_zip" bootstrap lib)
}

pids=()
names=()
for h in "${HANDLERS[@]}"; do
  zip_one "$h" &
  pids+=($!)
  names+=("$h")
done
zip_failed=0
for i in "${!pids[@]}"; do
  if ! wait "${pids[$i]}"; then
    echo "ERROR: packaging failed for ${names[$i]}"
    zip_failed=1
  fi
done
if [[ $zip_failed -ne 0 ]]; then
  exit 1
fi
phase_end

# ---------------------------------------------------------------------------
# 5. Every expected zip must exist
# ---------------------------------------------------------------------------
phase_start "check outputs"
missing=0
for h in "${HANDLERS[@]}"; do
  z="$OUTPUT_BASE/$h/$h.zip"
  if [[ -s "$z" ]]; then
    printf '  %-28s %8s bytes\n' "$h" "$(stat -c %s "$z")"
  else
    echo "  MISSING: $z"
    missing=1
  fi
done
if [[ $missing -ne 0 ]]; then
  echo "ERROR: one or more expected zips are missing"
  exit 1
fi
echo "All ${#HANDLERS[@]} zips present."
phase_end
