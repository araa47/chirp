#!/bin/sh
# Runs the unit tests. Under the Command Line Tools SwiftPM does not find the Swift Testing macro
# plugin by itself, so point the compiler at it; with a full Xcode toolchain plain `swift test` works.
set -eu
cd "$(dirname "$0")/.."
# The app must build with the Command Line Tools, which ship no SwiftUI macro plugins: keep view state in
# @Observable models instead of these property wrappers.
if grep -rnE '^[[:space:]]*@(State|FocusState|Entry|Previewable)\b' Sources; then
    echo "error: SwiftUI macro property wrappers break the Command Line Tools build" >&2
    exit 1
fi
DEV=$(xcode-select -p)
PLUGINS="$DEV/usr/lib/swift/host/plugins/testing"
run() {
    # Keep the no-argument full gate (including the isolated soak) usable outside ~/Documents and under Rosetta.
    [ -z "${CHIRP_MAC_SCRATCH:-}" ] || set -- --scratch-path "$CHIRP_MAC_SCRATCH" "$@"
    [ -z "${CHIRP_MAC_ARCH:-}" ] || set -- --arch "$CHIRP_MAC_ARCH" "$@"
    [ "${CHIRP_MAC_SERIAL:-0}" != 1 ] || set -- --no-parallel "$@"
    if [ "$DEV" = "/Library/Developer/CommandLineTools" ] && [ -d "$PLUGINS" ]; then
        swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
    else
        swift test "$@"
    fi
}
# With no arguments the snapshot renderer and the 2-hour Live Notes soak each run on their own after the rest. The
# renderer holds the main actor for minutes, which other suites' time limits and real-time deadlines must not include
# (#315); the soak's 2-minute limit is for the soak alone.
if [ $# -eq 0 ]; then
    run --skip 'NotesSoakTests|ChirpCoreTests\.SnapshotTests/'
    ./scripts/test.sh --skip-build --filter 'ChirpCoreTests\.SnapshotTests/'
    exec ./scripts/test.sh --skip-build --filter NotesSoakTests
fi
run "$@"
