#!/usr/bin/env python3
"""Run bounded phone/Assist lifecycle checks on disposable Docker resources."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import secrets
import shutil
import signal
import subprocess
import tempfile
import time
import uuid


FILES = ("Dockerfile", "run.py", "services.py", "client.el", "README.md", "test_harness.py")
SOURCE = "ssh://test@git:2222/repos/domain.git"


class Harness:
    def __init__(self, args):
        self.args = args
        self.name = "phone-assist-e2e-" + uuid.uuid4().hex[:12]
        self.network = self.name
        self.image = self.name + ":test"
        self.volume = self.name + "-threads"
        self.containers = []
        self.network_attempted = self.volume_attempted = False
        self.deadline = time.monotonic() + 900
        self.results = []
        self.token = secrets.token_urlsafe(32)
        self.args.logs.mkdir(parents=True, exist_ok=False)

    def command(self, *args, timeout=45, input=None):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("E2E overall deadline exceeded")
        process = subprocess.run(args, input=input, text=True, capture_output=True,
                                 timeout=min(timeout, remaining))
        if process.returncode:
            raise RuntimeError(f"{args[0]} failed ({process.returncode}): "
                               + self.scrub(process.stdout + process.stderr)[-6000:])
        return process.stdout

    def scrub(self, text):
        return text.replace(self.token, "[test-token]")

    def docker(self, *args, **kwargs):
        return self.command("docker", *args, **kwargs)

    def execute(self, service, *args, **kwargs):
        return self.docker("exec", "--user", "1000:1000", self.name + "-" + service, *args, **kwargs)

    def wait(self, description, predicate, seconds=45):
        deadline = min(self.deadline, time.monotonic() + seconds)
        last = None
        while time.monotonic() < deadline:
            try:
                value = predicate()
                if value:
                    return value
            except RuntimeError as exc:
                last = exc
            time.sleep(.1)
        raise TimeoutError(f"{description}: {last or 'condition not reached'}")

    def stage(self, repo, target, added):
        files = self.command("git", "-C", str(repo), "ls-files", "-z").split("\0")
        for relative in {*files, *added}:
            if not relative:
                continue
            path = Path(relative)
            if any(part == ".git" or part.endswith(".env") or part.startswith(".env")
                   for part in path.parts):
                continue
            source = repo / path
            if any(parent.is_symlink() for parent in (source, *source.parents)
                   if parent == repo or repo in parent.parents):
                raise RuntimeError("Source staging refuses symlinks: " + relative)
            if source.is_file():
                destination = target / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)

    def copy(self, file, service, destination):
        self.docker("cp", "-a", str(file), self.name + "-" + service + ":" + destination)

    def start(self, service, *command, user="1000:1000", mounts=(), environment=()):
        name = self.name + "-" + service
        if service in {"assist", "client"}:
            command = ("sh", "-c", "set -e; export HOME=/home/test; chown -R 1000:1000 /secrets /home/test/.ssh; "
                       "touch /runtime/credentials-ready; "
                       "exec setpriv --reuid=1000 --regid=1000 --init-groups \"$@\"", "bootstrap", *command)
            user = "0:0"
        self.containers.append(name)
        self.docker("create", "--name", name, "--network", self.network,
                    "--network-alias", service, "--user", user,
                    "--label", "phone-assist-e2e.owner=" + self.name,
                    "--memory", "1g", "--pids-limit", "128", "--cpus", "2",
                    *mounts, *environment, self.image, *command)

    def bootstrap(self, temporary):
        context = temporary / "source"
        self.stage(self.args.assist_source, context / "assist", [])
        adapter = context / "assist/tests/phone_e2e_server.py"
        adapter.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(self.args.assist_adapter, adapter)
        self.stage(self.args.emacsos_source, context / "emacsos",
                   ["tests/phone-assist-e2e/" + f for f in FILES])
        identities = {}
        for name, source in (("assist", self.args.assist_source), ("emacsos", self.args.emacsos_source)):
            identities[name] = {"head": self.command("git", "-C", str(source), "rev-parse", "HEAD").strip(),
                "files": {str(p.relative_to(context / name)): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in sorted((context / name).rglob("*")) if p.is_file()}}
        (self.args.logs / "source.json").write_text(json.dumps(identities, indent=2))
        print("Building isolated E2E image; logs: " + str(self.args.logs), flush=True)
        with (self.args.logs / "build.log").open("w") as log:
            build = subprocess.run(["docker", "build", "-t", self.image, "-f",
                str(context / "emacsos/tests/phone-assist-e2e/Dockerfile"), str(context)],
                stdout=log, stderr=log, timeout=600)
        if build.returncode:
            raise RuntimeError("E2E image build failed; see build.log")
        self.deadline = time.monotonic() + 300
        self.network_attempted = True
        self.docker("network", "create", "--internal", "--label",
                    "phone-assist-e2e.owner=" + self.name, self.network)
        self.volume_attempted = True
        self.docker("volume", "create", "--label", "phone-assist-e2e.owner=" + self.name,
                    self.volume)
        private = temporary / "secrets"
        private.mkdir(mode=0o700)
        for key in ("client_key", "server_ssh", "ssh_host"):
            self.command("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(private / key))
        (private / "authorized_keys").write_text(
            (private / "client_key.pub").read_text() + (private / "server_ssh.pub").read_text())
        host = (private / "ssh_host.pub").read_text().split()
        (private / "known_hosts").write_text("[git]:2222 " + " ".join(host[:2]) + "\n")
        self.command("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                     "-keyout", str(private / "ca.key"), "-out", str(private / "ca.crt"),
                     "-days", "1", "-subj", "/CN=Disposable E2E CA",
                     "-addext", "basicConstraints=critical,CA:TRUE",
                     "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        self.command("openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout",
                     str(private / "server.key"), "-out", str(private / "server.csr"),
                     "-subj", "/CN=assist")
        (private / "extensions").write_text("subjectAltName=DNS:assist\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature,keyEncipherment\nbasicConstraints=critical,CA:FALSE\nauthorityKeyIdentifier=keyid,issuer\n")
        self.command("openssl", "x509", "-req", "-in", str(private / "server.csr"),
                     "-CA", str(private / "ca.crt"), "-CAkey", str(private / "ca.key"),
                     "-CAcreateserial", "-out", str(private / "server.crt"), "-days", "1",
                     "-extfile", str(private / "extensions"))
        (private / "token").write_text(self.token)
        (private / "ssh_config").write_text(
            "Host git\n HostName git\n Port 2222\n User test\n IdentityFile /secrets/server_ssh\n"
            " UserKnownHostsFile /secrets/known_hosts\n GlobalKnownHostsFile /dev/null\n"
            " StrictHostKeyChecking yes\n IdentitiesOnly yes\n BatchMode yes\n")
        key = hashlib.sha256(SOURCE.encode()).hexdigest()[:20]
        (private / "remotes.json").write_text(json.dumps({key: SOURCE}))
        for file in private.iterdir():
            file.chmod(0o600)
        service_script = "/src/emacsos/tests/phone-assist-e2e/services.py"
        self.start("git", "python", service_script, "git", user="0:0")
        self.start("shell", "python", service_script, "shell",
                   mounts=("-v", self.volume + ":/state/threads"))
        self.start("assist", "python", "tests/phone_e2e_server.py",
                   mounts=("-v", self.volume + ":/state/threads"), environment=(
                       "-e", "ASSIST_THREADS_DIR=/state/threads", "-e", "ASSIST_DOMAINS=" + SOURCE,
                       "-e", "ASSIST_MODEL_URL=http://model.invalid:1/v1"))
        self.start("client", "sleep", "300")
        for file, service, destination in (
            ("authorized_keys", "git", "/home/test/.ssh/authorized_keys"),
            ("ssh_host", "git", "/secrets/ssh_host"),
            ("server_ssh", "assist", "/secrets/server_ssh"),
            ("known_hosts", "assist", "/secrets/known_hosts"),
            ("ssh_config", "assist", "/home/test/.ssh/config"),
            ("server.crt", "assist", "/secrets/server.crt"),
            ("server.key", "assist", "/secrets/server.key"),
            ("token", "assist", "/secrets/token"),
            ("ca.crt", "client", "/secrets/ca.crt"),
            ("token", "client", "/secrets/token"),
            ("client_key", "client", "/secrets/client_key"),
            ("known_hosts", "client", "/secrets/known_hosts"),
            ("remotes.json", "client", "/secrets/remotes.json")):
            self.copy(private / file, service, destination)
        # Each service corrects copied private-file ownership before its runtime starts.
        for service in ("git", "assist", "client"):
            self.docker("start", self.name + "-" + service)

        self.docker("start", self.name + "-shell")
        self.wait("client credential bootstrap", lambda: self.execute(
            "client", "test", "-f", "/runtime/credentials-ready") == "")
        self.execute("client", "sh", "-c",
            "mkdir -p ~/.config/emacsos; cp /secrets/token ~/.config/emacsos/assist-web-token; "
            "cp /secrets/client_key ~/.config/emacsos/assist-git-key; "
            "cp /secrets/known_hosts ~/.config/emacsos/assist-git-known-hosts; "
            "cp /secrets/remotes.json ~/.config/emacsos/assist-git-remotes.json")
        self.wait("Assist startup", lambda: self.api("GET", "/api/v1/phone/threads"))

    def api(self, method, path, body=None):
        script = ("import json,requests; from pathlib import Path; "
            "v=json.load(__import__('sys').stdin); "
            "r=requests.request(v['method'],'https://assist:8443'+v['path'],json=v['body'],"
            "headers={'Authorization':'Bearer '+Path('/secrets/token').read_text().strip()},"
            "verify='/secrets/ca.crt',timeout=5); r.raise_for_status(); print(r.text)")
        return json.loads(self.docker("exec", "--user", "1000:1000", "-i", self.name + "-client", "python", "-c", script,
            input=json.dumps({"method": method, "path": path, "body": body})))

    def client(self, action, tid="", text=""):
        expression = "(phone-e2e-main " + " ".join(json.dumps(x) for x in (action, tid, text)) + ")"
        output = self.execute("client", "emacs", "-Q", "--batch", "-L", "/src/emacsos",
            "-l", "/src/emacsos/tests/phone-assist-e2e/client.el", "--eval", expression, timeout=50)
        line = next((l[9:] for l in output.splitlines() if l.startswith("E2E_JSON:")), None)
        if line is None:
            raise RuntimeError("No Emacs receipt: " + output[-1000:])
        result = json.loads(line)
        with (self.args.logs / "client-receipts.jsonl").open("a") as log:
            log.write(self.scrub(json.dumps({"action": action, "receipt": result})) + "\n")
        assert not result.get("error"), result
        return result

    def state(self, tid):
        result = self.api("GET", "/__e2e/state/" + tid)
        (self.args.logs / "state-last.json").write_text(self.scrub(json.dumps(result, indent=2)))
        return result

    def git(self, checkout, *args):
        return self.execute("client", "git", "-C", checkout, *args).strip()

    def edit(self, checkout, filename, content, push=True):
        self.execute("client", "python", "-c", "from pathlib import Path; import sys; "
                     "Path(sys.argv[1]).write_text(sys.argv[2])", checkout + "/" + filename, content)
        self.git(checkout, "add", filename)
        self.git(checkout, "-c", "user.name=Phone", "-c", "user.email=phone@localhost",
                 "commit", "-m", "Phone edit")
        if push:
            self.git(checkout, "push", "origin", "HEAD")

    def passed(self, name):
        self.results.append(name)
        print("PASS " + name, flush=True)

    def scenarios(self):
        result = self.client("new", text="Write server.txt hello-server")
        tid, checkout = result["thread_id"], result["checkout"]
        assert result["git"]["local_oid"] == result["git"]["thread_oid"]
        assert self.execute("client", "cat", checkout + "/server.txt") == "hello-server"
        assert self.state(tid)["runs"][-1]["status"] == "success"
        self.passed("new thread, server publication and client refresh")

        opened = self.client("refresh", tid)
        assert opened["checkout"] == checkout and "Saved server.txt" in opened["text"]
        self.edit(checkout, "phone.txt", "phone-pushed")
        read = self.client("send", tid, "Read phone.txt")
        assert "phone-pushed" in read["text"]
        self.passed("existing thread, explicit client commit/push and next-turn pull")

        self.execute("client", "python", "-c", "from pathlib import Path; import sys; "
                     "Path(sys.argv[1]).write_text('unsaved-local')", checkout + "/server.txt")
        before_index = self.git(checkout, "write-tree")
        result = self.client("send", tid, "Write other.txt next-server")
        assert self.execute("client", "cat", checkout + "/server.txt") == "unsaved-local"
        assert self.git(checkout, "write-tree") == before_index
        assert "local edits are unchanged" in result["git"]["pending"]
        self.git(checkout, "restore", "server.txt")
        self.client("refresh", tid)
        self.passed("dirty client retains bytes and index with actionable notice")

        self.client("accepted", tid, "Hold publication")
        self.wait("publication model barrier", lambda: "Hold publication" in self.state(tid)["holds"])
        self.edit(checkout, "during.txt", "during-turn")
        phone_tip = self.git(checkout, "rev-parse", "HEAD")
        self.api("POST", "/__e2e/release", {"text": "Hold publication"})
        self.wait("publication completion", lambda: self.state(tid)["runs"][-1]["status"] == "success")
        published = self.state(tid)["runs"][-1]
        assert "assist-result/" in published["result"]
        result_branch = published["result"].split("Git branch ", 1)[1].split(".", 1)[0]
        self.git(checkout, "fetch", "origin", result_branch)
        self.git(checkout, "-c", "user.name=Phone", "-c", "user.email=phone@localhost",
                 "merge", "--no-ff", "FETCH_HEAD", "-m", "Reconcile server result")
        assert self.execute("client", "cat", checkout + "/server-during.txt") == "server-race-result"
        assert self.execute("client", "cat", checkout + "/during.txt") == "during-turn"
        assert self.git(checkout, "merge-base", "--is-ancestor", phone_tip, "HEAD") == ""
        self.git(checkout, "push", "origin", "HEAD")
        recovered = self.client("send", tid, "Read server-during.txt")
        assert "server-race-result" in recovered["text"]
        assert self.state(tid)["runs"][-1]["status"] == "success"
        self.passed("concurrent client push yields exceptional result branch and explicit reconciliation")

        self.execute("client", "sh", "-c",
            "mv ~/.config/emacsos/assist-git-remotes.json ~/.config/emacsos/assist-git-remotes.saved")
        missing = self.client("refresh", tid)
        assert "missing assist-git-remotes.json" in missing["git_error"]
        self.execute("client", "sh", "-c",
            "mv ~/.config/emacsos/assist-git-remotes.saved ~/.config/emacsos/assist-git-remotes.json")
        assert not self.client("refresh", tid)["git_error"]
        self.passed("private Git configuration failure and recovery")

        self.execute("client", "sh", "-c", "printf invalid > ~/.config/emacsos/assist-web-token")
        assert self.client("denied", tid)["denied"]
        self.execute("client", "sh", "-c", "cp /secrets/token ~/.config/emacsos/assist-web-token")
        assert not self.client("refresh", tid)["denied"]
        self.passed("canonical authentication denial and recovery")

        self.client("accepted", tid, "Hold restart")
        self.wait("restart model barrier", lambda: "Hold restart" in self.state(tid)["holds"])
        self.client("accepted-fresh", tid, "Accepted before restart")
        before = self.state(tid)
        accepted = next(r for r in before["runs"] if r["text"] == "Accepted before restart")
        assert accepted["status"] in {"pending", "revocation_pending"}
        self.docker("kill", "--signal", "KILL", self.name + "-assist")
        self.docker("start", self.name + "-assist")
        self.wait("restart recovery barrier", lambda: "Hold restart" in self.state(tid)["holds"])
        after = self.state(tid)
        retained = next(r for r in after["runs"] if r["id"] == accepted["id"])
        assert retained["work_id"] == accepted["work_id"]
        self.api("POST", "/__e2e/release", {"text": "Hold restart"})
        self.wait("accepted Run executes after restart", lambda: any(
            r["id"] == accepted["id"] and r["status"] == "success" for r in self.state(tid)["runs"]))
        snapshot = self.api("GET", "/api/v1/phone/threads/" + tid)
        assert sum(m["text"] == "Accepted before restart" for m in snapshot["messages"]) == 1
        self.passed("forced server interruption preserves accepted queued Run and executes once")

        child = self.api("POST", "/__e2e/child/" + tid)
        self.wait("child model barrier", lambda: "Hold child" in self.state(tid)["holds"])
        self.client("accepted", tid, "Queued user message")
        accepted = next(r for r in self.state(tid)["runs"] if r["text"] == "Queued user message")
        held = self.wait("real reset deferred on live child", lambda:
            (s if s["lease"] and s["lease"]["owner_run_id"] == child["run_id"]
             and any(refusal["owner_run_id"] == child["run_id"]
                     and accepted["id"] in refusal["held_run_ids"]
                     and refusal["generation"] in s["lease"]["generations"]
                     for refusal in s["reset_refusals"]) else None)
            if (s := self.state(tid)) else None)
        accepted = next(r for r in held["runs"] if r["text"] == "Queued user message")
        assert accepted["status"] == "revocation_pending"
        self.api("POST", "/__e2e/release", {"text": "Hold child"})
        finished = self.wait("child completion wakes held parent", lambda:
            (s if any(r["id"] == accepted["id"] and r["status"] == "success" for r in s["runs"])
             and any(r["origin"] == "task-completion" and r["status"] == "success" for r in s["runs"])
             else None) if (s := self.state(tid)) else None)
        handoffs = [r for r in finished["runs"] if r["origin"] == "task-completion"]
        assert len(handoffs) == 1
        user = next(r for r in finished["runs"] if r["id"] == accepted["id"])
        assert user["updated_at"] <= handoffs[0]["updated_at"]
        self.passed("live child completion wakes queued parent user before exactly one handoff")

    def cleanup(self):
        failures = []
        resources = [("container", name) for name in reversed(self.containers)]
        if self.volume_attempted:
            resources.append(("volume", self.volume))
        if self.network_attempted:
            resources.append(("network", self.network))
        for kind, name in resources:
            try:
                inspected = subprocess.run(["docker", kind, "inspect", name],
                                           capture_output=True, text=True, timeout=5)
                if inspected.returncode:
                    if "No such" in inspected.stderr:
                        continue
                    raise RuntimeError(inspected.stderr)
                record = json.loads(inspected.stdout)[0]
                labels = (record["Config"] if kind == "container" else record).get("Labels", {})
                if (labels or {}).get("phone-assist-e2e.owner") != self.name:
                    continue  # A name collision belongs to someone else.
            except (OSError, subprocess.TimeoutExpired, RuntimeError, ValueError, KeyError) as error:
                failures.append("ownership inspection: " + str(error))
                continue
            if kind == "container":
                try:
                    logs = subprocess.run(["docker", "logs", name], capture_output=True,
                                          text=True, timeout=5)
                    (self.args.logs / (name.rsplit("-", 1)[-1] + ".log")).write_text(
                        self.scrub(logs.stdout + logs.stderr))
                except (OSError, subprocess.TimeoutExpired) as error:
                    failures.append("log collection: " + str(error))
            command = ["docker", "rm", "-f", name] if kind == "container" else ["docker", kind, "rm", name]
            try:
                removal = subprocess.run(command, capture_output=True, text=True, timeout=10)
                if removal.returncode:
                    failures.append("resource removal: " + removal.stderr)
            except (OSError, subprocess.TimeoutExpired) as error:
                failures.append("resource removal: " + str(error))
        if failures:
            (self.args.logs / "cleanup-errors.log").write_text(self.scrub("\n".join(failures)))
            raise RuntimeError("E2E cleanup had failures; see cleanup-errors.log")


def main():
    if not __debug__:
        raise RuntimeError("E2E requires assertions; unset PYTHONOPTIMIZE and omit -O")
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[2]
    parser.add_argument("--emacsos-source", type=Path, default=root)
    parser.add_argument("--assist-source", type=Path, default=root.parent / "assist")
    parser.add_argument("--assist-adapter", type=Path,
                        default=root.parent / "assist/tests/phone_e2e_server.py")
    parser.add_argument("--logs", type=Path, required=True)
    args = parser.parse_args()
    def interrupted(signum, frame):
        raise KeyboardInterrupt("E2E interrupted; cleaning up owned resources")
    signal.signal(signal.SIGTERM, interrupted)
    harness = Harness(args)
    try:
        with tempfile.TemporaryDirectory(prefix=harness.name + "-") as name:
            harness.bootstrap(Path(name))
            harness.scenarios()
    finally:
        try:
            harness.cleanup()
        finally:
            (args.logs / "results.json").write_text(json.dumps({
                "passed": harness.results, "image": harness.image}, indent=2))


if __name__ == "__main__":
    main()
