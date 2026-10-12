"""Disposable Git/SSH and credential-free shell services for the E2E network."""
import base64
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys


THREADS_ROOT = Path("/state/threads")
WORKSPACE_LINK = Path("/runtime/workspace")


def git_service():
    subprocess.run(["ssh-keygen", "-A"], check=True)
    subprocess.run(["usermod", "-p", "e2e-public-key-only", "test"], check=True)
    subprocess.run(["git", "init", "--bare", "--initial-branch=main", "/repos/domain.git"], check=True)
    subprocess.run(["git", "init", "--initial-branch=main", "/tmp/seed"], check=True)
    Path("/tmp/seed/README.txt").write_text("Disposable E2E repository\n")
    for arguments in (["add", "."], ["-c", "user.name=E2E", "-c", "user.email=e2e@localhost",
                                      "commit", "-m", "Initial"],
                      ["push", "/repos/domain.git", "HEAD:main"]):
        subprocess.run(["git", "-C", "/tmp/seed", *arguments], check=True)
    subprocess.run(["chown", "-R", "1000:1000", "/repos", "/home/test/.ssh"], check=True)
    Path("/run/sshd").mkdir(exist_ok=True)
    os.execv("/usr/sbin/sshd", ["/usr/sbin/sshd", "-D", "-e", "-p", "2222", "-h", "/secrets/ssh_host",
        "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
        "-o", "PermitRootLogin=no", "-o", "UsePAM=no", "-o", "AllowUsers=test"])


class ShellHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= 1024 * 1024:
            self.send_error(413)
            return
        data = json.loads(self.rfile.read(length))
        worktree = Path(data["worktree"]).resolve()
        if not worktree.is_relative_to(THREADS_ROOT) or not worktree.is_dir():
            self.send_error(400)
            return
        link = WORKSPACE_LINK
        link.unlink(missing_ok=True)
        link.symlink_to(worktree)
        if self.path == "/execute":
            process = subprocess.run(["sh", "-c", data["command"]], cwd=worktree,
                                     capture_output=True, timeout=27)
            result = {"exit_code": process.returncode,
                      "output": (process.stdout + process.stderr)[:65536].decode(errors="replace"),
                      "truncated": len(process.stdout) + len(process.stderr) > 65536}
        elif self.path == "/upload":
            for name, content in data["files"]:
                path = Path(name).resolve()
                if not (path.is_relative_to(worktree) or path in {
                        Path("/tmp/assist-git-incoming.bundle"), Path("/tmp/assist-git-merge.bundle")}):
                    self.send_error(400)
                    return
                path.write_bytes(base64.b64decode(content, validate=True))
            result = {"uploaded": True}
        else:
            self.send_error(404)
            return
        payload = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    if sys.argv[1] == "git":
        git_service()
    else:
        HTTPServer(("0.0.0.0", 8080), ShellHandler).serve_forever()
