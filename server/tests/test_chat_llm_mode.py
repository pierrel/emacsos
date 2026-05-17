"""Tests for the LLM-enabled mode of POST /chat.

Mocks `_run_agent` so we never hit a real model.  The echo-mode
tests live in test_chat_endpoint.py and cover the default-off path.
Together they pin both branches of the LLM-disabled gate.
"""
from __future__ import annotations

import os
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient


@pytest.fixture(autouse=True)
def _reset_thread_singleton():
    """Clear the module-level Thread between tests so each one
    constructs/skips construction freshly."""
    import emacsos_server.app as app_mod

    app_mod._THREAD = None
    yield
    app_mod._THREAD = None


@pytest.fixture
def llm_on(monkeypatch):
    """Set env so `_llm_enabled()` returns True."""
    monkeypatch.setenv("ASSIST_MODEL_URL", "http://fake.local/v1")
    monkeypatch.delenv("EMACSOS_LLM_DISABLED", raising=False)


@pytest.fixture
def llm_off(monkeypatch):
    """Set env so `_llm_enabled()` returns False (the existing echo
    path)."""
    monkeypatch.delenv("ASSIST_MODEL_URL", raising=False)
    monkeypatch.delenv("EMACSOS_LLM_DISABLED", raising=False)


@pytest.fixture
def client():
    from emacsos_server.app import app
    return TestClient(app)


# --- gate semantics ----------------------------------------------------------


def test_llm_enabled_false_when_url_unset(llm_off):
    from emacsos_server.app import _llm_enabled
    assert _llm_enabled() is False


def test_llm_enabled_false_when_disabled_flag_set(llm_on, monkeypatch):
    from emacsos_server.app import _llm_enabled
    monkeypatch.setenv("EMACSOS_LLM_DISABLED", "1")
    assert _llm_enabled() is False


@pytest.mark.parametrize("val", ["1", "true", "True", "yes", "on"])
def test_disabled_flag_truthy_values(llm_on, monkeypatch, val):
    from emacsos_server.app import _llm_enabled
    monkeypatch.setenv("EMACSOS_LLM_DISABLED", val)
    assert _llm_enabled() is False


def test_disabled_flag_falsy_keeps_llm_on(llm_on, monkeypatch):
    from emacsos_server.app import _llm_enabled
    monkeypatch.setenv("EMACSOS_LLM_DISABLED", "0")
    assert _llm_enabled() is True


def test_llm_enabled_true_when_url_set_and_no_disable(llm_on):
    from emacsos_server.app import _llm_enabled
    assert _llm_enabled() is True


# --- /chat LLM path ----------------------------------------------------------


def test_chat_calls_agent_in_llm_mode(llm_on, client):
    with patch("emacsos_server.app._run_agent", return_value="Hi from the agent!"):
        r = client.post("/chat", json={"message": "hello"})
    assert r.status_code == 200
    body = r.json()
    assert body["text"] == "Hi from the agent!"
    assert body["side_effect"] is None  # no phone in this request


def test_chat_falls_back_to_echo_when_llm_off(llm_off, client):
    # _run_agent must not be called when LLM is off.
    with patch("emacsos_server.app._run_agent") as agent:
        r = client.post("/chat", json={"message": "hello"})
    assert r.status_code == 200
    assert r.json()["text"] == "echo: hello"
    agent.assert_not_called()


def test_chat_flash_text_in_llm_mode(llm_on, client):
    """In LLM mode, the phone flash is `agent: <prefix>`, not `saw: <msg>`."""
    with patch("emacsos_server.app._run_agent", return_value="42 is the answer"), \
         patch("emacsos_server.app.call_emacs", return_value=(True, "nil")) as emc:
        r = client.post("/chat", json={
            "message": "what's the meaning of life?",
            "phone": {"auth_file": "x"},
        })
    assert r.status_code == 200
    expr = emc.call_args.args[2]
    assert 'agent: 42 is the answer' in expr
    assert 'saw:' not in expr


def test_chat_flash_text_in_echo_mode(llm_off, client):
    """In echo mode, the flash is the unchanged `saw: <msg>`."""
    with patch("emacsos_server.app.call_emacs", return_value=(True, "nil")) as emc:
        r = client.post("/chat", json={
            "message": "hi",
            "phone": {"auth_file": "x"},
        })
    expr = emc.call_args.args[2]
    assert 'saw: hi' in expr
    assert 'agent:' not in expr


def test_chat_flash_truncates_long_response(llm_on, client):
    long = "x" * 200
    with patch("emacsos_server.app._run_agent", return_value=long), \
         patch("emacsos_server.app.call_emacs", return_value=(True, "nil")) as emc:
        client.post("/chat", json={
            "message": "hi",
            "phone": {"auth_file": "x"},
        })
    expr = emc.call_args.args[2]
    # Cap is on the REPLY portion (60 chars); the "agent: " prefix is
    # always shown in full.  So the truncated reply ends with "..." and
    # the full 200 x's must NOT appear.
    assert "..." in expr
    assert "x" * 200 not in expr


def test_chat_flash_collapses_newlines(llm_on, client):
    with patch("emacsos_server.app._run_agent", return_value="line one\nline two"), \
         patch("emacsos_server.app.call_emacs", return_value=(True, "nil")) as emc:
        client.post("/chat", json={
            "message": "hi",
            "phone": {"auth_file": "x"},
        })
    expr = emc.call_args.args[2]
    # The flash text shouldn't have literal newlines (the elisp string
    # literal would survive them but the phone minibuffer can't show
    # multi-line content).  _flash_text replaces them with spaces.
    assert "line one line two" in expr


# --- error handling ----------------------------------------------------------


def test_agent_runtime_error_returns_error_text(llm_on, client):
    from emacsos_server.app import _agent_text

    def boom(_msg):
        raise RuntimeError("ASSIST_MODEL_URL not set or invalid")
    with patch("emacsos_server.app._run_agent", side_effect=boom):
        text = _agent_text("hi")
    assert text.startswith("[error:")
    assert "ASSIST_MODEL_URL" in text


def test_agent_timeout_returns_specific_error(llm_on, client):
    from concurrent.futures import TimeoutError as FutureTimeoutError

    with patch("emacsos_server.app._run_agent", side_effect=FutureTimeoutError):
        from emacsos_server.app import _agent_text
        text = _agent_text("hi")
    assert "[error: agent timed out after" in text


def test_agent_generic_exception_caught(llm_on, client):
    with patch("emacsos_server.app._run_agent",
               side_effect=ValueError("something else broke")):
        from emacsos_server.app import _agent_text
        text = _agent_text("hi")
    assert text.startswith("[error:")
    assert "ValueError" in text
    assert "something else broke" in text


def test_chat_returns_200_even_on_agent_error(llm_on, client):
    """Errors are surfaced as `bot> [error: ...]` text, not HTTP 500."""
    with patch("emacsos_server.app._run_agent",
               side_effect=RuntimeError("nope")):
        r = client.post("/chat", json={"message": "hi"})
    assert r.status_code == 200
    assert r.json()["text"].startswith("[error:")
