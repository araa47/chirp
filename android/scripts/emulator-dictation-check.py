#!/usr/bin/env python3
"""Native watcher for real IME tap/hold, partial/final, Ripple evidence and typing."""


def check(p, work, output):
    adb = p['adb']
    failures = []
    for theme in ('light', 'dark'):
        adb('shell', 'cmd', 'uimode', 'night', 'yes' if theme == 'dark' else 'no')
        p['fresh_editor']()
        for mode in ('tap', 'hold'):
            if mode == 'hold':
                p['click']('More keys')
                try:
                    target = p['wait_for']('Voice input', 10)
                except AssertionError:
                    data = adb('exec-out', 'screencap', '-p')
                    (output / (theme + '-hold-control-missing.png')).write_bytes(data[data.index(b'\x89PNG'):])
                    failures.append(theme + ': no accessible Voice input hold target')
                    print('FAIL:', failures[-1], flush=True)
                    continue
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
    assert not failures, '; '.join(failures)
