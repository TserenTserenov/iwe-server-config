#!/usr/bin/env python3
"""Read-only convergence report: how every git repo under IWE_ROOT relates to its upstream.

WP-539 F21 B0(a). Three independent fields per repo, never merged into one status:
  relation -- HEAD vs the locally known upstream ref (no network, no fetch);
  fetch    -- age of the last *confirmed* successful fetch of exactly that upstream
              ref, from producers that log it (refs-sync-broker); no evidence means
              "unknown", not "never", and "equal" without it is not confirmed;
  block    -- an observed blocker of the canon sync contour with its age.
Completeness (found / checked / errors / unconfirmed) and the state of every
evidence source are printed, so neither a vanished repo nor a broken source can
turn the report green by its absence.
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
# "<ts> OK <path> <- <remote> +<src>:<dst>" -- refs-sync-broker.sh success line.
BROKER_OK_RE = re.compile(r"^(\S+) OK (\S+) <- \S+ \+?[^:\s]+:(\S+)$")
CANON_REPO = "DS-my-strategy"
SYNC_RUN_STALE_MIN = 60   # the canon sync runs every 20 min (Mac backstop: hourly)
FETCH_FRESH_MIN = int(os.environ.get("CONVERGENCE_FETCH_FRESH_MIN", "120"))


def git(repo, *args):
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        env=GIT_ENV, capture_output=True, text=True, timeout=30,
    )
    return proc.returncode, proc.stdout.strip()


def discover(root):
    repos = [root] if (root / ".git").exists() else []
    for child in sorted(root.iterdir()):
        if child.name not in SKIP_DIRS and child.is_dir() and (child / ".git").exists():
            repos.append(child)
    return repos


def parse_ts(value):
    try:
        return dt.datetime.strptime(str(value), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def age(ts, now):
    minutes = int((now - ts).total_seconds() // 60)
    if minutes < 120:
        return f"{minutes}m"
    if minutes < 48 * 60:
        return f"{minutes // 60}h"
    return f"{minutes // 1440}d"


def broker_fetch_times(root):
    """{(repo path, destination ref): last OK time} from refs-sync-broker.log."""
    log = root / ".iwe-runtime" / "refs-sync-broker" / "broker.log"
    if not log.is_file():
        return {}, "broker.log: нет файла"
    times = {}
    try:
        with log.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                match = BROKER_OK_RE.match(line.strip())
                ts = match and parse_ts(match.group(1))
                if ts:
                    path = match.group(2)
                    times[(root if path == "." else root / path, match.group(3))] = ts
    except OSError as exc:
        return {}, f"broker.log: не читается ({exc.__class__.__name__})"
    return times, f"broker.log: {len(times)} подтверждений"


def canon_block(state_file, now):
    """Blocker text for the canon sync contour, plus a source note."""
    try:
        state = json.loads(state_file.read_text(encoding="utf-8"))
        fails = int(state.get("consecutive_fails") or 0)
    except FileNotFoundError:
        return "", "состояние синхронизатора: нет файла"
    except (OSError, ValueError, TypeError, AttributeError) as exc:
        return "состояние синхронизатора не читается", f"состояние синхронизатора: ошибка ({exc.__class__.__name__})"
    parts = []
    if fails:
        since = parse_ts(state.get("failure_started_ts"))
        parts.append(f"синхронизатор отказывает подряд {fails} раз" + (f", {age(since, now)}" if since else ""))
    for key, label in (("behind_since_ts", "позади"), ("ahead_since_ts", "впереди")):
        since = parse_ts(state.get(key))
        if since:
            parts.append(f"{label} с GitHub уже {age(since, now)}")
    last_run = parse_ts(state.get("last_run_ts"))
    if last_run is None:
        parts.append("время последнего запуска синхронизатора неизвестно")
    elif (now - last_run).total_seconds() > SYNC_RUN_STALE_MIN * 60:
        parts.append(f"синхронизатор не запускался {age(last_run, now)}")
    return "; ".join(parts), "состояние синхронизатора: прочитано"


def relation(repo):
    """(relation text, full upstream ref or None, is_error)."""
    rc, branch = git(repo, "symbolic-ref", "-q", "--short", "HEAD")
    if rc == 1:
        return "detached", None, False
    if rc != 0:
        return f"error: symbolic-ref exit {rc}", None, True
    rc, upstream = git(repo, "rev-parse", "--symbolic-full-name", "@{upstream}")
    if rc != 0:
        configured, _ = git(repo, "config", "--get", f"branch.{branch}.merge")
        if configured == 1:  # key absent: no upstream is set up
            return f"no-upstream ({branch})", None, False
        if configured != 0:
            return f"error: git config exit {configured}", None, True
        return "error: upstream configured but unresolved", None, True
    rc, counts = git(repo, "rev-list", "--left-right", "--count", "HEAD...@{upstream}")
    if rc != 0:
        return f"error: rev-list exit {rc}", upstream, True
    ahead, behind = (int(x) for x in counts.split())
    if ahead and behind:
        return f"diverged +{ahead}/-{behind}", upstream, False
    if ahead:
        return f"ahead +{ahead}", upstream, False
    if behind:
        return f"behind -{behind}", upstream, False
    return "equal", upstream, False


def scan(root, state_file):
    now = dt.datetime.now(dt.timezone.utc)
    fetch_times, broker_note = broker_fetch_times(root)
    block_text, state_note = canon_block(state_file, now)
    rows = []
    for repo in discover(root):
        try:
            rel, upstream, is_error = relation(repo)
        except (subprocess.SubprocessError, OSError, ValueError) as exc:
            rel, upstream, is_error = f"error: {exc.__class__.__name__}", None, True
        fetched = fetch_times.get((repo, upstream)) if upstream else None
        rows.append({
            "repo": "." if repo == root else repo.name,
            "relation": rel,
            "upstream": upstream,
            "error": is_error,
            "fetch": age(fetched, now) if fetched else "unknown",
            "fetch_stale": bool(fetched) and (now - fetched).total_seconds() > FETCH_FRESH_MIN * 60,
            "block": block_text if repo.name == CANON_REPO else "",
        })
    return rows, [broker_note, state_note]


def classify(row):
    # An old confirmation is not a current one: equal on stale data is a problem.
    if row["error"] or row["block"] or row["relation"] != "equal" or row["fetch_stale"]:
        return "problem"
    return "confirmed" if row["fetch"] != "unknown" else "unconfirmed"


def render(rows, sources, host, problems_only):
    groups = {"problem": [], "confirmed": [], "unconfirmed": []}
    for row in rows:
        groups[classify(row)].append(row)
    errors = sum(r["error"] for r in rows)
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%MZ")
    out = [
        f"Сходимость git — {host}, {now}",
        f"найдено {len(rows)}, проверено {len(rows) - errors}, ошибок {errors}; "
        f"расходятся {len(groups['problem'])}, совпадение подтверждено {len(groups['confirmed'])}, "
        f"совпадает, но получение с сервера не подтверждено {len(groups['unconfirmed'])}",
        "источники: " + "; ".join(sources),
    ]
    for r in sorted(groups["problem"], key=lambda r: (not r["error"], not r["block"], r["repo"])):
        fetched = r["fetch"] + (" (устарело)" if r["fetch_stale"] else "")
        line = f"- {r['repo']}: {r['relation']}; данные с сервера получены: {fetched}"
        if r["block"]:
            line += f"; блокировка: {r['block']}"
        out.append(line)
    if groups["unconfirmed"]:
        out.append("совпадение не подтверждено: " + ", ".join(r["repo"] for r in groups["unconfirmed"]))
    if not problems_only and groups["confirmed"]:
        out.append("совпадение подтверждено: " + ", ".join(r["repo"] for r in groups["confirmed"]))
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=os.environ.get("IWE_ROOT", str(Path.home() / "IWE")))
    parser.add_argument("--host", default=socket.gethostname().split(".")[0])
    parser.add_argument("--state-file",
                        default=str(Path.home() / ".claude" / "state" / "tsekh1-git-sync-state.json"))
    parser.add_argument("--problems-only", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    root = Path(args.root)
    if not root.is_dir():
        print(f"convergence-report: root not found: {root}", file=sys.stderr)
        return 2
    rows, sources = scan(root, Path(args.state_file))
    if args.json:
        print(json.dumps({"host": args.host, "sources": sources, "repos": rows}, ensure_ascii=False))
    else:
        print(render(rows, sources, args.host, args.problems_only))
    return 1 if any(r["error"] for r in rows) else 0


if __name__ == "__main__":
    sys.exit(main())
