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
  * a checkout with `shared_lock: ds-commit` (the Mac root, pilot decision 13.11.2026) is also used
    by sessions and the publication gateway: it is moved only under ds-commit.lock taken
    non-blocking (busy -> SKIP this tick). Manual `git checkout` takes no lock, so the branch is
    re-read right before and after the merge; the residual window is accepted, not closed.
Exit code: 0 when every copy is current/moved/blocked-and-reported; 1 on a broken registry.
"""

import argparse
import fcntl
import os
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


def same_bytes(repo, path, target, name):
    """True when `path` is a regular file whose raw bytes (no .gitattributes filters) equal target:name."""
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    rc_local, local, _ = git(repo, "hash-object", "--no-filters", "--", str(path))
    rc_target, wanted, _ = git(repo, "rev-parse", f"{target}:{name}")
    return rc_local == 0 and rc_target == 0 and local == wanted


def files_in_the_way(repo, target):
    """(identical, differing): untracked local files (ignored or not) at paths the fast-forward adds.

    git refuses a merge over a plain untracked file and silently replaces an ignored one. A regular file
    whose raw bytes already equal the target blob is set aside (park_identical) instead of blocking:
    a scheduled writer that publishes elsewhere and leaves its copy behind (MC-sessions elar-window,
    14.11.2026) is the usual case. Anything else -- other bytes, a symlink -- blocks."""
    _, names, _ = git(repo, "diff", "--name-only", "-z", "--no-renames", "--diff-filter=A", f"HEAD..{target}")
    if not names:
        return [], []
    _, present, _ = git(repo, "ls-files", "-o", "-z", "--", *names.split("\0")[:-1])
    identical, differing = [], []
    for name in present.split("\0")[:-1]:
        (identical if same_bytes(repo, Path(repo) / name, target, name) else differing).append(name)
    return identical, differing


def park_identical(repo, names, target):
    """Move byte-equal copies out of the way into the git dir; re-check them there.

    Nothing is deleted: a writer that touches a file between the check and the move ends up with its
    bytes in the parked copy, which then fails the re-check and everything is put back.
    Returns (parked [(name, parked_path)], None) or ([], reason)."""
    _, git_dir, _ = git(repo, "rev-parse", "--absolute-git-dir")
    stamp = time.strftime("%Y%m%dT%H%M%S")
    parked = []
    for name in names:
        dest = Path(git_dir) / "reader-sync-parked" / stamp / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        os.rename(Path(repo) / name, dest)
        parked.append((name, dest))
        if not same_bytes(repo, dest, target, name):
            restore_parked(repo, parked)
            return [], f"файл {name} изменился во время перемотки"
    return parked, None


def restore_parked(repo, parked):
    """Put parked copies back where nothing new took their place; report the ones that stay parked."""
    kept = []
    for name, dest in parked:
        home = Path(repo) / name
        if home.exists() or home.is_symlink():
            kept.append(str(dest))
        else:
            os.rename(dest, home)
    if kept:
        log(f"{repo}: копии оставлены в {', '.join(kept[:3])} (на их месте появился новый файл)")


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
    identical, differing = files_in_the_way(repo, target)
    if differing:
        return ("BLOCKED перемотка заменит игнорируемые или неотслеживаемые локальные файлы, "
                f"отличные от GitHub: {', '.join(differing[:3])}")
    _, behind, _ = git(repo, "rev-list", "--count", f"HEAD..{target}")
    same_note = f" (одинаковые локальные копии отложены в .git/reader-sync-parked: {len(identical)})" if identical else ""
    if dry_run:
        return f"would move {behind}{same_note}"
    # A shared copy (the Mac root) can be switched by a manual checkout that takes no lock: re-read the
    # branch and HEAD right before the merge. This narrows the window, it does not close it.
    if not on_branch_at(repo, expected_branch, head):
        return "BLOCKED ветка или HEAD сменились во время проверки"
    parked, park_failure = park_identical(repo, identical, target)
    if park_failure:
        return f"BLOCKED {park_failure}"
    rc, _, err = git(repo, "merge", "--ff-only", "--no-autostash", "--no-overwrite-ignore", "--quiet", target,
                     timeout=MERGE_TIMEOUT_S)
    if rc != 0:
        restore_parked(repo, parked)
        return f"BLOCKED перемотка отказала: {err.splitlines()[-1] if err else rc}"
    if not on_branch_at(repo, expected_branch, target):
        return f"BLOCKED после перемотки копия не на {expected_branch}@{upstream}: проверить вручную"
    return f"moved {behind}{same_note}"


def on_branch_at(repo, expected_branch, sha):
    """True when the copy is still on `expected_branch` and HEAD is exactly `sha`."""
    rc, ref, _ = git(repo, "symbolic-ref", "--quiet", "HEAD")
    if rc != 0 or ref != f"refs/heads/{expected_branch}":
        return False
    rc, head, _ = git(repo, "rev-parse", "HEAD")
    return rc == 0 and head == sha


def ds_commit_lock_path(root):
    """Same file session-guard.sh, isolate-push.sh and tsekh1-git-sync.sh take (DRR WP-539 F21 B4)."""
    explicit = os.environ.get("DS_COMMIT_LOCK_FILE")
    return Path(explicit) if explicit else root / ".claude" / "state" / "ds-commit.lock"


def sync_shared(repo, root, expected_branch, upstream, dry_run):
    """sync_one under the shared ds-commit.lock, non-blocking: this script already holds its own lock
    (B4 order invariant), and a busy lock means a session start or a publication -- skip this tick."""
    lock_path = ds_commit_lock_path(root)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "a") as shared:
        try:
            fcntl.flock(shared, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return "SKIP общий замок занят (старт сессии или публикация), следующий проход через 5 мин"
        return sync_one(repo, expected_branch, upstream, dry_run)


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
                branch, upstream = entry.get("expected_branch", "main"), entry.get("upstream", "origin/main")
                try:
                    if checkout.get("shared_lock") == "ds-commit":
                        outcome = sync_shared(repo, root, branch, upstream, args.dry_run)
                    else:
                        outcome = sync_one(repo, branch, upstream, args.dry_run)
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
