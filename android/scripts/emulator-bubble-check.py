#!/usr/bin/env python3
"""Floating mic bubble (#167) on a disposable emulator, through emulator-check.py --keepkb-check or --bubble-check.

Debug APK, synthetic speech and #166's EditorProbeActivity only. Field and clipboard text is never printed or
kept: checks read lengths and states. The caller owns the throwaway server (m['stop_server'] stops it).
"""
from pathlib import Path
import re
import shlex
import time

PACKAGE = 'dev.chirp.android'
CHIRP = PACKAGE + '/.ChirpImeService'
GBOARD = 'com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME'
SERVICE = PACKAGE + '/.ChirpAccessibilityService'
PROBE = PACKAGE + '/.EditorProbeActivity'
BUBBLE = 'Chirp microphone'
COPY_MODE = "Chirp microphone — this field can't be filled automatically"
COULDNT = "Couldn't put this in the field"
CANT = "This field can't be filled automatically"


def present(found):
    """ElementTree leaves are falsy, so presence is spelled out: anything but None, False or ''."""
    return found is not None and found is not False and found != ''


def bounds(node):
    return tuple(map(int, re.findall(r'-?\d+', node.get('bounds', ''))))


def center(node):
    x1, y1, x2, y2 = bounds(node)
    return (x1 + x2) // 2, (y1 + y2) // 2


class Bubble:
    def __init__(self, m, output):
        self.m, self.adb, self.output = m, m['adb'], output
        self.results = []

    # ---- UI helpers ------------------------------------------------------------------------------------------
    def nodes(self):
        return self.m['nodes']()

    def bubble(self, hierarchy=None):
        return next((n for n in (hierarchy or self.nodes()) if n.get('content-desc', '').startswith(BUBBLE)), None)

    def wait(self, test, what, seconds=30):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            hierarchy = self.nodes()
            found = test(hierarchy)
            if present(found):
                return found
            time.sleep(.2)
        self.capture('failure-' + re.sub(r'\W+', '-', what.lower()).strip('-'), keep=False)
        raise AssertionError('Missing state: ' + what)

    def label(self, text, seconds=30):
        return self.wait(lambda h: next((n for n in h if n.get('text') == text or n.get('content-desc', '').startswith(text)), None), text, seconds)

    def gone(self, test, what, seconds=10):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if not present(test(self.nodes())):
                return
            time.sleep(.2)
        raise AssertionError('Still shown: ' + what)

    def tap(self, node):
        self.adb('shell', 'input', 'tap', *map(str, center(node)))

    def press(self, text):
        self.tap(self.label(text))

    def probe_field(self, label):
        """Opens the probe and focuses one of its fields by tapping it, like a person would."""
        self.adb('shell', 'am', 'start', '-W', '--activity-clear-task', '-n', PROBE)
        # The report line changes once used; the Recognize button is always there.
        self.label('Recognize')
        field = self.label(label)
        self.tap(field)
        # Let the tap's caret move land first: a caret that moves after the bubble's snapshot is (rightly) a changed field.
        time.sleep(1.2)
        return field

    def field_state(self, label):
        node = next((n for n in self.nodes() if n.get('content-desc') == label or n.get('text') == label or
                     (n.get('class', '').endswith('EditText') and label in n.get('content-desc', ''))), None)
        assert node is not None, 'Field missing: ' + label
        return len(node.get('text', '')), node.get('selection', '')

    def plain_digest(self):
        """A digest of the plain field, to tell two values apart without ever printing either."""
        import hashlib
        editors = [n for n in self.nodes() if n.get('class') == 'android.widget.EditText' and n.get('package') == PACKAGE]
        return hashlib.sha256(editors[0].get('text', '').encode()).hexdigest() if editors else ''

    def plain_length(self):
        editors = [n for n in self.nodes() if n.get('class') == 'android.widget.EditText' and n.get('package') == PACKAGE]
        assert editors, 'Probe editor missing'
        node = editors[0]
        hint = node.get('text', '') == 'Plain field'
        return 0 if hint else len(node.get('text', '')), node.get('selection', '')

    def change_while_live(self):
        """Tap the bubble, then type into the field right after the snapshot: the final can't go in and must wait."""
        self.tap(self.wait(self.bubble, 'bubble'))
        time.sleep(.5)
        self.adb('shell', 'input', 'text', 'x')

    def click_now(self, label):
        """One accessibility click by label, without a hierarchy round trip; False when it isn't there."""
        # An absent optional target is a successful probe result, not an adb failure.
        # In particular, never turn exit 137 into a claim that clean-up changed nothing.
        result = self.adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/',
                          'dev.chirp.smoke.UiHierarchy', 'click-if-present', shlex.quote(label))
        return b'MISSING' not in result

    def no_microphone_service(self, where):
        services = self.adb('shell', 'dumpsys', 'activity', 'services', PACKAGE)
        assert b'isForeground=true' not in services, 'Foreground service still running: ' + where
        audio = self.adb('shell', 'dumpsys', 'audio')
        recording = audio.split(b'RecordActivityMonitor', 1)[-1].split(b'\n\n', 1)[0]
        assert PACKAGE.encode() not in recording, 'Recording client still open: ' + where
        crash = self.adb('logcat', '-b', 'crash', '-d').decode(errors='replace')
        # The app's own process only; the shell UI probe is dev.chirp.smoke and runs as shell.
        assert not re.search(r'>>> dev\.chirp\.android <<<|Process: dev\.chirp\.android', crash), 'Chirp crash: ' + where

    def capture(self, name, keep=True):
        data = self.adb('exec-out', 'screencap', '-p')
        target = (self.output / ('emulator-floating-' + name + '.png')) if keep else Path('/tmp/chirp-bubble-' + name + '.png')
        target.write_bytes(data[data.index(b'\x89PNG'):])
        assert target.stat().st_size < 2_000_000, 'Screenshot over 2 MB'

    def dictate(self, field_label, stop=True):
        """Tap the bubble, wait for a non-empty partial (length only), optionally Stop."""
        self.tap(self.wait(self.bubble, 'bubble'))
        self.label('Listening…', 40)
        # A partial: some panel text beyond the fixed labels (and the probe's own report line); its length only.
        fixed = ('', 'Start speaking…', 'Listening', 'Cancel', 'Stop', 'Probe ready', 'Connecting to your computer…')
        self.wait(lambda h: any(n.get('content-desc', '') == '' and n.get('text', '') not in fixed
                                and not n.get('text', '').startswith(('Paste length', 'Recognize'))
                                and n.get('package') == PACKAGE and n.get('class') == 'android.widget.TextView'
                                and bounds(n)[1] > 0 for n in h), 'partial', 40)
        # The synthetic clip ends by itself, so the utterance may already be finishing: Stop only if it's still there.
        if stop and (button := self.m['find']('Stop dictation')) is not None:
            self.tap(button)

    # ---- Cases ----------------------------------------------------------------------------------------------
    def show_and_hide(self):
        self.probe_field('Plain field')
        self.wait(self.bubble, 'bubble on plain field')
        self.adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        self.gone(self.bubble, 'bubble after Home')
        self.probe_field('Password field')
        time.sleep(1.5)
        assert self.bubble() is None, 'Bubble shown on a password field'
        self.no_microphone_service('show/hide')
        self.results.append('show/hide (plain, Home, password)')

    def drag(self):
        self.probe_field('Plain field')
        start = self.wait(self.bubble, 'bubble')
        width, height = self.m['size']()
        x, y = center(start)
        assert x > width // 2, 'Default bubble should be on the right edge'
        # A slow swipe: well past the 8 dp slop before 250 ms, released at a third of the width.
        self.adb('shell', 'input', 'swipe', str(x), str(y), str(width // 3), str(y + 120), '700')
        self.no_microphone_service('during drag')
        moved = self.wait(lambda h: (b := self.bubble(h)) is not None and center(b)[0] < width // 2 and b, 'bubble at left edge')
        assert bounds(moved)[0] <= 8, 'Bubble did not snap to the left edge'
        self.no_microphone_service('after drag')
        self.adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        self.probe_field('Plain field')
        kept = self.wait(self.bubble, 'bubble after refocus')
        assert center(kept)[0] < width // 2, 'Dropped position did not persist'
        # The other screen posture keeps its own spot: unfold to the inner size and back.
        original = self.adb('shell', 'wm', 'size').decode()
        try:
            self.adb('shell', 'wm', 'size', '1080x2092' if width > 1500 else '2208x1840')
            time.sleep(2)
            self.probe_field('Plain field')
            other = self.wait(self.bubble, 'bubble on the other posture')
            other_width = self.m['size']()[0]
            assert center(other)[0] > other_width // 2, 'Other posture should keep its own (default right) spot'
            self.capture('other-posture', keep=False)
        finally:
            override = re.search(r'Override size: (\S+)', original)
            self.adb('shell', 'wm', 'size', override.group(1) if override else 'reset')
            time.sleep(2)
        self.probe_field('Plain field')
        back = self.wait(self.bubble, 'bubble back on the first posture')
        assert center(back)[0] < self.m['size']()[0] // 2, 'First posture lost its spot'
        # Put it back on the right for the remaining cases.
        bx, by = center(back)
        self.adb('shell', 'input', 'swipe', str(bx), str(by), str(self.m['size']()[0] * 3 // 4), str(by), '700')
        self.wait(lambda h: (b := self.bubble(h)) is not None and center(b)[0] > self.m['size']()[0] // 2, 'bubble back right')
        self.results.append('drag: no FGS/recording, snap, persisted, separate posture')

    FILLERS = re.compile(r'\b(?:um|uh)\b', re.I)

    def has_fillers(self, hierarchy=None):
        """Whether the plain field holds a spoken filler of the synthetic fixture (a boolean; the text is never kept)."""
        editors = [n for n in (hierarchy or self.nodes()) if n.get('class') == 'android.widget.EditText' and n.get('package') == PACKAGE]
        return bool(editors) and bool(self.FILLERS.search(editors[0].get('text', '')))

    def await_action(self, mode, label, seconds):
        """#183: one tight-polling probe for the transient action; a probe failure raises instead of reading as 'not offered'."""
        result = self.adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/', 'dev.chirp.smoke.UiHierarchy',
                          'await-action', mode, shlex.quote(label), str(seconds * 1000)).decode().strip()
        assert result.split(' ')[0] in ('PRESENT', 'CLICKED', 'EXPIRED'), 'Probe returned no verdict: ' + result[:80]
        return result

    def use_raw_replacement(self):
        """Native bubble: Use raw replaces a cleaned insertion with the raw words, deterministically.

        The synthetic fixture says "Um … a, a … Uh … the, the", and managed clean-up (warmed, asserted corrected) removes
        them, so the cleaned final always differs from the raw. The probe starts before the final exists and clicks the
        instant the 5 s action appears, so no hierarchy dump can eat the window; each failure says which thing went wrong.
        """
        self.probe_field('Plain field')
        assert not self.has_fillers(), 'Fixture: the field must start without fillers'
        self.tap(self.wait(self.bubble, 'bubble'))
        result = self.await_action('click', 'Use raw', 90)
        if result.startswith('EXPIRED'):
            if 'fillers_before=true' in result:
                raise AssertionError('Clean-up returned the raw text: the fixture was not corrected (not a Use raw failure)')
            raise AssertionError('Clean-up changed the text but Use raw was never offered')
        assert result == 'CLICKED fillers_before=false', 'Use raw was offered over uncleaned text: ' + result
        self.wait(self.has_fillers, 'raw words back in the field', 20)
        self.no_microphone_service('after Use raw')
        self.results.append('Use raw (cleaned differed from raw) replaced the cleaned text with the raw words')

    def use_raw_expiry(self):
        """The same fixture, left alone: Use raw goes away after 5 s and the cleaned text stays (expired, not unchanged)."""
        self.probe_field('Plain field')
        self.tap(self.wait(self.bubble, 'bubble'))
        result = self.await_action('observe', 'Use raw', 90)
        assert result == 'PRESENT fillers_before=false', 'Use raw not offered over cleaned text: ' + result
        time.sleep(5.5)
        assert not self.click_now('Use raw'), 'Use raw outlived 5 s'
        assert not self.has_fillers(), 'Expiry must keep the cleaned text'
        self.no_microphone_service('after Use raw expiry')
        self.results.append('Use raw expired after 5 s and kept the cleaned text')

    def dictate_insert(self, cleanup_warm):
        self.probe_field('Plain field')
        before, _ = self.plain_length()
        self.dictate('Plain field')
        self.wait(lambda h: self.plain_length()[0] > before, 'field grew', 60)
        after, selection = self.plain_length()
        assert after > before, 'Field did not grow'
        assert selection == f'{after},{after}', 'Caret not at the end of the insertion'
        self.no_microphone_service('after insert')
        self.results.append('dictate: Listening, partial, inserted at caret')
        if cleanup_warm:
            self.use_raw_replacement()
            self.use_raw_expiry()

    def field_changed(self):
        self.probe_field('Plain field')
        self.change_while_live()
        self.label(COULDNT, 90)
        self.capture('ready', keep=False)
        self.press('Copy')
        self.gone(lambda h: any(n.get('text') == COULDNT for n in h), 'Ready to copy panel')
        self.press('Paste and report length')
        report = self.wait(lambda h: next((n for n in h if n.get('text', '').startswith('Paste length=')), None), 'paste report')
        text = report.get('text')
        length = int(re.search(r'Paste length=(\d+)', text).group(1))
        assert length > 0 and 'sensitive=true' in text, 'Copy did not leave a sensitive clip'
        self.no_microphone_service('field changed')
        self.results.append('field changed while finishing → Ready to copy; Copy → sensitive clip')

    def copy_mode(self):
        self.probe_field('Editable without set text')
        self.wait(lambda h: (b := self.bubble(h)) is not None and b.get('content-desc', '').startswith(COPY_MODE) and b, 'copy-mode badge')
        self.capture('copy-mode-bubble', keep=False)
        self.dictate('Editable without set text')
        self.label(CANT, 60)
        self.press('Open in Scratchpad')
        self.wait(lambda h: any(n.get('package') == PACKAGE and n.get('class') == 'android.widget.EditText' and n.get('text', '') not in ('', 'Dictate, then edit here') for n in h),
                  'Scratchpad with the words', 20)
        self.no_microphone_service('copy mode')
        self.adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
        self.results.append('copy mode badge → Ready to copy → Scratchpad has the words')

    def web_field(self):
        """Records the WebView outcome (the spec asks which); Chromium's textarea node comes and goes, so this never fails the run."""
        self.adb('shell', 'am', 'start', '-W', '--activity-clear-task', '-n', PROBE)
        self.label('Recognize')
        def textarea(h):
            return next((n for n in h if n.get('class') == 'android.widget.EditText' and n.get('package') == PACKAGE
                         and n.get('content-desc', '') == ''), None)
        try:
            self.tap(self.wait(textarea, 'web textarea', 15))
            bubble = self.wait(self.bubble, 'bubble on the web textarea', 15)
        except AssertionError:
            self.results.append('WebView textarea → no bubble (Chromium did not report it as the input focus)')
            return
        mode = 'copy mode' if bubble.get('content-desc', '').startswith(COPY_MODE) else 'insert'
        self.dictate('Web field')
        state = self.wait(lambda h: next((n.get('text') for n in h if n.get('text') in ('Finished', COULDNT, CANT)), None),
                          'WebView outcome', 60)
        self.results.append(f'WebView textarea ({mode}) → ' + ('inserted' if state == 'Finished' else 'Ready to copy'))
        if state != 'Finished':
            self.press('Done')
        self.no_microphone_service('web field')

    def errors(self):
        self.adb('shell', 'pm', 'revoke', PACKAGE, 'android.permission.RECORD_AUDIO')
        try:
            time.sleep(2)  # Revoking restarts the process; the service rebinds.
            self.probe_field('Plain field')
            self.tap(self.wait(self.bubble, 'bubble after revoke', 40))
            self.label('Allow the microphone for Chirp')
            assert self.m['find']('Allow') is not None
            self.capture('error-microphone', keep=False)
            self.press('Hide panel')
        finally:
            self.adb('shell', 'pm', 'grant', PACKAGE, 'android.permission.RECORD_AUDIO')
        self.m['stop_server']()
        time.sleep(1)
        self.probe_field('Plain field')
        self.tap(self.wait(self.bubble, 'bubble with the Mac offline', 40))
        self.label('Check again', 40)
        self.capture('error-offline', keep=False)
        self.press('Hide panel')
        self.no_microphone_service('errors')
        self.results.append('errors: Allow (mic revoked), Check again (server stopped)')

    def scratchpad_field(self):
        """Chirp's own Scratchpad as the backdrop for captures: a real editor, and unlike the probe not FLAG_SECURE."""
        # Not exported: reached the way a person does, from Notes' Dictate action (as the release smoke does).
        self.adb('shell', 'am', 'start', '-W', '-n', PACKAGE + '/.SetupActivity', '--es', 'section', 'try')
        self.press('Dictate')
        field = self.label('Dictate, then edit here')
        self.tap(field)
        time.sleep(1.2)

    def captures(self):
        """Idle, listening and Ready to copy over the Scratchpad, on the inner screen and the cover size, light and dark."""
        original = self.adb('shell', 'wm', 'size').decode()
        try:
            for screen, size in (('inner', None), ('cover', '1080x2092')):
                if size:
                    self.adb('shell', 'wm', 'size', size); time.sleep(2)
                for night in ('no', 'yes'):
                    self.adb('shell', 'cmd', 'uimode', 'night', night); time.sleep(1.5)
                    theme = 'dark' if night == 'yes' else 'light'
                    self.scratchpad_field()
                    self.wait(self.bubble, 'bubble'); time.sleep(.6)
                    self.capture(f'idle-{screen}-{theme}')
                    # Typing while live sends the final to Ready to copy, the never-lost state.
                    self.change_while_live()
                    self.label('Listening…', 40)
                    self.capture(f'listening-{screen}-{theme}')
                    self.label(COULDNT, 90); time.sleep(.4)
                    self.capture(f'ready-{screen}-{theme}')
                    self.press('Done')
                    self.no_microphone_service('captures')
                    # Back, not force-stop: force-stopping the package also unbinds the accessibility service.
                    self.adb('shell', 'input', 'keyevent', 'KEYCODE_BACK'); self.adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
        finally:
            self.adb('shell', 'cmd', 'uimode', 'night', 'no')
            override = re.search(r'Override size: (\S+)', original)
            self.adb('shell', 'wm', 'size', override.group(1) if override else 'reset')
        self.results.append('captures: idle, listening, Ready to copy over the Scratchpad; inner and cover; light and dark')

    def talkback_labels(self):
        """The bubble's TalkBack contract without TalkBack running: a button with both custom actions."""
        self.probe_field('Plain field')
        node = self.wait(self.bubble, 'bubble')
        assert node.get('clickable') == 'true'
        assert node.get('actions') == 'Move to other side|Hide in this app', 'Bubble custom actions missing'
        x = center(node)[0]
        self.adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/', 'dev.chirp.smoke.UiHierarchy',
                 'custom-action', shlex.quote(BUBBLE), shlex.quote('Move to other side'))
        width = self.m['size']()[0]
        self.wait(lambda h: (b := self.bubble(h)) is not None and (center(b)[0] < width // 2) != (x < width // 2), 'moved to other side')
        self.adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/', 'dev.chirp.smoke.UiHierarchy',
                 'custom-action', shlex.quote(BUBBLE), shlex.quote('Move to other side'))
        self.adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/', 'dev.chirp.smoke.UiHierarchy',
                 'custom-action', shlex.quote(BUBBLE), shlex.quote('Hide in this app'))
        self.gone(self.bubble, 'bubble after Hide in this app')
        self.adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        self.probe_field('Plain field')
        self.wait(self.bubble, 'bubble back after leaving the app')
        self.results.append('TalkBack contract: button, Move to other side, Hide in this app (until the app leaves)')


def prepare(m, base, token):
    """Standalone setup for --bubble-check: pairing first, then Gboard, the service, microphone and synthetic speech."""
    import urllib.parse
    adb = m['adb']
    adb('shell', 'settings', 'delete', 'secure', 'enabled_accessibility_services')
    # A clean app: an earlier run's pairing would otherwise satisfy the wait below before this server's lands.
    adb('shell', 'pm', 'clear', PACKAGE)
    adb('shell', 'run-as', PACKAGE, 'mkdir', '-p', 'shared_prefs')
    adb('shell', 'run-as', PACKAGE, 'sh', '-c', shlex.quote('cat > shared_prefs/debug_capture.xml'),
        data=b'<map><boolean name="synthetic" value="true" /></map>')
    for permission in ('RECORD_AUDIO', 'ACCESS_LOCAL_NETWORK', 'POST_NOTIFICATIONS'):
        adb('shell', 'pm', 'grant', PACKAGE, 'android.permission.' + permission)
    link = 'chirp://pair?' + urllib.parse.urlencode({'url': base, 'token': token})
    # adb echoes the intent; never forward its output.
    adb('shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', shlex.quote(link))
    # Saved pairing shows up as the encrypted token key; its value is never read out.
    deadline = time.monotonic() + 40
    while b'name="token"' not in adb('shell', 'run-as', PACKAGE, 'sh', '-c', shlex.quote('cat shared_prefs/chirp.xml 2>/dev/null; true')):
        assert time.monotonic() < deadline, 'Pairing was not saved'
        time.sleep(.5)
    # Close the pairing screen for good (it would come back over the probe), then turn the floating mic on.
    time.sleep(2)
    adb('shell', 'am', 'force-stop', PACKAGE)
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    adb('shell', 'ime', 'enable', GBOARD)
    adb('shell', 'ime', 'set', GBOARD)
    adb('shell', 'settings', 'put', 'secure', 'enabled_accessibility_services', SERVICE)
    adb('shell', 'settings', 'put', 'secure', 'accessibility_enabled', '1')
    time.sleep(2)


def check(m, work, output, base, token, cleanup_warm=False, standalone=False):
    adb = m['adb']
    if standalone:
        prepare(m, base, token)
    assert adb('shell', 'settings', 'get', 'secure', 'default_input_method').decode().strip() == GBOARD, 'Gboard must stay selected'
    adb('logcat', '-b', 'crash', '-c')
    run = Bubble(m, output)
    for case in (run.show_and_hide, run.drag, lambda: run.dictate_insert(cleanup_warm), run.field_changed, run.copy_mode,
                 run.web_field, run.captures, run.errors, run.talkback_labels):
        case()
    assert adb('shell', 'settings', 'get', 'secure', 'default_input_method').decode().strip() == GBOARD, 'Gboard was replaced'
    prefs = adb('shell', 'run-as', PACKAGE, 'sh', '-c', shlex.quote('cat shared_prefs/*.xml'))
    assert b'Synthetic' not in prefs and b'synthetic speech' not in prefs.lower(), 'Dictated text reached preferences'
    for line in run.results:
        print('  ·', line, flush=True)
    print('PASS: floating mic bubble checks; Gboard kept; no FGS, recording client or crash after each case; no text in prefs.', flush=True)
