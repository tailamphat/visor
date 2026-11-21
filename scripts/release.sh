#!/bin/bash
# Builds the universal Visor.app zip for a GitHub release, and prints its sha256.
#
#   scripts/release.sh             # version from the nearest git tag (v0.1.0)
#   scripts/release.sh 0.2.0       # explicit version
#
# The zip is build/Visor-<version>.zip. Upload it to the matching GitHub
# release, commit and push appcast.xml (installed apps update from it), then
# put the version and sha256 in the Homebrew cask.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-${VISOR_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.1.0)}}"
VERSION="${VERSION#v}"

# CFBundleVersion is the commit count, which Sparkle compares: a release must be
# built from a clean tree at or after the last tag. VISOR_RELEASE_FORCE=1 skips this.
if [[ "${VISOR_RELEASE_FORCE:-}" != 1 ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Uncommitted changes: commit or stash them first." >&2
    exit 1
  fi
  LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  if [[ -n "$LAST_TAG" ]] && ! git merge-base --is-ancestor "$LAST_TAG" HEAD; then
    echo "HEAD is behind $LAST_TAG: build releases from the latest commit." >&2
    exit 1
  fi
fi

VISOR_VERSION="$VERSION" ./scripts/bundle.sh --universal

APP=build/Visor.app
OUT="build/Visor-$VERSION.zip"
rm -f "$OUT"
# ditto keeps the bundle's symlinks, permissions and signature intact.
# Drop resource forks and extended attributes so the zip has no AppleDouble
# ._ files, which Homebrew's extractor does not expect inside an app bundle.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$OUT"

# Sparkle appcast: signs the zip with the EdDSA key in the login Keychain
# (Sparkle's generate_keys) and adds this version to appcast.xml, keeping
# older ones. Installed apps read it from main, so push it after the release.
STAGE=build/appcast
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp "$OUT" "$STAGE/"
[[ -f appcast.xml ]] && cp appcast.xml "$STAGE/appcast.xml"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/tailamphat/visor/releases/download/v$VERSION/" \
  --link https://tailamphat.github.io/visor/ "$STAGE"
cp "$STAGE/appcast.xml" appcast.xml

echo
echo "Version:  $VERSION ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"
echo "Artifact: $OUT"
echo "SHA256:   $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
