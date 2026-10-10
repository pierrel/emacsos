#!/usr/bin/env python3
"""Fetch approved thread refs into an ordinary user-owned checkout.

The disposable bare repository owns network credentials. Repository-local Git
configuration is never read by a credentialed command. Existing checkout files,
index and branch are changed only by Git's clean fast-forward operation.
"""

from __future__ import annotations

import fcntl
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import resource
import selectors
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit


KEY = re.compile(r"[0-9a-f]{20}\Z")
THREAD = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
OID = re.compile(r"[0-9a-f]{40}\Z")
HOST = re.compile(r"[A-Za-z0-9][A-Za-z0-9.:-]*\Z")
USER = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*\Z")
REMOTE_PATH = re.compile(r"/[A-Za-z0-9._/~+-]+\Z")
MAX_BUNDLE = 256 * 1024 * 1024
MAX_FETCH_BYTES = 512 * 1024 * 1024
MAX_OUTPUT = 1024 * 1024
ACTIVE_GIT: subprocess.Popen | None = None


class Refusal(Exception):
    """A bounded, user-visible reason to preserve the checkout unchanged."""


def private_file(path: Path, limit: int = 65536) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_mode & 0o077 or info.st_size > limit):
            raise Refusal("Git credential configuration is not private")
        data = os.read(descriptor, limit + 1)
        if len(data) > limit:
            raise Refusal("Git credential configuration is too large")
        return data
    finally:
        os.close(descriptor)


def directory(path: Path) -> None:
    """Admit or create only user-owned directories without symlink parents."""
    if path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
        raise Refusal("Git workspace path is not a private directory")
    if not path.exists():
        directory(path.parent)
        path.mkdir(mode=0o700)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
            or info.st_mode & 0o022):
        raise Refusal("Git workspace path is not a private directory")


def approved_url(value: object) -> str:
    if not isinstance(value, str) or len(value) > 512 or any(
            ord(char) < 33 or ord(char) > 126 for char in value):
        raise Refusal("Git repository map is invalid")
    parsed = urlsplit(value)
    try:
        port = parsed.port
    except ValueError as error:
        raise Refusal("Git repository map is invalid") from error
    if (parsed.scheme != "ssh" or not parsed.username or parsed.password
            or not parsed.hostname or parsed.query or parsed.fragment
            or not USER.fullmatch(parsed.username) or not HOST.fullmatch(parsed.hostname)
            or not REMOTE_PATH.fullmatch(parsed.path)
            or any(part == ".." for part in parsed.path.split("/"))
            or "%" in value or port is not None and not 1 <= port <= 65535):
        raise Refusal("Git repository map requires a credential-free SSH URL")
    return value


def configuration(config: Path, repo_key: str) -> tuple[str, dict[str, str]]:
    raw = private_file(config / "assist-git-remotes.json")
    def unique_pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
        values = {}
        for key, value in pairs:
            if key in values:
                raise Refusal("Git repository map has duplicate keys")
            values[key] = value
        return values
    try:
        remotes = json.loads(raw, object_pairs_hook=unique_pairs)
    except (UnicodeError, ValueError) as error:
        raise Refusal("Git repository map is invalid") from error
    if (not isinstance(remotes, dict) or len(remotes) > 100
            or any(not isinstance(key, str) or not KEY.fullmatch(key) for key in remotes)):
        raise Refusal("Git repository map is invalid")
    url = approved_url(remotes.get(repo_key))
    key, hosts = config / "assist-git-key", config / "assist-git-known-hosts"
    if not private_file(key, 16384) or not private_file(hosts):
        raise Refusal("Git credential or pinned host is unavailable")
    ssh = ("ssh -F /dev/null -i " + shlex.quote(str(key))
           + " -o UserKnownHostsFile=" + shlex.quote(str(hosts))
           + " -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes"
           + " -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8")
    environment = {"PATH": "/usr/bin:/bin", "HOME": str(Path.home()),
                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                   "GIT_NO_REPLACE_OBJECTS": "1", "GIT_TERMINAL_PROMPT": "0",
                   "GIT_ALLOW_PROTOCOL": "ssh", "GIT_SSH_COMMAND": ssh, "LC_ALL": "C"}
    return url, environment


def git(arguments: list[str], environment: dict[str, str], *, seconds: int = 30,
        output_limit: int = 4096, network: bool = False,
        allowed: tuple[int, ...] = (0,)) -> str:
    global ACTIVE_GIT
    command = ["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
               "-c", "core.commitGraph=false", "-c", "core.multiPackIndex=false",
               "-c", "pack.useBitmaps=false", "-c", "push.useBitmaps=false",
               "-c", "gc.auto=0", "-c", "maintenance.auto=false",
               "-c", "fetch.fsckObjects=true", "-c", "protocol.ext.allow=never",
               *arguments]
    env = environment if network else {key: value for key, value in environment.items()
                                       if key not in {"GIT_SSH_COMMAND", "GIT_ALLOW_PROTOCOL"}}
    def limit_files() -> None:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
        _, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
        resource.setrlimit(resource.RLIMIT_FSIZE,
                           (min(MAX_FETCH_BYTES, hard) if hard >= 0 else MAX_FETCH_BYTES,
                            hard))
        _, memory_hard = resource.getrlimit(resource.RLIMIT_AS)
        memory_limit = 1024 * 1024 * 1024
        resource.setrlimit(resource.RLIMIT_AS,
                           (min(memory_limit, memory_hard) if memory_hard >= 0
                            else memory_limit, memory_hard))

    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env=env, start_new_session=True,
                                   preexec_fn=limit_files)
        ACTIVE_GIT = process
    finally:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
    output = bytearray()
    try:
        deadline = time.monotonic() + seconds
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise Refusal("Git operation timed out")
                for key, _ in selector.select(remaining):
                    chunk = os.read(key.fd, min(4096, output_limit + 1 - len(output)))
                    if chunk:
                        output.extend(chunk)
                        if len(output) > output_limit:
                            raise Refusal("Git result exceeded its bound")
                    else:
                        selector.unregister(key.fileobj)
        process.wait(timeout=max(.01, deadline - time.monotonic()))
        if process.returncode not in allowed:
            raise Refusal("Git operation failed; local work is preserved")
        return output.decode("utf-8", "strict").rstrip("\n")
    except (OSError, subprocess.TimeoutExpired, Refusal):
        terminate_git(process)
        raise
    finally:
        process.stdout.close()
        ACTIVE_GIT = None


def terminate_git(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=2)


def stop_on_signal(signum: int, _frame: object) -> None:
    if ACTIVE_GIT is not None:
        terminate_git(ACTIVE_GIT)
    raise SystemExit(128 + signum)


def promote_workspace(stage: Path, checkout: Path) -> None:
    """Atomically promote an initial checkout without replacing any user path."""
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        try:
            rename = libc.renamex_np
        except AttributeError as exc:
            raise Refusal("Atomic checkout promotion unavailable") from exc
        rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
        rename.restype = ctypes.c_int
        result = rename(os.fsencode(stage), os.fsencode(checkout), 4)
    else:
        arguments = (ctypes.c_int(-100), ctypes.c_char_p(os.fsencode(stage)),
                     ctypes.c_int(-100), ctypes.c_char_p(os.fsencode(checkout)), ctypes.c_uint(1))
        try:
            rename = libc.renameat2
        except AttributeError:
            number = ({"aarch64": 276, "x86_64": 316}.get(platform.machine())
                      if sys.platform == "linux" and ctypes.sizeof(ctypes.c_void_p) == 8 else None)
            if number is None:
                raise Refusal("Atomic checkout promotion unavailable")
            libc.syscall.restype = ctypes.c_long
            result = libc.syscall(ctypes.c_long(number), *arguments)
        else:
            rename.restype = ctypes.c_int
            result = rename(*arguments)
    if result:
        code = ctypes.get_errno()
        if code == errno.EEXIST:
            raise Refusal("Checkout destination already exists; local work preserved")
        raise OSError(code, "Checkout promotion failed")


def identity(repo_key: str, thread_id: str) -> str:
    return hashlib.sha256((repo_key + "\n" + thread_id).encode()).hexdigest()[:16]


def legacy_checkout(cache: Path, workspace_root: Path,
                    repo_key: str, thread_id: str) -> Path:
    """Resolve one private old binding, never guessing from a remote or branch."""
    route = cache / "routes" / (
        hashlib.sha256((repo_key + "\n" + thread_id).encode()).hexdigest() + ".json")
    if not route.exists():
        raise Refusal("No bound legacy checkout is available to move")
    try:
        record = json.loads(private_file(route, 2048))
    except (UnicodeError, ValueError) as error:
        raise Refusal("Legacy checkout binding is invalid") from error
    if not isinstance(record, dict):
        raise Refusal("Legacy checkout binding is invalid")
    legacy, relative = record.get("legacy"), record.get("relative")
    if (record.get("repo_key") != repo_key or record.get("thread_id") != thread_id
            or record.get("initialized") is not True):
        raise Refusal("Legacy checkout binding is not movable")
    if (isinstance(legacy, str) and re.fullmatch(r"[0-9a-f]{64}", legacy)
            and relative is None):
        old = cache / "checkouts" / legacy
        selected = ("legacy", legacy)
    elif (legacy is None and isinstance(relative, str)
          and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,47}/[a-z0-9][a-z0-9-]{0,47}-[0-9a-f]{12}", relative)
          and relative.endswith("-" + hashlib.sha256(
              (repo_key + "\n" + thread_id).encode()).hexdigest()[:12])):
        old = workspace_root / relative
        selected = ("relative", relative)
    else:
        raise Refusal("Legacy checkout binding is not movable")
    routes = list((cache / "routes").glob("*.json"))
    if len(routes) > 10000:
        raise Refusal("Legacy checkout binding inventory is too large")
    for other in routes:
        if other != route:
            try:
                claim = json.loads(private_file(other, 2048))
            except (UnicodeError, ValueError) as error:
                raise Refusal("Legacy checkout binding inventory is invalid") from error
            if isinstance(claim, dict) and claim.get(selected[0]) == selected[1]:
                raise Refusal("Legacy checkout has more than one binding")
    return old


def verify_checkout_bound(path: Path, environment: dict[str, str]) -> None:
    """Refuse Git metadata that can redirect work outside PATH."""
    metadata = path / ".git"
    stack, count, deadline = [metadata], 0, time.monotonic() + 10
    while stack:
        folder = stack.pop()
        with os.scandir(folder) as entries:
            for entry in entries:
                count += 1
                if count > 100000 or time.monotonic() > deadline:
                    raise Refusal("Checkout Git metadata scan exceeded its bound")
                if entry.is_symlink():
                    raise Refusal("Checkout Git storage leaves its bound directory")
                if entry.is_dir(follow_symlinks=False):
                    stack.append(Path(entry.path))
                elif not entry.is_file(follow_symlinks=False):
                    raise Refusal("Checkout Git metadata is not regular storage")
    for relative in ("commondir", "worktrees", "modules",
                     "objects/info/alternates", "config.worktree"):
        candidate = metadata / relative
        if candidate.exists() or candidate.is_symlink():
            raise Refusal("Path-dependent Git metadata prevents checkout sync")
    keys = git(["-C", str(path), "config", "--local", "--no-includes",
                "--name-only", "--list"], environment, output_limit=65536).lower().splitlines()
    if any(key == "core.worktree" or key == "include.path"
           or key.startswith("includeif.") or key == "extensions.worktreeconfig"
           for key in keys):
        raise Refusal("Path-dependent Git configuration prevents checkout sync")
    if git(["-C", str(path), "rev-parse", "--show-toplevel"], environment) != str(path):
        raise Refusal("Checkout root differs from its bound path")


def checkout_path(root: Path, repo_key: str, thread_id: str) -> Path:
    if not KEY.fullmatch(repo_key) or not THREAD.fullmatch(thread_id):
        raise Refusal("Git thread identity is invalid")
    return root / repo_key / (thread_id + "-" + identity(repo_key, thread_id))


def existing_checkout(path: Path, url: str, environment: dict[str, str]) -> bool:
    if not path.exists() and not path.is_symlink():
        return False
    directory(path)
    metadata = path / ".git"
    if metadata.is_symlink() or not metadata.is_dir():
        raise Refusal("Existing path is not an ordinary Git checkout")
    actual = git(["config", "--file", str(metadata / "config"), "--no-includes",
                  "--get", "remote.origin.url"], environment)
    if actual != url:
        raise Refusal("Existing checkout belongs to another Git remote")
    verify_checkout_bound(path, environment)
    return True


def network_snapshot(source: str, branch: str, checkout: Path | None,
                     environment: dict[str, str], temporary: Path) -> tuple[str, str, Path | None]:
    """Fetch only approved refs using private config, then bundle missing objects."""
    repository = temporary / "fetch.git"
    git(["init", "--bare", "--quiet", str(repository)], environment)
    network_env = dict(environment)
    local = None
    if checkout is not None:
        objects = checkout / ".git" / "objects"
        if objects.is_symlink() or not objects.is_dir():
            raise Refusal("Checkout objects are unavailable")
        local = git(["-C", str(checkout), "rev-parse", "HEAD^{commit}"], environment)
        if not OID.fullmatch(local):
            raise Refusal("Local Git HEAD is invalid")
        network_env["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = str(objects)
    refs = ["refs/heads/main:refs/remotes/origin/main",
            "refs/heads/" + branch + ":refs/remotes/origin/thread"]
    git(["--git-dir", str(repository), "fetch", "--no-tags", source, *refs],
        network_env, seconds=90, network=True)
    main = git(["--git-dir", str(repository), "rev-parse",
                "refs/remotes/origin/main^{commit}"], network_env)
    thread = git(["--git-dir", str(repository), "rev-parse",
                  "refs/remotes/origin/thread^{commit}"], network_env)
    if not OID.fullmatch(main) or not OID.fullmatch(thread):
        raise Refusal("Fetched Git refs are invalid")
    if local is not None and git(["--git-dir", str(repository), "rev-list", "--count",
                                  "refs/remotes/origin/main", "refs/remotes/origin/thread",
                                  "--not", local], network_env) == "0":
        return main, thread, None
    bundle = temporary / "incoming.bundle"
    arguments = ["--git-dir", str(repository), "bundle", "create", str(bundle),
                 "refs/remotes/origin/main", "refs/remotes/origin/thread"]
    if local is not None:
        arguments += ["--not", local]
    git(arguments, network_env, seconds=60)
    if bundle.stat().st_size > MAX_BUNDLE:
        raise Refusal("Fetched Git history exceeds its bound")
    return main, thread, bundle


def sync(request: dict, config: Path | None = None, cache: Path | None = None) -> dict:
    repo_key, thread_id, branch = (request.get("repo_key"), request.get("thread_id"),
                                   request.get("branch"))
    if (not isinstance(repo_key, str) or not isinstance(thread_id, str)
            or not isinstance(branch, str) or branch in {"main", "HEAD"}
            or len(branch.encode()) > 240 or branch.startswith("-")):
        raise Refusal("Git thread metadata is invalid")
    root = Path(request.get("workspace_root", ""))
    if not root.is_absolute() or ".." in root.parts:
        raise Refusal("Git workspace root is invalid")
    checkout = checkout_path(root, repo_key, thread_id)
    source, environment = configuration(config or Path.home() / ".config" / "emacsos",
                                        repo_key)
    git(["check-ref-format", "refs/heads/" + branch], environment)
    directory(checkout.parent)
    lock_path = checkout.parent / ("." + checkout.name + ".lock")
    lock = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        exists = existing_checkout(checkout, source, environment)
        if not exists:
            cache = cache or Path.home() / ".cache" / "emacsos" / "assist-git"
            route_id = hashlib.sha256((repo_key + "\n" + thread_id).encode()).hexdigest()
            route = cache / "routes" / (route_id + ".json")
            legacy_id = hashlib.sha256(
                (repo_key + "\n" + thread_id + "\n" + branch).encode()).hexdigest()
            if (route.exists() or route.is_symlink()
                    or (cache / "checkouts" / legacy_id).exists()):
                raise Refusal("Existing legacy checkout needs explicit migration")
        stage = checkout.with_name("." + checkout.name + ".initial")
        if not exists and (stage.exists() or stage.is_symlink()):
            raise Refusal("Interrupted initial checkout needs local inspection")
        with tempfile.TemporaryDirectory(prefix="assist-git-fetch-") as temporary_name:
            temporary = Path(temporary_name)
            main, remote, bundle = network_snapshot(source, branch,
                                                    checkout if exists else None,
                                                    environment, temporary)
            working = checkout if exists else stage
            if not exists:
                working.mkdir(mode=0o700)
                git(["init", "--quiet", "--template=", str(working)], environment)
                git(["-C", str(working), "remote", "add", "origin", source], environment)
                git(["-C", str(working), "config", "core.sshCommand",
                     environment["GIT_SSH_COMMAND"]], environment)
            if bundle is not None:
                git(["-C", str(working), "bundle", "unbundle", str(bundle)],
                    environment, seconds=60, output_limit=65536)
            git(["-C", str(working), "update-ref", "refs/remotes/origin/main", main],
                environment)
            git(["-C", str(working), "update-ref",
                 "refs/remotes/origin/" + branch, remote], environment)
            if not exists:
                git(["-C", str(working), "checkout", "-b", branch, remote], environment)
                git(["-C", str(working), "branch", "--set-upstream-to=origin/" + branch,
                     branch], environment)
                promote_workspace(stage, checkout)
            actual = git(["-C", str(checkout), "symbolic-ref", "--short", "HEAD"],
                         environment)
            local = git(["-C", str(checkout), "rev-parse", "HEAD^{commit}"], environment)
            status = git(["-C", str(checkout), "status", "--porcelain",
                          "--untracked-files=normal"], environment,
                         output_limit=MAX_OUTPUT)
            dirty = bool(status)
            pending = None
            if actual != branch:
                pending = "select the thread branch in Magit"
            elif local != remote:
                base = git(["-C", str(checkout), "merge-base", local, remote],
                           environment, allowed=(0, 1))
                if base == local:
                    if dirty:
                        pending = ("New thread commits are available. Your local edits are "
                                   "unchanged. Commit your edits, then fetch and merge; or "
                                   "stash them, pull, and reapply the stash.")
                    else:
                        git(["-C", str(checkout), "merge", "--ff-only", "--no-autostash",
                             "--no-overwrite-ignore", remote], environment, seconds=30)
                        local = git(["-C", str(checkout), "rev-parse", "HEAD^{commit}"],
                                    environment)
                        if local != remote:
                            raise Refusal("Git fast-forward did not reach the published branch")
                elif base == remote:
                    pending = "Local commits are not published; push or reconcile in Magit"
                else:
                    pending = "Local and published commits diverged; reconcile in Magit"
            return {"ok": True, "checkout_path": str(checkout), "branch": actual,
                    "local_oid": local, "thread_oid": remote, "main_oid": main,
                    "dirty": dirty, "status_short": status[:240], "pending": pending}
    except BlockingIOError as error:
        raise Refusal("Another Git operation owns this checkout") from error
    finally:
        os.close(lock)


def migrate(request: dict, config: Path | None = None,
            cache: Path | None = None) -> dict:
    """Move one explicitly selected bound checkout without touching its contents."""
    repo_key, thread_id = request.get("repo_key"), request.get("thread_id")
    root = Path(request.get("workspace_root", ""))
    if (not isinstance(repo_key, str) or not isinstance(thread_id, str)
            or not root.is_absolute() or ".." in root.parts):
        raise Refusal("Git migration identity is invalid")
    destination = checkout_path(root, repo_key, thread_id)
    source, environment = configuration(config or Path.home() / ".config" / "emacsos",
                                        repo_key)
    old_root = cache or Path.home() / ".cache" / "emacsos" / "assist-git"
    old = legacy_checkout(old_root, root, repo_key, thread_id)
    if not old.exists() or old.is_symlink():
        raise Refusal("Bound legacy checkout is missing")
    directory(old)
    directory(destination.parent)
    if destination.exists() or destination.is_symlink():
        raise Refusal("Local checkout already exists; migration will not replace it")
    if not existing_checkout(old, source, environment):
        raise Refusal("Bound legacy checkout is missing")
    verify_checkout_bound(old, environment)
    lock_root = old_root / "locks"
    directory(lock_root)
    physical = (old.name if old.parent == old_root / "checkouts" else
                "path-" + hashlib.sha256(os.fsencode(old)).hexdigest())
    names = ("workspace-" + hashlib.sha256((repo_key + "\n" + thread_id).encode()).hexdigest(),
             physical)
    locks = [os.open(lock_root / name, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
             for name in names]
    try:
        for lock in locks:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if legacy_checkout(old_root, root, repo_key, thread_id) != old:
            raise Refusal("Legacy checkout binding changed")
        if not existing_checkout(old, source, environment):
            raise Refusal("Bound legacy checkout changed")
        verify_checkout_bound(old, environment)
        if destination.exists() or destination.is_symlink():
            raise Refusal("Local checkout already exists; migration will not replace it")
        if old.stat().st_dev != destination.parent.stat().st_dev:
            raise Refusal("Checkout migration requires one filesystem")
        promote_workspace(old, destination)
        for parent in (old.parent, destination.parent):
            descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        return {"ok": True, "checkout_path": str(destination)}
    except BlockingIOError as error:
        raise Refusal("Another Git operation owns this checkout") from error
    finally:
        for lock in locks:
            os.close(lock)


def main() -> None:
    os.umask(0o077)
    signal.signal(signal.SIGTERM, stop_on_signal)
    try:
        raw = sys.stdin.buffer.read(8193)
        if len(raw) > 8192:
            raise Refusal("Git request is too large")
        request = json.loads(raw)
        if not isinstance(request, dict) or request.get("action") not in {"sync", "migrate"}:
            raise Refusal("Git action is invalid")
        response = sync(request) if request["action"] == "sync" else migrate(request)
    except (OSError, ValueError, UnicodeError, Refusal) as error:
        response = {"ok": False, "error": str(error)[:256]}
    sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
