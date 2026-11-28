#!/bin/bash
# Builds build/Visor.app.
#
#   scripts/bundle.sh             # this Mac's architecture, ad-hoc signed
#   scripts/bundle.sh --open      # ...and launch it
#   scripts/bundle.sh --universal # Apple Silicon + Intel
#
# Signed with the "Notchboard Local Signing" certificate when present
# (see scripts/make-signing-identity.sh), otherwise ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

OPEN=0
ARCHS=()
for arg in "$@"; do
  case "$arg" in
    --open) OPEN=1 ;;
    --universal) ARCHS=(--arch arm64 --arch x86_64) ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

swift build -c release --product Visor ${ARCHS[@]+"${ARCHS[@]}"}
swift build -c release --product visor-bridge ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Visor"

APP=build/Visor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Visor"
# Sparkle (Check for Updates) is a framework the app loads from Contents/Frameworks.
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Visor" 2>/dev/null || true
# Started by browsers for the Visor Media extension, which ships alongside.
cp "$(dirname "$BIN")/visor-bridge" "$APP/Contents/Helpers/visor-bridge"
cp -R Extension "$APP/Contents/Resources/Extension"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The release version comes from the nearest git tag (v0.1.0 -> 0.1.0), or
# VISOR_VERSION when set. The build number is the commit count.
VERSION="${VISOR_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.1.0)}"
VERSION="${VERSION#v}"
BUILD="${VISOR_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
# Local builds show their commit in the menu; release.sh sets VISOR_RELEASE=1 to stamp a release.
/usr/libexec/PlistBuddy -c "Add :VisorCommit string $(git rev-parse --short HEAD 2>/dev/null || echo unknown)" "$APP/Contents/Info.plist"
if [[ "${VISOR_RELEASE:-}" == 1 ]]; then
  /usr/libexec/PlistBuddy -c "Add :VisorRelease string YES" "$APP/Contents/Info.plist"
fi
# Icons come from scripts/make-icon.swift. Local builds get the "Blueprint" dev
# variants under the release names, so Info.plist and the app load them unchanged;
# a missing dev file falls back to the release one.
for icon in AppIcon.icns MenuIcon.png; do
  src="Resources/$icon"
  dev="Resources/${icon%.*}-Dev.${icon##*.}"
  if [[ "${VISOR_RELEASE:-}" != 1 && -f "$dev" ]]; then src="$dev"; fi
  cp "$src" "$APP/Contents/Resources/$icon"
done
# Sign with a stable local identity when there is one, so macOS keeps the
# Accessibility and Automation permissions across rebuilds (an ad-hoc
# signature is tied to the exact binary and changes every build).
# Create it once with scripts/make-signing-identity.sh.
IDENTITY="Notchboard Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  SIGN=(codesign --force --sign "$IDENTITY")
else
  echo "note: no \"$IDENTITY\" certificate; signing ad hoc (permissions reset on every build)" >&2
  SIGN=(codesign --force --sign -)
fi
# Inside out: Sparkle's helpers, then the framework and the bridge, then the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$APP/Contents/Helpers/visor-bridge"
"${SIGN[@]}" "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Visor"))"
if [[ $OPEN == 1 ]]; then
  pkill -x Visor 2>/dev/null || true
  open "$APP"
fi
