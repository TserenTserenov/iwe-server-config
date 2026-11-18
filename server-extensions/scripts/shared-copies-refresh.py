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
    detached), it has no tracked changes, no untracked files and no half-finished git operation,
    HEAD has not moved for QUIET_MINUTES (a session may still be working on the branch it just
    switched to), and its current tip is already contained in the upstream ref (so nothing
    reachable only from this tip is left behind).
  * anything else is reported as BLOCKED and left untouched.
  * fast-forwarding the returned copy is left to the existing sync jobs.
  * a copy BLOCKED without a break for NOTIFY_AFTER_HOURS gets one message through iwe-notify
    (WP-484 F312). Episode = uninterrupted BLOCKED; a new reason does not restart it (a copy
    flapping between two reasons would otherwise never reach the threshold); any other outcome
    or the copy leaving the registry ends it. Delivery is at least once per episode: a crash
    between a delivered message and the state write repeats it next hour.
Exit code: 0 on any outcome that was reported; 1 on a broken registry. Never non-zero for a
BLOCKED copy: a failing timer unit rolls back the whole tsekh-1 deploy.
"""

import argparse
import datetime
import fcntl
import importlib.util
import json
import math
import os
import subprocess
import sys
import time
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import repo_registry  # noqa: E402

SHARED_PREFIXES = ("PACK-", "DS-IT-systems/")
SHARED_CLASSES = ("reader", "service")
# Most of these copies are written to by sessions (class service, written_here), so a branch
# switch may be a session at work, not a leftover. Within this window after the last HEAD move the
# copy is left alone (cold review 17.11: a session that ran `git switch -c` and had only new files
# would have its next commit land on main after the hourly return).
QUIET_MINUTES = 120
NOTIFY_AFTER_HOURS = 24
# iwe-notify's outcome line: only these reached the phone (see scripts/iwe-notify header).
DELIVERED_OUTCOMES = {"sent", "direct-sent"}
# The pilot reads the message in Moscow time; the server clock is UTC.
MSK = datetime.timezone(datetime.timedelta(hours=3))
# iwe-notify-sources: shared-copies-refresh
NOTIFY_SOURCE = "shared-copies-refresh"


def _load_reader_helpers():
    """Reuse the reader job's own safety checks instead of copying them (OwnerIntegrity)."""
    spec = importlib.util.spec_from_file_location("reader_copies_sync", SCRIPTS / "reader-copies-sync.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


reader = _load_reader_helpers()


def log(message):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [shared-copies-refresh] {message}", flush=True)


def minutes_since_head_moved(repo):
    """Minutes since the last HEAD reflog entry (switch, commit, reset), or None without a reflog."""
    rc, stamp, _ = reader.git(repo, "reflog", "-1", "--date=unix", "--format=%gd", "HEAD")
    if rc != 0 or not stamp.startswith("HEAD@{") or not stamp.endswith("}"):
        return None
    try:
        moved_at = int(stamp[len("HEAD@{"):-1])
    except ValueError:
        return None
    return (time.time() - moved_at) / 60


def session_activity_reason(repo, quiet_minutes):
    """Why this copy may still be in a session's hands, or None."""
    rc, untracked, _ = reader.git(repo, "ls-files", "--others", "--exclude-standard")
    if rc != 0:
        return "не читается список новых файлов"
    if untracked:
        return f"новые неотслеживаемые файлы ({len(untracked.splitlines())}), возможно, идёт работа"
    minutes = minutes_since_head_moved(repo)
    if minutes is None:
        # No reflog (disabled or expired): the quiet window cannot be proven, so do not move it.
        return "нет журнала перемещений HEAD, нельзя убедиться, что работа не идёт"
    if minutes < quiet_minutes:
        return f"ветку переключали {minutes:.0f} мин назад (< {quiet_minutes}), возможно, идёт работа"
    return None


def heal_one(repo, expected_branch, upstream, dry_run, quiet_minutes=QUIET_MINUTES):
    """One line of outcome: 'current', 'returned <from>', 'would return <from>' or 'BLOCKED <reason>'."""
    rc, branch, _ = reader.git(repo, "branch", "--show-current")
    if rc != 0:
        return "BLOCKED не читается ветка"
    if branch == expected_branch:
        return "current"
    reason = reader.blocked_reason(repo, branch)  # same clean/in-progress/hidden-edits test, on the branch it is on
    if reason:
        return f"BLOCKED {reason}"
    reason = session_activity_reason(repo, quiet_minutes)
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


def load_state(path):
    """Blocked episodes by copy path; an unreadable file starts over (logged), it never stops the job."""
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        log(f"WARN состояние {path} не читается ({exc}), начинаю заново")
        return {}
    if not isinstance(data, dict):
        log(f"WARN состояние {path} не словарь, начинаю заново")
        return {}
    state = {}
    for copy_path, ep in data.items():
        if (isinstance(ep, dict) and isinstance(ep.get("first_blocked_at"), (int, float))
                and not isinstance(ep.get("first_blocked_at"), bool)
                and math.isfinite(ep["first_blocked_at"]) and ep["first_blocked_at"] > 0
                and isinstance(ep.get("first_reason"), str)):
            state[copy_path] = {"first_blocked_at": ep["first_blocked_at"],
                                "first_reason": ep["first_reason"],
                                "last_reason": str(ep.get("last_reason") or ep["first_reason"]),
                                "notified": bool(ep.get("notified"))}
        else:
            log(f"WARN эпизод {copy_path} в состоянии повреждён, начинаю его заново")
    return state


def save_state(path, state):
    tmp = path.with_name(path.name + ".tmp")
    try:
        tmp.write_text(json.dumps(state, ensure_ascii=False, indent=1, sort_keys=True))
        os.replace(tmp, path)
    except OSError as exc:  # lost state only delays or repeats a message (at least once)
        log(f"WARN состояние {path} не записано: {exc}")
        tmp.unlink(missing_ok=True)


def track_episodes(state, outcomes, now):
    """Update blocked episodes from this run's outcomes {copy path: outcome}; returns the new state."""
    new_state = {}
    for path, outcome in outcomes.items():
        if not outcome.startswith("BLOCKED"):
            continue
        reason = outcome[len("BLOCKED "):]
        episode = dict(state.get(path) or {"first_blocked_at": now, "first_reason": reason, "notified": False})
        episode["last_reason"] = reason
        new_state[path] = episode
    return new_state


def due_episodes(state, now, notify_after_hours):
    return {path: ep for path, ep in state.items()
            if not ep.get("notified") and now - ep["first_blocked_at"] >= notify_after_hours * 3600}


def notify_text(due):
    lines = [f"Общие копии на сервере не возвращаются на свою ветку больше {NOTIFY_AFTER_HOURS} ч:"]
    for path, ep in sorted(due.items()):
        since = datetime.datetime.fromtimestamp(ep["first_blocked_at"], MSK).strftime("%d.%m %H:%M МСК")
        line = f"- {path}: {ep['first_reason']} (с {since})"
        if ep["last_reason"] != ep["first_reason"]:
            line += f"; сейчас: {ep['last_reason']}"
        lines.append(line)
    lines.append("Что делать: открыть копию, разобрать ветку и незакоммиченные файлы вручную; "
                 "служба вернёт копию сама, когда препятствие уйдёт.")
    return "\n".join(lines)


def send_notification(notify_cmd, text):
    """True only for a phone delivery: iwe-notify's outcome line says sent or direct-sent.

    Exit 0 also covers not-sent (no gateway, no credentials) and deferred (digest only), so
    the exit code alone would mark the one message of an episode delivered when it was not.
    """
    env = dict(os.environ, TELEGRAM_NEEDS_DECISION="1")
    try:
        proc = subprocess.run([notify_cmd, "--source", NOTIFY_SOURCE, text], env=env, check=False,
                              capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as exc:
        log(f"WARN уведомление не отправлено: {exc}")
        return False
    if proc.returncode != 0:
        log(f"WARN уведомление не отправлено: iwe-notify код {proc.returncode} {proc.stderr.strip()[-200:]}")
        return False
    outcome = next((line.split("=", 1)[1].strip() for line in proc.stdout.splitlines()
                    if line.startswith("iwe-notify: outcome=")), "")
    if outcome not in DELIVERED_OUTCOMES:
        log(f"WARN уведомление не доставлено на телефон: outcome={outcome or 'нет строки'}, повторю через час")
        return False
    log(f"уведомление: outcome={outcome}")
    return True


def report_long_blocks(state_path, outcomes, notify_cmd, notify_after_hours, now):
    state = track_episodes(load_state(state_path), outcomes, now)
    due = due_episodes(state, now, notify_after_hours)
    if due and send_notification(notify_cmd, notify_text(due)):
        for path in due:
            state[path]["notified"] = True
    save_state(state_path, state)


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
    parser.add_argument("--quiet-minutes", type=int, default=QUIET_MINUTES,
                        help="leave a copy alone this long after its HEAD last moved")
    parser.add_argument("--notify-after-hours", type=float, default=NOTIFY_AFTER_HOURS,
                        help="message once a copy has been BLOCKED this long without a break")
    parser.add_argument("--notify-cmd", default=None, help="default: <root>/scripts/iwe-notify")
    parser.add_argument("--now", type=float, default=None, help=argparse.SUPPRESS)  # tests only
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
        outcomes = {}
        for entry, checkout in shared_checkouts(registry, host):
            repo = root / checkout["path"]
            if not (repo / ".git").exists():
                outcome = "absent"
            else:
                try:
                    outcome = heal_one(repo, entry.get("expected_branch", "main"),
                                       entry.get("upstream", "origin/main"), args.dry_run,
                                       args.quiet_minutes)
                except subprocess.TimeoutExpired as exc:
                    outcome = f"BLOCKED git дольше {exc.timeout:.0f} с"
                except Exception as exc:  # one broken copy must not skip the rest; reported, not swallowed
                    outcome = f"BLOCKED ошибка {exc.__class__.__name__}: {exc}"
            kind = outcome.split()[0]
            counts[kind] = counts.get(kind, 0) + 1
            outcomes[checkout["path"]] = outcome
            if kind not in ("current", "absent"):
                log(f"{checkout['path']}: {outcome}")
        log("итог: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) if counts
            else "итог: общих копий на этом хосте нет")
        if not args.dry_run:  # still under the lock: one run reads, notifies and writes the state
            try:
                report_long_blocks(root / ".iwe-runtime" / "shared-copies-refresh.state.json", outcomes,
                                   args.notify_cmd or str(root / "scripts" / "iwe-notify"),
                                   args.notify_after_hours, args.now if args.now is not None else time.time())
            except Exception as exc:  # the message is optional; a failing unit would roll back the deploy
                log(f"WARN уведомление/состояние: {exc.__class__.__name__}: {exc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
