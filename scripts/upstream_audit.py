#!/usr/bin/env python3
"""Read-only upstream backlog for this standalone snapshot; never fetch or merge."""

import argparse
import json
import subprocess
from pathlib import Path


def git(repo, *args):
    result = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True, check=False
    )
    if result.returncode:
        raise ValueError(result.stderr.strip() or "Git command failed")
    return result.stdout.strip()


def resolve(repo, ref):
    return git(repo, "rev-parse", "--verify", "--end-of-options", ref + "^{commit}")


def tree(repo, ref, paths):
    output = git(repo, "ls-tree", "-r", "--format=%(objectname)\t%(path)", ref, "--", *paths)
    return {path: oid for oid, path in (line.split("\t", 1) for line in output.splitlines())}


def audit(upstream, local, ledger, upstream_ref="origin/main", local_ref="HEAD"):
    base = resolve(upstream, ledger["snapshot_base"])
    tip = resolve(upstream, upstream_ref)
    local_tip = resolve(local, local_ref)
    # A rewritten source history needs an explicit new comparison, never an empty backlog.
    git(upstream, "merge-base", "--is-ancestor", base, tip)
    paths = ledger["paths"]
    base_files = tree(upstream, base, paths)
    local_files = tree(local, local_tip, paths)
    decisions = {item["commit"]: item for item in ledger["decisions"]}
    rows = []
    handled = 0
    history = git(
        upstream, "log", "--no-merges", "--reverse", "--no-renames", "--name-only", "-z",
        "--format=%x1e%H\t%cs\t%s%x00", f"{base}..{tip}", "--", *paths,
    )
    for record in history.split("\x1e"):
        if not record:
            continue
        header, _, names = record.partition("\0")
        sha, date, subject = header.split("\t", 2)
        decision = decisions.get(sha, {})
        if decision.get("status") in {"backported", "already_local", "out_of_scope"}:
            handled += 1
            continue
        changed = [name for name in names.removeprefix("\0").removeprefix("\n").split("\0") if name]
        retained = [path for path in changed if path in local_files]
        diverged = [path for path in retained if local_files[path] != base_files.get(path)]
        category = "adaptation-review" if diverged else "unchanged-base-review"
        if not retained:
            category = "new-or-removed-paths-review"
        rows.append({
            "commit": sha, "date": date, "subject": subject, "category": category,
            "retained_paths": retained, "locally_changed_paths": diverged,
            "other_paths": [path for path in changed if path not in local_files],
            "decision": decision.get("note"),
        })
    dirty = bool(git(local, "status", "--porcelain", "--untracked-files=normal"))
    return {
        "snapshot_base": base, "upstream_head": tip, "local_head": local_tip,
        "local_worktree_dirty": dirty,
        "scope": paths, "handled_commits": handled, "pending_commits": len(rows),
        "note": "Committed trees only. Categories guide review; none authorizes automatic application. "
                "Merge-only conflict resolutions require a separate net-diff review.",
        "commits": rows,
    }


def markdown(report):
    lines = [
        "# Omi upstream backlog", "",
        f"Upstream: `{report['upstream_head']}`; local: `{report['local_head']}`.",
        f"Pending: {report['pending_commits']}; recorded decisions: {report['handled_commits']}.",
        f"Local working tree dirty: {report['local_worktree_dirty']}.", "", report["note"], "",
        "| Commit | Date | Review | Change |", "| --- | --- | --- | --- |",
    ]
    for row in report["commits"]:
        subject = row["subject"].replace("|", "\\|").replace("\n", " ")
        lines.append(
            f"| `{row['commit'][:12]}` | {row['date']} | {row['category']} | {subject} |"
        )
    return "\n".join(lines) + "\n"


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", required=True, type=Path, help="Existing BasedHardware/omi checkout")
    parser.add_argument("--local", type=Path, default=root)
    parser.add_argument("--ledger", type=Path, default=root / "upstream-sync.json")
    parser.add_argument("--upstream-ref", default="origin/main")
    parser.add_argument("--local-ref", default="HEAD")
    parser.add_argument("--format", choices=("json", "markdown"), default="markdown")
    args = parser.parse_args()
    try:
        ledger = json.loads(args.ledger.read_text())
        if ledger.get("schema_version") != 1:
            raise ValueError("Unsupported upstream ledger version")
        report = audit(args.upstream, args.local, ledger, args.upstream_ref, args.local_ref)
    except (ValueError, KeyError, OSError) as exc:
        parser.exit(2, f"Upstream audit failed: {exc}\n")
    print(json.dumps(report, indent=2, ensure_ascii=False) if args.format == "json" else markdown(report), end="\n")


if __name__ == "__main__":
    main()
