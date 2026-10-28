#!/usr/bin/env python3
"""Match wallpaper (dynamic colour) on real system wallpapers, light and dark (#332).

Run through e2e-all.sh --only wallpaper, which owns the emulator. Each wallpaper is set through
WallpaperManager (the debug-only WallpaperProbeActivity), so Android extracts its colours as it would from a photo;
the app's Match wallpaper scheme then comes from that extraction, not from a test fixture.
Captures are for human review; text-contrast-report.py measures the text in them afterwards.
"""
import json
import re
import shlex
import time

# Photo-like gradients (drawn by WallpaperProbeActivity) covering the extraction's range: warm, cool, green, pale (light) and near-black (dark).
WALLPAPERS = {
    'sunset': ((255, 183, 94), (214, 72, 96), (58, 32, 74)),
    'ocean': ((168, 222, 236), (28, 120, 168), (6, 36, 66)),
    'forest': ((120, 160, 84), (36, 84, 48), (10, 26, 16)),
    'snow': ((250, 251, 253), (226, 232, 240), (196, 206, 220)),
    'night': ((44, 40, 92), (20, 18, 46), (4, 4, 12)),
}


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
            before = (palette(), accent())
            colours = ','.join(str((0xff << 24 | r << 16 | g << 8 | b) - (1 << 32)) for r, g, b in stops)
            adb('logcat', '-c')
            adb('shell', 'am', 'start', '-W', '-n', package + '/.WallpaperProbeActivity', '--eia', 'colors', colours)
            seed = None
            for _ in range(20):
                found = re.search(r'wallpaper set primary=(\w+) source=(\w+)', adb('logcat', '-d', '-s', 'ChirpWallpaperProbe:I').decode(errors='replace'))
                if found: seed, extracted = found.groups(); break
                time.sleep(.5)
            if not seed or seed == 'none':
                log = adb('logcat', '-d', '-s', 'ChirpWallpaperProbe', 'AndroidRuntime', 'WallpaperManager', 'WallpaperManagerService', 'ActivityTaskManager').decode(errors='replace')
                print(log[-4000:], adb('shell', 'dumpsys', 'wallpaper').decode(errors='replace')[:3000], sep='\n', flush=True)
                raise AssertionError(f'{wallpaper}: the wallpaper was not set or Android extracted no colours')
            # System UI applies new wallpaper colours when the screen next turns off: sleep, wake, unlock.
            source = 'system'
            deadline = time.monotonic() + 20
            while (palette(), accent()) == before and time.monotonic() < deadline:
                adb('shell', 'input', 'keyevent', 'KEYCODE_SLEEP'); time.sleep(2)
                adb('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP'); adb('shell', 'wm', 'dismiss-keyguard'); time.sleep(2)
            if (palette(), accent()) == before:
                # This AVD's System UI didn't re-theme by itself: apply the extracted seed the way the
                # Wallpaper & style picker does, which runs the same Monet palette generation.
                source = 'seed'
                setting = json.dumps({'android.theme.customization.system_palette': seed, 'android.theme.customization.theme_style': 'TONAL_SPOT',
                                      'android.theme.customization.color_source': 'home_wallpaper', '_applied_timestamp': int(time.time() * 1000)})
                adb('shell', 'settings', 'put', 'secure', 'theme_customization_overlay_packages', shlex.quote(setting))
                deadline = time.monotonic() + 30
                while (palette(), accent()) == before and time.monotonic() < deadline: time.sleep(2)
            palettes[wallpaper] = {'seed': seed, 'extracted_by': extracted, 'applied_by': source, 'overlay': palette(), 'accent1_600': accent()}
            print('PALETTE:', wallpaper, palettes[wallpaper], flush=True)
            if (palettes[wallpaper]['overlay'], palettes[wallpaper]['accent1_600']) == before:
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
