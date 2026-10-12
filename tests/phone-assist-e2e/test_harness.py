"""Regressions for client wait completion, assertion admission and exact cleanup."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from run import Driver


class DriverTests(unittest.TestCase):
    def test_successful_client_wait_predicate_is_not_repeated(self):
        repo = Path(__file__).resolve().parents[2]
        expression = """(let ((calls 0))
          (phone-e2e-wait (lambda () (= (cl-incf calls) 1)))
          (unless (= calls 1) (error "successful predicate repeated")))"""
        result = subprocess.run(['emacs', '-Q', '--batch', '-L', str(repo),
            '-l', str(Path(__file__).with_name('client.el')), '--eval', expression],
            env={**os.environ, 'ASSIST_E2E_URL': 'https://assist:8443'},
            capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_optimized_runner_refuses_before_creating_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            logs = Path(temporary) / 'logs'
            result = subprocess.run([sys.executable, '-O', str(Path(__file__).with_name('run.py')),
                '--fixture', str(Path(temporary) / 'absent'), '--logs', str(logs)],
                capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('E2E requires assertions', result.stderr)
            self.assertFalse(logs.exists())

    def test_log_timeout_still_removes_owned_client_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'token').write_text('synthetic-token')
            fixture = root / 'fixture.json'
            fixture.write_text(json.dumps({'credentials': {'token': str(root / 'token')}}))
            driver = Driver(argparse.Namespace(logs=root / 'logs', fixture=fixture))
            driver.created = True
            calls = []
            def command(args, **kwargs):
                calls.append(args)
                if args[1:3] == ['container', 'inspect']:
                    return subprocess.CompletedProcess(args, 0, json.dumps([
                        {'Config': {'Labels': {'phone-assist-e2e.owner': driver.name}}}]), '')
                if args[1] == 'logs':
                    raise subprocess.TimeoutExpired(args, 5)
                return subprocess.CompletedProcess(args, 0, '', '')
            with patch('run.subprocess.run', command):
                with self.assertRaisesRegex(RuntimeError, 'Client cleanup failed'):
                    driver.cleanup()
            self.assertEqual([c for c in calls if c[1] == 'rm'], [
                ['docker', 'rm', '-f', '-v', driver.name + '-client']])
            self.assertFalse(any('network' in c or 'volume' in c for c in calls))


if __name__ == '__main__':
    unittest.main()
