#!/usr/bin/env python3
"""Process-level checks for emulator lease exclusion and dead-owner recovery."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('emulator-lock.py')


class LeaseTest(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.lock = Path(self.work.name) / 'lease.lock'

    def command(self, action, pid=None):
        # Isolate tests from the real host lease while exercising the real CLI.
        code = ('import runpy,sys; from pathlib import Path; '
                'm=runpy.run_path(sys.argv.pop(1)); '
                'm["main"].__globals__["LOCK"]=Path(sys.argv.pop(1)); m["main"]()')
        return [sys.executable, '-c', code, str(SCRIPT), str(self.lock), action,
                '--pid', str(pid or os.getpid()), '--timeout', '0']

    def run_lock(self, action, pid=None):
        return subprocess.run(self.command(action, pid), capture_output=True, timeout=5)

    def test_live_owner_excludes_parallel_worktrees_and_foreign_release(self):
        jobs = [subprocess.Popen(self.command('acquire'), stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(4)]
        codes = [job.wait(timeout=5) for job in jobs]
        for job in jobs:
            job.communicate()
        self.assertEqual(codes.count(0), 1)
        self.assertEqual(self.run_lock('release', os.getppid()).returncode, 0)
        self.assertTrue(self.lock.exists())
        self.assertNotEqual(self.run_lock('acquire').returncode, 0)
        self.assertEqual(self.run_lock('release').returncode, 0)
        self.assertEqual(self.run_lock('acquire').returncode, 0)

    def test_dead_owner_and_interrupted_creation_are_recoverable(self):
        dead = subprocess.Popen([sys.executable, '-c', 'pass'])
        dead.wait(timeout=5)
        self.lock.mkdir()
        (self.lock / 'owner.json').write_text(json.dumps({'pid': dead.pid, 'worktree': 'old'}))
        self.assertEqual(self.run_lock('acquire').returncode, 0)
        self.assertEqual(json.loads((self.lock / 'owner.json').read_text())['pid'], os.getpid())
        self.run_lock('release')
        self.lock.mkdir()  # A crash between mkdir and metadata publication.
        self.assertEqual(self.run_lock('acquire').returncode, 0)


if __name__ == '__main__':
    unittest.main()
