#!/usr/bin/env python3
"""One host-wide Chirp emulator lease, shared by every checkout/worktree."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import time

LOCK = Path('/tmp/chirp-emulator.lock')


def alive(pid):
    try: os.kill(pid, 0)
    except ProcessLookupError: return False
    except PermissionError: return True
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('acquire', 'release'))
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--worktree', default='')
    parser.add_argument('--timeout', type=float, default=1800)
    args = parser.parse_args()
    if args.pid <= 1: parser.error('owner must be a running shell PID')
    deadline = time.monotonic() + args.timeout
    announced = False
    # This persistent guard serializes metadata changes, including stale-owner
    # recovery. Never unlink it: replacement inodes would allow two guard owners.
    with LOCK.with_suffix('.guard').open('a') as guard:
        while True:
            fcntl.flock(guard, fcntl.LOCK_EX)
            try:
                if not LOCK.exists():
                    if args.action == 'release': return
                    LOCK.mkdir(mode=0o700)
                    (LOCK / 'owner.json').write_text(json.dumps({'pid': args.pid, 'worktree': args.worktree}) + '\n')
                    return
                try:
                    owner = json.loads((LOCK / 'owner.json').read_text())
                    pid = int(owner['pid'])
                    if pid <= 1: raise ValueError('invalid owner')
                    stale = not alive(pid)
                except FileNotFoundError:
                    # An earlier process may have crashed after mkdir. All live
                    # creators write inside this same guard, so no grace race.
                    stale = True
                    owner = {}
                except (ValueError, KeyError, PermissionError):
                    raise SystemExit('Cannot verify emulator lock owner; refusing to remove it')
                if args.action == 'release':
                    if owner.get('pid') != args.pid: return
                    stale = True
                if stale:
                    (LOCK / 'owner.json').unlink(missing_ok=True)
                    LOCK.rmdir()
                    if args.action == 'release': return
                    continue
                if time.monotonic() >= deadline:
                    raise SystemExit('Timed out queued for the host-wide Chirp emulator lock')
                if not announced:
                    print('Queued for the host-wide Chirp emulator slot (one run at a time).', flush=True)
                    announced = True
            finally:
                fcntl.flock(guard, fcntl.LOCK_UN)
            time.sleep(2)


if __name__ == '__main__':
    main()
