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
import os
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


# --- persistent conversation: fixed thread id + shared checkpointer ---------

def _tmp_config(tmp_path):
    """A Config pointing state/config dirs at a tmp_path so a test never
    touches ~/.local/state or ~/.config."""
    from emacsos_server.config import Config
    return Config(
        port=8765,
        emacsclient="emacsclient",
        config_dir=str(tmp_path / "cfg"),
        state_dir=str(tmp_path / "state"),
    )


def test_build_thread_binds_fixed_id_and_persistent_checkpointer(tmp_path, monkeypatch):
    """`_build_thread` must construct the Thread with the FIXED
    conversation thread id and the process-wide persistent checkpointer —
    that's what makes the agent remember prior turns.  Captures the
    Thread(...) kwargs at the assist boundary."""
    import emacsos_server.app as app_mod
    from emacsos_server.channel import PhoneContext

    monkeypatch.setattr(app_mod, "config", _tmp_config(tmp_path))
    monkeypatch.setattr(app_mod, "_CHECKPOINTER", None)  # rebuild under tmp state

    captured = {}

    class _FakeThread:
        def __init__(self, **kw):
            captured.update(kw)
            self.thread_id = kw.get("thread_id")
            self.model = None  # exercises the max_input_tokens log fallback

        def stream_message(self, _msg):
            return iter([])

    import assist.thread as assist_thread_mod
    monkeypatch.setattr(assist_thread_mod, "Thread", _FakeThread)

    ctx = PhoneContext(auth_contents=_FAKE_AUTH, phone_host="10.0.0.1")
    app_mod._build_thread(ctx)

    assert captured["thread_id"] == app_mod.CONVERSATION_THREAD_ID
    # Same persistent checkpointer instance the rest of the server uses.
    assert captured["checkpointer"] is app_mod._checkpointer()
    # Phone toolset + context still wired through unchanged.
    assert captured["extra_tools"] is app_mod.EMACS_TOOLS
    assert captured["extra_config"]["configurable"]["phone_context"] is ctx
    # eval_elisp opts into the relaxed LoopDetection threshold so the
    # agent's emacs exploration isn't terminated prematurely.
    assert captured["loop_exploration_tools"] == frozenset({"eval_elisp"})


def test_checkpointer_is_singleton(tmp_path, monkeypatch):
    """The checkpointer is built once and reused — two turns share it, so
    the conversation accumulates in one threads.db."""
    import emacsos_server.app as app_mod
    monkeypatch.setattr(app_mod, "config", _tmp_config(tmp_path))
    monkeypatch.setattr(app_mod, "_CHECKPOINTER", None)
    assert app_mod._checkpointer() is app_mod._checkpointer()


def test_private_makedirs_is_user_only(tmp_path):
    """Conversation state (threads.db transcripts, AGENTS.md memory) must
    live under a user-only (0700) dir so other local users can't read chat
    history.  Also tightens a pre-existing loose dir."""
    import stat
    import emacsos_server.app as app_mod

    d = str(tmp_path / "sub" / "leaf")
    app_mod._private_makedirs(d)
    assert stat.S_IMODE(os.stat(d).st_mode) == 0o700

    # Idempotent + tightens an already-existing world-readable dir.
    os.chmod(d, 0o755)
    app_mod._private_makedirs(d)
    assert stat.S_IMODE(os.stat(d).st_mode) == 0o700


def test_checkpointer_creates_private_state_dir(tmp_path, monkeypatch):
    """Building the checkpointer creates state_dir as 0700 (gates
    threads.db from other local users)."""
    import stat
    import emacsos_server.app as app_mod
    monkeypatch.setattr(app_mod, "config", _tmp_config(tmp_path))
    monkeypatch.setattr(app_mod, "_CHECKPOINTER", None)
    app_mod._checkpointer()
    assert stat.S_IMODE(os.stat(app_mod.config.state_dir).st_mode) == 0o700


# --- applied event (derived from apply_config's tool result) ----------------

def test_apply_config_result_emits_applied_event(client):
    scripted = [
        ("messages", (_FakeToolMessage(
            name="apply_config",
            content="applied: blue cursor (vabc123) — loaded cleanly"), {})),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=iter(scripted)):
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
               return_value=iter(scripted)):
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
               return_value=iter(scripted)):
        with client.stream("POST", "/chat", json=_chat_body()) as r:
            events = _collect_events(r)
    assert len([e for e in events if e["type"] == "applied"]) == 1


def test_non_apply_config_tool_result_emits_no_applied(client):
    scripted = [
        ("messages", (_FakeToolMessage(name="eval_elisp", content="applied: nope"), {})),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=iter(scripted)):
        with client.stream("POST", "/chat", json=_chat_body()) as r:
            events = _collect_events(r)
    assert not [e for e in events if e["type"] == "applied"]


def test_applied_but_unrecorded_emits_no_applied_event(client):
    # Loaded on the phone but the git commit failed → no rollback target,
    # so NO `applied` event (the colon-terminated prefix excludes it).
    scripted = [
        ("messages", (_FakeToolMessage(
            name="apply_config",
            content="applied-but-unrecorded: live but not in git"), {})),
    ]
    with patch("emacsos_server.app._start_stream_iter",
               return_value=iter(scripted)):
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
    from emacsos_server.config_repo import ConfigRepo, render
    from emacsos_server.apply import ApplyResult
    repo = ConfigRepo(str(tmp_path / "repo"))
    repo.write_and_commit("(setq x 1)", "v1")
    repo.write_and_commit("(setq x 2)", "v2")
    with patch("emacsos_server.app.ConfigRepo", lambda _d: repo), \
         patch("emacsos_server.app.apply_mod.apply_to_phone",
               return_value=ApplyResult("applied", "ok: loaded")) as m:
        out = _do_rollback(PhoneContext(auth_contents=_FAKE_AUTH, phone_host="10.0.0.5"))
    assert out["status"] == "applied"
    # Reverted to v1's body, and the RENDERED v1 file got applied to the phone.
    assert repo.current().body == "(setq x 1)"
    assert m.call_args.args[1] == render("(setq x 1)")


def test_do_rollback_returns_structured_error_on_exception(tmp_path):
    """A git/repo failure must come back as {status: error}, not a 500."""
    from emacsos_server.app import _do_rollback
    from emacsos_server.channel import PhoneContext
    with patch("emacsos_server.app.ConfigRepo", side_effect=RuntimeError("git boom")):
        out = _do_rollback(PhoneContext(auth_contents=_FAKE_AUTH, phone_host="10.0.0.5"))
    assert out["status"] == "error"
    assert "git boom" in out["detail"]


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


# --- /clear (new chat) ------------------------------------------------------

def test_clear_endpoint_returns_cleared(client):
    """POST /clear returns the _clear_conversation result.  No phone body
    needed — /clear never touches the phone."""
    with patch("emacsos_server.app._clear_conversation",
               return_value={"status": "cleared"}):
        r = client.post("/clear")
    assert r.status_code == 200
    assert r.json() == {"status": "cleared"}


def test_clear_conversation_resets_thread_and_working_dir(tmp_path, monkeypatch):
    """_clear_conversation deletes the fixed thread's checkpoint AND wipes
    the conversation working dir (where the agent's `AGENTS.md` memory
    lives), so "New chat" fully forgets — not just the transcript.  The
    working-dir wipe was added after a live smoke showed the agent still
    recalling a saved fact after a checkpoint-only clear."""
    import emacsos_server.app as app_mod

    monkeypatch.setattr(app_mod, "config", _tmp_config(tmp_path))

    deleted = {}

    class _FakeCP:
        def delete_thread(self, tid):
            deleted["tid"] = tid

    monkeypatch.setattr(app_mod, "_checkpointer", lambda: _FakeCP())

    # Seed the working dir with an agent memory file that must NOT survive.
    wd = app_mod._conversation_working_dir()
    os.makedirs(wd, exist_ok=True)
    memory = os.path.join(wd, "AGENTS.md")
    with open(memory, "w") as f:
        f.write("codeword: ZEPHYR-9\n")

    out = app_mod._clear_conversation()

    assert out == {"status": "cleared"}
    assert deleted["tid"] == app_mod.CONVERSATION_THREAD_ID
    assert not os.path.exists(memory), "agent memory survived New chat"
    assert os.path.isdir(wd), "working dir should be recreated empty"


def test_clear_conversation_returns_structured_error_on_exception(monkeypatch):
    """A checkpointer failure comes back as {status: error}, not a 500."""
    import emacsos_server.app as app_mod

    class _BoomCP:
        def delete_thread(self, _tid):
            raise RuntimeError("db boom")

    monkeypatch.setattr(app_mod, "_checkpointer", lambda: _BoomCP())
    out = app_mod._clear_conversation()
    assert out["status"] == "error"
    assert "db boom" in out["detail"]


def test_clear_conversation_surfaces_wipe_failure(tmp_path, monkeypatch):
    """A genuine working-dir wipe failure must be reported as a structured
    error, NOT a false 'cleared' (which would leave AGENTS.md behind).
    Regression guard against re-introducing rmtree(ignore_errors=True)."""
    import emacsos_server.app as app_mod

    monkeypatch.setattr(app_mod, "config", _tmp_config(tmp_path))

    class _FakeCP:
        def delete_thread(self, _tid):
            pass

    monkeypatch.setattr(app_mod, "_checkpointer", lambda: _FakeCP())
    # Dir must exist so the wipe is attempted; then make rmtree fail hard.
    os.makedirs(app_mod._conversation_working_dir(), exist_ok=True)

    def boom(*_a, **_k):
        raise PermissionError("denied")

    monkeypatch.setattr(app_mod.shutil, "rmtree", boom)
    out = app_mod._clear_conversation()
    assert out["status"] == "error"
    assert "PermissionError" in out["detail"] or "denied" in out["detail"]
