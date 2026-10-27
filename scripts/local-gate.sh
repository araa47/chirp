#!/bin/bash
# Runs the local test gates for the platforms a branch touches, then records each result on GitHub for the EXACT
# commit that was tested: one commit status per gate (`local/mac-full`, `local/ios`, `local/android`, `local/server`),
# an aggregate `local/gate`, and one PR comment with counts and the host. Hosted mac.yml and ios.yml only run by hand
# (macOS runner minutes cost 10x Linux), so this is the check that gates those platforms.
#
#   scripts/local-gate.sh [--base REF] [--pr N] [--dry-run] [--no-post] [--prefix local/] [GATE...]
#
# GATE is one of mac, ios, android, server. With none, the gates are derived from the diff against the merge base
# with --base (default origin/main), the same path rules the hosted workflows used. Run from a clean tree whose HEAD
# is pushed: a status can only describe a commit, so the tree must be that commit and GitHub must know it.
#
# Heavy gates take the host's leases (/tmp/chirp-mac-full.lock, /tmp/chirp-ios-sim.lock, /tmp/chirp-gradle-full.lock)
# and wait for them. Build products go to /tmp/chirp-local-gate (TCC). Test hook: CHIRP_GATE_CMD_<GATE> (for example
# CHIRP_GATE_CMD_SERVER='echo 12 passed') replaces a gate's command, to try the reporting without the real suite.
set -euo pipefail

BASE=origin/main PR= DRY=0 POST=1 PREFIX=local/ GATES=
while [ $# -gt 0 ]; do
    case $1 in
    --base) BASE=$2; shift ;;
    --pr) PR=$2; shift ;;
    --dry-run) DRY=1 ;;
    --no-post) POST=0 ;;
    --prefix) PREFIX=$2; shift ;;
    -h | --help) sed -n '2,/^set -e/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    mac | ios | android | server) GATES="$GATES $1" ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done

cd "$(git rev-parse --show-toplevel)"
ROOT=$PWD
SHA=$(git rev-parse HEAD)
OUT=/tmp/chirp-local-gate/${SHA:0:8}
EXPLICIT=0
[ -z "$GATES" ] || EXPLICIT=1

if [ -z "$GATES" ]; then
    files=$(git diff --name-only "$(git merge-base "$BASE" HEAD)" HEAD)
    has() { printf '%s\n' "$files" | grep -Eq "$1"; }
    has '^server/' && GATES="$GATES server"
    # The READMEs and mac/docs are prose nothing reads. NOTICES.md is read by a test, so it stays in.
    has '^mac/' && printf '%s\n' "$files" | grep '^mac/' | grep -Ev '^mac/(README\.md|docs/)' | grep -q . && GATES="$GATES mac"
    if has '^ios/|^mac/(Package\.swift|Package\.resolved|Sources/ChirpCore/|Sources/ChirpSpeakers/)'; then
        printf '%s\n' "$files" | grep -Ev '^ios/(README\.md|Shared/README\.md)$' |
            grep -Eq '^ios/|^mac/(Package\.swift|Package\.resolved|Sources/ChirpCore/|Sources/ChirpSpeakers/)' && GATES="$GATES ios"
    fi
    has '^android/' && GATES="$GATES android"
fi
GATES=${GATES# }

echo "commit: $SHA"
echo "gates:  ${GATES:-none}"
[ -n "$GATES" ] || { echo "No gate applies to this diff."; exit 0; }
[ "$DRY" = 0 ] || exit 0

if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
    echo "error: the working tree is not clean; the result must describe commit $SHA exactly. Commit or remove the changes." >&2
    exit 2
fi

REPO= BRANCH=$(git branch --show-current)
if [ "$POST" = 1 ]; then
    REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
    if ! gh api "repos/$REPO/commits/$SHA" --silent 2>/dev/null; then
        echo "error: GitHub does not know $SHA; push the branch first (or use --no-post)." >&2
        exit 2
    fi
    [ -n "$PR" ] || PR=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)
fi
mkdir -p "$OUT"

post_status() { # state context description
    [ "$POST" = 1 ] || return 0
    gh api "repos/$REPO/statuses/$SHA" -f state="$1" -f context="$2" -f description="$(printf '%s' "$3" | cut -c1-140)" --silent ||
        echo "warning: could not post status $2" >&2
}

HOST="$(hostname -s), $(uname -m), macOS $(sw_vers -productVersion 2>/dev/null || uname -r)"
XCODE=$(xcodebuild -version 2>/dev/null | head -1 || true)
[ -z "$XCODE" ] || HOST="$HOST, $XCODE"

gate_context() { case $1 in mac) echo "${PREFIX}mac-full" ;; *) echo "${PREFIX}$1" ;; esac; }
gate_lock() { case $1 in mac) echo chirp-mac-full ;; ios) echo chirp-ios-sim ;; android) echo chirp-gradle-full ;; *) echo ;; esac; }
gate_command() {
    case $1 in
    mac) echo "cd mac && CHIRP_MAC_SERIAL=1 CHIRP_MAC_SCRATCH=/tmp/chirp-local-gate/mac-build ./scripts/test.sh" ;;
    ios) echo "cd ios && CHIRP_DERIVED_DATA=/tmp/chirp-local-gate/ios-derived ./scripts/ci-test.sh" ;;
    android) echo ". \"\${CHIRP_ANDROID_ENV:-\$HOME/.local/share/chirp-android/env.sh}\" && cd android && ./gradlew --console=plain lint testDebugUnitTest assembleDebug --rerun-tasks" ;;
    server) echo "cd server && uv sync --locked && uv run ruff check . && uv run ruff format --check . && uv run pytest -q" ;;
    esac
}

# Test counts are read from the log (and, for Android, the JUnit XML), so they are as good as the tools' own summaries.
gate_counts() { # gate log
    case $1 in
    mac | ios)
        python3 - "$2" <<'PY'
import re, sys
text = open(sys.argv[1], errors="replace").read()
swift_testing = sum(int(n) for n in re.findall(r"Test run with (\d+) tests?", text))
xctest = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", text)
parts = []
if swift_testing:
    parts.append(f"{swift_testing} Swift Testing")
if xctest:
    parts.append(f"{xctest[-1][0]} XCTest")  # the last Executed line is the grand total
print(" + ".join(parts) or "no count found in the log")
PY
        ;;
    android)
        python3 - "$ROOT/android" <<'PY'
import glob, sys, xml.etree.ElementTree as ET
t = f = s = 0
for p in glob.glob(sys.argv[1] + "/**/build/test-results/**/*.xml", recursive=True):
    r = ET.parse(p).getroot()
    t += int(r.get("tests", 0)); f += int(r.get("failures", 0)) + int(r.get("errors", 0)); s += int(r.get("skipped", 0))
print(f"{t} unit tests, {f} failed, {s} skipped" if t else "no JUnit results found")
PY
        ;;
    server) grep -E '[0-9]+ passed' "$2" | tail -1 | sed 's/=//g;s/^ *//' || true ;;
    esac
}

LEASE=
release_lease() { [ -z "$LEASE" ] || rmdir "/tmp/$LEASE.lock" 2>/dev/null || true; LEASE=; }
trap release_lease EXIT
acquire_lease() { # name
    local waited=0
    until mkdir "/tmp/$1.lock" 2>/dev/null; do
        [ $waited -lt 7200 ] || return 1
        [ $((waited % 300)) -ne 0 ] || echo "waiting for the $1 lease (held by another job)..."
        sleep 30
        waited=$((waited + 30))
    done
    LEASE=$1
}

RESULTS=$OUT/results.tsv
: >"$RESULTS"
[ "$EXPLICIT" = 1 ] || post_status pending "${PREFIX}gate" "Running local gates: $GATES on $(hostname -s)"
overall=success
for g in $GATES; do
    ctx=$(gate_context "$g")
    log=$OUT/$g.log
    override=CHIRP_GATE_CMD_$(printf '%s' "$g" | tr '[:lower:]' '[:upper:]')
    cmd=${!override:-$(gate_command "$g")}
    post_status pending "$ctx" "Running on $(hostname -s)"
    echo "== $g: $cmd"
    start=$(date +%s)
    state=success
    lock=$(gate_lock "$g")
    if [ -n "$lock" ] && ! acquire_lease "$lock"; then
        echo "could not get the $lock lease within 2 hours" >"$log"
        state=error
    else
        bash -c "$cmd" >"$log" 2>&1 || state=failure
        release_lease
    fi
    secs=$(($(date +%s) - start))
    counts=$(gate_counts "$g" "$log")
    [ "$state" = success ] || overall=failure
    tail -3 "$log" | sed 's/^/   /'
    echo "== $g: $state, $counts, $((secs / 60)) min"
    printf '%s\t%s\t%s\t%s\t%s\n' "$g" "$state" "$counts" "$((secs / 60))" "$ctx" >>"$RESULTS"
    final=$SHA
    if [ "$(git rev-parse HEAD)" != "$final" ] || [ -n "$(git status --porcelain --untracked-files=no)" ]; then
        # Never vouch for a commit whose tree moved under the run.
        echo "error: the tree changed during the run; not recording $g for $SHA" >&2
        state=error counts="the tree changed during the run"
        overall=failure
    fi
    post_status "$state" "$ctx" "$counts; $(hostname -s); $((secs / 60)) min"
done
[ "$EXPLICIT" = 1 ] || post_status "$overall" "${PREFIX}gate" "$([ "$overall" = success ] && echo "All local gates passed" || echo "A local gate failed"): $GATES"

if [ "$POST" = 1 ] && [ -n "$PR" ]; then
    body=$OUT/comment.md
    {
        echo "### Local gate for \`${SHA:0:10}\`: $overall"
        echo
        echo "| Gate | Result | Tests | Minutes |"
        echo "|---|---|---|---|"
        while IFS=$'\t' read -r g state counts mins ctx; do
            echo "| \`$ctx\` | $state | $counts | $mins |"
        done <"$RESULTS"
        echo
        echo "Host: $HOST. Base: \`$BASE\`. Posted as commit statuses on \`$SHA\` by \`scripts/local-gate.sh\`; a new push needs a new run."
        while IFS=$'\t' read -r g state counts mins ctx; do
            [ "$state" = success ] && continue
            echo
            echo "<details><summary>$g: last lines of the log</summary>"
            echo
            echo '```'
            tail -25 "$OUT/$g.log" | sed "s#$HOME#~#g"
            echo '```'
            echo "</details>"
        done <"$RESULTS"
    } >"$body"
    gh pr comment "$PR" --body-file "$body" >/dev/null && echo "commented on PR #$PR"
elif [ "$POST" = 1 ]; then
    echo "no open PR for $BRANCH; statuses posted, no comment."
fi
echo "logs: $OUT"
[ "$overall" = success ]
