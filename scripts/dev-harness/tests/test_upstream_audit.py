"""Exercise the snapshot audit against independent, synthetic Git histories."""

import importlib.util
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("upstream_audit", ROOT / "upstream_audit.py")
audit_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit_module)


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def commit(repo, path, text, subject):
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    git(repo, "add", path)
    git(repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", subject)
    return git(repo, "rev-parse", "HEAD")


@pytest.fixture
def histories(tmp_path):
    upstream, local = tmp_path / "upstream", tmp_path / "local"
    for repo in (upstream, local):
        repo.mkdir()
        git(repo, "init", "-q")
    base = commit(upstream, "app/shared.dart", "base", "snapshot base")
    first = commit(upstream, "app/shared.dart", "fixed", "first upstream fix")
    second = commit(upstream, "app/new.dart", "new feature", "new app feature")
    commit(upstream, "desktop/desktop.swift", "unrelated", "desktop only")
    commit(local, "app/shared.dart", "local pairing", "independent local snapshot")
    ledger = {
        "schema_version": 1, "snapshot_base": base, "paths": ["app", "backend"],
        "observed_head": second, "decisions": [],
    }
    return upstream, local, ledger, first, second


def test_unrelated_histories_keep_old_backlog_and_detect_local_adaptation(histories):
    upstream, local, ledger, first, second = histories
    before = (git(upstream, "rev-parse", "HEAD"), git(local, "status", "--porcelain"))
    report = audit_module.audit(upstream, local, ledger, "HEAD")
    assert [r["commit"] for r in report["commits"]] == [first, second]
    assert report["commits"][0]["category"] == "adaptation-review"
    assert report["commits"][0]["locally_changed_paths"] == ["app/shared.dart"]
    assert report["commits"][1]["category"] == "new-or-removed-paths-review"
    assert before == (git(upstream, "rev-parse", "HEAD"), git(local, "status", "--porcelain"))


def test_only_explicit_decisions_remove_items_and_dirty_work_is_visible(histories):
    upstream, local, ledger, first, second = histories
    ledger["decisions"] = [
        {"commit": first, "status": "backported", "note": "ported with tests"},
        {"commit": second, "status": "deferred", "note": "needs local transport adaptation"},
    ]
    (local / "app/shared.dart").write_text("unsaved work")
    report = audit_module.audit(upstream, local, ledger, "HEAD")
    assert report["handled_commits"] == 1
    assert report["pending_commits"] == 1
    assert report["commits"][0]["decision"] == "needs local transport adaptation"
    assert report["local_worktree_dirty"] is True
    assert (local / "app/shared.dart").read_text() == "unsaved work"
    assert "Pending: 1" in audit_module.markdown(report)


def test_matching_snapshot_blob_is_reviewable_but_never_auto_applied(histories):
    upstream, local, ledger, first, _ = histories
    commit(local, "app/shared.dart", "base", "retain baseline")
    report = audit_module.audit(upstream, local, ledger, "HEAD")
    assert report["commits"][0]["commit"] == first
    assert report["commits"][0]["category"] == "unchanged-base-review"
    assert (local / "app/shared.dart").read_text() == "base"


def test_missing_or_unrelated_baseline_fails_instead_of_claiming_no_updates(histories):
    upstream, local, ledger, _, _ = histories
    with pytest.raises(ValueError):
        audit_module.audit(upstream, local, ledger, "missing-upstream-ref")
    git(upstream, "checkout", "--orphan", "rewritten")
    commit(upstream, "app/shared.dart", "new history", "rewritten baseline")
    with pytest.raises(ValueError):
        audit_module.audit(upstream, local, ledger, "HEAD")
