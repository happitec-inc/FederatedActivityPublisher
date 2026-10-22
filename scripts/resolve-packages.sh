#!/usr/bin/env bash
# resolve-packages.sh
#
# Regenerates Package.resolved from scratch with the deploy toolchain. Runs
# inside the swift-al2023:6.3 image, so the pins are what Swift 6.3 resolves:
# version-specific manifests (Package@swift-6.4.swift and so on) are read the
# way the deploy reads them. Generating the file with another toolchain can
# pin a different package set.
#
# Usage:
#   scripts/in-build-image.sh scripts/resolve-packages.sh

set -euo pipefail

swift --version
rm -f Package.resolved
swift package resolve
echo "Pins: $(grep -c '"identity"' Package.resolved)"
grep '"identity"' Package.resolved | sed -E 's/.*"identity" : "([^"]+)".*/  \1/'
