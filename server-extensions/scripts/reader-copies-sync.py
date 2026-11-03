#!/usr/bin/env python3
"""Fast-forward clean reader checkouts of this host to their already-fetched upstream.

WP-539, pilot decision 03.11.2026 (peer-session 2026-11-03-12-wp539-sync-processes-audit).
Packs, FPF, SPF and ZP on the Mac had no executor at all: refs-sync-broker fetched nothing for
them and nothing moved the working tree, so style hooks read rules 31 commits old.

Contract:
  * WHICH checkouts: effective class `reader` for this host in repo-convergence.registry.yaml.
  * fetching is NOT done here: refs-sync-broker owns fetch rights (refs-sync-broker.repos.yaml);
    this script only moves a working tree to an upstream ref that is already local.
  * moves only a clean copy (no tracked changes) on its expected branch, only when HEAD is an
    ancestor of upstream (`merge --ff-only --no-autostash`); anything else is reported as
    BLOCKED and left untouched -- the morning convergence digest shows it.
Exit code: 0 when every copy is current/moved/blocked-and-reported; 1 on a broken registry.
"""

import argparse
import fcntl
import subprocess
import sys
import time
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import repo_registry  # noqa: E402

GIT_TIMEOUT_S = 60
MERGE_TIMEOUT_S = 600  # a killed merge can leave index.lock behind: give the one mutating call room
IN_PROGRESS = ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply")


def log(message):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [reader-copies-sync] {message}", flush=True)


def git(repo, *args, timeout=GIT_TIMEOUT_S):
    proc = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                          errors="replace", timeout=timeout)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def blocked_reason(repo, expected_branch):
    """Why this copy must not be moved, or None. Anything that could hide local work blocks."""
    rc, branch, _ = git(repo, "branch", "--show-current")
    if rc != 0:
        return "не читается ветка"
    if branch != expected_branch:
        return f"ветка {branch or '(detached)'} вместо {expected_branch}"
    for marker in IN_PROGRESS:
        _, path, _ = git(repo, "rev-parse", "--git-path", marker)
        if (Path(repo) / path).exists():
            return f"незавершённая операция git ({marker})"
    rc, changes, _ = git(repo, "status", "--porcelain", "--untracked-files=no")
    if rc != 0:
        return "не читается состояние"
    if changes:
        return f"незакоммиченные правки ({len(changes.splitlines())})"
    # assume-unchanged / skip-worktree files hide edits from `status`
    _, tags, _ = git(repo, "ls-files", "-v")
    if any(line[:1] not in ("H", "") for line in tags.splitlines()):
        return "есть файлы со скрытыми правками (assume-unchanged/skip-worktree)"
    return None


def ignored_overwritten(repo, target):
    """Ignored local files that the fast-forward would silently replace with tracked ones."""
    _, names, _ = git(repo, "diff", "--name-only", "--diff-filter=A", f"HEAD..{target}")
    if not names:
        return []
    _, ignored, _ = git(repo, "ls-files", "-o", "-i", "--exclude-standard", "--", *names.splitlines())
    return ignored.splitlines()


def sync_one(repo, expected_branch, upstream, dry_run):
    """One line of outcome: 'current', 'moved N', or 'BLOCKED <reason>'."""
    reason = blocked_reason(repo, expected_branch)
    if reason:
        return f"BLOCKED {reason}"
    rc, target, _ = git(repo, "rev-parse", "--verify", "--quiet", f"{upstream}^{{commit}}")
    if rc != 0:
        return f"BLOCKED нет ссылки {upstream} (брокер ещё не получал?)"
    rc, head, _ = git(repo, "rev-parse", "HEAD")
    if head == target:
        return "current"
    if git(repo, "merge-base", "--is-ancestor", "HEAD", target)[0] != 0:
        return f"BLOCKED свои коммиты, не перемотка ({upstream} не потомок HEAD)"
    clobbered = ignored_overwritten(repo, target)
    if clobbered:
        return f"BLOCKED перемотка заменит игнорируемые локальные файлы: {', '.join(clobbered[:3])}"
    _, behind, _ = git(repo, "rev-list", "--count", f"HEAD..{target}")
    if dry_run:
        return f"would move {behind}"
    rc, _, err = git(repo, "merge", "--ff-only", "--no-autostash", "--quiet", target, timeout=MERGE_TIMEOUT_S)
    if rc != 0:
        return f"BLOCKED перемотка отказала: {err.splitlines()[-1] if err else rc}"
    return f"moved {behind}"


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

    lock_path = root / ".iwe-runtime" / "reader-copies-sync.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("SKIP другой запуск держит замок")
            return 0
        counts = {}
        for entry, checkout in repo_registry.checkouts_of_class(registry, "reader", host):
            repo = root / checkout["path"]
            if not (repo / ".git").exists():
                outcome = "absent (optional)" if checkout.get("optional") else "BLOCKED нет копии на диске"
            else:
                try:
                    outcome = sync_one(repo, entry.get("expected_branch", "main"), entry.get("upstream", "origin/main"), args.dry_run)
                except subprocess.TimeoutExpired as exc:
                    outcome = f"BLOCKED git дольше {exc.timeout:.0f} с"
                except Exception as exc:  # one broken copy must not skip the rest; reported, not swallowed
                    outcome = f"BLOCKED ошибка {exc.__class__.__name__}: {exc}"
            kind = outcome.split()[0]
            counts[kind] = counts.get(kind, 0) + 1
            if kind != "current":
                log(f"{checkout['path']}: {outcome}")
        log("итог: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) if counts else "итог: читательских копий на этом хосте нет")
    return 0


if __name__ == "__main__":
    sys.exit(main())
