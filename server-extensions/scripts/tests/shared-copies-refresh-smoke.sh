#!/usr/bin/env bash
# shared-copies-refresh-smoke.sh -- heal_one() of scripts/shared-copies-refresh.py on throwaway
# repos: which shared copies the hourly job may put back on main and which it must leave alone.
# WP-484 F310 (17.11): cold review found the job returned a copy a session had just switched
# with `git switch -c` while holding only new files; its next commit would then land on main.
set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=smoke GIT_AUTHOR_EMAIL=smoke@example.invalid
export GIT_COMMITTER_NAME=smoke GIT_COMMITTER_EMAIL=smoke@example.invalid

python3 - "$SCRIPTS" "$WORK" <<'PY'
import importlib.util, subprocess, sys
from pathlib import Path

scripts, work = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("refresh", scripts / "shared-copies-refresh.py")
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)

def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True,
                          text=True).stdout.strip()

origin = work / "origin.git"
subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True)
seed = work / "seed"
subprocess.run(["git", "clone", "-q", str(origin), str(seed)], check=True, capture_output=True)
(seed / "a.txt").write_text("a\n")
git(seed, "add", "a.txt"); git(seed, "commit", "-q", "-m", "a"); git(seed, "push", "-q", "origin", "HEAD:main")

failures = 0
def check(name, outcome, expected_prefix, branch_after, repo):
    global failures
    now = git(repo, "branch", "--show-current")
    if outcome.startswith(expected_prefix) and now == branch_after:
        print(f"PASS: {name} -> {outcome}")
    else:
        failures += 1
        print(f"FAIL: {name}: got '{outcome}', branch '{now}'; expected '{expected_prefix}…', branch '{branch_after}'")

def copy(name):
    repo = work / name
    subprocess.run(["git", "clone", "-q", str(origin), str(repo)], check=True, capture_output=True)
    return repo

r = copy("on-main")
check("on main", refresh.heal_one(r, "main", "origin/main", False), "current", "main", r)

r = copy("fresh-switch")
git(r, "switch", "-q", "-c", "wp-live")
check("fresh switch, default quiet window", refresh.heal_one(r, "main", "origin/main", False),
      "BLOCKED ветку переключали", "wp-live", r)

r = copy("old-switch")
git(r, "switch", "-q", "-c", "leftover")
check("switch outside the quiet window", refresh.heal_one(r, "main", "origin/main", False, quiet_minutes=0),
      "returned leftover", "main", r)

r = copy("untracked")
git(r, "switch", "-q", "-c", "wp-new-files")
(r / "draft.md").write_text("work in progress\n")
check("only untracked files", refresh.heal_one(r, "main", "origin/main", False, quiet_minutes=0),
      "BLOCKED новые неотслеживаемые файлы", "wp-new-files", r)

r = copy("ignored-only")
(r / ".gitignore").write_text("*.log\n")
git(r, "add", ".gitignore"); git(r, "commit", "-q", "-m", "ignore"); git(r, "push", "-q", "origin", "HEAD:main")
git(r, "switch", "-q", "-c", "with-ignored")
(r / "run.log").write_text("x\n")
check("ignored files do not block", refresh.heal_one(r, "main", "origin/main", False, quiet_minutes=0),
      "returned with-ignored", "main", r)

r = copy("tracked-edit")
git(r, "switch", "-q", "-c", "wp-edit")
(r / "a.txt").write_text("changed\n")
check("tracked edit", refresh.heal_one(r, "main", "origin/main", False, quiet_minutes=0),
      "BLOCKED незакоммиченные правки", "wp-edit", r)

r = copy("own-commit")
git(r, "switch", "-q", "-c", "wp-commit")
(r / "b.txt").write_text("b\n"); git(r, "add", "b.txt"); git(r, "commit", "-q", "-m", "b")
check("commit not on origin", refresh.heal_one(r, "main", "origin/main", False, quiet_minutes=0),
      "BLOCKED вершина", "wp-commit", r)

r = copy("no-reflog")
git(r, "switch", "-q", "-c", "leftover")
git(r, "reflog", "expire", "--expire=now", "--all")
check("no reflog: age unknown", refresh.heal_one(r, "main", "origin/main", False, quiet_minutes=0),
      "BLOCKED нет журнала перемещений", "leftover", r)

r = copy("dry-run")
git(r, "switch", "-q", "-c", "leftover")
check("dry run changes nothing", refresh.heal_one(r, "main", "origin/main", True, quiet_minutes=0),
      "would return leftover", "leftover", r)

print(f"failures: {failures}")
sys.exit(1 if failures else 0)
PY
