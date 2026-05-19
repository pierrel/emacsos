"""Tests for the streaming POST /chat endpoint.

The endpoint now returns an NDJSON event stream rather than a JSON
object.  Tests mock `Thread.stream_message` so we never hit a real
model and drive the stream through FastAPI's TestClient, collecting
events from the response body.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient


@pytest.fixture(autouse=True)
def _reset_thread_singleton():
    """Clear the module-level Thread between tests so the lazy
    _build_thread path is exercised cleanly each time."""
    import emacsos_server.app as app_mod
    app_mod._THREAD = None
    yield
    app_mod._THREAD = None


@pytest.fixture
def client():
    from emacsos_server.app import app
    return TestClient(app)


@dataclass
class _FakeAIMessageChunk:
    content: str = ""
    tool_calls: list[dict] | None = None

    def __post_init__(self):
        if self.tool_calls is None:
            self.tool_calls = []


def _collect_events(response) -> list[dict]:
    """Drain an NDJSON streaming response into a list of parsed
    event dicts."""
    events = []
    for raw in response.iter_lines():
        if not raw:
            continue
        events.append(json.loads(raw))
    return events


def _mock_iter(iterator):
    """Wrap an iterator as the (thread, iter) tuple `_start_stream_iter`
    now returns.  The fake thread object is only used as an identity
    handle for `_reset_thread_if`, so a plain `object()` is enough."""
    return object(), iterator


# --- happy path -------------------------------------------------------------

def test_streams_start_token_end_for_simple_response(client):
    """A simple message → start, one token, end."""
    scripted = [
        ("messages", (_FakeAIMessageChunk(content="Hello!"), {})),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=_mock_iter(iter(scripted))):
        with client.stream("POST", "/chat", json={"message": "hi"}) as r:
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
               return_value=_mock_iter(iter(scripted))):
        with client.stream("POST", "/chat", json={"message": "q"}) as r:
            events = _collect_events(r)

    tokens = [e["text"] for e in events if e["type"] == "token"]
    assert tokens == ["The ", "answer ", "is 42."]
    end = [e for e in events if e["type"] == "end"][-1]
    assert end["text"] == "The answer is 42."


def test_empty_content_chunks_dont_produce_token_events(client):
    """The spike showed warmup/cleanup chunks have empty content;
    they must not produce noise token events."""
    scripted = [
        ("messages", (_FakeAIMessageChunk(content=""), {})),
        ("messages", (_FakeAIMessageChunk(content="x"), {})),
        ("messages", (_FakeAIMessageChunk(content=""), {})),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=_mock_iter(iter(scripted))):
        with client.stream("POST", "/chat", json={"message": "q"}) as r:
            events = _collect_events(r)

    tokens = [e for e in events if e["type"] == "token"]
    assert len(tokens) == 1
    assert tokens[0]["text"] == "x"


# --- tool-call status -------------------------------------------------------

def test_tool_call_emits_status_event(client):
    scripted = [
        ("messages", (
            _FakeAIMessageChunk(tool_calls=[{"name": "task", "id": "tc-1"}]),
            {},
        )),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=_mock_iter(iter(scripted))):
        with client.stream("POST", "/chat", json={"message": "q"}) as r:
            events = _collect_events(r)

    statuses = [e for e in events if e["type"] == "status"]
    assert len(statuses) == 1
    assert statuses[0]["text"] == "calling task"


def test_repeated_tool_call_chunks_dont_repeat_status(client):
    """Same tc_id across many chunks (typical: continuations as
    args stream in) → only one status emitted."""
    scripted = [
        ("messages", (
            _FakeAIMessageChunk(tool_calls=[{"name": "task", "id": "tc-1"}]),
            {},
        )),
        # Continuations: args streaming in via tool_call_chunks;
        # tool_calls=[] on these.
        ("messages", (_FakeAIMessageChunk(tool_calls=[]), {})),
        ("messages", (_FakeAIMessageChunk(tool_calls=[]), {})),
        # Different tool, different id → another status.
        ("messages", (
            _FakeAIMessageChunk(tool_calls=[{"name": "search", "id": "tc-2"}]),
            {},
        )),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=_mock_iter(iter(scripted))):
        with client.stream("POST", "/chat", json={"message": "q"}) as r:
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
               return_value=_mock_iter(iter(scripted))):
        with client.stream("POST", "/chat", json={"message": "q"}) as r:
            events = _collect_events(r)

    statuses = [e["text"] for e in events if e["type"] == "status"]
    assert statuses == ["running task", "running research-agent"]


# --- error path -------------------------------------------------------------

def test_construction_error_yields_error_event(client):
    """When the iterator construction itself raises (e.g., model
    misconfig), the error event maps the reason."""
    def boom(_msg):
        raise RuntimeError("ASSIST_MODEL_URL not set")
    with patch("emacsos_server.app._start_stream_iter", side_effect=boom):
        with client.stream("POST", "/chat", json={"message": "q"}) as r:
            events = _collect_events(r)

    errors = [e for e in events if e["type"] == "error"]
    assert len(errors) == 1
    assert "ASSIST_MODEL_URL" in errors[0]["reason"]
    # No `end` after an error.
    assert not [e for e in events if e["type"] == "end"]


def test_mid_stream_exception_yields_error_event_with_partial(client):
    def gen():
        yield ("messages", (_FakeAIMessageChunk(content="partial"), {}))
        raise ValueError("model died mid-stream")
    with patch("emacsos_server.app._start_stream_iter",
               return_value=_mock_iter(gen())):
        with client.stream("POST", "/chat", json={"message": "q"}) as r:
            events = _collect_events(r)

    tokens = [e["text"] for e in events if e["type"] == "token"]
    errors = [e for e in events if e["type"] == "error"]
    assert tokens == ["partial"]
    assert len(errors) == 1
    assert "ValueError" in errors[0]["reason"]
    # after_tokens reports the partial-content byte count for the
    # client's "we got this far" rendering.
    assert errors[0]["after_tokens"] == len("partial")


# --- thread singleton lifecycle --------------------------------------------

def test_thread_reset_after_stream_ends(client):
    """Stream end must reset the singleton so the next request
    builds a fresh Thread.  Verified by asserting _THREAD is None
    after the stream completes."""
    import emacsos_server.app as app_mod
    scripted = [("messages", (_FakeAIMessageChunk(content="x"), {}))]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=_mock_iter(iter(scripted))):
        with client.stream("POST", "/chat", json={"message": "q"}) as r:
            _collect_events(r)
    assert app_mod._THREAD is None


def test_thread_reset_after_error(client):
    import emacsos_server.app as app_mod
    with patch("emacsos_server.app._start_stream_iter",
               side_effect=RuntimeError("boom")):
        with client.stream("POST", "/chat", json={"message": "q"}) as r:
            _collect_events(r)
    assert app_mod._THREAD is None


# --- response shape --------------------------------------------------------

def test_content_type_is_ndjson(client):
    scripted = [("messages", (_FakeAIMessageChunk(content="x"), {}))]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=_mock_iter(iter(scripted))):
        with client.stream("POST", "/chat", json={"message": "q"}) as r:
            assert r.headers["content-type"].startswith("application/x-ndjson")


def test_start_event_carries_stream_id_and_ts(client):
    scripted = [("messages", (_FakeAIMessageChunk(content="x"), {}))]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=_mock_iter(iter(scripted))):
        with client.stream("POST", "/chat", json={"message": "q"}) as r:
            events = _collect_events(r)
    start = events[0]
    assert start["type"] == "start"
    assert isinstance(start["stream_id"], str) and len(start["stream_id"]) >= 8
    assert isinstance(start["ts"], (int, float))


# --- thread singleton tests (independent of /chat) -------------------------

def test_get_thread_lazy_constructs():
    import emacsos_server.app as app_mod
    fake_thread = object()
    with patch("emacsos_server.app._build_thread", return_value=fake_thread) as build:
        a = app_mod._get_thread()
        b = app_mod._get_thread()
    assert a is fake_thread
    assert b is fake_thread
    build.assert_called_once()


def test_reset_thread_clears_singleton():
    import emacsos_server.app as app_mod

    class _FakeThread:
        thread_id = "fake-id"
    app_mod._THREAD = _FakeThread()
    app_mod._reset_thread()
    assert app_mod._THREAD is None
