#!/usr/bin/env python3
"""Bounded, noninteractive Git work for the Assist thread mirror.

The Emacs client supplies a repository key, thread ID, branch, admitted workspace,
private metadata root and fast-forward admission flag.  This process validates
the request, resolves the remote from private device configuration, and never
emits the URL, SSH diagnostics, or credential material.
"""

import fcntl
import hashlib
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
import tempfile
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
OPERATION_LOCK: int | None = None


class Refusal(Exception):
    """A safe, bounded reason to decline a mirror refresh."""


class WorkspaceChoice(Refusal):
    """A bounded local choice, not authority to replace an existing workspace."""

    def __init__(self, choices: list[dict]):
        super().__init__("existing workspace needs local choice")
        self.choices = choices


def workspace_directory(path: Path) -> None:
    """Create an owned directory, never follow symlinks or chmod existing work."""
    if path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
        raise Refusal("workspace directory is invalid")
    if not path.exists():
        workspace_directory(path.parent)
        path.mkdir(mode=0o700)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
            or info.st_mode & 0o022):
        raise Refusal("workspace directory is invalid")


def workspace_slug(value: object, fallback: str) -> str:
    """Return one bounded filename component; labels are never source authority."""
    if not isinstance(value, str) or len(value.encode()) > 4096:
        return fallback
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")[:48].rstrip("-") or fallback


def stable_identity(repo_key: str, tid: str) -> str:
    return hashlib.sha256((repo_key + "\n" + tid).encode()).hexdigest()


def route_path(record: dict, root: Path, workspaces: Path,
               repo_key: str, tid: str) -> Path:
    """Resolve an exact identity's private route under one of two fixed anchors."""
    if (not isinstance(record, dict) or record.get("repo_key") != repo_key
            or record.get("thread_id") != tid):
        raise Refusal("workspace binding is invalid")
    initialized = record.get("initialized")
    if initialized is not False and initialized is not True and initialized != "installing":
        raise Refusal("workspace binding is invalid")
    legacy = record.get("legacy")
    relative = record.get("relative")
    if isinstance(legacy, str) and re.fullmatch(r"[0-9a-f]{64}", legacy) and relative is None:
        return root / "checkouts" / legacy
    if (legacy is None and isinstance(relative, str)
            and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,47}/[a-z0-9][a-z0-9-]{0,47}-[0-9a-f]{12}", relative)
            and relative.endswith("-" + stable_identity(repo_key, tid)[:12])):
        return workspaces / relative
    raise Refusal("workspace binding is invalid")


def read_route(path: Path) -> dict:
    if path.lstat().st_size > 2048:
        raise Refusal("workspace binding is invalid")
    return json.loads(private_file(path), object_pairs_hook=unique_object)


def write_route(path: Path, record: dict) -> None:
    """Atomically publish only private binding metadata, never workspace bytes."""
    descriptor, temporary = tempfile.mkstemp(prefix=".route-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(record, output)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def workspace_bindings(root: Path, workspaces: Path) -> dict[Path, str]:
    """Read bounded valid bindings, refusing duplicate physical ownership."""
    bindings = {}
    for index, route in enumerate((root / "routes").glob("*.json")):
        if index >= FILE_LIMIT:
            raise Refusal("workspace binding inventory exceeds its limit")
        record = read_route(route)
        if not isinstance(record, dict):
            raise Refusal("workspace binding is invalid")
        repo_key, tid = record.get("repo_key"), record.get("thread_id")
        if (not isinstance(repo_key, str) or not KEY_RE.fullmatch(repo_key)
                or not isinstance(tid, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", tid)):
            raise Refusal("workspace binding is invalid")
        identity = stable_identity(repo_key, tid)
        if route.name != identity + ".json":
            raise Refusal("workspace binding is invalid")
        checkout = route_path(record, root, workspaces, repo_key, tid)
        if checkout in bindings:
            raise Refusal("workspace is already bound to another thread")
        bindings[checkout] = identity
    return bindings


def physical_lock(checkout: Path, legacy: str | None) -> str:
    """Keep old physical locks; new locks depend on the path, not the thread."""
    return legacy or "path-" + hashlib.sha256(os.fsencode(checkout)).hexdigest()


def legacy_choices(root: Path, url: str, env: dict, bindings: dict[Path, str]) -> list[dict]:
    """Inspect only bounded old managed paths, disclosing no configured URL."""
    choices = []
    for index, entry in enumerate((root / "checkouts").iterdir()):
        if index >= FILE_LIMIT:
            raise Refusal("legacy workspace inventory exceeds its limit")
        if not re.fullmatch(r"[0-9a-f]{64}", entry.name):
            continue
        if entry in bindings:
            continue
        private_directory(entry)
        if not (entry / ".git").is_dir() or (entry / ".git").is_symlink():
            raise Refusal("legacy workspace source is unavailable")
        if git(["-C", str(entry), "remote", "get-url", "origin"], env, seconds=2) == url:
            branch = git(["-C", str(entry), "rev-parse", "--abbrev-ref", "HEAD"], env, seconds=2)
            if branch == "HEAD":
                branch = "detached"
            choices.append({"identity": entry.name,
                            "branch": re.sub(r"[^A-Za-z0-9._/-]", "?", branch)[:48]})
            if len(choices) > 16:
                raise Refusal("legacy workspace inventory exceeds its limit")
    return choices


def allocate_workspace(request: dict, root: Path, workspaces: Path,
                       repo_key: str, tid: str, branch: str, url: str, env: dict) -> tuple[Path, str]:
    """Freeze one path, registering legacy work in place without changing Git bytes."""
    identity = stable_identity(repo_key, tid)
    routes = root / "routes"
    private_directory(routes)
    bindings = workspace_bindings(root, workspaces)
    route = routes / (identity + ".json")
    if route.exists() or route.is_symlink():
        record = read_route(route)
        checkout = route_path(record, root, workspaces, repo_key, tid)
        if record.get("initialized") == "installing":
            raise Refusal("workspace initialization interrupted; local files preserved")
        if record.get("initialized") is False and (checkout.exists() or checkout.is_symlink()):
            raise Refusal("workspace destination already exists; local work preserved")
        if record.get("initialized") is not False and not checkout.exists():
            raise Refusal("bound workspace missing; restore its existing path")
        return checkout, physical_lock(checkout, record.get("legacy"))
    legacy = hashlib.sha256((repo_key + "\n" + tid + "\n" + branch).encode()).hexdigest()
    choice = request.get("workspace_choice")
    if choice is not None and (not isinstance(choice, str)
                               or (choice != "new" and not re.fullmatch(r"[0-9a-f]{64}", choice))):
        raise Refusal("workspace choice is invalid")
    if (root / "checkouts" / legacy).exists():
        choice = None  # An exact known existing workspace is never replaced.
    if choice is None and not (root / "checkouts" / legacy).exists():
        choices = legacy_choices(root, url, env, bindings)
        if choices:
            raise WorkspaceChoice(choices)
    elif choice != "new":
        legacy = choice or legacy
        if choice is not None and not (root / "checkouts" / legacy).exists():
            raise Refusal("chosen legacy workspace is unavailable")
    if choice == "new" or not (root / "checkouts" / legacy).exists():
        relative = (workspace_slug(request.get("repo_label"), "repo") + "/"
                    + workspace_slug(request.get("thread_label"), "thread") + "-" + identity[:12])
        record = {"repo_key": repo_key, "thread_id": tid, "legacy": None,
                  "relative": relative, "initialized": False}
        checkout = route_path(record, root, workspaces, repo_key, tid)
        workspace_directory(checkout.parent)
        if checkout.exists() or checkout.is_symlink():
            raise Refusal("workspace destination already exists; local work preserved")
    else:
        record = {"repo_key": repo_key, "thread_id": tid, "legacy": legacy,
                  "relative": None, "initialized": True}
        checkout = route_path(record, root, workspaces, repo_key, tid)
        private_directory(checkout)
        if not (checkout / ".git").is_dir() or (checkout / ".git").is_symlink():
            raise Refusal("legacy workspace Git directory is invalid")
        if git(["-C", str(checkout), "remote", "get-url", "origin"], env, seconds=2) != url:
            raise Refusal("legacy workspace remote differs from configured repository")
    # Serialize only metadata publication, never the legacy Git inventory.
    with os.fdopen(os.open(root / "locks" / "workspace-bindings",
                           os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "rb") as publication:
        try:
            fcntl.flock(publication.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise Refusal("another Git operation is allocating a workspace") from exc
        if checkout in workspace_bindings(root, workspaces):
            raise Refusal("workspace is already bound to another thread")
        if route.exists() or route.is_symlink():
            raise Refusal("workspace binding changed; Refresh to retry")
        # Atomic publication freezes allocation even if the following fetch fails.
        write_route(route, record)
    return checkout, physical_lock(checkout, record.get("legacy"))


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
    if path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
        raise Refusal("Git metadata directory is invalid")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise Refusal("Git cache directory must be private mode 0700")


def promote_workspace(stage: Path, checkout: Path) -> None:
    """Atomically install our staged directory without replacing any user path."""
    try:
        import ctypes
        rename = ctypes.CDLL(None, use_errno=True).renameat2
    except (ImportError, AttributeError) as exc:
        raise Refusal("atomic workspace promotion unavailable") from exc
    rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                       ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    # Linux AT_FDCWD and RENAME_NOREPLACE: no overwrite, including empty dirs.
    if rename(-100, os.fsencode(stage), -100, os.fsencode(checkout), 1):
        import errno
        error = ctypes.get_errno()
        if error == errno.EEXIST:
            raise Refusal("workspace destination already exists; local work preserved")
        raise OSError(error, "workspace promotion failed")


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
    key = config / "assist-git-key"
    hosts = config / "assist-git-known-hosts"
    try:
        raw = private_file(mapping, nonempty=True)
    except OSError as exc:
        raise Refusal("Git repository map unavailable") from exc
    try:
        private_file(key, nonempty=True)
    except OSError as exc:
        raise Refusal("Git key unavailable") from exc
    try:
        private_file(hosts, nonempty=True)
    except OSError as exc:
        raise Refusal("Git host pin unavailable") from exc
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


def git(args: list[str], env: dict[str, str], *, seconds: int = 20,
        output_limit: int = 4096, presence_only: bool = False) -> str:
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
            pass_fds=(() if OPERATION_LOCK is None else (OPERATION_LOCK,)),
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
                    chunk = os.read(key.fd, 4096 if presence_only else
                                    min(4096, output_limit + 1 - len(output)))
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        if presence_only:
                            output[:] = b"1"
                        else:
                            output.extend(chunk)
                        if len(output) > output_limit:
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




def cleanup(request: dict) -> dict:
    generation = request.get("generation")
    kind = request.get("kind")
    raw_root = request.get("cache_root", "")
    if not isinstance(raw_root, str):
        raise Refusal("cleanup request is invalid")
    root = Path(raw_root)
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


def sync_checkout(request: dict) -> dict:
    """Fetch the selected thread ref and safely FF its persistent local checkout.

    No operation resets, stashes, pushes or deletes an existing checkout.
    The locked path must equal the client path admitted for buffer protection.
    """
    global OPERATION_LOCK
    repo_key = request.get("repo_key")
    branch = request.get("branch")
    tid = request.get("thread_id")
    raw_root = request.get("cache_root", "")
    if not isinstance(raw_root, str):
        raise Refusal("checkout request metadata is invalid")
    root = Path(raw_root)
    raw_workspaces = request.get("workspace_root")
    admitted_path = request.get("checkout_path")
    if not isinstance(raw_workspaces, str) or not isinstance(admitted_path, str):
        raise Refusal("checkout request metadata is invalid")
    workspaces = Path(raw_workspaces)
    if (not isinstance(repo_key, str) or not KEY_RE.fullmatch(repo_key)
            or not isinstance(tid, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", tid)
            or not isinstance(branch, str) or not 1 <= len(branch.encode()) <= 240
            or branch in ("main", "HEAD") or branch.startswith("-") or not root.is_absolute()
            or not workspaces.is_absolute() or not Path(admitted_path).is_absolute()):
        raise Refusal("checkout request metadata is invalid")
    remotes, key, hosts = configuration()
    url = remotes.get(repo_key)
    if url is None:
        raise Refusal("no configured Git remote for this repository key")
    env = git_environment(key, hosts)
    git(["check-ref-format", "refs/heads/" + branch], env)
    private_directory(root)
    private_directory(root / "checkouts")
    identity = stable_identity(repo_key, tid)
    private_directory(root / "locks")
    allocation = os.open(root / "locks" / ("workspace-" + identity),
                         os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    descriptor = allocation
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise Refusal("another Git operation is still using this checkout") from exc
        OPERATION_LOCK = allocation
        checkout, physical = allocate_workspace(request, root, workspaces,
                                                repo_key, tid, branch, url, env)
        if str(checkout) != admitted_path:
            raise Refusal("workspace binding changed; Refresh to retry")
        descriptor = os.open(root / "locks" / physical,
                             os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise Refusal("another Git operation is still using this checkout") from exc
        OPERATION_LOCK = descriptor
        if shutil.disk_usage(checkout.parent).free < FREE_MARGIN:
            raise Refusal("insufficient free space for Git fetch")
        new = not checkout.exists()
        if checkout.is_symlink():
            raise Refusal("checkout path is a symlink")
        stage = checkout.with_name("." + checkout.name + ".initial")
        working = stage if new else checkout
        if new:
            if stage.exists() or stage.is_symlink():
                raise Refusal("initial checkout interrupted; inspect staging before Retry")
            stage.mkdir(mode=0o700)
        else:
            workspace_directory(checkout)
            if (not (checkout / ".git").is_dir() or (checkout / ".git").is_symlink()):
                raise Refusal("checkout Git directory is invalid")
        try:
            if new:
                git(["init", "--quiet", "--template=", "--initial-branch=thread",
                     str(working)], env)
                git(["-C", str(working), "remote", "add", "origin", url], env)
                # Standard Git/Magit uses this same dedicated identity and pin.
                git(["-C", str(working), "config", "core.sshCommand",
                     env.get("GIT_SSH_COMMAND", "ssh")], env)
                git(["-C", str(working), "config", "core.symlinks", "false"], env)
                git(["-C", str(working), "config", "push.default", "simple"], env)
            elif git(["-C", str(working), "remote", "get-url", "origin"], env) != url:
                raise Refusal("checkout remote differs from the configured repository")
            # Keep checkout bytes bounded by stored blobs, not repository-driven
            # ident/encoding/filter expansion.  This local override also keeps
            # ordinary Git operating on the same literal files as this client.
            attributes = working / ".git" / "info" / "attributes"
            literal_attributes = "* -filter -ident -working-tree-encoding -text -eol\n"
            if new:
                attributes.parent.mkdir(exist_ok=True)
                attributes.write_text(literal_attributes)
            elif (attributes.is_symlink() or not attributes.is_file()
                  or attributes.stat().st_size > 1024
                  or attributes.read_text() != literal_attributes):
                raise Refusal("local checkout conversion policy changed; inspect Git configuration")
            git(["-C", str(working), "fetch", "--no-tags", "--no-write-fetch-head",
                 "--no-recurse-submodules", url,
                 "+refs/heads/main:refs/remotes/origin/main",
                 "+refs/heads/" + branch + ":refs/remotes/origin/" + branch],
                env, seconds=60)
            remote_oid = git(["-C", str(working), "rev-parse", "--verify",
                              "refs/remotes/origin/" + branch + "^{commit}"], env)
            main_oid = git(["-C", str(working), "rev-parse", "--verify",
                            "refs/remotes/origin/main^{commit}"], env)
            if not OID_RE.fullmatch(remote_oid) or not OID_RE.fullmatch(main_oid):
                raise Refusal("fetched Git refs are invalid")
            if tree_size(working / ".git" / "objects")[0] > OBJECT_LIMIT:
                raise Refusal("Git objects exceed the checkout limit")
            # Check expanded blob sizes before checkout, not compressed pack bytes.
            sizes = git(["-C", str(working), "ls-tree", "-r",
                         "--format=%(objecttype) %(objectsize)", remote_oid],
                        env, output_limit=512 * 1024).splitlines()
            if (len(sizes) > FILE_LIMIT
                    or sum(int(line.split()[1]) for line in sizes
                           if line.startswith("blob ")) > WORKTREE_LIMIT):
                raise Refusal("committed thread files exceed the checkout limit")
            pending = None
            if new:
                git(["-C", str(working), "checkout", "--quiet", "--no-overwrite-ignore",
                     "-b", branch, "refs/remotes/origin/" + branch], env, seconds=30)
                git(["-C", str(working), "branch", "--set-upstream-to=origin/" + branch,
                     branch], env)
            else:
                actual = git(["-C", str(working), "symbolic-ref", "--short", "HEAD"], env)
                dirty = git(["-C", str(working), "status", "--porcelain",
                             "--untracked-files=all"], env, presence_only=True)
                if actual != branch:
                    pending = "local branch changed; select the thread branch in Magit"
                elif dirty or request.get("allow_ff") is not True:
                    pending = "local edits or Git operation; local update pending"
                else:
                    try:
                        git(["-C", str(working), "merge", "--ff-only", "--no-autostash",
                             "--no-overwrite-ignore", remote_oid], env, seconds=30)
                    except Refusal:
                        pending = "fast-forward unavailable; local update pending"
            local_oid = git(["-C", str(working), "rev-parse", "--verify", "HEAD^{commit}"], env)
            if not pending and local_oid != remote_oid:
                pending = "local commits differ from remote; push or reconcile in Magit"
            dirty = bool(git(["-C", str(working), "status", "--porcelain",
                              "--untracked-files=all"], env, presence_only=True))
            if new:
                worktree_bytes, files = tree_size(working, omit_git=True)
                if (worktree_bytes > WORKTREE_LIMIT or files > FILE_LIMIT
                        or tree_size(working)[0] > TOTAL_LIMIT):
                    raise Refusal("initial Git checkout exceeds its cache limit")
            actual = git(["-C", str(working), "symbolic-ref", "--short", "HEAD"], env)
            if new:
                route = root / "routes" / (identity + ".json")
                record = read_route(route)
                record["initialized"] = "installing"
                # An interrupted promotion refuses retry, whether the path is
                # missing or occupied. It must not adopt somebody else's work.
                write_route(route, record)
                promote_workspace(working, checkout)
                record["initialized"] = True
                write_route(route, record)
            return {"ok": True, "checkout_path": str(checkout),
                    "thread_oid": remote_oid, "local_oid": local_oid, "main_oid": main_oid,
                    "dirty": dirty, "pending": pending, "actual_branch": actual}
        except BaseException:
            if new and stage.exists():
                shutil.rmtree(stage)
            raise
    finally:
        OPERATION_LOCK = None
        if descriptor != allocation:
            os.close(descriptor)
        os.close(allocation)


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
            if action == "sync":
                result = sync_checkout(request)
            elif action == "cleanup":
                result = cleanup(request)
            else:
                raise Refusal("helper action is invalid")
        else:
            raise Refusal("helper invocation is invalid")
    except (Refusal, OSError, UnicodeError, ValueError) as exc:
        if isinstance(exc, Refusal):
            reason = str(exc)
        elif isinstance(exc, OSError):
            reason = "Git mirror local I/O unavailable"
        else:
            reason = "Git mirror local data invalid"
        result = {"ok": False, "reason": reason}
        if isinstance(exc, WorkspaceChoice):
            result["workspace_choices"] = exc.choices
    sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
