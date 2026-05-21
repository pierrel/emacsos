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
import shutil
import tempfile
import time
import uuid
from typing import AsyncIterator, Optional

from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from .channel import EMACS_TOOLS, PHONE_CONTEXT_KEY, PhoneContext
from .config import Config
from . import stream as ndjson

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("emacsos_server")

app = FastAPI(title="emacsos-server", version="0.2.0")
config = Config.from_env()


class PhoneAuth(BaseModel):
    auth_file: str


class ChatRequest(BaseModel):
    message: str
    phone: Optional[PhoneAuth] = None


# Single-flight serialization for /chat streams.  EmacsOS is designed
# for one user / one phone / one chat at a time; the lock prevents
# concurrent /chat coroutines from running the model simultaneously.
# A second /chat arriving mid-stream waits behind the first; the
# `start` event is emitted *before* the lock acquire so the client
# still gets immediate ack of receipt even when queued.
#
# Thread lifecycle is "fresh per stream": each /chat constructs a new
# `assist.Thread` (in `_start_stream_iter`, bound to that request's
# phone context via `extra_config`).  Construction is cheap — no
# model probe — so we don't bother with a cross-request singleton.
# This also means conversation continuity across turns is NOT
# preserved in v1; that's accepted (matches the pre-channel
# behavior, where the singleton was reset in finally anyway).
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

# Runaway backstop: reset the singleton after this many seconds
# of the same stream so a truly-stuck agent doesn't pin the server
# until process restart.  Far longer than any legitimate research
# prompt; the user can always ABORT sooner.
RUNAWAY_SECONDS = 30 * 60.0


def _build_thread(phone_ctx: PhoneContext):
    """Construct a fresh `assist.Thread` for one /chat turn, with the
    phone-control toolset bound and the per-request phone context
    threaded into the langgraph RunnableConfig.  Returns
    `(thread, working_dir)` — caller is responsible for `rmtree`'ing
    `working_dir` when the stream is done so we don't leak one
    `/tmp/emacsos-thread-*` directory per /chat.  Raises whatever
    assist raises during construction (eg. model probe failure)."""
    # Import inside so module import doesn't trigger assist's
    # transitive imports during server startup.
    from assist.thread import Thread

    working_dir = tempfile.mkdtemp(prefix="emacsos-thread-")
    # sandbox_backend=None: emacsos runs the agent without a
    # container sandbox.  model=None lets Thread call
    # `select_chat_model` itself, which reads ASSIST_MODEL_URL.
    log.info("Constructing assist.Thread (working_dir=%s) for %s",
             working_dir, phone_ctx.phone_host)
    try:
        t = Thread(
            working_dir=working_dir,
            sandbox_backend=None,
            extra_tools=EMACS_TOOLS,
            extra_config={"configurable": {PHONE_CONTEXT_KEY: phone_ctx}},
        )
    except BaseException:
        # If Thread construction raises (eg. ASSIST_MODEL_URL misconfig
        # or model probe failure), the caller never gets the
        # working_dir to clean up — so rmtree it here before re-raising.
        # Without this, every failing /chat would leak a tempdir.
        shutil.rmtree(working_dir, ignore_errors=True)
        raise
    log.info("assist.Thread ready (thread_id=%s)", t.thread_id)
    return t, working_dir


def _start_stream_iter(message: str, phone_ctx: PhoneContext):
    """Sync helper invoked via run_in_executor: build a fresh Thread
    for this /chat turn and start the stream_message iterator.
    Returns `(iterator, working_dir)` — caller stores the working_dir
    for cleanup in `_stream_turn`'s finally."""
    t, working_dir = _build_thread(phone_ctx)
    return iter(t.stream_message(message)), working_dir


async def _stream_turn(message: str, phone_auth: Optional[str], request: Request) -> AsyncIterator[bytes]:
    """The async generator that drives one chat turn.  Bridges
    assist's sync iterator via run_in_executor and polls
    is_disconnected() between yields so client ABORT fires the
    finally cleanly.  See design doc §4 for the cancellation chain."""
    loop = asyncio.get_running_loop()
    SENTINEL = object()
    stream_id = uuid.uuid4().hex
    full_text_parts: list[str] = []
    seen_tool_ids: set[str] = set()
    it = None
    working_dir: Optional[str] = None
    # NOTE: `runaway_at` is set AFTER acquiring `_STREAM_LOCK` below;
    # otherwise a long wait behind the lock would burn the budget
    # before we'd even started this stream's actual work.
    runaway_at = float("inf")

    yield ndjson.event("start", stream_id=stream_id, ts=time.time())

    # Build the PhoneContext for this request: the auth-file contents
    # are POSTed in the request body; the host we substitute for the
    # untrusted `host` field in that file is the real source address of
    # the TCP socket (FastAPI's `request.client.host`).  See `phone.py`.
    phone_ctx: Optional[PhoneContext] = None
    if phone_auth is not None and request.client is not None:
        phone_ctx = PhoneContext(
            auth_contents=phone_auth,
            phone_host=request.client.host,
        )

    # Fail fast on malformed requests BEFORE acquiring the lock —
    # a missing phone-context is purely a request-shape problem and
    # has no business queuing behind an in-flight stream.
    if phone_ctx is None:
        yield ndjson.event(
            "error",
            reason="missing phone context: request lacks phone.auth_file or client host",
        )
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
        # Move Thread construction onto the executor so the async
        # handler isn't blocked by it.  This is also the only place an
        # ASSIST_MODEL_URL misconfig can raise.
        it, working_dir = await loop.run_in_executor(
            None, _start_stream_iter, message, phone_ctx)
        pending = None
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
                pending = loop.run_in_executor(None, next, it, SENTINEL)
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
        # on runaway-return, AND on exception.  Drops the iterator
        # so GC closes it (releasing THREAD_QUEUE via __exit__).
        # No singleton to reset — `_start_stream_iter` built a fresh
        # Thread per stream and it'll GC with the iterator.
        if it is not None and hasattr(it, "close"):
            # Generators expose close(); plain list_iterators (used by
            # the test stub) do not, hence the hasattr guard -- avoids
            # a noisy AttributeError-as-Exception log on every test.
            try:
                it.close()
            except ValueError:
                # "generator already executing" — agent thread is
                # still active on its worker.  GC will close once
                # the agent yields/returns; nothing else to do.
                pass
            except Exception:
                log.exception("error closing inner iterator")
        # Remove the per-stream working_dir so /tmp/emacsos-thread-*
        # doesn't accumulate one entry per /chat.  Best-effort —
        # cleanup failures get logged but don't break the stream.
        if working_dir is not None:
            try:
                shutil.rmtree(working_dir, ignore_errors=False)
            except Exception:
                log.exception("error removing working_dir %s", working_dir)
        # Release the single-flight lock so the next queued /chat can
        # proceed.  Always paired with the acquire above this try block.
        _STREAM_LOCK.release()


@app.post("/chat")
async def chat(req: ChatRequest, request: Request):
    log.info("POST /chat msg=%r", req.message)
    phone_auth = req.phone.auth_file if req.phone is not None else None
    return StreamingResponse(
        _stream_turn(req.message, phone_auth, request),
        # Explicit charset so emacs url-http (and any other client that
        # defaults differently) decodes our UTF-8-encoded NDJSON
        # correctly; non-ASCII tokens otherwise risk mojibake.
        media_type="application/x-ndjson; charset=utf-8",
    )


def main() -> None:
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=config.port)


if __name__ == "__main__":
    main()
