#!/usr/bin/env python3
"""Release-only UI smoke. Hard pinned to the authorized disposable emulator.
No pairing tokens, speech, or server. Temporary emulator hierarchies are removed.
"""
import os
import hashlib
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET
import zipfile

from emulator_serial import emulator_serial

SERIAL = emulator_serial()

PACKAGE = 'dev.chirp.android'
IME = PACKAGE + '/.ChirpImeService'
ROOT = Path(__file__).resolve().parents[2]
OUT = Path(os.environ.get('CHIRP_E2E_OUTPUT', ROOT / 'docs/screenshots/android'))


def adb(*args):
    result = subprocess.run(['adb', '-s', SERIAL, *args], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if result.returncode:
        raise RuntimeError('ADB operation failed: ' + args[0])
    return result.stdout


def nodes():
    for attempt in range(2):
        try:
            adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/', 'dev.chirp.smoke.UiHierarchy')
            break
        except RuntimeError:
            if attempt: raise
    return list(ET.fromstring(adb('shell', 'cat', '/sdcard/chirp-windows.xml')).iter('node'))


def bounds(node):
    return tuple(map(int, re.findall(r'\d+', node.get('bounds', ''))))


def visible(node):
    x1, y1, x2, y2 = bounds(node)
    return x2 > x1 and y2 > y1


def center(node):
    x1, y1, x2, y2 = bounds(node)
    return (x1 + x2) // 2, (y1 + y2) // 2


def tap(node):
    adb('shell', 'input', 'tap', *map(str, center(node)))


def find(label, hierarchy=None):
    hierarchy = nodes() if hierarchy is None else hierarchy
    if label == 'Microphone: tap to dictate':
        ime = [n for n in hierarchy if n.get('content-desc', '').startswith(label + ',') and visible(n)]
        if ime: return ime[-1]
    matches = [n for n in (nodes() if hierarchy is None else hierarchy)
               if visible(n) and (label in n.get('text', '').split('\n') or label in n.get('content-desc', ''))]
    return matches[-1] if matches else None


def size():
    return tuple(map(int, re.findall(rb'(\d+)x(\d+)', adb('shell', 'wm', 'size'))[-1]))


def click(label):
    started = time.monotonic()
    for _ in range(12):
        hierarchy = nodes()
        matches = [n for n in hierarchy if visible(n) and (label in n.get('text', '').split('\n') or label in n.get('content-desc', ''))]
        actionable = [n for n in matches if n.get('clickable') == 'true' or any(
            p.get('clickable') == 'true' and n in list(p.iter('node'))[1:] for p in hierarchy)]
        if actionable:
            tap(actionable[-1])
            return
        if time.monotonic() - started < 12:
            continue  # Let a popup finish opening; a scroll would dismiss it.
        w, h = size()
        adb('shell', 'input', 'swipe', str(w // 2), str(h * 4 // 5), str(w // 2), str(h // 3), '250')
    raise AssertionError('Missing accessible action: ' + label)


def wait_for(label, seconds=45):
    return wait_for_hierarchy(label, seconds)[0]


def wait_for_hierarchy(label, seconds=45):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        hierarchy = nodes()
        node = find(label, hierarchy)
        if node is not None:
            return node, hierarchy
    raise AssertionError('Missing UI state: ' + label)


def screenshot(name):
    target = OUT / ('release-' + name + '.png')
    data = adb('exec-out', 'screencap', '-p')
    target.write_bytes(data[data.index(b'\x89PNG'):])
    assert target.stat().st_size < 2_000_000, 'Screenshot exceeds 2 MB'


def focus_editor():
    w, h = size()
    for direction in ('up', 'down'):
        for _ in range(4):
            hierarchy = nodes()
            editor = next((n for n in hierarchy if n.get('class') == 'android.widget.EditText' and visible(n)), None)
            if editor is not None:
                # boundsInScreen is not clipped to the viewport: a mostly-below-fold field
                # still reports its full height, and its centre tap lands off screen. Only
                # tap when the centre is comfortably inside the visible area.
                x1, y1, x2, y2 = bounds(editor)
                cy = (y1 + y2) // 2
                if 100 < cy < h - 120:
                    x, y = center(editor)
                    adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/', 'dev.chirp.smoke.UiHierarchy', 'tap', str(x), str(y))
                    wait_for('Microphone: tap to dictate')
                    return
            start, end = (h * 3 // 4, h // 3) if direction == 'up' else (h // 3, h * 3 // 4)
            adb('shell', 'input', 'swipe', str(w // 2), str(start), str(w // 2), str(end), '250')
    raise AssertionError('Test editor is not visible')


def wait_for_editor():
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if any(n.get('class') == 'android.widget.EditText' for n in nodes()): return
    raise AssertionError('Scratchpad editor did not open')


def fresh_editor():
    if os.environ.get('CHIRP_E2E_NATIVE_EDITOR') == '1':
        adb('shell', 'am', 'force-stop', PACKAGE)
        adb('shell', 'ime', 'enable', IME)
        adb('shell', 'ime', 'set', IME)
        adb('shell', 'am', 'start', '-n', PACKAGE + '/.E2eEditorActivity')
        wait_for_editor()
        focus_editor()
        return
    adb('shell', 'cmd', 'statusbar', 'collapse')
    adb('shell', 'am', 'force-stop', PACKAGE)
    # Android falls back to Gboard when the selected IME package is force-stopped.
    adb('shell', 'ime', 'enable', IME)
    adb('shell', 'ime', 'set', IME)
    adb('shell', 'am', 'start', '-n', PACKAGE + '/.SetupActivity', '--es', 'section', 'try')
    # Notes is the launcher destination; Dictate opens Scratchpad.
    wait_for('Dictate', 60)
    click('Dictate')
    wait_for_editor()
    focus_editor()


def tap_key(label):
    hierarchy = nodes()
    key = next((n for n in hierarchy if n.get('class') == 'helium314.keyboard.keyboard.Key'
                and (n.get('content-desc', '').lower() == label.lower() or
                     n.get('content-desc', '').lower().startswith(label.lower() + ' corrects '))), None)
    assert key is not None, 'Missing key: ' + label
    x, y = center(key)
    w, h = size()
    assert 0 <= x < w and 0 <= y < h, 'Key accessibility bounds are outside the screen'
    tap(key)


def editor_text():
    return next(n.get('text', '') for n in nodes() if n.get('class') == 'android.widget.EditText')


def typing_check():
    # True on-screen key taps enter HeliBoard's correction path; adb input text would bypass it.
    for key in ('t', 'e', 'h', 'Space'):
        tap_key(key)
    assert editor_text().strip().lower() == 'the', 'English transposition autocorrect failed'
    screenshot('typing-autocorrect')
    suggestions = next(n for n in nodes() if n.get('resource-id', '').endswith(':id/suggestions_strip'))
    assert any(n.get('text') for n in suggestions.iter('node')), 'Next-word suggestions missing'
    screenshot('typing-next-word')
    for key in ('i', 'm', 'Space'):
        tap_key(key)
    assert editor_text().strip().endswith("I'm"), 'English contraction autocorrect failed'
    screenshot('typing-contraction')
    # Select/copy the synthetic fixture using editor commands; inspect actual clipboard history UI.
    adb('shell', 'input', 'keycombination', 'KEYCODE_CTRL_LEFT', 'KEYCODE_A')
    adb('shell', 'input', 'keycombination', 'KEYCODE_CTRL_LEFT', 'KEYCODE_C')
    click('More keys')
    click('Clipboard')
    assert any("I'm" in n.get('text', '') for n in nodes()), 'Clipboard fixture missing'
    screenshot('typing-clipboard')
    # Hide/show the keyboard returns to the normal layout without editing the fixture.
    fresh_editor()
    click('More keys')
    click('Emoji')
    # The palette inflates after the tap; on a contended host that can take several seconds.
    deadline = time.monotonic() + 20
    while not any('emoji' in n.get('resource-id', '') for n in nodes()):
        assert time.monotonic() < deadline, 'Emoji keyboard missing'
    screenshot('typing-emoji')
    fresh_editor()


def crash_check():
    crash = adb('logcat', '-b', 'crash', '-d').decode(errors='replace')
    assert not re.search(r'dev\.chirp\.|Process: dev\.chirp\.android|>>> dev\.chirp\.android <<<', crash), 'Chirp crash in release'


def main():
    assert os.environ.get('ANDROID_SERIAL', SERIAL) == SERIAL
    assert adb('get-serialno').strip().decode() == SERIAL
    # The release splits by ABI; smoke installs the split matching this emulator's ABI.
    abi = adb('shell', 'getprop', 'ro.product.cpu.abi').decode().strip()
    assert abi in ('arm64-v8a', 'x86_64'), 'unexpected emulator ABI ' + abi
    apk = Path(os.environ.get('CHIRP_SMOKE_APK', ROOT / ('android/app/build/outputs/apk/release/app-%s-release.apk' % abi)))
    # Artifact inspection supplements (rather than substitutes for) UI verification.
    with zipfile.ZipFile(apk) as archive:
        assert not any('synthetic' in name or 'debug_network_security' in name for name in archive.namelist()), 'Debug resource in release'
        assert not any('libjni_latinimegoogle' in name for name in archive.namelist()), 'Proprietary glide library in release'
        for asset, digest in {
            'assets/dicts/main_en-US.dict': 'bd950ef4b57655120eee65cee62a5d216a63f721d9a8bb759ce2022437840443',
            'assets/dicts/emoji_en.dict': '23f95de30c79f828169233367343edd91e3fb486bef596127cb200959c2dc212',
        }.items():
            assert hashlib.sha256(archive.read(asset)).hexdigest() == digest, 'Packaged dictionary pin changed'

    original_size = adb('shell', 'wm', 'size').decode()
    original_density = adb('shell', 'wm', 'density').decode()
    original_night = adb('shell', 'cmd', 'uimode', 'night').decode()
    try:
        adb('shell', 'cmd', 'statusbar', 'collapse')
        adb('install', '-r', str(apk))
        adb('shell', 'pm', 'clear', PACKAGE)
        adb('shell', 'ime', 'disable', IME)
        adb('logcat', '-b', 'crash', '-c')
        adb('shell', 'settings', 'put', 'secure', 'show_ime_with_hard_keyboard', '1')
        adb('shell', 'am', 'start', '-n', PACKAGE + '/.SetupActivity')
        wait_for('Dictate anywhere')
        click('Get started')
        wait_for('How you’ll dictate')
        click('Use Chirp Keyboard')
        click('Continue')
        wait_for('Turn on Chirp Keyboard')
        click('Enable Chirp Keyboard')
        wait_for('Keyboard apps')
        adb('shell', 'ime', 'enable', IME)
        adb('shell', 'ime', 'set', IME)
        adb('shell', 'input', 'keyevent', '4')
        wait_for('Allow microphone')  # Returning from system settings auto-advances.
        click('Allow microphone')
        permission = wait_for('While using the app')
        tap(permission)
        wait_for('Scan code')
        screenshot('pairing-light')
        click('Scan code')
        wait_for('Close code scanner', seconds=60)
        screenshot('scanner-light')
        adb('shell', 'input', 'keyevent', '4')
        wait_for('Scan code')
        crash_check()
        adb('shell', 'am', 'start', '-n', PACKAGE + '/.SetupActivity', '--es', 'section', 'try')
        wait_for('Dictate')
        click('Dictate')
        wait_for('Dictate, then edit here')
        focus_editor()
        mic = wait_for('Microphone: tap to dictate')
        tap(mic)
        action = wait_for('Pair your Mac in Chirp setup. Pair Mac')
        assert action.get('text') == 'Pair Mac', 'Mic strip did not respond'
        tap(action)
        wait_for('Scan code')
        adb('shell', 'am', 'start', '-n', PACKAGE + '/.SetupActivity', '--es', 'section', 'try')
        wait_for('Dictate')
        click('Dictate')
        wait_for('Dictate, then edit here')
        focus_editor()
        # Long press must expose options and stay idle (no capture before consent).
        mic = wait_for('Microphone: tap to dictate')
        x, y = center(mic)
        adb('shell', 'input', 'swipe', str(x), str(y), str(x), str(y), '700')
        wait_for('Chirp settings')
        adb('shell', 'input', 'keyevent', '4')
        typing_check()
        for form, resolution, density in [('inner', '2076x2152', '420'), ('cover', '1080x2520', '420')]:
            adb('shell', 'wm', 'size', resolution)
            adb('shell', 'wm', 'density', density)
            for theme in ('light', 'dark'):
                adb('shell', 'cmd', 'uimode', 'night', 'yes' if theme == 'dark' else 'no')
                fresh_editor()
                hierarchy = nodes()
                mic = find('Microphone: tap to dictate', hierarchy)
                assert mic is not None, 'Mic absent after configuration change'
                w, h = size()
                digits = [n for n in hierarchy if n.get('class') == 'helium314.keyboard.keyboard.Key' and n.get('content-desc') == '1']
                assert bool(digits) == (form == 'inner'), 'Number-row default does not match Fold width'
                for label in ('Microphone: tap to dictate', 'Test dictation here'):
                    node = find(label, hierarchy)
                    if node is not None:
                        x1, y1, x2, y2 = bounds(node)
                        assert 0 <= x1 < x2 <= w and 0 <= y1 < y2 <= h, 'Clipped accessible control'
                screenshot('keyboard-' + form + '-' + theme)
                tap(mic)
                # The pairing notice expires after 5 s and a dump can take 2 s; reuse the same dump for Cancel.
                _, hierarchy = wait_for_hierarchy('Pair your Mac in Chirp setup. Pair Mac')
                cancel = find('Cancel dictation', hierarchy)
                assert cancel is not None and cancel.get('clickable') == 'true', 'Cancel missing beside pair action'
                screenshot('pair-action-' + form + '-' + theme)
                tap(cancel)
                wait_for('Microphone: tap to dictate')
                crash_check()
        adb('shell', 'wm', 'size', '2560x1600')
        adb('shell', 'cmd', 'uimode', 'night', 'no')
        fresh_editor()
        keys = [n for n in nodes() if n.get('class') == 'helium314.keyboard.keyboard.Key']
        left = next(n for n in keys if n.get('content-desc', '').lower() == 't')
        right = next(n for n in keys if n.get('content-desc', '').lower() == 'y')
        assert center(right)[0] - center(left)[0] > size()[0] * .15, 'Unfolded landscape split missing'
        screenshot('keyboard-inner-landscape-light')
        click('More keys')
        wait_for('One-handed mode')
        adb('shell', 'input', 'keyevent', '4')
        mic = wait_for('Microphone: tap to dictate')
        x, y = center(mic)
        adb('shell', 'input', 'swipe', str(x), str(y), str(x), str(y), '700')
        click('Chirp settings')
        wait_for('Settings')
        click('About')
        wait_for('Diagnostics')
        assert any('No crashes recorded' in n.get('text', '') for n in nodes()), 'Chirp crash in diagnostics'
        crash_check()
        print('PASS: release install; state-aware setup; QR scanner open/back; editor + keyboard; mic pairing action; long-press options; inner/cover light/dark; accessible labels and bounds; autocorrect teh/the + contraction; next-word suggestions; clipboard + emoji; settings + diagnostics; no Chirp crash.')
        print('Release APK bytes:', apk.stat().st_size)
    finally:
        for command, original in [('size', original_size), ('density', original_density)]:
            override = re.search(r'Override (?:size|density): (\S+)', original)
            adb('shell', 'wm', command, override.group(1) if override else 'reset')
        adb('shell', 'cmd', 'uimode', 'night', 'yes' if 'yes' in original_night else ('auto' if 'auto' in original_night else 'no'))
        adb('shell', 'rm', '-f', '/sdcard/chirp-release.xml', '/sdcard/chirp-windows.xml', '/data/local/tmp/chirp-ui-probe.jar')


if __name__ == '__main__':
    main()
