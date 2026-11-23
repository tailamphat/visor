#!/bin/bash
# Checks what scripts/release.sh built: scripts/release-verify.sh <version>
#
# Run after release.sh, before publishing. Read-only. Checks the zip, the
# app's signature and Info.plist, and the new appcast.xml entry. Prints one
# pass/FAIL line per check and exits 1 if any fails.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
VERSION="${VERSION#v}"
if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/release-verify.sh <version>" >&2
  exit 2
fi

ZIP="build/Visor-$VERSION.zip"
APP=build/Visor.app
PLIST="$APP/Contents/Info.plist"
FAILED=0
pass() { echo "pass  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }

if [[ ! -f "$ZIP" ]]; then
  fail "no $ZIP (run scripts/release.sh $VERSION)"
  echo "verify: FAIL"
  exit 1
fi
LENGTH="$(stat -f %z "$ZIP")"
pass "$ZIP ($LENGTH bytes)"

# The app inside the zip, not just build/Visor.app, is what users get.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP"
ZAPP="$TMP/Visor.app"
if codesign --verify --deep --strict "$ZAPP" 2>"$TMP/codesign.log"; then
  pass "codesign --verify --deep --strict"
else
  fail "codesign: $(head -1 "$TMP/codesign.log")"
fi
PLIST="$ZAPP/Contents/Info.plist"

[[ "$(plist VisorRelease)" == YES ]] && pass "VisorRelease = YES" || fail "VisorRelease is not YES (not built by release.sh?)"
SHORT="$(plist CFBundleShortVersionString)"
[[ "$SHORT" == "$VERSION" ]] && pass "CFBundleShortVersionString = $VERSION" || fail "CFBundleShortVersionString is $SHORT, want $VERSION"
BUILD="$(plist CFBundleVersion)"
COUNT="$(git rev-list --count HEAD)"
[[ "$BUILD" == "$COUNT" ]] && pass "CFBundleVersion = $COUNT (commit count)" || fail "CFBundleVersion is $BUILD, commit count is $COUNT"

# appcast.xml: an item for this version with a signature and the zip's length.
ITEM="$(awk -v v="$VERSION" '
  /<item>/ { buf = ""; on = 1 }
  on { buf = buf $0 "\n" }
  /<\/item>/ { if (buf ~ "<sparkle:shortVersionString>" v "</sparkle:shortVersionString>") print buf; on = 0 }
' appcast.xml)"
if [[ -z "$ITEM" ]]; then
  fail "appcast.xml has no item for $VERSION"
else
  pass "appcast.xml has an item for $VERSION"
  [[ "$ITEM" == *'sparkle:edSignature="'?* ]] && pass "appcast item has an EdDSA signature" || fail "appcast item has no EdDSA signature"
  [[ "$ITEM" == *"length=\"$LENGTH\""* ]] && pass "appcast length matches the zip" || fail "appcast length does not match the zip ($LENGTH)"
  [[ "$ITEM" == *"<sparkle:version>$COUNT</sparkle:version>"* ]] && pass "appcast build = $COUNT" || fail "appcast build is not $COUNT"
  [[ "$ITEM" == *"releases/download/v$VERSION/Visor-$VERSION.zip"* ]] && pass "appcast URL points at v$VERSION" || fail "appcast URL does not point at v$VERSION"
fi

echo "sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
if [[ $FAILED == 1 ]]; then
  echo "verify: FAIL"
  exit 1
fi
echo "verify: pass"
