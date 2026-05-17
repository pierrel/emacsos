"""Unit tests for POST /chat.

call_emacs is patched — these tests never shell out.  Real-emacs
exercise lives in the end-to-end test (next PR).
"""
from __future__ import annotations

from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient

from emacsos_server.app import _escape_elisp_string, app

client = TestClient(app)


def _read_elisp_string(s: str) -> str:
    """Inverse of ``_escape_elisp_string``: decode an elisp string
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


def test_echoes_message_without_phone():
    response = client.post("/chat", json={"message": "hello"})
    assert response.status_code == 200
    body = response.json()
    assert body["text"] == "echo: hello"
    assert body["side_effect"] is None


def test_calls_emacs_when_phone_auth_present():
    """Back-channel runs as a BackgroundTask after the response.  The
    FastAPI TestClient runs background tasks synchronously between
    response send and return, so the mock is reachable here."""
    with patch(
        "emacsos_server.app.call_emacs", return_value=(True, "nil")
    ) as m:
        response = client.post(
            "/chat",
            json={
                "message": "hi",
                "phone": {"auth_file": "127.0.0.1:1234\nsecret\n"},
            },
        )

    assert response.status_code == 200
    body = response.json()
    assert body["text"] == "echo: hi"
    # New shape: side_effect describes the SCHEDULED back-channel
    # rather than the post-call result (the call hasn't necessarily
    # completed by the time we return; see the async back-channel
    # comment in app.py).
    assert body["side_effect"] is not None
    assert "back-channel" in body["side_effect"]

    auth_arg, host_arg, expr_arg = m.call_args.args[:3]
    assert auth_arg == "127.0.0.1:1234\nsecret\n"
    # TestClient's client.host is "testclient" by default.
    assert host_arg == "testclient"
    assert 'saw: hi' in expr_arg


def test_back_channel_scheduled_even_when_call_will_fail():
    """side_effect reflects the SCHEDULING decision, not the call
    outcome.  Failures inside the background task get logged but
    don't change the response (the response has already been sent
    by then).  Deliberate change from PR #5's sync semantics; see
    the BackgroundTasks comment in app.py."""
    with patch(
        "emacsos_server.app.call_emacs", return_value=(False, "no daemon")
    ):
        response = client.post(
            "/chat",
            json={"message": "hi", "phone": {"auth_file": "anything"}},
        )

    assert response.status_code == 200
    body = response.json()
    assert body["text"] == "echo: hi"
    # Scheduled even though the call will fail.
    assert body["side_effect"] is not None
    assert "back-channel" in body["side_effect"]


@pytest.mark.parametrize(
    "message",
    [
        "hello",
        'he said "hi"',  # quote
        "path\\to\\file",  # backslash
        'mixed "quotes" and \\ backslashes',  # both
        'evil" (delete-file "/tmp/x") "',  # the quote-injection vector
        "trailing \\",  # trailing backslash edge case
    ],
)
def test_escape_roundtrip(message):
    """Whatever message we get, the elisp form must read back as the
    original string -- so quotes AND backslashes are both faithfully
    escaped.  Direct unit test on _escape_elisp_string; the endpoint
    just composes it."""
    assert _read_elisp_string(_escape_elisp_string(message)) == message


def test_chat_uses_escape_function_on_message():
    """The endpoint must actually run user input through the escape
    function, not paste it raw into the elisp expression."""
    with patch(
        "emacsos_server.app.call_emacs", return_value=(True, "nil")
    ) as m:
        client.post(
            "/chat",
            json={
                "message": 'evil" (delete-file "/tmp/x") "',
                "phone": {"auth_file": "x"},
            },
        )

    expr = m.call_args.args[2]
    assert expr.startswith("(message ") and expr.endswith(")")
    literal = expr[len("(message ") : -1]
    # Round-trip yields the saw:-prefixed message; the dangerous
    # substring is contained inside the elisp string literal, not
    # adjacent to it.
    assert _read_elisp_string(literal) == 'saw: evil" (delete-file "/tmp/x") "'
