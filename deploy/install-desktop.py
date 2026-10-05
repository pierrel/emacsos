#!/usr/bin/env python3
"""Install the standalone Assist payload without changing private user setup."""

import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile


FILES = ("assist-desktop.el", "chat.el", "assist-web.el", "assist-web-git.el",
         "assist-web-git-helper.py")


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(65536), b""):
            result.update(chunk)
    return result.hexdigest()


def handoff(staged, installed, exchange):
    """Atomically exchange existing bytes, or admit a new path without replacement."""
    import ctypes
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        rename = library.renamex_np
        rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
        arguments = (os.fsencode(staged), os.fsencode(installed), 2 if exchange else 4)
    else:
        rename = library.renameat2
        rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                           ctypes.c_char_p, ctypes.c_uint)
        arguments = (-100, os.fsencode(staged), -100, os.fsencode(installed),
                     2 if exchange else 1)
    rename.restype = ctypes.c_int
    if rename(*arguments):
        raise OSError(ctypes.get_errno(), f"Install handoff failed; files retained in {staged.parent}")


def install():
    configured = os.environ.get("DESKTOP_ASSIST_DIR", "")
    if not configured:
        raise ValueError("DESKTOP_ASSIST_DIR must not be empty")
    target = Path(configured).expanduser()
    source = Path(__file__).resolve().parents[1]
    payload = {name: (source / name).read_bytes() for name in FILES}
    hashes = {name: hashlib.sha256(data).hexdigest() for name, data in payload.items()}
    manifest = target / ".assist-desktop-install.json"
    previous = {}
    if manifest.is_symlink():
        raise ValueError("Install record must not be a symlink")
    if manifest.exists():
        if not manifest.is_file() or manifest.stat().st_size > 8192:
            raise ValueError("Install record is invalid")
        previous = json.loads(manifest.read_text())
        if not isinstance(previous, dict):
            raise ValueError("Install record is invalid")
    for name in FILES:
        installed = target / name
        if installed.exists() or installed.is_symlink():
            if (installed.is_symlink() or not installed.is_file()
                    or digest(installed) not in (hashes[name], previous.get(name))):
                raise ValueError(f"Installed file changed: {name}; local work preserved")
    target.mkdir(parents=True, exist_ok=True)
    # Exchanges leave the previous inode here, including a concurrent user save.
    # Never recursively clean this directory: interruption must preserve its bytes.
    staging = Path(tempfile.mkdtemp(prefix=".assist-desktop-update-", dir=target))
    for name, data in payload.items():
        item = staging / name
        item.write_bytes(data)
        item.chmod(0o755 if name.endswith(".py") else 0o644)
    record = staging / manifest.name
    record.write_text(json.dumps(hashes, sort_keys=True) + "\n")
    record.chmod(0o600)
    for name in FILES:
        installed = target / name
        item = staging / name
        if installed.is_file() and not installed.is_symlink() and digest(installed) == hashes[name]:
            item.unlink()
            installed.chmod(0o755 if name.endswith(".py") else 0o644)
        else:
            handoff(item, installed, installed.exists() or installed.is_symlink())
    os.replace(record, manifest)
    if any(staging.iterdir()):
        print(f"Previous client files preserved in {staging}")
    else:
        staging.rmdir()
    print(f"Installed desktop Assist in {target}")
    print("Private configuration, credentials, caches and thread workspaces were not changed.")
    print("Configure before loading assist-desktop.el; run M-x emacsos-desktop-assist.")


if __name__ == "__main__":
    try:
        install()
    except (OSError, ValueError, AttributeError) as error:
        print(f"Desktop install failed: {error}", file=sys.stderr)
        sys.exit(1)
