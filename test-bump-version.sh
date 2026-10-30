#!/usr/bin/env bash
# Quick manual test for bump-version.sh logic
# Run: bash test-bump-version.sh
set -euo pipefail

# Temporary fixture commits must also work on CI runners with no Git identity.
export GIT_AUTHOR_NAME="Release Test"
export GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

SCRIPT="$(cd "$(dirname "$0")" && pwd)/scripts/bump-version.sh"

log()   { echo "  $*"; }
pass()  { log "PASS"; }
fail()  { log "FAIL: $*"; FAILED=1; }

FAILED=0

# ── Helper: set up a mock environment ─────────────────────────────────────────
prep() {
  local D
  D="$(mktemp -d)"
  mkdir -p "$D/bin" "$D/.git"
  cat > "$D/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
mkdir -p "$(dirname "$GH_CALLS")"
echo "$@" >> "$GH_CALLS"
# Mock gh pr list — return a PR URL so pr_exists thinks a PR is found
case "$*" in
  *pr\ list*)
    mkdir -p "/tmp/gh-mock"
    if [ -f "/tmp/gh-mock/force_pr" ]; then
      echo '["https://github.com/user/repo/pull/42 - v1.17.4"]'
    else
      echo ""
    fi
    ;;
esac
MOCKEOF
  chmod +x "$D/bin/gh"
  # Also mock git to allow reset during gh workflow
  cat > "$D/bin/git" <<'EOF'
#!/usr/bin/env bash
# Allow any git command
exit 0
EOF
  chmod +x "$D/bin/git"
  echo "$D"
}

# ── Test 1: Create a new PR (no existing PR) ──────────────────────────────────
log "Test 1: Create a new PR (no existing PR)..."
S1="$(prep)"
echo "1.17.0" > "$S1/version.txt"
pushd "$S1" >/dev/null
git init -q && git add version.txt && git commit -q --allow-empty -m "init"
GH_CALLS="$S1/calls.txt" GH_TOKEN="mock" \
  PATH="$S1/bin:$PATH" bash "$SCRIPT" "1.17.4" >/dev/null 2>&1
popd >/dev/null
c1=$(grep -c 'pr create' "$S1/calls.txt" 2>/dev/null || echo 0)
if [ "$c1" -ge 1 ]; then pass; else fail "no gh pr create captured"; fi
rm -rf "$S1"

# ── Test 2: Skip when version already current ─────────────────────────────────
log "Test 2: gh pr list runs for all bumps (skip logic is in GH Action)..."
S2="$(prep)"
echo "1.17.4" > "$S2/version.txt"
pushd "$S2" >/dev/null
git init -q && git add version.txt && git commit -q --allow-empty -m "init"
GH_CALLS="$S2/calls.txt" GH_TOKEN="mock" \
  PATH="$S2/bin:$PATH" bash "$SCRIPT" "1.17.4" >/dev/null 2>&1
popd >/dev/null
has_list=$(grep -c 'pr list' "$S2/calls.txt" 2>/dev/null || echo 0)
if [ "$has_list" -ge 1 ]; then pass; else fail "expected gh pr list"; fi
rm -rf "$S2"

# ── Test 3: Version format — strips leading v ─────────────────────────────────
log "Test 3: Version format — no double-v (v1.17.4 → v1.17.4)..."
S3="$(prep)"
echo "1.17.0" > "$S3/version.txt"
pushd "$S3" >/dev/null
git init -q && git add version.txt && git commit -q --allow-empty -m "init"
GH_CALLS="$S3/calls.txt" GH_TOKEN="mock" \
  PATH="$S3/bin:$PATH" bash "$SCRIPT" "v1.17.4" >/dev/null 2>&1
popd >/dev/null
if grep -q 'pr/opencode-release/vv' "$S3/calls.txt" 2>/dev/null; then
  fail "double-v found in calls"
else
  pass
fi
rm -rf "$S3"

# ── Test 4: Version format — pre-release tags ─────────────────────────────────
log "Test 4: Version format — pre-release (1.18.0-beta.1)..."
S4="$(prep)"
echo "1.17.0" > "$S4/version.txt"
pushd "$S4" >/dev/null
git init -q && git add version.txt && git commit -q --allow-empty -m "init"
GH_CALLS="$S4/calls.txt" GH_TOKEN="mock" \
  PATH="$S4/bin:$PATH" bash "$SCRIPT" "1.18.0-beta.1" >/dev/null 2>&1
popd >/dev/null
c4=$(grep -c 'pr create' "$S4/calls.txt" 2>/dev/null || echo 0)
if [ "$c4" -ge 1 ] && grep -q '1.18.0-beta.1' "$S4/calls.txt"; then pass; else fail "bad pre-release handling"; fi
rm -rf "$S4"

# ── Test 5: Error on empty version ───────────────────────────────────────────
log "Test 5: Error on empty version string..."
S5="$(prep)"
err=$(GH_TOKEN="mock" PATH="$S5/bin:$PATH" bash "$SCRIPT" "" 2>&1 || true)
if echo "$err" | grep -qi 'usage'; then pass; else fail "no usage error, got: $err"; fi
rm -rf "$S5"

# ── Test 6: Update existing PR ───────────────────────────────────────────────
log "Test 6: Update existing PR (force gh pr list to return PR)..."
S6="$(prep)"
echo "1.17.0" > "$S6/version.txt"
pushd "$S6" >/dev/null
git init -q && git add version.txt && git commit -q --allow-empty -m "init"
mkdir -p /tmp/gh-mock
echo "1" > /tmp/gh-mock/force_pr
GH_CALLS="$S6/calls.txt" GH_TOKEN="mock" \
  PATH="$S6/bin:$PATH" bash "$SCRIPT" "1.17.4" >/dev/null 2>&1
popd >/dev/null
c6=$(grep -c 'pr edit' "$S6/calls.txt" 2>/dev/null || echo 0)
rm -f /tmp/gh-mock/force_pr
if [ "$c6" -ge 1 ]; then pass; else fail "expected 'gh pr edit', got: $(cat "$S6/calls.txt" 2>/dev/null || echo "empty")"; fi
rm -rf "$S6"

# ── Test 7: Explicit version file — v1 track writes version-v1.txt ──────────────
log "Test 7: Explicit version file (version-v1.txt)..."
S7="$(prep)"
echo "2.2.4" > "$S7/version.txt"
echo "1.19.4" > "$S7/version-v1.txt"
pushd "$S7" >/dev/null
git init -q && git add version.txt version-v1.txt && git commit -q --allow-empty -m "init"
GH_CALLS="$S7/calls.txt" GH_TOKEN="mock" \
  PATH="$S7/bin:$PATH" bash "$SCRIPT" "1.19.5" main version-v1.txt >/dev/null 2>&1
popd >/dev/null
if [ "$(cat "$S7/version-v1.txt" 2>/dev/null | tr -d '[:space:]')" = "1.19.5" ] \
   && [ "$(cat "$S7/version.txt" | tr -d '[:space:]')" = "2.2.4" ] \
   && grep -q 'pr create' "$S7/calls.txt" 2>/dev/null; then pass
else fail "version-v1.txt not written or version.txt modified"; fi
rm -rf "$S7"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
if [ "${FAILED:-0}" = "0" ]; then
  echo "All tests passed."
else
  echo "Some tests FAILED." >&2
  exit 1
fi
