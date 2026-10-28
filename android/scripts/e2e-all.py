#!/usr/bin/env python3
"""Sweep coordinator. Run through e2e-all.sh, which owns the emulator and trap."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import signal
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(os.environ['CHIRP_E2E_OUTPUT'])
SERIAL = os.environ['ANDROID_SERIAL']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--only', nargs='+', choices=('dictation', 'cleanup', 'notes', 'speakers', 'history', 'learn', 'stop', 'device', 'bubble', 'quickdictate', 'visual', 'wallpaper', 'keepkb', 'release'))
    args = parser.parse_args()
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        result = subprocess.run(['adb', '-s', SERIAL, 'shell', 'getprop', 'sys.boot_completed'], capture_output=True, timeout=10)
        if result.returncode == 0 and result.stdout.strip() == b'1': break
        time.sleep(2)
    else: raise SystemExit('AVD did not boot in 300 s; see emulator.log; try fewer cores/memory')
    subprocess.run(['adb', '-s', SERIAL, 'shell', 'wm', 'dismiss-keyguard'], check=True)
    subprocess.run(['adb', '-s', SERIAL, 'uninstall', 'dev.chirp.android'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    abi = subprocess.check_output(['adb', '-s', SERIAL, 'shell', 'getprop', 'ro.product.cpu.abi']).decode().strip()
    port = os.environ.get('CHIRP_E2E_PORT', '7899')  # the throwaway server's port; another run may hold 7899
    server_root = Path(os.environ.get('CHIRP_E2E_SERVER_ROOT', ROOT / 'server'))
    command = ['python3', str(ROOT / 'android/scripts/emulator-check.py'), '--tls', '--server-port', port,
               '--server-root', str(server_root), '--python', str(server_root / '.venv/bin/python'),
               '--model-dir', os.environ.get('CHIRP_MODEL_DIR', str(Path.home() / '.koi/voice-models/parakeet-mlx')),
               '--apk', str(ROOT / f'android/app/build/outputs/apk/debug/app-{abi}-debug.apk')]
    results = {}
    defaults = ('dictation', 'cleanup', 'notes', 'history', 'learn', 'stop', 'device', 'bubble', 'quickdictate', 'visual', 'keepkb', 'release')
    if os.environ.get('CHIRP_SPEAKER_MODEL'): defaults += ('speakers',)
    for phase in args.only or defaults:
        target = OUT / phase
        target.mkdir(exist_ok=True)
        env = dict(os.environ, CHIRP_E2E_OUTPUT=str(target), CHIRP_E2E_NATIVE_EDITOR='0' if phase == 'release' else '1')
        flags = [] if phase == 'dictation' else ['--' + ('cleanup-only' if phase == 'cleanup' else phase + '-check')]
        print('RUN:', phase, flush=True)
        commands = [command + flags] if phase != 'release' else [
            ['bash', str(ROOT / 'android/scripts/emulator-smoke.sh')],
            ['bash', str(ROOT / 'android/scripts/build-ui-probe.sh')],
            ['python3', str(ROOT / 'android/scripts/emulator-talkback.py'), '--quickdictate-check'],
        ]
        with (target / 'run.log').open('w') as log:
            for check in commands:
                process = subprocess.Popen(check, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    code = process.wait(timeout=1200)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM)
                    try: process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                    code = 124
                if code: break
        results[phase] = 'PASS' if code == 0 else f'FAIL ({code})'
        print(phase, results[phase], flush=True)
    (OUT / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('\n| Flow | Result |\n| --- | --- |')
    for phase, result in results.items(): print(f'| {phase} | {result} |')
    raise SystemExit(0 if all(r == 'PASS' for r in results.values()) else 1)


if __name__ == '__main__':
    main()
