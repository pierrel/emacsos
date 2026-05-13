"""Unit tests for POST /chat.

call_emacs is patched — these tests never shell out.  Real-emacs
exercise lives in the end-to-end test (next PR).
"""
from __future__ import annotations

from unittest.mock import patch

from fastapi.testclient import TestClient

from emacsos_server.app import app

client = TestClient(app)


def test_echoes_message_without_phone():
    response = client.post("/chat", json={"message": "hello"})
    assert response.status_code == 200
    body = response.json()
    assert body["text"] == "echo: hello"
    assert body["side_effect"] is None


def test_calls_emacs_when_phone_auth_present():
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
    assert body["side_effect"] is not None
    assert "phone" in body["side_effect"]

    auth_arg, host_arg, expr_arg = m.call_args.args[:3]
    assert auth_arg == "127.0.0.1:1234\nsecret\n"
    # TestClient's client.host is "testclient" by default.
    assert host_arg == "testclient"
    assert 'saw: hi' in expr_arg


def test_side_effect_null_when_emacsclient_fails():
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
    assert body["side_effect"] is None


def test_escapes_message_contents_into_elisp_string():
    """A message containing quotes or backslashes must not break out
    of the elisp string literal we build for (message ...).  Otherwise
    a hostile or careless message could inject arbitrary elisp."""
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
    assert expr.startswith("(message ")
    # The escaped form contains no unescaped quote that closes the literal
    # before the very last character before the closing paren.
    inner = expr[len("(message ") : -1]
    assert inner.startswith('"') and inner.endswith('"')
    # Every internal " is escaped
    body_chars = inner[1:-1]
    for i, ch in enumerate(body_chars):
        if ch == '"':
            assert i > 0 and body_chars[i - 1] == "\\"
