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

# --- WP-484 F312: a copy BLOCKED for a day gets one message through iwe-notify ---
import json, fcntl, os

def expect(name, cond, detail=""):
    global failures
    if cond:
        print(f"PASS: {name}")
    else:
        failures += 1
        print(f"FAIL: {name} {detail}")

calls = work / "notify-calls.txt"
notify_rc = work / "notify-rc"
notify_outcome = work / "notify-outcome"
fake_notify = work / "fake-notify"
fake_notify.write_text(
    "#!/usr/bin/env bash\n"
    f"printf '%s|%s|%s\\n' \"$1\" \"$2\" \"$TELEGRAM_NEEDS_DECISION\" | head -c 400 >> '{calls}'\n"
    f"printf '%s\\n' \"$3\" >> '{calls}'\n"
    f"echo \"iwe-notify: outcome=$(cat '{notify_outcome}')\"\n"
    f"exit $(cat '{notify_rc}')\n")
fake_notify.chmod(0o755)
notify_rc.write_text("0")
notify_outcome.write_text("sent")
state_file = work / "state.json"
H = 3600.0
t0 = 1_000_000.0

def run(outcomes, now, after=24):
    refresh.report_long_blocks(state_file, outcomes, str(fake_notify), after, now)
    return json.loads(state_file.read_text())

def n_calls():
    return calls.read_text().count("--source|shared-copies-refresh|") if calls.exists() else 0

st = run({"PACK-a": "BLOCKED новые неотслеживаемые файлы (1)", "PACK-b": "current"}, t0)
expect("episode starts, no message before the threshold", n_calls() == 0 and list(st) == ["PACK-a"], st)
st = run({"PACK-a": "BLOCKED ветку переключали 5 мин назад"}, t0 + 23 * H)
expect("new reason keeps the episode start", st["PACK-a"]["first_blocked_at"] == t0
       and st["PACK-a"]["last_reason"].startswith("ветку") and n_calls() == 0, st)
notify_rc.write_text("1")
st = run({"PACK-a": "BLOCKED ветку переключали 5 мин назад"}, t0 + 24 * H)
expect("failed iwe-notify leaves notified=false", n_calls() == 1 and st["PACK-a"]["notified"] is False, st)
notify_rc.write_text("0")
for outcome, hour in (("not-sent", 24.2), ("deferred", 24.4), ("", 24.6)):
    notify_outcome.write_text(outcome)
    st = run({"PACK-a": "BLOCKED ветку переключали 5 мин назад"}, t0 + hour * H)
    expect(f"exit 0 with outcome={outcome or 'missing'} is not a delivery", st["PACK-a"]["notified"] is False, st)
notify_outcome.write_text("sent")
st = run({"PACK-a": "BLOCKED ветку переключали 5 мин назад"}, t0 + 25 * H)
text = calls.read_text()
expect("next run retries and marks notified", n_calls() == 5 and st["PACK-a"]["notified"] is True, st)
expect("message: decision flag, both reasons, what to do",
       "|shared-copies-refresh|1" in text and "новые неотслеживаемые файлы" in text
       and "сейчас: ветку переключали" in text and "Что делать:" in text, text[-600:])
st = run({"PACK-a": "BLOCKED ветку переключали 5 мин назад"}, t0 + 48 * H)
expect("one message per episode", n_calls() == 5, n_calls())
st = run({"PACK-a": "current"}, t0 + 49 * H)
expect("current ends the episode", st == {}, st)
st = run({"PACK-a": "BLOCKED x"}, t0 + 50 * H)
st = run({}, t0 + 80 * H)
expect("copy gone from the registry ends the episode, no message", st == {} and n_calls() == 5, st)

# The whole read -> notify -> write runs under the job's lock: a second run while it is held skips.
root = work / "root"
(root / ".iwe-runtime").mkdir(parents=True)
lock = open(root / ".iwe-runtime" / "shared-copies-refresh.lock", "w")
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
cmd = [sys.executable, str(scripts / "shared-copies-refresh.py"), "--root", str(root),
       "--host", "no-such-host", "--notify-cmd", str(fake_notify)]
out = subprocess.run(cmd, capture_output=True, text=True)
expect("held lock: run skipped, state untouched",
       out.returncode == 0 and "SKIP" in out.stdout
       and not (root / ".iwe-runtime" / "shared-copies-refresh.state.json").exists(), out.stdout + out.stderr)
lock.close()
out = subprocess.run(cmd, capture_output=True, text=True)
expect("free lock: run writes its state",
       out.returncode == 0 and (root / ".iwe-runtime" / "shared-copies-refresh.state.json").exists(),
       out.stdout + out.stderr)

# Garbled state of any shape must not raise (a failing unit rolls back the server deploy).
for garbled in ('[1, 2]', '"x"', '{"PACK-a": "x"}', '{"PACK-a": {"first_reason": "r"}}',
                '{"PACK-a": {"first_blocked_at": "soon", "first_reason": "r"}}',
                '{"PACK-a": {"first_blocked_at": 0, "first_reason": "r"}}'):
    state_file.write_text(garbled)
    try:
        st = run({"PACK-a": "BLOCKED x"}, t0 + 100 * H)
        expect(f"garbled state {garbled}: no exception, valid episode kept or restarted",
               isinstance(st.get("PACK-a"), dict) and "first_blocked_at" in st["PACK-a"], st)
    except Exception as exc:
        expect(f"garbled state {garbled}: no exception", False, repr(exc))

# A non-finite or non-positive start is garbled too: NaN would never notify, 0 or -Infinity at once.
for garbled in ('{"PACK-a": {"first_blocked_at": NaN, "first_reason": "r"}}',
                '{"PACK-a": {"first_blocked_at": -Infinity, "first_reason": "r"}}',
                '{"PACK-a": {"first_blocked_at": 0, "first_reason": "r"}}'):
    state_file.write_text(garbled)
    st = run({"PACK-a": "BLOCKED x"}, t0 + 100 * H)
    expect(f"bad start {garbled}: episode restarts now", st["PACK-a"]["first_blocked_at"] == t0 + 100 * H
           and st["PACK-a"]["notified"] is False, st)

print(f"failures: {failures}")
sys.exit(1 if failures else 0)
PY
