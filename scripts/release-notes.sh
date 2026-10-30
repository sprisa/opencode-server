#!/usr/bin/env bash
#
# Generate git-cliff-style release notes from Conventional Commits since the
# previous v* tag. Output is Markdown on stdout.
#
#   Usage: scripts/release-notes.sh <new-tag> [owner/repo]
#   e.g.   scripts/release-notes.sh v1.17.4 sprisa/opencode
#
# Commit subjects are grouped by type (feat, fix, ...). Squash-merged PR refs
# like "(#123)" are turned into links, and every entry links to its commit -
# mirroring what GitHub's --generate-notes does, but driven by commits so it
# works with a direct-to-main workflow.
set -euo pipefail

TAG="${1:?usage: release-notes.sh <new-tag> [owner/repo]}"
REPO="${2:-${RELEASE_REPO:-sprisa/opencode-server}}"
REPO_URL="https://github.com/${REPO}"
VERSION="${TAG#v}"          # image version without the leading "v"

# Highest older stable version in this commit's history. This prefers the same
# major, falls back to a lower major for the first release of a new line, and
# excludes newer versions when regenerating notes for an older release.
IFS=. read -r MAJOR MINOR PATCH <<< "${VERSION%%[-+]*}"
MAJOR=$((10#$MAJOR)); MINOR=$((10#$MINOR)); PATCH=$((10#$PATCH))
PREV=""
while IFS= read -r candidate; do
  [[ "$candidate" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || continue
  major=$((10#${BASH_REMATCH[1]}))
  minor=$((10#${BASH_REMATCH[2]}))
  patch=$((10#${BASH_REMATCH[3]}))
  if (( major < MAJOR || (major == MAJOR && minor < MINOR) ||
        (major == MAJOR && minor == MINOR && patch < PATCH) )); then
    PREV="$candidate"
    break
  fi
done < <(git tag --merged HEAD --list 'v*' --sort=-v:refname)
if [ -n "$PREV" ]; then
  RANGE="${PREV}..HEAD"
else
  RANGE="HEAD"   # first release: include all history
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Conventional Commit subject: type(scope)?!?: description
cc_re='^([a-zA-Z]+)(\(([^)]*)\))?(!)?:[[:space:]]+(.*)$'

# Bucket each commit into $tmp/<type>.
while IFS="$(printf '\t')" read -r subject hash; do
  [ -n "$subject" ] || continue

  if [[ "$subject" =~ $cc_re ]]; then
    type="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
    scope="${BASH_REMATCH[3]}"
    bang="${BASH_REMATCH[4]}"
    desc="${BASH_REMATCH[5]}"
  else
    type="other"; scope=""; bang=""; desc="$subject"
  fi

  # Only keep known types in their bucket; everything else -> other.
  case "$type" in
    feat|fix|perf|refactor|docs|style|test|build|ci|chore|revert) ;;
    *) type="other" ;;
  esac

  # Turn "(#123)" PR references into links.
  desc="$(printf '%s' "$desc" | sed -E "s@\(#([0-9]+)\)@([#\1](${REPO_URL}/pull/\1))@g")"

  line="-"
  [ -n "$scope" ] && line="$line **${scope}:**"
  line="$line ${desc}"
  [ -n "$bang" ] && line="$line **(breaking)**"
  line="$line ([\`${hash}\`](${REPO_URL}/commit/${hash}))"

  printf '%s\n' "$line" >> "$tmp/$type"
# The trailing `printf '\n'` appends a newline: git's --pretty=format omits one
# after the last commit, so otherwise `read` would drop the final entry.
done < <(git log --no-merges --reverse --pretty=format:'%s%x09%h' "$RANGE"; printf '\n')

# Emit one group (if it has any entries). Args: <type> <emoji heading>
emit() {
  if [ -s "$tmp/$1" ]; then
    printf '### %s\n\n' "$2"
    cat "$tmp/$1"
    printf '\n'
  fi
}

# Install instructions for this exact version, up top.
printf '### 📦 Install\n\n'
printf '```bash\n'
printf 'docker run -it -p 4096:4096 -v $(pwd):/home/opencode sprisa/opencode:%s\n' "$VERSION"
printf '```\n\n'

# Emit groups in a fixed, git-cliff-like order.
emit feat     "🚀 Features"
emit fix      "🐛 Bug Fixes"
emit perf     "⚡ Performance"
emit refactor "🚜 Refactor"
emit docs     "📚 Documentation"
emit style    "🎨 Styling"
emit test     "🧪 Testing"
emit build    "📦 Build"
emit ci       "⚙️ CI"
emit chore    "🧹 Miscellaneous Tasks"
emit revert   "◀️ Revert"
emit other    "🔗 Other"

# Footer: compare link (or commit list for the very first release).
if [ -n "$PREV" ]; then
  printf '**Full Changelog**: %s/compare/%s...%s\n' "$REPO_URL" "$PREV" "$TAG"
else
  printf '**Full Changelog**: %s/commits/%s\n' "$REPO_URL" "$TAG"
fi
