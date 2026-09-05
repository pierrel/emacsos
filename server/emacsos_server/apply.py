"""Apply a rendered agent.el file to the live phone and classify the outcome.

Transport: send the file CONTENTS as an elisp string over the existing
emacsclient channel (no scp — one transport, one auth path).  The
phone writes a temp file in the target dir, atomically renames it over
agent.el, then `load-file`s it and runs the optional platform finalizer that was
registered before the load.  The whole operation returns failures as
a *value* (`load-error: ...` or `apply-error: ...`, exit 0).  Failures proven
to occur before dispatch are unreachable; timeout and other ambiguous
post-dispatch failures are apply errors because the saved-file state is unknown.

The phone owns the agent.el path: the apply expr reads
`emacos-agent-file` (a defvar the boot snippet sets) with a hardcoded
fallback, so the server constant and the boot path can't silently
diverge.  Original design: docs/2026-05-21-config-apply-rollback.org.
PinePhone finalizer: docs/2026-09-03-pinephone-assist-parity.org.
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
    status: Literal[
        "applied", "load_error", "apply_error", "unreachable", "too_large"
    ]
    detail: str


def _elisp_string(s: str) -> str:
    """Encode a Python str as an elisp double-quoted string literal."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _build_apply_expr(content: str) -> str:
    """Elisp that atomically writes the agent.el CONTENT to the phone's
    agent file, loads it, and runs the phone's optional
    `emacos-agent-config-applied-function`, returning `"ok: loaded"`,
    `"load-error: <...>"`, or `"apply-error: <...>"`.  CONTENT is the full
    candidate file (header carrying the `lexical-binding` cookie + body +
    provide) produced by `config_repo.render`.  A confirmed-and-recorded
    operation stores those same bytes in git.  The platform
    finalizer is captured as a function object before the load and run before
    its variable is restored.  Agent config remains full-trust Elisp, not a
    security boundary."""
    content_lit = _elisp_string(content)
    return f"""(condition-case err
    (let* ((f (expand-file-name (or (bound-and-true-p emacos-agent-file)
                                    {_elisp_string(DEFAULT_PHONE_AGENT_FILE)})))
           (content {content_lit})
           (raw-finalizer
            (and (boundp 'emacos-agent-config-applied-function)
                 emacos-agent-config-applied-function))
           (finalizer
            (if (symbolp raw-finalizer)
                (indirect-function raw-finalizer)
              raw-finalizer))
           (load-failure nil)
           (finalizer-failure nil))
      (make-directory (file-name-directory f) t)
      (let ((tmp (make-temp-file (concat (file-name-directory f) "agent-") nil ".el")))
        (with-temp-file tmp (insert content))
        (rename-file tmp f t))
      (unwind-protect
          (condition-case caught
              (load-file f)
            (t (setq load-failure caught)))
        (when finalizer
          (condition-case caught
              (funcall finalizer)
            (t (setq finalizer-failure caught))))
        (condition-case caught
            (setq emacos-agent-config-applied-function finalizer)
          (t
           (unless finalizer-failure
             (setq finalizer-failure caught)))))
      (cond ((and load-failure finalizer-failure)
             (format (concat "load-error: config-load: %S; "
                             "platform-finalizer: %S")
                     load-failure finalizer-failure))
            (load-failure
             (format "load-error: config-load: %S" load-failure))
            (finalizer-failure
             (format "load-error: platform-finalizer: %S"
                     finalizer-failure))
            (t "ok: loaded")))
  (t (format "apply-error: %S" err)))"""


def apply_to_phone(ctx: PhoneContext, content: str) -> ApplyResult:
    """Write and load agent.el, run platform finalizers, and classify honestly.
    CONTENT is the rendered candidate file (see `config_repo.render`), not the
    bare body.  A caller may record the same bytes after a confirmed write."""
    n_bytes = len(content.encode("utf-8"))
    if n_bytes > MAX_BODY_BYTES:
        return ApplyResult(
            status="too_large",
            detail=f"config is {n_bytes} bytes; max {MAX_BODY_BYTES}",
        )
    expr = _build_apply_expr(content)
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
        return ApplyResult(status="apply_error", detail=f"{type(e).__name__}: {e}")

    if ok:
        # call_emacs returns Emacs' PRINTED representation; our expr
        # returns a string, so it arrives quoted (`"ok: loaded"`,
        # `"load-error: ..."`, or `"apply-error: ..."`).  Strip the
        # surrounding read-syntax quotes before the prefix check — otherwise
        # a load failure starts with `"` and gets misclassified as `applied`.
        text = (output[1:-1]
                if len(output) >= 2 and output[0] == '"' == output[-1]
                else output)
        if text.startswith("apply-error:"):
            return ApplyResult(status="apply_error", detail=text)
        if text.startswith("load-error:"):
            return ApplyResult(status="load_error", detail=text)
        return ApplyResult(status="applied", detail=text)
    # call_emacs itself failed.
    # Timeout and an unclassified non-zero exit may occur after Emacs began
    # evaluating the expression, so the saved-file state is unconfirmed.
    if "timed out" in output or output.startswith("exit "):
        return ApplyResult(status="apply_error", detail=output)
    if (output.startswith("auth file:")
            or output.startswith("emacsclient binary not found:")
            or output.startswith("[Errno ")
            or output.startswith("emacsclient: connect:")):
        return ApplyResult(status="unreachable", detail=output)
    # A non-unreachable call_emacs failure gives no proof that the atomic
    # rename completed, so it must not enter the commit-after-receipt path.
    return ApplyResult(status="apply_error", detail=output)
