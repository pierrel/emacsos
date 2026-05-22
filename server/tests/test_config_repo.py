"""Unit tests for the git-backed ConfigRepo — pure git+fs, tmp repo, no mocks."""
from __future__ import annotations

import os
import subprocess

from emacsos_server.config_repo import ConfigRepo, _extract_body, render


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
    assert res.version is not None
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
