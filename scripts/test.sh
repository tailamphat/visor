#!/bin/bash
# Runs the unit tests: scripts/test.sh [swift test options, e.g. --filter Bar]
#
# With the Command Line Tools, incremental test builds can lose track of
# Swift Testing's macro plugin ("plugin for module 'TestingMacros' not
# found"), so its location is passed explicitly. Tests also build in their
# own folder, apart from scripts/bundle.sh's release build.
set -euo pipefail
cd "$(dirname "$0")/.."
TOOLCHAIN="$(dirname "$(dirname "$(xcrun --find swift)")")"
PLUGINS="$TOOLCHAIN/lib/swift/host/plugins/testing"
SERVER="$TOOLCHAIN/bin/swift-plugin-server"
FLAGS=()
if [[ -d "$PLUGINS" && -x "$SERVER" ]]; then
  FLAGS=(-Xswiftc -external-plugin-path -Xswiftc "$PLUGINS#$SERVER")
fi
swift test --scratch-path .build/tests ${FLAGS[@]+"${FLAGS[@]}"} "$@"
