#!/usr/bin/env bash
# Exercise the pinned package managers and their real install paths.
# Usage: bash test-toolchain-e2e.sh <image>
set -euo pipefail

IMAGE="${1:?usage: test-toolchain-e2e.sh <image>}"
NAME="opencode-toolchain-e2e-$$"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "Testing package managers and lazy installs (${IMAGE}; 5-minute timeout)..."
docker run --rm -i --name "$NAME" -e GITHUB_TOKEN --entrypoint timeout "$IMAGE" 300 bash -s <<'TEST'
set -euo pipefail

brew --version
mise --version
zb --version
git -C /opt/mise/plugins/zerobrew rev-parse HEAD

# These commands must start lazy and then install via the zerobrew plugin,
# including its per-tool root initialization and runtime library paths.
for command in ruby wget nano; do
  [ "$(command -v "$command")" = "/opt/auto-install-shims/$command" ]
done
ruby --version
wget --version
nano --version

# Also exercise Homebrew itself and the standalone zbx wrapper, rather than
# only checking that the pinned package-manager executables start.
brew install hello
hello --version
zbx hello --version
TEST

echo "PASS: Homebrew, mise, zerobrew plugin lazy installs, and zbx ($IMAGE)"
