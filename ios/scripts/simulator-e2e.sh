#!/bin/sh
# The full UI scheme, including the live end-to-end suite, on one simulator against a throwaway local chirp-server: temporary HOME (its own
# token), port 7899 (CHIRP_E2E_PORT), cached model, no LaunchAgent, a deterministic local clean-up stand-in and a
# synthetic `say` sentence. Debug simulator builds pair with http://127.0.0.1:PORT; nothing else changes.
# Usage: [CHIRP_E2E_APPEARANCE=dark] ios/scripts/simulator-e2e.sh SIMULATOR-UUID [extra xcodebuild args, e.g. -only-testing:…]
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
device="${1:-}"; [ -n "$device" ] || { echo 'Usage: simulator-e2e.sh SIMULATOR-UUID [xcodebuild args]' >&2; exit 2; }
shift
PORT=${CHIRP_E2E_PORT:-7899}; CLEANUP_PORT=$((PORT - 1))
MODEL_DIR=${CHIRP_MODEL_DIR:-$HOME/.koi/voice-models/parakeet-mlx}
# A separately installed Intel Python can be newer than the native interpreter. MLX needs native arm64 wheels.
if [ -n "${CHIRP_E2E_PYTHON:-}" ]; then
  UV_PYTHON=$CHIRP_E2E_PYTHON; export UV_PYTHON
elif [ "$(uname -m)" = arm64 ]; then
  UV_PYTHON=cpython-3.13-macos-aarch64-none; export UV_PYTHON
fi
for p in "$PORT" "$CLEANUP_PORT"; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then echo "port $p is in use; set CHIRP_E2E_PORT" >&2; exit 1; fi
done
WORK=$(mktemp -d /tmp/chirp-ios-e2e.XXXX)
echo "work dir (synthetic audio, throwaway token, server log): $WORK"
SERVER=""; CLEANUP=""
stop() {
  if [ -n "$SERVER" ]; then pkill -P "$SERVER" 2>/dev/null || true; kill "$SERVER" 2>/dev/null || true; fi
  if [ -n "$CLEANUP" ]; then kill "$CLEANUP" 2>/dev/null || true; fi
}
# Register before the first background process: uv sync/startup failures must not leak the stand-in's port.
trap stop EXIT INT TERM
say -o "$WORK/s.aiff" "So, um, schedule the team review for Tuesday morning and invite the whole design group."
ffmpeg -loglevel error -i "$WORK/s.aiff" -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/s.wav"
# First words (#376 follow-up): the opening sentence from the start, and after 2.5 s of silence (speech after "Listening…").
say -o "$WORK/first.aiff" "Chirp test one. The quick brown fox jumps over the lazy dog."
ffmpeg -loglevel error -i "$WORK/first.aiff" -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/first.wav"
ffmpeg -loglevel error -f lavfi -i "anullsrc=r=16000:cl=mono" -t 2.5 -c:a pcm_s16le "$WORK/lead.wav"
printf "file '%s'\nfile '%s'\n" lead.wav first.wav > "$WORK/first-late.txt"
ffmpeg -loglevel error -f concat -safe 0 -i "$WORK/first-late.txt" -c:a pcm_s16le "$WORK/first-late.wav"
# Long dictation: about 50 s of speech, a 1.5 s pause (the segment cut), then a closing sentence.
LONG="Here is the plan for next quarter. We will start by reviewing the customer feedback from the spring survey and grouping it into themes. Then the design team will sketch three options for the onboarding flow, and we will test each option with five people from our pilot group. After that, engineering will estimate the work for the option that tests best, and we will agree on a schedule that leaves room for bug fixes. Marketing will prepare a short announcement, and support will update the help center articles so that nobody is surprised on launch day. We will also keep a running list of risks and review it every Monday morning. If a risk turns into a real problem, the owner writes a short note with what happened and what we will change, and we share it in the weekly meeting. By the end of the quarter we want the new onboarding flow in the hands of every new customer. That gives us a clear goal and a simple way to measure progress."
say -o "$WORK/long.aiff" "$LONG [[slnc 1500]] Finally, send the summary to everyone before Friday afternoon."
ffmpeg -loglevel error -i "$WORK/long.aiff" -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/long.wav"
# Two voices, Samantha then Daniel, looped like a meeting (the speaker-label test): about 40 s with pauses between turns.
{
  say -v Samantha -o "$WORK/a.aiff" "We should ship the new onboarding flow on Friday, and I will write the announcement tonight."
  say -v Daniel -o "$WORK/b.aiff" "That sounds good to me. I will check the release notes with the support team tomorrow morning."
  for f in a b; do ffmpeg -loglevel error -i "$WORK/$f.aiff" -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/$f.wav"; done
  ffmpeg -loglevel error -f lavfi -i "anullsrc=r=16000:cl=mono" -t 1.6 -c:a pcm_s16le "$WORK/gap.wav"
  printf "file '%s'\n" a.wav gap.wav b.wav gap.wav a.wav gap.wav b.wav gap.wav a.wav gap.wav b.wav > "$WORK/two.txt"
  ffmpeg -loglevel error -f concat -safe 0 -i "$WORK/two.txt" -c:a pcm_s16le "$WORK/two.wav"
  # Six turns per voice leave headroom above the 20 seconds of voiced speech needed for enrolment.
  : > "$WORK/voices.txt"
  for turn in 1 2 3 4 5 6; do
    printf "file '%s'\n" a.wav gap.wav b.wav gap.wav >> "$WORK/voices.txt"
  done
  ffmpeg -loglevel error -f concat -safe 0 -i "$WORK/voices.txt" -c:a pcm_s16le "$WORK/voices.wav"
}
mkdir -p "$WORK/.config/chirp"
printf '[correction]\nmode = "endpoint"\nbase_url = "http://127.0.0.1:%s/v1"\nmodel = "stand-in"\n' "$CLEANUP_PORT" > "$WORK/.config/chirp/server.toml"
python3 -I "$ROOT/ios/scripts/fake-cleanup.py" "$CLEANUP_PORT" & CLEANUP=$!
cd "$ROOT/server"
uv sync --locked -q
# The speaker model is downloaded by the server itself, when the app sees it is missing (a real Hugging Face download into this
# throwaway HOME). HF_HOME keeps the hub's cache between runs so only the first one fetches it.
HOME="$WORK" UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}" HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}" \
  uv run chirp-server --port "$PORT" --model-dir "$MODEL_DIR" > "$WORK/server.log" 2>&1 & SERVER=$!
for _ in $(seq 1 120); do curl -s -m 1 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1 && break; sleep 1; done
[ -s "$WORK/.config/chirp/token" ] || { echo "server did not start; see $WORK/server.log" >&2; exit 1; }
# A per-device pairing, as the README recommends; the app shows its name.
LINK=$(HOME="$WORK" uv run chirp-server pair --name "Chirp simulator" --url "http://127.0.0.1:$PORT" 2>/dev/null | head -1)
cd "$ROOT/ios"
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl ui "$device" appearance "${CHIRP_E2E_APPEARANCE:-light}" # light or dark, for screenshots
xcrun simctl privacy "$device" grant microphone "${CHIRP_BUNDLE_ID:-dev.chirp.ios}" 2>/dev/null || true
status=0
VOICES_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WORK/voices.wav")
TEST_RUNNER_CHIRP_LIVE_VOICES_AUDIO="$WORK/voices.wav" TEST_RUNNER_CHIRP_LIVE_VOICES_DURATION="$VOICES_DURATION" \
TEST_RUNNER_CHIRP_LIVE_FIRST_AUDIO="$WORK/first.wav" TEST_RUNNER_CHIRP_LIVE_FIRST_LATE_AUDIO="$WORK/first-late.wav" \
TEST_RUNNER_CHIRP_LIVE_LINK="$LINK" TEST_RUNNER_CHIRP_LIVE_AUDIO="$WORK/s.wav" TEST_RUNNER_CHIRP_LIVE_LONG_AUDIO="$WORK/long.wav" \
  TEST_RUNNER_CHIRP_LIVE_SPEAKERS_AUDIO="$WORK/two.wav" \
  ./scripts/simulator.sh ui "$device" "$@" || status=$?
# Re-transcribe (#287): device activity records the runs as notes_retranscribe with audio_ms and no text.
activity=$(find "$WORK" -name device-activity.json 2>/dev/null | head -1)
if [ -n "$activity" ]; then
  echo "== device activity: notes_retranscribe events"; grep -o '"notes_retranscribe"' "$activity" | wc -l
  echo "== privacy: transcript words in device activity (expect 0)"
  ahits=$(grep -c -i -E "tuesday|onboarding|release notes|wrong text" "$activity" || true)
  echo "$ahits"; [ "$ahits" = 0 ] || status=1
fi
echo "== privacy: transcript words in server log (expect 0)"
hits=$(grep -c -i -E "tuesday|schedule|design group|onboarding|friday afternoon|release notes|announcement|support team|wrong text" "$WORK/server.log" || true)
echo "$hits"; [ "$hits" = 0 ] || status=1
[ $status = 0 ] && echo "iOS E2E: PASS" || { echo "iOS E2E: FAIL"; exit 1; }
