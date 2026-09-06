"""Unit tests for the phone driver.

Two concerns:
- ``parse_auth_file`` round-trips the format emacs writes and rejects
  anything it can't make sense of.
- ``call_emacs`` *never* uses the host the client posted; the address
  it writes into the temp file is always the caller-supplied
  ``phone_host`` (the IP of the incoming HTTP request).
"""
from __future__ import annotations

import subprocess
import shutil
import time
from unittest.mock import MagicMock, patch

import pytest

from emacsos_server.phone import (
    AuthFileParseError,
    AuthInfo,
    MAX_EXPRESSION_BYTES,
    call_emacs,
    parse_auth_file,
)


# --- parse_auth_file ---

def test_parse_happy_path():
    info = parse_auth_file("0.0.0.0:12345 4242\nthe-secret\n")
    assert info == AuthInfo(port=12345, pid="4242", secret="the-secret")


def test_parse_strips_trailing_whitespace_in_secret():
    info = parse_auth_file("0.0.0.0:12345 4242\nthe-secret   \n")
    assert info.secret == "the-secret"


def test_parse_rejects_empty():
    with pytest.raises(AuthFileParseError):
        parse_auth_file("")


def test_parse_rejects_header_only():
    with pytest.raises(AuthFileParseError):
        parse_auth_file("0.0.0.0:12345 4242")


def test_parse_rejects_missing_pid():
    with pytest.raises(AuthFileParseError):
        parse_auth_file("0.0.0.0:12345\nsecret\n")


def test_parse_rejects_non_numeric_port():
    with pytest.raises(AuthFileParseError):
        parse_auth_file("0.0.0.0:abc 4242\nsecret\n")


def test_parse_rejects_port_out_of_range():
    with pytest.raises(AuthFileParseError):
        parse_auth_file("0.0.0.0:70000 4242\nsecret\n")


def test_parse_rejects_empty_secret():
    with pytest.raises(AuthFileParseError):
        parse_auth_file("0.0.0.0:12345 4242\n\n")


# --- call_emacs ignores posted host, uses caller host ---

def test_uses_caller_host_not_posted_host():
    """A careless or malicious client could supply an auth file
    pointing at evil.example.com:6666; the driver must ignore that
    and use the address the HTTP request actually came from."""
    captured = {}

    def fake_run(cmd, **_kwargs):
        # cmd layout: [emacsclient, -q, -f, <auth path>, -e]
        with open(cmd[3]) as f:
            captured["auth"] = f.read()
        return MagicMock(returncode=0, stdout="ok\n", stderr="")

    with patch("subprocess.run", side_effect=fake_run):
        ok, _out = call_emacs(
            auth_contents="evil.example.com:6666 4242\nsecret\n",
            phone_host="10.0.0.42",
            expr='(message "x")',
        )

    assert ok
    assert "evil.example.com" not in captured["auth"]
    # Posted port + pid + secret are kept; only the host changes.
    assert captured["auth"].startswith("10.0.0.42:6666 4242\n")
    assert "secret" in captured["auth"]


# --- failure modes ---

def test_returns_failure_on_unparseable_auth():
    """Unparseable auth must short-circuit; emacsclient must not run."""
    with patch("subprocess.run") as m:
        ok, err = call_emacs("garbage", "1.2.3.4", "(foo)")
    assert not ok
    assert "auth file" in err
    m.assert_not_called()


def test_passes_expr_on_stdin_and_auth_path_to_emacsclient():
    captured = {}

    def fake_run(cmd, **kwargs):
        captured["cmd"] = cmd
        captured["input"] = kwargs["input"]
        captured["encoding"] = kwargs["encoding"]
        return MagicMock(returncode=0, stdout="", stderr="")

    with patch("subprocess.run", side_effect=fake_run):
        call_emacs(
            "0.0.0.0:1234 1\nsecret\n",
            "1.2.3.4",
            '(message "hi")',
            emacsclient="ec",
        )

    # `-q` first to suppress emacsclient's "connected to remote socket"
    # stdout chatter so the agent's tool result is just the elisp value.
    # See `phone.call_emacs` comment.
    assert captured["cmd"][0] == "ec"
    assert captured["cmd"][1] == "-q"
    assert captured["cmd"][2] == "-f"
    assert captured["cmd"][4] == "-e"
    assert len(captured["cmd"]) == 5
    assert captured["input"] == '(message "hi")\n'
    assert captured["encoding"] == "utf-8"
    assert '(message "hi")' not in captured["cmd"]


def test_rejects_oversized_expression_before_starting_emacsclient():
    with patch("subprocess.run") as run:
        ok, error = call_emacs(
            "0.0.0.0:1234 1\nsecret\n",
            "1.2.3.4",
            "x" * (MAX_EXPRESSION_BYTES + 1),
        )
    assert not ok
    assert error == (
        f"elisp expression is {MAX_EXPRESSION_BYTES + 1} bytes; "
        f"max {MAX_EXPRESSION_BYTES}"
    )
    run.assert_not_called()


def test_returns_failure_on_nonzero_exit():
    with patch(
        "subprocess.run",
        return_value=MagicMock(returncode=1, stdout="", stderr="boom"),
    ):
        ok, err = call_emacs(
            "0.0.0.0:1234 1\nsecret\n", "1.2.3.4", "(foo)"
        )
    assert not ok
    assert "boom" in err


def test_returns_failure_on_timeout():
    with patch(
        "subprocess.run",
        side_effect=subprocess.TimeoutExpired(cmd="emacsclient", timeout=5.0),
    ):
        ok, err = call_emacs(
            "0.0.0.0:1234 1\nsecret\n", "1.2.3.4", "(foo)", timeout=5.0
        )
    assert not ok
    assert "timed out" in err.lower()


def test_returns_failure_when_binary_missing():
    with patch("subprocess.run", side_effect=FileNotFoundError()):
        ok, err = call_emacs(
            "0.0.0.0:1234 1\nsecret\n",
            "1.2.3.4",
            "(foo)",
            emacsclient="nope",
        )
    assert not ok
    assert "not found" in err


@pytest.mark.skipif(
    not shutil.which("emacs") or not shutil.which("emacsclient"),
    reason="Emacs client/server integration binaries unavailable",
)
def test_expression_on_stdin_reaches_real_tcp_emacs_server(tmp_path):
    """Pin emacsclient's surprising no-argument `-e` stdin contract."""
    tmp_path.chmod(0o700)
    auth_path = tmp_path / "stdin-test"
    expression = (
        "(progn (require 'server) "
        "(setq server-use-tcp t server-host \"127.0.0.1\" "
        f"server-auth-dir {str(tmp_path)!r} server-name \"stdin-test\") "
        "(server-start) (while t (accept-process-output nil 0.1)))"
    )
    # Python repr uses single quotes, which are not Lisp strings.
    expression = expression.replace(repr(str(tmp_path)),
                                    '"' + str(tmp_path).replace('"', '\\"') + '"')
    server = subprocess.Popen(
        ["emacs", "-Q", "--batch", "--eval", expression],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.monotonic() + 5
        while not auth_path.exists() and time.monotonic() < deadline:
            if server.poll() is not None:
                pytest.fail("test Emacs server exited before writing its auth file")
            time.sleep(0.05)
        assert auth_path.exists()
        ok, output = call_emacs(
            auth_path.read_text(), "127.0.0.1", "(+ 20 22)", timeout=2
        )
        assert ok
        assert output == "42"
    finally:
        server.terminate()
        server.wait(timeout=5)


# --- is_unreachable classifier ---

def test_is_unreachable_matches_infra_failures():
    from emacsos_server.phone import is_unreachable
    assert is_unreachable("emacsclient: connect: Connection refused")
    assert is_unreachable("emacsclient timed out after 15.0s")
    assert is_unreachable("emacsclient binary not found: emacsclient")
    assert is_unreachable("auth file: must have header + secret lines")
    assert is_unreachable("[Errno 24] Too many open files")
    assert is_unreachable("exit 1")


def test_is_unreachable_false_for_elisp_errors():
    from emacsos_server.phone import is_unreachable
    assert not is_unreachable("Symbol's value as variable is void: foo")
    assert not is_unreachable("3")
