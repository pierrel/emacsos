"""NDJSON event encoding + LangGraph chunk → user-visible status mapping.

The wire format is one JSON object per line (no SSE framing).  Each
event is `(json.dumps({"type": <type>, ...}) + "\\n").encode("utf-8")`
ready for `StreamingResponse` to push.  See
docs/2026-05-17-streaming-responses.org §3 for the taxonomy.

`render_message_chunk` and `render_update_to_status` are pure
functions that turn LangGraph stream chunks into our taxonomy.  The
stateful "have I emitted a status for this tool_call_id yet?"
tracking lives in `app.py`'s `_stream_turn` (one chat session is one
generator's local scope; no need for a class).
"""
from __future__ import annotations

import json
from typing import Any, Iterable


def event(event_type: str, **fields: Any) -> bytes:
    """Encode a single NDJSON event.  Always ends with `\\n`."""
    payload = {"type": event_type, **fields}
    return (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")


def map_error(exc: BaseException) -> str:
    """Map an exception to a short human-readable reason string for
    the `error` event's `reason` field.  Mirrors PR #6's _agent_text
    error wording so chat.el's renderer doesn't need new cases."""
    if isinstance(exc, RuntimeError):
        msg = str(exc)
        if "ASSIST_MODEL_URL" in msg:
            return f"assist model not configured: {msg}"
        if "model" in msg.lower():
            return f"assist model unavailable: {msg}"
        return msg
    return f"{type(exc).__name__}: {exc}"


def extract_new_tool_calls(messages_chunk: Any) -> Iterable[tuple[str, str]]:
    """From a `messages` stream chunk (a `(AIMessageChunk, metadata)`
    tuple), yield `(tool_call_id, tool_name)` for every tool call
    that has a non-empty `name` field.

    Caller is responsible for de-duplicating across chunks — the
    same tool_call_id appears in many subsequent chunks as args
    stream in via `tool_call_chunks`, but only the first chunk has
    `tool_calls=[{name: ..., id: ...}]` populated; later chunks
    have `tool_calls=[]` and the args land in `tool_call_chunks`
    with the same id.  We yield only when `name` is present so
    callers can use seen-set logic on id alone."""
    try:
        ai_chunk, _meta = messages_chunk
    except (TypeError, ValueError):
        return
    tool_calls = getattr(ai_chunk, "tool_calls", None) or []
    for tc in tool_calls:
        name = tc.get("name") if isinstance(tc, dict) else None
        tc_id = tc.get("id") if isinstance(tc, dict) else None
        if name and tc_id:
            yield (tc_id, name)


def extract_content_text(messages_chunk: Any) -> str:
    """From a `messages` stream chunk, return the AIMessageChunk's
    text content (may be empty).  Returns "" for any chunk we can't
    parse — callers should test for truthiness before emitting a
    token event."""
    try:
        ai_chunk, _meta = messages_chunk
    except (TypeError, ValueError):
        return ""
    content = getattr(ai_chunk, "content", "")
    return content if isinstance(content, str) else ""


def render_update_to_status(update_chunk: Any) -> str | None:
    """Map an `updates` stream chunk to a status string, or None to
    drop.  v1 heuristic: skip every middleware lifecycle event
    (those keys end in 'Middleware.<phase>') and the bare 'model'
    node (LLM call itself — silent), surface anything else as
    'running <node>'.

    The captured spike fixtures (see
    server/tests/fixtures/stream_chunks_research.txt) showed that
    top-level updates expose only middleware lifecycle + 'model'
    node + actual tool/subagent node names.  Filtering as
    described leaves only the interesting ones."""
    if not isinstance(update_chunk, dict):
        return None
    for key in update_chunk:
        # Keys look like '<NodeName>' or '<MiddlewareName>.<phase>'.
        node = key.split(".", 1)[0]
        if node.endswith("Middleware"):
            continue
        if node == "model":
            continue
        return f"running {node}"
    return None
