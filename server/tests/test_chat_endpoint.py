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


@dataclass
class _FakeToolMessage:
    name: str
    content: str
    tool_call_id: str = "tc-1"
    type: str = "tool"


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
               return_value=(iter(scripted), None)):
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
               return_value=(iter(scripted), None)):
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
               return_value=(iter(scripted), None)):
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
               return_value=(iter(scripted), None)):
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
               return_value=(iter(scripted), None)):
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
               return_value=(iter(scripted), None)):
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
               return_value=(gen(), None)):
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
               return_value=(iter(scripted), None)):
        with client.stream("POST", "/chat", json=_chat_body("q")) as r:
            assert r.headers["content-type"].startswith("application/x-ndjson")


def test_start_event_carries_stream_id_and_ts(client):
    scripted = [("messages", (_FakeAIMessageChunk(content="x"), {}))]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=(iter(scripted), None)):
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
        # Return a (thread, working_dir) tuple matching the real
        # `_build_thread`'s shape (added in Copilot round 2 fix for
        # the per-/chat tempdir leak).
        class _T:
            def stream_message(self, _msg):
                return iter([])
        return _T(), None

    with patch.object(app_mod, "_build_thread", side_effect=fake_build):
        with client.stream("POST", "/chat", json=_chat_body("q")) as r:
            _collect_events(r)

    ctx = captured["ctx"]
    assert isinstance(ctx, PhoneContext)
    assert ctx.auth_contents == _FAKE_AUTH
    # TestClient sets client.host to "testclient" by default.
    assert ctx.phone_host == "testclient"


def test_working_dir_is_cleaned_up_after_stream(client, tmp_path):
    """Per-/chat working_dir must be rmtree'd in `_stream_turn`'s
    finally — otherwise /tmp/emacsos-thread-* leaks one entry per
    request (Copilot round 2 caught this)."""
    import emacsos_server.app as app_mod

    wd = tmp_path / "emacsos-thread-xyz"
    wd.mkdir()
    assert wd.exists()

    def fake_build(_phone_ctx):
        class _T:
            def stream_message(self, _msg):
                return iter([])
        return _T(), str(wd)

    with patch.object(app_mod, "_build_thread", side_effect=fake_build):
        with client.stream("POST", "/chat", json=_chat_body("q")) as r:
            _collect_events(r)

    assert not wd.exists(), f"working_dir leaked: {wd}"


def test_build_thread_cleans_working_dir_on_construction_failure(tmp_path, monkeypatch):
    """If `Thread(...)` raises (eg. ASSIST_MODEL_URL misconfig), the
    working_dir is leaked because the caller never gets a handle to
    rmtree it.  `_build_thread` must rmtree on failure before
    re-raising (Copilot round 3 caught this)."""
    import emacsos_server.app as app_mod
    from emacsos_server.channel import PhoneContext

    captured = {}

    def fake_mkdtemp(prefix):
        path = tmp_path / f"{prefix}xyz"
        path.mkdir()
        captured["path"] = path
        return str(path)

    monkeypatch.setattr(app_mod.tempfile, "mkdtemp", fake_mkdtemp)

    class _BoomThread:
        def __init__(self, **_kw):
            raise RuntimeError("ASSIST_MODEL_URL not set")

    # Patch Thread import in app_mod by replacing assist.thread.Thread.
    import assist.thread as assist_thread_mod
    monkeypatch.setattr(assist_thread_mod, "Thread", _BoomThread)

    ctx = PhoneContext(auth_contents=_FAKE_AUTH, phone_host="10.0.0.1")
    import pytest as _pytest
    with _pytest.raises(RuntimeError, match="ASSIST_MODEL_URL"):
        app_mod._build_thread(ctx)

    assert not captured["path"].exists(), \
        f"working_dir leaked on Thread construction failure: {captured['path']}"


# --- applied event (derived from apply_config's tool result) ----------------

def test_apply_config_result_emits_applied_event(client):
    scripted = [
        ("messages", (_FakeToolMessage(
            name="apply_config",
            content="applied: blue cursor (vabc123) — loaded cleanly"), {})),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=(iter(scripted), None)):
        with client.stream("POST", "/chat", json=_chat_body()) as r:
            events = _collect_events(r)
    applied = [e for e in events if e["type"] == "applied"]
    assert len(applied) == 1
    assert applied[0]["broken"] is False
    assert "blue cursor" in applied[0]["detail"]


def test_apply_config_load_error_sets_broken_flag(client):
    scripted = [
        ("messages", (_FakeToolMessage(
            name="apply_config",
            content="applied-but-broken: x (vabc123) — errored while loading"), {})),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=(iter(scripted), None)):
        with client.stream("POST", "/chat", json=_chat_body()) as r:
            events = _collect_events(r)
    applied = [e for e in events if e["type"] == "applied"]
    assert len(applied) == 1
    assert applied[0]["broken"] is True


def test_applied_event_deduped_across_stream_modes(client):
    # The same ToolMessage can surface in both messages and updates mode;
    # the seen-set must emit `applied` exactly once.
    tm = _FakeToolMessage(name="apply_config", content="applied: x", tool_call_id="tc-7")
    scripted = [
        ("messages", (tm, {})),
        ("updates", {"tools": {"messages": [tm]}}),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=(iter(scripted), None)):
        with client.stream("POST", "/chat", json=_chat_body()) as r:
            events = _collect_events(r)
    assert len([e for e in events if e["type"] == "applied"]) == 1


def test_non_apply_config_tool_result_emits_no_applied(client):
    scripted = [
        ("messages", (_FakeToolMessage(name="eval_elisp", content="applied: nope"), {})),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=(iter(scripted), None)):
        with client.stream("POST", "/chat", json=_chat_body()) as r:
            events = _collect_events(r)
    assert not [e for e in events if e["type"] == "applied"]


# --- /rollback --------------------------------------------------------------

def test_rollback_missing_phone_returns_error(client):
    r = client.post("/rollback", json={})
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "error"
    assert "missing phone context" in body["detail"]


def test_rollback_endpoint_returns_do_rollback_result(client):
    with patch("emacsos_server.app._do_rollback",
               return_value={"status": "applied", "detail": "ok: loaded"}):
        r = client.post("/rollback", json={"phone": {"auth_file": _FAKE_AUTH}})
    assert r.status_code == 200
    assert r.json() == {"status": "applied", "detail": "ok: loaded"}


def test_do_rollback_reverts_and_applies(tmp_path):
    from emacsos_server.app import _do_rollback
    from emacsos_server.channel import PhoneContext
    from emacsos_server.config_repo import ConfigRepo
    from emacsos_server.apply import ApplyResult
    repo = ConfigRepo(str(tmp_path / "repo"))
    repo.write_and_commit("(setq x 1)", "v1")
    repo.write_and_commit("(setq x 2)", "v2")
    with patch("emacsos_server.app.ConfigRepo", lambda _d: repo), \
         patch("emacsos_server.app.apply_mod.apply_to_phone",
               return_value=ApplyResult("applied", "ok: loaded")) as m:
        out = _do_rollback(PhoneContext(auth_contents=_FAKE_AUTH, phone_host="10.0.0.5"))
    assert out["status"] == "applied"
    # Reverted to v1's body, and that's what got applied to the phone.
    assert repo.current().body == "(setq x 1)"
    assert m.call_args.args[1] == "(setq x 1)"


def test_do_rollback_noop_when_nothing_to_roll_back(tmp_path):
    from emacsos_server.app import _do_rollback
    from emacsos_server.channel import PhoneContext
    from emacsos_server.config_repo import ConfigRepo
    repo = ConfigRepo(str(tmp_path / "repo"))  # scaffold only after ensure
    with patch("emacsos_server.app.ConfigRepo", lambda _d: repo), \
         patch("emacsos_server.app.apply_mod.apply_to_phone") as m:
        out = _do_rollback(PhoneContext(auth_contents=_FAKE_AUTH, phone_host="10.0.0.5"))
    assert out["status"] == "noop"
    assert "nothing to roll back" in out["detail"]
    m.assert_not_called()
