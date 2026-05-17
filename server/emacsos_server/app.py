"""FastAPI app for the chat endpoint.

POST /chat: either echoes (LLM-disabled mode) or invokes assist's
agent (LLM-enabled mode), then fires a single ``(message ...)`` on
the phone via emacsclient to confirm the back-channel.

See docs/2026-05-17-assist-import.org for the experiment plan and
the decisions behind the LLM-disabled flag, the lazy Thread
singleton, the timeout shape, and the post-response back-channel
flash format.
"""
from __future__ import annotations

import logging
import os
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeoutError
from typing import Optional

from fastapi import FastAPI, Request
from pydantic import BaseModel

from .config import Config
from .phone import call_emacs

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("emacsos_server")

app = FastAPI(title="emacsos-server", version="0.1.0")
config = Config.from_env()


class PhoneAuth(BaseModel):
    auth_file: str


class ChatRequest(BaseModel):
    message: str
    phone: Optional[PhoneAuth] = None


class ChatResponse(BaseModel):
    text: str
    side_effect: Optional[str] = None


# --- assist Thread singleton (lazy, process-wide) ---

# One Thread, one ongoing conversation, every /chat extends it.
# Lazy construction: the server boots even when ASSIST_MODEL_URL isn't
# yet pointed at a live endpoint; first /chat in LLM mode triggers
# construction.  Lock-guarded so two concurrent first-requests don't
# double-construct.  See design doc §3 + §4.
_THREAD = None
_THREAD_LOCK = threading.Lock()

# Server-internal timeout for the agent call.  30s under the
# chat.el client timeout of 300s (design doc §9) so the server
# returns a clean error message before the client gives up.
AGENT_TIMEOUT_SECONDS = 270

# One worker is enough: assist's per-thread queue already serialises
# LLM calls on the same thread id, and we only have one thread.
# Workers > 1 would create contention without parallelism.
#
# Known limitation: `future.result(timeout=…)` unblocks the caller on
# timeout, but the underlying Python thread keeps running until the
# agent returns (Python threads aren't externally cancellable).  A
# runaway agent therefore leaks one thread per timeout until the
# process exits.  Acceptable for v1 (one-thread singleton, manual
# server restart on bad state); revisit if we ever expect concurrent
# runaway calls.
_AGENT_EXECUTOR = ThreadPoolExecutor(max_workers=1, thread_name_prefix="emacsos-agent")


def _llm_enabled() -> bool:
    """LLM mode is on iff ASSIST_MODEL_URL is set AND
    EMACSOS_LLM_DISABLED is not set to a truthy value.  Either gate
    being closed falls back to the echo path (design doc §11)."""
    if os.environ.get("EMACSOS_LLM_DISABLED", "").lower() in ("1", "true", "yes", "on"):
        return False
    return bool(os.environ.get("ASSIST_MODEL_URL"))


def _get_thread():
    """Lazy-construct the singleton Thread.  Raises whatever assist
    raises during construction (model probe failure, etc.); callers
    must catch."""
    global _THREAD
    if _THREAD is not None:
        return _THREAD
    with _THREAD_LOCK:
        if _THREAD is not None:
            return _THREAD
        # Import inside the lock so module import doesn't trigger
        # assist's transitive imports during server startup.
        from assist.thread import Thread

        working_dir = tempfile.mkdtemp(prefix="emacsos-thread-")
        # sandbox_backend=None (design doc §5); model=None lets Thread
        # call select_chat_model itself which reads ASSIST_MODEL_URL.
        log.info("Constructing assist.Thread (working_dir=%s)", working_dir)
        _THREAD = Thread(working_dir=working_dir, sandbox_backend=None)
        log.info("assist.Thread ready (thread_id=%s)", _THREAD.thread_id)
        return _THREAD


def _run_agent(message: str) -> str:
    """Run one agent turn under the inner timeout.  Returns the bot
    text, or raises an exception type the caller maps to an error
    string."""
    thread = _get_thread()
    future = _AGENT_EXECUTOR.submit(thread.message, message)
    return future.result(timeout=AGENT_TIMEOUT_SECONDS)


def _agent_text(message: str) -> str:
    """Catch-all wrapper around `_run_agent`.  Returns the bot text on
    success; on any exception returns a chat-recognisable error
    string.  Design doc §10 — two specific carve-outs for the most
    common operator-facing errors, catch-all for everything else."""
    try:
        return _run_agent(message)
    except FutureTimeoutError:
        log.warning("Agent timed out after %ds", AGENT_TIMEOUT_SECONDS)
        return f"[error: agent timed out after {AGENT_TIMEOUT_SECONDS}s]"
    except RuntimeError as e:
        # select_chat_model raises RuntimeError for missing config
        # AND for liveness/probe failures ("could not reach …",
        # "returned no models", etc.).  Narrow the explicit-config
        # case to messages that name the env var; everything else
        # gets a model-unavailable wording so we don't mislabel a
        # liveness failure as a misconfig.
        msg = str(e)
        if "ASSIST_MODEL_URL" in msg:
            log.error("Agent config error: %s", e)
            return f"[error: assist model not configured: {msg}]"
        if "model" in msg.lower():
            log.error("Agent model unavailable: %s", e)
            return f"[error: assist model unavailable: {msg}]"
        log.exception("Agent RuntimeError")
        return f"[error: {msg}]"
    except Exception as e:  # noqa: BLE001 — catch-all is intentional
        log.exception("Agent call failed")
        return f"[error: {type(e).__name__}: {e}]"


def _escape_elisp_string(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _flash_text(reply: str) -> str:
    """Format `reply` for a one-line phone minibuffer flash.

    Newlines collapse to spaces; the *reply portion* is capped at 60
    chars (the `agent: ` prefix is always shown in full).  Total
    flash is therefore up to ~67 chars — comfortable for the phone's
    minibuffer.  Design doc §12."""
    one_line = reply.replace("\n", " ").strip()
    if len(one_line) > 60:
        one_line = one_line[:57] + "..."
    return f"agent: {one_line}"


# Sync (not async): the agent call + emacsclient call both block.
# A sync handler lets FastAPI run us in its threadpool so we don't
# stall the event loop for unrelated requests.
@app.post("/chat", response_model=ChatResponse)
def chat(req: ChatRequest, request: Request) -> ChatResponse:
    if _llm_enabled():
        log.info("POST /chat msg=%r mode=llm", req.message)
        text = _agent_text(req.message)
        flash = _flash_text(text)
    else:
        log.info("POST /chat msg=%r mode=echo", req.message)
        text = f"echo: {req.message}"
        flash = f"saw: {req.message}"

    side_effect: Optional[str] = None

    if req.phone is not None and request.client is not None:
        phone_host = request.client.host
        expr = f"(message {_escape_elisp_string(flash)})"
        ok, output = call_emacs(
            req.phone.auth_file,
            phone_host,
            expr,
            emacsclient=config.emacsclient,
        )
        if ok:
            side_effect = f"messaged the phone at {phone_host}"
        else:
            log.warning("emacsclient call failed: %s", output)

    return ChatResponse(text=text, side_effect=side_effect)


def main() -> None:
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=config.port)


if __name__ == "__main__":
    main()
