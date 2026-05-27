"""FastAPI app for the chat endpoint.

POST /chat: async route handler that streams NDJSON events as
assist's agent runs.  Wire shape + decisions: see
docs/2026-05-17-streaming-responses.org and
docs/2026-05-18-emacs-modifying-channel.org.

ASSIST_MODEL_URL must be set when the server is invoked OR by the
time the first /chat lands; without it, agent construction fails
on the first chat and the client sees a clean `error` event.

Agent-callable phone-control tools (eg. `eval_elisp`) are wired in
via `extra_tools=EMACS_TOOLS` on `Thread`; per-request phone identity
flows through `extra_config={"configurable": {"phone_context": ...}}`
and tools read it via the `config: RunnableConfig` parameter.
"""
from __future__ import annotations

import asyncio
import logging
import os
import re
import shutil
import sqlite3
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from typing import AsyncIterator, Optional

from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from .channel import EMACS_TOOLS, LOOP_EXPLORATION_TOOLS, PHONE_CONTEXT_KEY, PhoneContext
from .config import Config
from .config_repo import ConfigRepo, render
from . import apply as apply_mod
from . import stream as ndjson

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("emacsos_server")

app = FastAPI(title="emacsos-server", version="0.2.0")
config = Config.from_env()

# Embedder skill route: a virtual-path backend holding our SKILL.md files,
# passed to the agent via create_agent's extra_skill_sources (ADDS to the
# built-in assist skills — distinct key from assist's SKILLS_ROUTE).  The
# config-apply skill teaches the verify->apply_config workflow so the small
# model doesn't wander on persistent-config requests.
EMACSOS_SKILLS_ROUTE = "/emacsos-skills/"
_SKILLS_DIR = os.path.join(os.path.dirname(__file__), "skills")
_SKILL_SOURCES = None


def _skill_sources() -> dict:
    """Route -> backend mapping for `create_agent(extra_skill_sources=...)`.
    Built lazily so the `FilesystemBackend` import defers deepagents'
    transitive imports off module load — same reason `_build_thread`
    imports `assist.thread.Thread` lazily."""
    global _SKILL_SOURCES
    if _SKILL_SOURCES is None:
        from deepagents.backends import FilesystemBackend
        _SKILL_SOURCES = {
            EMACSOS_SKILLS_ROUTE: FilesystemBackend(root_dir=_SKILLS_DIR,
                                                    virtual_mode=True)
        }
    return _SKILL_SOURCES


class PhoneAuth(BaseModel):
    auth_file: str


class ChatRequest(BaseModel):
    message: str
    phone: Optional[PhoneAuth] = None
    # File-backed chat (.assist): a client-minted thread id keys the
    # conversation, and `workdir` is the file's directory ON THE PHONE that
    # the EmacsBackend operates in.  Both absent => the legacy fixed *chat*
    # conversation (CONVERSATION_THREAD_ID) with the EMACS_TOOLS surface.
    thread_id: Optional[str] = None
    workdir: Optional[str] = None


class RollbackRequest(BaseModel):
    phone: Optional[PhoneAuth] = None


class ForgetRequest(BaseModel):
    thread_id: str


def _phone_ctx(phone_auth: Optional[str], request: Request) -> Optional[PhoneContext]:
    """Build the per-request PhoneContext: the posted auth-file contents
    plus the real source address of the socket (the untrusted host field
    in the auth file is discarded — see `phone.py`).  Returns None when
    the request lacks an auth file or a client host."""
    if phone_auth is not None and request.client is not None:
        return PhoneContext(auth_contents=phone_auth, phone_host=request.client.host)
    return None


# Single-flight serialization for /chat streams.  EmacsOS is designed
# for one user / one phone / one chat at a time; the lock prevents
# concurrent /chat coroutines from running the model simultaneously.
# A second /chat arriving mid-stream waits behind the first; the
# `start` event is emitted *before* the lock acquire so the client
# still gets immediate ack of receipt even when queued.
#
# The lock is also load-bearing for conversation persistence: /chat,
# /rollback, AND /clear all acquire it, so on the NORMAL path the shared
# checkpointer (below) is only ever touched by one operation at a time —
# /clear can't delete the thread out from under a turn that's
# mid-checkpoint.  Caveat: an ABORT/runaway during agent execution
# leaves the worker thread running after the lock is released (see the
# `_stream_turn` finally), so a /clear queued right then CAN overlap that
# orphaned worker's last checkpoint write.  That overlap is bounded by
# SqliteSaver's own per-connection lock — worst case a torn/partial
# conversation, never DB corruption — and matches the design's existing
# acceptance of orphaned workers on the abort path.
#
# Each /chat rebuilds a fresh `assist.Thread` (in `_start_stream_iter`)
# but now binds it to the persistent checkpointer + a FIXED thread id
# (see CONVERSATION_THREAD_ID below), so the prior conversation is
# replayed from the checkpointer and the agent remembers earlier turns.
# Rebuilding the Thread object each turn is cheap and the right
# langgraph idiom — all conversational state lives in the checkpoint,
# not the compiled graph.
_STREAM_LOCK = asyncio.Lock()

# Heartbeat: emit a `heartbeat` event every N seconds of silence so
# long tool runs don't look like a dead connection.  Spike showed
# tool-call args stream as `tool_call_chunks` (no `content`) and
# sub-agent execution is opaque from the top-level stream, so
# silent periods between status events are routine on research-
# shaped prompts.
HEARTBEAT_SECONDS = 10.0

# How often the inner loop wakes to check `request.is_disconnected()`.
# Decoupled from HEARTBEAT_SECONDS so an ABORT (client disconnect)
# frees the executor thread/queue within ~1s rather than waiting up
# to a full heartbeat cycle.
DISCONNECT_POLL_SECONDS = 1.0

# Runaway backstop: abort a stream after this many seconds so a
# truly-stuck agent doesn't pin the server until process restart.
# Far longer than any legitimate research prompt; the user can always
# ABORT sooner.
RUNAWAY_SECONDS = 30 * 60.0

# --- Persistent conversation ------------------------------------------------
# One rolling conversation for the single phone this server serves.  A
# fixed thread id (not the phone IP, which changes LAN<->WireGuard, nor
# the emacs auth secret, which rotates on daemon restart) so the
# conversation survives both a server restart and a phone reboot — only
# "New chat" (POST /clear) forgets it.
#
# We use assist's low-level `Thread(checkpointer=, thread_id=)` + a
# `SqliteSaver` directly rather than `assist.ThreadManager`: that class
# mints *random* thread ids (`new()`), raises if the thread dir is
# missing (`get()`), and pulls container-sandbox cleanup into deletion
# (`hard_delete()`) — none of which fit a single fixed-id, sandbox-less
# phone conversation.  The low-level API is exactly what ThreadManager
# is built on, minus the multi-thread machinery we don't want.
#
# Context-window growth is handled upstream by deepagents'
# SummarizationMiddleware (auto-installed by create_deep_agent, keyed by
# this thread id); it offloads older turns into the checkpoint and feeds
# the model summary+recent, so the raw log accumulates in threads.db but
# the model context stays bounded.
CONVERSATION_THREAD_ID = "emacsos-phone"

# Lazily built so importing this module (e.g. in tests) doesn't create
# threads.db until a request needs it (a /chat turn or a /clear).
_CHECKPOINTER = None


def _private_makedirs(path: str) -> None:
    """`makedirs` + enforce user-only (0700) perms, even on an existing dir.
    The conversation state under `state_dir` — `threads.db` (full chat
    transcripts) and the working dir (the agent's `AGENTS.md` memory,
    derived from user prompts) — is personal data; a 0700 dir keeps it out
    of reach of other local users regardless of umask.  `mode=0o700` on
    `makedirs` creates it restricted from the start (no group/world window
    before the `chmod` — matters under a shared parent); the `chmod` then
    tightens a pre-existing dir, where `makedirs` is a no-op."""
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)


_THREAD_ID_RE = re.compile(r"\A[A-Za-z0-9_-]{1,128}\Z")


def _validate_thread_id(thread_id: str) -> str:
    """Reject a thread id that isn't a safe slug.  It's both a checkpoint
    key AND a filesystem path component (`_thread_working_dir`), so a `/` or
    `..` would be a path-traversal / key-injection foothold.  The client
    mints a UUID; the legacy `emacsos-phone` also matches."""
    if not _THREAD_ID_RE.match(thread_id or ""):
        raise ValueError(f"invalid thread_id: {thread_id!r}")
    return thread_id


def _thread_working_dir(thread_id: str) -> str:
    """Stable per-thread SERVER-side working dir (sub-agent scratch; for the
    legacy path also the agent's `AGENTS.md`).  Reused across turns — no
    per-/chat tempdir to leak.  For file-backed chat the agent's *files* live
    on the phone (the EmacsBackend), so this dir holds only sub-agent scratch.
    Conversation state itself lives in the checkpointer, not here."""
    return os.path.join(config.state_dir, "threads",
                        _validate_thread_id(thread_id))


def _conversation_working_dir() -> str:
    """The legacy fixed *chat* working dir."""
    return _thread_working_dir(CONVERSATION_THREAD_ID)


def _checkpointer():
    """The process-wide persistent conversation checkpointer (one
    SqliteSaver on `<state_dir>/threads.db`).  Built once, lazily.

    `check_same_thread=False` because turns run on `run_in_executor`
    worker threads; SqliteSaver serializes all DB access behind its own
    internal lock, and `_STREAM_LOCK` keeps operations from overlapping
    semantically.  Follows `assist.thread.ThreadManager`'s setup (we skip
    its upfront DB-file touch — `sqlite3.connect` creates the file).

    First-init has no construction lock of its own: it's safe because
    every caller (`_build_thread` via /chat, `_clear_conversation` via
    /clear) reaches it on a `run_in_executor` thread while holding
    `_STREAM_LOCK`, so the build is serialized."""
    global _CHECKPOINTER
    if _CHECKPOINTER is None:
        from langgraph.checkpoint.sqlite import SqliteSaver
        # 0700 state_dir: gates threads.db (chat transcripts) from other
        # local users even though SqliteSaver creates the db with default
        # perms — they can't traverse a user-only parent.
        _private_makedirs(config.state_dir)
        db_path = os.path.join(config.state_dir, "threads.db")
        _CHECKPOINTER = SqliteSaver(
            sqlite3.connect(db_path, check_same_thread=False))
    return _CHECKPOINTER


def _build_thread(phone_ctx: PhoneContext, thread_id=None, workdir=None):
    """Build this /chat turn's `assist.Thread` over the SHARED persistent
    backing (the process-wide checkpointer), keyed by `thread_id` so prior
    turns replay from the checkpoint.  Two modes:

    - FILE-BACKED CHAT (`thread_id` + `workdir` given): the main agent runs
      against the phone via an `EmacsBackend` rooted at the phone `workdir`,
      with NO `EMACS_TOOLS` — the backend's filesystem ops + `execute` ARE
      the surface.  (See the file-backed-chat doc: this is full-trust,
      unconfined on-device execution.)
    - LEGACY *chat* (neither given): the emacs-control `EMACS_TOOLS`
      (eval_elisp/apply_config) on the fixed `CONVERSATION_THREAD_ID`.

    The per-request phone context is threaded into the RunnableConfig in
    both modes.  Raises whatever assist raises during construction."""
    # Import inside so module import doesn't trigger assist's
    # transitive imports during server startup.
    from assist.thread import Thread

    tid = thread_id or CONVERSATION_THREAD_ID
    # SERVER-side scratch dir (sub-agents + makedirs); NEVER the phone path.
    server_dir = _thread_working_dir(tid)
    _private_makedirs(server_dir)

    # model=None lets Thread call `select_chat_model` itself (reads ASSIST_MODEL_URL).
    kwargs = dict(
        working_dir=server_dir,
        thread_id=tid,
        checkpointer=_checkpointer(),
        loop_exploration_tools=LOOP_EXPLORATION_TOOLS,
        extra_skill_sources=_skill_sources(),
        extra_config={"configurable": {PHONE_CONTEXT_KEY: phone_ctx}},
    )
    if thread_id is not None:
        if not workdir:
            raise ValueError("file-backed chat requires `workdir`")
        # The phone's emacs daemon IS the backend.  eval transport must
        # outwait the command's own coreutils `timeout` (EXEC_TIMEOUT_SECONDS)
        # or the emacsclient round trip dies before the command finishes.
        from .emacs_backend import EmacsBackend, EXEC_TIMEOUT_SECONDS
        from . import phone as phone_mod

        def _eval(expr: str):
            return phone_mod.call_emacs(
                phone_ctx.auth_contents, phone_ctx.phone_host, expr,
                timeout=EXEC_TIMEOUT_SECONDS + 15)
        # default_backend (mutually exclusive with sandbox_backend) — being a
        # SandboxBackendProtocol, it auto-enables deepagents' `execute` tool.
        kwargs["default_backend"] = EmacsBackend(workdir, _eval)
    else:
        # sandbox_backend=None (the default): no container; the emacs-control
        # toolset is bound for the legacy fixed conversation.
        kwargs["extra_tools"] = EMACS_TOOLS

    t = Thread(**kwargs)
    # Surface the resolved context window: summarization's 0.85 trigger
    # only fires if the model profile exposes max_input_tokens, so log it
    # to make a windowing misconfig visible rather than silently degraded.
    max_in = (getattr(t.model, "profile", None) or {}).get("max_input_tokens")
    log.info("assist.Thread ready (thread_id=%s, file_chat=%s, max_input_tokens=%s)",
             t.thread_id, thread_id is not None, max_in)
    return t


# Known limitation (see docs/2026-05-22-conversation-history.org): now
# that state persists, a crash mid-tool-call can leave a dangling tool
# call that the next turn resumes into, which some providers reject
# (BadRequest).  `Thread.stream_message` has no invoke_with_rollback
# wrapper, so this path won't auto-recover; the v1 remedy is "New chat".
def _start_stream_iter(message: str, phone_ctx: PhoneContext,
                       thread_id=None, workdir=None):
    """Sync helper invoked via run_in_executor: build the Thread for this
    /chat turn and start its `stream_message` iterator."""
    t = _build_thread(phone_ctx, thread_id=thread_id, workdir=workdir)
    return iter(t.stream_message(message))


def _close_iter(it) -> None:
    """Close the stream iterator, releasing assist's THREAD_QUEUE via the
    generator's `with` __exit__.  Run on the SAME pump thread that entered it
    (see `_stream_turn`).

    MUST NOT let an exception escape: this is submitted fire-and-forget, and
    an un-retrieved executor-future exception emits a noisy "Future exception
    was never retrieved" warning.  The `hasattr` guard tolerates the test
    stub's plain list-iterator (no `.close()`)."""
    if not hasattr(it, "close"):
        return
    try:
        it.close()
    except ValueError:
        # "generator already executing" — kept defensively; under the
        # single-worker pump this close is always queued behind the in-flight
        # next() (never concurrent with it), so it shouldn't actually fire.
        pass
    except Exception:
        log.exception("error closing inner iterator")


def _defuse_future(fut) -> None:
    """Retrieve a future's exception so an abandoned `next()` future (left
    in flight when a turn aborts) doesn't log "Future exception was never
    retrieved".  Used as a done-callback; the result/exception is discarded."""
    if not fut.cancelled():
        fut.exception()


async def _stream_turn(message: str, phone_auth: Optional[str], request: Request,
                       thread_id: Optional[str] = None,
                       workdir: Optional[str] = None) -> AsyncIterator[bytes]:
    """The async generator that drives one chat turn.  Bridges
    assist's sync iterator via run_in_executor and polls
    is_disconnected() between yields so client ABORT fires the
    finally cleanly.  See design doc §4 for the cancellation chain."""
    loop = asyncio.get_running_loop()
    SENTINEL = object()
    stream_id = uuid.uuid4().hex
    full_text_parts: list[str] = []
    seen_tool_ids: set[str] = set()
    seen_applied: set[str] = set()
    it = None
    # The outstanding `next()` future.  Declared here (not just inside the try)
    # so the finally can defuse it on an abort-return while it's still in flight.
    pending = None
    # Single-worker executor: assist's stream generator holds a thread-affine
    # lock + ContextVar (THREAD_QUEUE.acquire), so it MUST be built, advanced,
    # and closed on ONE OS thread.  A dedicated max_workers=1 pool pins every
    # run_in_executor(pump, ...) below to the same worker (and contextvar
    # context) — mirroring the CLI, which is immune because it drives the
    # generator synchronously on one thread.  Using the default pool (None)
    # spreads next()/close() across threads and crashes the worker with
    # "cannot release un-acquired lock".  Initialized to None so the finally
    # can guard cleanly if we fail before constructing it.
    pump: Optional[ThreadPoolExecutor] = None
    # NOTE: `runaway_at` is set AFTER acquiring `_STREAM_LOCK` below;
    # otherwise a long wait behind the lock would burn the budget
    # before we'd even started this stream's actual work.
    runaway_at = float("inf")

    yield ndjson.event("start", stream_id=stream_id, ts=time.time())

    # Build the PhoneContext for this request: the auth-file contents
    # are POSTed in the request body; the host we substitute for the
    # untrusted `host` field in that file is the real source address of
    # the TCP socket (FastAPI's `request.client.host`).  See `phone.py`.
    phone_ctx: Optional[PhoneContext] = _phone_ctx(phone_auth, request)

    # Fail fast on malformed requests BEFORE acquiring the lock —
    # a missing phone-context is purely a request-shape problem and
    # has no business queuing behind an in-flight stream.
    if phone_ctx is None:
        yield ndjson.event(
            "error",
            reason="missing phone context: request lacks phone.auth_file or client host",
        )
        return

    # File-backed chat: validate the client-minted thread id + require a
    # workdir BEFORE acquiring the lock (a request-shape problem, like the
    # phone-context check above).
    if thread_id is not None:
        try:
            _validate_thread_id(thread_id)
        except ValueError as e:
            yield ndjson.event("error", reason=str(e))
            return
        if not workdir:
            yield ndjson.event("error",
                               reason="file-backed chat requires `workdir`")
            return

    # Single-flight: serialize the body of the stream so two /chat
    # coroutines don't run the model in parallel.  Acquire BEFORE the
    # try so the corresponding release in finally always pairs cleanly;
    # `start` is yielded *before* acquire so queued clients still see
    # an immediate ack of receipt.
    await _STREAM_LOCK.acquire()
    try:
        # `runaway_at` is set HERE (not before the lock acquire) so a
        # long wait behind the lock doesn't burn the budget before
        # we've even started.  Inside the try so the finally is the
        # exclusive release path.
        runaway_at = time.monotonic() + RUNAWAY_SECONDS
        pump = ThreadPoolExecutor(max_workers=1)
        # Move Thread construction onto the pump so the async handler isn't
        # blocked by it AND so __enter__ of THREAD_QUEUE.acquire (which the
        # generator runs on its first next()) lands on the pump thread.  This
        # is also the only place an ASSIST_MODEL_URL misconfig can raise.
        it = await loop.run_in_executor(
            pump, _start_stream_iter, message, phone_ctx, thread_id, workdir)
        last_heartbeat = time.monotonic()
        while True:
            if await request.is_disconnected():
                log.info("Client disconnected; aborting stream %s", stream_id)
                return
            if time.monotonic() > runaway_at:
                log.warning("Stream %s exceeded RUNAWAY_SECONDS=%s; aborting",
                            stream_id, RUNAWAY_SECONDS)
                yield ndjson.event(
                    "error",
                    reason=f"runaway: stream ran longer than {int(RUNAWAY_SECONDS)}s",
                    after_tokens=sum(len(p) for p in full_text_parts),
                )
                return
            if pending is None:
                # run_in_executor returns an asyncio.Future already, so
                # we don't need ensure_future to make asyncio.wait happy.
                # `pump` (max_workers=1) keeps every next() on the same worker
                # thread as __enter__, so the generator's THREAD_QUEUE lock is
                # released by its owning thread when it exits.
                pending = loop.run_in_executor(pump, next, it, SENTINEL)
            # Wait on the inner-iter future for DISCONNECT_POLL_SECONDS;
            # this caps client-disconnect latency at ~1s independently of
            # the heartbeat cadence.  If the wait times out and a full
            # HEARTBEAT_SECONDS has elapsed since the last heartbeat,
            # emit one to keep the pipe live; otherwise just loop and
            # re-check disconnect.
            done, _ = await asyncio.wait([pending], timeout=DISCONNECT_POLL_SECONDS)
            if not done:
                if time.monotonic() - last_heartbeat >= HEARTBEAT_SECONDS:
                    yield ndjson.event("heartbeat", ts=time.time())
                    last_heartbeat = time.monotonic()
                continue
            chunk = await pending
            pending = None
            if chunk is SENTINEL:
                break
            ch_type, payload = chunk
            # Derive the `applied` event from apply_config's tool RESULT
            # (the ToolMessage), the single source of truth.  Works
            # regardless of which stream mode surfaces the result; the
            # seen-set de-dupes if it shows up in both.
            #
            # Only the two COMMITTED outcomes (`applied:` clean,
            # `applied-but-broken:` loaded-with-error) get the event —
            # both have a git commit the user can revert.  NOT
            # `applied-but-unrecorded:` (loaded but the commit failed):
            # there's nothing in history to roll back to, so offering
            # ROLLBACK there would revert to the *wrong* state.  The
            # colon-terminated prefixes are mutually exclusive, so this
            # excludes `applied-but-unrecorded:` cleanly.
            for tc_id, tname, content in ndjson.extract_tool_results(payload):
                if (tname == "apply_config" and tc_id not in seen_applied
                        and content.startswith(("applied:", "applied-but-broken:"))):
                    seen_applied.add(tc_id)
                    yield ndjson.event(
                        "applied",
                        detail=content,
                        broken=content.startswith("applied-but-broken"),
                    )
            if ch_type == "messages":
                text = ndjson.extract_content_text(payload)
                if text:
                    full_text_parts.append(text)
                    yield ndjson.event("token", text=text)
                for tc_id, tc_name in ndjson.extract_new_tool_calls(payload):
                    if tc_id not in seen_tool_ids:
                        seen_tool_ids.add(tc_id)
                        yield ndjson.event("status",
                                           text=f"calling {tc_name}")
            elif ch_type == "updates":
                status = ndjson.render_update_to_status(payload)
                if status:
                    yield ndjson.event("status", text=status)
            # else: other stream_mode kinds we don't subscribe to.
        yield ndjson.event("end", text="".join(full_text_parts))
    except Exception as e:
        log.exception("stream %s failed", stream_id)
        yield ndjson.event(
            "error",
            reason=ndjson.map_error(e),
            after_tokens=sum(len(p) for p in full_text_parts),
        )
    finally:
        # Load-bearing: runs on natural exit, on disconnect-return,
        # on runaway-return, AND on exception.
        #
        # Close the iterator ON THE PUMP THREAD (never the event-loop
        # thread): the generator's __exit__ releases THREAD_QUEUE's lock,
        # which must happen on the thread that acquired it.  On natural exit
        # the generator already exited its `with` block during the final
        # next() (so this close is a no-op); on abort, an in-flight next()
        # may still hold the worker, and the queued close runs once it
        # returns.  Fire-and-forget — we do NOT await it, so a wedged model
        # call can't block the lock release below (a truly stuck next()
        # orphans the worker AND leaks that thread-id's THREAD_QUEUE slot
        # until the call returns; this is the accepted fail-fast behavior).
        # `_close_iter` swallows its own exceptions so the un-awaited future
        # is clean.
        #
        # If we aborted (disconnect/runaway) with a next() abandoned, retrieve
        # its eventual exception so a failing next() doesn't log "Future
        # exception was never retrieved".  Defuse unconditionally (not just when
        # still pending): it may have completed-with-exception between the last
        # asyncio.wait and the abort check; add_done_callback fires immediately
        # if it's already done, retrieving the exception either way.
        if pending is not None:
            pending.add_done_callback(_defuse_future)
        # Submit BEFORE shutdown: scheduling on a shut-down pool raises.
        if pump is not None:
            if it is not None:
                loop.run_in_executor(pump, _close_iter, it)
            pump.shutdown(wait=False)
        # Release the single-flight lock so the next queued /chat can
        # proceed.  Always paired with the acquire above this try block.
        _STREAM_LOCK.release()


@app.post("/chat")
async def chat(req: ChatRequest, request: Request):
    log.info("POST /chat msg=%r", req.message)
    phone_auth = req.phone.auth_file if req.phone is not None else None
    return StreamingResponse(
        _stream_turn(req.message, phone_auth, request, req.thread_id, req.workdir),
        # Explicit charset so emacs url-http (and any other client that
        # defaults differently) decodes our UTF-8-encoded NDJSON
        # correctly; non-ASCII tokens otherwise risk mojibake.
        media_type="application/x-ndjson; charset=utf-8",
    )


def _do_rollback(phone_ctx: PhoneContext) -> dict:
    """Sync rollback (run on the executor): git-revert the config repo's
    HEAD, then load the resulting config on the phone.  Returns a small
    status dict for the JSON response.  Any git/repo failure is caught
    and returned as a structured error — never a bare 500 (apply_to_phone
    already returns structured results, but ConfigRepo can raise on a
    revert conflict / corrupted repo)."""
    try:
        repo = ConfigRepo(config.config_dir)
        repo.ensure()
        result = repo.rollback()
        if not result.ok:
            return {"status": "noop", "detail": result.detail}
        # Load the reverted config (the new HEAD) on the phone so the live
        # state matches the repo again.  Apply the RENDERED file (same
        # content git holds) so the phone's agent.el stays byte-identical
        # to the repo, with the lexical-binding cookie.  apply_to_phone
        # classifies honestly.  `result.version` is non-None when `ok`.
        ar = apply_mod.apply_to_phone(phone_ctx, render(result.version.body))
        return {"status": ar.status, "detail": ar.detail}
    except Exception as e:  # noqa: BLE001 — structured error, never a 500
        log.exception("rollback failed")
        return {"status": "error", "detail": f"{type(e).__name__}: {e}"}


@app.post("/rollback")
async def rollback(req: RollbackRequest, request: Request):
    """Roll the phone config back one version: `git revert` the config
    repo's HEAD and load the result on the phone.  Not a stream — it's a
    fast git op + one emacsclient apply — so it returns plain JSON.
    Serialized behind the same `_STREAM_LOCK` as /chat so it can't race
    a stream's phone access."""
    log.info("POST /rollback")
    phone_ctx = _phone_ctx(req.phone.auth_file if req.phone is not None else None,
                           request)
    if phone_ctx is None:
        return {"status": "error",
                "detail": "missing phone context: request lacks "
                          "phone.auth_file or client host"}
    loop = asyncio.get_running_loop()
    await _STREAM_LOCK.acquire()
    try:
        return await loop.run_in_executor(None, _do_rollback, phone_ctx)
    finally:
        _STREAM_LOCK.release()


def _clear_conversation(thread_id: str = CONVERSATION_THREAD_ID) -> dict:
    """Forget a persistent conversation so the next /chat starts fresh.
    Defaults to the legacy fixed *chat* thread (backs /clear); /forget passes
    a specific file-backed thread id.  For a file-backed thread the agent's
    *memory* (AGENTS.md) lives on the phone, not in the server dir wiped here,
    so the load-bearing effect there is the checkpoint deletion.
    Backs the phone's "New chat".  Two parts, because conversation state
    lives in TWO places:

    1. the checkpointer (messages + summarization offload) → `delete_thread`;
    2. the working dir, where the agent's memory middleware persists facts
       to `AGENTS.md` (and may scratch other files).  This dir is now
       STABLE/reused across turns, so `delete_thread` alone would leave the
       agent still recalling saved facts after a "New chat" — contrary to
       the forget-everything intent (found in the live smoke).  So we wipe
       and recreate it.  Safe: it holds only agent scratch/memory; the
       persistent config lives in the SEPARATE git config repo.

    On the normal path `_STREAM_LOCK` keeps this quiescent — no in-flight
    turn is using the dir.  We do NOT pass `ignore_errors=True`: a genuine
    wipe failure (permission/IO) must surface as a structured error, not a
    false "cleared" that silently leaves `AGENTS.md` behind.  The
    missing-dir case (clear before any /chat) is handled by the `isdir`
    guard, not by swallowing.  Caveat (same as the lock comment above): an
    ABORT/runaway can leave an orphaned worker briefly running after the
    lock releases; on Linux `rmtree` still unlinks its open files, and a
    file the worker re-creates AFTER the wipe is stale scratch the next New
    chat re-wipes — worst case that rare race surfaces as a retry-able
    error.

    Any failure comes back as a structured error, never a bare 500."""
    try:
        tid = _validate_thread_id(thread_id)
        _checkpointer().delete_thread(tid)
        wd = _thread_working_dir(tid)
        # Default ignore_errors=False: a real wipe failure raises and
        # becomes the structured error below rather than a false "cleared".
        if os.path.isdir(wd):
            shutil.rmtree(wd)
        _private_makedirs(wd)
        return {"status": "cleared"}
    except Exception as e:  # noqa: BLE001 — structured error, never a 500
        log.exception("clear failed")
        return {"status": "error", "detail": f"{type(e).__name__}: {e}"}


@app.post("/clear")
async def clear(request: Request):
    """New chat: forget the persistent conversation — both its checkpoint
    state AND the working dir (the agent's `AGENTS.md` memory); see
    `_clear_conversation`.  Argument-free — unlike /rollback it never
    touches the phone (no emacsclient callback), so it needs no phone
    context or body.  Serialized behind the same `_STREAM_LOCK` as /chat so
    it can't wipe state out from under an in-flight turn."""
    log.info("POST /clear")
    loop = asyncio.get_running_loop()
    await _STREAM_LOCK.acquire()
    try:
        return await loop.run_in_executor(None, _clear_conversation)
    finally:
        _STREAM_LOCK.release()


@app.post("/forget")
async def forget(req: ForgetRequest):
    """Forget a specific file-backed conversation: delete its checkpoint +
    server-side scratch dir, keyed by `thread_id`.  The generalized sibling
    of /clear (which stays frozen to the legacy fixed *chat* thread).  Like
    /clear it needs no phone callback; serialized behind the same
    `_STREAM_LOCK` so it can't wipe state under an in-flight turn.  NOTE: a
    file-backed thread's AGENTS.md lives on the phone, so this wipes the
    conversation memory (the checkpoint) but not phone-side files."""
    log.info("POST /forget thread_id=%s", req.thread_id)
    loop = asyncio.get_running_loop()
    await _STREAM_LOCK.acquire()
    try:
        return await loop.run_in_executor(None, _clear_conversation, req.thread_id)
    finally:
        _STREAM_LOCK.release()


def main() -> None:
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=config.port)


if __name__ == "__main__":
    main()
