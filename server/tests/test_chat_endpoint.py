"""Tests for POST /chat.

Mocks `_run_turn` so we never hit a real model.  Covers:
- agent path: response shape, back-channel scheduling
- error mapping: timeout, RuntimeError variants, generic Exception
- elisp escaping (pure unit) — survives quote / backslash injection
- flash text format: prefix, newline collapse, 60-char cap
"""
from __future__ import annotations

from concurrent.futures import TimeoutError as FutureTimeoutError
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient

from emacsos_server.app import _escape_elisp_string, app

client = TestClient(app)


@pytest.fixture(autouse=True)
def _reset_thread_singleton():
    """Clear the module-level Thread between tests."""
    import emacsos_server.app as app_mod
    app_mod._THREAD = None
    yield
    app_mod._THREAD = None


def _read_elisp_string(s: str) -> str:
    """Inverse of `_escape_elisp_string`: decode an elisp string
    literal so we can verify the escape function round-trips."""
    assert s.startswith('"') and s.endswith('"'), s
    body = s[1:-1]
    out: list[str] = []
    i = 0
    while i < len(body):
        if body[i] == "\\" and i + 1 < len(body):
            out.append(body[i + 1])
            i += 2
        else:
            out.append(body[i])
            i += 1
    return "".join(out)


# --- happy path -------------------------------------------------------------

def test_returns_agent_text():
    with patch("emacsos_server.app._run_turn", return_value="Hi from the agent!"):
        r = client.post("/chat", json={"message": "hello"})
    assert r.status_code == 200
    body = r.json()
    assert body["text"] == "Hi from the agent!"
    assert body["side_effect"] is None  # no phone in this request


def test_back_channel_scheduled_when_phone_auth_present():
    """Back-channel runs as a BackgroundTask after the response.
    FastAPI TestClient runs background tasks synchronously between
    response send and return, so the mock is reachable here."""
    with patch("emacsos_server.app._run_turn", return_value="hi"), \
         patch("emacsos_server.app.call_emacs", return_value=(True, "nil")) as emc:
        response = client.post(
            "/chat",
            json={
                "message": "hi",
                "phone": {"auth_file": "127.0.0.1:1234\nsecret\n"},
            },
        )

    assert response.status_code == 200
    body = response.json()
    assert body["text"] == "hi"
    # side_effect describes the SCHEDULED back-channel, not the call
    # outcome (the call hasn't necessarily completed when we return).
    assert body["side_effect"] is not None
    assert "back-channel" in body["side_effect"]

    auth_arg, host_arg, expr_arg = emc.call_args.args[:3]
    assert auth_arg == "127.0.0.1:1234\nsecret\n"
    # TestClient's client.host is "testclient" by default.
    assert host_arg == "testclient"
    assert "agent: hi" in expr_arg


def test_back_channel_scheduled_even_when_call_will_fail():
    """side_effect reflects SCHEDULING, not the call outcome.  Errors
    inside the background task get logged but don't change the
    response (already sent by then)."""
    with patch("emacsos_server.app._run_turn", return_value="hi"), \
         patch("emacsos_server.app.call_emacs", return_value=(False, "no daemon")):
        response = client.post(
            "/chat",
            json={"message": "hi", "phone": {"auth_file": "x"}},
        )
    assert response.status_code == 200
    body = response.json()
    assert body["text"] == "hi"
    assert body["side_effect"] is not None
    assert "back-channel" in body["side_effect"]


# --- flash text format ------------------------------------------------------

def test_flash_text_uses_agent_prefix():
    with patch("emacsos_server.app._run_turn", return_value="42 is the answer"), \
         patch("emacsos_server.app.call_emacs", return_value=(True, "nil")) as emc:
        client.post("/chat", json={
            "message": "what's the meaning of life?",
            "phone": {"auth_file": "x"},
        })
    expr = emc.call_args.args[2]
    assert "agent: 42 is the answer" in expr


def test_flash_text_truncates_long_response():
    long = "x" * 200
    with patch("emacsos_server.app._run_turn", return_value=long), \
         patch("emacsos_server.app.call_emacs", return_value=(True, "nil")) as emc:
        client.post("/chat", json={
            "message": "hi", "phone": {"auth_file": "x"},
        })
    expr = emc.call_args.args[2]
    # Cap is on the REPLY portion (60 chars); the "agent: " prefix
    # is always shown in full.  Truncated reply ends with "...".
    assert "..." in expr
    assert "x" * 200 not in expr


def test_flash_text_collapses_newlines():
    with patch("emacsos_server.app._run_turn", return_value="line one\nline two"), \
         patch("emacsos_server.app.call_emacs", return_value=(True, "nil")) as emc:
        client.post("/chat", json={
            "message": "hi", "phone": {"auth_file": "x"},
        })
    expr = emc.call_args.args[2]
    assert "line one line two" in expr


# --- error mapping ----------------------------------------------------------

def test_timeout_returns_specific_error_and_resets_thread():
    """On timeout, _agent_text returns the specific error string AND
    resets the singleton so the next call constructs a fresh Thread."""
    import emacsos_server.app as app_mod

    with patch("emacsos_server.app._run_turn", side_effect=FutureTimeoutError):
        with patch("emacsos_server.app._reset_thread") as reset:
            text = app_mod._agent_text("hi")
    assert "[error: agent timed out after" in text
    reset.assert_called_once()


def test_runtime_error_missing_url():
    import emacsos_server.app as app_mod
    err = RuntimeError("ASSIST_MODEL_URL not set or invalid")
    with patch("emacsos_server.app._run_turn", side_effect=err):
        text = app_mod._agent_text("hi")
    assert text.startswith("[error: assist model not configured")
    assert "ASSIST_MODEL_URL" in text


def test_runtime_error_model_unavailable():
    """RuntimeError mentioning 'model' but NOT the env var gets the
    'model unavailable' wording (liveness / probe failure)."""
    import emacsos_server.app as app_mod
    err = RuntimeError("Could not reach model at http://...; HTTP 502")
    with patch("emacsos_server.app._run_turn", side_effect=err):
        text = app_mod._agent_text("hi")
    assert text.startswith("[error: assist model unavailable")


def test_generic_exception_caught():
    import emacsos_server.app as app_mod
    with patch("emacsos_server.app._run_turn",
               side_effect=ValueError("something else broke")):
        text = app_mod._agent_text("hi")
    assert text.startswith("[error:")
    assert "ValueError" in text
    assert "something else broke" in text


def test_chat_returns_200_even_on_agent_error():
    """Errors are surfaced as `bot> [error: ...]` text, not HTTP 500."""
    with patch("emacsos_server.app._run_turn", side_effect=RuntimeError("nope")):
        r = client.post("/chat", json={"message": "hi"})
    assert r.status_code == 200
    assert r.json()["text"].startswith("[error:")


# --- thread singleton lifecycle --------------------------------------------

def test_reset_thread_clears_singleton():
    import emacsos_server.app as app_mod
    # Plant a fake non-None value, confirm reset clears it.
    class _FakeThread:
        thread_id = "fake-id"  # for the reset log line
    app_mod._THREAD = _FakeThread()
    app_mod._reset_thread()
    assert app_mod._THREAD is None


def test_get_thread_lazy_constructs():
    """First call constructs; second returns the same instance."""
    import emacsos_server.app as app_mod
    fake_thread = object()
    with patch("emacsos_server.app._build_thread", return_value=fake_thread) as build:
        a = app_mod._get_thread()
        b = app_mod._get_thread()
    assert a is fake_thread
    assert b is fake_thread
    build.assert_called_once()


# --- elisp escaping (pure unit) --------------------------------------------

@pytest.mark.parametrize(
    "message",
    [
        "hello",
        'he said "hi"',
        "path\\to\\file",
        'mixed "quotes" and \\ backslashes',
        'evil" (delete-file "/tmp/x") "',
        "trailing \\",
    ],
)
def test_escape_roundtrip(message):
    assert _read_elisp_string(_escape_elisp_string(message)) == message


def test_chat_uses_escape_function_on_message():
    """The endpoint runs the agent reply through the escape function
    when composing the back-channel flash, so injection in the reply
    can't escape the elisp string."""
    evil = 'evil" (delete-file "/tmp/x") "'
    with patch("emacsos_server.app._run_turn", return_value=evil), \
         patch("emacsos_server.app.call_emacs", return_value=(True, "nil")) as m:
        client.post("/chat", json={"message": "hi", "phone": {"auth_file": "x"}})

    expr = m.call_args.args[2]
    assert expr.startswith("(message ") and expr.endswith(")")
    literal = expr[len("(message ") : -1]
    # Round-trip yields the agent:-prefixed message; the dangerous
    # substring is contained inside the elisp string literal.
    assert _read_elisp_string(literal) == f"agent: {evil}"
