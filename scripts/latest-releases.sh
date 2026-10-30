#!/usr/bin/env bash
# Print the highest stable upstream release for each supported major as JSON.
# Requires an authenticated gh CLI (or GH_TOKEN) and jq.
set -euo pipefail

gh api --paginate --slurp "repos/${UPSTREAM_REPO:-anomalyco/opencode}/releases?per_page=100" \
  | jq -e '
      (add // [] | map(
        select(.draft == false and .prerelease == false)
        | .tag_name
        | select(test("^v[12]\\.[0-9]+\\.[0-9]+$"))
        | ltrimstr("v") | split(".") | map(tonumber)
      )) as $versions
      | reduce [1, 2][] as $major ({};
          ($versions | map(select(.[0] == $major)) | max) as $latest
          | if $latest == null then error("No stable v\($major) release found")
            else .["v\($major)"] = ($latest | map(tostring) | join("."))
            end
        )
    '
