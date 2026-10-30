#!/usr/bin/env bash
# Bump opencode version and create/update a PR.
# Usage: scripts/bump-version.sh <upstream-version> <target-branch> [version-file]
# Requires: curl, jq, gh, git
set -euo pipefail

VERSION="${1:?usage: bump-version.sh <upstream-version> [target-branch] [version-file]}"
VERSION="${VERSION#v}"
BRANCH="pr/opencode-release/v${VERSION}"
TARGET="${2:-main}"
VERSION_FILE="${3:-version.txt}"
UPSTREAM_REPO="anomalyco/opencode"

log() { echo "[bump] $*"; }
die() { echo "[bump] error: $*" >&2; exit 1; }

[ -z "$VERSION" ] && die "version must not be empty"

pr_exists() {
  gh pr list --state open --head "$BRANCH" --json url -q '.[].url' 2>/dev/null | grep -q .
}

fetch_changelog() {
  gh api "repos/${UPSTREAM_REPO}/releases/tags/v${VERSION}" --jq '.body' 2>/dev/null || true
}

pr_body() {
  local changelog="$1"
  cat <<EOB
## What's Changed

${changelog}

---

**Full Changelog**: https://github.com/${UPSTREAM_REPO}/releases/tag/v${VERSION}

> This PR was created automatically by a scheduled workflow.
EOB
}

create_pr() {
  local title="feat: opencode release v${VERSION}"
  local changelog
  changelog="$(fetch_changelog)"
  local body
  body="$(pr_body "$changelog")"

  gh pr create \
    --title "$title" \
    --body "$body" \
    --base "$TARGET"
}

update_pr() {
  local title="feat: opencode release v${VERSION}"
  local changelog
  changelog="$(fetch_changelog)"
  local body
  body="$(pr_body "$changelog")"

  gh pr edit \
    --title "$title" \
    --body "$body"
}

log "Checking for existing PR for v${VERSION}..."

git fetch origin "$BRANCH" 2>/dev/null && git checkout "$BRANCH" || git checkout -b "$BRANCH"

echo "$VERSION" > "$VERSION_FILE"

if git ls-files --error-unmatch "$VERSION_FILE" >/dev/null 2>&1 && git diff --quiet HEAD -- "$VERSION_FILE"; then
  log "version file already up to date"
else
  git add "$VERSION_FILE"
  git commit -m "feat: opencode release v${VERSION}"
  git push origin "$BRANCH"
fi

if pr_exists; then
  log "PR for v${VERSION} already exists, updating..."
  update_pr
else
  log "Creating new PR for v${VERSION}..."
  create_pr
fi

git checkout "${TARGET}" 2>/dev/null || true
