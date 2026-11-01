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
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Visor"

APP=build/Visor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Visor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Icons come from scripts/make-icon.swift.
cp Resources/AppIcon.icns Resources/MenuIcon.png "$APP/Contents/Resources/"
# Sign with a stable local identity when there is one, so macOS keeps the
# Accessibility and Automation permissions across rebuilds (an ad-hoc
# signature is tied to the exact binary and changes every build).
# Create it once with scripts/make-signing-identity.sh.
IDENTITY="Notchboard Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "note: no \"$IDENTITY\" certificate; signing ad hoc (permissions reset on every build)" >&2
  codesign --force --sign - "$APP"
fi

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Visor"))"
if [[ $OPEN == 1 ]]; then
  pkill -x Visor 2>/dev/null || true
  open "$APP"
fi
