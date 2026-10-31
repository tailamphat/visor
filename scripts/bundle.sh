#!/bin/bash
# Builds build/Notchboard.app.
#
#   scripts/bundle.sh             # this Mac's architecture, ad-hoc signed
#   scripts/bundle.sh --open      # ...and launch it
#   scripts/bundle.sh --universal # Apple Silicon + Intel
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

swift build -c release --product Notchboard ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Notchboard"

APP=build/Notchboard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notchboard"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Notchboard"))"
if [[ $OPEN == 1 ]]; then
  pkill -x Notchboard 2>/dev/null || true
  open "$APP"
fi
