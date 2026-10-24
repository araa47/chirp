#!/bin/bash
# Own one read-only AVD. Never reuse an adb serial or signal an unrelated QEMU.
set -euo pipefail
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
    echo 'Usage: android/scripts/e2e-all.sh [--only dictation cleanup notes history stop device]'
    echo 'Runs one owned read-only chirp-fold AVD, queued behind the host-wide emulator lease.'
    exit 0
fi
source "$HOME/.local/share/chirp-android/env.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
export CHIRP_E2E_OUTPUT=${CHIRP_E2E_OUTPUT:-$(mktemp -d /tmp/chirp-android-e2e.XXXXXX)}
mkdir -p "$CHIRP_E2E_OUTPUT"
chmod 700 "$CHIRP_E2E_OUTPUT"
echo "Evidence: $CHIRP_E2E_OUTPUT"
# All worktrees share this lease. Queue; never parallelise emulator runs.
if ! python3 android/scripts/emulator-lock.py acquire --pid "$$" --worktree "$ROOT" \
    --timeout "${CHIRP_E2E_LOCK_TIMEOUT:-1800}"; then
    echo '| Flow | Result |'
    echo '| --- | --- |'
    echo '| Emulator slot | FAIL (queue timeout or unverifiable owner) |'
    echo '{"infrastructure": "FAIL: emulator slot unavailable; no flows ran"}' > "$CHIRP_E2E_OUTPUT/results.json"
    exit 1
fi
PORT=
EMULATOR_PID=
cleanup() {
    trap - EXIT INT TERM
    if [ -n "$EMULATOR_PID" ]; then
        kill "$EMULATOR_PID" 2>/dev/null || true
        wait "$EMULATOR_PID" 2>/dev/null || true
    fi
    if [ -n "$PORT" ]; then rmdir "/tmp/chirp-e2e-port-$PORT" 2>/dev/null || true; fi
    python3 "$ROOT/android/scripts/emulator-lock.py" release --pid "$$"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Bind both ports: QEMU orphans may be absent from adb's device list.
PORT=$(python3 - <<'PY'
import os, socket
for port in range(5582, 5682, 2):
    if port == 5600: continue  # Reserved for the separate release/UI acceptance runner.
    lock = '/tmp/chirp-e2e-port-%d' % port
    try: os.mkdir(lock, 0o700)
    except FileExistsError: continue
    sockets = []
    try:
        for number in (port, port + 1):
            s = socket.socket(); sockets.append(s); s.bind(('127.0.0.1', number))
        print(port); break
    except OSError: os.rmdir(lock)
    finally:
        for s in sockets: s.close()
else: raise SystemExit('No free emulator port pair')
PY
)
export ANDROID_SERIAL="emulator-$PORT"
(cd android && ./scripts/make-keystore.sh && ./gradlew --console=plain assembleDebug) >"$CHIRP_E2E_OUTPUT/build.log" 2>&1
(cd server && uv sync --locked) >"$CHIRP_E2E_OUTPUT/server-setup.log" 2>&1
"$ANDROID_HOME/emulator/emulator" -avd chirp-fold -read-only -port "$PORT" \
    -no-snapshot -no-boot-anim -no-window -no-audio -gpu swiftshader -feature -Vulkan \
    -cores "${CHIRP_EMULATOR_CORES:-2}" -memory "${CHIRP_EMULATOR_MEMORY:-2048}" >"$CHIRP_E2E_OUTPUT/emulator.log" 2>&1 &
EMULATOR_PID=$!
export CHIRP_E2E_EMULATOR_PID=$EMULATOR_PID
python3 android/scripts/e2e-all.py "$@"
