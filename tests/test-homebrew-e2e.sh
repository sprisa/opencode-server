#!/usr/bin/env bash
# Exercise Homebrew end to end in the real image.
# Usage: bash tests/test-homebrew-e2e.sh <image>
#
# The image trims Homebrew to save space: a shallow clone of the pinned release
# and no bundled portable Ruby. A broken Homebrew repository still passes
# `brew --version`, so this covers the whole lifecycle.
set -euo pipefail

IMAGE="${1:?usage: tests/test-homebrew-e2e.sh <image>}"

echo "Testing Homebrew (${IMAGE}; 15-minute timeout)..."
docker run --rm -i -e GITHUB_TOKEN --entrypoint timeout "$IMAGE" 900 bash -s <<'TEST'
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

prefix=/home/linuxbrew/.linuxbrew
repo="$prefix/Homebrew"
cellar="$prefix/Cellar"

# Setup, before brew touches the network.
[ "$(command -v brew)" = "$prefix/bin/brew" ] || fail "brew is not on PATH (got '$(command -v brew)')"
[ "$(bash -lc 'command -v brew')" = "$prefix/bin/brew" ] || fail "brew is not on PATH in a login shell"
[ "${HOMEBREW_NO_AUTO_UPDATE:-}" = 1 ] || fail "HOMEBREW_NO_AUTO_UPDATE is not set"
[ "${HOMEBREW_INSTALL_FROM_API:-}" = 1 ] || fail "HOMEBREW_INSTALL_FROM_API is not set"
[ -w "$prefix" ] && [ -w "$repo" ] || fail "the opencode user cannot write to Homebrew"
[ ! -d "$repo/Library/Taps/homebrew/homebrew-core" ] || fail "homebrew-core is tapped; the image installs from the API"
ok "brew is on PATH for login and non-login shells, writable, and in API mode"

[ -d "$repo/.git" ] || fail "Homebrew's .git is missing; brew needs it"
[ "$(git -C "$repo" rev-parse --is-shallow-repository)" = true ] || fail "Homebrew is no longer a shallow clone"
git -C "$repo" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null || fail "origin/main is missing; brew update prints an error"
tag="$(git -C "$repo" describe --tags --exact-match)" || fail "HEAD is not a release tag"
[ "$(brew --version | head -1)" = "Homebrew $tag" ] || fail "brew --version does not match the checked-out tag $tag"
[ ! -e "$repo/Library/Homebrew/vendor/portable-ruby" ] || fail "the image ships portable Ruby (45 MB); brew should download it on first use"
ok "shallow clone of Homebrew $tag with origin/main and no bundled portable Ruby"

# First Ruby-backed command downloads Homebrew's own portable Ruby.
brew config >/tmp/config.log 2>&1 || { tail -5 /tmp/config.log >&2; fail "brew config failed"; }
grep -q "^Homebrew Ruby: .* => $repo/Library/Homebrew/vendor/portable-ruby/" /tmp/config.log \
  || { grep -i ruby /tmp/config.log >&2; fail "brew is not running on its portable Ruby"; }
ok "first brew command downloads and uses Homebrew's portable Ruby"

# brew doctor may only report the image's known, harmless warnings: no
# compiler, and the files the build deletes from the Homebrew checkout.
brew doctor >/tmp/doctor.log 2>&1 || true
unexpected="$(grep '^Warning:' /tmp/doctor.log \
  | grep -vE 'No developer tools installed|You have uncommitted modifications to Homebrew/brew' || true)"
[ -z "$unexpected" ] || { cat /tmp/doctor.log >&2; fail "brew doctor reported new warnings: $unexpected"; }
ok "brew doctor reports only the known warnings"

# Install a bottle with a dependency, link it, and run it.
brew install jq >/tmp/install.log 2>&1 || { tail -5 /tmp/install.log >&2; fail "brew install jq failed"; }
brew deps --installed jq | grep -qx oniguruma || fail "jq's dependency oniguruma was not installed"
[ "$("$prefix/bin/jq" -n '1 + 1')" = 2 ] || fail "Homebrew's jq does not run"
if ldd "$prefix/bin/jq" | grep -q 'not found'; then ldd "$prefix/bin/jq" >&2; fail "jq has unresolved libraries"; fi
ok "brew install resolves dependencies and links working binaries"

# Upgrade: relabel an installed keg as an older version so it is outdated.
brew install hello >/dev/null 2>&1 || fail "brew install hello failed"
current="$(ls "$cellar/hello")"
brew unlink hello >/dev/null
mv "$cellar/hello/$current" "$cellar/hello/0.1"
brew link --overwrite hello >/dev/null || fail "brew link failed for the relabeled hello"
brew outdated --formula | grep -qx hello || fail "brew outdated did not report the old hello"
brew upgrade >/tmp/upgrade.log 2>&1 || { tail -5 /tmp/upgrade.log >&2; fail "brew upgrade failed"; }
[ "$(ls "$cellar/hello")" = "$current" ] || fail "brew upgrade left hello at $(ls "$cellar/hello")"
"$prefix/bin/hello" --version >/dev/null || fail "upgraded hello does not run"
ok "brew outdated and brew upgrade bring hello back to $current"

# Uninstall and remove orphaned dependencies.
brew uninstall jq >/dev/null 2>&1 || fail "brew uninstall jq failed"
brew autoremove >/dev/null 2>&1 || fail "brew autoremove failed"
if brew list --formula | grep -qxE 'jq|oniguruma'; then fail "jq or oniguruma is still installed"; fi
[ ! -e "$prefix/bin/jq" ] || fail "jq is still linked"
ok "brew uninstall and autoremove remove jq and oniguruma"

# Third-party taps need trusting in Homebrew 7. Installing a tap formula
# without a bottle needs a compiler, which the image doesn't ship (the README
# says to install build-essential first), so only check the tap itself here.
brew tap sprisa/tap >/dev/null 2>&1 || fail "brew tap sprisa/tap failed"
brew trust sprisa/tap >/dev/null 2>&1 || fail "brew trust sprisa/tap failed"
brew info sprisa/tap/clonetree >/tmp/tap.log 2>&1 || { tail -5 /tmp/tap.log >&2; fail "brew info for a tap formula failed"; }
ok "brew tap, trust, and info for a third-party tap"

brew cleanup >/dev/null 2>&1 || fail "brew cleanup failed"
ok "brew cleanup"

# Last, so the steps above run on the pinned release. Updating moves Homebrew
# to a newer release through the shallow clone, without errors. Exit codes
# alone miss a broken repository: without .git, brew reports
# "Homebrew >=4.3.0 (shallow or no git repository)", and `brew update` re-clones
# every branch and lands on unreleased main (e.g. 7.0.13-128-gfc51ba6).
brew update >/tmp/update.log 2>&1 || { tail -5 /tmp/update.log >&2; fail "brew update failed"; }
if grep -qiE '^(error|fatal)' /tmp/update.log; then grep -iE '^(error|fatal)' /tmp/update.log >&2; fail "brew update printed errors"; fi
updated="$(brew --version | head -1)"
[[ "$updated" =~ ^Homebrew\ [0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "brew update left a non-release version: $updated"
brew config >/dev/null 2>&1 || fail "brew config failed after brew update"
ok "brew update moves from $tag to the release ${updated#Homebrew }"
TEST

echo "PASS: Homebrew e2e (${IMAGE})"
