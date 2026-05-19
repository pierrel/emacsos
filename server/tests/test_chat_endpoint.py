"""Tests for the streaming POST /chat endpoint.

The endpoint returns an NDJSON event stream rather than a JSON object.
Tests mock `_start_stream_iter` (which builds the per-request Thread
and starts its `stream_message` iterator) so we never hit a real model
and drive the stream through FastAPI's TestClient, collecting events
from the response body.

Every test sends a `phone.auth_file` in the request body so
`_stream_turn`'s phone-context guard is satisfied — see the dedicated
`test_missing_phone_yields_error_event` for the negative case.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client():
    from emacsos_server.app import app
    return TestClient(app)


# Minimal but parseable auth file: `host:port pid\nsecret\n`.  Host gets
# discarded server-side (replaced with request.client.host) — see phone.py.
_FAKE_AUTH = "0.0.0.0:1234 555\nsecret\n"


def _chat_body(message: str = "hi") -> dict:
    return {"message": message, "phone": {"auth_file": _FAKE_AUTH}}


@dataclass
class _FakeAIMessageChunk:
    content: str = ""
    tool_calls: list[dict] | None = None

    def __post_init__(self):
        if self.tool_calls is None:
            self.tool_calls = []


def _collect_events(response) -> list[dict]:
    """Drain an NDJSON streaming response into a list of parsed events."""
    events = []
    for raw in response.iter_lines():
        if not raw:
            continue
        events.append(json.loads(raw))
    return events


# --- happy path -------------------------------------------------------------

def test_streams_start_token_end_for_simple_response(client):
    scripted = [
        ("messages", (_FakeAIMessageChunk(content="Hello!"), {})),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=iter(scripted)):
        with client.stream("POST", "/chat", json=_chat_body()) as r:
            events = _collect_events(r)

    types = [e["type"] for e in events]
    assert types[0] == "start"
    assert types[-1] == "end"
    tokens = [e for e in events if e["type"] == "token"]
    assert [t["text"] for t in tokens] == ["Hello!"]
    end = [e for e in events if e["type"] == "end"][-1]
    assert end["text"] == "Hello!"


def test_streams_multiple_tokens_concatenate_into_end_text(client):
    scripted = [
        ("messages", (_FakeAIMessageChunk(content="The "), {})),
        ("messages", (_FakeAIMessageChunk(content="answer "), {})),
        ("messages", (_FakeAIMessageChunk(content="is 42."), {})),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=iter(scripted)):
        with client.stream("POST", "/chat", json=_chat_body("q")) as r:
            events = _collect_events(r)

    tokens = [e["text"] for e in events if e["type"] == "token"]
    assert tokens == ["The ", "answer ", "is 42."]
    end = [e for e in events if e["type"] == "end"][-1]
    assert end["text"] == "The answer is 42."


def test_empty_content_chunks_dont_produce_token_events(client):
    """Spike showed warmup/cleanup chunks have empty content; no noise."""
    scripted = [
        ("messages", (_FakeAIMessageChunk(content=""), {})),
        ("messages", (_FakeAIMessageChunk(content="x"), {})),
        ("messages", (_FakeAIMessageChunk(content=""), {})),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=iter(scripted)):
        with client.stream("POST", "/chat", json=_chat_body("q")) as r:
            events = _collect_events(r)

    tokens = [e for e in events if e["type"] == "token"]
    assert len(tokens) == 1
    assert tokens[0]["text"] == "x"


# --- tool-call status -------------------------------------------------------

def test_tool_call_emits_calling_status(client):
    """v1 status format: `calling <tool_name>`.  Args-in-status is
    deferred to v2 — real streams populate `args` via subsequent
    `tool_call_chunks`, not on the first chunk we see, so the
    truncated-args UX requires `tool_call_chunks` accumulation."""
    scripted = [
        ("messages", (
            _FakeAIMessageChunk(tool_calls=[{"name": "task", "id": "tc-1"}]),
            {},
        )),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=iter(scripted)):
        with client.stream("POST", "/chat", json=_chat_body("q")) as r:
            events = _collect_events(r)

    statuses = [e for e in events if e["type"] == "status"]
    assert len(statuses) == 1
    assert statuses[0]["text"] == "calling task"


def test_repeated_tool_call_chunks_dont_repeat_status(client):
    scripted = [
        ("messages", (
            _FakeAIMessageChunk(tool_calls=[{"name": "task", "id": "tc-1"}]),
            {},
        )),
        ("messages", (_FakeAIMessageChunk(tool_calls=[]), {})),
        ("messages", (_FakeAIMessageChunk(tool_calls=[]), {})),
        ("messages", (
            _FakeAIMessageChunk(tool_calls=[{"name": "search", "id": "tc-2"}]),
            {},
        )),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=iter(scripted)):
        with client.stream("POST", "/chat", json=_chat_body("q")) as r:
            events = _collect_events(r)

    statuses = [e["text"] for e in events if e["type"] == "status"]
    assert statuses == ["calling task", "calling search"]


def test_update_to_status_surfaces_named_node(client):
    scripted = [
        ("updates", {"task": {"messages": []}}),
        ("updates", {"JsonValidationMiddleware.before_model": None}),  # dropped
        ("updates", {"research-agent": {}}),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=iter(scripted)):
        with client.stream("POST", "/chat", json=_chat_body("q")) as r:
            events = _collect_events(r)

    statuses = [e["text"] for e in events if e["type"] == "status"]
    assert statuses == ["running task", "running research-agent"]


# --- error path -------------------------------------------------------------

def test_construction_error_yields_error_event(client):
    def boom(_msg, _ctx):
        raise RuntimeError("ASSIST_MODEL_URL not set")
    with patch("emacsos_server.app._start_stream_iter", side_effect=boom):
        with client.stream("POST", "/chat", json=_chat_body("q")) as r:
            events = _collect_events(r)

    errors = [e for e in events if e["type"] == "error"]
    assert len(errors) == 1
    assert "ASSIST_MODEL_URL" in errors[0]["reason"]
    assert not [e for e in events if e["type"] == "end"]


def test_mid_stream_exception_yields_error_event_with_partial(client):
    def gen():
        yield ("messages", (_FakeAIMessageChunk(content="partial"), {}))
        raise ValueError("model died mid-stream")
    with patch("emacsos_server.app._start_stream_iter",
               return_value=gen()):
        with client.stream("POST", "/chat", json=_chat_body("q")) as r:
            events = _collect_events(r)

    tokens = [e["text"] for e in events if e["type"] == "token"]
    errors = [e for e in events if e["type"] == "error"]
    assert tokens == ["partial"]
    assert len(errors) == 1
    assert "ValueError" in errors[0]["reason"]
    assert errors[0]["after_tokens"] == len("partial")


def test_missing_phone_yields_error_event(client):
    """The channel needs phone context; a request without `phone` is
    rejected with a clean error event rather than starting an agent
    that would have nowhere to invoke eval_elisp."""
    with client.stream("POST", "/chat", json={"message": "hi"}) as r:
        events = _collect_events(r)

    errors = [e for e in events if e["type"] == "error"]
    assert len(errors) == 1
    assert "phone" in errors[0]["reason"].lower()
    assert not [e for e in events if e["type"] == "end"]


# --- response shape --------------------------------------------------------

def test_content_type_is_ndjson(client):
    scripted = [("messages", (_FakeAIMessageChunk(content="x"), {}))]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=iter(scripted)):
        with client.stream("POST", "/chat", json=_chat_body("q")) as r:
            assert r.headers["content-type"].startswith("application/x-ndjson")


def test_start_event_carries_stream_id_and_ts(client):
    scripted = [("messages", (_FakeAIMessageChunk(content="x"), {}))]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=iter(scripted)):
        with client.stream("POST", "/chat", json=_chat_body("q")) as r:
            events = _collect_events(r)
    start = events[0]
    assert start["type"] == "start"
    assert isinstance(start["stream_id"], str) and len(start["stream_id"]) >= 8
    assert isinstance(start["ts"], (int, float))


# --- _start_stream_iter wires phone_ctx into Thread -------------------------

def test_start_stream_iter_passes_phone_ctx_to_build_thread(client):
    """The /chat handler must pass the parsed PhoneContext through to
    `_start_stream_iter` so the Thread is built with the right
    `extra_config`.  Mocks at the build-thread boundary and asserts
    on the captured PhoneContext."""
    import emacsos_server.app as app_mod
    from emacsos_server.channel import PhoneContext

    captured = {}

    def fake_build(phone_ctx):
        captured["ctx"] = phone_ctx
        # Return a thread-like object with a no-op stream_message.
        class _T:
            def stream_message(self, _msg):
                return iter([])
        return _T()

    with patch.object(app_mod, "_build_thread", side_effect=fake_build):
        with client.stream("POST", "/chat", json=_chat_body("q")) as r:
            _collect_events(r)

    ctx = captured["ctx"]
    assert isinstance(ctx, PhoneContext)
    assert ctx.auth_contents == _FAKE_AUTH
    # TestClient sets client.host to "testclient" by default.
    assert ctx.phone_host == "testclient"
