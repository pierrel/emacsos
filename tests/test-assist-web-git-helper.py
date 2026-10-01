"""Real local Git coverage for the off-loop Assist mirror helper."""

import importlib.util
import fcntl
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


class HelperInputBoundaryTest(unittest.TestCase):
    """Helper input and local failures return fixed JSON categories."""

    def test_missing_private_git_configuration_names_only_fixed_file(self):
        files = {
            "assist-git-remotes.json": ("{}", "Git repository map unavailable"),
            "assist-git-key": ("test key\n", "Git key unavailable"),
            "assist-git-known-hosts": ("test host\n", "Git host pin unavailable"),
        }
        with tempfile.TemporaryDirectory() as home:
            config = Path(home) / ".config" / "emacsos"
            config.mkdir(parents=True)
            for name, (content, _) in files.items():
                target = config / name
                target.write_text(content)
                target.chmod(0o600)
            for name, (_, reason) in files.items():
                with self.subTest(file=name):
                    target = config / name
                    target.rename(config / (name + ".held"))
                    result = subprocess.run(
                        [sys.executable, "-B", str(MODULE), "--check-config"],
                        env={**os.environ, "HOME": home}, text=True,
                        capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, 0)
                    self.assertEqual(result.stderr, "")
                    self.assertEqual(json.loads(result.stdout),
                                     {"ok": False, "reason": reason})
                    (config / (name + ".held")).rename(target)

            request = {"action": "sync", "repo_key": "b" * 20,
                       "branch": "thread/one", "thread_id": "thread-1",
                       "cache_root": str(Path(home) / "cache"),
                       "workspace_root": str(Path(home) / "workspaces"),
                       "checkout_path": str(Path(home) / "workspaces" / "thread")}
            mapping = config / "assist-git-remotes.json"
            mapping.rename(config / "assist-git-remotes.json.held")
            result = subprocess.run([sys.executable, "-B", str(MODULE)],
                                    input=json.dumps(request),
                                    env={**os.environ, "HOME": home}, text=True,
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stderr, "")
            self.assertEqual(json.loads(result.stdout),
                             {"ok": False, "reason": "Git repository map unavailable"})
            self.assertFalse((Path(home) / "cache").exists())

    def test_other_local_io_and_invalid_json_have_safe_categories(self):
        with tempfile.TemporaryDirectory() as directory:
            regular = Path(directory) / "regular"
            regular.write_text("not a directory")
            request = {"action": "cleanup", "cache_root": str(regular / "cache"),
                       "generation": "a" * 32, "kind": "staging"}
            result = subprocess.run([sys.executable, "-B", str(MODULE)],
                                    input=json.dumps(request), text=True,
                                    capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        self.assertEqual(json.loads(result.stdout),
                         {"ok": False, "reason": "Git mirror local I/O unavailable"})
        malformed = subprocess.run([sys.executable, "-B", str(MODULE)],
                                   input="{", text=True,
                                   capture_output=True, timeout=5)
        self.assertEqual(malformed.returncode, 0)
        self.assertEqual(malformed.stderr, "")
        self.assertEqual(json.loads(malformed.stdout),
                         {"ok": False, "reason": "Git mirror local data invalid"})

    def assert_refusal(self, action, root, *, missing=False):
        request = {"action": action, "repo_key": "b" * 20,
                   "branch": "thread/one", "thread_id": "thread-1",
                   "generation": "a" * 32, "kind": "staging"}
        if not missing:
            request["cache_root"] = root
        result = subprocess.run([sys.executable, "-B", str(MODULE)],
                                input=json.dumps(request), text=True,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        self.assertEqual(json.loads(result.stdout), {
            "ok": False, "reason": "cleanup request is invalid" if action == "cleanup"
            else "checkout request metadata is invalid"})

    def test_non_string_cache_roots_return_json(self):
        for action in ("sync", "cleanup"):
            for root in (None, [], {}, 7, True, False):
                with self.subTest(action=action, root=root):
                    self.assert_refusal(action, root)

    def test_missing_and_relative_cache_roots_keep_fixed_refusal(self):
        for action in ("sync", "cleanup"):
            self.assert_refusal(action, None, missing=True)
            for root in ("", "relative-cache", "../cache"):
                with self.subTest(action=action, root=root):
                    self.assert_refusal(action, root)


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
                "workspace_root": str(self.root / "workspaces")}

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
        identity = helper.stable_identity(request["repo_key"], request["thread_id"])
        route = self.cache / "routes" / (identity + ".json")
        if route.exists():
            checkout = helper.route_path(helper.read_route(route), self.cache,
                                         self.root / "workspaces", request["repo_key"], request["thread_id"])
        else:
            legacy = self.cache / "checkouts" / __import__("hashlib").sha256(
                (request["repo_key"] + "\n" + request["thread_id"] + "\n" + request["branch"]).encode()).hexdigest()
            choice = request.get("workspace_choice")
            if legacy.exists():
                checkout = legacy
            elif choice and choice != "new":
                checkout = self.cache / "checkouts" / choice
            else:
                checkout = (self.root / "workspaces" / helper.workspace_slug(request.get("repo_label"), "repo")
                            / (helper.workspace_slug(request.get("thread_label"), "thread") + "-" + identity[:12]))
        request.setdefault("checkout_path", str(checkout))
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

    def legacy_checkout(self, tid="old-thread", branch="thread/one", remote=None):
        """Make an old managed checkout, not a newly allocated workspace route."""
        identity = __import__("hashlib").sha256(("b" * 20 + "\n" + tid + "\n" + branch).encode()).hexdigest()
        checkout = self.cache / "checkouts" / identity
        checkout.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.cache.chmod(0o700)
        run("clone", "-q", "--branch", branch, str(remote or self.bare), str(checkout))
        checkout.chmod(0o700)
        (checkout / ".git" / "info" / "attributes").write_text(
            "* -filter -ident -working-tree-encoding -text -eol\n")
        return checkout

    def test_readable_workspace_name_is_frozen_across_names_and_branches(self):
        first = self.sync(repo_label="Project Notes", thread_label="Plan the week")
        checkout = Path(first["checkout_path"])
        self.assertEqual(checkout.parent.name, "project-notes")
        self.assertEqual(checkout.name, "plan-the-week-" + helper.stable_identity("b" * 20, "thread-1")[:12])
        renamed = self.sync(repo_label="Renamed", thread_label="New title")
        self.assertEqual(renamed["checkout_path"], str(checkout))
        run("-C", str(self.repo), "branch", "thread/two")
        run("-C", str(self.repo), "push", "-q", "origin", "thread/two")
        old_head = run("-C", str(checkout), "rev-parse", "HEAD")
        result = self.sync(branch="thread/two")
        self.assertEqual(result["checkout_path"], str(checkout))
        self.assertEqual(result["actual_branch"], "thread/one")
        self.assertTrue(result["pending"])
        self.assertEqual(run("-C", str(checkout), "rev-parse", "HEAD"), old_head)

    def test_same_labels_different_threads_and_malicious_labels_are_separate(self):
        first = Path(self.sync(repo_label="../../Project", thread_label="--../..Plan") ["checkout_path"])
        second = Path(self.sync(thread_id="thread-2", repo_label="Project", thread_label="Plan")["checkout_path"])
        self.assertNotEqual(first, second)
        self.assertEqual(first.parent, second.parent)
        self.assertTrue(first.is_relative_to(self.root / "workspaces"))

    def test_existing_user_root_is_not_chmodded(self):
        root = self.root / "workspaces"
        root.mkdir(mode=0o755)
        self.sync()
        self.assertEqual(root.stat().st_mode & 0o777, 0o755)

    def test_concurrent_creation_of_shared_repo_directory_preserves_peer_inode(self):
        target = self.root / "workspaces" / "repo"
        original = Path.mkdir
        peer = []

        def concurrent(path, *args, **options):
            if path == target and not path.exists():
                original(path, mode=0o755)
                peer.append(path.stat().st_ino)
            return original(path, *args, **options)

        with patch.object(Path, "mkdir", new=concurrent):
            self.sync()
        self.assertEqual([target.stat().st_ino], peer)
        self.assertEqual(target.stat().st_mode & 0o777, 0o755)

    def test_exact_legacy_checkout_registers_in_place_preserving_user_state(self):
        for kind in ("unstaged", "staged", "untracked", "local-commit"):
            with self.subTest(kind=kind):
                tid = "legacy-" + kind
                checkout = self.legacy_checkout(tid)
                target = checkout / ("local.txt" if kind == "untracked" else "hello.txt")
                target.write_text("user work\n")
                if kind in ("staged", "local-commit"):
                    run("-C", str(checkout), "add", "hello.txt")
                if kind == "local-commit":
                    run("-C", str(checkout), "-c", "user.name=Sam", "-c", "user.email=sam@example.invalid",
                        "commit", "-qm", "local")
                inode, index = checkout.stat().st_ino, (checkout / ".git" / "index").read_bytes()
                head = run("-C", str(checkout), "rev-parse", "HEAD")
                result = self.sync(thread_id=tid)
                self.assertEqual(result["checkout_path"], str(checkout))
                self.assertEqual(checkout.stat().st_ino, inode)
                self.assertEqual(target.read_text(), "user work\n")
                self.assertEqual(run("-C", str(checkout), "rev-parse", "HEAD"), head)
                self.assertEqual((checkout / ".git" / "index").read_bytes(), index)
                self.assertTrue(result["pending"])

    def test_ambiguous_legacy_requires_choice_and_never_replaces_user_files(self):
        checkout = self.legacy_checkout()
        (checkout / "personal.txt").write_text("keep\n")
        with self.assertRaises(helper.WorkspaceChoice) as refused:
            self.sync()
        self.assertEqual(refused.exception.choices[0]["identity"], checkout.name)
        self.assertFalse((self.root / "workspaces").exists())
        result = self.sync(workspace_choice=checkout.name)
        self.assertEqual(result["checkout_path"], str(checkout))
        self.assertEqual((checkout / "personal.txt").read_text(), "keep\n")
        with self.assertRaisesRegex(helper.Refusal, "already bound"):
            self.sync(thread_id="other-thread", workspace_choice=checkout.name)

    def test_unrelated_repository_legacy_does_not_block_new_workspace(self):
        checkout = self.legacy_checkout()
        run("-C", str(checkout), "remote", "set-url", "origin", str(self.root / "another.git"))
        self.assertTrue(Path(self.sync()["checkout_path"]).is_relative_to(self.root / "workspaces"))

    def test_bound_legacy_is_not_an_ambiguous_candidate_for_a_new_thread(self):
        checkout = self.legacy_checkout("thread-1")
        self.sync()
        result = self.sync(thread_id="thread-2")
        self.assertNotEqual(result["checkout_path"], str(checkout))
        self.assertTrue(Path(result["checkout_path"]).is_relative_to(self.root / "workspaces"))

    def test_detached_unbound_legacy_still_offers_explicit_new_choice(self):
        checkout = self.legacy_checkout()
        run("-C", str(checkout), "checkout", "--detach", "-q")
        before = checkout.stat().st_ino, (checkout / ".git" / "HEAD").read_bytes()
        with self.assertRaises(helper.WorkspaceChoice) as refused:
            self.sync()
        self.assertEqual(refused.exception.choices, [{"identity": checkout.name, "branch": "detached"}])
        self.sync(workspace_choice="new")
        self.assertEqual((checkout.stat().st_ino, (checkout / ".git" / "HEAD").read_bytes()), before)

    def test_legacy_choice_inventory_never_silently_truncates(self):
        for index in range(17):
            self.legacy_checkout("old-" + str(index))
        with self.assertRaisesRegex(helper.Refusal, "inventory exceeds"):
            self.sync()

    def test_route_cannot_alias_another_threads_workspace(self):
        checkout = Path(self.sync()["checkout_path"])
        identity = helper.stable_identity("b" * 20, "thread-2")
        route = self.cache / "routes" / (identity + ".json")
        helper.write_route(route, {"repo_key": "b" * 20, "thread_id": "thread-2",
                                   "legacy": None, "relative": str(checkout.relative_to(self.root / "workspaces")),
                                   "initialized": True})
        before = checkout.stat().st_ino, (checkout / ".git" / "index").read_bytes()
        with patch.object(helper, "git", wraps=helper.git) as invoked:
            with self.assertRaisesRegex(helper.Refusal, "binding is invalid"):
                self.sync(thread_id="thread-2", checkout_path=str(checkout))
        self.assertFalse(any("fetch" in call.args[0] for call in invoked.call_args_list))
        self.assertEqual((checkout.stat().st_ino, (checkout / ".git" / "index").read_bytes()), before)

    def test_duplicate_legacy_bindings_refuse_before_fetch(self):
        checkout = self.legacy_checkout("thread-1")
        self.sync()
        identity = helper.stable_identity("b" * 20, "thread-2")
        helper.write_route(self.cache / "routes" / (identity + ".json"),
                           {"repo_key": "b" * 20, "thread_id": "thread-2", "legacy": checkout.name,
                            "relative": None, "initialized": True})
        with patch.object(helper, "git", wraps=helper.git) as invoked:
            with self.assertRaisesRegex(helper.Refusal, "already bound"):
                self.sync(thread_id="thread-2")
        self.assertFalse(any("fetch" in call.args[0] for call in invoked.call_args_list))

    def test_explicit_new_choice_leaves_unattributed_legacy_in_place(self):
        checkout = self.legacy_checkout()
        before = checkout.stat().st_ino
        result = self.sync(workspace_choice="new")
        self.assertNotEqual(result["checkout_path"], str(checkout))
        self.assertEqual(checkout.stat().st_ino, before)

    def test_symlink_root_and_occupied_destination_are_never_overwritten(self):
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        (self.root / "workspaces").symlink_to(elsewhere, target_is_directory=True)
        with self.assertRaises(helper.Refusal):
            self.sync()
        self.assertFalse(list(elsewhere.iterdir()))
        (self.root / "workspaces").unlink()
        identity = helper.stable_identity("b" * 20, "thread-1")
        destination = self.root / "workspaces" / "repo" / ("thread-" + identity[:12])
        destination.mkdir(parents=True)
        (destination / "user.txt").write_text("keep")
        with self.assertRaisesRegex(helper.Refusal, "already exists"):
            self.sync()
        self.assertEqual((destination / "user.txt").read_text(), "keep")

    def test_bound_uninitialized_workspace_refuses_replaced_parent(self):
        with self.assertRaises(helper.Refusal):
            self.sync(branch="thread/missing", repo_label="Notes")
        route = self.cache / "routes" / (
            helper.stable_identity("b" * 20, "thread-1") + ".json")
        checkout = self.root / "workspaces" / helper.read_route(route)["relative"]
        original_parent = checkout.parent
        outside = self.root / "outside"
        outside.mkdir()
        original_parent.rmdir()
        original_parent.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(helper.Refusal, "workspace directory is invalid"):
            self.sync()
        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse(checkout.exists())

    def test_binding_path_mismatch_refuses_before_fetch(self):
        with patch.object(helper, "git", wraps=helper.git) as invoked:
            with self.assertRaisesRegex(helper.Refusal, "binding changed"):
                self.sync(checkout_path=str(self.root / "wrong"))
        self.assertFalse(any("fetch" in call.args[0] for call in invoked.call_args_list))
        self.assertFalse((self.root / "workspaces" / "repo" / "wrong").exists())

    def test_free_space_preflight_uses_workspace_not_metadata_filesystem(self):
        empty = shutil.disk_usage(self.root)._replace(free=0)
        with patch.object(helper.shutil, "disk_usage", return_value=empty) as checked, \
             patch.object(helper, "git", wraps=helper.git) as invoked:
            with self.assertRaisesRegex(helper.Refusal, "insufficient free space"):
                self.sync(repo_label="Life", thread_label="Nutrition")
        self.assertEqual(checked.call_args.args[0], self.root / "workspaces" / "life")
        self.assertFalse(any("fetch" in call.args[0] for call in invoked.call_args_list))

    def test_missing_initialized_workspace_is_not_recreated(self):
        checkout = Path(self.sync()["checkout_path"])
        held = checkout.with_name("user-moved-workspace")
        checkout.rename(held)
        with self.assertRaisesRegex(helper.Refusal, "bound workspace missing"):
            self.sync()
        self.assertFalse(checkout.exists())
        self.assertEqual((held / "hello.txt").read_text(), "thread\n")

    def test_initial_fetch_failure_keeps_frozen_allocation(self):
        with self.assertRaises(helper.Refusal):
            self.sync(branch="thread/missing", repo_label="First", thread_label="First title")
        result = self.sync(repo_label="Changed", thread_label="Changed title")
        self.assertEqual(Path(result["checkout_path"]).parent.name, "first")
        self.assertTrue(Path(result["checkout_path"]).name.startswith("first-title-"))

    def test_failed_allocation_does_not_adopt_a_later_user_checkout(self):
        with self.assertRaises(helper.Refusal):
            self.sync(branch="thread/missing")
        route = self.cache / "routes" / (helper.stable_identity("b" * 20, "thread-1") + ".json")
        checkout = self.root / "workspaces" / helper.read_route(route)["relative"]
        run("clone", "-q", "-b", "thread/one", str(self.bare), str(checkout))
        inode = checkout.stat().st_ino
        index = (checkout / ".git" / "index").read_bytes()
        head = run("-C", str(checkout), "rev-parse", "HEAD")
        (checkout / "personal.txt").write_text("keep\n")
        with patch.object(helper, "git", wraps=helper.git) as invoked:
            with self.assertRaisesRegex(helper.Refusal, "destination already exists"):
                self.sync()
        self.assertFalse(any("fetch" in call.args[0] for call in invoked.call_args_list))
        self.assertEqual((checkout.stat().st_ino, (checkout / ".git" / "index").read_bytes(),
                          run("-C", str(checkout), "rev-parse", "HEAD")), (inode, index, head))
        self.assertEqual((checkout / "personal.txt").read_text(), "keep\n")

    def test_atomic_promotion_never_replaces_a_new_empty_user_directory(self):
        promote = helper.promote_workspace
        state = {}

        def occupied(stage, checkout):
            checkout.mkdir(mode=0o755)
            state.update(path=checkout, inode=checkout.stat().st_ino)
            promote(stage, checkout)

        with patch.object(helper, "promote_workspace", side_effect=occupied):
            with self.assertRaisesRegex(helper.Refusal, "destination already exists"):
                self.sync()
        checkout = state["path"]
        self.assertEqual(checkout.stat().st_ino, state["inode"])
        self.assertEqual(checkout.stat().st_mode & 0o777, 0o755)
        self.assertEqual(list(checkout.iterdir()), [])
        with self.assertRaisesRegex(helper.Refusal, "initialization interrupted"):
            self.sync()
        self.assertEqual(checkout.stat().st_ino, state["inode"])

    def test_interrupted_promotion_does_not_recreate_a_missing_workspace(self):
        with patch.object(helper, "promote_workspace", side_effect=OSError("interrupted")):
            with self.assertRaises(OSError):
                self.sync()
        with self.assertRaisesRegex(helper.Refusal, "initialization interrupted"):
            self.sync()
        self.assertFalse(any(path.is_dir() for path in (self.root / "workspaces" / "repo").iterdir()))

    def test_corrupt_route_state_cannot_admit_an_existing_workspace(self):
        checkout = Path(self.sync()["checkout_path"])
        route = self.cache / "routes" / (helper.stable_identity("b" * 20, "thread-1") + ".json")
        original = helper.read_route(route)
        inode, index = checkout.stat().st_ino, (checkout / ".git" / "index").read_bytes()
        head = run("-C", str(checkout), "rev-parse", "HEAD")
        for value in (None, 0, 1, "yes", [], {}, "missing"):
            with self.subTest(state=value):
                corrupt = {**original, "initialized": value}
                if value == "missing":
                    corrupt.pop("initialized")
                helper.write_route(route, corrupt)
                with patch.object(helper, "git", wraps=helper.git) as invoked:
                    with self.assertRaisesRegex(helper.Refusal, "binding is invalid"):
                        self.sync()
                self.assertFalse(any("fetch" in call.args[0] for call in invoked.call_args_list))
                self.assertEqual((checkout.stat().st_ino, (checkout / ".git" / "index").read_bytes(),
                                  run("-C", str(checkout), "rev-parse", "HEAD")), (inode, index, head))

    def test_stable_allocation_lock_covers_a_changed_branch(self):
        locks = self.cache / "locks"
        locks.mkdir(mode=0o700, parents=True)
        self.cache.chmod(0o700)
        lock = locks / ("workspace-" + helper.stable_identity("b" * 20, "thread-1"))
        descriptor = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(helper.Refusal, "another Git operation"):
                self.sync(branch="thread/two")
            self.assertFalse((self.root / "workspaces").exists())
        finally:
            os.close(descriptor)

    def test_legacy_physical_lock_is_not_bypassed_by_new_binding(self):
        checkout = self.legacy_checkout("thread-1")
        locks = self.cache / "locks"
        locks.mkdir(mode=0o700)
        descriptor = os.open(locks / checkout.name, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(helper, "git", wraps=helper.git) as invoked:
                with self.assertRaisesRegex(helper.Refusal, "another Git operation"):
                    self.sync()
            self.assertFalse(any("fetch" in call.args[0] for call in invoked.call_args_list))
        finally:
            os.close(descriptor)

    def test_binding_publication_serializes_different_thread_identities(self):
        checkout = self.legacy_checkout()
        locks = self.cache / "locks"
        locks.mkdir(mode=0o700)
        descriptor = os.open(locks / "workspace-bindings", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(helper, "git", wraps=helper.git) as invoked:
                with self.assertRaisesRegex(helper.Refusal, "allocating a workspace"):
                    self.sync(thread_id="another-thread", workspace_choice=checkout.name)
            self.assertFalse(any("fetch" in call.args[0] for call in invoked.call_args_list))
            self.assertFalse(list((self.cache / "routes").iterdir()))
        finally:
            os.close(descriptor)

    def test_new_workspace_fetch_uses_its_physical_path_lock(self):
        checkout = Path(self.sync()["checkout_path"])
        physical = helper.physical_lock(checkout, None)
        self.assertEqual(physical, "path-" + __import__("hashlib").sha256(os.fsencode(checkout)).hexdigest())
        descriptor = os.open(self.cache / "locks" / physical, os.O_RDWR)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(helper, "git", wraps=helper.git) as invoked:
                with self.assertRaisesRegex(helper.Refusal, "another Git operation"):
                    self.sync()
            self.assertFalse(any("fetch" in call.args[0] for call in invoked.call_args_list))
        finally:
            os.close(descriptor)

    def test_legacy_git_scan_does_not_hold_the_binding_publication_lock(self):
        checkout = self.legacy_checkout()
        original = helper.git
        probed = []

        def inspected(args, env, **options):
            if str(checkout) in args and "get-url" in args:
                descriptor = os.open(self.cache / "locks" / "workspace-bindings",
                                     os.O_RDWR | os.O_CREAT, 0o600)
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    probed.append(True)
                finally:
                    os.close(descriptor)
            return original(args, env, **options)

        with patch.object(helper, "git", side_effect=inspected):
            with self.assertRaises(helper.WorkspaceChoice):
                self.sync()
        self.assertEqual(probed, [True])

    def test_persistent_checkout_fast_forwards_without_reset_or_delete(self):
        first = self.sync()
        checkout = Path(first["checkout_path"])
        self.assertEqual(run("-C", str(checkout), "branch", "--show-current"), "thread/one")
        self.assertEqual(run("-C", str(checkout), "remote", "get-url", "origin"), str(self.bare))
        self.assertEqual(run("-C", str(checkout), "rev-parse", "@{upstream}"), self.thread_oid)
        next_oid = self.publish_update()
        result = self.sync()
        self.assertEqual(result["checkout_path"], str(checkout))
        self.assertEqual(result["local_oid"], next_oid)
        self.assertEqual(result["thread_oid"], next_oid)
        self.assertIsNone(result["pending"])

    def test_selected_remote_branch_needs_no_assist_oid(self):
        result = self.sync()
        self.assertEqual(result["local_oid"], self.thread_oid)
        self.assertEqual(result["thread_oid"], self.thread_oid)
        self.assertNotIn("expected_matches", result)

    def test_busy_remote_advance_is_visible_without_expected_equality(self):
        self.sync()
        next_oid = self.publish_update()
        result = self.sync(allow_ff=False)
        self.assertEqual(result["thread_oid"], next_oid)
        self.assertEqual(result["local_oid"], self.thread_oid)
        self.assertNotIn("expected_matches", result)
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
        self.assertNotIn("expected_matches", result)

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
