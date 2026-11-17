#!/usr/bin/env python3
"""Put shared server copies (PACK-*, bot docs) back on their main branch when someone switched them.

WP-484, bug-2026-11-17-multiline-note-file-claim-blocks-product-receipt.md, fix 5.

A shared copy is read by every session and by the style/rule hooks. When an agent runs
`git switch <other branch>` there, everybody after it reads that branch's files; the 5-minute
reader-copies-sync only reports "branch X instead of main" and leaves the copy alone.

Contract (hourly, no fetch, no commits, nothing deleted):
  * WHICH copies: registry checkouts of class reader or service on this host whose path starts
    with PACK- or DS-IT-systems/ (the shared packs and the bot docs).
  * returns a copy to its expected branch only when ALL hold: it is on another branch (or
    detached), it has no tracked changes and no half-finished git operation, and its current tip
    is already contained in the upstream ref (so nothing reachable only from this tip is left behind).
  * anything else is reported as BLOCKED and left untouched.
  * fast-forwarding the returned copy is left to the existing sync jobs.
Exit code: 0 on any outcome that was reported; 1 on a broken registry.
"""

import argparse
import fcntl
import importlib.util
import subprocess
import sys
import time
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import repo_registry  # noqa: E402

SHARED_PREFIXES = ("PACK-", "DS-IT-systems/")
SHARED_CLASSES = ("reader", "service")


def _load_reader_helpers():
    """Reuse the reader job's own safety checks instead of copying them (OwnerIntegrity)."""
    spec = importlib.util.spec_from_file_location("reader_copies_sync", SCRIPTS / "reader-copies-sync.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


reader = _load_reader_helpers()


def log(message):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [shared-copies-refresh] {message}", flush=True)


def heal_one(repo, expected_branch, upstream, dry_run):
    """One line of outcome: 'current', 'returned <from>', 'would return <from>' or 'BLOCKED <reason>'."""
    rc, branch, _ = reader.git(repo, "branch", "--show-current")
    if rc != 0:
        return "BLOCKED не читается ветка"
    if branch == expected_branch:
        return "current"
    reason = reader.blocked_reason(repo, branch)  # same clean/in-progress/hidden-edits test, on the branch it is on
    if reason:
        return f"BLOCKED {reason}"
    rc, target, _ = reader.git(repo, "rev-parse", "--verify", "--quiet", f"{upstream}^{{commit}}")
    if rc != 0:
        return f"BLOCKED нет ссылки {upstream}"
    if reader.git(repo, "merge-base", "--is-ancestor", "HEAD", target)[0] != 0:
        return f"BLOCKED вершина {branch or '(detached)'} ещё не на {upstream}: возвращать нельзя, коммиты останутся только там"
    where = branch or "(detached)"
    if dry_run:
        return f"would return {where}"
    if reader.git(repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{expected_branch}")[0] == 0:
        rc, _, err = reader.git(repo, "switch", "--quiet", expected_branch)
    else:
        rc, _, err = reader.git(repo, "switch", "--quiet", "--create", expected_branch, "--track", upstream)
    if rc != 0:
        return f"BLOCKED переключение отказало: {err.splitlines()[-1] if err else rc}"
    rc, now, _ = reader.git(repo, "branch", "--show-current")
    if now != expected_branch:
        return f"BLOCKED после переключения копия на {now or '(detached)'}, проверить вручную"
    if reader.git(repo, "merge-base", "--is-ancestor", "HEAD", target)[0] != 0:
        # The branch was put back, but its own tip holds commits origin lacks (or diverged): the
        # reader sync will report it as BLOCKED; say so here instead of claiming a clean return.
        return f"returned {where}; но {expected_branch} расходится с {upstream}, нужен разбор вручную"
    return f"returned {where}"


def shared_checkouts(registry, host):
    seen = set()
    for cls in SHARED_CLASSES:
        for entry, checkout in repo_registry.checkouts_of_class(registry, cls, host):
            path = checkout["path"]
            if path in seen or not path.startswith(SHARED_PREFIXES):
                continue
            seen.add(path)
            yield entry, checkout


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=str(Path.home() / "IWE"))
    parser.add_argument("--registry", default=str(SCRIPTS / "repo-convergence.registry.yaml"))
    parser.add_argument("--host", default=None, help="registry host id; default: detected")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    registry, errors = repo_registry.load(args.registry)
    if registry is None:
        log("FAIL реестр: " + "; ".join(errors))
        return 1
    host = args.host or repo_registry.host_id()
    root = Path(args.root)

    lock_path = root / ".iwe-runtime" / "shared-copies-refresh.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("SKIP другой запуск держит замок")
            return 0
        counts = {}
        for entry, checkout in shared_checkouts(registry, host):
            repo = root / checkout["path"]
            if not (repo / ".git").exists():
                outcome = "absent"
            else:
                try:
                    outcome = heal_one(repo, entry.get("expected_branch", "main"),
                                       entry.get("upstream", "origin/main"), args.dry_run)
                except subprocess.TimeoutExpired as exc:
                    outcome = f"BLOCKED git дольше {exc.timeout:.0f} с"
                except Exception as exc:  # one broken copy must not skip the rest; reported, not swallowed
                    outcome = f"BLOCKED ошибка {exc.__class__.__name__}: {exc}"
            kind = outcome.split()[0]
            counts[kind] = counts.get(kind, 0) + 1
            if kind not in ("current", "absent"):
                log(f"{checkout['path']}: {outcome}")
        log("итог: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) if counts
            else "итог: общих копий на этом хосте нет")
    return 0


if __name__ == "__main__":
    sys.exit(main())
