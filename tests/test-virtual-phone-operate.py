"""Exercise readiness through stalled native SSH attempts and its total deadline."""
from contextlib import redirect_stderr, redirect_stdout
import io
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

OPERATE = Path(__file__).resolve().parents[1] / 'deploy/virtual-phone/operate'


class ReadinessTests(unittest.TestCase):
    def run_ready(self, recover):
        now = [0.0]
        attempts = []

        def probe(command, **kwargs):
            attempts.append(kwargs['timeout'])
            if recover and len(attempts) == 2:
                return subprocess.CompletedProcess(command, 0)
            now[0] += kwargs['timeout']
            raise subprocess.TimeoutExpired(command, kwargs['timeout'])

        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'container.id').write_text('synthetic-container')
            with patch.dict(os.environ, VIRTUAL_PHONE_STATE=directory), \
                    patch.object(sys, 'argv', [str(OPERATE), 'ready']), \
                    patch('subprocess.run', side_effect=probe), \
                    patch('time.monotonic', side_effect=lambda: now[0]), \
                    patch('time.sleep', side_effect=lambda delay: now.__setitem__(0, now[0] + delay)), \
                    redirect_stdout(output), redirect_stderr(output):
                status = 0
                try:
                    runpy.run_path(str(OPERATE), run_name='__main__')
                except SystemExit as error:
                    status = error.code
        return status, now[0], attempts, output.getvalue()

    def test_stalled_attempt_can_be_followed_by_ready_guest(self):
        status, elapsed, attempts, output = self.run_ready(recover=True)
        self.assertEqual(status, 0, output)
        self.assertEqual(len(attempts), 2)
        self.assertLess(elapsed, 60)
        self.assertIn('shared Sway window and Emacs server probes passed', output)

    def test_repeated_stalls_stop_at_total_deadline_with_diagnostic(self):
        status, elapsed, attempts, output = self.run_ready(recover=False)
        self.assertEqual(status, 1)
        self.assertEqual(elapsed, 60)
        self.assertGreater(len(attempts), 1)
        self.assertLessEqual(max(attempts), 15)
        self.assertIn('UI not ready after 60 seconds; run operate logs', output)


if __name__ == '__main__':
    unittest.main()
