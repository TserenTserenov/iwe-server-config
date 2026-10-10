#!/usr/bin/env python3
"""Classify stale session semaphores (.open files without a live owner pid)
as A (published, safe candidate) / needs-review (no commit refs or an
unresolved commit) / fresh (younger than 24h, needs pilot's own word
regardless of classification). Read-only - never renames or deletes.
"""
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

FRESH_THRESHOLD_HOURS = 24


def find_repo_map(iwe_root: Path) -> dict[str, list[Path]]:
    """Map a repo name (as written in a semaphore's commit:/receipt lines)
    to every matching filesystem path, by walking IWE_ROOT for .git
    directories. A bare repo name is genuinely ambiguous when two real,
    independently-diverged checkouts share a basename (confirmed live on
    this filesystem: knowledge-mcp exists both at IWE root and nested under
    DS-MCP/, at different HEADs) - commit_exists() checks every candidate
    rather than trusting whichever os.walk() happens to visit first."""
    repo_map: dict[str, list[Path]] = {"iwe-root": [iwe_root]}
    skip_dirs = {".git", ".iwe-runtime", ".worktrees", "node_modules", ".venv"}
    for root, dirs, _files in os.walk(iwe_root):
        depth = len(Path(root).relative_to(iwe_root).parts)
        if depth > 3:
            dirs[:] = []
            continue
        dirs[:] = [d for d in dirs if d not in skip_dirs]
        if (Path(root) / ".git").exists():
            repo_map.setdefault(Path(root).name, []).append(Path(root))
    return repo_map


def commit_exists(repo_map: dict[str, list[Path]], repo_name: str, sha: str) -> str:
    candidates = repo_map.get(repo_name)
    if not candidates:
        return "repo-unknown"
    for repo_path in candidates:
        result = subprocess.run(
            ["git", "-C", str(repo_path), "cat-file", "-e", f"{sha}^{{commit}}"],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            return "found"
    return "missing"


def _receipt_commits(text: str) -> list[tuple[str, str]]:
    """Extract (repo, sha) from publication_receipt_v2 lines via real JSON
    parsing, not positional regex - the previous regex only matched because
    the one writer seen so far happens to sort_keys and stay single-line;
    nothing in this script enforced that, so a different agent's writer
    (pretty-printed, differently-ordered) would silently lose the
    reference. Skip a line that fails to parse (another agent's format we
    don't yet understand) rather than crash the whole scan."""
    commits = []
    for line in text.splitlines():
        if not line.startswith("publication_receipt_v2:"):
            continue
        payload = line.split(":", 1)[1].strip()
        try:
            receipt = json.loads(payload)
        except ValueError:
            continue
        sha = receipt.get("anchor_commit")
        repo = receipt.get("repo")
        if sha and repo:
            commits.append((repo, sha))
    return commits


def parse_semaphore(path: Path) -> dict:
    text = path.read_text(encoding="utf-8", errors="replace")
    wp = (re.search(r"^wp:\s*(\S+)", text, re.M) or [None, "?"])[1]
    agent = (re.search(r"^agent:\s*(\S+)", text, re.M) or [None, "?"])[1]
    created_at = (re.search(r"^created_at:\s*(\S+)", text, re.M) or [None, None])[1]
    pid = (re.search(r"^pid:\s*(\d+)", text, re.M) or [None, None])[1]
    commit_lines = re.findall(r"^commit:\s*(\S+)\s+([0-9a-f]{8,64})", text, re.M)
    commits = commit_lines + _receipt_commits(text)
    return {"wp": wp, "agent": agent, "created_at": created_at, "pid": pid,
            "commits": commits, "path": path}


def pid_alive(pid: str | None) -> bool:
    if not pid or not pid.isdigit() or pid == "0":
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # kernel confirms the process exists, just owned by someone else


def age_hours(created_at: str | None) -> float | None:
    if not created_at:
        return None
    try:
        created = dt.datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=dt.timezone.utc
        )
    except ValueError:
        return None
    return (dt.datetime.now(dt.timezone.utc) - created).total_seconds() / 3600


def classify(sem: dict, repo_map: dict[str, list[Path]]) -> dict:
    if pid_alive(sem["pid"]):
        return {**sem, "class": "active", "reason": f"pid {sem['pid']} alive"}

    age = age_hours(sem["created_at"])
    checks = [(repo, sha, commit_exists(repo_map, repo, sha))
              for repo, sha in sem["commits"]]
    missing = [c for c in checks if c[2] != "found"]

    if age is None:
        # Missing/unparseable created_at must be at least as cautious as a
        # known-fresh session, not fall through to evidence-based A/needs-
        # review as if age were irrelevant - an unreadable timestamp is not
        # proof the session is old.
        klass = "needs-review"
        reason = "created_at missing or unparseable - cannot verify freshness, treating cautiously"
    elif age < FRESH_THRESHOLD_HOURS:
        klass = "fresh"
        reason = f"age={age:.1f}h < {FRESH_THRESHOLD_HOURS}h - needs pilot's own word regardless of evidence"
    elif not checks:
        klass = "needs-review"
        reason = "no commit references in semaphore - check the WP card for unfinished work"
    elif missing:
        klass = "needs-review"
        reason = f"{len(missing)}/{len(checks)} referenced commits not found in their repo"
    else:
        klass = "A"
        reason = f"all {len(checks)} referenced commits found on origin"

    return {**sem, "class": klass, "reason": reason, "age_hours": age, "checks": checks}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iwe-root", default=os.environ.get("IWE_ROOT", os.path.expanduser("~/IWE")))
    parser.add_argument("--sessions-dir", default=None,
                         help="default: <iwe-root>/.iwe-runtime/sessions")
    args = parser.parse_args()

    iwe_root = Path(args.iwe_root)
    sessions_dir = Path(args.sessions_dir) if args.sessions_dir else iwe_root / ".iwe-runtime/sessions"
    if not sessions_dir.is_dir():
        print(f"sessions dir not found: {sessions_dir}", file=sys.stderr)
        return 1

    repo_map = find_repo_map(iwe_root)
    results = [classify(parse_semaphore(p), repo_map)
               for p in sorted(sessions_dir.glob("*.open"))]

    by_class: dict[str, list[dict]] = {}
    for r in results:
        by_class.setdefault(r["class"], []).append(r)

    order = ["active", "A", "needs-review", "fresh"]
    for klass in order:
        items = by_class.get(klass, [])
        if not items:
            continue
        print(f"=== {klass} ({len(items)}) ===")
        for r in items:
            print(f"  {r['path'].name}  wp={r['wp']}  {r['reason']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
