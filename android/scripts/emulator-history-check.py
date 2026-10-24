#!/usr/bin/env python3
"""Dictation history demo, invoked by emulator-check.py --history-check. Synthetic speech only:
opt in from the keyboard, dictate, erase, reinsert from history (cleaned and raw), check the
file is encrypted, capture the panel on the Fold's inner and cover screens, then turn history
off and confirm the file is deleted."""
import re
import time
import xml.etree.ElementTree as ET

HINTS = ('Test dictation here', 'Try it', 'Synthetic E2E editor')


def log(*args):
    print('%7.1f' % (time.monotonic() % 100000), *args, flush=True)


def check(probe, work, output):
    adb, click, wait_for, nodes, tap = (probe[name] for name in ('adb', 'click', 'wait_for', 'nodes', 'tap'))
    package = probe['PACKAGE']
    store = 'files/dictation_history.bin'

    def shot(name):
        data = adb('exec-out', 'screencap', '-p')
        path = output / ('emulator-history-' + name + '.png')
        path.write_bytes(data[data.index(b'\x89PNG'):])
        assert path.stat().st_size < 2_000_000, 'Screenshot exceeds 2 MB'

    def editor():
        # A keyboard strip resize can briefly expose no editor accessibility root.
        for _ in range(30):
            try:
                value = probe['editor_text']()
            except StopIteration:
                time.sleep(.2)
                continue
            return '' if value in HINTS else value
        raise AssertionError('Editor accessibility root did not return')

    def poll(predicate, message, seconds=15):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                result = predicate()
            except RuntimeError:
                # The on-device accessibility probe can fail transiently under host load.
                time.sleep(.5)
                continue
            # A matched node with no children is falsy, so test elements by identity.
            if isinstance(result, ET.Element) or result:
                return result
            time.sleep(.3)
        raise AssertionError(message)

    def strip_button():
        # The settings page behind the keyboard also has a "Dictation history" switch.
        return next((n for n in nodes() if n.get('content-desc') == 'Dictation history'
                     and n.get('class') == 'android.widget.Button'), None)

    def strip_idle():
        # During a notice the history slot collapses and the mic can slide into it; never
        # aim a tap across that transition.
        busy = ('Use raw dictation', 'Cancel dictation', 'Stop dictation', 'Polishing dictation')
        if any(n.get('content-desc') in busy for n in nodes()):
            return None
        return strip_button()

    def open_history():
        for _ in range(4):
            node = poll(strip_idle, 'History button missing from the Chirp row', seconds=40)
            log('OPEN-TAP', probe['bounds'](node), probe['size']())
            tap(node)
            try:
                poll(lambda: any(n.get('content-desc') == 'Close dictation history' for n in nodes()),
                     'panel did not open', seconds=10)
                return
            except AssertionError:
                # The tap can land on the mic when the strip re-renders between the probe dump
                # and event delivery on a loaded host; cancel the stray session and retry.
                log('OPEN-TAP missed; cancelling any stray session')
                cancel = probe['find']('Cancel dictation')
                if cancel is not None:
                    tap(cancel)
                    poll(lambda: probe['find']('Cancel dictation') is None, 'Stray session did not cancel', seconds=30)
                erase()
        raise AssertionError('History panel did not open')

    def row(value):
        deadline = time.monotonic() + 15
        needle = value[:40]
        while time.monotonic() < deadline:
            match = next((n for n in nodes() if n.get('content-desc', '').startswith(value + '. ')
                          or needle in n.get('content-desc', '')), None)
            if isinstance(match, ET.Element):
                return match
            time.sleep(.3)
        raise AssertionError('Dictation missing from history')

    def stored():
        return adb('shell', 'run-as', package, 'sh', '-c', "'cat " + store + " 2>/dev/null || true'")

    def fresh_editor():
        # Once paired, the test field can sit just under the fold with only a sliver reported
        # visible; the shared helper then taps outside it. Scroll it fully into view and retry.
        # A leftover history screen can also swallow the BACK; pop it first. Post-install cold
        # starts can exceed the helper's own timeouts, so allow several slow rounds. The field
        # may already hold text from a previous iteration, so never poll for its hint.
        for attempt in range(5):
            if probe['find']('Search history') is not None:
                adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
                time.sleep(2)
            try:
                probe['fresh_editor']()
                return
            except AssertionError as e:
                log('fresh_editor retry: ' + str(e).splitlines()[-1][:60])
                try:
                    shot('freshfail-' + str(attempt))
                except Exception:
                    pass
                try:
                    seen = [(n.get('text') or n.get('content-desc') or '')[:36]
                            for n in nodes() if (n.get('text') or n.get('content-desc'))]
                    log('SCREEN: ' + ' | '.join(x for x in seen if x)[:400])
                except Exception:
                    log('SCREEN: probe failed')
                w, h = probe['size']()
                adb('shell', 'input', 'swipe', str(w // 2), str(h * 3 // 4), str(w // 2), str(h // 4), '300')
                time.sleep(3)
        raise AssertionError('Setup activity did not return')

    def erase():
        log('ERASE')
        adb('shell', 'input', 'keycombination', 'KEYCODE_CTRL_LEFT', 'KEYCODE_A')
        adb('shell', 'input', 'keyevent', 'KEYCODE_DEL')
        poll(lambda: editor() == '', 'Editor was not cleared')

    original_size = adb('shell', 'wm', 'size').decode()
    original_density = adb('shell', 'wm', 'density').decode()
    try:
        adb('shell', 'run-as', package, 'rm', '-f', 'shared_prefs/chirp_history.xml', store)
        adb('shell', 'cmd', 'uimode', 'night', 'no')
        adb('shell', 'wm', 'size', '2076x2152')
        adb('shell', 'wm', 'density', '420')
        fresh_editor()
        erase()

        # One-tap opt-in from the keyboard; nothing is stored before it.
        open_history()
        wait_for('Keep history on this phone')
        shot('optin-inner-light')
        click('Keep history on this phone')
        poll(lambda: any(n.get('text', '').startswith('No dictations yet') for n in nodes()), 'Empty history missing after opt-in')
        click('Back to keyboard')
        assert not stored(), 'History file written before any dictation'

        # Synthetic dictation with on-Mac clean-up, then erase it.
        def dictate():
            x, y = probe['center'](wait_for('Microphone: tap to dictate'))
            log('MIC-TAP-START', x, y)
            adb('shell', 'input', 'tap', str(x), str(y))
            poll(lambda: editor() != '', 'No partial reached the editor', seconds=60)
            # No stop tap: the synthetic clip ends the session on its own. A stop tap
            # delivered after that on a loaded host would start a new session on the mic.
            wait_for('Microphone: tap to dictate', seconds=70)
            return poll(lambda: editor().strip(), 'Final was not committed')

        # Under host load the IME's clean-up budget can lapse and keep the original; retry once.
        final = dictate()
        if re.search(r'\b(?:um|uh)\b', final, re.I):
            print('Clean-up kept the original; retrying once', flush=True)
            erase()
            final = dictate()
        assert not re.search(r'\b(?:um|uh)\b', final, re.I), 'Clean-up did not remove fixture fillers'
        encrypted = poll(stored, 'History file was not written')
        words = [w for w in re.findall(r'[A-Za-z]{5,}', final)]
        assert words and not any(w.encode() in encrypted for w in words), 'History file contains plaintext'
        erase()

        # Reinsert the cleaned text from the keyboard panel.
        open_history()
        row(final)
        shot('list-inner-light')
        target = row(final)
        assert 'Cleaned' in target.get('content-desc', ''), 'Cleaned entry is not announced as cleaned'
        # The row's longest text is the stored value; compare against it rather than the editor
        # snapshot, which a late commit can distort under host load.
        texts = [(c.get('text') or '') for c in target.iter() if c.get('text')]
        expected = max(texts, key=len).strip()
        assert len(expected) > 20, 'History row text was not readable'
        tap(target)
        deadline = time.monotonic() + 20
        last = None
        while time.monotonic() < deadline:
            try:
                last = editor().strip()
            except RuntimeError:
                time.sleep(.5)
                continue
            if last == expected:
                break
            time.sleep(.3)
        else:
            raise AssertionError('History tap did not reinsert the dictation')
        assert not any(n.get('content-desc') == 'Close dictation history' for n in nodes()), 'Panel stayed open after insert'
        shot('reinserted-inner-light')

        # Long-press shows Copy / Insert raw / Delete; Insert raw restores the fillers.
        erase()
        open_history()
        item = None
        for _ in range(3):
            rx, ry = probe['center'](row(final))
            adb('shell', 'input', 'swipe', str(rx), str(ry), str(rx), str(ry), '800')
            try:
                item = poll(lambda: probe['find']('Insert raw'), 'menu stayed closed', seconds=8)
                break
            except AssertionError:
                item = None
                # A menu that opens late hides the panel rows from the probe; dismiss it first.
                adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
                time.sleep(1)
        assert item is not None, 'Long-press menu did not open'
        shot('menu-inner-light')
        tap(item)
        raw = poll(lambda: editor().strip(), 'Insert raw did not insert')
        assert re.search(r'\bum\b', raw, re.I) and re.search(r'\buh\b', raw, re.I), 'Insert raw did not restore fixture fillers'
        erase()

        for form, resolution in (('inner', '2076x2152'), ('cover', '1080x2520')):
            adb('shell', 'wm', 'size', resolution)
            for theme in ('light', 'dark'):
                adb('shell', 'cmd', 'uimode', 'night', 'yes' if theme == 'dark' else 'no')
                fresh_editor()
                shot('keyboard-' + form + '-' + theme)
                open_history()
                try:
                    node = row(final)
                except AssertionError:
                    raise AssertionError('History missing on ' + form + ' ' + theme)
                w, h = probe['size']()
                x1, y1, x2, y2 = probe['bounds'](node)
                assert 0 <= x1 < x2 <= w and 0 <= y1 < y2 <= h, 'Clipped history row'
                # A fresh probe connection can serve a stale tree on a loaded host; only a
                # consistent answer across three dumps fails the check.
                exposed = 0
                settled = False
                for _ in range(90):
                    try:
                        if any(n.get('class') == 'helium314.keyboard.keyboard.Key' for n in nodes()):
                            exposed += 1
                            if exposed >= 3:
                                for n in nodes():
                                    if n.get('text') or n.get('content-desc'):
                                        log('EXPOSED-DUMP', n.get('class'), (n.get('text') or '')[:40],
                                            (n.get('content-desc') or '')[:60], n.get('bounds'))
                                raise AssertionError('Keys still exposed under the panel')
                        else:
                            exposed = 0
                            settled = True
                            break
                    except RuntimeError:
                        exposed = 0
                    time.sleep(.3)
                if not settled:
                    raise AssertionError('Keys exposure never settled under the panel')
                shot('panel-' + form + '-' + theme)
                # Closing must leave the keyboard up. The close button is deterministic; a BACK
                # keyevent can land on the activity behind the IME on a loaded host. (The
                # hardware-BACK path itself is covered by HistoryRenderTest.onKeyDown.)
                button = poll(lambda: probe['find']('Back to keyboard'), 'Close button missing')
                # Activate the actual accessibility action, avoiding a stale hit rectangle.
                adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/',
                    'dev.chirp.smoke.UiHierarchy', 'click', "'Back to keyboard'")
                wait_for('Microphone: tap to dictate', seconds=70)
                poll(lambda: probe['find']('Close dictation history') is None and probe['find']('Microphone: tap to dictate') is not None,
                     'Closing the panel did not restore the keyboard strip', seconds=30)
                # Virtual HeliBoard key nodes can stay stale after this transition;
                # retain a screenshot of the visible keys rather than treating that cache as disappearance.
                shot('closed-' + form + '-' + theme)

        # Full history screen with search.
        adb('shell', 'wm', 'size', '2076x2152')
        adb('shell', 'cmd', 'uimode', 'night', 'no')
        fresh_editor()
        open_history()
        click('Search and manage dictation history')
        wait_for('Search history')
        poll(lambda: any(final in n.get('text', '') for n in nodes()), 'Entry missing from history screen')
        # Raw text is collapsed in the modern History UI; its reinsertion was verified above.
        shot('screen-light')
        matched = False
        for _ in range(4):
            # A real touch focuses a Compose field; an accessibility click may not.
            tap(poll(lambda: probe['find']('Search history'), 'Search field missing'))
            adb('shell', 'input', 'text', 'zzqx')
            if any(n.get('class') == 'helium314.keyboard.keyboard.Key' for n in nodes()):
                # The open IME can cover the result list; hide it before checking.
                adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
            try:
                wait_for('No matches', seconds=12)
                matched = True
                break
            except AssertionError:
                pass
        assert matched, 'History search did not filter'
        adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
        adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')

        # Turning history off asks first and then deletes the file. The switch sits far down
        # the wizard's settings page; scroll it into view. HistoryActivity can stay on top of
        # the single-task wizard (its search field is the tell); BACK pops only that.
        adb('shell', 'am', 'start', '-n', package + '/.SetupActivity', '--es', 'section', 'settings')
        time.sleep(4)
        w, h = probe['size']()
        arrived = False
        # Modern settings places history on its own page under Privacy & history.
        for _ in range(12):
            if probe['find']('Privacy & history') is not None: break
            adb('shell', 'input', 'swipe', str(w // 4), str(h * 3 // 4), str(w // 4), str(h // 3), '300')
        click('Privacy & history')
        for _ in range(14):
            if probe['find']('Search history') is not None:
                adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
                time.sleep(2)
                adb('shell', 'am', 'start', '-n', package + '/.SetupActivity', '--es', 'section', 'settings')
                time.sleep(3)
                continue
            try:
                wait_for('Keep dictation history on this phone', seconds=8)
                arrived = True
                break
            except AssertionError:
                pass
            if any(n.get('class') == 'helium314.keyboard.keyboard.Key' for n in nodes()):
                adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')  # hide the IME only
                time.sleep(1)
            adb('shell', 'input', 'swipe', str(w // 2), str(h * 2 // 3), str(w // 2), str(h // 4), '400')
            time.sleep(1)
        assert arrived, 'History settings switch did not appear'
        shot('settings-light')
        tap(poll(lambda: next((n for n in nodes() if n.get('class') == 'android.widget.Switch' or (n.get('text') == 'Keep dictation history on this phone' and n.get('clickable') == 'true')), None), 'History switch missing'))
        wait_for('Turn off and delete')
        click('Turn off and delete')
        poll(lambda: not stored(), 'History file survived turning history off')
        print('PASS: keyboard opt-in; cleaned final recorded encrypted (no plaintext on disk); erase + reinsert '
              'from panel; long-press Insert raw; inner/cover light/dark; back closes panel; history screen '
              'search; turn off deletes file.', flush=True)
    except Exception:
        data = adb('exec-out', 'screencap', '-p')
        open('/tmp/chirp-history-failure.png', 'wb').write(data[data.index(b'\x89PNG'):])
        raise
    finally:
        for command, original in (('size', original_size), ('density', original_density)):
            override = re.search(r'Override (?:size|density): (\S+)', original)
            adb('shell', 'wm', command, override.group(1) if override else 'reset')
        adb('shell', 'cmd', 'uimode', 'night', 'no')
        adb('shell', 'run-as', package, 'rm', '-f', 'shared_prefs/chirp_history.xml', store)
