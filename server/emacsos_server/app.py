"""FastAPI app for the chat endpoint.

POST /chat: async route handler that streams NDJSON events as
assist's agent runs.  Wire shape + decisions: see
docs/2026-05-17-streaming-responses.org.

ASSIST_MODEL_URL must be set when the server is invoked OR by the
time the first /chat lands; without it, agent construction fails
on the first chat and the client sees a clean `error` event.

Back-channel mechanism (call_emacs in phone.py) is preserved for
the next experiment's agent-callable phone-control tools; the
automatic post-response flash was removed when streaming made it
redundant.
"""
from __future__ import annotations

import asyncio
import logging
import tempfile
import threading
import time
import uuid
from typing import AsyncIterator, Optional

from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

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


# --- assist Thread singleton (lazy, process-wide) ---

# Effectively one Thread per /chat: the singleton is built lazily on
# demand and reset in `_stream_turn`'s finally on every termination
# path (end / abort / client-disconnect / error / runaway), so each
# request starts on a fresh Thread.  Conversation continuity across
# turns is therefore NOT preserved in v1 -- accepted in exchange for
# never queuing behind a stale in-flight agent thread (Python threads
# aren't externally cancellable).  The lock guards the construction
# critical section so two concurrent first-requests don't double-
# construct.  Same shape as PR #6's reset-on-termination pattern,
# just driven by more event types and gated on ownership via
# `_reset_thread_if`.
_THREAD = None
_THREAD_LOCK = threading.Lock()

# Single-flight serialization for /chat streams.  EmacsOS is designed
# for one user / one phone / one chat at a time; the lock prevents
# concurrent /chat coroutines from sharing the singleton Thread and
# accumulating multiple parallel Thread instances under contention.
# A second /chat arriving mid-stream waits behind the first; the
# `start` event is emitted *before* the lock acquire so the client
# still gets immediate ack of receipt even when queued.
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


def _build_thread():
    """Construct a fresh `assist.Thread`.  Raises whatever assist
    raises during construction (eg. model probe failure)."""
    # Import inside so module import doesn't trigger assist's
    # transitive imports during server startup.
    from assist.thread import Thread

    working_dir = tempfile.mkdtemp(prefix="emacsos-thread-")
    # sandbox_backend=None: emacsos runs the agent without a
    # container sandbox.  model=None lets Thread call
    # `select_chat_model` itself, which reads ASSIST_MODEL_URL.
    log.info("Constructing assist.Thread (working_dir=%s)", working_dir)
    t = Thread(working_dir=working_dir, sandbox_backend=None)
    log.info("assist.Thread ready (thread_id=%s)", t.thread_id)
    return t


def _get_thread():
    """Return the singleton Thread, lazy-constructing under the lock.
    The lock is held only for the construction critical section; the
    actual `.stream_message()` call happens outside it so concurrent
    streams don't serialize on Thread construction."""
    global _THREAD
    if _THREAD is not None:
        return _THREAD
    with _THREAD_LOCK:
        if _THREAD is not None:
            return _THREAD
        _THREAD = _build_thread()
        return _THREAD


def _reset_thread_if(owner):
    """Reset the singleton only if it still refers to OWNER.

    Concurrent /chat requests share the lazily-built singleton; if
    request A finishes and unconditionally clears `_THREAD`, request B
    might still be mid-stream against that same Thread instance — and
    request C arriving next would build a fresh Thread, leaving two
    Threads alive concurrently.  Guarding the reset on ownership means
    finishing requests only clear their own singleton; later requests
    arriving while another is still mid-stream skip the reset cleanly.
    """
    global _THREAD
    with _THREAD_LOCK:
        if _THREAD is owner:
            log.warning("Resetting assist.Thread singleton (thread_id=%s)",
                        _THREAD.thread_id)
            _THREAD = None


def _start_stream_iter(message: str):
    """Sync helper invoked via run_in_executor: get the singleton
    Thread and start the stream_message iterator.  Returns a tuple
    `(thread, iterator)` so the caller can later reset the singleton
    via `_reset_thread_if(thread)` without race-ing other requests."""
    t = _get_thread()
    return t, iter(t.stream_message(message))


async def _stream_turn(message: str, request: Request) -> AsyncIterator[bytes]:
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
    my_thread = None
    # NOTE: `runaway_at` is set AFTER acquiring `_STREAM_LOCK` below;
    # otherwise a long wait behind the lock would burn the budget
    # before we'd even started this stream's actual work.
    runaway_at = float("inf")

    yield ndjson.event("start", stream_id=stream_id, ts=time.time())

    # Single-flight: serialize the body of the stream so two /chat
    # coroutines can't accumulate parallel Thread instances under
    # contention.  Acquire BEFORE the try so the corresponding release
    # in finally always pairs cleanly; `start` is yielded *before*
    # acquire so queued clients still see an immediate ack of receipt.
    await _STREAM_LOCK.acquire()
    try:
        # `runaway_at` is set HERE (not before the lock acquire) so a
        # long wait behind the lock doesn't burn the budget before
        # we've even started.  Inside the try so the finally is the
        # exclusive release path.
        runaway_at = time.monotonic() + RUNAWAY_SECONDS
        # Move singleton construction onto the executor so the
        # async handler isn't blocked by it.  This is also the
        # only place an ASSIST_MODEL_URL misconfig can raise.
        my_thread, it = await loop.run_in_executor(None, _start_stream_iter, message)
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
        # so GC closes it (releasing THREAD_QUEUE via __exit__) and
        # clears the singleton so the next /chat builds fresh.
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
        # Only clear the singleton if it still belongs to us; protects
        # in-flight concurrent /chat requests from losing their Thread
        # reference mid-stream (see `_reset_thread_if` docstring).
        if my_thread is not None:
            _reset_thread_if(my_thread)
        # Release the single-flight lock so the next queued /chat can
        # proceed.  Always paired with the acquire above this try block.
        _STREAM_LOCK.release()


@app.post("/chat")
async def chat(req: ChatRequest, request: Request):
    log.info("POST /chat msg=%r", req.message)
    return StreamingResponse(
        _stream_turn(req.message, request),
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
