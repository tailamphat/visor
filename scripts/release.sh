#!/bin/bash
# Builds the universal Visor.app zip for a GitHub release, and prints its sha256.
#
#   scripts/release.sh             # version from the nearest git tag (v0.1.0)
#   scripts/release.sh 0.2.0       # explicit version
#
# The zip is build/Visor-<version>.zip. Upload it to the matching GitHub
# release, then put the version and sha256 in the Homebrew cask.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-${VISOR_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.1.0)}}"
VERSION="${VERSION#v}"

VISOR_VERSION="$VERSION" ./scripts/bundle.sh --universal

APP=build/Visor.app
OUT="build/Visor-$VERSION.zip"
rm -f "$OUT"
# ditto keeps the bundle's symlinks, permissions and signature intact.
# Drop resource forks and extended attributes so the zip has no AppleDouble
# ._ files, which Homebrew's extractor does not expect inside an app bundle.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$OUT"

echo
echo "Version:  $VERSION ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"
echo "Artifact: $OUT"
echo "SHA256:   $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
