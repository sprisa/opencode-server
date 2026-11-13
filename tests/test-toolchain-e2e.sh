#!/usr/bin/env bash
# Exercise the pinned package managers and their real install paths.
# Usage: bash tests/test-toolchain-e2e.sh <image>
set -euo pipefail

IMAGE="${1:?usage: tests/test-toolchain-e2e.sh <image>}"
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
for command in wget nano; do
  [ "$(command -v "$command")" = "/opt/auto-install-shims/$command" ]
done
wget --version
nano --version

# Ruby comes from mise core as a precompiled build (ruby.compile = false).
# Regression: the old zerobrew Ruby passed `ruby --version` but looked for its
# standard library under the Homebrew Cellar, so every require and gem failed.
# Check the stdlib dirs exist, load stdlib and native libraries, and install
# and load a gem.
[ "$(command -v ruby)" = "/opt/auto-install-shims/ruby" ]
ruby -e '
  require "rbconfig"
  dirs = RbConfig::CONFIG.values_at("rubylibdir", "archdir")
  missing = dirs.reject { |dir| File.directory?(dir) }
  abort "missing Ruby stdlib dirs: #{missing.join(", ")}" unless missing.empty?
  %w[json openssl psych].each { |lib| require lib }
  puts RUBY_DESCRIPTION
'
gem install --no-document rainbow
ruby -rrainbow -e 'puts Rainbow("gem install ok").green'
bundle --version

# Also exercise Homebrew itself and the standalone zbx wrapper, rather than
# only checking that the pinned package-manager executables start.
brew install hello
hello --version
zbx hello --version
TEST

echo "PASS: Homebrew, mise, zerobrew plugin and mise core lazy installs, and zbx ($IMAGE)"
