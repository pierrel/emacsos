"""Drive a remote emacs daemon via ``emacsclient``.

The phone POSTs the contents of its emacs server auth file with each
request, but the host field in that file is *not* trusted: otherwise
a careless or malicious client could redirect our emacsclient calls
at an arbitrary host:port.  We parse the file for port + pid +
secret, discard the posted host, and reconstruct with the address
the HTTP request actually came from (``request.client.host``).
"""
from __future__ import annotations

import logging
import subprocess
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Iterator

log = logging.getLogger(__name__)


class AuthFileParseError(ValueError):
    """Raised when the posted auth file does not parse."""


@dataclass(frozen=True)
class AuthInfo:
    port: int
    pid: str
    secret: str


def parse_auth_file(contents: str) -> AuthInfo:
    """Parse the file emacs writes for its TCP server.

    Format (one line of header, one line of secret):
        <host>:<port> <pid>
        <secret>

    The host field is parsed but discarded; the caller substitutes
    the request's reachable address instead.
    """
    if not contents:
        raise AuthFileParseError("auth file is empty")
    lines = contents.splitlines()
    if len(lines) < 2:
        raise AuthFileParseError("auth file must have header + secret lines")
    header, secret = lines[0], lines[1].strip()
    parts = header.rsplit(" ", 1)
    if len(parts) != 2:
        raise AuthFileParseError("auth header must be 'host:port pid'")
    hostport, pid = parts
    host, sep, port_s = hostport.rpartition(":")
    if not sep or not host or not port_s.isdigit():
        raise AuthFileParseError("auth header must contain 'host:port'")
    port = int(port_s)
    if not 1 <= port <= 65535:
        raise AuthFileParseError(f"port out of range: {port}")
    if not secret:
        raise AuthFileParseError("auth secret is empty")
    return AuthInfo(port=port, pid=pid.strip(), secret=secret)


def _render_auth_file(host: str, info: AuthInfo) -> str:
    return f"{host}:{info.port} {info.pid}\n{info.secret}\n"


@contextmanager
def _auth_file(auth_contents: str, phone_host: str) -> Iterator[str]:
    info = parse_auth_file(auth_contents)
    rendered = _render_auth_file(phone_host, info)
    with tempfile.NamedTemporaryFile(mode="w", suffix=".server", delete=True) as f:
        f.write(rendered)
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

    Returns ``(ok, output_or_error)``.  ``ok`` is False if the auth
    file is unparseable, emacsclient exited non-zero, timed out, or
    could not be invoked.
    """
    try:
        with _auth_file(auth_contents, phone_host) as path:
            # `-q` suppresses emacsclient's "connected to remote socket
            # at <host>" success message — which (surprise) goes to
            # STDOUT, not stderr, and otherwise ends up prefixing the
            # elisp result we hand to the agent.  The eval_elisp tool
            # caller treats this stdout as the value, so without -q the
            # agent reads `"connected to remote socket at 1.2.3.4\\n3"`
            # and may echo the diagnostic in its reply.
            result = subprocess.run(
                [emacsclient, "-q", "-f", path, "-e", expr],
                capture_output=True,
                text=True,
                timeout=timeout,
            )
    except AuthFileParseError as e:
        return False, f"auth file: {e}"
    except subprocess.TimeoutExpired:
        return False, f"emacsclient timed out after {timeout}s"
    except FileNotFoundError:
        return False, f"emacsclient binary not found: {emacsclient}"
    except OSError as e:
        return False, str(e)
    if result.returncode == 0:
        return True, result.stdout.strip()
    return False, result.stderr.strip() or f"exit {result.returncode}"


def is_unreachable(output: str) -> bool:
    """Classify a `call_emacs` failure ``output`` (the str from a
    ``(False, output)`` return) as an infrastructure failure
    (phone/network/binary) vs. an elisp-level error.

    Lives here, next to `call_emacs`, because every shape it matches is
    produced by `call_emacs`'s own `except` branches + the
    empty-stderr `exit N` fallback + emacsclient's connect-time error
    prefix.  Both the eval_elisp tool and the config-apply path import
    it from here so the classification has one owner.  (A future
    refactor returns a typed kind from `call_emacs` directly — see
    roadmap; this is the intermediate step toward it.)
    """
    return (
        output.startswith("emacsclient:")
        or output.startswith("exit ")
        or output.startswith("[Errno ")
        or "timed out" in output
        or "auth file:" in output
        or "binary not found" in output
    )
