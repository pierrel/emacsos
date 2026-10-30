"""Run the actual installer admission against real UID processes in Alpine."""
import os
from pathlib import Path
import re
import select
import subprocess
import tempfile
import unittest


class Quiescence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.environ.get("EMACSOS_QUIESCENCE_FIXTURE") != "1" or os.geteuid() != 0:
            raise unittest.SkipTest("requires the isolated Alpine installer fixture")
        subprocess.run(["addgroup", "-g", "104", "emacsos-lab"], check=True)
        subprocess.run(["adduser", "-D", "-H", "-u", "104", "-G", "emacsos-lab", "emacsos-lab"], check=True)
        if not Path("/usr/bin/python3").exists():
            Path("/usr/bin/python3").symlink_to("/usr/local/bin/python3")
        source = (Path(__file__).resolve().parents[1] / "deploy/pinephone/openrc-update-root").read_text()
        cls.functions = "\n".join(re.search(r"^" + name + r"\(\) \{\n.*?^\}", source, re.M | re.S).group()
                                  for name in ("no_lab_processes", "ui_quiescent"))

    def admission(self, *, path=None, populated=False):
        with tempfile.TemporaryDirectory() as tmp:
            group = Path(tmp) / "cgroup" if populated else Path(tmp) / "absent"
            if populated:
                group.mkdir()
            script = self.functions + '\nrc_service() { return 3; }\ncgroup_empty() { return 1; }\n'
            script += 'service_cgroup="$1"\nui_quiescent\n'
            env = dict(os.environ)
            if path:
                env["PATH"] = str(path) + ":" + env["PATH"]
            return subprocess.run(["/bin/sh", "-s", str(group)], input=script, text=True,
                                  capture_output=True, env=env, timeout=5)

    def zombie(self):
        pid = os.fork()
        if pid == 0:
            os.setgid(104)
            os.setuid(104)
            os._exit(0)
        os.waitid(os.P_PID, pid, os.WEXITED | os.WNOWAIT)
        self.assertIn("State:\tZ", Path(f"/proc/{pid}/status").read_text())
        return pid

    def test_actual_busybox_zombie_match_passes_installer_admission(self):
        pid = self.zombie()
        try:
            old = subprocess.run(["pgrep", "-u", "104"], capture_output=True, text=True)
            self.assertEqual(old.returncode, 0)  # The old predicate rejected this.
            self.assertIn(str(pid), old.stdout.split())
            self.assertEqual(self.admission().returncode, 0)
            self.assertTrue(Path(f"/proc/{pid}").exists())  # No reaping wait needed.
        finally:
            os.waitpid(pid, 0)

    def test_genuinely_live_unrelated_process_rejected_even_with_zombie(self):
        pid = self.zombie()
        child = subprocess.Popen(["sleep", "300"], user=104, group=104)
        try:
            self.assertEqual(self.admission().returncode, 1)
            self.assertIsNone(child.poll())
        finally:
            child.terminate()
            child.wait(timeout=2)
            os.waitpid(pid, 0)

    def test_zombie_leader_with_live_worker_is_not_exited(self):
        source = '''import ctypes,os,threading
libc=ctypes.CDLL(None)
libc.pthread_self.restype=ctypes.c_ulong
libc.pthread_join.argtypes=[ctypes.c_ulong,ctypes.c_void_p]
main=libc.pthread_self()
def worker():
 assert libc.pthread_join(main,None)==0
 os.write(1,b'R')
 os.read(0,1)
 os._exit(0)
threading.Thread(target=worker).start()
libc.pthread_exit(None)
'''
        child = subprocess.Popen(["/usr/local/bin/python3", "-c", source], user=104, group=104,
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        try:
            self.assertTrue(select.select([child.stdout], [], [], 3)[0])
            self.assertEqual(child.stdout.read(1), b"R")
            self.assertIn("State:\tZ", Path(f"/proc/{child.pid}/status").read_text())
            self.assertEqual(self.admission().returncode, 1)
        finally:
            child.stdin.write(b"x")
            child.stdin.close()
            child.wait(timeout=3)
            child.stdout.close()

    def test_enumeration_error_and_malformed_output_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "pgrep"
            for body in ("exit 2", "echo malformed; exit 0", "echo 0; exit 0"):
                binary.write_text("#!/bin/sh\n" + body + "\n")
                binary.chmod(0o755)
                self.assertEqual(self.admission(path=tmp).returncode, 1)

    def test_empty_UID_passes_but_populated_cgroup_still_rejects(self):
        self.assertEqual(self.admission().returncode, 0)
        self.assertEqual(self.admission(populated=True).returncode, 1)


if __name__ == "__main__":
    unittest.main()
