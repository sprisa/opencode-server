#!/usr/bin/env bash
# Print every stable upstream release on <track> newer than <current>, one per
# line, oldest first.
# Usage: scripts/pending-releases.sh <track> <current-version>
#   e.g. scripts/pending-releases.sh v2 2.3.0
# Requires an authenticated gh CLI (or GH_TOKEN) and jq.
set -euo pipefail

TRACK="${1:?usage: pending-releases.sh <track> <current-version>}"
CURRENT="${2:?usage: pending-releases.sh <track> <current-version>}"
CURRENT="${CURRENT#v}"

gh api --paginate --slurp "repos/${UPSTREAM_REPO:-anomalyco/opencode}/releases?per_page=100" \
  | jq -r --arg track "$TRACK" --arg current "$CURRENT" '
      ($track | ltrimstr("v") | tonumber) as $major
      | ($current | split(".") | map(tonumber)) as $cur
      | add // []
      | map(
          select(.draft == false and .prerelease == false)
          | .tag_name
          | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
          | ltrimstr("v") | split(".") | map(tonumber)
          | select(.[0] == $major and . > $cur)
        )
      | unique
      | .[]
      | map(tostring) | join(".")
    '
