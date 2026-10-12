"""Regressions for client budgets, wait completion, assertion admission and exact cleanup."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
from run import Driver


class DriverTests(unittest.TestCase):
    def test_build_uses_remaining_global_budget_and_refuses_after_expiry(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'token').write_text('synthetic-token')
            fixture = root / 'fixture.json'
            fixture.write_text(json.dumps({'credentials': {'token': str(root / 'token')}}))
            for remaining in [700, 100, 0]:
                with self.subTest(remaining=remaining):
                    driver = Driver(argparse.Namespace(fixture=fixture,
                        logs=root / ('logs-' + str(remaining)), emacsos_source=root))
                    driver.deadline = remaining
                    driver.verify_fixture = Mock()
                    driver.stage = Mock()
                    driver.command = Mock(return_value='synthetic-head')
                    with (patch('run.time.monotonic', return_value=0),
                          patch('run.subprocess.run', side_effect=subprocess.TimeoutExpired('build', 1)) as build):
                        if remaining > 0:
                            with self.assertRaises(subprocess.TimeoutExpired):
                                driver.bootstrap(root)
                            self.assertEqual(build.call_args.kwargs['timeout'], min(600, remaining))
                        else:
                            with self.assertRaisesRegex(TimeoutError, 'driver deadline exceeded'):
                                driver.bootstrap(root)
                            build.assert_not_called()
                    self.assertFalse(driver.created)

    def test_client_multistage_action_uses_remaining_global_budget(self):
        driver = Driver.__new__(Driver)
        driver.name = 'synthetic-client'
        driver.token = 'synthetic-token'
        driver.deadline = 220
        timeouts = []
        def complete(args, **kwargs):
            timeouts.append(kwargs['timeout'])
            if kwargs['timeout'] < 60:
                raise subprocess.TimeoutExpired(args, kwargs['timeout'])
            return subprocess.CompletedProcess(args, 0, 'E2E_JSON:{}\n', '')
        with tempfile.TemporaryDirectory() as temporary:
            driver.args = argparse.Namespace(logs=Path(temporary))
            with (patch('run.time.monotonic', return_value=100),
                  patch('run.subprocess.run', complete)):
                self.assertEqual(driver.client('auth-recovery', 'thread'), {})
                driver.deadline = 150
                with self.assertRaises(subprocess.TimeoutExpired):
                    driver.client('auth-recovery', 'thread')
        self.assertEqual(timeouts, [120, 50])

    def test_auth_recovery_requires_a_new_git_receipt(self):
        repo = Path(__file__).resolve().parents[2]
        expression = """(dolist (fresh '(nil t))
          (let ((emacsos-assist-web-token-file (make-temp-file "e2e-token-"))
                (emacsos-assist-web--snapshot (list 'before))
                (emacsos-assist-web--requests nil)
                (emacsos-assist-web--denied nil)
                (emacsos-assist-web--auth-epoch 0)
                (emacsos-assist-web-git--result (list 'old-git))
                (emacsos-assist-web-git--process nil)
                (emacsos-assist-web-git--unavailable nil)
                (refreshes 0) failed result)
            (unwind-protect
                (cl-letf (((symbol-function 'phone-e2e-wait)
                           (lambda (predicate)
                             (unless (funcall predicate) (error "unmet recovery condition"))))
                          ((symbol-function 'copy-file) (lambda (&rest _) nil))
                          ((symbol-function 'emacsos-assist-web-refresh-thread)
                           (lambda () (interactive)
                             (cl-incf refreshes)
                             (if (= refreshes 1)
                                 (setq emacsos-assist-web--denied t
                                       emacsos-assist-web--auth-epoch 1)
                               (setq emacsos-assist-web--denied nil
                                     emacsos-assist-web--snapshot (list 'new-canonical))
                               (when fresh
                                 (setq emacsos-assist-web-git--result (list 'new-git)))))))
                  (condition-case nil
                      (setq result (phone-e2e-auth-recovery))
                    (error (setq failed t)))
                  (if fresh
                      (unless (and (not failed) (alist-get 'git_refreshed result))
                        (error "fresh Git recovery failed"))
                    (unless failed (error "stale Git receipt passed recovery"))))
              (delete-file emacsos-assist-web-token-file))))"""
        result = subprocess.run(['emacs', '-Q', '--batch', '-L', str(repo),
            '-l', str(Path(__file__).with_name('client.el')), '--eval', expression],
            env={**os.environ, 'ASSIST_E2E_URL': 'https://assist:8443'},
            capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_timeout_does_not_report_a_recovered_transient_error(self):
        driver = Driver.__new__(Driver)
        driver.deadline = 10
        predicate = Mock(side_effect=[RuntimeError('transient connection refusal'), False])
        with (patch('run.time.monotonic', side_effect=[0, .1, .2, 1]),
              patch('run.time.sleep')):
            with self.assertRaisesRegex(TimeoutError, 'restart barrier: condition not reached'):
                driver.wait('restart barrier', predicate, seconds=1)
        self.assertEqual(predicate.call_count, 2)

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
