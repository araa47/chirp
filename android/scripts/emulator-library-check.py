#!/usr/bin/env python3
"""Saved Notes library UI acceptance on the real capture result; synthetic text only."""
import json
import re
import shlex
import time


def check(p, work, output):
    adb, nodes, find, click, wait = (p[k] for k in ('adb', 'nodes', 'find', 'click', 'wait_for'))

    def shot(name):
        data = adb('exec-out', 'screencap', '-p')
        (output / (name + '.png')).write_bytes(data[data.index(b'\x89PNG'):])
        nodes()
        (output / (name + '.xml')).write_bytes(adb('shell', 'cat', '/sdcard/chirp-windows.xml'))

    def poll(predicate, message, seconds=60):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            result = predicate()
            if result is not None and result is not False: return result
            time.sleep(.5)
        raise AssertionError(message)

    def row():
        return next((n for n in nodes() if n.get('resource-id', '').endswith('note-library-row')), None)

    def text(value):
        adb('shell', 'input', 'keycombination', 'KEYCODE_CTRL_LEFT', 'KEYCODE_A')
        adb('shell', 'input', 'text', value)

    # Rename in the real detail, then search via the library's editable field.
    click('More options'); click('Rename')
    p['tap'](wait('Note title'))
    text('E2E-library-fixture')
    click('Save title')
    if any(n.get('class') == 'helium314.keyboard.keyboard.Key' for n in nodes()):
        adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
    click('Back to notes')
    poll(row, 'Saved note missing from library')
    shot('library-saved')
    p['tap'](wait('Search notes')); text('zzqxx')
    adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
    wait('No results for “zzqxx”')
    click('Clear search')
    p['tap'](wait('Search notes')); text('E2E-library-fixture')
    adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
    target = poll(row, 'Renamed note not found by search')
    shot('library-search')
    click('Clear search')
    # Swipe left and undo while the transient snackbar is present.
    # A swipe that the list never recognised (slow, loaded emulator) shows no snackbar at all; retry it rather than
    # reporting the missing Undo as an accessibility failure. Undo itself is only waited for once the delete is announced.
    for attempt in range(3):
        target = poll(row, 'No row to delete')
        x1, y1, x2, y2 = p['bounds'](target)
        adb('shell', 'input', 'swipe', str(x2 - 12), str((y1+y2)//2), str(x1 + 12), str((y1+y2)//2), '300')
        try:
            wait('Note deleted', 10); break
        except AssertionError:
            if attempt == 2: raise AssertionError('Swipe did not delete the note (no "Note deleted" snackbar after 3 swipes)')
    click('Undo')
    poll(row, 'Undo did not restore saved note')
    target = poll(row, 'No row for second delete')
    x, y = p['center'](target)
    adb('shell', 'input', 'swipe', str(x), str(y), str(x), str(y), '800')
    click('Delete selected notes')
    click('Library options'); p['tap'](wait('Recently Deleted', 15))
    poll(row, 'Deleted note missing from Recently Deleted')
    shot('library-recently-deleted')
    click('Restore'); click('Back to notes')
    p['tap'](poll(row, 'Restore did not return the note'))
    wait('Continue recording')
    before = json.loads((work / 'notes.json').read_text()).get('finals', 0)
    click('Continue recording')
    poll(lambda: json.loads((work / 'notes.json').read_text()).get('finals', 0) > before or None,
         'Continue did not append a real segment', 90)
    click('Stop recording notes'); wait('Stopped')
    shot('library-continued')
    print('PASS: library list, rename, search hit/miss, delete/undo, Recently Deleted/restore, continue recording', flush=True)
