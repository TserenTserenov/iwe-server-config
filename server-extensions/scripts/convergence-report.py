#!/usr/bin/env python3
"""Read-only convergence report: how every git repo under IWE_ROOT relates to its upstream.

WP-539 F21 B0(a). Three independent fields per repo, never merged into one status:
  relation -- HEAD vs the locally known upstream ref (no network, no fetch);
  fetch    -- age of the last *confirmed* successful fetch of exactly that upstream
              ref, from producers that log it (refs-sync-broker); no evidence means
              "unknown", not "never", and "equal" without it is not confirmed;
  block    -- an observed blocker of the canon sync contour with its age.
Per-copy facts beside them (WP-539, 03.11): origin (copies of one GitHub repo in
several folders are listed as duplicates), unpublished commits (in no known
remote branch, not just "ahead of upstream"), uncommitted and untracked files.
Discovery descends MAX_DEPTH levels, so nested repos (DS-MCP/*, DS-IT-systems/*)
are seen too.
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
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
try:
    import repo_registry  # sibling module
except ImportError:  # `python3 -` (script piped on stdin): __file__ is "<stdin>", no sibling next to it
    repo_registry = None

GIT_ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0", LC_ALL="C")
DEFAULT_REGISTRY = str(HERE / "repo-convergence.registry.yaml") if repo_registry else ""
REGISTRY_NAMES_SHOWN = 15
MAX_DEPTH = 2  # root = 0; DS-MCP/knowledge-mcp = 2
COVERAGE_NOTE = (f"полнота обхода: корень и вложенные каталоги до глубины {MAX_DEPTH}, кроме служебных; "
                 "по символическим ссылкам внутрь не заходит")
SKIP_DIRS = {".git", ".iwe-runtime", ".worktrees", ".claude", "node_modules"}
# "<ts> OK <path> <- <remote> +<src>:<dst>" -- refs-sync-broker.sh success line.
BROKER_OK_RE = re.compile(r"^(\S+) OK (\S+) <- \S+ \+?[^:\s]+:(\S+)$")
CANON_REPO = "DS-my-strategy"
SYNC_RUN_STALE_MIN = 60   # the canon sync runs every 20 min (Mac backstop: hourly)
FETCH_FRESH_MIN = int(os.environ.get("CONVERGENCE_FETCH_FRESH_MIN", "120"))
# Whole-scan budget: copies left when it runs out are reported as not checked, not dropped.
SCAN_BUDGET_S = int(os.environ.get("CONVERGENCE_SCAN_BUDGET_S", "120"))
COPY_FACTS = ("origin", "unpublished", "changed", "untracked")
DUP_FOLDERS_SHOWN = 3


def git(repo, *args):
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        env=GIT_ENV, capture_output=True, text=True, timeout=30,
    )
    return proc.returncode, proc.stdout.strip()


def has_git(path):
    """True if path holds a .git entry; raises OSError when path cannot be entered (Python <3.12)."""
    return (path / ".git").exists()


def discover(root):
    """(repos down to MAX_DEPTH, unreadable dirs). A symlinked repo is listed, never descended into;
    a folder reachable by two paths (memory and iwe-local-config/memory) is listed once, under its
    shallowest non-symlink path."""
    found, unreadable = {}, []  # real path -> ((is_link, depth, posix path), path); smaller key wins

    def add(path, depth, is_link):
        key = (is_link, depth, path.as_posix())
        real = path.resolve()
        if real not in found or key < found[real][0]:
            found[real] = (key, path)

    def walk(path, depth):
        try:
            if has_git(path):
                add(path, depth, False)
            if depth == MAX_DEPTH:
                return
            children = sorted(c for c in path.iterdir() if c.name not in SKIP_DIRS and c.is_dir())
        except OSError:
            unreadable.append(path)
            return
        for child in children:
            if not child.is_symlink():
                walk(child, depth + 1)
                continue
            try:
                if has_git(child):
                    add(child, depth + 1, True)
            except OSError:
                unreadable.append(child)

    walk(root, 0)
    repos = sorted((path for _, path in found.values()), key=lambda p: p.as_posix())
    return repos, unreadable


def origin_id(repo):
    """'owner/name' of the origin remote in lower case (GitHub ignores case), or None."""
    rc, url = git(repo, "remote", "get-url", "origin")
    if rc != 0 or not url:
        return None
    url = re.sub(r"\.git$", "", url.rstrip("/"))
    match = re.search(r"[:/]([^/:]+/[^/:]+)$", url)
    return (match.group(1) if match else url).lower()


def unpublished(repo):
    """Commits of the current branch that no remote-tracking ref contains.

    Current branch only: publication here cherry-picks session commits onto origin, so old
    local session branches never merge and --branches would count delivered work (198 on the
    root, 03.11). None when there is nothing to compare with: no remote, or a remote never
    fetched (every commit would read as unpublished). Stale remote-tracking refs overstate it."""
    rc, refs = git(repo, "for-each-ref", "--count=1", "--format=%(refname)", "refs/remotes")
    if rc != 0 or not refs:
        return None
    rc, count = git(repo, "rev-list", "--count", "HEAD", "--not", "--remotes")
    if rc != 0:
        return None
    if int(count) == 0:
        return 0
    # Publication cherry-picks onto origin: a commit whose patch is already upstream is delivered.
    rc, unique = git(repo, "rev-list", "--count", "--cherry-pick", "--right-only", "--no-merges",
                     "@{upstream}...HEAD")
    return min(int(count), int(unique)) if rc == 0 else int(count)


def worktree_changes(repo):
    """(changed tracked files, untracked entries); (None, None) on error."""
    rc, out = git(repo, "status", "--porcelain", "--untracked-files=normal")
    if rc != 0:
        return None, None
    lines = [line for line in out.splitlines() if line]
    untracked = sum(line.startswith("??") for line in lines)
    return len(lines) - untracked, untracked


def copy_facts(repo):
    """Per-copy facts beside the relation; a failure leaves them None and never touches the relation."""
    try:
        changed, untracked = worktree_changes(repo)
        return {"origin": origin_id(repo), "unpublished": unpublished(repo),
                "changed": changed, "untracked": untracked}
    except (subprocess.SubprocessError, OSError, ValueError) as exc:
        print(f"convergence-report: {repo}: {exc.__class__.__name__}", file=sys.stderr)
        return dict.fromkeys(COPY_FACTS)


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
    repos, unreadable = discover(root)
    deadline = time.monotonic() + SCAN_BUDGET_S
    rows = []
    for repo in repos:
        name = "." if repo == root else repo.relative_to(root).as_posix()
        if time.monotonic() > deadline:
            rel, upstream, is_error = f"не проверено: обход дольше {SCAN_BUDGET_S} с", None, True
            facts = dict.fromkeys(COPY_FACTS)
        else:
            try:
                rel, upstream, is_error = relation(repo)
            except (subprocess.SubprocessError, OSError, ValueError) as exc:
                rel, upstream, is_error = f"error: {exc.__class__.__name__}", None, True
            facts = copy_facts(repo)
        fetched = fetch_times.get((repo, upstream)) if upstream else None
        rows.append({
            "repo": name,
            "relation": rel,
            "upstream": upstream,
            "error": is_error,
            "fetch": age(fetched, now) if fetched else "unknown",
            "fetch_stale": bool(fetched) and (now - fetched).total_seconds() > FETCH_FRESH_MIN * 60,
            "block": block_text if name == CANON_REPO else "",
            **facts,
        })
    sources = [broker_note, state_note]
    if unreadable:
        sources.append(f"не читаются каталоги: {_names([str(p.relative_to(root)) for p in unreadable])}")
    return rows, sources


def duplicates(rows):
    """{origin: [repo, ...]} for origins checked out in more than one folder."""
    by_origin = {}
    for row in rows:
        if row["origin"]:
            by_origin.setdefault(row["origin"], []).append(row["repo"])
    return {origin: repos for origin, repos in sorted(by_origin.items()) if len(repos) > 1}


def _folders(repos):
    rest = len(repos) - DUP_FOLDERS_SHOWN
    return ", ".join(repos[:DUP_FOLDERS_SHOWN]) + (f" и ещё {rest}" if rest > 0 else "")


def render_copies(rows):
    """Summary lines for work at risk and duplicate copies; empty parts are omitted."""
    out = []
    pending = [f"{r['repo']} ({r['unpublished']})" for r in rows if r["unpublished"]]
    if pending:
        out.append(f"коммиты текущей ветки, которых нет ни в одной известной удалённой ветке, "
                   f"в {len(pending)} копиях: {_names(pending)}")
    dirty = [f"{r['repo']} ({r['changed']})" for r in rows if r["changed"]]
    if dirty:
        out.append(f"незакоммиченные правки в {len(dirty)} копиях: {_names(dirty)}")
    dups = duplicates(rows)
    if dups:
        out.append(f"один удалённый репозиторий в нескольких папках ({len(dups)}): "
                   + _names([f"{o}: {_folders(repos)}" for o, repos in dups.items()]))
    return out


def registry_section(rows, registry_path):
    """Registry view of the same repos; a broken/missing registry is reported, never silent."""
    if repo_registry is None:
        return {"state": "unavailable",
                "errors": ["сводка запущена со стандартного ввода: модуль реестра недоступен"]}
    registry, errors = repo_registry.load(registry_path)
    if registry is None:
        return {"state": "unavailable", "errors": errors}
    result = repo_registry.compare(registry, [r["repo"] for r in rows], repo_registry.host_id())
    result.update(state="ok", entries=len(registry["repos"]))
    return result


def _names(items):
    shown = ", ".join(items[:REGISTRY_NAMES_SHOWN])
    rest = len(items) - REGISTRY_NAMES_SHOWN
    return shown + (f" и ещё {rest}" if rest > 0 else "")


def render_registry(section):
    if section["state"] != "ok":
        first = section["errors"][0] if section["errors"] else "причина не указана"
        return [f"реестр сходимости НЕ РАБОТАЕТ ({len(section['errors'])} ош.): {first}", COVERAGE_NOTE]
    out = [f"реестр сходимости: записей {section['entries']}; найдено в реестре {len(section['registered'])}"]
    if section["outside"]:
        out.append(f"вне реестра {len(section['outside'])}: {_names(section['outside'])}")
    if section["absent"]:
        out.append(f"в реестре, но не найдено: {_names(section['absent'])}")
    if section["not_expected"]:
        out.append(f"присутствие на этом хосте не ожидается: {_names(section['not_expected'])}")
    out.append(COVERAGE_NOTE)
    return out


def classify(row):
    # An old confirmation is not a current one: equal on stale data is a problem.
    if row["error"] or row["block"] or row["relation"] != "equal" or row["fetch_stale"]:
        return "problem"
    return "confirmed" if row["fetch"] != "unknown" else "unconfirmed"


def render(rows, sources, host, problems_only, registry=None):
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
    if registry is not None:
        out += render_registry(registry)
    out += render_copies(rows)
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
    parser.add_argument("--registry", default=DEFAULT_REGISTRY,
                        help="convergence registry (repo-convergence.registry.yaml)")
    parser.add_argument("--problems-only", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    root = Path(args.root)
    if not root.is_dir():
        print(f"convergence-report: root not found: {root}", file=sys.stderr)
        return 2
    rows, sources = scan(root, Path(args.state_file))
    registry = registry_section(rows, args.registry)
    if args.json:
        print(json.dumps({"host": args.host, "sources": sources, "repos": rows, "registry": registry},
                         ensure_ascii=False))
    else:
        print(render(rows, sources, args.host, args.problems_only, registry))
    return 1 if any(r["error"] for r in rows) else 0


if __name__ == "__main__":
    sys.exit(main())
