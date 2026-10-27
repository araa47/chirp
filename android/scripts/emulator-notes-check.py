#!/usr/bin/env python3
"""Live Notes end to end, invoked by emulator-check.py --notes-check. Synthetic speech only (the debug
asset, looped with silence like a meeting) through the real NotesCapture, rolling /v1/stream sockets and
/v1/notes/* calls of the throwaway server, which counts finals and notes calls without content. Fails
unless what is said reaches the transcript and the notes while recording, within a deadline. Prints
states and counts, never the notes or transcript."""
import json
import re
import time
from pathlib import Path

DEADLINE = 90
RECORDING = ('Listening…', 'Updating notes…', 'Organizing notes…')


def log(*args):
    print('%7.1f' % (time.monotonic() % 100000), *args, flush=True)


def check(probe, work, output):
    adb, nodes = probe['adb'], probe['nodes']
    package = probe['PACKAGE']
    counts = work / 'notes.json'

    def server():
        try: return json.loads(counts.read_text())
        except (OSError, ValueError): return {}

    baseline = 0
    def finals(): return server().get('finals', 0) - baseline

    def notes_editor(hierarchy):
        # Compose exposes the Markdown description on a separate accessibility child, sharing the EditText's bounds.
        label = next((n for n in hierarchy if n.get('content-desc') == 'Notes (Markdown)'), None)
        return next((n for n in hierarchy if n.get('class') == 'android.widget.EditText' and label is not None and n.get('bounds') == label.get('bounds')), None)

    def state():
        hierarchy = nodes()
        texts = [n.get('text', '') for n in hierarchy]
        # The notes render as Markdown blocks (tagged notes-block); while editing they are one EditText.
        blocks = [n for n in hierarchy if n.get('resource-id', '').endswith('notes-block')]
        field = notes_editor(hierarchy)
        editor = field.get('text', '') if field is not None else ''
        notes = len(editor) if field is not None else sum(len(child.get('text', '')) for block in blocks for child in block.iter('node'))
        status = next((t for t in texts if t.startswith(STATUSES)), None)
        # A listening command shows what it heard: never printed.
        if any(t.startswith('“') for t in texts) and status is None: status = '“…”'
        note = next((t for t in texts if t.startswith(NOTES)), None)
        # Chirp's elapsed clock (not the status bar's) comes before any transcript timestamp. The recording dock is one
        # accessibility node read as "<title>, <elapsed>", so its time ends the description rather than being a text node.
        def elapsed(n):
            if re.fullmatch(r'(\d+:)?\d\d:\d\d', n.get('text', '')): return n.get('text')
            found = re.search(r', ((\d+:)?\d\d:\d\d)$', n.get('content-desc', ''))
            return found and found.group(1)
        clock = next((t for n in hierarchy if n.get('package') == package for t in [elapsed(n)] if t), '0:0')
        seconds = sum(int(part) * 60 ** i for i, part in enumerate(reversed(clock.split(':'))))
        return {'status': status, 'note': note, 'clock': seconds, 'notes_chars': notes, 'gaps': [t for t in texts if 'audio not transcribed' in t],
                'hearing': any(n.get('resource-id') == 'notes-hearing' for n in hierarchy)}

    def wait(predicate, message, seconds=DEADLINE):
        deadline = time.monotonic() + seconds
        last = None
        while time.monotonic() < deadline:
            current = state()
            seen = (current, server())
            if seen != last: log(*seen); last = seen
            assert not (current['status'] or '').startswith(('Notes stopped', 'Couldn’t resume')), 'Notes stopped by itself: ' + current['status']
            assert not current['gaps'], 'A segment was not transcribed: ' + ', '.join(current['gaps'])
            if predicate(current): return current
            time.sleep(1)
        shot = Path('/tmp/chirp-notes-failure.png')
        data = adb('exec-out', 'screencap', '-p'); shot.write_bytes(data[data.index(b'\x89PNG'):])
        raise AssertionError(message + ' within %d s (last: %s; server: %s; screen: %s)' % (seconds, json.dumps(last[0]), json.dumps(server()), shot))

    def wait_node(label, seconds=20):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            node = probe['find'](label)
            if node is not None: return node
        raise AssertionError('Missing control: ' + label)

    def tap(node): adb('shell', 'input', 'tap', *map(str, probe['center'](node)))

    def find_idle(): return probe['find']('Microphone: tap to dictate') is not None

    def recording(s): return (s['status'] or '').startswith(RECORDING)

    adb('shell', 'pm', 'grant', package, 'android.permission.POST_NOTIFICATIONS')
    # Start from empty notes: no recovery copy (or kept notes) of an earlier run. The fresh install's process reads
    # them only when Notes first opens.
    adb('shell', 'am', 'force-stop', package)
    adb('shell', 'run-as', package, 'rm', '-f', 'no_backup/notes_recovery.bin', 'files/notes_sessions.bin')
    adb('shell', 'run-as', package, 'rm', '-rf', 'files/notes')
    # Opt in on the disposable emulator before the new process reads its preferences. Real MediaCodec, no fake encoder.
    import shlex
    adb('shell', 'run-as', package, 'sh', '-c', shlex.quote('cat > shared_prefs/chirp_notes_sessions.xml'),
        data=b'<map><boolean name="enabled" value="true"/><boolean name="keep_audio" value="true"/></map>')
    baseline = server().get('finals', 0)  # the managed warm-up's final
    adb('shell', 'am', 'start', '-n', package + '/.SetupActivity', '--es', 'section', 'try')
    probe['wait_for']('Notes')
    wait_node('Record new note')
    started = time.monotonic()
    tap(wait_node('Record new note'))
    wait(lambda s: recording(s) and s['hearing'], 'No live speech reached Notes')
    # The asset repeats every ~12 s, so a cut comes at the first pause after 12 s: three segments need two cuts.
    wait(lambda s: recording(s) and finals() >= 3, 'Three segments did not reach the transcript while recording')
    wait(lambda s: recording(s) and 200 in server().get('structure', []) and s['notes_chars'] > 0, 'Structured notes did not reach the editor while recording')
    log('Recording: segments and notes arrived after %.0f s' % (time.monotonic() - started))

    def calls(name): return len(server().get(name, []))

    # Edit by voice while recording: capture goes to the command's socket and back to a fresh notes socket.
    before = finals()
    tap(wait_node('Edit notes by voice'))
    wait(lambda s: s['status'] in ('Say the edit…', '“…”'), 'The voice command did not start listening', 20)
    time.sleep(8)
    tap(wait_node('Send the spoken edit'))
    wait(lambda s: calls('edit') >= 1, 'The spoken edit never reached /v1/notes/edit', 60)
    assert all(code == 200 for code in server()['edit']), 'The edit call failed: ' + json.dumps(server())
    wait(lambda s: recording(s) and finals() >= before + 3, 'Notes did not go on recording after the spoken edit')
    log('Voice edit: one edit call; notes went on recording')

    # Battery saver: with the screen off, segments and notes calls go on; the editor catches up when it is back.
    clock, before, passes = state()['clock'], finals(), calls('structure')
    adb('shell', 'input', 'keyevent', 'KEYCODE_SLEEP')
    time.sleep(40)
    off = (finals() - before, calls('structure') - passes)
    adb('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP'); adb('shell', 'wm', 'dismiss-keyguard')
    assert off[0] >= 1, 'Segments stopped with the screen off: ' + json.dumps(server())
    assert off[1] >= 1, 'Notes calls stopped with the screen off: ' + json.dumps(server())
    # The clock stops with the screen off; it (and the editor and partial line) catch up the moment it is back. It counts
    # captured audio, which the paced synthetic source delivers a little behind wall time on a busy host.
    wait(lambda s: recording(s) and s['clock'] >= clock + 20, 'The screen did not catch up after it came back', 10)
    log('Screen off 40 s: %d segments, %d notes calls; editor caught up' % off)
    probe['click']('Pause recording notes')
    wait(lambda s: s['status'] == 'Paused', 'Pause did not take effect', 30)
    before = finals()
    time.sleep(3)
    probe['click']('Resume recording notes')
    wait(lambda s: recording(s) and finals() >= before + 1, 'No segment reached the transcript after Resume')
    probe['click']('Stop recording notes')
    final = wait(lambda s: (s['status'] or '').startswith('Stopped'), 'Stop did not finish', 60)
    assert final['notes_chars'] > 0, 'Notes are empty after Stop'
    assert all(code == 200 for code in server().get('structure', [])), 'A structure call failed: ' + json.dumps(server())
    # Replay an actual kept VAD segment. The button changes only after MediaPlayer is prepared and has started.
    # Require it to keep playing, finish naturally and report no decoder error: this is a real AAC round trip.
    tap(wait_node('Transcript'))
    tap(wait_node('Play segment 1', seconds=60))
    wait_node('Stop playback')
    time.sleep(2)
    assert probe['find']('Stop playback') is not None, 'MediaPlayer did not sustain playback'
    data = adb('exec-out', 'screencap', '-p')
    (output / 'emulator-notes-kept-audio-playing.png').write_bytes(data[data.index(b'\x89PNG'):])
    deadline = time.monotonic() + 75
    while probe['find']('Stop playback') is not None:
        assert time.monotonic() < deadline, 'Kept audio never completed playback'
        time.sleep(.5)
    assert not any('Couldn’t play kept audio' in n.get('text', '') for n in nodes()), 'Kept audio decoder failed'
    assert any(n.get('content-desc', '').startswith('Play segment ') for n in nodes()), 'Playback did not return to its idle affordance'
    tap(wait_node('Close transcript'))
    log('PASS: real MediaCodec AAC kept-audio record → MediaPlayer prepare/start → natural completion')

    import runpy
    runpy.run_path(str(Path(__file__).with_name("emulator-retranscribe-check.py")))["check"](probe, work, output)
    runpy.run_path(str(Path(__file__).with_name('emulator-library-check.py')))['check'](probe, work, output)

    # Short synthetic notes may legitimately be below the Organize minimum.
    # Library round-trip and real audio are the sweep's required acceptance gates.
    def menu(item): probe['click']('More options'); tap(wait_node(item))
    menu('Share')
    deadline = time.monotonic() + 15
    # Wait until the sheet has input focus, so Back closes it rather than reaching Notes behind it on a slow host.
    while 'Chooser' not in next((l for l in adb('shell', 'dumpsys', 'window').decode(errors='replace').splitlines() if 'mCurrentFocus' in l), ''):
        assert time.monotonic() < deadline, 'Share did not open the share sheet'
        time.sleep(.5)
    adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')

    # The Scratchpad: the same server and app network path, the keyboard's capture. One synthetic utterance must land.
    tap(wait_node('Back to notes'))  # Detail pops to the preserved Notes library; Dictate is its small FAB.
    probe['wait_for']('Dictate')
    probe['click']('Dictate')
    check_scratchpad(probe, work, output)
    if probe.get('speakers_model'):
        runpy.run_path(str(Path(__file__).with_name('emulator-speakers-check.py')))['check'](probe, work, output)
    else:
        log('SKIPPED speaker labels: no speaker model (set CHIRP_SPEAKER_MODEL, or run chirp-server model fetch --speakers)')
    log('PASS: Live Notes: rolling segments reached the transcript, structured notes reached the editor while recording; voice edit; screen-off battery saver; pause, resume, stop; real kept-audio encode and playback; library list/search/rename/delete/undo/trash/restore/continue; Share; Scratchpad' + ('; speaker labels' if probe.get('speakers_model') else ''), server())


def check_scratchpad(probe, work, output):
    adb, nodes = probe['adb'], probe['nodes']
    def finals():
        try: return json.loads((work / 'notes.json').read_text()).get('finals', 0)
        except (OSError, ValueError): return 0
    before = finals()
    mic = probe['wait_for']('Microphone: tap to dictate')
    adb('shell', 'input', 'tap', *map(str, probe['center'](mic)))
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        hierarchy = nodes()
        editor = next((n.get('text', '') for n in hierarchy if n.get('class') == 'android.widget.EditText'), '')
        idle = probe['find']('Microphone: tap to dictate', hierarchy) is not None
        if finals() > before and editor not in ('', 'Dictate, then edit here') and idle:
            log('Scratchpad: one dictation landed')
            return
        time.sleep(1)
    data = adb('exec-out', 'screencap', '-p')
    Path('/tmp/chirp-notes-scratchpad-failure.png').write_bytes(data[data.index(b'\x89PNG'):])
    raise AssertionError('Scratchpad dictation did not land; new finals=%d' % (finals() - before))


# The fixed notes above the record control (voice edit, Organize, structuring); never notes text.
NOTES = ('Couldn’t', 'Didn’t catch', 'Nothing to edit', 'That didn’t sound', 'Can’t add', 'Notes changed', 'The edit changed',
         'Too much to edit', 'Edited', 'Organized', 'Too long to organize', 'Nothing to organize')
STATUSES = ('Tap Record', 'Pair your Mac', 'Connecting', 'Listening…', 'Updating notes', 'Organizing notes', 'Finishing', 'Stopped', 'Paused',
            'Notes stopped', 'Couldn', 'Mac ', 'Checking', 'Allow microphone', 'Say the edit', 'Editing notes')
