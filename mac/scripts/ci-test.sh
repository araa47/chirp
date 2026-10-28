#!/bin/sh
# CI entry point for the unit tests on GitHub's hosted macOS runners (Xcode 26.x, Swift 6.2/6.3).
# - The stream/recorder suites below abort the whole test process there ("freed pointer was not the last
#   allocation") when their tests share a process, yet every test passes alone and on Swift 6.4. They run
#   one test per process, as does the Live Notes soak (its 2-minute limit is for the soak alone).
# - GeneratedSoundTests shells out to `swift make-sounds.swift`, which does not run on the runner, and
#   SnapshotTests renders PNGs a few KB over the committed-size cap with the runner's fonts. Both pass on the
#   reference Mac (`scripts/test.sh`).
set -eu
cd "$(dirname "$0")/.."
ISOLATED="NotesBudgetTests NotesLongRecorderTests NotesLayoutTests NotesLongSessionTests NotesOrganizeRecorderTests NotesOverlapRouterTests NotesPauseSessionTests NotesPauseTests NotesRecorderTests NotesReorganizeRecorderTests NotesSoakTests ServerSpeakersRecorderTests SpeakerRecorderTests StreamBoundsTests StreamSessionTests RollingDictationTests DictationStartTests NotesRetranscribeTests NotesRetranscribeSessionTests"
SKIPPED="GeneratedSoundTests SnapshotTests"
re() { echo "$*" | tr ' ' '\n' | paste -sd'|' -; }
# Keep the build quiet, but show compiler errors when it fails.
# CHIRP_MAC_SCRATCH (as in test.sh) builds outside the checkout, for running this locally.
SCRATCH=${CHIRP_MAC_SCRATCH:+--scratch-path $CHIRP_MAC_SCRATCH}
swift build --build-tests $SCRATCH >/tmp/chirp-build 2>&1 || { grep -A12 'error:' /tmp/chirp-build || tail -100 /tmp/chirp-build; exit 1; }
swift test list $SCRATCH 2>/tmp/chirp-list > /tmp/chirp-tests || { cat /tmp/chirp-list; exit 1; }
./scripts/test.sh --skip-build --skip "$(re $ISOLATED $SKIPPED)"
fail=0
for suite in $ISOLATED; do
    # `swift test list` prints Module.Suite/test(); escape the regex metacharacters for --filter. Swift 6.4 matches
    # the filter against that ID followed by /File.swift:line:column, so end it with (/|$) rather than $.
    for t in $(grep "\.$suite/" /tmp/chirp-tests | sed -E 's/[().]/\\&/g'); do
        ./scripts/test.sh --skip-build --filter "^$t(/|\$)" >/tmp/chirp-one 2>&1 \
            && grep -q "passed after" /tmp/chirp-one || { echo "FAILED: $t"; tail -20 /tmp/chirp-one; fail=1; }
    done
done
exit $fail
