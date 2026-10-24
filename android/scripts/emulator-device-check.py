#!/usr/bin/env python3
"""Real-server device acceptance: floating mic, TalkBack, font 200%, hinge states."""
import json
import re
import shlex
import time

TALKBACK = 'com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService'
FLOATING = 'dev.chirp.android/.ChirpAccessibilityService'


def onboarding(p):
    adb, click, wait = (p[k] for k in ('adb', 'click', 'wait_for'))
    package = p['PACKAGE']
    adb('shell', 'pm', 'clear', package)
    adb('shell', 'ime', 'disable', p['IME'])
    adb('shell', 'am', 'start', '-n', package + '/.SetupActivity')
    wait('Dictate anywhere'); click('Get started')
    wait('How you’ll dictate'); click('Use Chirp Keyboard'); click('Continue')
    wait('Turn on Chirp Keyboard'); click('Enable Chirp Keyboard')
    wait('Keyboard apps')
    adb('shell', 'ime', 'enable', p['IME']); adb('shell', 'ime', 'set', p['IME'])
    adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
    wait('Allow microphone'); click('Allow microphone'); p['tap'](wait('While using the app'))
    wait('Scan code')
    print('PASS: fresh onboarding welcome, keyboard settings return, microphone permission, pairing page', flush=True)


def check(p, work, output):
    adb, nodes, click, wait = (p[k] for k in ('adb', 'nodes', 'click', 'wait_for'))
    results = {}

    def shot(name):
        data = adb('exec-out', 'screencap', '-p')
        (output / (name + '.png')).write_bytes(data[data.index(b'\x89PNG'):])
        nodes()
        (output / (name + '.xml')).write_bytes(adb('shell', 'cat', '/sdcard/chirp-windows.xml'))

    def poll(predicate, message, seconds=70):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(.5)
        raise AssertionError(message)

    def native(action, label):
        adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/',
            'dev.chirp.smoke.UiHierarchy', action, shlex.quote(label))

    def attempt(name, run):
        try:
            run(); results[name] = 'PASS'
        except Exception as error:
            # ANR diagnostics stay private; never echo app/editor contents.
            (output / (name + '-anr.txt')).write_bytes(adb('shell', 'dumpsys', 'activity', 'lastanr'))
            results[name] = 'FAIL: ' + str(error)
        finally:
            try: shot(name)
            except Exception: pass
        print(name + ': ' + results[name], flush=True)

    original = {key: adb('shell', 'settings', 'get', 'secure', key).decode().strip()
                for key in ('enabled_accessibility_services', 'accessibility_enabled')}
    font = adb('shell', 'settings', 'get', 'system', 'font_scale').decode().strip()
    services = original['enabled_accessibility_services']
    services = [] if services in ('null', '') else services.split(':')

    def enable(service):
        adb('shell', 'settings', 'put', 'secure', 'enabled_accessibility_services', ':'.join(services + [service]))
        adb('shell', 'settings', 'put', 'secure', 'accessibility_enabled', '1')

    def floating():
        p['fresh_editor']()
        # The bubble deliberately hides while Chirp Keyboard is selected.
        adb('shell', 'ime', 'set', 'com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME')
        enable(FLOATING)
        field = next(n for n in nodes() if n.get('class') == 'android.widget.EditText')
        x1, y1, x2, y2 = p['bounds'](field)
        adb('shell', 'input', 'tap', str(x1 + 80), str(y1 + 80))
        label = 'Chirp microphone:'
        bubble = wait(label)
        before = p['editor_text']()
        p['tap'](bubble)
        adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/',
            'dev.chirp.smoke.UiHierarchy', 'watch', 'Listening…', '/sdcard/chirp-floating-listening.png')
        adb('pull', '/sdcard/chirp-floating-listening.png', str(output / 'floating-listening.png'))
        # Accessibility insertion commits on final, rather than composing in the target.
        time.sleep(4)
        # The expanded panel has its own stop mic; avoid the IME window.
        target = next(n for n in nodes() if n.get('content-desc', '').startswith('Microphone: tap to toggle'))
        p['tap'](target)
        poll(lambda: p['find']('Use raw') is not None or p['find'](label) is not None,
             'Floating final did not complete')
        assert p['editor_text']() != before, 'Floating final did not insert text'
        shot('floating-final')
        # Collapse and hold/release the same actual bubble, rather than its options menu.
        hide = p['find']('Hide panel')
        if hide is not None: p['tap'](hide)
        bubble = wait(label)
        x, y = p['center'](bubble)
        adb('shell', 'input', 'swipe', str(x), str(y), str(x), str(y), '4500')
        poll(lambda: p['find']('Listening…') is None, 'Floating hold did not stop on release')

    def talkback():
        # This AVD must have TalkBack installed; missing service is a failed prerequisite.
        installed = adb('shell', 'pm', 'path', 'com.google.android.marvin.talkback')
        assert installed.strip(), 'TalkBack is not installed in chirp-fold'
        adb('shell', 'pm', 'grant', 'com.google.android.marvin.talkback', 'android.permission.POST_NOTIFICATIONS')
        p['fresh_editor'](); enable(TALKBACK)
        poll(lambda: b'touchExplorationEnabled=true' in adb('shell', 'dumpsys', 'accessibility'), 'TalkBack did not enable touch exploration', 30)
        before = p['editor_text']()
        native('click', 'Microphone: tap to dictate')
        # TalkBack can make shell probes slower than a short synthetic utterance.
        poll(lambda: p['find']('Cancel dictation') is not None or p['editor_text']() != before, 'TalkBack dictation produced no state or final')
        if p['find']('Cancel dictation') is not None: native('click', 'Cancel dictation')
        wait('Microphone: tap to dictate')
        native('long-click', 'Microphone: tap to dictate')
        wait('Chirp settings')
        adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')

    def font200():
        adb('shell', 'settings', 'put', 'system', 'font_scale', '2.0')
        adb('shell', 'am', 'force-stop', p['PACKAGE'])
        adb('shell', 'am', 'start', '-n', p['PACKAGE'] + '/.SetupActivity', '--es', 'section', 'try')
        wait('Record new note')
        w, h = p['size']()
        for label in ('Record new note', 'Dictate', 'Library options'):
            node = wait(label)
            x1, y1, x2, y2 = p['bounds'](node)
            assert 0 <= x1 < x2 <= w and 0 <= y1 < y2 <= h, 'Clipped 200% font control: ' + label
        shot('font200-library')
        click('Dictate'); p['wait_for_editor'](); shot('font200-scratchpad')
        assert p['find']('Microphone: tap to dictate') is not None, 'Scratchpad mic missing at 200%'

    def fold():
        adb('shell', 'settings', 'put', 'system', 'font_scale', '1.0')
        adb('shell', 'am', 'force-stop', p['PACKAGE'])
        adb('shell', 'am', 'start', '-n', p['PACKAGE'] + '/.SetupActivity', '--es', 'section', 'try')
        click('Record new note'); wait('Pause recording notes')
        states = adb('shell', 'cmd', 'device_state', 'print-states').decode()
        (output / 'device-states.txt').write_text(states)
        # State names vary by image; discover identifiers rather than assume a device model.
        parsed = re.findall(r'identifier=(\d+).*?name=[\'\"]?([^}\n]+)', states)
        folded = next((i for i, name in parsed if 'CLOSED' in name.upper() or 'FOLDED' in name.upper()), None)
        opened = next((i for i, name in parsed if 'OPEN' in name.upper() or 'UNFOLDED' in name.upper()), None)
        assert folded is not None and opened is not None, 'AVD does not expose folded/open states'
        for name, identifier in (('folded', folded), ('unfolded', opened)):
            adb('shell', 'cmd', 'device_state', 'state', identifier)
            wait('Pause recording notes'); shot(name)
        click('Stop recording notes'); wait('Stopped')

    try:
        attempt('floating', floating)
        for key, value in original.items():
            adb('shell', 'settings', 'put', 'secure', key, value if value != 'null' else ':')
        attempt('talkback', talkback)
        for key, value in original.items():
            adb('shell', 'settings', 'put', 'secure', key, value if value != 'null' else ':')
        attempt('font200', font200)
        attempt('fold', fold)
    finally:
        adb('shell', 'cmd', 'device_state', 'state', 'reset')
        if font == 'null': adb('shell', 'settings', 'delete', 'system', 'font_scale')
        else: adb('shell', 'settings', 'put', 'system', 'font_scale', font)
        for key, value in original.items():
            if value == 'null': adb('shell', 'settings', 'delete', 'secure', key)
            else: adb('shell', 'settings', 'put', 'secure', key, value)
        (output / 'device-results.json').write_text(json.dumps(results, indent=2) + '\n')
    assert all(value == 'PASS' for value in results.values()), 'Device checks failed; see device-results.json'
