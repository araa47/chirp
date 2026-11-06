#!/usr/bin/env python3
"""Capture real main-screen pixels for human review; synthetic content only.

Run through e2e-all.sh so screenshots share its owned emulator and private evidence.
This checks navigation and captures evidence; it does not certify visual quality.
"""
import json
import re
import shlex
import time
import xml.etree.ElementTree as ET


def check(p, work, output):
    adb, wait, click = (p[k] for k in ('adb', 'wait_for', 'click'))
    package = p['PACKAGE']
    captures = []

    def start(activity='SetupActivity', section=None):
        adb('shell', 'am', 'force-stop', package)
        args = ['shell', 'am', 'start', '-n', package + '/.' + activity]
        if section:
            args += ['--es', 'section', section]
        adb(*args)

    def hide_ime():
        def shown():
            p['nodes']()
            windows = ET.fromstring(adb('shell', 'cat', '/sdcard/chirp-windows.xml'))
            return any(w.get('type') == '2' for w in windows.iter('window'))
        if shown():
            adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
            deadline = time.monotonic() + 15
            while shown():
                if time.monotonic() > deadline: raise AssertionError('IME did not hide')

    def shot(name):
        # Wait for the screen's assertions before calling; allow the final drawing frame.
        time.sleep(.3)
        data = adb('exec-out', 'screencap', '-p')
        name = f'{form}-{theme}-{name}.png'
        (output / name).write_bytes(data[data.index(b'\x89PNG'):])
        captures.append(name)
        print('CAPTURE:', name, flush=True)

    def bars():
        """Status-bar bottom and navigation-bar top in pixels, as the window manager reports them."""
        dump = adb('shell', 'dumpsys', 'window').decode(errors='replace')
        status = re.search(r'type=statusBars frame=\[\d+,\d+\]\[\d+,(\d+)\]', dump)
        navigation = re.search(r'type=navigationBars frame=\[\d+,(\d+)\]\[\d+,\d+\]', dump)
        assert status and navigation, 'System bar insets unavailable'
        return int(status.group(1)), int(navigation.group(1))

    def assert_settings_column_clear():
        """#181: the inner screen's category column neither starts under the clock nor ends under the gesture handle."""
        w, h = p['size']()
        status_bottom, navigation_top = bars()
        def column():
            return [n for n in p['nodes']() if n.get('package') == package and n.get('text') and w * .15 < p['center'](n)[0] < w * .45
                    and p['bounds'](n)[3] > p['bounds'](n)[1]]
        first = column()
        if not first:  # Say what is on screen instead of failing inside min().
            seen = [(n.get('text'), p['center'](n)[0]) for n in p['nodes']() if n.get('package') == package and n.get('text')]
            raise AssertionError(f'No Settings column text between 15% and 45% of {w}px; text centres: {seen[:20]}')
        assert min(p['bounds'](n)[1] for n in first) >= status_bottom, 'Settings column starts under the status bar'
        shot('settings-column-top')
        for _ in range(8):
            adb('shell', 'input', 'swipe', str(w // 4), str(h * 3 // 4), str(w // 4), str(h // 5), '250')
        last = column()
        assert any(n.get('text') == 'About' for n in last), 'Scrolling did not reach About'
        assert max(p['bounds'](n)[3] for n in last) <= navigation_top, 'Settings column ends under the gesture area'
        shot('settings-column-end')

    originals = {key: adb('shell', 'wm', key).decode() for key in ('size', 'density')}
    night = adb('shell', 'cmd', 'uimode', 'night').decode()
    font = adb('shell', 'settings', 'get', 'system', 'font_scale').decode().strip()
    try:
        adb('shell', 'settings', 'put', 'system', 'font_scale', '1.0')
        # Seed a known local document so detail captures wait for loaded content.
        start(section='try'); wait('Record new note')
        adb('shell', 'am', 'start', '-a', 'android.intent.action.SEND', '-t', 'text/plain',
            '--es', 'android.intent.extra.SUBJECT', shlex.quote('Visual review'),
            '--es', 'android.intent.extra.TEXT', shlex.quote('Review the launch checklist.'),
            '-n', package + '/.ShareToNotesActivity')
        wait('Save to Notes'); click('Save as new note')
        for form, dimensions in (('cover', '1080x2520'), ('inner', '2076x2152')):
            adb('shell', 'wm', 'size', dimensions)
            adb('shell', 'wm', 'density', '420')
            for theme in ('light', 'dark'):
                adb('shell', 'cmd', 'uimode', 'night', 'yes' if theme == 'dark' else 'no')
                start(section='try'); wait('Record new note'); hide_ime(); shot('notes-library')
                click('Visual review'); wait('Review the launch checklist.'); shot('note-detail')
                click('Transcript'); wait('Transcript'); shot('note-transcript')
                start(section='history'); wait('Dictation history'); shot('history')
                if form == 'inner':
                    start(section='settings'); wait('How you dictate'); assert_settings_column_clear()
                for label, slug in ((None, 'home'), ('Connection', 'connection'),
                                    ('How you dictate', 'input'), ('Dictation', 'dictation'),
                                    ('Keyboard', 'keyboard'), ('Feedback & look', 'feedback'),
                                    ('Notes', 'notes'), ('Privacy & history', 'privacy'), ('About', 'about')):
                    start(section='settings'); wait('How you dictate')
                    if label:
                        # Exclude shell tabs (bottom bar or left rail) when titles repeat.
                        w, h = p['size']()
                        for _ in range(8):
                            candidates = [n for n in p['nodes']() if n.get('text') == label
                                          and 80 < p['center'](n)[1] < h - 80
                                          and (form != 'inner' or p['center'](n)[0] > w * .1)]
                            if candidates:
                                p['tap'](candidates[0]); break
                            adb('shell', 'input', 'swipe', str(w // 4), str(h * 3 // 4), str(w // 4), str(h // 3), '300')
                        else: raise AssertionError('Settings row missing: ' + label)
                        marker = {'Notes': 'Save battery while the screen is off', 'About': 'Diagnostics',
                                  'Privacy & history': 'Keep dictation history on this phone'}.get(label, label)
                        wait(marker)
                    shot('settings-' + slug)
                start(section='try'); wait('Record new note'); click('Dictate')
                wait('Dictate, then edit here'); shot('scratchpad')
                # Revoke the microphone first to keep this visual-only pass silent.
                adb('shell', 'pm', 'revoke', package, 'android.permission.RECORD_AUDIO')
                start('QuickDictateActivity'); wait('Quick dictate'); shot('quick-dictate')
                adb('shell', 'pm', 'grant', package, 'android.permission.RECORD_AUDIO')
                start(section='try'); wait('Record new note')
                adb('shell', 'am', 'start', '-a', 'android.intent.action.SEND', '-t', 'text/plain',
                    '--es', 'android.intent.extra.TEXT', shlex.quote('Synthetic visual review note'),
                    '-n', package + '/.ShareToNotesActivity')
                wait('Save to Notes'); shot('share'); click('Cancel')
        # Fresh, unpaired onboarding screens contain no pairing credential.
        for form, dimensions in (('cover', '1080x2520'), ('inner', '2076x2152')):
            adb('shell', 'wm', 'size', dimensions)
            for theme in ('light', 'dark'):
                adb('shell', 'cmd', 'uimode', 'night', 'yes' if theme == 'dark' else 'no')
                adb('shell', 'pm', 'clear', package)
                adb('shell', 'ime', 'set', 'com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME')
                adb('shell', 'ime', 'disable', p['IME'])
                start(); wait('Get started'); shot('onboarding-welcome')
                click('Get started'); wait('How you’ll dictate'); shot('onboarding-choice')
                click('Keep Gboard'); click('Continue'); wait('Turn on the floating mic'); shot('onboarding-floating')
                adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
                wait('How you’ll dictate'); click('Use Chirp Keyboard'); click('Continue')
                wait('Turn on Chirp Keyboard'); shot('onboarding-keyboard')
                adb('shell', 'ime', 'enable', p['IME']); adb('shell', 'ime', 'set', p['IME'])
                adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
                adb('shell', 'am', 'start', '-n', package + '/.SetupActivity')
                wait('Continue'); click('Continue')
                wait('Allow microphone'); shot('onboarding-microphone')
                click('Allow microphone'); wait('While using the app')
                adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/',
                    'dev.chirp.smoke.UiHierarchy', 'click', shlex.quote('While using the app'))
                wait('Scan code'); shot('onboarding-pair')
        p['crash_check']()
    finally:
        for key, value in originals.items():
            override = re.search(r'Override (?:size|density): (\S+)', value)
            adb('shell', 'wm', key, override.group(1) if override else 'reset')
        adb('shell', 'cmd', 'uimode', 'night', 'yes' if 'yes' in night else 'auto' if 'auto' in night else 'no')
        if font == 'null': adb('shell', 'settings', 'delete', 'system', 'font_scale')
        else: adb('shell', 'settings', 'put', 'system', 'font_scale', font)
        (output / 'captures.json').write_text(json.dumps(captures, indent=2) + '\n')
    print('PASS: main-screen capture matrix; human visual review still required.', flush=True)
