#!/usr/bin/env python3
"""Match wallpaper (dynamic colour) on real system wallpapers, light and dark (#332).

Run through e2e-all.sh --only wallpaper, which owns the emulator. Each wallpaper is set through the
system wallpaper service, so Android extracts its colours exactly as it would from a person's photo;
the app's Match wallpaper scheme then comes from that extraction, not from a test fixture.
Captures are for human review; text-contrast-report.py measures the text in them afterwards.
"""
import json
import re
import shlex
import struct
import time
import zlib

# Photo-like gradients covering the extraction's range: warm, cool, green, pale (light) and near-black (dark).
WALLPAPERS = {
    'sunset': ((255, 183, 94), (214, 72, 96), (58, 32, 74)),
    'ocean': ((168, 222, 236), (28, 120, 168), (6, 36, 66)),
    'forest': ((120, 160, 84), (36, 84, 48), (10, 26, 16)),
    'snow': ((250, 251, 253), (226, 232, 240), (196, 206, 220)),
    'night': ((44, 40, 92), (20, 18, 46), (4, 4, 12)),
}


def png(top, middle, bottom, width=540, height=1260):
    """A vertical three-stop gradient with fine grain, so the quantiser sees a photo rather than flat fills."""
    rows = []
    for y in range(height):
        t = y / (height - 1)
        a, b, f = (top, middle, t * 2) if t < .5 else (middle, bottom, t * 2 - 1)
        base = [round(a[i] + (b[i] - a[i]) * f) for i in range(3)]
        row = bytearray(b'\0')
        for x in range(width):
            grain = ((x * 7919 + y * 104729) % 23) - 11
            row += bytes(max(0, min(255, c + grain)) for c in base)
        rows.append(bytes(row))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    header = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(b''.join(rows), 6)) + chunk(b'IEND', b'')


def check(p, work, output):
    adb, wait, click = (p[k] for k in ('adb', 'wait_for', 'click'))
    package = p['PACKAGE']
    captures, palettes = [], {}

    def start(activity='SetupActivity', section=None):
        adb('shell', 'am', 'force-stop', package)
        args = ['shell', 'am', 'start', '-n', package + '/.' + activity]
        if section: args += ['--es', 'section', section]
        adb(*args)

    def palette():
        return adb('shell', 'settings', 'get', 'secure', 'theme_customization_overlay_packages').decode().strip()

    def accent():
        """The system accent tone the app's dynamic primary is built from, when the overlay service reports it."""
        try: return adb('shell', 'cmd', 'overlay', 'lookup', 'android', 'android:color/system_accent1_600').decode().strip()
        except RuntimeError: return ''

    def shot(name):
        time.sleep(.6)
        data = adb('exec-out', 'screencap', '-p')
        file = f'{wallpaper}-{theme}-{name}'
        (output / (file + '.png')).write_bytes(data[data.index(b'\x89PNG'):])
        texts = [{'text': n.get('text') or n.get('content-desc'), 'bounds': p['bounds'](n)} for n in p['nodes']()
                 if n.get('package') == package and (n.get('text') or '').strip()]
        (output / (file + '.json')).write_text(json.dumps(texts, indent=1) + '\n')
        captures.append(file)
        print('CAPTURE:', file, flush=True)

    originals = {key: adb('shell', 'wm', key).decode() for key in ('size', 'density')}
    night = adb('shell', 'cmd', 'uimode', 'night').decode()
    try:
        # The cover screen, as the main visual check captures it.
        adb('shell', 'wm', 'size', '1080x2520'); adb('shell', 'wm', 'density', '420')
        # Choose Match wallpaper the way a person does: Settings → Feedback & look.
        start(section='settings'); wait('How you dictate')
        w, h = p['size']()
        for _ in range(8):
            if p['find']('Feedback & look') is not None: break
            adb('shell', 'input', 'swipe', str(w // 2), str(h * 3 // 4), str(w // 2), str(h // 3), '300')
        click('Feedback & look'); wait('Feedback & look')
        for _ in range(8):
            if p['find']('Match wallpaper') is not None: break
            adb('shell', 'input', 'swipe', str(w // 2), str(h * 3 // 4), str(w // 2), str(h // 3), '300')
        click('Match wallpaper')
        # A note with a heading, a task and body text, so the detail capture shows the editor's roles.
        start(section='try'); wait('Record new note')
        adb('shell', 'am', 'start', '-a', 'android.intent.action.SEND', '-t', 'text/plain',
            '--es', 'android.intent.extra.SUBJECT', shlex.quote('Wallpaper review'),
            '--es', 'android.intent.extra.TEXT', shlex.quote('Review the launch checklist.'),
            '-n', package + '/.ShareToNotesActivity')
        wait('Save to Notes'); click('Save as new note')
        for wallpaper, stops in WALLPAPERS.items():
            image = work / f'wallpaper-{wallpaper}.png'
            image.write_bytes(png(*stops))
            adb('push', str(image), '/data/local/tmp/chirp-wallpaper.png')
            before = palette()
            print(adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/',
                      'dev.chirp.smoke.UiHierarchy', 'set-wallpaper', '/data/local/tmp/chirp-wallpaper.png').decode().strip(), flush=True)
            # System UI applies new wallpaper colours when the screen next turns off: sleep, wake, unlock.
            deadline = time.monotonic() + 45
            while palette() == before and time.monotonic() < deadline:
                adb('shell', 'input', 'keyevent', 'KEYCODE_SLEEP'); time.sleep(2)
                adb('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP'); adb('shell', 'wm', 'dismiss-keyguard'); time.sleep(2)
            palettes[wallpaper] = {'overlay': palette(), 'accent1_600': accent()}
            print('PALETTE:', wallpaper, palettes[wallpaper]['overlay'], flush=True)
            if palettes[wallpaper]['overlay'] == before:
                raise AssertionError(f'{wallpaper}: System UI did not apply new wallpaper colours')
            for theme in ('light', 'dark'):
                adb('shell', 'cmd', 'uimode', 'night', 'yes' if theme == 'dark' else 'no')
                start(section='try'); wait('Record new note'); shot('notes-library')
                click('Wallpaper review'); wait('Review the launch checklist.'); shot('note-detail')
                start(section='history'); wait('Dictation history'); shot('history')
                start(section='settings'); wait('How you dictate'); shot('settings-home')
                click('Feedback & look'); wait('Match wallpaper'); shot('settings-look')
                adb('shell', 'pm', 'revoke', package, 'android.permission.RECORD_AUDIO')
                start('QuickDictateActivity'); wait('Quick dictate'); shot('quick-dictate')
                adb('shell', 'pm', 'grant', package, 'android.permission.RECORD_AUDIO')
        p['crash_check']()
    finally:
        for key, value in originals.items():
            override = re.search(r'Override (?:size|density): (\S+)', value)
            adb('shell', 'wm', key, override.group(1) if override else 'reset')
        adb('shell', 'cmd', 'uimode', 'night', 'yes' if 'yes' in night else 'auto' if 'auto' in night else 'no')
        (output / 'captures.json').write_text(json.dumps({'captures': captures, 'palettes': palettes}, indent=2) + '\n')
    print('PASS: Match wallpaper capture matrix on real system wallpapers; human visual review still required.', flush=True)
