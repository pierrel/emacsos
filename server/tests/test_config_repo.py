"""Unit tests for the git-backed ConfigRepo — pure git+fs, tmp repo, no mocks."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from unittest.mock import patch

import pytest

from emacsos_server.config_repo import (
    ConfigRepo,
    ConfigRepoError,
    _extract_body,
    migrate_emacos_symbols,
    render,
)


_EMACS_CHARACTER_LITERALS = (
    "?;", '?"', r"?\;", r'?\"', r"?\\",
    r"?\^?", r"?\^x", r"?\^;", r'?\^"', r"?\^\\",
    r"?\123", r"?\777", r"?\x41", r"?\u0041", r"?\U00000041",
    r"?\N{LATIN CAPITAL LETTER A}", r"?\C-a", r"?\M-a", r"?\S-a",
    r"?\H-a", r"?\A-a", r"?\s-a", r"?\C-\M-\S-\H-\A-\s-a",
    r"?\C-", r"?\^", r"?\s",
)


def test_namespace_migration_changes_only_lisp_symbols():
    body = ('(emacos-call "+1")\n'
            "#'emacos--chat-show-top-buffer\n"
            "; keep emacos-call as the historical spelling\n"
            "#| keep emacos-call in a block comment |#\n"
            '(message "emacos-call is old")\n'
            '(not-emacos-call)\n')
    assert migrate_emacos_symbols(body) == (
        '(emacsos-call "+1")\n'
        "#'emacsos--chat-show-top-buffer\n"
        "; keep emacos-call as the historical spelling\n"
        "#| keep emacos-call in a block comment |#\n"
        '(message "emacos-call is old")\n'
        '(not-emacos-call)\n'
    )


def test_namespace_migration_skips_characters_before_later_symbols():
    body = (
        '(list ?; (emacos-call "+1"))\n'
        '(list ?" (emacos--chat-show-top-buffer))\n'
        r'(list ?\; ?\" ?\\ ?\C-a emacos\-call)' "\n"
    )
    assert migrate_emacos_symbols(body) == (
        '(list ?; (emacsos-call "+1"))\n'
        '(list ?" (emacsos--chat-show-top-buffer))\n'
        r'(list ?\; ?\" ?\\ ?\C-a emacsos\-call)' "\n"
    )


@pytest.mark.parametrize("literal", _EMACS_CHARACTER_LITERALS)
def test_namespace_migration_skips_complete_emacs_character_literals(literal):
    body = f"(list {literal} (emacos-call \"+1\"))"
    assert migrate_emacos_symbols(body) == (
        f"(list {literal} (emacsos-call \"+1\"))")


@pytest.mark.skipif(shutil.which("emacs") is None,
                    reason="requires the installed Emacs reader")
def test_namespace_migration_character_corpus_is_accepted_by_emacs(tmp_path):
    source = tmp_path / "characters.el"
    source.write_text("(list " + " ".join(_EMACS_CHARACTER_LITERALS) + ")")
    form = (
        "(with-temp-buffer "
        f"(insert-file-contents {json.dumps(str(source))}) "
        "(goto-char (point-min)) (read (current-buffer)) "
        "(skip-chars-forward \" \\t\\r\\n\") "
        "(unless (eobp) (error \"trailing reader input\")))"
    )
    result = subprocess.run(
        ["emacs", "-Q", "--batch", "--eval", form],
        capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stderr


def test_namespace_migration_changes_only_complete_symbol_atoms():
    body = '(list `emacos-call ,emacos-call ,@emacos-calls :emacos-call foo/emacos-call)'
    assert migrate_emacos_symbols(body) == (
        '(list `emacsos-call ,emacsos-call ,@emacsos-calls :emacsos-call '
        'foo/emacos-call)'
    )


def test_namespace_migration_preserves_noncode_and_canonical_body():
    body = (
        '(message "emacos-call string")\n'
        '; emacos-call line comment\n'
        '#| emacos-call block comment #| nested emacos-call |# |#\n'
        '(emacsos-call "+1")\n'
    )
    assert migrate_emacos_symbols(body) == body


def test_namespace_migration_noops_exact_canonical_body():
    body = '(emacsos-call "+1")'
    assert migrate_emacos_symbols(body) == body


@pytest.mark.parametrize("body", [
    '"emacos-call',
    '#| emacos-call',
    '?',
    r'?\C',
    '(emacos-call "+1"',
    ']',
])
def test_namespace_migration_rejects_incomplete_lisp_before_apply(body):
    with pytest.raises(ConfigRepoError, match="incomplete Lisp config"):
        migrate_emacos_symbols(body)


def _repo(tmp_path):
    return ConfigRepo(str(tmp_path / "config-repo"))


def test_ensure_idempotent_and_scaffolds(tmp_path):
    r = _repo(tmp_path)
    r.ensure()
    assert os.path.isdir(os.path.join(r.repo_dir, ".git"))
    assert os.path.isfile(r.agent_path)
    # Second ensure is a no-op (doesn't raise, doesn't add commits).
    r.ensure()
    cur = r.current()
    assert "scaffold" in cur.summary
    assert cur.body == ""  # scaffold body is empty


def test_namespace_migration_reconciliation_state_survives_reset(tmp_path):
    r = _repo(tmp_path)
    r.ensure()
    assert not r.namespace_migration_reconciliation_pending()
    r.mark_namespace_migration_reconciliation()
    assert r.namespace_migration_reconciliation_pending()
    r.ensure()
    assert r.namespace_migration_reconciliation_pending()
    r.clear_namespace_migration_reconciliation()
    assert not r.namespace_migration_reconciliation_pending()


def test_write_and_commit_round_trips_body(tmp_path):
    r = _repo(tmp_path)
    sha = r.write_and_commit("(setq foo 1)", "set foo")
    assert sha
    cur = r.current()
    assert cur.summary == "set foo"
    assert cur.body == "(setq foo 1)"
    # The on-disk file is loadable: header + body + (provide 'agent).
    with open(r.agent_path) as f:
        full = f.read()
    assert "(provide 'agent)" in full
    assert "(setq foo 1)" in full


def test_first_apply_produces_scaffold_plus_change(tmp_path):
    r = _repo(tmp_path)
    r.write_and_commit("(setq foo 1)", "set foo")
    # scaffold + change == 2 commits, so rollback has somewhere to land.
    count = int(subprocess.run(
        ["git", "-C", r.repo_dir, "rev-list", "--count", "HEAD"],
        capture_output=True, text=True).stdout.strip())
    assert count == 2


def test_rollback_reverts_to_prior_body(tmp_path):
    r = _repo(tmp_path)
    r.write_and_commit("(setq foo 1)", "set foo")
    r.write_and_commit("(setq foo 2)", "set foo to 2")
    assert r.current().body == "(setq foo 2)"
    res = r.rollback()
    assert res.ok
    # Reverting the "set foo to 2" commit restores foo 1.
    assert r.current().body == "(setq foo 1)"


def test_rollback_preserves_history_for_roll_forward(tmp_path):
    r = _repo(tmp_path)
    r.write_and_commit("(setq foo 1)", "v1")
    r.write_and_commit("(setq foo 2)", "v2")
    r.rollback()
    # The reverted-from commit must still be in history (roll-forward).
    log = subprocess.run(
        ["git", "-C", r.repo_dir, "log", "--format=%s"],
        capture_output=True, text=True).stdout
    assert "v2" in log
    assert "Revert" in log or "revert" in log


def test_rollback_on_empty_repo_reports_nothing(tmp_path):
    r = _repo(tmp_path)
    res = r.rollback()  # only scaffold (or nothing) exists
    assert not res.ok
    assert "nothing to roll back" in res.detail


def test_rollback_body_previews_without_changing_history(tmp_path):
    r = _repo(tmp_path)
    r.write_and_commit("(setq foo 1)", "set foo")
    before = r.current().sha
    assert r.rollback_body() == ""
    assert r.current().sha == before


def test_rollback_body_is_none_for_scaffold_only(tmp_path):
    r = _repo(tmp_path)
    assert r.rollback_body() is None


def test_ensure_recovers_from_interrupted_staging(tmp_path):
    r = _repo(tmp_path)
    r.write_and_commit("(setq foo 1)", "v1")
    # Simulate an interrupted commit: stage a change but don't commit.
    with open(r.agent_path, "w") as f:
        f.write(render("(setq bar 99)"))
    subprocess.run(["git", "-C", r.repo_dir, "add", "agent.el"],
                   capture_output=True, text=True)
    # ensure() resets staging so the next op starts clean.
    r.ensure()
    staged = subprocess.run(
        ["git", "-C", r.repo_dir, "diff", "--cached", "--name-only"],
        capture_output=True, text=True).stdout.strip()
    assert staged == ""


def test_ensure_scaffolds_committless_repo(tmp_path):
    """`.git` exists but no commits (manual init / partial) → ensure()
    scaffolds a first commit so current()/rollback() have a HEAD."""
    repo_dir = str(tmp_path / "config-repo")
    os.makedirs(repo_dir)
    subprocess.run(["git", "-C", repo_dir, "init", "-q"], check=True)
    r = ConfigRepo(repo_dir)
    r.ensure()
    cur = r.current()  # would raise (no HEAD) without the scaffold
    assert "scaffold" in cur.summary
    assert cur.body == ""


def test_ensure_restores_dirty_working_tree(tmp_path):
    """A prior interrupted write leaves agent.el dirty; without a hard
    reset, `git revert` would fail with 'local changes would be
    overwritten'.  ensure() restores the tree to HEAD so rollback works."""
    r = _repo(tmp_path)
    r.write_and_commit("(setq foo 1)", "v1")
    r.write_and_commit("(setq foo 2)", "v2")
    # Simulate a crashed write: dirty agent.el, uncommitted.
    with open(r.agent_path, "w") as f:
        f.write(render("(setq garbage 99)"))
    r.ensure()
    # Tree restored to HEAD (v2), and rollback (a revert) succeeds.
    assert r.current().body == "(setq foo 2)"
    assert r.rollback().ok
    assert r.current().body == "(setq foo 1)"


def test_ensure_recreates_missing_agent_file(tmp_path):
    r = _repo(tmp_path)
    r.write_and_commit("(setq foo 1)", "v1")
    os.remove(r.agent_path)
    r.ensure()  # self-heal a working-tree file deleted out of band
    assert os.path.isfile(r.agent_path)
    # Restored from HEAD (the real last config), not scaffolded empty.
    assert r.current().body == "(setq foo 1)"


def test_reapplying_identical_config_creates_no_empty_commit(tmp_path):
    r = _repo(tmp_path)
    sha1 = r.write_and_commit("(setq foo 1)", "set foo")
    count1 = int(subprocess.run(
        ["git", "-C", r.repo_dir, "rev-list", "--count", "HEAD"],
        capture_output=True, text=True).stdout.strip())
    sha2 = r.write_and_commit("(setq foo 1)", "set foo again")
    count2 = int(subprocess.run(
        ["git", "-C", r.repo_dir, "rev-list", "--count", "HEAD"],
        capture_output=True, text=True).stdout.strip())
    # No new commit, same HEAD — no empty commit to break a later revert.
    assert sha2 == sha1
    assert count2 == count1


def test_post_commit_sha_read_failure_stays_recorded(tmp_path):
    r = _repo(tmp_path)
    real_git = r._git

    def git_without_head_read(*args):
        if args == ("rev-parse", "HEAD"):
            raise OSError("metadata unavailable")
        return real_git(*args)

    with patch.object(r, "_git", side_effect=git_without_head_read):
        assert r.write_and_commit("(setq foo 1)", "set foo") is None
    assert r.current().body == "(setq foo 1)"


def test_rollback_after_identical_reapply_does_not_error(tmp_path):
    """Regression: an empty commit would make `git revert` abort. With
    the no-diff guard, a second identical apply makes no commit, so
    rollback still cleanly reverts the one real change."""
    r = _repo(tmp_path)
    r.write_and_commit("(setq foo 1)", "v1")
    r.write_and_commit("(setq foo 1)", "v1 again")  # no-op, no commit
    res = r.rollback()
    assert res.ok
    assert r.current().body == ""  # reverted the only real apply → scaffold


def test_render_extract_body_round_trip():
    assert _extract_body(render("(message \"hi\")")) == "(message \"hi\")"
    assert _extract_body(render("")) == ""


def test_history_newest_first(tmp_path):
    r = _repo(tmp_path)
    r.write_and_commit("(setq a 1)", "first")
    r.write_and_commit("(setq a 2)", "second")
    hist = r.history()
    summaries = [v.summary for v in hist]
    assert summaries[0] == "second"
    assert "first" in summaries


def test_body_at_returns_the_body_committed_at_a_ref(tmp_path):
    repo = _repo(tmp_path)
    repo.ensure()
    sha1 = repo.write_and_commit("(setq a 1)", "first")
    repo.write_and_commit("(setq a 2)", "second")
    # body_at fetches an OLD version's body for a restore-to-version; current()
    # is unaffected.
    assert repo.body_at(sha1) == "(setq a 1)"
    assert repo.current().body == "(setq a 2)"


def test_body_at_unknown_ref_raises(tmp_path):
    repo = _repo(tmp_path)
    repo.ensure()
    with pytest.raises(ConfigRepoError):
        repo.body_at("deadbeef")
