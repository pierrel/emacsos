"""Real desktop install/update checks in disposable homes and prefixes."""

import ctypes
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import shutil
import selectors
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1]
FILES = ("assist-desktop.el", "chat.el", "assist-web.el", "assist-web-git.el",
         "assist-web-git-helper.py")


class DesktopInstallTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="desktop-install-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.source = self.base / "source"
        self.source.mkdir()
        (self.source / "deploy").mkdir()
        for name in (*FILES, "Makefile", "deploy/install-desktop.py"):
            shutil.copyfile(ROOT / name, self.source / name)
        self.home = self.base / "home"
        self.home.mkdir()
        self.destination = self.home / ".local/share/emacsos-assist"

    def install(self, prefix=None):
        environment = {**os.environ, "HOME": str(self.home)}
        environment.pop("DESKTOP_ASSIST_DIR", None)
        if prefix is not None:
            environment["DESKTOP_ASSIST_DIR"] = str(prefix)
        return subprocess.run(["make", "install-desktop"], cwd=self.source,
                              env=environment, text=True, capture_output=True, timeout=10)

    def assert_payload(self, target):
        for name in FILES:
            self.assertEqual((target / name).read_bytes(), (self.source / name).read_bytes())
            self.assertEqual((target / name).stat().st_mode & 0o777,
                             0o755 if name.endswith(".py") else 0o644)
        manifest = json.loads((target / ".assist-desktop-install.json").read_text())
        self.assertEqual(set(manifest), set(FILES))

    def test_default_install_and_repeat_update_preserve_private_work(self):
        private = (".config/emacsos/assist-desktop-config.el",
                   ".config/emacsos/assist-web-token", ".emacs.d/init.el",
                   ".cache/emacsos/assist-web/draft.json", "assist/local-edit.txt")
        for name in private:
            path = self.home / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("preserve local work\n")
            path.chmod(0o600)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_payload(self.destination)
        self.assertEqual(self.install().returncode, 0)
        with (self.source / "assist-desktop.el").open("a") as source:
            source.write("\n;; Updated source fixture.\n")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_payload(self.destination)
        for name in private:
            self.assertEqual((self.home / name).read_text(), "preserve local work\n")
            self.assertEqual((self.home / name).stat().st_mode & 0o777, 0o600)
        result = subprocess.run(
            ["emacs", "-Q", "--batch", "--load", str(self.destination / "assist-desktop.el"),
             "--eval", "(unless (and (commandp 'emacsos-desktop-assist) (not (featurep 'os))) (kill-emacs 1))"],
            cwd=self.base, env={**os.environ, "HOME": str(self.home)},
            text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_custom_prefix_preserves_unrelated_files(self):
        target = self.base / 'quoted "prefix"; inert'
        target.mkdir()
        (target / "sentinel").write_text("keep")
        result = self.install(target)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_payload(target)
        self.assertEqual((target / "sentinel").read_text(), "keep")

    def test_update_refuses_local_code_edits_before_replacing_any_file(self):
        self.assertEqual(self.install().returncode, 0)
        (self.destination / "chat.el").write_text("local code edit\n")
        before = {path.name: path.read_bytes() for path in self.destination.iterdir()}
        (self.source / "assist-desktop.el").write_text("new version\n")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("local work preserved", result.stderr)
        self.assertEqual(before, {path.name: path.read_bytes()
                                  for path in self.destination.iterdir()})

    def test_concurrent_save_is_retained_by_atomic_handoff(self):
        self.assertEqual(self.install().returncode, 0)
        spec = importlib.util.spec_from_file_location("desktop_installer", self.source / "deploy/install-desktop.py")
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        old = self.destination / "chat.el"
        (self.source / "chat.el").write_text("new client version\n")
        handoff = installer.handoff

        def save_then_handoff(staged, installed, exchange):
            # Model an editor's atomic-save rename at the last possible boundary.
            saved = self.base / "saved"
            saved.write_text("concurrent local work\n")
            saved.replace(installed)
            handoff(staged, installed, exchange)

        with patch.dict(os.environ, {"DESKTOP_ASSIST_DIR": str(self.destination)}), \
                patch.object(installer, "handoff", side_effect=save_then_handoff):
            installer.install()
        self.assertEqual(old.read_text(), "new client version\n")
        backups = list(self.destination.glob(".assist-desktop-update-*/chat.el"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), "concurrent local work\n")

    def test_interrupted_update_retains_exchanged_file(self):
        self.assertEqual(self.install().returncode, 0)
        spec = importlib.util.spec_from_file_location("desktop_installer", self.source / "deploy/install-desktop.py")
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        old = (self.destination / "chat.el").read_bytes()
        (self.source / "chat.el").write_text("new client version\n")
        handoff = installer.handoff

        def interrupt_after_handoff(*arguments):
            handoff(*arguments)
            raise OSError("interrupted")

        with patch.dict(os.environ, {"DESKTOP_ASSIST_DIR": str(self.destination)}), \
                patch.object(installer, "handoff", side_effect=interrupt_after_handoff):
            with self.assertRaisesRegex(OSError, "interrupted"):
                installer.install()
        backups = list(self.destination.glob(".assist-desktop-update-*/chat.el"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), old)
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(backups[0].read_bytes(), old)
        self.assert_payload(self.destination)

    def test_handoff_preserves_collision_and_darwin_flags(self):
        spec = importlib.util.spec_from_file_location("desktop_installer", ROOT / "deploy/install-desktop.py")
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        first, second = self.base / "first", self.base / "second"
        first.write_text("new")
        second.write_text("local")
        with self.assertRaises(OSError):
            installer.handoff(first, second, False)
        self.assertEqual(second.read_text(), "local")
        self.assertEqual(first.read_text(), "new")
        installer.handoff(first, second, True)
        self.assertEqual(second.read_text(), "new")
        self.assertEqual(first.read_text(), "local")
        rename = Mock(return_value=0)
        with patch.object(installer.sys, "platform", "darwin"), \
                patch.object(ctypes, "CDLL", return_value=Mock(renamex_np=rename)):
            installer.handoff(first, second, True)
            self.assertEqual(rename.call_args.args[-1], 2)
            installer.handoff(first, second, False)
            self.assertEqual(rename.call_args.args[-1], 4)
            self.assertEqual(rename.argtypes,
                             (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint))

    def test_stale_bytecode_refuses_update_without_changing_any_file(self):
        self.assertEqual(self.install().returncode, 0)
        bytecode = self.base / "bytecode"
        bytecode.mkdir()
        compiled_source = bytecode / "chat.el"
        compiled_source.write_bytes((self.destination / "chat.el").read_bytes()
                                    + b"\n(defconst desktop-stale-bytecode t)\n")
        result = subprocess.run(
            ["emacs", "-Q", "--batch", "-L", str(self.destination),
             "-f", "batch-byte-compile", str(compiled_source)],
            env={**os.environ, "HOME": str(self.home)},
            text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        shutil.copyfile(compiled_source.with_suffix(".elc"), self.destination / "chat.elc")
        result = subprocess.run(
            ["emacs", "-Q", "--batch", "--load", str(self.destination / "assist-desktop.el"),
             "--eval", "(unless (bound-and-true-p desktop-stale-bytecode) (kill-emacs 1))"],
            env={**os.environ, "HOME": str(self.home)},
            text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        before = {path.name: path.read_bytes() for path in self.destination.iterdir()}
        with (self.source / "assist-desktop.el").open("a") as source:
            source.write("\n;; Updated source fixture.\n")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Compiled client file present: chat.elc", result.stderr)
        self.assertEqual(before, {path.name: path.read_bytes()
                                  for path in self.destination.iterdir()})

    def test_concurrent_checkouts_serialize_through_prefix_alias(self):
        self.assertEqual(self.install().returncode, 0)
        second_source = self.base / "second-source"
        shutil.copytree(self.source, second_source)
        for source, version in ((self.source, "A"), (second_source, "B")):
            for name in FILES:
                with (source / name).open("a") as payload:
                    payload.write(("\n# " if name.endswith(".py") else "\n;; ") + version + "\n")
        alias = self.base / "same-prefix"
        alias.symlink_to(self.destination, target_is_directory=True)
        wrapper = """import importlib.util,sys
spec=importlib.util.spec_from_file_location('installer',sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
if sys.argv[2]=='A':
 native=m.handoff; first=True
 def pause(*arguments):
  global first
  native(*arguments)
  if first:
   first=False; print('ready',flush=True); sys.stdin.readline()
 m.handoff=pause
else: print('started',flush=True)
m.install()
"""
        processes = []

        def start(source, target, version):
            child = subprocess.Popen(
                ["python3", "-c", wrapper, str(source / "deploy/install-desktop.py"), version],
                env={**os.environ, "HOME": str(self.home), "DESKTOP_ASSIST_DIR": str(target)},
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            processes.append(child)
            return child

        def signal(child, expected):
            with selectors.DefaultSelector() as monitor:
                monitor.register(child.stdout, selectors.EVENT_READ)
                self.assertTrue(monitor.select(5), "installer signal missing")
                self.assertEqual(child.stdout.readline().strip(), expected)

        try:
            first = start(self.source, self.destination, "A")
            signal(first, "ready")
            descriptor = os.open(self.destination / ".assist-desktop-install.lock",
                                 os.O_CREAT | os.O_RDWR, 0o600)
            with os.fdopen(descriptor, "r+") as lock:
                # A different process cannot enter while the real exchange is paused.
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            second = start(second_source, alias, "B")
            signal(second, "started")
            first.stdin.write("continue\n")
            first.stdin.flush()
            first_output, first_error = first.communicate(timeout=10)
            second_output, second_error = second.communicate(timeout=10)
            self.assertEqual(first.returncode, 0, first_error)
            self.assertEqual(second.returncode, 0, second_error)
            for name in FILES:
                self.assertEqual((self.destination / name).read_bytes(),
                                 (second_source / name).read_bytes())
            import hashlib
            expected = {name: hashlib.sha256((second_source / name).read_bytes()).hexdigest()
                        for name in FILES}
            self.assertEqual(json.loads((self.destination / ".assist-desktop-install.json").read_text()),
                             expected)
        finally:
            for child in processes:
                if child.poll() is None:
                    child.kill()
                    child.communicate(timeout=5)

    def test_existing_symlink_and_empty_prefix_are_refused(self):
        self.destination.mkdir(parents=True)
        outside = self.base / "user-file"
        outside.write_text("keep")
        (self.destination / "assist-desktop.el").symlink_to(outside)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(outside.read_text(), "keep")
        self.assertEqual(self.install("").returncode, 2)


if __name__ == "__main__":
    unittest.main()
