"""Unit tests for apply.py — transport expr + honesty classification."""
from __future__ import annotations

from unittest.mock import patch

from emacsos_server.apply import (
    MAX_BODY_BYTES,
    _build_apply_expr,
    _elisp_string,
    apply_to_phone,
)
from emacsos_server.channel import PhoneContext

_CTX = PhoneContext(auth_contents="0.0.0.0:1234 5\nsec\n", phone_host="10.0.0.5")


def _patch_call_emacs(retval):
    return patch("emacsos_server.apply.phone_mod.call_emacs", return_value=retval)


# --- elisp string encoding ---

def test_elisp_string_escapes_quotes_and_backslashes():
    assert _elisp_string('a"b\\c') == '"a\\"b\\\\c"'


def test_build_apply_expr_uses_phone_defvar_and_loads():
    expr = _build_apply_expr("(setq foo 1)")
    assert "emacos-agent-file" in expr          # phone owns the path
    assert "rename-file" in expr                 # atomic write
    assert "load-file" in expr
    assert "emacos-agent-config-applied-function" in expr
    assert "indirect-function" in expr
    assert "funcall finalizer" in expr
    assert "finalizer-failure" in expr
    assert "unwind-protect" in expr
    assert "(t (setq load-failure caught))" in expr
    assert expr.index("(funcall finalizer)") < expr.index(
        "(setq emacos-agent-config-applied-function"
    )
    assert "load-error: config-load:" in expr
    assert "load-error: platform-finalizer:" in expr
    assert "apply-error:" in expr
    assert "load-error" in expr                  # honesty wrapper
    assert "(setq foo 1)" in expr                # body embedded


# --- classification ---
# call_emacs returns Emacs' PRINTED form; a string result comes back
# QUOTED (verified live: `emacsclient -e '"x"'` prints `"x"`).  The
# mocks below use the quoted form to match the real wire — apply.py must
# strip the read-syntax quotes before classifying, or a quoted
# "load-error: ..." gets misread as applied.

def test_apply_ok_is_applied():
    with _patch_call_emacs((True, '"ok: loaded"')):
        r = apply_to_phone(_CTX, "(setq foo 1)")
    assert r.status == "applied"
    assert r.detail == "ok: loaded"  # quotes stripped


def test_apply_load_error_is_load_error():
    with _patch_call_emacs((True, '"load-error: (void-function foo)"')):
        r = apply_to_phone(_CTX, "(foo)")
    assert r.status == "load_error"
    assert "void-function" in r.detail
    assert not r.detail.startswith('"')  # quotes stripped


def test_apply_unquoted_result_still_classifies():
    # Defensive: if a result ever arrives unquoted, classification still
    # works (the strip is conditional on surrounding quotes).
    with _patch_call_emacs((True, "load-error: boom")):
        r = apply_to_phone(_CTX, "(foo)")
    assert r.status == "load_error"


def test_apply_error_is_not_classified_as_received():
    with _patch_call_emacs((True, '"apply-error: (file-error denied)"')):
        r = apply_to_phone(_CTX, "(setq foo 1)")
    assert r.status == "apply_error"
    assert "file-error" in r.detail


def test_apply_unreachable_classified():
    with _patch_call_emacs((False, "emacsclient: connect: Connection refused")):
        r = apply_to_phone(_CTX, "(setq foo 1)")
    assert r.status == "unreachable"


def test_apply_timeout_is_unconfirmed():
    with _patch_call_emacs((False, "emacsclient timed out after 15.0s")):
        r = apply_to_phone(_CTX, "(setq foo 1)")
    assert r.status == "apply_error"


def test_apply_empty_nonzero_exit_is_unconfirmed():
    with _patch_call_emacs((False, "exit 1")):
        r = apply_to_phone(_CTX, "(setq foo 1)")
    assert r.status == "apply_error"


def test_apply_oversize_body_rejected():
    big = "x" * (MAX_BODY_BYTES + 1)
    r = apply_to_phone(_CTX, big)
    assert r.status == "too_large"


def test_apply_unexpected_exception_is_unconfirmed():
    with patch("emacsos_server.apply.phone_mod.call_emacs",
               side_effect=OSError("[Errno 24] Too many open files")):
        r = apply_to_phone(_CTX, "(setq foo 1)")
    assert r.status == "apply_error"
