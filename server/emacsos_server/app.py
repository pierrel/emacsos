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

# One Thread, one ongoing conversation, every /chat extends it.
# Lazy construction.  Reset on stream end / abort / error / runaway
# so the next /chat builds fresh and doesn't queue behind a stale
# in-flight agent thread.  Same shape as PR #6's _reset_thread()
# pattern, just driven by more event types.
_THREAD = None
_THREAD_LOCK = threading.Lock()

# Heartbeat: emit a `heartbeat` event every N seconds of silence so
# long tool runs don't look like a dead connection.  Spike showed
# tool-call args stream as `tool_call_chunks` (no `content`) and
# sub-agent execution is opaque from the top-level stream, so
# silent periods between status events are routine on research-
# shaped prompts.
HEARTBEAT_SECONDS = 10.0

# Runaway backstop: reset the singleton after this many seconds
# of the same stream so a truly-stuck agent doesn't pin the server
# until process restart.  Far longer than any legitimate research
# prompt; the user can always ABORT sooner.
RUNAWAY_SECONDS = 30 * 60.0


def _build_thread():
    from assist.thread import Thread
    working_dir = tempfile.mkdtemp(prefix="emacsos-thread-")
    log.info("Constructing assist.Thread (working_dir=%s)", working_dir)
    t = Thread(working_dir=working_dir, sandbox_backend=None)
    log.info("assist.Thread ready (thread_id=%s)", t.thread_id)
    return t


def _get_thread():
    global _THREAD
    if _THREAD is not None:
        return _THREAD
    with _THREAD_LOCK:
        if _THREAD is not None:
            return _THREAD
        _THREAD = _build_thread()
        return _THREAD


def _reset_thread():
    global _THREAD
    with _THREAD_LOCK:
        if _THREAD is not None:
            log.warning("Resetting assist.Thread singleton (thread_id=%s)",
                        _THREAD.thread_id)
            _THREAD = None


def _start_stream_iter(message: str):
    """Sync helper invoked via run_in_executor: get the singleton
    Thread and start the stream_message iterator."""
    return iter(_get_thread().stream_message(message))


async def _stream_turn(message: str, request: Request) -> AsyncIterator[bytes]:
    """The async generator that drives one chat turn.  Bridges
    assist's sync iterator via run_in_executor and polls
    is_disconnected() between yields so client ABORT fires the
    finally cleanly.  See design doc §4 for the cancellation chain."""
    loop = asyncio.get_event_loop()
    SENTINEL = object()
    stream_id = uuid.uuid4().hex
    full_text_parts: list[str] = []
    seen_tool_ids: set[str] = set()
    it = None
    runaway_at = time.monotonic() + RUNAWAY_SECONDS

    yield ndjson.event("start", stream_id=stream_id, ts=time.time())

    try:
        # Move singleton construction onto the executor so the
        # async handler isn't blocked by it.  This is also the
        # only place an ASSIST_MODEL_URL misconfig can raise.
        it = await loop.run_in_executor(None, _start_stream_iter, message)
        pending = None
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
                pending = asyncio.ensure_future(
                    loop.run_in_executor(None, next, it, SENTINEL))
            done, _ = await asyncio.wait([pending], timeout=HEARTBEAT_SECONDS)
            if not done:
                # Inner iter has produced nothing in HEARTBEAT_SECONDS;
                # keep the pipe live and try again (don't cancel pending —
                # next loop will re-await it).
                yield ndjson.event("heartbeat", ts=time.time())
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
        if it is not None:
            try:
                it.close()
            except ValueError:
                # "generator already executing" — agent thread is
                # still active on its worker.  GC will close once
                # the agent yields/returns; nothing else to do.
                pass
            except Exception:
                log.exception("error closing inner iterator")
        _reset_thread()


@app.post("/chat")
async def chat(req: ChatRequest, request: Request):
    log.info("POST /chat msg=%r", req.message)
    return StreamingResponse(
        _stream_turn(req.message, request),
        media_type="application/x-ndjson",
    )


def main() -> None:
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=config.port)


if __name__ == "__main__":
    main()
