#!/usr/bin/env python3
"""Native watcher for real IME tap/hold, partial/final, Ripple evidence and typing."""
import shlex


def check(p, work, output):
    adb = p['adb']
    for theme in ('light', 'dark'):
        adb('shell', 'cmd', 'uimode', 'night', 'yes' if theme == 'dark' else 'no')
        p['fresh_editor']()
        for mode in ('tap', 'hold'):
            if mode == 'hold':
                p['click']('More keys')
                target = p['wait_for']('Voice input')
            else:
                target = p['wait_for']('Microphone: tap to dictate')
            x, y = p['center'](target)
            remote = '/sdcard/chirp-listening.png'
            adb('shell', 'rm', '-f', remote)
            try:
                adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/',
                    'dev.chirp.smoke.UiHierarchy', 'dictation-cycle', mode, str(x), str(y), remote)
            finally:
                try: adb('pull', remote, str(output / (theme + '-' + mode + '-listening.png')))
                except RuntimeError: pass
            # Keep the all-window dump beside the post-final screenshot; only synthetic text.
            p['nodes']()
            (output / (theme + '-' + mode + '-final.xml')).write_bytes(adb('shell', 'cat', '/sdcard/chirp-windows.xml'))
            before = p['editor_text']()
            p['tap_key']('a')
            assert len(p['editor_text']()) > len(before), 'Typing after dictation failed'
            print('PASS:', theme, mode, 'partial/final and typing; listening screenshot captured on device', flush=True)
    p['crash_check']()
