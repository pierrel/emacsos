#!/usr/bin/env python3
"""Drive nine real phone-client flows against an independently running Assist fixture."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

FILES = ("Dockerfile", "run.py", "client.el", "README.md", "test_harness.py")
RUN_SECONDS = 1200


class Driver:
    def __init__(self, args):
        self.args = args
        self.fixture = json.loads(args.fixture.read_text())
        self.name = "phone-assist-e2e-" + uuid.uuid4().hex[:12]
        self.image = self.name + ":client"
        self.created = False
        self.results = []
        self.token = Path(self.fixture["credentials"]["token"]).read_text().strip()
        self.deadline = time.monotonic() + RUN_SECONDS
        args.logs.mkdir(parents=True, exist_ok=False)
        args.logs.chmod(0o700)

    def scrub(self, text):
        return text.replace(self.token, "[test-token]")

    def command(self, *args, timeout=45, input=None):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Client driver deadline exceeded")
        result = subprocess.run(args, input=input, text=True, capture_output=True,
                                timeout=min(timeout, remaining))
        if result.returncode:
            raise RuntimeError(f"{args[0]} failed ({result.returncode}): "
                               + self.scrub(result.stdout + result.stderr)[-6000:])
        return result.stdout

    def docker(self, *args, **kwargs):
        return self.command("docker", *args, **kwargs)

    def execute(self, service, *args, **kwargs):
        assert service == "client"
        return self.docker("exec", "--user", "1000:1000", self.name + "-client", *args, **kwargs)

    def wait(self, description, predicate, seconds=90):
        deadline = min(self.deadline, time.monotonic() + seconds)
        last = None
        while time.monotonic() < deadline:
            try:
                value = predicate()
                last = None
                if value:
                    return value
            except RuntimeError as error:
                last = error
            time.sleep(.1)
        raise TimeoutError(f"{description}: {last or 'condition not reached'}")

    def verify_fixture(self):
        for kind, name in (("container", self.fixture["server_container"]),
                           ("network", self.fixture["network"])):
            record = json.loads(self.docker(kind, "inspect", name))[0]
            labels = (record["Config"] if kind == "container" else record).get("Labels", {})
            if (labels or {}).get(self.fixture["label"]) != self.fixture["owner"]:
                raise RuntimeError("Fixture ownership changed: " + name)

    def stage(self, repo, target):
        files = self.command("git", "-C", str(repo), "ls-files", "-z").split("\0")
        for relative in {*files, *("tests/phone-assist-e2e/" + f for f in FILES)}:
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

    def bootstrap(self, temporary):
        self.verify_fixture()
        context = temporary / "source"
        self.stage(self.args.emacsos_source, context)
        (self.args.logs / "source.json").write_text(json.dumps({
            "emacsos_head": self.command("git", "-C", str(self.args.emacsos_source), "rev-parse", "HEAD").strip(),
            "files": {str(p.relative_to(context)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in sorted(context.rglob("*")) if p.is_file()}}, indent=2))
        with (self.args.logs / "build.log").open("w") as log:
            build = subprocess.run(["docker", "build", "-t", self.image, "-f",
                str(context / "tests/phone-assist-e2e/Dockerfile"), str(context)],
                stdout=log, stderr=log, timeout=600)
        if build.returncode:
            raise RuntimeError("Client image build failed; see build.log")
        self.created = True
        self.docker("create", "--name", self.name + "-client", "--network", self.fixture["network"],
            "--label", "phone-assist-e2e.owner=" + self.name, "--memory", "1g", "--pids-limit", "128",
            "--cpus", "2", "--user", "0:0", "-e", "ASSIST_E2E_URL=" + self.fixture["container_url"],
            "-e", "NO_PROXY=*", "-e", "no_proxy=*",
            self.image, "sh", "-c", "set -e; chown -R 1000:1000 /secrets; touch /runtime/credentials-ready; "
            "exec setpriv --reuid=1000 --regid=1000 --init-groups sleep " + str(RUN_SECONDS))
        for name, source in self.fixture["credentials"].items():
            self.docker("cp", "-a", source, self.name + "-client:/secrets/" + name)
        self.docker("start", self.name + "-client")
        self.wait("client credential bootstrap", lambda: self.execute(
            "client", "test", "-f", "/runtime/credentials-ready") == "")
        self.execute("client", "sh", "-c",
            "mkdir -p ~/.config/emacsos; cp /secrets/token ~/.config/emacsos/assist-web-token; "
            "cp /secrets/client_key ~/.config/emacsos/assist-git-key; "
            "cp /secrets/known_hosts ~/.config/emacsos/assist-git-known-hosts; "
            "cp /secrets/remotes.json ~/.config/emacsos/assist-git-remotes.json")

    def api(self, method, path, body=None):
        script = ("import json,os,ssl,urllib.request; from pathlib import Path; "
            "v=json.load(__import__('sys').stdin); "
            "h={'Authorization':'Bearer '+Path('/secrets/token').read_text().strip(),'Content-Type':'application/json'}; "
            "r=urllib.request.urlopen(urllib.request.Request(os.environ['ASSIST_E2E_URL']+v['path'],"
            "method=v['method'],data=None if v['body'] is None else json.dumps(v['body']).encode(),headers=h),"
            "context=ssl.create_default_context(cafile='/secrets/ca.crt'),timeout=5); print(r.read().decode())")
        return json.loads(self.docker("exec", "--user", "1000:1000", "-i", self.name + "-client",
            "python", "-c", script, input=json.dumps({"method": method, "path": path, "body": body})))

    def client(self, action, tid="", text=""):
        expression = "(phone-e2e-main " + " ".join(json.dumps(x) for x in (action, tid, text)) + ")"
        output = self.execute("client", "emacs", "-Q", "--batch", "-L", "/src/emacsos",
            "-l", "/src/emacsos/tests/phone-assist-e2e/client.el", "--eval", expression, timeout=RUN_SECONDS)
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
        refreshed = self.client("refresh", tid)
        assert not refreshed["git_error"]
        assert refreshed["git"]["local_oid"] == refreshed["git"]["thread_oid"]
        assert self.execute("client", "cat", checkout + "/other.txt") == "next-server"
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

        recovered = self.client("auth-recovery", tid)
        assert recovered["canonical_refreshed"] and recovered["git_refreshed"]
        assert recovered["auth_denied_seen"] and recovered["same_buffer"] and not recovered["denied"]
        assert recovered["auth_denied_epoch"] > recovered["auth_initial_epoch"]
        self.passed("canonical authentication denial and recovery")

        recovered = self.client("observer-recovery", tid, "Hold observer")
        assert recovered["observer_lost"] and recovered["same_buffer"] and recovered["queue_cleared"]
        assert "Completed: Hold observer" in recovered["text"]
        self.passed("same resident client refresh recovers completed Run after observer loss")

        self.client("accepted", tid, "Hold restart")
        self.wait("restart model barrier", lambda: "Hold restart" in self.state(tid)["holds"])
        self.client("accepted-fresh", tid, "Accepted before restart")
        before = self.state(tid)
        accepted = next(r for r in before["runs"] if r["text"] == "Accepted before restart")
        assert accepted["status"] in {"pending", "revocation_pending"}
        self.verify_fixture()
        server = self.fixture["server_container"]
        self.docker("exec", server, "sh", "-c", 'kill -KILL "$(cat /runtime/server.pid)"')
        self.wait("server container exits", lambda:
            self.docker("inspect", "--format", "{{.State.Running}}", server).strip() == "false")
        self.docker("start", server)
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
            (s if s["reset_worker_idle"] and s["lease"]
             and s["lease"]["owner_run_id"] == child["run_id"]
             and s["live_registered_generation"] in s["lease"]["generations"]
             and any(r["id"] == accepted["id"] and r["status"] == "revocation_pending"
                     and not r.get("error") and not r.get("revocation_retry_at")
                     for r in s["runs"]) else None)
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
        self.wait("terminal reset queue idle", lambda: self.state(tid)["reset_worker_idle"])
        self.verify_fixture()
        census = self.wait("terminal native Docker sandbox census", lambda:
            {"sandbox_ids": [], "server_container": self.fixture["server_container"],
             "owner": self.fixture["owner"], "reset_worker_idle": True}
            if not self.docker("exec", self.fixture["server_container"], "docker", "ps",
                "--all", "--no-trunc", "--filter", "label=assist.sandbox=true",
                "--format", "{{.ID}}").strip() else None)
        (self.args.logs / "terminal-sandbox-census.json").write_text(json.dumps(census, indent=2))
        self.passed("live child completion wakes queued parent user before exactly one handoff")

    def cleanup(self):
        if not self.created:
            return
        name = self.name + "-client"
        failures = []
        record = subprocess.run(["docker", "container", "inspect", name],
                                capture_output=True, text=True, timeout=5)
        if record.returncode:
            if "No such" in record.stderr:
                return
            raise RuntimeError(record.stderr)
        labels = json.loads(record.stdout)[0]["Config"].get("Labels", {})
        if (labels or {}).get("phone-assist-e2e.owner") != self.name:
            return
        try:
            logs = subprocess.run(["docker", "logs", name], capture_output=True, text=True, timeout=5)
            (self.args.logs / "client.log").write_text(self.scrub(logs.stdout + logs.stderr))
        except (OSError, subprocess.TimeoutExpired) as error:
            failures.append("log collection: " + str(error))
        removal = subprocess.run(["docker", "rm", "-f", "-v", name],
                                 capture_output=True, text=True, timeout=20)
        if removal.returncode:
            failures.append("client removal: " + removal.stderr)
        if failures:
            raise RuntimeError("Client cleanup failed: " + self.scrub("; ".join(failures)))


def main():
    if not __debug__:
        raise RuntimeError("E2E requires assertions; unset PYTHONOPTIMIZE and omit -O")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--emacsos-source", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--logs", type=Path, required=True)
    args = parser.parse_args()
    def interrupted(signum, frame):
        raise KeyboardInterrupt("Client interrupted; cleaning up its container")
    signal.signal(signal.SIGTERM, interrupted)
    driver = Driver(args)
    try:
        with tempfile.TemporaryDirectory(prefix=driver.name + "-") as name:
            driver.bootstrap(Path(name))
            driver.scenarios()
    finally:
        try:
            driver.cleanup()
        finally:
            (args.logs / "results.json").write_text(json.dumps({
                "passed": driver.results, "image": driver.image}, indent=2))


if __name__ == "__main__":
    main()
