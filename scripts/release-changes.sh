#!/bin/bash
# Lists what changed since the last tag, as markdown: scripts/release-changes.sh [base-ref]
#
#   scripts/release-changes.sh          # since the last tag
#   scripts/release-changes.sh v0.8.0   # since another ref
#
# Commits grouped by Conventional Commit type, the docs each change likely
# touches ("surfaces"), and a suggested version (any feat: minor, else patch).
# Read-only. The surface flags are hints for /visor-release, not rules.
set -euo pipefail
cd "$(dirname "$0")/.."

LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
BASE="${1:-$LAST_TAG}"
if [[ -z "$BASE" ]]; then
  echo "release-changes: no tag yet; pass a base ref" >&2
  exit 2
fi
RANGE="$BASE..HEAD"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git log --no-merges --format='%s' "$RANGE" > "$TMP/subjects"
git diff --name-only "$RANGE" > "$TMP/files"

echo "# Changes since $BASE"
echo
echo "$(wc -l < "$TMP/subjects" | tr -d ' ') commits, $(wc -l < "$TMP/files" | tr -d ' ') files."

# Commits by type. "feat(scope)!: text" counts as feat.
section() {
  local title="$1" pattern="$2" lines
  lines="$(grep -E "$pattern" "$TMP/subjects" || true)"
  [[ -z "$lines" ]] && return 0
  echo
  echo "## $title"
  echo
  echo "$lines" | sed 's/^/- /'
}
TYPED='^(feat|fix|perf)(\([^)]*\))?!?:'
section "Features" '^feat(\([^)]*\))?!?:'
section "Fixes" '^fix(\([^)]*\))?!?:'
section "Performance" '^perf(\([^)]*\))?!?:'
OTHERS="$(grep -vE "$TYPED" "$TMP/subjects" || true)"
if [[ -n "$OTHERS" ]]; then
  echo
  echo "## Other"
  echo
  echo "$OTHERS" | sed 's/^/- /'
fi

# Surfaces: which docs probably need a look.
echo
echo "## Surfaces"
echo
SURF=0
flag() { echo "- **$1**: $2"; SURF=1; }

FEATS="$(grep -cE '^feat(\([^)]*\))?!?:' "$TMP/subjects" || true)"
AREAS="$(grep -E '^Sources/(Visor|VisorCore)/' "$TMP/files" | grep -v '^Sources/Visor/Support/' |
  awk -F/ '{ a = $3; sub(/\.swift$/, "", a); print a }' | sort -u | paste -sd' ' - || true)"
if [[ "$FEATS" -gt 0 ]]; then
  flag "features" "$FEATS feat commit(s); areas: ${AREAS:-none}. Docs agent: README Features, docs/features.md. Website agent: docs/index.html."
fi

# New hosts in added lines, and new paths under Application Support.
git diff -U0 "$RANGE" -- Sources Resources | grep -E '^\+[^+]' > "$TMP/added" || true
HOSTS="$(grep -oE 'https://[A-Za-z0-9.-]+' "$TMP/added" | sort -u || true)"
NEW_HOSTS=""
for h in $HOSTS; do
  git grep -qF "$h" "$BASE" -- Sources Resources 2>/dev/null || NEW_HOSTS+="${NEW_HOSTS:+ }$h"
done
STORAGE="$(grep -oE 'Application Support/Visor/[A-Za-z0-9._/-]+|appendingPathComponent\("[A-Za-z0-9._-]+\.(json|log|sock)"\)' "$TMP/added" | sort -u | paste -sd' ' - || true)"
if [[ -n "$NEW_HOSTS" || -n "$STORAGE" ]]; then
  flag "network or storage" "new hosts: ${NEW_HOSTS:-none}; new files: ${STORAGE:-none}. Docs agent: docs/how-it-works.md, SECURITY.md."
fi

# Hooks, sockets, plugins: what Visor installs or exposes.
SEC="$(grep -E 'HookInstaller|HookServer|Socket|Plugins?/|PluginSecret|Keychain' "$TMP/files" | paste -sd' ' - || true)"
[[ -n "$SEC" ]] && flag "hooks, sockets or plugins" "$SEC. Docs agent: docs/how-it-works.md, SECURITY.md; docs/plugins.md if the plugin API changed."

# UI files: screenshots may be stale.
UI="$(grep -E '^Sources/Visor/' "$TMP/files" | grep -vE '^Sources/Visor/(Support|App)/' |
  awk -F/ '{ print $3 }' | sed 's/\.swift$//' | sort -u | paste -sd' ' - || true)"
if [[ -n "$UI" ]]; then
  # docs/assets images whose name matches a changed area (Notch: closed-notch).
  IMGS=""
  for area in $UI; do
    key="$(echo "$area" | tr '[:upper:]' '[:lower:]')"
    IMGS+="$(ls docs/assets 2>/dev/null | grep -i -- "$key" | sed 's|^|docs/assets/|' | paste -sd' ' -) "
  done
  IMGS="$(echo "$IMGS" | xargs)"
  flag "UI" "changed: $UI. May be stale: ${IMGS:-no matching images}. List them in the review; no recapture by default."
fi

# Docs already touched in this range.
DOCS="$(grep -E '^(README\.md|SECURITY\.md|docs/)' "$TMP/files" | paste -sd' ' - || true)"
[[ -n "$DOCS" ]] && flag "docs already changed" "$DOCS"

[[ $SURF == 0 ]] && echo "- none flagged: no docs agents needed"

# Suggested version.
CUR="${LAST_TAG#v}"
IFS=. read -r MA MI PA <<< "${CUR:-0.0.0}"
if [[ "$FEATS" -gt 0 ]]; then NEXT="$MA.$((MI + 1)).0"; WHY="feat commits"; else NEXT="$MA.$MI.$((PA + 1))"; WHY="no feat commits"; fi
echo
echo "## Suggested version"
echo
echo "$NEXT ($WHY; last tag ${LAST_TAG:-none})"
