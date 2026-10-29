#!/usr/bin/env python3
"""Read-only convergence report: how every git repo under IWE_ROOT relates to its upstream.

WP-539 F21 B0(a). Three independent fields per repo, never merged into one status:
  relation -- HEAD vs the locally known upstream ref (no network, no fetch);
  fetch    -- age of the last *confirmed* successful fetch, from producers that log it
              (refs-sync-broker); no evidence means "unknown", not "never";
  block    -- an observed blocker of the sync contour with its age (sync state file).
Completeness (found / checked / errors / fetch unknown) is printed so a repo that
disappears from the scan cannot turn the report green by its absence.
"""

import argparse
import datetime as dt
import json
import os
import re
import socket
import subprocess
import sys
from pathlib import Path

GIT_ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0", LC_ALL="C")
SKIP_DIRS = {".iwe-runtime", ".worktrees", ".claude", "node_modules"}
BROKER_OK_RE = re.compile(r"^(\S+) OK (\S+) <- ")


def git(repo, *args):
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        env=GIT_ENV, capture_output=True, text=True, timeout=30,
    )
    return proc.returncode, proc.stdout.strip()


def discover(root):
    repos = []
    if (root / ".git").exists():
        repos.append(root)
    for child in sorted(root.iterdir()):
        if child.name in SKIP_DIRS or not child.is_dir():
            continue
        if (child / ".git").exists():
            repos.append(child)
    return repos


def parse_ts(value):
    if not value:
        return None
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def broker_fetch_times(root):
    """Last confirmed OK fetch per repo path, from refs-sync-broker.log."""
    log = root / ".iwe-runtime" / "refs-sync-broker" / "broker.log"
    times = {}
    if not log.is_file():
        return times
    with log.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            match = BROKER_OK_RE.match(line)
            if not match:
                continue
            ts = parse_ts(match.group(1))
            if ts:
                path = match.group(2)
                times[root if path == "." else root / path] = ts
    return times


def canon_block(root):
    """Blocker of the canon sync contour, from tsekh1-git-sync's state file."""
    state_file = Path.home() / ".claude" / "state" / "tsekh1-git-sync-state.json"
    try:
        state = json.loads(state_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return {root / "DS-my-strategy": f"state unreadable: {exc.__class__.__name__}"}
    fails = int(state.get("consecutive_fails") or 0)
    if fails == 0:
        return {}
    since = parse_ts(state.get("failure_started_ts")) or parse_ts(state.get("last_success_ts"))
    return {root / "DS-my-strategy": f"sync failing x{fails}" + (f" since {age(since)}" if since else "")}


def age(ts, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    minutes = int((now - ts).total_seconds() // 60)
    if minutes < 120:
        return f"{minutes}m"
    if minutes < 48 * 60:
        return f"{minutes // 60}h"
    return f"{minutes // 1440}d"


def relation(repo):
    rc, branch = git(repo, "symbolic-ref", "-q", "--short", "HEAD")
    if rc != 0:
        return "detached", None
    rc, upstream = git(repo, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
    if rc != 0:
        return f"no-upstream ({branch})", None
    rc, counts = git(repo, "rev-list", "--left-right", "--count", "HEAD...@{upstream}")
    if rc != 0:
        return "error: rev-list", upstream
    ahead, behind = (int(x) for x in counts.split())
    if ahead and behind:
        return f"diverged +{ahead}/-{behind}", upstream
    if ahead:
        return f"ahead +{ahead}", upstream
    if behind:
        return f"behind -{behind}", upstream
    return "equal", upstream


def scan(root):
    fetch_times = broker_fetch_times(root)
    blocks = canon_block(root)
    rows, errors = [], 0
    for repo in discover(root):
        try:
            rel, upstream = relation(repo)
        except (subprocess.SubprocessError, OSError, ValueError) as exc:
            rel, upstream = f"error: {exc.__class__.__name__}", None
        if rel.startswith("error"):
            errors += 1
        fetched = fetch_times.get(repo)
        rows.append({
            "repo": "." if repo == root else repo.name,
            "relation": rel,
            "upstream": upstream,
            "fetch": age(fetched) if fetched else "unknown",
            "block": blocks.get(repo, ""),
        })
    return rows, errors


def is_problem(row):
    return row["relation"] != "equal" or bool(row["block"])


def render(rows, errors, host, problems_only):
    unknown = sum(1 for r in rows if r["fetch"] == "unknown")
    problems = [r for r in rows if is_problem(r)]
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%MZ")
    out = [
        f"Сходимость git — {host}, {now}",
        f"найдено {len(rows)}, проверено {len(rows) - errors}, ошибок {errors}, "
        f"проблемных {len(problems)}, свежесть получения неизвестна у {unknown}",
    ]
    for r in sorted(problems, key=lambda r: (not r["block"], r["repo"])):
        line = f"- {r['repo']}: {r['relation']}; получено с GitHub: {r['fetch']}"
        if r["block"]:
            line += f"; блокировка: {r['block']}"
        out.append(line)
    if not problems_only:
        equal = sorted(r["repo"] for r in rows if not is_problem(r))
        out.append(f"совпадают ({len(equal)}): {', '.join(equal)}")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=os.environ.get("IWE_ROOT", str(Path.home() / "IWE")))
    parser.add_argument("--host", default=socket.gethostname().split(".")[0])
    parser.add_argument("--problems-only", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    root = Path(args.root)
    if not root.is_dir():
        print(f"convergence-report: root not found: {root}", file=sys.stderr)
        return 2
    rows, errors = scan(root)
    if args.json:
        print(json.dumps({"host": args.host, "errors": errors, "repos": rows}, ensure_ascii=False))
    else:
        print(render(rows, errors, args.host, args.problems_only))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
