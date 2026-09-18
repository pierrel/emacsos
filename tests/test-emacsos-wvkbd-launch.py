import json
import os
import runpy
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SOURCE = Path(__file__).parents[1] / "deploy" / "pinephone" / "emacsos-wvkbd-launch"


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.keyboard = self.root / "keyboard"
        self.collector = self.root / "collector"
        self.marker = self.root / "enabled"
        self.launcher = self.root / "launcher"
        self._script(
            self.keyboard,
            """#!/usr/bin/python3
import json
import os
import sys
try:
    info = os.fstat(3)
    fd3 = {"open": True, "socket": stat.S_ISSOCK(info.st_mode), "inheritable": os.get_inheritable(3)}
except OSError:
    fd3 = {"open": False}
print(json.dumps({"argv": sys.argv, "fd3": fd3}))
""".replace("import sys", "import sys\nimport stat"),
        )
        self._script(
            self.collector,
            """#!/usr/bin/python3
import os
os.write(6, b"ready")
os.close(6)
os.read(3, 1)
""",
        )
        source = SOURCE.read_text()
        source = source.replace(
            'KEYBOARD = "/usr/local/bin/wvkbd-emacsos"',
            f"KEYBOARD = {str(self.keyboard)!r}",
        ).replace(
            'COLLECTOR = "/usr/local/share/emacsos-openrc/swipe-learning-collector.py"',
            f"COLLECTOR = {str(self.collector)!r}",
        ).replace(
            'MARKER = "/var/lib/emacsos-lab/.local/state/emacsos/swipe-learning/enabled"',
            f"MARKER = {str(self.marker)!r}",
        ).replace("STATUS_TIMEOUT = 1.0", "STATUS_TIMEOUT = 0.05").replace(
            "TERM_GRACE = 0.5", "TERM_GRACE = 0.05"
        ).replace("KILL_GRACE = 1.0", "KILL_GRACE = 0.2")
        self._script(self.launcher, source)

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def _script(path: Path, content: str) -> None:
        path.write_text(content)
        path.chmod(0o755)

    def _run(self):
        result = subprocess.run(
            [self.launcher],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=3,
            check=True,
        )
        return json.loads(result.stdout)

    def test_absent_or_invalid_marker_runs_exact_baseline_without_learning_fd(self):
        expected = [str(self.keyboard), "--mod-swipe", "-H", "300", "-L", "300"]
        self.assertEqual(self._run(), {"argv": expected, "fd3": {"open": False}})
        self.marker.write_text("not-an-epoch")
        self.marker.chmod(0o600)
        self.assertEqual(self._run(), {"argv": expected, "fd3": {"open": False}})

    def test_unsafe_marker_and_unready_collector_fall_back_without_hanging(self):
        expected = [str(self.keyboard), "--mod-swipe", "-H", "300", "-L", "300"]
        target = self.root / "target"
        target.write_text("0123456789abcdef0123456789abcdef")
        self.marker.symlink_to(target)
        self.assertEqual(self._run(), {"argv": expected, "fd3": {"open": False}})
        self.marker.unlink()
        os.mkfifo(self.marker, 0o600)
        self.assertEqual(self._run(), {"argv": expected, "fd3": {"open": False}})
        self.marker.unlink()
        self.marker.write_text("0123456789abcdef0123456789abcdef")
        self.marker.chmod(0o600)
        self._script(
            self.collector,
            """#!/usr/bin/python3
import signal
import time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
time.sleep(60)
""",
        )
        self.assertEqual(self._run(), {"argv": expected, "fd3": {"open": False}})

    def test_private_epoch_runs_exact_armed_keyboard_with_only_learning_fd(self):
        self.marker.write_text("0123456789abcdef0123456789abcdef")
        self.marker.chmod(0o600)
        expected = [
            str(self.keyboard),
            "--mod-swipe",
            "-H",
            "300",
            "-L",
            "300",
            "--glide-learning-fd",
            "3",
        ]
        self.assertEqual(
            self._run(),
            {
                "argv": expected,
                "fd3": {"open": True, "socket": True, "inheritable": True},
            },
        )

    def test_armed_keyboard_reads_the_queued_fd3_snapshot(self):
        self.marker.write_text("0123456789abcdef0123456789abcdef")
        self.marker.chmod(0o600)
        self._script(
            self.collector,
            """#!/usr/bin/python3
import os
os.write(3, b"feedback-v1\\n")
os.write(6, b"ready")
os.close(6)
os.read(3, 1)
""",
        )
        self._script(
            self.keyboard,
            """#!/usr/bin/python3
import json
import os
import sys
print(json.dumps({"argv": sys.argv, "snapshot": os.read(3, 5964).decode()}))
""",
        )
        self.assertEqual(
            self._run(),
            {
                "argv": [
                    str(self.keyboard), "--mod-swipe", "-H", "300", "-L", "300",
                    "--glide-learning-fd", "3",
                ],
                "snapshot": "feedback-v1\n",
            },
        )

    def test_unreaped_collector_never_starts_baseline_keyboard(self):
        self.marker.write_text("0123456789abcdef0123456789abcdef")
        self.marker.chmod(0o600)
        self._script(
            self.collector,
            """#!/usr/bin/python3
import time
time.sleep(60)
""",
        )
        source = self.launcher.read_text().replace(
            "def _terminate_child(pid: int) -> bool:\n",
            "def _terminate_child(pid: int) -> bool:\n    return False\n",
        )
        self._script(self.launcher, source)
        result = subprocess.run(
            [self.launcher],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_termination_reaps_child_lost_before_either_signal(self):
        terminate = runpy.run_path(SOURCE)["_terminate_child"]
        for waits, signals in (
            ([False, True], [ProcessLookupError()]),
            ([False, False, True], [None, ProcessLookupError()]),
        ):
            with mock.patch.dict(
                terminate.__globals__, {"_wait_gone": mock.Mock(side_effect=waits)}
            ), mock.patch.object(os, "kill", side_effect=signals):
                self.assertTrue(terminate(12345))


if __name__ == "__main__":
    unittest.main()
