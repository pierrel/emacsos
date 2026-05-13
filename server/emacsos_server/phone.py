"""Drive a remote emacs daemon over TCP via ``emacsclient``.

The phone POSTs the contents of its emacs auth file
(``~/.emacs.d/server/server``) with each chat request.  The file emacs
writes contains ``0.0.0.0`` as the host (because the daemon binds to
all interfaces); the real reachable address is whatever IP the HTTP
request came from.  We substitute that in, write a temp file, and
shell out to ``emacsclient -f``.
"""
from __future__ import annotations

import logging
import subprocess
import tempfile
from contextlib import contextmanager
from typing import Iterator

log = logging.getLogger(__name__)

AUTH_PLACEHOLDER_HOST = "0.0.0.0"


@contextmanager
def _auth_file(auth_contents: str, phone_host: str) -> Iterator[str]:
    fixed = auth_contents.replace(AUTH_PLACEHOLDER_HOST, phone_host)
    with tempfile.NamedTemporaryFile(mode="w", suffix=".server", delete=True) as f:
        f.write(fixed)
        f.flush()
        yield f.name


def call_emacs(
    auth_contents: str,
    phone_host: str,
    expr: str,
    emacsclient: str = "emacsclient",
    timeout: float = 5.0,
) -> tuple[bool, str]:
    """Send an elisp expression to the phone.

    Returns ``(ok, output_or_error)``.  ``ok`` is False if emacsclient
    exited non-zero, timed out, or could not be invoked.
    """
    try:
        with _auth_file(auth_contents, phone_host) as path:
            result = subprocess.run(
                [emacsclient, "-f", path, "-e", expr],
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        if result.returncode == 0:
            return True, result.stdout.strip()
        return False, result.stderr.strip() or f"exit {result.returncode}"
    except subprocess.TimeoutExpired:
        return False, f"emacsclient timed out after {timeout}s"
    except FileNotFoundError:
        return False, f"emacsclient binary not found: {emacsclient}"
    except OSError as e:
        return False, str(e)
