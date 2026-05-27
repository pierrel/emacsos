"""EmacsBackend — a deepagents SandboxBackendProtocol whose "sandbox" is the
phone's emacs daemon, reached over ``emacsclient``.

This is what lets a ``.assist`` file-chat read/edit/run files in its
directory *on the phone, in place* — the assist-cli experience without a
container.  It mirrors ``assist.sandbox.DockerSandboxBackend`` exactly: that
class subclasses deepagents' ``BaseSandbox`` and implements only
``execute()`` (commands run via ``container.exec_run``); ``read/write/edit/
ls/grep/glob`` are inherited from ``BaseSandbox``, which builds ordinary
shell commands (cat, ls, grep, sed, ...) and runs them through ``execute``.
We do the same, but ``execute`` runs the command in the phone's shell via an
elisp ``call-process-shell-command`` evaluated by ``emacsclient``.

IMPORTANT — this is NOT a sandbox in the containment sense (see
docs/2026-05-27-file-backed-chat.org §Security).  ``execute`` runs a real,
unconfined shell on the phone: full network, full filesystem, destructive
commands.  The working-dir prefixing in ``_resolve`` and the ``.assist``
refusal are guardrails for the agent's *file tools* (so they don't wander
out of the directory or clobber the transcript), NOT a security boundary —
``execute`` ignores them.  This is the deliberate full-trust v1 posture
(the phone holds nothing sensitive yet); real containment is deferred.
"""

import base64
import logging
import os
import shlex

from deepagents.backends.sandbox import BaseSandbox
from deepagents.backends.protocol import (
    ExecuteResponse,
    FileDownloadResponse,
    FileUploadResponse,
)

log = logging.getLogger(__name__)

MAX_OUTPUT_CHARS = 100_000

# Wall-clock cap on a single command (coreutils `timeout` on the phone).
# The phone is a Zero 2 W (512 MB) — this is "edit + light run", not a build
# farm.  The eval transport (call_emacs) MUST allow at least this long, or
# the emacsclient round trip times out before the command finishes (the
# wiring in _build_thread is responsible for that).
EXEC_TIMEOUT_SECONDS = int(os.getenv("EMACSOS_EXEC_TIMEOUT", "60"))
EXEC_KILL_GRACE_SECONDS = 5


def _elisp_str(s: str) -> str:
    """Escape S for embedding inside an elisp double-quoted string literal."""
    return s.replace("\\", "\\\\").replace('"', '\\"')


class EmacsBackend(BaseSandbox):
    """SandboxBackendProtocol backed by the phone's emacs daemon.

    Args:
        work_dir: the conversation's working directory ON THE PHONE (the
            ``.assist`` file's directory).  Paths from the agent are resolved
            under it.
        eval_elisp: callable ``(elisp: str) -> tuple[bool, str]`` that
            evaluates ELISP on the phone and returns ``(ok, raw_output)`` —
            in practice a partial of ``phone.call_emacs`` bound to the
            request's phone context.  Injected (not hard-wired to call_emacs)
            so the backend is unit-testable without a phone.
    """

    def __init__(self, work_dir: str, eval_elisp, *,
                 timeout: int = EXEC_TIMEOUT_SECONDS):
        self.work_dir = (work_dir or "/").rstrip("/") or "/"
        self._eval = eval_elisp
        self._timeout = timeout

    @property
    def id(self) -> str:
        return f"emacs:{self.work_dir}"

    # --- the one method that talks to the phone -----------------------------

    def execute(self, command: str, *, timeout: int | None = None) -> ExecuteResponse:
        """Run COMMAND in the phone's shell, rooted at ``work_dir``.

        Wrapped in coreutils ``timeout`` so a runaway can't pin the phone's
        emacs.  The command's combined stdout+stderr and exit code are
        base64-encoded inside elisp before being returned, so arbitrary bytes
        (newlines, quotes, non-UTF-8) survive ``emacsclient``'s result
        printing intact — we just strip the surrounding quotes and decode.
        """
        # Cap every command at the backend max regardless of the agent's
        # requested timeout (deepagents exposes one, up to 3600s).  The phone
        # is weak + full-trust "light run", and — crucially — the emacsclient
        # transport timeout is a fixed margin above EXEC_TIMEOUT_SECONDS, so a
        # larger command timeout would let the command outlive the transport
        # and orphan a process on the daemon.  None / <=0 (the tool's
        # "no timeout") => the default cap, not unbounded.
        t = (self._timeout if (timeout is None or timeout <= 0)
             else min(timeout, self._timeout))
        bounded = (
            f"timeout --kill-after={EXEC_KILL_GRACE_SECONDS}s {t}s "
            f"sh -c {shlex.quote(command)} 2>&1"
        )
        elisp = (
            f'(let ((default-directory "{_elisp_str(self.work_dir)}/"))'
            f'  (with-temp-buffer'
            f'    (let ((code (call-process-shell-command "{_elisp_str(bounded)}" nil t)))'
            f'      (base64-encode-string'
            f'        (encode-coding-string'
            f'          (concat (number-to-string (if (integerp code) code -1)) "\\n"'
            f'                  (buffer-string))'
            f"          'utf-8)"
            f"        t))))"
        )
        try:
            ok, raw = self._eval(elisp)
        except Exception as e:  # noqa: BLE001 — surface transport failure as a result
            log.exception("EmacsBackend.execute: eval transport failed")
            return ExecuteResponse(output=f"emacs backend error: {e}", exit_code=1)
        if not ok:
            return ExecuteResponse(output=f"emacs backend error: {raw}", exit_code=1)

        exit_code, output = self._decode(raw)

        if exit_code in (124, 137):  # `timeout` SIGTERM / SIGKILL
            output = (f"[command exceeded {t}s wall-clock limit on the phone; "
                      f"narrow its scope and retry]\n") + (output or "(no output)")

        truncated = len(output) > MAX_OUTPUT_CHARS
        if truncated:
            output = output[:MAX_OUTPUT_CHARS] + "\n... [output truncated]"
        return ExecuteResponse(output=output, exit_code=exit_code, truncated=truncated)

    @staticmethod
    def _decode(raw: str) -> tuple[int, str]:
        """Parse the base64 payload emacsclient printed for execute().

        emacsclient prints the elisp string result as ``"<base64>"`` — the
        base64 alphabet has no quote/backslash, so there's no internal
        escaping; strip the surrounding quotes and decode.  The decoded text
        is ``<exit_code>\\n<output>``."""
        s = raw.strip()
        if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
            s = s[1:-1]
        try:
            text = base64.b64decode(s).decode("utf-8", errors="replace")
        except Exception:  # noqa: BLE001 — malformed payload: surface raw
            return 1, f"emacs backend: could not decode result: {raw[:200]}"
        head, _, body = text.partition("\n")
        try:
            return int(head), body
        except ValueError:
            return 1, text

    # --- path resolution: a guardrail for the file tools (NOT execute) ------

    def _resolve(self, path: str | None) -> str:
        """Prefix PATH with ``work_dir`` (mirrors DockerSandboxBackend), and
        guard the agent's *file tools* against escaping the directory or
        touching transcripts.  Raises ``ValueError`` (surfaced to the model as
        a tool error) on a ``..`` segment or a ``.assist`` path.  NOTE: this
        confines only the fs tools; ``execute`` runs an unconfined shell."""
        if not path:
            path = "/"
        if ".." in path.split("/"):
            raise ValueError(f"path escapes the working directory: {path!r}")
        if path.rstrip("/").endswith(".assist"):
            raise ValueError(
                ".assist transcript files are managed by the chat UI; "
                "the agent can't read or modify them")
        # Already rooted?  Require a separator boundary so a sibling whose name
        # merely extends work_dir's (e.g. /data/projevil vs /data/proj) isn't
        # mistaken for "already under" and returned unprefixed.
        if path == self.work_dir or path.startswith(self.work_dir + "/"):
            return path
        return self.work_dir + (path if path.startswith("/") else "/" + path)

    def ls(self, path: str = "/"):
        return super().ls(self._resolve(path))

    def read(self, file_path: str, offset: int = 0, limit: int = 2000):
        return super().read(self._resolve(file_path), offset, limit)

    def write(self, file_path: str, content: str):
        return super().write(self._resolve(file_path), content)

    def edit(self, file_path: str, old_string: str, new_string: str,
             replace_all: bool = False):
        return super().edit(self._resolve(file_path), old_string, new_string,
                            replace_all)

    def grep(self, pattern: str, path: str | None = None, glob: str | None = None):
        return super().grep(pattern, self._resolve(path or "/"), glob)

    def glob(self, pattern: str, path: str = "/"):
        return super().glob(pattern, self._resolve(path))

    # --- bulk transfer (not the hot path; implemented via execute) ----------

    def upload_files(self, files: list[tuple[str, bytes]]) -> list[FileUploadResponse]:
        out: list[FileUploadResponse] = []
        for path, content in files:
            try:
                resolved = self._resolve(path)
                b64 = base64.b64encode(content).decode("ascii")
                cmd = (f"mkdir -p {shlex.quote(os.path.dirname(resolved) or '/')} && "
                       f"printf %s {shlex.quote(b64)} | base64 -d > {shlex.quote(resolved)}")
                resp = self.execute(cmd)
                out.append(FileUploadResponse(path=path)
                           if resp.exit_code == 0
                           else FileUploadResponse(path=path, error="permission_denied"))
            except ValueError as e:
                out.append(FileUploadResponse(path=path, error=str(e)))
        return out

    def download_files(self, paths: list[str]) -> list[FileDownloadResponse]:
        out: list[FileDownloadResponse] = []
        for path in paths:
            try:
                resolved = self._resolve(path)
                resp = self.execute(f"base64 {shlex.quote(resolved)}")
                if resp.exit_code != 0:
                    out.append(FileDownloadResponse(path=path, error="file_not_found"))
                    continue
                content = base64.b64decode(resp.output.strip())
                out.append(FileDownloadResponse(path=path, content=content))
            except Exception as e:  # noqa: BLE001 — _resolve ValueError or decode/transport failure
                out.append(FileDownloadResponse(path=path, error=str(e)))
        return out
