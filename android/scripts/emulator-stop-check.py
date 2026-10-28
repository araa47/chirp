#!/usr/bin/env python3
"""Stop-state matrix, invoked by emulator-check.py --stop-check [--tls]. No text captures."""
import json
import re
import shlex
import time
from pathlib import Path
import xml.etree.ElementTree as ET


def check(probe, work, expect_crash=False):
    adb, click, wait_for = (probe[name] for name in ('adb', 'click', 'wait_for'))
    package, ime = probe['PACKAGE'], probe['IME']
    # Preserve crash evidence outside git; no editor contents, credentials or screenshots.
    evidence = Path('/tmp/chirp-stopcrash-baseline' if expect_crash else '/tmp/chirp-stopcrash-fixed')
    evidence.mkdir(exist_ok=True)

    def diagnostics(label):
        crash = adb('logcat', '-b', 'crash', '-d', '-s', 'AndroidRuntime:E').decode(errors='replace')
        prefs = adb('shell', 'run-as', package, 'sh', '-c', shlex.quote(
            'cat shared_prefs/crash_diagnostics.xml 2>/dev/null || true'))
        entries = []
        if prefs.strip():
            for item in ET.fromstring(prefs):
                if item.get('name') == 'entries': entries = json.loads(item.text)
        (evidence / (label + '-logcat.txt')).write_text(crash)
        (evidence / (label + '-diagnostics.json')).write_text(json.dumps(entries, indent=2))
        crashed = bool(entries) or bool(re.search(r'Process: dev\.chirp\.android|>>> dev\.chirp\.android <<<', crash))
        if crashed:
            print('Crash captured:', label, '; exceptions:', [item['exception'] for item in entries], flush=True)
        return crashed

    def idle_mic():
        # A dump taken while windows change can miss the keyboard: look again briefly (#344).
        deadline = time.monotonic() + 10
        while True:
            mic = next((n for n in probe['nodes']() if n.get('content-desc', '').startswith('Microphone: tap to dictate,')
                        and n.get('class') == 'android.widget.Button'), None)
            if mic is not None: return mic
            if time.monotonic() > deadline: raise AssertionError('Chirp\'s idle mic is not on screen')
            time.sleep(.25)

    cases = ('partial', 'hide', 'unbind') if expect_crash else (
        'immediate', 'listening', 'partial', 'polishing', 'double', 'hide', 'focus', 'unbind')
    for case in cases:
        for attempt in (1, 2):
            # Reset the process to create a new TLS health connection for teardown too.
            adb('shell', 'am', 'force-stop', package)
            adb('shell', 'run-as', package, 'sh', '-c', shlex.quote('cat > shared_prefs/debug_capture.xml'),
                data=('<map><boolean name="synthetic" value="true"/><long name="initial_frame_delay_ms" value="' +
                      ('4000' if case == 'immediate' else '0') + '"/></map>').encode())
            probe['fresh_editor']()
            mic = idle_mic()
            before = probe['editor_text']()
            x, y = probe['center'](mic)
            # The first menu item must expose the default without toggling it on.
            click('Dictation options')
            if expect_crash:
                # The pre-fix Android baseline predates the default and menu-label change.
                off = probe['find']('Clean-up off · Correction on Mac')
                if off is not None: probe['tap'](off)
                else: adb('shell', 'input', 'keyevent', '4')
            else:
                switch = wait_for('Clean-up, On your computer')
                assert switch.get('checked') == 'true', 'Clean-up was not on by default'
                adb('shell', 'input', 'keyevent', '4')
            probe["focus_editor"]()
            mic = idle_mic()
            x, y = probe["center"](mic)
            (work / "events.json").write_text("{}")
            try:
                adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/',
                    'dev.chirp.smoke.UiHierarchy', 'stop-case', case, str(x), str(y))
                if case == 'unbind':
                    other = 'com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME'
                    adb('shell', 'ime', 'set', other)
                    adb('shell', 'ime', 'set', ime)
                # Wait for the real model's final or for cancellation to retire the stream.
                if case in ('hide', 'focus', 'unbind'): time.sleep(2)
                else: wait_for('Microphone: tap to dictate', seconds=70)
                deadline = time.monotonic() + 70
                while time.monotonic() < deadline:
                    if json.loads((work / 'events.json').read_text()).get('retired'): break
                    time.sleep(.1)
                else: raise AssertionError('Previous server utterance did not retire')
            except Exception:
                if (work / 'events.json').exists():
                    print('Failed scenario metadata:', json.loads((work / 'events.json').read_text()), flush=True)
                # A health check that timed out on a loaded host marks the computer offline, and the tap then re-checks instead
                # of dictating. That is about reachability, not stopping: say so and run the case once more (#344).
                if attempt == 1 and not diagnostics(case) and probe['find']('Computer offline, double-tap to retry') is not None:
                    print('Environment: the app marked the computer offline during', case, '; running it once more', flush=True)
                    continue
                if not diagnostics(case): raise
            if diagnostics(case):
                if expect_crash:
                    assert 'NetworkOnMainThreadException' in (evidence / (case + '-logcat.txt')).read_text()
                    print('PASS: baseline TLS stop reproduces NetworkOnMainThreadException; logcat and Diagnostics saved outside git.', flush=True)
                    return
                raise AssertionError('Chirp crashed in stop scenario: ' + case)
            state = json.loads((work / 'events.json').read_text())
            print('Stop:', case, '; content-free server state:', state, flush=True)
            assert state['correction_requested'], 'On-Mac clean-up was not on by default'
            assert state['stop'], 'Server never received STOP: ' + case
            if case == 'immediate':
                assert state['stop'] and state['frames'] == 0, 'Immediate stop sent audio or missed STOP'
                assert state['empty'] or state['error'] == 'bad_audio', 'Missing empty final / old error'
                assert probe['editor_text']() == before, 'Empty final changed the editor'
            if case in ('partial', 'polishing'):
                assert state['partials'] > 0, 'Stop did not follow a partial'
            if case == 'polishing': assert state['correcting'], 'Managed polishing did not run'
            print('PASS stop:', case, '; content-free server state:', state, flush=True)
            break
    assert not expect_crash, 'Baseline did not reproduce the reported TLS crash'
    # A new task drops the test editor's focus/scroll state before opening Diagnostics (Chirp settings → About).
    adb('shell', 'am', 'start', '-f', '0x10008000', '-n', package + '/.SetupActivity', '--es', 'section', 'settings')
    # About also prefixes the recogniser's info button. Match the category text exactly.
    deadline = time.monotonic() + 60
    about = None
    while time.monotonic() < deadline:
        about = next((n for n in probe['nodes']() if n.get('text') == 'About'), None)
        if about is not None: break
    assert about is not None, 'About category did not appear'
    probe['tap'](about)
    wait_for('Diagnostics')
    # Session timings can push the crash summary below the fold. Scroll the detail pane.
    w, h = probe['size']()
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if any('No crashes recorded' in n.get('text', '') for n in probe['nodes']()): break
        adb('shell', 'input', 'swipe', str(w * 3 // 4), str(h * 3 // 4), str(w * 3 // 4), str(h // 3), '300')
    else: raise AssertionError('Diagnostics did not show the clean crash summary')
    print('PASS: stop-state matrix; StrictMode debug network death enabled; logcat and in-app Diagnostics clean.', flush=True)
