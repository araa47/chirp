# Recording crash: sliced PCM Data indices

The recording crash evidence reported three native ARM64 (`translated=false`)
`EXC_BREAKPOINT` / `SIGTRAP` failures on `RealtimeMessenger.mServiceQueue`, with
`Foundation.Data.subdata(in:) → RollingDictationSession.sendAudio →
CaptureSink.handle → AudioCapture.installTap` in the stack.

`PCMConverter` emits `pending.prefix(1600)`, then removes those bytes from
`pending`. A later prefix can have `startIndex == 1600`, `endIndex == 3200`
and `count == 1600`. `Data` slices retain collection indices. The old rolling
consumer passed `0..<1600` to `subdata(in:)`, outside that slice's valid indices.
The fix must translate byte offsets relative to `data.startIndex`; discarding
or padding captured bytes would hide the error and change the audio.

Regression coverage exercises nonzero starts (including an odd storage offset),
empty and single-byte slices, complete PCM16 partial tails, repeated real
16/48 kHz stereo converter callbacks and flush, and an oversized sliced input
crossing two 90-second boundaries. Transport assertions compare every byte and
check the final short frame. Converter output is also compared with independent
unframed conversion plus resampler drain. Existing ten-minute ceiling tests
remain part of the focused gate.

Nearby consumers were audited: capture forwards frames, `Level` reads raw byte
buffers, `StreamSession` queues complete `Data` values, Notes rings retain frames,
and the call mixer uses `prefix`/raw buffers. These do not assume a zero-based
collection index. `NotesRetranscriber.run` has a separate zero-based slicing
assumption; its production decoder builds fresh `Data` with index zero. A custom
injected decoder returning a slice is a follow-up risk, outside this fix's files.

The new sliced-frame test was first run against unchanged production code in an
isolated SwiftPM test process (core dumps disabled). It compiled successfully,
then `swiftpm-testing-helper` exited with signal 5 (`SIGTRAP`) on the first
`prefix: 1` case. The same test passes with the index-relative fix.

The focused `mac/scripts/test.sh --filter
"AudioTests|AudioCaptureTests|RollingDictationTests|CallAudioTests"` gate passed:
59 tests in 9 suites, including all new regression cases. Runs used native ARM64,
Swift 6.4, a private scratch directory and serial test execution. Full Mac gate
and shared iOS portable/build/unit validation results are reported in the PR.
iOS links ChirpCore, although its app has its own rolling session orchestration.
Simulator injection cannot prove real microphone capture. A rebuilt application
recording check on the original crash host remains a coordinator/operator gate.

The separate repeated legacy Keychain refresh prompts are unproven and are not
explained by this bounds failure. This investigation changes no installed app,
permissions or Keychain state.

Coordinator verification on unchanged `da214ff4`: the exact full
`mac/scripts/test.sh` rerun exited 0, with 1,244 tests in 189 suites and the
separate two-hour-session soak passing. The earlier full command exited 1 only
on the soak hearing-parts timing budget; its unchanged isolated retry also
passed. No source or timing budgets changed between these runs. iOS source
checks, 108 shared tests, 112 keyboard-policy tests, and the owned simulator
build plus 100 app unit tests passed on the same source head.
