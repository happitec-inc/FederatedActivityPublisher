#!/usr/bin/env bash
# in-build-image.sh
#
# Runs a repo script inside the swift-al2023:6.3 build image (built from
# docker/Dockerfile.al2023-swift), from the repository root, as the calling
# uid so nothing in the workspace ends up root-owned.
#
# Usage:
#   scripts/in-build-image.sh scripts/build-all-lambdas.sh
#   scripts/in-build-image.sh scripts/verify-lambda-zips.sh
#
# The container has no passwd entry for the uid, so HOME is /tmp, which is
# writable; SwiftPM keeps its config and caches under HOME.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <script> [args...]" >&2
  exit 1
fi

exec docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD:/workspace" \
  -w /workspace \
  swift-al2023:6.3 \
  bash "$@"
