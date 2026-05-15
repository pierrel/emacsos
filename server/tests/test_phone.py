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
from unittest.mock import MagicMock, patch

import pytest

from emacsos_server.phone import (
    AuthFileParseError,
    AuthInfo,
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
        with open(cmd[2]) as f:
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


def test_passes_expr_and_auth_path_to_emacsclient():
    captured = {}

    def fake_run(cmd, **_kwargs):
        captured["cmd"] = cmd
        return MagicMock(returncode=0, stdout="", stderr="")

    with patch("subprocess.run", side_effect=fake_run):
        call_emacs(
            "0.0.0.0:1234 1\nsecret\n",
            "1.2.3.4",
            '(message "hi")',
            emacsclient="ec",
        )

    assert captured["cmd"][0] == "ec"
    assert captured["cmd"][1] == "-f"
    assert captured["cmd"][3] == "-e"
    assert captured["cmd"][4] == '(message "hi")'


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
