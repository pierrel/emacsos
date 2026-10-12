"""Source privacy and cleanup regressions, without Docker or a model."""
import argparse
import base64
from http.server import HTTPServer
import threading
import urllib.request
import urllib.error
import services
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from run import Harness


class HarnessTests(unittest.TestCase):
    def test_upload_rejects_traversal_symlinks_and_unrecognized_bundle_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            worktree, sibling = root / "threads/one", root / "threads/two"
            worktree.mkdir(parents=True)
            sibling.mkdir()
            victim = sibling / "victim"
            victim.write_bytes(b"unchanged")
            (worktree / "escape").symlink_to(sibling, target_is_directory=True)
            with patch.object(services, "THREADS_ROOT", root / "threads"), patch.object(
                    services, "WORKSPACE_LINK", root / "workspace"):
                server = HTTPServer(("127.0.0.1", 0), services.ShellHandler)
                worker = threading.Thread(target=server.serve_forever, daemon=True)
                worker.start()
                try:
                    def upload(name):
                        body = json.dumps({"worktree": str(worktree), "files": [
                            [name, base64.b64encode(b"new").decode()]]}).encode()
                        return urllib.request.urlopen(urllib.request.Request(
                            f"http://127.0.0.1:{server.server_port}/upload", data=body), timeout=2)
                    with upload(str(worktree / "allowed")) as response:
                        self.assertEqual(response.status, 200)
                    self.assertEqual((worktree / "allowed").read_bytes(), b"new")
                    for destination in [str(worktree / "../two/victim"),
                                        str(worktree / "escape/victim"),
                                        "/tmp/assist-git-not-a-transfer.bundle"]:
                        with self.subTest(destination=destination), self.assertRaises(
                                urllib.error.HTTPError) as denied:
                            upload(destination)
                        self.assertEqual(denied.exception.code, 400)
                        denied.exception.close()
                        self.assertEqual(victim.read_bytes(), b"unchanged")
                finally:
                    server.shutdown()
                    server.server_close()
                    worker.join(2)

    def test_optimized_runner_refuses_before_creating_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            logs = Path(temporary) / "logs"
            result = subprocess.run([sys.executable, "-O", str(Path(__file__).with_name("run.py")),
                                     "--logs", str(logs)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("E2E requires assertions", result.stderr)
            self.assertFalse(logs.exists())

    def test_snapshot_excludes_environment_and_untracked_credentials(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = root / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", str(repo)], check=True, capture_output=True)
            (repo / "source.py").write_text("public source")
            (repo / ".dev.env").write_text("synthetic private environment")
            (repo / "untracked-key").write_text("synthetic private credential")
            subprocess.run(["git", "-C", str(repo), "add", "source.py", ".dev.env"], check=True)
            harness = Harness(argparse.Namespace(logs=root / "logs"))
            harness.stage(repo, root / "snapshot", [])
            self.assertEqual([p.name for p in (root / "snapshot").iterdir()], ["source.py"])
            (repo / "escape").symlink_to(repo / "untracked-key")
            subprocess.run(["git", "-C", str(repo), "add", "escape"], check=True)
            with self.assertRaisesRegex(RuntimeError, "refuses symlinks"):
                harness.stage(repo, root / "second", [])

    def test_log_timeout_still_removes_all_owned_runtime_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = Harness(argparse.Namespace(logs=Path(temporary) / "logs"))
            harness.network_attempted = harness.volume_attempted = True
            harness.containers = [harness.name + "-client", harness.name + "-assist"]
            calls = []

            def command(args, **kwargs):
                calls.append(args)
                if args[2] == "inspect":
                    labels = {"Labels": {"phone-assist-e2e.owner": harness.name}}
                    record = {"Config": labels} if args[1] == "container" else labels
                    return subprocess.CompletedProcess(args, 0, json.dumps([record]), "")
                if args[1] == "logs":
                    raise subprocess.TimeoutExpired(args, 5)
                return subprocess.CompletedProcess(args, 0, "", "")

            with patch("run.subprocess.run", command):
                with self.assertRaisesRegex(RuntimeError, "cleanup had failures"):
                    harness.cleanup()
            self.assertEqual([c for c in calls if c[1] == "rm"], [
                ["docker", "rm", "-f", harness.containers[1]],
                ["docker", "rm", "-f", harness.containers[0]]])
            self.assertIn(["docker", "volume", "rm", harness.volume], calls)
            self.assertIn(["docker", "network", "rm", harness.network], calls)

    def test_interrupted_create_is_reconciled_without_removing_foreign_collision(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = Harness(argparse.Namespace(logs=Path(temporary) / "logs"))
            with patch.object(harness, "docker", side_effect=subprocess.TimeoutExpired("docker create", 45)):
                with self.assertRaises(subprocess.TimeoutExpired):
                    harness.start("shell", "sleep", "300")
            owned = harness.name + "-shell"
            foreign = harness.name + "-client"
            harness.containers.append(foreign)
            calls = []

            def command(args, **kwargs):
                calls.append(args)
                if args[2] == "inspect":
                    owner = harness.name if args[3] == owned else "different-harness"
                    return subprocess.CompletedProcess(args, 0, json.dumps([
                        {"Config": {"Labels": {"phone-assist-e2e.owner": owner}}}]), "")
                return subprocess.CompletedProcess(args, 0, "", "")

            with patch("run.subprocess.run", command):
                harness.cleanup()
            self.assertIn(["docker", "rm", "-f", owned], calls)
            self.assertNotIn(["docker", "rm", "-f", foreign], calls)

    def test_snapshot_refuses_symlink_parent_of_tracked_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = root / "repo"
            (repo / "nested").mkdir(parents=True)
            subprocess.run(["git", "init", str(repo)], check=True, capture_output=True)
            (repo / "nested/file").write_text("tracked")
            subprocess.run(["git", "-C", str(repo), "add", "nested/file"], check=True)
            (repo / "nested/file").unlink()
            (repo / "nested").rmdir()
            (root / "private").mkdir()
            (root / "private/file").write_text("private")
            (repo / "nested").symlink_to(root / "private")
            harness = Harness(argparse.Namespace(logs=root / "logs"))
            with self.assertRaisesRegex(RuntimeError, "refuses symlinks"):
                harness.stage(repo, root / "snapshot", [])


if __name__ == "__main__":
    unittest.main()
