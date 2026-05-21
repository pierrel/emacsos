"""Unit tests for emacsos_server.stream — the NDJSON event encoder
and LangGraph chunk → status mapping.  Pure functions; no FastAPI
plumbing under test here."""
from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

import pytest

from emacsos_server import stream as ndjson


# --- event(): NDJSON encoding ----------------------------------------------

def test_event_appends_newline():
    out = ndjson.event("token", text="hi")
    assert out.endswith(b"\n"), out


def test_event_round_trips_json():
    out = ndjson.event("start", stream_id="abc", ts=1.5)
    parsed = json.loads(out.decode("utf-8").rstrip("\n"))
    assert parsed == {"type": "start", "stream_id": "abc", "ts": 1.5}


def test_event_non_ascii_preserved():
    out = ndjson.event("token", text="héllo — 日本語")
    parsed = json.loads(out.decode("utf-8").rstrip("\n"))
    assert parsed["text"] == "héllo — 日本語"


# --- map_error() -----------------------------------------------------------

def test_map_error_assist_model_url():
    err = RuntimeError("ASSIST_MODEL_URL not set or invalid")
    assert "ASSIST_MODEL_URL" in ndjson.map_error(err)
    assert "not configured" in ndjson.map_error(err)


def test_map_error_model_unavailable():
    err = RuntimeError("Could not reach model at http://...; HTTP 502")
    out = ndjson.map_error(err)
    assert out.startswith("assist model unavailable")


def test_map_error_other_runtime():
    err = RuntimeError("the disk is on fire")
    assert ndjson.map_error(err) == "the disk is on fire"


def test_map_error_generic_exception():
    err = ValueError("nope")
    out = ndjson.map_error(err)
    assert "ValueError" in out
    assert "nope" in out


# --- extract_content_text() ------------------------------------------------

@dataclass
class _FakeMsg:
    content: Any = ""
    tool_calls: list[dict] | None = None


def test_extract_content_text_returns_content():
    chunk = (_FakeMsg(content="hello"), {})
    assert ndjson.extract_content_text(chunk) == "hello"


def test_extract_content_text_handles_empty():
    chunk = (_FakeMsg(content=""), {})
    assert ndjson.extract_content_text(chunk) == ""


def test_extract_content_text_non_string_returns_empty():
    chunk = (_FakeMsg(content=None), {})
    assert ndjson.extract_content_text(chunk) == ""


def test_extract_content_text_malformed_chunk_returns_empty():
    assert ndjson.extract_content_text(object()) == ""
    assert ndjson.extract_content_text(None) == ""


# --- extract_new_tool_calls() ----------------------------------------------

def test_extract_tool_calls_yields_name_id_pairs():
    chunk = (
        _FakeMsg(tool_calls=[
            {"name": "task", "id": "tc-1"},
            {"name": "search_internet", "id": "tc-2"},
        ]),
        {},
    )
    assert list(ndjson.extract_new_tool_calls(chunk)) == [
        ("tc-1", "task"),
        ("tc-2", "search_internet"),
    ]


def test_extract_tool_calls_skips_unnamed_continuations():
    """Mid-stream chunks have tool_calls=[] (args are in
    tool_call_chunks instead).  Yield nothing for those."""
    chunk = (_FakeMsg(tool_calls=[]), {})
    assert list(ndjson.extract_new_tool_calls(chunk)) == []


# --- extract_tool_results() ------------------------------------------------

@dataclass
class _FakeToolMsg:
    name: str
    content: Any
    tool_call_id: str = "tc-1"
    type: str = "tool"


def test_extract_tool_results_from_messages_mode():
    chunk = (_FakeToolMsg(name="apply_config", content="applied: ok"), {})
    assert list(ndjson.extract_tool_results(chunk)) == [
        ("tc-1", "apply_config", "applied: ok"),
    ]


def test_extract_tool_results_from_updates_mode():
    """updates mode wraps tool output as {node: {messages: [...]}}."""
    chunk = {"tools": {"messages": [
        _FakeToolMsg(name="apply_config", content="applied: ok", tool_call_id="tc-9"),
    ]}}
    assert list(ndjson.extract_tool_results(chunk)) == [
        ("tc-9", "apply_config", "applied: ok"),
    ]


def test_extract_tool_results_skips_non_tool_messages():
    # An AIMessage chunk (type != "tool") yields nothing.
    chunk = (_FakeMsg(content="hi"), {})
    assert list(ndjson.extract_tool_results(chunk)) == []


def test_extract_tool_results_skips_non_string_content():
    chunk = (_FakeToolMsg(name="apply_config", content=None), {})
    assert list(ndjson.extract_tool_results(chunk)) == []


def test_extract_tool_results_skips_missing_tool_call_id():
    # No tool_call_id → skip (an empty id would collide in app.py's
    # de-dup set and suppress unrelated results).
    chunk = (_FakeToolMsg(name="apply_config", content="applied: x",
                          tool_call_id=None), {})
    assert list(ndjson.extract_tool_results(chunk)) == []


def test_extract_tool_results_malformed_payload_is_empty():
    assert list(ndjson.extract_tool_results(object())) == []
    assert list(ndjson.extract_tool_results(None)) == []


def test_extract_tool_calls_skips_name_or_id_missing():
    chunk = (
        _FakeMsg(tool_calls=[
            {"name": None, "id": "tc-1"},
            {"name": "x", "id": None},
            {"args": "..."},  # neither
        ]),
        {},
    )
    assert list(ndjson.extract_new_tool_calls(chunk)) == []


def test_extract_tool_calls_malformed_chunk_yields_nothing():
    assert list(ndjson.extract_new_tool_calls(object())) == []


# --- render_update_to_status() ---------------------------------------------

def test_render_update_drops_middleware_lifecycle():
    """Middleware lifecycle events are internal plumbing; not
    user-visible."""
    cases = [
        {"PatchToolCallsMiddleware.before_agent": None},
        {"SmallModelSkillsMiddleware.before_agent": {"skills_metadata": []}},
        {"JsonValidationMiddleware.before_model": None},
        {"ModelLoggingMiddleware.after_model": None},
    ]
    for c in cases:
        assert ndjson.render_update_to_status(c) is None, c


def test_render_update_drops_model_node():
    """The 'model' node's update is the LLM call itself —
    silent at the status level (tokens render via the messages
    stream)."""
    assert ndjson.render_update_to_status(
        {"model": {"messages": []}}
    ) is None


def test_render_update_surfaces_named_nodes():
    """Tool/subagent nodes surface as 'running <node>' status."""
    assert ndjson.render_update_to_status({"task": {"messages": []}}) == "running task"
    assert ndjson.render_update_to_status({"research-agent": {}}) == "running research-agent"


def test_render_update_malformed_input():
    assert ndjson.render_update_to_status(None) is None
    assert ndjson.render_update_to_status("not a dict") is None
    assert ndjson.render_update_to_status({}) is None


# --- spike-fixture parse sanity --------------------------------------------

def test_simple_fixture_parses(tmp_path):
    """Sanity: the spike fixture lines look like '<type>\\t<repr>'."""
    import pathlib
    fixture = pathlib.Path(__file__).parent / "fixtures" / "stream_chunks_simple.txt"
    if not fixture.exists():
        pytest.skip("fixture not present")
    lines = fixture.read_text().splitlines()
    assert lines, "fixture is empty"
    for line in lines:
        assert "\t" in line, f"unexpected line shape: {line!r}"
        ch_type, _repr = line.split("\t", 1)
        assert ch_type in ("messages", "updates"), ch_type
