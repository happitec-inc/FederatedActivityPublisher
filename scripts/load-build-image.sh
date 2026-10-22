#!/usr/bin/env bash
# load-build-image.sh
#
# Makes the swift-al2023:6.3 build image available on the runner: loads it
# from /tmp/docker-image.tar (restored by actions/cache) or builds it from
# docker/Dockerfile.al2023-swift and saves it there for the cache. Docker must
# already be installed and usable by the runner user (GitHub-hosted runners
# have it).
#
# Usage:
#   bash scripts/load-build-image.sh

set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found. The Lambda build runs in Docker; install it on this runner." >&2
  exit 1
fi
docker --version

if [[ -f /tmp/docker-image.tar ]]; then
  echo "Loading cached Docker image"
  docker load < /tmp/docker-image.tar
else
  echo "Building Docker image"
  docker build -t swift-al2023:6.3 -f docker/Dockerfile.al2023-swift .
  docker save swift-al2023:6.3 > /tmp/docker-image.tar
fi
