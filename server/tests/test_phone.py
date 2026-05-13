"""Unit tests for the phone driver.  Subprocess is mocked."""
from __future__ import annotations

import subprocess
from unittest.mock import MagicMock, patch

from emacsos_server.phone import call_emacs


def test_substitutes_phone_host_into_auth_file():
    """The auth file emacs writes contains 0.0.0.0; the driver must
    replace it with the IP that the phone reached the server from,
    otherwise emacsclient connects to nothing."""
    captured = {}

    def fake_run(cmd, **kwargs):
        with open(cmd[2]) as f:
            captured["auth_content"] = f.read()
        return MagicMock(returncode=0, stdout="ok\n", stderr="")

    with patch("subprocess.run", side_effect=fake_run):
        ok, _out = call_emacs(
            auth_contents="0.0.0.0:1234\nsecret\n",
            phone_host="192.168.1.42",
            expr='(message "hi")',
        )

    assert ok
    assert captured["auth_content"] == "192.168.1.42:1234\nsecret\n"


def test_passes_expr_and_auth_path_to_emacsclient():
    captured = {}

    def fake_run(cmd, **kwargs):
        captured["cmd"] = cmd
        return MagicMock(returncode=0, stdout="", stderr="")

    with patch("subprocess.run", side_effect=fake_run):
        call_emacs("auth", "1.2.3.4", '(message "hi")', emacsclient="ec")

    assert captured["cmd"][0] == "ec"
    assert captured["cmd"][1] == "-f"
    assert captured["cmd"][3] == "-e"
    assert captured["cmd"][4] == '(message "hi")'


def test_returns_failure_on_nonzero_exit():
    with patch(
        "subprocess.run",
        return_value=MagicMock(returncode=1, stdout="", stderr="boom"),
    ):
        ok, err = call_emacs("auth", "1.2.3.4", "(foo)")

    assert not ok
    assert "boom" in err


def test_returns_failure_on_timeout():
    with patch(
        "subprocess.run",
        side_effect=subprocess.TimeoutExpired(cmd="emacsclient", timeout=5.0),
    ):
        ok, err = call_emacs("auth", "1.2.3.4", "(foo)", timeout=5.0)

    assert not ok
    assert "timed out" in err.lower()


def test_returns_failure_when_binary_missing():
    with patch("subprocess.run", side_effect=FileNotFoundError()):
        ok, err = call_emacs("auth", "1.2.3.4", "(foo)", emacsclient="nope")

    assert not ok
    assert "not found" in err
