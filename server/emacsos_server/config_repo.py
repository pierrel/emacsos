"""Git-backed config repo emacsos-server owns end-to-end.

A single file =agent.el= lives in a git repo at ``config_dir``.  The
agent never touches git; the server commits each applied config and
navigates history for rollback.  The server writes to the phone FIRST and
commits only after confirmed atomic replacement, including for undo and
restore.  HEAD is therefore the last server-recorded phone file.  It may lag
the phone after an unconfirmed operation or a commit failure; those results
explicitly require reconciliation before another persistent config change.

Pure git + filesystem; no langgraph/assist imports, so this is
unit-testable against a tmp repo with no mocks.  Design doc:
docs/2026-05-21-config-apply-rollback.org.
"""
from __future__ import annotations

import logging
import os
import re
import subprocess
from dataclasses import dataclass

log = logging.getLogger(__name__)

AGENT_FILE = "agent.el"

# Commit message of the empty-config bootstrap commit.  Not a user-applied
# version — config_history filters it out so the agent isn't offered "restore
# to the scaffold" as a version.
SCAFFOLD_SUMMARY = "scaffold: empty agent config"

# Header + footer wrap the agent-supplied body so agent.el is always a
# loadable feature even when the body is empty (scaffold) — and so the
# whole-file replace on each apply has stable bookends.
_HEADER = ";;; agent.el --- agent-managed emacsos config -*- lexical-binding: t -*-\n;;; Managed by emacsos-server; do not edit by hand.\n\n"
_FOOTER = "\n(provide 'agent)\n;;; agent.el ends here\n"

# Commit identity baked in so commits never depend on (or mutate) the
# operator's global git config.
_GIT_IDENTITY = [
    "-c", "user.email=emacsos@localhost",
    "-c", "user.name=emacsos-server",
]

_LEGACY_SYMBOL = re.compile(
    r"^(?P<keyword>:?)emacos(?P<hyphen>-|\\-)(?=[A-Za-z0-9_\\-])")


def _incomplete_config(detail: str) -> ConfigRepoError:
    return ConfigRepoError(f"incomplete Lisp config: {detail}")


def _skip_string(body: str, index: int) -> int:
    """Return the index just after the string beginning at INDEX."""
    index += 1
    while index < len(body):
        if body[index] == "\\":
            index += 1
            if index >= len(body):
                raise _incomplete_config("unfinished string escape")
        elif body[index] == '"':
            return index + 1
        index += 1
    raise _incomplete_config("unterminated string")


def _skip_block_comment(body: str, index: int) -> int:
    """Return the index just after a nested block comment at INDEX."""
    depth = 1
    index += 2
    while index < len(body):
        if body.startswith("#|", index):
            depth += 1
            index += 2
        elif body.startswith("|#", index):
            depth -= 1
            index += 2
            if depth == 0:
                return index
        else:
            index += 1
    raise _incomplete_config("unterminated block comment")


def _skip_char_component(body: str, index: int) -> int:
    """Return the index after one Emacs Lisp character component."""
    if index >= len(body):
        raise _incomplete_config("missing character literal")
    if body[index] != "\\":
        return index + 1

    index += 1
    if index >= len(body):
        raise _incomplete_config("unfinished character escape")
    marker = body[index]
    if marker in "CMSHA":
        if index + 1 >= len(body) or body[index + 1] != "-":
            raise _incomplete_config("unfinished character modifier")
        return _skip_char_component(body, index + 2)
    if marker == "N":
        if index + 1 >= len(body) or body[index + 1] != "{":
            raise _incomplete_config("malformed named character")
        end = body.find("}", index + 2)
        if end < 0 or end == index + 2:
            raise _incomplete_config("unterminated named character")
        return end + 1
    if marker in "uU":
        count = 4 if marker == "u" else 8
        digits = body[index + 1:index + 1 + count]
        if len(digits) != count or any(c not in "0123456789abcdefABCDEF"
                                       for c in digits):
            raise _incomplete_config("malformed Unicode character")
        return index + 1 + count
    if marker == "x":
        end = index + 1
        while end < len(body) and body[end] in "0123456789abcdefABCDEF":
            end += 1
        if end == index + 1:
            raise _incomplete_config("malformed hexadecimal character")
        return end
    return index + 1


def _skip_char_literal(body: str, index: int) -> int:
    """Return the index just after the character literal beginning at INDEX."""
    return _skip_char_component(body, index + 1)


def migrate_emacos_symbols(body: str) -> str:
    """Return complete BODY with legacy Lisp symbols renamed.

    The caller still owns the confirmed full-body ConfigRepo -> apply_config
    transaction.  This pure transform deliberately does not inspect or write a
    phone file.  It changes only lexical atoms, including an escaped hyphen in
    a symbol, and fails closed before apply on incomplete strings, comments,
    characters, or list/vector delimiters.
    """
    pieces: list[str] = []
    index = 0
    length = len(body)
    delimiters: list[str] = []
    while index < length:
        start = index
        if body[index] == ";":
            index = body.find("\n", index)
            if index < 0:
                pieces.append(body[start:])
                break
            index += 1
            pieces.append(body[start:index])
            continue
        if body.startswith("#|", index):
            index = _skip_block_comment(body, index)
            pieces.append(body[start:index])
            continue
        if body[index] == '"':
            index = _skip_string(body, index)
            pieces.append(body[start:index])
            continue
        if body[index] == "?":
            index = _skip_char_literal(body, index)
            pieces.append(body[start:index])
            continue
        if body[index] in "([":
            delimiters.append(body[index])
            index += 1
            pieces.append(body[start:index])
            continue
        if body[index] in ")]":
            expected = "(" if body[index] == ")" else "["
            if not delimiters or delimiters.pop() != expected:
                raise _incomplete_config("unmatched closing delimiter")
            index += 1
            pieces.append(body[start:index])
            continue
        if body.startswith(",@", index):
            index += 2
            pieces.append(body[start:index])
            continue
        if body[index] in "`,":
            index += 1
            pieces.append(body[start:index])
            continue
        while (index < length and not body[index].isspace() and
               body[index] not in "()[]\";'?"):
            index += 1
        if start == index:
            index += 1
            pieces.append(body[start:index])
        else:
            pieces.append(_LEGACY_SYMBOL.sub(
                lambda match: (
                    f"{match.group('keyword')}emacsos{match.group('hyphen')}"),
                body[start:index]))
    if delimiters:
        raise _incomplete_config("unclosed list or vector")
    return "".join(pieces)


class ConfigRepoError(RuntimeError):
    """A git/fs operation on the config repo failed."""


@dataclass(frozen=True)
class ConfigVersion:
    sha: str
    summary: str
    body: str  # the agent-supplied body (between header and footer)


@dataclass(frozen=True)
class RollbackResult:
    ok: bool
    detail: str


def render(body: str) -> str:
    """The canonical agent.el file content for BODY: header (carrying the
    `lexical-binding: t` cookie) + body + `(provide 'agent)` footer.  This
    is the SINGLE renderer for the file sent to the phone and the file git
    records.  A confirmed-and-recorded apply therefore matches byte for byte
    and the phone loads with lexical-binding (closures behave as in the
    committed file)."""
    return _HEADER + body.strip("\n") + _FOOTER


def _extract_body(full: str) -> str:
    """Inverse of `render`: pull the agent body back out of agent.el."""
    s = full
    if s.startswith(_HEADER):
        s = s[len(_HEADER):]
    if s.endswith(_FOOTER):
        s = s[: -len(_FOOTER)]
    return s.strip("\n")


class ConfigRepo:
    def __init__(self, repo_dir: str):
        self.repo_dir = repo_dir
        self.agent_path = os.path.join(repo_dir, AGENT_FILE)

    # --- git plumbing ---

    def _git(self, *args: str) -> subprocess.CompletedProcess:
        result = subprocess.run(
            ["git", "-C", self.repo_dir, *args],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            raise ConfigRepoError(
                f"git {' '.join(args)} failed: {result.stderr.strip() or result.stdout.strip()}"
            )
        return result

    def _commit_count(self) -> int:
        # rev-list --count HEAD; 0 if no commits / no HEAD yet.
        r = subprocess.run(
            ["git", "-C", self.repo_dir, "rev-list", "--count", "HEAD"],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            return 0
        try:
            return int(r.stdout.strip())
        except ValueError:
            return 0

    # --- lifecycle ---

    def ensure(self) -> None:
        """Idempotent: bring the repo to a clean, usable state.
        - No `.git`: init + scaffold the first commit.
        - `.git` but zero commits (manual `git init` / partial init):
          scaffold so `current()`/`rollback()` have a HEAD.
        - Otherwise: hard-reset index + working tree to HEAD.  This drops
          any staged or dirty state from a prior interrupted write — which
          would otherwise make `git revert` fail with "local changes would
          be overwritten" — and restores `agent.el` if it was deleted out
          of band.  The repo is server-owned; there's no legitimate
          uncommitted work between operations to lose."""
        if not os.path.isdir(os.path.join(self.repo_dir, ".git")):
            os.makedirs(self.repo_dir, exist_ok=True)
            self._git("init", "-q")
            self._scaffold()
            log.info("Initialized config repo at %s", self.repo_dir)
        elif self._commit_count() == 0:
            self._scaffold()
            log.warning("Scaffolded commit-less repo at %s", self.repo_dir)
        else:
            # Use _git (raises ConfigRepoError on failure) — a failed
            # hard reset means a genuinely broken repo, and the callers
            # (apply_config, _do_rollback) catch it into a structured
            # error rather than continuing on a partially-reset repo.
            self._git("reset", "--hard", "-q", "HEAD")
            # Defensive: a hard reset restores tracked files, so agent.el
            # is back unless HEAD genuinely lacks it (shouldn't happen
            # post-scaffold) — scaffold if so.
            if not os.path.isfile(self.agent_path):
                self._scaffold()
                log.warning("Recovered missing agent file in %s", self.repo_dir)

    def _scaffold(self) -> None:
        """Write the empty-config scaffold file and commit it."""
        with open(self.agent_path, "w") as f:
            f.write(render(""))
        self._git("add", AGENT_FILE)
        self._git(*_GIT_IDENTITY, "commit", "-q", "-m", SCAFFOLD_SUMMARY)

    def write_and_commit(self, body: str, summary: str) -> str | None:
        """Replace agent.el's body, commit, and return its sha when readable."""
        self.ensure()
        with open(self.agent_path, "w") as f:
            f.write(render(body))
        self._git("add", AGENT_FILE)
        # If the staged tree is identical to HEAD, do NOT create an empty
        # commit: an empty commit later breaks `git revert` ("revert is
        # now empty" aborts).  Re-applying an identical config is a clean
        # no-op — return the existing HEAD sha.
        no_diff = subprocess.run(
            ["git", "-C", self.repo_dir, "diff", "--cached", "--quiet"],
            capture_output=True,
        ).returncode == 0
        if not no_diff:
            self._git(*_GIT_IDENTITY, "commit", "-q", "-m", summary)
        try:
            return self._git("rev-parse", "HEAD").stdout.strip()
        except Exception:  # noqa: BLE001 — commit already succeeded
            # The commit/no-diff operation already succeeded.  A follow-up
            # metadata read must not be misreported as an unrecorded config.
            log.exception("Config recorded but HEAD sha could not be read")
            return None

    def current(self) -> ConfigVersion:
        self.ensure()
        sha = self._git("rev-parse", "HEAD").stdout.strip()
        summary = self._git("log", "-1", "--format=%s").stdout.strip()
        with open(self.agent_path) as f:
            body = _extract_body(f.read())
        return ConfigVersion(sha=sha, summary=summary, body=body)

    def rollback(self) -> RollbackResult:
        """Record a revert of the last apply as a new commit."""
        self.ensure()
        # Need at least scaffold + one real apply to have something to
        # undo.  rev-list count: 1 == scaffold only.
        if self._commit_count() < 2:
            return RollbackResult(ok=False, detail="nothing to roll back (no config applied yet)")
        self._git(*_GIT_IDENTITY, "revert", "--no-edit", "HEAD")
        return RollbackResult(ok=True, detail="reverted last apply")

    def rollback_body(self) -> str | None:
        """Return the body an undo would restore, without changing history."""
        self.ensure()
        if self._commit_count() < 2:
            return None
        full = self._git("show", f"HEAD^:{AGENT_FILE}").stdout
        return _extract_body(full)

    def body_at(self, ref: str) -> str:
        """The agent body committed at REF (e.g. a sha from `history()`), with
        the header/footer stripped — ready to re-apply for a restore-to-version.
        Raises ConfigRepoError if REF is unknown or has no agent file there."""
        self.ensure()
        full = self._git("show", f"{ref}:{AGENT_FILE}").stdout
        return _extract_body(full)

    def history(self, limit: int = 20) -> list[ConfigVersion]:
        """Recent versions, newest first (thin; underpins a future
        history-view affordance)."""
        self.ensure()
        out = self._git(
            "log", f"-{limit}", "--format=%H%x1f%s"
        ).stdout.strip()
        versions = []
        for line in out.splitlines():
            if "\x1f" not in line:
                continue
            sha, summary = line.split("\x1f", 1)
            versions.append(ConfigVersion(sha=sha, summary=summary, body=""))
        return versions
