"""Real local Git coverage for the off-loop Assist mirror helper."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


MODULE = Path(__file__).resolve().parents[1] / "assist-web-git-helper.py"
SPEC = importlib.util.spec_from_file_location("assist_web_git_helper", MODULE)
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


def run(*args: str) -> str:
    return subprocess.check_output(["git", *args], text=True,
                                   stderr=subprocess.DEVNULL).strip()


class GitHelperTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "source"
        self.bare = self.root / "remote.git"
        self.cache = self.root / "cache"
        run("init", "-q", "-b", "main", str(self.repo))
        run("-C", str(self.repo), "config", "user.email", "sam@example.invalid")
        run("-C", str(self.repo), "config", "user.name", "Sam")
        (self.repo / "hello.txt").write_text("main\n")
        run("-C", str(self.repo), "add", "hello.txt")
        run("-C", str(self.repo), "commit", "-qm", "main")
        run("init", "-q", "--bare", str(self.bare))
        run("-C", str(self.repo), "remote", "add", "origin", str(self.bare))
        run("-C", str(self.repo), "push", "-q", "origin", "main")
        run("-C", str(self.repo), "switch", "-qc", "thread/one")
        (self.repo / "hello.txt").write_text("thread\n")
        (self.repo / "other.txt").write_text("committed\n")
        run("-C", str(self.repo), "add", ".")
        run("-C", str(self.repo), "commit", "-qm", "thread")
        run("-C", str(self.repo), "push", "-q", "origin", "thread/one")
        self.thread_oid = run("-C", str(self.repo), "rev-parse", "HEAD")
        self.main_oid = run("-C", str(self.repo), "rev-parse", "main")

    def request(self, branch="thread/one", generation="a" * 32):
        return {"repo_key": "b" * 20, "branch": branch,
                "generation": generation, "cache_root": str(self.cache),
                "expected_oid": self.thread_oid}

    def isolated_env(self, _key, _hosts):
        return {"PATH": "/usr/bin:/bin", "HOME": str(self.root),
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_ALLOW_PROTOCOL": "file",
                "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"}

    def test_invalid_or_missing_branch_never_installs_checkout(self):
        for branch in ("main", "HEAD", "-option", "bad..ref", "thread/missing"):
            with self.subTest(branch=branch):
                with self.assertRaises(helper.Refusal):
                    self.sync(branch=branch)
        self.assertFalse(any((self.cache / "checkouts").glob("*")))

    def test_private_map_refuses_duplicate_keys_and_credential_url(self):
        config = self.root / ".config" / "emacsos"
        config.mkdir(parents=True)
        key = "b" * 20
        (config / "assist-git-key").write_text("Git credential\n")
        (config / "assist-git-known-hosts").write_text("host key\n")
        for name in ("assist-git-key", "assist-git-known-hosts"):
            (config / name).chmod(0o600)
        mapping = config / "assist-git-remotes.json"
        mapping.write_text(json.dumps({key: "ssh://git@host.example/repo.git"}))
        mapping.chmod(0o600)
        with patch.dict(os.environ, {"HOME": str(self.root)}):
            self.assertEqual(helper.configuration()[0][key],
                             "ssh://git@host.example/repo.git")
            mapping.write_text(
                '{"' + key + '":"ssh://git@host.example/repo.git",'
                '"' + key + '":"ssh://git@host.example/other.git"}')
            with self.assertRaises(helper.Refusal):
                helper.configuration()
            mapping.write_text(json.dumps(
                {key: "ssh://git:secret@host.example/repo.git"}))
            with self.assertRaises(helper.Refusal):
                helper.configuration()
            mapping.chmod(0o644)
            with self.assertRaises(helper.Refusal):
                helper.configuration()

    def sync(self, **changes):
        request = {**self.request(), "thread_id": "thread-1", "allow_ff": True,
                   **changes}
        with patch.object(helper, "configuration",
                          return_value=({"b" * 20: str(self.bare)},
                                        self.root / "key", self.root / "hosts")), \
             patch.object(helper, "git_environment", side_effect=self.isolated_env):
            return helper.sync_checkout(request)

    def publish_update(self, text="next committed turn\n"):
        (self.repo / "hello.txt").write_text(text)
        run("-C", str(self.repo), "add", "hello.txt")
        run("-C", str(self.repo), "commit", "-qm", "next")
        run("-C", str(self.repo), "push", "-q", "origin", "thread/one")
        return run("-C", str(self.repo), "rev-parse", "HEAD")

    def test_persistent_checkout_fast_forwards_without_reset_or_delete(self):
        first = self.sync()
        checkout = Path(first["checkout_path"])
        self.assertEqual(run("-C", str(checkout), "branch", "--show-current"), "thread/one")
        self.assertEqual(run("-C", str(checkout), "remote", "get-url", "origin"), str(self.bare))
        self.assertEqual(run("-C", str(checkout), "rev-parse", "@{upstream}"), self.thread_oid)
        next_oid = self.publish_update()
        result = self.sync(expected_oid=next_oid)
        self.assertEqual(result["checkout_path"], str(checkout))
        self.assertEqual(result["local_oid"], next_oid)
        self.assertEqual(result["thread_oid"], next_oid)
        self.assertIsNone(result["pending"])

    def test_busy_remote_advance_is_visible_without_expected_equality(self):
        self.sync()
        next_oid = self.publish_update()
        result = self.sync(allow_ff=False)
        self.assertEqual(result["thread_oid"], next_oid)
        self.assertEqual(result["local_oid"], self.thread_oid)
        self.assertFalse(result["expected_matches"])
        self.assertTrue(result["pending"])

    def test_local_staged_unstaged_untracked_edits_survive_refresh(self):
        for kind in ("unstaged", "staged", "untracked"):
            with self.subTest(kind=kind):
                # Each case has a separate persistent checkout, same trusted remote.
                result = self.sync(thread_id="thread-" + kind)
                checkout = Path(result["checkout_path"])
                target = checkout / ("local.txt" if kind == "untracked" else "hello.txt")
                target.write_text("my edit\n")
                if kind == "staged":
                    run("-C", str(checkout), "add", "hello.txt")
                updated = self.sync(thread_id="thread-" + kind)
                self.assertTrue(updated["dirty"])
                self.assertTrue(updated["pending"])
                self.assertEqual(target.read_text(), "my edit\n")

    def test_manual_commit_push_uses_ordinary_thread_upstream(self):
        checkout = Path(self.sync()["checkout_path"])
        run("-C", str(checkout), "config", "user.email", "sam@example.invalid")
        run("-C", str(checkout), "config", "user.name", "Sam")
        (checkout / "hello.txt").write_text("phone edit\n")
        run("-C", str(checkout), "add", "hello.txt")
        run("-C", str(checkout), "commit", "-qm", "phone")
        run("-C", str(checkout), "push", "-q", "origin", "thread/one")
        oid = run("-C", str(checkout), "rev-parse", "HEAD")
        result = self.sync()
        self.assertEqual(result["thread_oid"], oid)
        self.assertEqual(result["local_oid"], oid)
        self.assertFalse(result["expected_matches"])

    def test_local_main_checkout_is_not_silently_repaired(self):
        checkout = Path(self.sync()["checkout_path"])
        run("-C", str(checkout), "switch", "-qc", "main", "origin/main")
        result = self.sync()
        self.assertEqual(result["actual_branch"], "main")
        self.assertTrue(result["pending"])
        self.assertEqual(run("-C", str(checkout), "branch", "--show-current"), "main")

    def test_many_untracked_files_preserve_remote_view(self):
        checkout = Path(self.sync()["checkout_path"])
        for index in range(150):
            (checkout / ("user-local-file-with-long-name-" + str(index))).write_text("edit")
        result = self.sync()
        self.assertTrue(result["dirty"])
        self.assertEqual(result["thread_oid"], self.thread_oid)
        self.assertEqual(len(list(checkout.glob("user-local-file-*"))), 150)

    def test_clean_unpushed_commit_is_pending_not_remote_current(self):
        checkout = Path(self.sync()["checkout_path"])
        run("-C", str(checkout), "config", "user.email", "sam@example.invalid")
        run("-C", str(checkout), "config", "user.name", "Sam")
        (checkout / "hello.txt").write_text("unpushed phone commit\n")
        run("-C", str(checkout), "add", "hello.txt")
        run("-C", str(checkout), "commit", "-qm", "phone")
        local_oid = run("-C", str(checkout), "rev-parse", "HEAD")
        result = self.sync()
        self.assertFalse(result["dirty"])
        self.assertEqual(result["local_oid"], local_oid)
        self.assertEqual(result["thread_oid"], self.thread_oid)
        self.assertIn("local commits", result["pending"])

    def test_repository_ident_expansion_is_disabled_before_checkout(self):
        (self.repo / ".gitattributes").write_text("bomb.txt ident\n")
        literal = "$Id$" * (256 * 1024)
        (self.repo / "bomb.txt").write_text(literal)
        run("-C", str(self.repo), "add", ".gitattributes", "bomb.txt")
        run("-C", str(self.repo), "commit", "-qm", "ident expansion")
        run("-C", str(self.repo), "push", "-q", "origin", "thread/one")
        with patch.object(helper, "WORKTREE_LIMIT", 2 * 1024 * 1024):
            checkout = Path(self.sync()["checkout_path"])
            self.assertEqual((checkout / "bomb.txt").read_text(), literal)
            run("-C", str(checkout), "checkout", "--", "bomb.txt")
            self.assertEqual((checkout / "bomb.txt").read_text(), literal)

    def fake_git_tree(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        marker = self.root / "survived"
        fake_git = bin_dir / "git"
        child = ("import os, signal, time, pathlib; "
                 "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                 "time.sleep(2); "
                 "pathlib.Path(os.environ['TEST_MARKER']).write_text('alive')")
        fake_git.write_text(
            "#!" + sys.executable + "\n"
            "import os, signal, subprocess, sys, time\n"
            f"subprocess.Popen([sys.executable, '-c', {child!r}], "
            "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
            "signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))\n"
            "time.sleep(20)\n"
        )
        fake_git.chmod(0o700)
        env = {"PATH": str(bin_dir), "HOME": str(self.root),
               "GIT_CONFIG_NOSYSTEM": "1", "TEST_MARKER": str(marker)}
        return env, marker

    def test_git_timeout_kills_descendant_after_parent_exits(self):
        env, marker = self.fake_git_tree()
        # The fake Git's child ignores TERM; the helper must kill the entire
        # session even if its direct child exits promptly.
        with self.assertRaises(helper.Refusal):
            helper.git([], env, seconds=1)
        time.sleep(2.2)
        self.assertFalse(marker.exists())

    def test_outer_timeout_cancels_inner_git_tree(self):
        env, marker = self.fake_git_tree()
        command = (
            "import importlib.util, signal; "
            f"spec=importlib.util.spec_from_file_location('helper', {str(MODULE)!r}); "
            "module=importlib.util.module_from_spec(spec); "
            "spec.loader.exec_module(module); "
            "signal.signal(signal.SIGTERM, module.stop_on_signal); "
            "import os; module.git([], dict(os.environ), seconds=20)"
        )
        with self.assertRaises(subprocess.CalledProcessError):
            subprocess.check_output(
                [shutil.which("setsid"), shutil.which("timeout"),
                 "--kill-after=2", "1", sys.executable,
                 "-B", "-c", command], env={**os.environ, **env},
                stderr=subprocess.DEVNULL, timeout=8)
        time.sleep(2.2)
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
