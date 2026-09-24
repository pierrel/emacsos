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

    def test_fetches_exact_two_refs_and_checks_out_thread(self):
        with patch.object(helper, "configuration",
                          return_value=({"b" * 20: str(self.bare),
                                         "c" * 20: str(self.bare)},
                                        self.root / "key", self.root / "hosts")), \
             patch.object(helper, "git_environment",
                          side_effect=self.isolated_env):
            result = helper.refresh(self.request())
        self.assertTrue(result["ok"])
        self.assertEqual(result["thread_oid"], self.thread_oid)
        self.assertEqual(result["main_oid"], self.main_oid)
        stage = self.cache / "staging" / ("a" * 32)
        self.assertEqual(run("-C", str(stage), "branch", "--show-current"),
                         "thread/one")
        self.assertEqual((stage / "hello.txt").read_text(), "thread\n")
        self.assertEqual(run("-C", str(stage), "rev-parse", "main"),
                         self.main_oid)
        self.assertEqual(run("-C", str(stage), "status", "--porcelain"), "")
        self.assertEqual(self.cache.stat().st_mode & 0o777, 0o700)
        self.assertEqual(helper.cleanup({"cache_root": str(self.cache),
                                         "kind": "staging",
                                         "generation": "a" * 32}),
                         {"ok": True})
        self.assertFalse(stage.exists())

    def test_invalid_or_missing_branch_leaves_no_staging(self):
        with patch.object(helper, "configuration",
                          return_value=({"b" * 20: str(self.bare)},
                                        self.root / "key", self.root / "hosts")), \
             patch.object(helper, "git_environment",
                          side_effect=self.isolated_env):
            for branch, generation in (
                    ("main", "a" * 32),
                    ("bad..ref", "c" * 32),
                    ("thread/missing", "d" * 32)):
                with self.assertRaises(helper.Refusal):
                    helper.refresh(self.request(branch, generation))
                self.assertFalse((self.cache / "staging" / generation).exists())

    def test_fetched_oid_must_equal_authenticated_expected_before_checkout(self):
        request = self.request()
        request["expected_oid"] = self.main_oid
        with patch.object(helper, "configuration",
                          return_value=({"b" * 20: str(self.bare)},
                                        self.root / "key", self.root / "hosts")), \
             patch.object(helper, "git_environment",
                          side_effect=self.isolated_env):
            with self.assertRaisesRegex(helper.Refusal, "remote update pending"):
                helper.refresh(request)
        self.assertFalse((self.cache / "staging" / ("a" * 32)).exists())

    def test_private_map_refuses_duplicate_keys_and_credential_url(self):
        config = self.root / ".config" / "emacsos"
        config.mkdir(parents=True)
        key = "b" * 20
        (config / "assist-git-read-key").write_text("read credential\n")
        (config / "assist-git-known-hosts").write_text("host key\n")
        for name in ("assist-git-read-key", "assist-git-known-hosts"):
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
