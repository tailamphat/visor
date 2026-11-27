#!/bin/bash
# Runs the unit tests: scripts/test.sh [swift test options, e.g. --filter Bar]
#
# With the Command Line Tools, incremental test builds can lose track of
# Swift Testing's macro plugin ("plugin for module 'TestingMacros' not
# found"), so its location is passed explicitly. Tests also build in their
# own folder, apart from scripts/bundle.sh's release build. Command Line
# Tools 26.x also keep Testing.framework and lib_TestingInterop.dylib outside
# the default search paths, so they are added when the active developer dir
# has them (Xcode does not, and needs nothing).
set -euo pipefail
cd "$(dirname "$0")/.."
TOOLCHAIN="$(dirname "$(dirname "$(xcrun --find swift)")")"
PLUGINS="$TOOLCHAIN/lib/swift/host/plugins/testing"
SERVER="$TOOLCHAIN/bin/swift-plugin-server"
FLAGS=()
if [[ -d "$PLUGINS" && -x "$SERVER" ]]; then
  FLAGS=(-Xswiftc -external-plugin-path -Xswiftc "$PLUGINS#$SERVER")
fi
DEV="$(xcode-select -p)/Library/Developer"
if [[ -d "$DEV/Frameworks/Testing.framework" && -f "$DEV/usr/lib/lib_TestingInterop.dylib" ]]; then
  FLAGS+=(-Xswiftc -F -Xswiftc "$DEV/Frameworks" -Xlinker -F -Xlinker "$DEV/Frameworks"
    -Xlinker -rpath -Xlinker "$DEV/Frameworks" -Xlinker -rpath -Xlinker "$DEV/usr/lib")
fi
swift test --scratch-path .build/tests ${FLAGS[@]+"${FLAGS[@]}"} "$@"
