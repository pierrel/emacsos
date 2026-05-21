"""Apply an agent.el body to the live phone + classify the outcome.

Transport: send the file CONTENTS as an elisp string over the existing
emacsclient channel (no scp — one transport, one auth path).  The
phone writes a temp file in the target dir, atomically renames it over
agent.el, then `load-file`s it — all inside one `condition-case` so a
broken config comes back as a *value* (`load-error: ...`, exit 0),
distinct from an unreachable phone (call_emacs exit != 0).

The phone owns the agent.el path: the apply expr reads
`emacos-agent-file` (a defvar the boot snippet sets) with a hardcoded
fallback, so the server constant and the boot path can't silently
diverge.  Design doc: docs/2026-05-21-config-apply-rollback.org.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import TYPE_CHECKING, Literal

from . import phone as phone_mod
from .config import Config

if TYPE_CHECKING:  # avoid a channel<->apply import cycle at runtime
    from .channel import PhoneContext

log = logging.getLogger(__name__)

# Read env once at import (matching channel._CONFIG / app.config) rather
# than re-parsing on every apply — `emacsclient` is server-wide config
# that doesn't vary per call.
_CONFIG = Config.from_env()

# Matches channel.EVAL_TIMEOUT_SECONDS; defined locally so apply.py
# doesn't import channel (which imports apply) — see the cycle note.
APPLY_TIMEOUT_SECONDS = 15.0

# Default phone path, matched by the boot snippet's `emacos-agent-file`
# defvar (deploy/emacsos-init.el.in).  The apply expr prefers the
# phone-side defvar and only falls back to this literal.
DEFAULT_PHONE_AGENT_FILE = "~/.emacs.d/emacsos/agent.el"

# Refuse to ship a config so large it'd overflow the emacsclient argv
# (which would surface as an opaque "unreachable" failure).  Far above
# any realistic single-file config.
MAX_BODY_BYTES = 100_000


@dataclass(frozen=True)
class ApplyResult:
    status: Literal["applied", "load_error", "unreachable", "too_large"]
    detail: str


def _elisp_string(s: str) -> str:
    """Encode a Python str as an elisp double-quoted string literal."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _build_apply_expr(body: str) -> str:
    """Elisp that atomically writes BODY to the phone's agent file and
    loads it, returning `"ok: loaded"` or `"load-error: <...>"`."""
    body_lit = _elisp_string(body)
    return f"""(condition-case err
    (let ((f (expand-file-name (or (bound-and-true-p emacos-agent-file)
                                   {_elisp_string(DEFAULT_PHONE_AGENT_FILE)})))
          (body {body_lit}))
      (make-directory (file-name-directory f) t)
      (let ((tmp (make-temp-file (file-name-directory f) nil ".el")))
        (with-temp-file tmp (insert body))
        (rename-file tmp f t))
      (load-file f)
      "ok: loaded")
  (error (format "load-error: %S" err)))"""


def apply_to_phone(ctx: PhoneContext, body: str) -> ApplyResult:
    """Write+load BODY on the phone, classify the outcome honestly."""
    if len(body.encode("utf-8")) > MAX_BODY_BYTES:
        return ApplyResult(
            status="too_large",
            detail=f"config is {len(body)} bytes; max {MAX_BODY_BYTES}",
        )
    expr = _build_apply_expr(body)
    try:
        ok, output = phone_mod.call_emacs(
            ctx.auth_contents,
            ctx.phone_host,
            expr,
            emacsclient=_CONFIG.emacsclient,
            timeout=APPLY_TIMEOUT_SECONDS,
        )
    except Exception as e:  # noqa: BLE001 — surface as a structured result
        log.exception("apply_to_phone raised")
        return ApplyResult(status="unreachable", detail=f"{type(e).__name__}: {e}")

    if ok:
        # call_emacs succeeded; the value is our wrapper's return.
        if output.startswith("load-error:"):
            return ApplyResult(status="load_error", detail=output)
        return ApplyResult(status="applied", detail=output)
    # call_emacs itself failed.
    if phone_mod.is_unreachable(output):
        return ApplyResult(status="unreachable", detail=output)
    # A non-unreachable call_emacs failure is unusual here (the expr
    # always returns a string on a reachable phone); treat as load_error
    # so it's reported as broken-config rather than infra.
    return ApplyResult(status="load_error", detail=output)
