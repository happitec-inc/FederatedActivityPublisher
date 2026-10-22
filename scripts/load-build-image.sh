#!/usr/bin/env bash
# load-build-image.sh
#
# Makes the swift-al2023:6.3 build image available on the runner: installs
# Docker if it is missing, then loads the image from /tmp/docker-image.tar
# (restored by actions/cache) or builds it from docker/Dockerfile.al2023-swift
# and saves it there for the cache.
#
# Usage:
#   bash scripts/load-build-image.sh

set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sudo sh
fi
sudo chmod 666 /var/run/docker.sock
docker --version

if [[ -f /tmp/docker-image.tar ]]; then
  echo "Loading cached Docker image"
  docker load < /tmp/docker-image.tar
else
  echo "Building Docker image"
  docker build -t swift-al2023:6.3 -f docker/Dockerfile.al2023-swift .
  docker save swift-al2023:6.3 > /tmp/docker-image.tar
fi
