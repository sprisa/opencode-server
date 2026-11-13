#!/usr/bin/env bash
# Exercise the build-time mise lockfile in the real image.
# Usage: bash tests/test-mise-lock-e2e.sh <image>
#
# Runs without GITHUB_TOKEN on purpose: locked tools must not need the GitHub
# API, and codex's release list (~10 MB) must never be fetched on first use.
set -euo pipefail

IMAGE="${1:?usage: tests/test-mise-lock-e2e.sh <image>}"

echo "Checking the image lockfile and locked first runs (${IMAGE})..."
docker run --rm -i --entrypoint timeout "$IMAGE" 600 bash -s <<'TEST'
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

lock=/etc/mise/mise.lock
[ -f "$lock" ] || fail "missing $lock"
[ "$(stat -c %U "$lock")" = opencode ] || fail "$lock must be owned by opencode"
[ -w /etc/mise ] || fail "/etc/mise must be writable by opencode"

# locked_version <config key> prints the version locked for that tool.
locked_version() {
  awk -v a="[[tools.$1]]" -v b="[[tools.\"$1\"]]" '
    $0 == a || $0 == b { found = 1; next }
    found && /^version = / { gsub(/"/, "", $3); print $3; exit }
  ' "$lock"
}

# install_dir <config key> matches mise's install directory naming.
install_dir() { printf '/opt/mise/installs/%s' "$(printf '%s' "$1" | tr ':/' '--')"; }

# Every non-zerobrew tool in the system config is locked to a real version.
grep -E '^\s*"' /etc/mise/config.toml | cut -d'"' -f2 | while read -r key; do
  case "$key" in zerobrew:*) continue ;; esac
  version="$(locked_version "$key")"
  case "$version" in
    "" | latest) fail "$key is not locked to a concrete version (got '${version}')" ;;
  esac
done
echo "ok: every mise core and github tool is locked"

# First runs install the locked version without fetching any release list.
# codex is the regression case: its list is too large for mise's timeout.
cp "$lock" /tmp/lock.before
for pair in jq:jq codex:codex github-cli:gh github:sprisa/clonetree:clonetree; do
  key="${pair%:*}" command="${pair##*:}"
  log="/tmp/first-run-${command}.log"
  if ! MISE_DEBUG=1 timeout 60 "$command" --version </dev/null >"$log" 2>&1; then
    tail -5 "$log" >&2
    fail "$command did not finish its first run within 60s"
  fi
  if grep -qE 'api\.github\.com|mise-versions\.jdx\.dev/api|Remote versions cannot be fetched|Failed to resolve tool version list' "$log"; then
    grep -E 'api\.github\.com|mise-versions\.jdx\.dev/api|Remote versions|Failed to resolve' "$log" | head -3 | cut -c1-200 >&2
    fail "$command looked up remote versions instead of using the lockfile"
  fi
  version="$(locked_version "$key")"
  [ -d "$(install_dir "$key")/$version" ] || fail "$command did not install locked version $version"
  echo "ok: $command installed locked $version with no version lookup"
done
cmp -s /tmp/lock.before "$lock" || fail "the lockfile changed during first runs"

# Tools the image doesn't ship resolve latest at runtime and leave no lockfiles.
mkdir -p ~/workspace/lock-project && cd ~/workspace/lock-project
mise use shellcheck >/tmp/use.log 2>&1 || { tail -3 /tmp/use.log >&2; fail "mise use shellcheck failed"; }
newest="$(mise latest shellcheck)"
installed="$(shellcheck --version | sed -n 's/^version: //p')"
[ "$installed" = "$newest" ] || fail "shellcheck resolved $installed, newest is $newest"
[ ! -e mise.lock ] || fail "mise use wrote mise.lock into the project"
[ ! -e ~/.config/mise/mise.lock ] || fail "mise wrote a user lockfile"
echo "ok: bare 'mise use shellcheck' resolves latest ($installed) without writing lockfiles"
TEST

# An old image keeps its locked versions with no lookup, and explicit requests
# still reach the newest release. Simulate a build that locked jq 1.7.1 and
# fd 10.1.0 for their "latest" requests.
echo "Checking old-image lockfile behavior (${IMAGE})..."
docker run --rm -i -u root --entrypoint timeout "$IMAGE" 900 bash -s <<'TEST'
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

cp /etc/mise/config.toml /tmp/config.toml
sed -i -e 's/^"jq" = "latest"/"jq" = "1.7.1"/' -e 's/^"fd" = "latest"/"fd" = "10.1.0"/' /etc/mise/config.toml
(cd / && MISE_LOCKFILE=1 MISE_CACHE_DIR=/tmp/root-cache MISE_STATE_DIR=/tmp/root-state \
  mise lock -g --platform linux-x64,linux-arm64 jq fd >/dev/null)
cp /tmp/config.toml /etc/mise/config.toml
for tool in jq fd; do
  sed -i "/^\[\[tools.$tool\]\]/,/^\[\[/ s/^specifiers = .*/specifiers = [\"latest\"]/" /etc/mise/mise.lock
done
chown opencode:opencode /etc/mise/mise.lock
chown -R opencode:opencode /opt/mise

sudo -u opencode HOME=/home/opencode PATH="$PATH" MISE_DATA_DIR=/opt/mise bash -s <<'USER'
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
cd ~/workspace

MISE_DEBUG=1 jq --version >/tmp/old.log 2>&1 || { tail -3 /tmp/old.log >&2; fail "jq failed"; }
grep -q '^jq-1.7.1$' /tmp/old.log || fail "old lockfile's jq 1.7.1 was not used"
if grep -qE 'api\.github\.com|mise-versions\.jdx\.dev/api' /tmp/old.log; then
  fail "old lockfile still looked up remote versions"
fi
echo "ok: an old lockfile keeps its version with no lookup"

newest="$(mise latest jq)"
[ "$newest" != 1.7.1 ] || fail "test needs a jq release newer than 1.7.1"
check() { # check <expected> <description> <command...>
  local expected="$1" description="$2"
  shift 2
  rm -rf ~/workspace/lock-project && mkdir -p ~/workspace/lock-project && cd ~/workspace/lock-project
  "$@" >/tmp/check.log 2>&1 || { tail -3 /tmp/check.log >&2; fail "$description failed"; }
  [ "$(jq --version)" = "jq-$expected" ] || fail "$description gave $(jq --version), expected jq-$expected"
  echo "ok: $description gives jq $expected"
}
check 1.7.1 "bare 'mise use jq'" mise use jq
check "$newest" "'mise use jq@latest'" mise use jq@latest
check "$newest" "'mise upgrade jq'" bash -c 'mise use jq && mise upgrade jq'

# Bare `mise upgrade` outside a project bumps image tools and rewrites the
# image lockfile. fd is only touched here, so earlier checks can't mask it.
# Like it does without a lockfile, this also installs every configured tool.
cd ~/workspace
[ "$(fd --version)" = "fd 10.1.0" ] || fail "old lockfile's fd 10.1.0 was not used"
newest_fd="$(mise latest fd)"
[ "$newest_fd" != 10.1.0 ] || fail "test needs an fd release newer than 10.1.0"
timeout 600 mise upgrade >/tmp/upgrade.log 2>&1 || { tail -3 /tmp/upgrade.log >&2; fail "bare 'mise upgrade' failed"; }
[ "$(fd --version)" = "fd $newest_fd" ] || fail "bare 'mise upgrade' left $(fd --version), expected fd $newest_fd"
grep -A1 '^\[\[tools.fd\]\]' /etc/mise/mise.lock | grep -q "^version = \"$newest_fd\"" \
  || fail "bare 'mise upgrade' did not update fd in the image lockfile"
echo "ok: bare 'mise upgrade' upgrades fd 10.1.0 to $newest_fd and updates the lockfile"
USER
TEST

echo "PASS: mise lockfile e2e (${IMAGE})"
