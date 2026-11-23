#!/bin/bash
# Publishes a built and verified release:
#   scripts/release-publish.sh <version> <notes-file> [--dry-run]
#
#   scripts/release-publish.sh 0.9.0 build/notes-0.9.0.md --dry-run   # print only
#   scripts/release-publish.sh 0.9.0 build/notes-0.9.0.md
#
# Steps, in order (each is skipped when already done, so a rerun resumes):
#   1. add the notes to this version's appcast.xml item as its description
#   2. tag v<version> on the commit the zip was built from
#   3. commit appcast.xml ("chore(release): <version> in the appcast", noreply email)
#   4. push main and the tag
#   5. gh release create with the zip and the notes
#   6. bump Casks/visor.rb in the tap clone (version, sha256), commit, push
#   7. print checks: release URL, the appcast on main, brew info
# Run it only after the user said to ship. It stops at the first failure and
# says what was done.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
VERSION="${VERSION#v}"
NOTES="${2:-}"
DRY=0
[[ "${3:-}" == --dry-run ]] && DRY=1
if [[ -z "$VERSION" || -z "$NOTES" ]]; then
  echo "usage: scripts/release-publish.sh <version> <notes-file> [--dry-run]" >&2
  exit 2
fi

TAG="v$VERSION"
ZIP="build/Visor-$VERSION.zip"
TAP="${VISOR_TAP:-$HOME/workspace/homebrew-tap}"
CASK="$TAP/Casks/visor.rb"
EMAIL="tailamphat@users.noreply.github.com"
REPO=tailamphat/visor
DONE=()

step() { echo; echo "== $1"; }
run() {
  echo "+ $(printf '%q ' "$@")"
  [[ $DRY == 1 ]] && return 0
  "$@"
}
gitc() { run git -c user.email="$EMAIL" "$@"; }
finish() {
  local code=$?
  if [[ $code != 0 && $DRY == 0 ]]; then
    echo
    echo "release-publish: FAILED. Done so far: ${DONE[*]:-nothing}."
    echo "Fix the cause and rerun the same command: finished steps are skipped."
  fi
}
trap finish EXIT

[[ -r "$NOTES" ]] || { echo "notes file not readable: $NOTES" >&2; exit 1; }
if [[ ! -f "$ZIP" ]]; then
  [[ $DRY == 1 ]] && echo "note: no $ZIP yet (dry run continues)" || { echo "no $ZIP: run scripts/release.sh $VERSION" >&2; exit 1; }
fi
SHA="$( [[ -f "$ZIP" ]] && shasum -a 256 "$ZIP" | cut -d' ' -f1 || echo '<sha256 of the zip>')"
[[ -s "$NOTES" ]] || echo "note: $NOTES is empty"

# 1. Notes as the appcast item's description (HTML; the signature covers the zip only).
step "1. appcast description"
if awk -v v="$VERSION" '
  /<item>/ { buf = "" } { buf = buf $0 "\n" }
  /<\/item>/ && buf ~ "<sparkle:shortVersionString>" v "<" && buf ~ "<description>" { found = 1 }
  END { exit !found }' appcast.xml; then
  echo "already has a description"
elif ! grep -q "<sparkle:shortVersionString>$VERSION<" appcast.xml; then
  [[ $DRY == 1 ]] && echo "would add the notes to the $VERSION item (no item yet: release.sh adds it)" ||
    { echo "appcast.xml has no $VERSION item: run scripts/release.sh $VERSION" >&2; exit 1; }
else
  # Markdown subset: "## x" headings, "- x" items, other lines paragraphs.
  HTML="$(awk '
    function close_list() { if (ul) { print "</ul>"; ul = 0 } }
    /^## / { close_list(); print "<h3>" substr($0, 4) "</h3>"; next }
    /^# / { next }
    /^- / { if (!ul) { print "<ul>"; ul = 1 } print "<li>" substr($0, 3) "</li>"; next }
    /^[[:space:]]*$/ { close_list(); next }
    { close_list(); print "<p>" $0 "</p>" }
    END { close_list() }' "$NOTES")"
  echo "$HTML" | sed 's/^/  /'
  if [[ $DRY == 0 ]]; then
    HTML="$HTML" awk -v v="$VERSION" '
      { lines[NR] = $0 }
      /<sparkle:shortVersionString>/ && index($0, ">" v "<") { mark = NR }
      END {
        for (i = 1; i <= NR; i++) {
          print lines[i]
          if (i == mark) print "            <description><![CDATA[" ENVIRON["HTML"] "]]></description>"
        }
      }' appcast.xml > appcast.xml.new && mv appcast.xml.new appcast.xml
  fi
fi
DONE+=("appcast description")

# 2. Tag the build commit (CFBundleVersion is its commit count), before the appcast commit.
step "2. tag $TAG"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "tag exists at $(git rev-parse --short "$TAG^{commit}")"
else
  BUILD="$( [[ -f "$ZIP" ]] && /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/Visor.app/Contents/Info.plist 2>/dev/null || git rev-list --count HEAD)"
  [[ "$BUILD" == "$(git rev-list --count HEAD)" ]] ||
    { echo "HEAD has $(git rev-list --count HEAD) commits but the app was built at $BUILD: tag by hand" >&2; exit 1; }
  gitc tag -a "$TAG" -m "Visor $VERSION"
fi
DONE+=("tag")

# 3. Commit appcast.xml.
step "3. commit appcast.xml"
OTHER="$(git status --porcelain | grep -v ' appcast.xml$' || true)"
if [[ -n "$OTHER" ]]; then
  echo "other uncommitted files (commit the docs first):"; echo "$OTHER"
  [[ $DRY == 1 ]] || exit 1
fi
if git diff --quiet -- appcast.xml && [[ $DRY == 0 ]]; then
  echo "nothing to commit"
else
  run git add appcast.xml
  gitc commit -m "chore(release): $VERSION in the appcast"
fi
DONE+=("appcast commit")

# 4. Push main, then the tag.
step "4. push main and $TAG"
run git push origin main
run git push origin "$TAG"
DONE+=("push")

# 5. GitHub release.
step "5. GitHub release $TAG"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "release exists"
else
  run gh release create "$TAG" "$ZIP" -R "$REPO" --title "Visor $VERSION" --notes-file "$NOTES"
fi
DONE+=("GitHub release")

# 6. Homebrew cask.
step "6. tap: Casks/visor.rb -> $VERSION"
[[ -f "$CASK" ]] || { echo "no cask at $CASK (set VISOR_TAP)" >&2; exit 1; }
if grep -q "version \"$VERSION\"" "$CASK" && grep -q "sha256 \"$SHA\"" "$CASK"; then
  echo "cask already at $VERSION"
else
  run git -C "$TAP" pull -q --ff-only
  run sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
  run git -C "$TAP" add Casks/visor.rb
  gitc -C "$TAP" commit -m "visor $VERSION"
fi
run git -C "$TAP" push origin HEAD
DONE+=("tap")

# 7. Checks.
step "7. checks"
echo "release: https://github.com/$REPO/releases/tag/$TAG"
if [[ $DRY == 1 ]]; then
  echo "+ curl -fsSL https://raw.githubusercontent.com/$REPO/main/appcast.xml | grep $VERSION"
  echo "+ brew update && brew info --cask tailamphat/tap/visor"
else
  if curl -fsSL "https://raw.githubusercontent.com/$REPO/main/appcast.xml" | grep -q "<sparkle:shortVersionString>$VERSION<"; then
    echo "appcast on main: has $VERSION"
  else
    echo "appcast on main: no $VERSION yet (raw files can lag a few minutes)"
  fi
  brew update >/dev/null 2>&1 || true
  brew info --cask tailamphat/tap/visor | head -3
fi
echo
[[ $DRY == 1 ]] && echo "release-publish: dry run, nothing changed" || echo "release-publish: done"
