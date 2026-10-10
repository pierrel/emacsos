"""Real local Git repositories exercise the persistent phone checkout."""

import importlib.util
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "assist-web-git-helper.py"
SPEC = importlib.util.spec_from_file_location("assist_web_git_helper", SCRIPT)
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


def git(*args, cwd=None):
    result = subprocess.run(["git", *map(str, args)], cwd=cwd, check=True,
                            capture_output=True, text=True)
    return result.stdout.strip()


def commit(root, name, body):
    (root / name).write_text(body)
    git("add", name, cwd=root)
    git("-c", "user.name=Test", "-c", "user.email=test@localhost",
        "commit", "-m", name, cwd=root)
    return git("rev-parse", "HEAD", cwd=root)


class WorkspacePromotionTest(unittest.TestCase):
    def test_native_promotion_does_not_replace_existing_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage"
            stage.mkdir()
            (stage / "local").write_text("stage")
            destination = root / "destination"
            for kind in ("file", "directory", "symlink"):
                with self.subTest(kind=kind):
                    if kind == "file":
                        destination.write_text("keep")
                    elif kind == "directory":
                        destination.mkdir()
                    else:
                        destination.symlink_to(stage, target_is_directory=True)
                    with self.assertRaisesRegex(helper.Refusal, "already exists"):
                        helper.promote_workspace(stage, destination)
                    self.assertTrue((stage / "local").exists())
                    if kind == "directory":
                        destination.rmdir()
                    else:
                        destination.unlink()
            helper.promote_workspace(stage, destination)
            self.assertEqual((destination / "local").read_text(), "stage")

    def test_darwin_exclusive_rename_binding(self):
        from unittest.mock import Mock
        rename = Mock(return_value=0)
        with patch.object(helper.sys, "platform", "darwin"), \
                patch.object(ctypes, "CDLL", return_value=Mock(renamex_np=rename)):
            helper.promote_workspace(Path("stage"), Path("destination"))
            rename.assert_called_once_with(b"stage", b"destination", 4)
            self.assertEqual(rename.argtypes,
                             (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint))
            rename.return_value = -1
            with patch.object(ctypes, "get_errno", return_value=errno.EEXIST):
                with self.assertRaisesRegex(helper.Refusal, "local work preserved"):
                    helper.promote_workspace(Path("stage"), Path("destination"))


class CheckoutTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="assist-git-test-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.source, seed, self.phone = (root / name for name in
                                         ("source.git", "seed", "phone"))
        self.workspaces = root / "workspaces"
        self.workspaces.mkdir(mode=0o700)
        git("init", "--bare", self.source)
        git("init", "-b", "main", seed)
        commit(seed, "README", "initial\n")
        git("remote", "add", "origin", self.source, cwd=seed)
        git("push", "origin", "main", cwd=seed)
        git("switch", "-c", "assist/thread", cwd=seed)
        git("push", "origin", "assist/thread", cwd=seed)
        git("clone", "--no-hardlinks", "-b", "assist/thread", self.source, self.phone)
        environment = {"PATH": "/usr/bin:/bin", "HOME": str(root),
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                       "GIT_NO_REPLACE_OBJECTS": "1", "GIT_TERMINAL_PROMPT": "0",
                       "GIT_SSH_COMMAND": "ssh -F /dev/null", "LC_ALL": "C"}
        self.real_configuration = helper.configuration
        self.configured = patch.object(helper, "configuration", return_value=
                                       (str(self.source), environment))
        self.configured.start()
        self.addCleanup(self.configured.stop)
        self.request = {"action": "sync", "workspace_root": str(self.workspaces),
                        "repo_key": "a" * 20, "thread_id": "thread-1",
                        "branch": "assist/thread"}

    def test_new_checkout_and_later_phone_push_fast_forward(self):
        first = helper.sync(self.request)
        checkout = Path(first["checkout_path"])
        self.assertTrue(checkout.is_relative_to(self.workspaces))
        self.assertEqual(git("rev-parse", "HEAD", cwd=checkout), first["thread_oid"])
        self.assertIsNone(first["pending"])
        phone_tip = commit(self.phone, "phone.txt", "explicit phone push\n")
        git("push", "origin", "assist/thread", cwd=self.phone)
        updated = helper.sync(self.request)
        self.assertEqual(updated["local_oid"], phone_tip)
        self.assertEqual(updated["thread_oid"], phone_tip)
        self.assertEqual((checkout / "phone.txt").read_text(), "explicit phone push\n")
        self.assertEqual(git("rev-parse", "refs/remotes/origin/main", cwd=checkout),
                         first["main_oid"])

    def test_dirty_and_unpushed_local_work_survive_refresh(self):
        checkout = Path(helper.sync(self.request)["checkout_path"])
        (checkout / "draft.txt").write_text("unsaved phone edit\n")
        before_index = (checkout / ".git" / "index").read_bytes()
        remote = commit(self.phone, "remote.txt", "server or other phone commit\n")
        git("push", "origin", "assist/thread", cwd=self.phone)
        blocked = helper.sync(self.request)
        self.assertEqual(blocked["thread_oid"], remote)
        self.assertNotEqual(blocked["local_oid"], remote)
        self.assertTrue(blocked["dirty"])
        self.assertIn("local edits are unchanged", blocked["pending"])
        self.assertEqual((checkout / "draft.txt").read_text(), "unsaved phone edit\n")
        self.assertEqual((checkout / ".git" / "index").read_bytes(), before_index)
        (checkout / "draft.txt").unlink()
        local = commit(checkout, "local.txt", "not pushed\n")
        blocked = helper.sync(self.request)
        self.assertEqual(blocked["local_oid"], local)
        self.assertEqual(blocked["thread_oid"], remote)
        self.assertIn("diverged", blocked["pending"])
        self.assertEqual(git("rev-parse", "refs/heads/assist/thread", cwd=self.source),
                         remote)

    def test_clean_local_ahead_remains_ahead_after_refresh(self):
        checkout = Path(helper.sync(self.request)["checkout_path"])
        local = commit(checkout, "local.txt", "unpushed\n")
        result = helper.sync(self.request)
        self.assertEqual(result["local_oid"], local)
        self.assertNotEqual(result["local_oid"], result["thread_oid"])
        self.assertFalse(result["dirty"])
        self.assertIn("not published", result["pending"])
        self.assertEqual(git("rev-parse", "HEAD", cwd=checkout), local)

    def test_checkout_local_config_cannot_redirect_credentialed_fetch(self):
        checkout = Path(helper.sync(self.request)["checkout_path"])
        marker = Path(self.temporary.name) / "redirect-ran"
        git("config", "url.ext::sh -c 'touch " + str(marker) + "'.insteadOf",
            "refs/heads/", cwd=checkout)
        commit(self.phone, "later.txt", "later\n")
        git("push", "origin", "assist/thread", cwd=self.phone)
        self.assertTrue(helper.sync(self.request)["ok"])
        self.assertFalse(marker.exists())

    def test_checkout_ref_symlink_cannot_redirect_local_fast_forward(self):
        checkout = Path(helper.sync(self.request)["checkout_path"])
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        heads = checkout / ".git" / "refs" / "heads"
        for child in heads.iterdir():
            if child.is_dir():
                for leaf in child.iterdir():
                    leaf.unlink()
                child.rmdir()
            else:
                child.unlink()
        heads.rmdir()
        heads.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(helper.Refusal, "bound directory"):
            helper.sync(self.request)
        self.assertEqual(list(outside.iterdir()), [])

    def test_checkout_core_worktree_cannot_redirect_local_fast_forward(self):
        checkout = Path(helper.sync(self.request)["checkout_path"])
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        git("config", "core.worktree", outside, cwd=checkout)
        with self.assertRaisesRegex(helper.Refusal, "configuration"):
            helper.sync(self.request)
        self.assertEqual(list(outside.iterdir()), [])

    def test_checkout_commondir_cannot_redirect_local_fast_forward(self):
        checkout = Path(helper.sync(self.request)["checkout_path"])
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        (checkout / ".git" / "commondir").write_text(str(outside) + "\n")
        with self.assertRaisesRegex(helper.Refusal, "metadata"):
            helper.sync(self.request)
        self.assertEqual(list(outside.iterdir()), [])

    def test_helper_termination_reaps_credentialed_git_child(self):
        root = Path(self.temporary.name)
        executable = root / "git"
        ready = root / "ready.fifo"
        os.mkfifo(ready, 0o600)
        executable.write_text(
            "#!/usr/bin/env python3\n"
            "import os, time\n"
            "with open(os.environ['READY_FIFO'], 'w') as connection:\n"
            "    connection.write(str(os.getpid()) + '\\n')\n"
            "time.sleep(30)\n")
        executable.chmod(0o700)
        code = (
            "import importlib.util, os, signal, sys\n"
            "spec = importlib.util.spec_from_file_location('helper', sys.argv[1])\n"
            "helper = importlib.util.module_from_spec(spec)\n"
            "spec.loader.exec_module(helper)\n"
            "signal.signal(signal.SIGTERM, helper.stop_on_signal)\n"
            "helper.git(['version'], dict(os.environ), seconds=30)\n")
        environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                           READY_FIFO=str(ready))
        descriptor = os.open(ready, os.O_RDWR | os.O_NONBLOCK)
        try:
            process = subprocess.Popen([sys.executable, "-c", code, str(SCRIPT)],
                                       env=environment, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL)
            child = None
            try:
                readable, _, _ = select.select([descriptor], [], [], 5)
                self.assertTrue(readable, "Git child did not start")
                child = int(os.read(descriptor, 32))
                os.kill(process.pid, signal.SIGTERM)
                self.assertEqual(process.wait(timeout=5), 128 + signal.SIGTERM)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                if child is not None:
                    try:
                        os.kill(child, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
        finally:
            os.close(descriptor)

    def test_duplicate_repo_key_in_private_map_is_rejected(self):
        config = Path(self.temporary.name) / "config"
        config.mkdir(mode=0o700)
        key = self.request["repo_key"]
        (config / "assist-git-remotes.json").write_text(
            '{"' + key + '":"ssh://git@example.test/one.git","' + key
            + '":"ssh://git@example.test/two.git"}')
        (config / "assist-git-key").write_text("placeholder")
        (config / "assist-git-known-hosts").write_text("placeholder")
        for path in config.iterdir():
            os.chmod(path, 0o600)
        with self.assertRaisesRegex(helper.Refusal, "duplicate"):
            self.real_configuration(config, key)

    def legacy_fixture(self, relative=False):
        cache = Path(self.temporary.name) / "cache"
        for name in ("routes", "checkouts", "locks"):
            (cache / name).mkdir(parents=True, mode=0o700)
        key = self.request["repo_key"] + "\n" + self.request["thread_id"]
        route_id = hashlib.sha256(key.encode()).hexdigest()
        legacy_id = hashlib.sha256((key + "\n" + self.request["branch"]).encode()).hexdigest()
        relative_path = "repo/thread-" + route_id[:12] if relative else None
        old = (self.workspaces / relative_path if relative_path
               else cache / "checkouts" / legacy_id)
        old.parent.mkdir(parents=True, exist_ok=True)
        git("clone", "--no-hardlinks", "-b", self.request["branch"], self.source, old)
        (old / "draft.txt").write_text("unchanged private draft\n")
        route = cache / "routes" / (route_id + ".json")
        route.write_text(json.dumps({"repo_key": self.request["repo_key"],
                                     "thread_id": self.request["thread_id"],
                                     "legacy": None if relative else legacy_id,
                                     "relative": relative_path,
                                     "initialized": True}))
        os.chmod(route, 0o600)
        return cache, old

    def test_explicit_legacy_migration_preserves_dirty_bytes_and_index(self):
        cache, old = self.legacy_fixture()
        before_index = (old / ".git" / "index").read_bytes()
        with self.assertRaisesRegex(helper.Refusal, "explicit migration"):
            helper.sync(self.request, cache=cache)
        self.assertTrue(old.exists())
        result = helper.migrate(self.request, cache=cache)
        checkout = Path(result["checkout_path"])
        self.assertFalse(old.exists())
        self.assertEqual((checkout / "draft.txt").read_text(), "unchanged private draft\n")
        self.assertEqual((checkout / ".git" / "index").read_bytes(), before_index)
        self.assertEqual(git("status", "--short", cwd=checkout), "?? draft.txt")
        self.assertEqual(git("rev-parse", "HEAD", cwd=checkout),
                         git("rev-parse", "HEAD", cwd=self.phone))
        self.assertTrue(helper.sync(self.request, cache=cache)["ok"])

    def test_migration_refuses_existing_target_without_touching_legacy(self):
        cache, old = self.legacy_fixture()
        target = helper.checkout_path(self.workspaces, self.request["repo_key"],
                                      self.request["thread_id"])
        target.parent.mkdir()
        target.mkdir()
        with self.assertRaises(helper.Refusal):
            helper.migrate(self.request, cache=cache)
        self.assertEqual((old / "draft.txt").read_text(), "unchanged private draft\n")

    def test_explicit_migration_of_old_named_workspace_preserves_dirty_work(self):
        cache, old = self.legacy_fixture(relative=True)
        result = helper.migrate(self.request, cache=cache)
        checkout = Path(result["checkout_path"])
        self.assertFalse(old.exists())
        self.assertEqual((checkout / "draft.txt").read_text(), "unchanged private draft\n")
        self.assertTrue(helper.sync(self.request, cache=cache)["dirty"])


if __name__ == "__main__":
    unittest.main()
