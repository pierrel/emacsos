#!/usr/bin/env python3
"""Bounded, noninteractive Git work for the Assist thread mirror.

The Emacs client supplies only a validated repository key and branch.  This
process resolves the remote from private device configuration and never emits
the URL, SSH diagnostics, or credential material.
"""

import json
import os
from pathlib import Path
import re
import selectors
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time
from urllib.parse import urlsplit


KEY_RE = re.compile(r"[0-9a-f]{20}\Z")
ID_RE = re.compile(r"[0-9a-f]{32}\Z")
OID_RE = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
HOST_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9.:-]*\Z")
USER_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*\Z")
PATH_RE = re.compile(r"/[A-Za-z0-9._/~+-]+\Z")
OBJECT_LIMIT = 256 * 1024 * 1024
WORKTREE_LIMIT = 64 * 1024 * 1024
TOTAL_LIMIT = 512 * 1024 * 1024
FREE_MARGIN = 512 * 1024 * 1024
FILE_LIMIT = 10000
ACTIVE_GIT: subprocess.Popen | None = None


class Refusal(Exception):
    """A safe, bounded reason to decline a mirror refresh."""


def private_file(path: Path, *, nonempty: bool = False) -> bytes:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
        raise Refusal("private configuration owner or type is invalid")
    if stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
        raise Refusal("private configuration must be mode 0600")
    if info.st_size > 65536 or (nonempty and info.st_size == 0):
        raise Refusal("private configuration size is invalid")
    return path.read_bytes()


def private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise Refusal("Git cache directory must be private mode 0700")


def remote_url(value: str) -> str:
    if not isinstance(value, str) or len(value) > 512 or any(
            ord(char) < 33 or ord(char) > 126 for char in value):
        raise Refusal("repository URL is invalid")
    parsed = urlsplit(value)
    try:
        port = parsed.port
    except ValueError as exc:
        raise Refusal("repository URL port is invalid") from exc
    if (parsed.scheme != "ssh" or not parsed.username or parsed.password
            or not parsed.hostname or parsed.query or parsed.fragment
            or not USER_RE.fullmatch(parsed.username)
            or not HOST_RE.fullmatch(parsed.hostname)
            or not PATH_RE.fullmatch(parsed.path)
            or any(segment == ".." for segment in parsed.path.split("/"))
            or "%" in value or (port is not None and not 1 <= port <= 65535)):
        raise Refusal("repository URL must be a credential-free SSH URL")
    return value


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise Refusal("duplicate repository key")
        result[key] = value
    return result


def configuration(config: Path | None = None) -> tuple[dict[str, str], Path, Path]:
    if config is None:
        config = Path.home() / ".config" / "emacsos"
    mapping = config / "assist-git-remotes.json"
    key = config / "assist-git-read-key"
    hosts = config / "assist-git-known-hosts"
    raw = private_file(mapping, nonempty=True)
    private_file(key, nonempty=True)
    private_file(hosts, nonempty=True)
    try:
        remotes = json.loads(raw, object_pairs_hook=unique_object)
    except (UnicodeError, ValueError) as exc:
        raise Refusal("repository map is malformed") from exc
    if not isinstance(remotes, dict) or len(remotes) > 100:
        raise Refusal("repository map is malformed")
    for repo_key, url in remotes.items():
        if not KEY_RE.fullmatch(repo_key):
            raise Refusal("repository map key is invalid")
        remote_url(url)
    return remotes, key, hosts


def git_environment(key: Path, hosts: Path) -> dict[str, str]:
    ssh = (
        "ssh -F /dev/null -i " + shlex.quote(str(key))
        + " -o UserKnownHostsFile=" + shlex.quote(str(hosts))
        + " -o GlobalKnownHostsFile=/dev/null"
        + " -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes"
        + " -o BatchMode=yes -o NumberOfPasswordPrompts=0"
        + " -o ConnectTimeout=8"
    )
    return {
        "PATH": "/usr/bin:/bin",
        "HOME": str(Path.home()),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_ALLOW_PROTOCOL": "ssh",
        "GIT_PROTOCOL_FROM_USER": "0",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/bin/false",
        "SSH_ASKPASS": "/bin/false",
        "GIT_SSH_COMMAND": ssh,
        "LC_ALL": "C",
    }


def terminate_git_tree(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass
    # Git can exit promptly while an SSH grandchild survives SIGTERM.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=1)


def stop_on_signal(signum: int, _frame: object) -> None:
    if ACTIVE_GIT is not None:
        terminate_git_tree(ACTIVE_GIT)
    raise SystemExit(128 + signum)


def git(args: list[str], env: dict[str, str], *, seconds: int = 20) -> str:
    global ACTIVE_GIT
    output = bytearray()
    try:
        process = subprocess.Popen(
            ["git", "-c", "core.hooksPath=/dev/null",
             "-c", "core.fsmonitor=false",
             "-c", "core.symlinks=false",
             "-c", "fetch.recurseSubmodules=false",
             "-c", "submodule.recurse=false",
             "-c", "protocol.allow=never",
             "-c", "protocol.ssh.allow=always", *args],
            env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, start_new_session=True,
        )
        ACTIVE_GIT = process
        deadline = time.monotonic() + seconds
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(args, seconds)
                for key, _ in selector.select(remaining):
                    chunk = os.read(key.fd, 4097 - len(output))
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        output.extend(chunk)
                        if len(output) > 4096:
                            raise Refusal("Git command returned an oversized result")
        process.wait(timeout=max(0.01, deadline - time.monotonic()))
    except (OSError, subprocess.TimeoutExpired, Refusal) as exc:
        if ACTIVE_GIT is not None:
            terminate_git_tree(ACTIVE_GIT)
        if isinstance(exc, Refusal):
            raise
        raise Refusal("Git operation timed out" if isinstance(
            exc, subprocess.TimeoutExpired) else "Git command unavailable") from exc
    finally:
        if ACTIVE_GIT is not None and ACTIVE_GIT.stdout is not None:
            ACTIVE_GIT.stdout.close()
        ACTIVE_GIT = None
    if process.returncode:
        raise Refusal("Git command failed")
    return output.decode("ascii", errors="strict").strip()


def tree_size(root: Path, *, omit_git: bool = False) -> tuple[int, int]:
    total = count = 0
    stack = [root]
    while stack:
        directory = stack.pop()
        for entry in os.scandir(directory):
            if omit_git and directory == root and entry.name == ".git":
                continue
            info = entry.stat(follow_symlinks=False)
            if stat.S_ISDIR(info.st_mode):
                stack.append(Path(entry.path))
            elif stat.S_ISREG(info.st_mode):
                total += info.st_size
                count += 1
            else:
                raise Refusal("mirror contains an unsupported file type")
            if count > FILE_LIMIT or total > TOTAL_LIMIT:
                raise Refusal("Git mirror exceeds its cache limit")
    return total, count


def refresh(request: dict) -> dict:
    repo_key = request.get("repo_key")
    branch = request.get("branch")
    expected = request.get("expected_oid")
    generation = request.get("generation")
    root = Path(request.get("cache_root", ""))
    if (not isinstance(repo_key, str) or not KEY_RE.fullmatch(repo_key)
            or not isinstance(branch, str) or len(branch) > 240
            or not isinstance(expected, str) or not OID_RE.fullmatch(expected)
            or not isinstance(generation, str) or not ID_RE.fullmatch(generation)
            or not root.is_absolute()):
        raise Refusal("mirror request metadata is invalid")
    remotes, key, hosts = configuration()
    url = remotes.get(repo_key)
    if url is None:
        raise Refusal("no configured Git remote for this repository key")
    private_directory(root)
    staging_root = root / "staging"
    private_directory(staging_root)
    if shutil.disk_usage(root).free < FREE_MARGIN:
        raise Refusal("insufficient free space for Git mirror")
    private_directory(root / "generations")
    stage = staging_root / generation
    if stage.exists() or stage.is_symlink():
        raise Refusal("Git staging generation already exists")
    stage.mkdir(mode=0o700)
    env = git_environment(key, hosts)
    if branch in ("main", "HEAD"):
        shutil.rmtree(stage)
        raise Refusal("thread branch is main or detached HEAD")
    try:
        git(["check-ref-format", "refs/heads/" + branch], env)
    except Refusal as exc:
        shutil.rmtree(stage)
        raise Refusal("thread branch is not a valid Git ref") from exc
    try:
        git(["init", "--quiet", "--template=", "--initial-branch=thread",
             str(stage)], env)
        git(["-C", str(stage), "fetch", "--no-tags", "--no-write-fetch-head",
             "--no-recurse-submodules", url,
             "+refs/heads/main:refs/remotes/assist/main",
             "+refs/heads/" + branch + ":refs/remotes/assist/thread"],
            env, seconds=60)
        thread_oid = git(["-C", str(stage), "rev-parse", "--verify",
                          "refs/remotes/assist/thread^{commit}"], env)
        main_oid = git(["-C", str(stage), "rev-parse", "--verify",
                        "refs/remotes/assist/main^{commit}"], env)
        if not OID_RE.fullmatch(thread_oid) or not OID_RE.fullmatch(main_oid):
            raise Refusal("fetched Git refs are invalid")
        if thread_oid != expected:
            raise Refusal("remote update pending: fetched branch differs from authenticated revision")
        objects = stage / ".git" / "objects"
        if tree_size(objects)[0] > OBJECT_LIMIT:
            raise Refusal("Git objects exceed the mirror limit")
        git(["-C", str(stage), "update-ref", "refs/heads/" + branch,
             thread_oid], env)
        git(["-C", str(stage), "update-ref", "refs/heads/main", main_oid], env)
        git(["-C", str(stage), "symbolic-ref", "HEAD",
             "refs/heads/" + branch], env)
        git(["-C", str(stage), "reset", "--hard", thread_oid], env,
            seconds=30)
        worktree_bytes, files = tree_size(stage, omit_git=True)
        if worktree_bytes > WORKTREE_LIMIT or files > FILE_LIMIT:
            raise Refusal("checked-out Git files exceed the mirror limit")
        if git(["-C", str(stage), "status", "--porcelain", "--untracked-files=all"],
               env):
            raise Refusal("checked-out Git mirror is not clean")
        if tree_size(stage)[0] > TOTAL_LIMIT:
            raise Refusal("Git mirror exceeds the total cache limit")
        if tree_size(root)[0] > TOTAL_LIMIT:
            raise Refusal("total Git cache exceeds its limit")
        return {"ok": True, "generation": generation,
                "thread_oid": thread_oid, "main_oid": main_oid,
                "bytes": worktree_bytes, "files": files}
    except BaseException:
        shutil.rmtree(stage)
        raise


def cleanup(request: dict) -> dict:
    generation = request.get("generation")
    kind = request.get("kind")
    root = Path(request.get("cache_root", ""))
    if (not isinstance(generation, str) or not ID_RE.fullmatch(generation)
            or kind not in ("staging", "generations") or not root.is_absolute()):
        raise Refusal("cleanup request is invalid")
    private_directory(root)
    target = root / kind / generation
    if target.is_symlink():
        raise Refusal("cleanup target is a symlink")
    if target.exists():
        shutil.rmtree(target)
    return {"ok": True}


def main() -> None:
    os.umask(0o077)
    signal.signal(signal.SIGTERM, stop_on_signal)
    try:
        if (len(sys.argv) in (2, 3) and sys.argv[1] == "--check-config"):
            configuration(Path(sys.argv[2]) if len(sys.argv) == 3 else None)
            result = {"ok": True}
        elif len(sys.argv) == 1:
            raw = sys.stdin.buffer.read(4097)
            if len(raw) > 4096:
                raise Refusal("helper request is too large")
            request = json.loads(raw)
            if not isinstance(request, dict):
                raise Refusal("helper request is invalid")
            action = request.get("action")
            if action == "refresh":
                result = refresh(request)
            elif action == "cleanup":
                result = cleanup(request)
            else:
                raise Refusal("helper action is invalid")
        else:
            raise Refusal("helper invocation is invalid")
    except (Refusal, OSError, UnicodeError, ValueError) as exc:
        result = {"ok": False, "reason": str(exc) if isinstance(exc, Refusal)
                  else "Git mirror operation failed"}
    sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
