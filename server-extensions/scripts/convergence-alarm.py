#!/usr/bin/env python3
"""Daytime alarm: a managed copy of this host stays off its upstream longer than its threshold.

WP-539 F21 B0, pilot decision 13.11.2026: the morning digest alone left a 14-commit lag of the
Mac root unnoticed for a whole day.

Contract:
  * WHICH copies: registry checkouts of this host with effective class canon or reader whose entry
    sets thresholds.behind_observed_for_min (null = not watched, as everywhere in the registry).
  * WHAT counts: relation of HEAD to its upstream ref, as the morning report computes it. The ref is
    kept fresh by refs-sync-broker and nothing is fetched here, so `equal` counts only while the
    broker confirmed a fetch within FETCH_STALE_MIN; a stale or never-confirmed fetch is an episode of
    its own. A pure `ahead` (own commits on their way through the publication gateway) gets
    AHEAD_GRACE_MIN; behind/diverged get the registry threshold.
  * WHEN: one message per episode once it lasts >= its threshold, and one "снова совпадает" when an
    alarmed copy is back. Both stay in the state until actually sent: quiet hours (default 23-08
    local; equal hours = none) and a failed send defer them to the next run.
  * WHY: the last line the reader mover wrote about that copy, when there is one.
Exit code: 0 on success, 1 when the registry is broken or a message could not be sent (the episode
stays unsent and is retried on the next run).
"""

import argparse
import datetime as dt
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import repo_registry  # noqa: E402

_spec = importlib.util.spec_from_file_location("convergence_report", SCRIPTS / "convergence-report.py")
report = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(report)

WATCHED_CLASSES = ("canon", "reader")
READER_LOG_TAIL = 400
FETCH_STALE_MIN = 120  # the broker runs every few minutes; two hours without a confirmed fetch is broken
AHEAD_GRACE_MIN = 120  # a session commit normally reaches GitHub within minutes
REPEAT_MIN = 360  # an alarmed episode that lasts is repeated this often (6 h), only after a message was really sent


def now_local():
    return dt.datetime.now().astimezone()


def watched(registry, host):
    """(path, threshold_min) of the copies this host must keep on their upstream."""
    out = []
    for cls in WATCHED_CLASSES:
        for entry, checkout in repo_registry.checkouts_of_class(registry, cls, host):
            threshold = (entry.get("thresholds") or {}).get("behind_observed_for_min")
            if threshold is not None:
                out.append((checkout["path"], threshold))
    return sorted(out)


def last_reader_line(log_path, path):
    """Last line the reader mover wrote about `path` ('<path>: <outcome>'), or ''."""
    try:
        lines = Path(log_path).read_text(encoding="utf-8", errors="replace").splitlines()[-READER_LOG_TAIL:]
    except OSError:
        return ""
    marker = f"] {path}: "
    for line in reversed(lines):
        if marker in line:
            return line.split(marker, 1)[1]
    return ""


def assess(relation, fetched, threshold, now):
    """(label, threshold) for one copy: `equal` only when the upstream ref itself is fresh."""
    if relation.startswith("ahead"):
        return relation, max(threshold, AHEAD_GRACE_MIN)
    if relation != "equal":
        return relation, threshold
    if fetched is None:
        return "нет подтверждённого получения данных с GitHub", FETCH_STALE_MIN
    stale_min = int((now - fetched).total_seconds() // 60)
    if stale_min > FETCH_STALE_MIN:
        return f"данные с GitHub не обновлялись {stale_min} мин", 0
    return "equal", threshold


def plural_commits(n):
    """'1 коммит', '2 коммита', '5 коммитов' (Russian plural of the number that follows 'на')."""
    if n % 10 == 1 and n % 100 != 11:
        return f"{n} коммит"
    if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        return f"{n} коммита"
    return f"{n} коммитов"


def humanize(label):
    """Message text of a relation label. The label itself ('behind -27') stays as the report computes it:
    its format is pinned by the morning report, only the message to the pilot gets words.
    `behind -27` is 'позади на 27 коммитов', not a negative number (found 16.11, WP-539)."""
    kind, _, rest = label.partition(" ")
    if kind == "behind" and rest.startswith("-") and rest[1:].isdigit():
        return f"позади на {plural_commits(int(rest[1:]))}"
    if kind == "ahead" and rest.startswith("+") and rest[1:].isdigit():
        return f"впереди на {plural_commits(int(rest[1:]))}"
    if kind == "diverged" and rest.count("/") == 1:
        ahead, behind = rest.split("/")
        if ahead.startswith("+") and behind.startswith("-") and ahead[1:].isdigit() and behind[1:].isdigit():
            return f"расходится: впереди на {plural_commits(int(ahead[1:]))}, позади на {plural_commits(int(behind[1:]))}"
    return label


def relation_kind(label):
    return label.split(" ", 1)[0]


def alarm_text(path, label, minutes, threshold, kind_since, repeat):
    """One alarm message. The episode clock runs from the first deviation of any kind (`minutes`), so a
    detached copy says how long the whole divergence lasts and since when the copy has no branch."""
    if label == "detached":
        since = f" (с {kind_since:%H:%M})" if kind_since else ""
        body = f"расхождение длится {minutes} мин (порог {threshold}); сейчас копия без ветки{since}"
    else:
        body = f"{humanize(label)} уже {minutes} мин (порог {threshold})"
    return f"⚠️ {path}: {body}" + (" — повторное сообщение, эпизод не закрыт" if repeat else "")


def step(state, path, label, threshold, now):
    """Advance one copy's episode; return the message to send for it, or None.

    A recovery of an alarmed episode stays in the state (recovered=True) until main() has sent it.
    An alarmed episode that lasts is repeated every REPEAT_MIN minutes after the last message that was
    actually sent: one message per episode left a second day of the same breakage silent (16.11, WP-539)."""
    episode = state.get(path)
    if label == "equal":
        if not episode:
            return None
        if not episode.get("alerted"):
            del state[path]
            return None
        episode["recovered"] = True
        return f"✅ {path}: снова совпадает с GitHub"
    if not episode:
        state[path] = {"since": now.isoformat(), "relation": label, "alerted": False}
        return None
    if relation_kind(episode["relation"]) != relation_kind(label):
        episode["kind_since"] = now.isoformat()
    episode["relation"] = label
    episode.pop("recovered", None)
    minutes = int((now - dt.datetime.fromisoformat(episode["since"])).total_seconds() // 60)
    kind_since = episode.get("kind_since")
    kind_since = dt.datetime.fromisoformat(kind_since).astimezone() if kind_since else None
    if episode["alerted"]:
        if "last_alert" not in episode:  # state written before repeats existed: count from the first run with them
            episode["last_alert"] = now.isoformat()
            return None
        since_alert = (now - dt.datetime.fromisoformat(episode["last_alert"])).total_seconds() // 60
        if since_alert < REPEAT_MIN:
            return None
        return alarm_text(path, label, minutes, threshold, kind_since, repeat=True)
    if minutes < threshold:
        return None
    return alarm_text(path, label, minutes, threshold, kind_since, repeat=False)


def in_quiet_hours(now, start, end):
    """Quiet window [start, end) in local hours, may wrap midnight; start == end means no quiet hours."""
    if start == end:
        return False
    if start < end:
        return start <= now.hour < end
    return now.hour >= start or now.hour < end


def log_messages(now, outcome, pending):
    """One log line per message: when, what happened to it, and its headline (copy + alarm or recovery),
    so a day of the log can be audited for false alarms without Telegram (WP-539 Ф21 Б0, 14.11)."""
    for _, text in pending:
        print(f"convergence-alarm: {now:%Y-%m-%dT%H:%M%z} {outcome}: {text.splitlines()[0]}")


TELEGRAM_SOURCE_ID = "convergence-alarm"
OUTCOME_MARKER = "CONVERGENCE_SEND_OUTCOME="
DELIVERED_OUTCOMES = {"sent", "deferred"}


def send_telegram(lib, text):
    # The gate identifies a sender by TELEGRAM_SOURCE_ID, else by the basename of $0.
    # With neither, $0 was "_" and the digest quarantined a real alarm as
    # "вне реестра: _" (WP-484 F313, 18.11).
    # An outcome inherited from our own environment must not pass for this send's result.
    env = {key: value for key, value in os.environ.items() if key != "TELEGRAM_SEND_OUTCOME"}
    env["TELEGRAM_SOURCE_ID"] = TELEGRAM_SOURCE_ID
    # telegram_send exits 0 for a quarantined message too; what really happened is in
    # TELEGRAM_SEND_OUTCOME (WP-538 Ф7). Only "sent" (and "deferred": the message is queued into the
    # digest, the channel's own delivery guarantee) counts as delivered, so a quarantined alarm
    # stays unsent and is retried instead of being logged as sent for three days (WP-484 Ф316, 19.11).
    # The marker is printed whatever the exit code was: a send that went out and then failed late
    # must not be repeated every 15 minutes. Newlines are stripped from the value so it cannot
    # forge a second marker line.
    script = ('. "$1"; unset TELEGRAM_SEND_OUTCOME; telegram_send "$2"; rc=$?; '
              'printf "\\n%s%s\\n" "' + OUTCOME_MARKER + '" "$(printf %s "${TELEGRAM_SEND_OUTCOME:-}" | tr -d "\\n\\r")"; exit $rc')
    proc = subprocess.run(["bash", "-c", script, Path(__file__).name, str(lib), text],
                          capture_output=True, text=True, timeout=60, env=env, check=False)
    outcome = next((line[len(OUTCOME_MARKER):] for line in reversed(proc.stdout.splitlines())
                    if line.startswith(OUTCOME_MARKER)), "")
    if outcome in DELIVERED_OUTCOMES:
        if proc.returncode != 0:
            print(f"convergence-alarm: telegram_send exited {proc.returncode} after outcome {outcome}; counted as delivered",
                  file=sys.stderr)
        return True
    if proc.returncode != 0:
        print(f"convergence-alarm: telegram_send failed: {proc.stderr.strip()[-300:]}", file=sys.stderr)
    else:
        print(f"convergence-alarm: message not delivered (outcome: {outcome or 'none'}) - episode stays unsent",
              file=sys.stderr)
    return False


def load_state(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:  # a broken state restarts episodes; said aloud, not hidden
        print(f"convergence-alarm: state unreadable ({exc.__class__.__name__}), starting over", file=sys.stderr)
        return {}


def save_state(path, state):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=str(Path.home() / "IWE"))
    parser.add_argument("--registry", default=str(SCRIPTS / "repo-convergence.registry.yaml"))
    parser.add_argument("--host", default=None, help="registry host id; default: detected")
    parser.add_argument("--state", default=None, help="default: <root>/.iwe-runtime/convergence-alarm.json")
    parser.add_argument("--reader-log", default=None,
                        help="default: <root>/DS-my-strategy/logs/reader-copies-sync.log")
    parser.add_argument("--telegram-lib", default=None,
                        help="default: <root>/DS-my-strategy/scripts/lib/telegram.sh")
    parser.add_argument("--quiet-from", type=int, default=23)
    parser.add_argument("--quiet-to", type=int, default=8)
    parser.add_argument("--dry-run", action="store_true", help="print messages, do not send or save state")
    args = parser.parse_args()

    root = Path(args.root)
    registry, errors = repo_registry.load(args.registry)
    if registry is None:
        print("convergence-alarm: FAIL реестр: " + "; ".join(errors), file=sys.stderr)
        return 1
    host = args.host or repo_registry.host_id()
    state_path = args.state or root / ".iwe-runtime" / "convergence-alarm.json"
    reader_log = args.reader_log or root / "DS-my-strategy" / "logs" / "reader-copies-sync.log"
    telegram_lib = args.telegram_lib or root / "DS-my-strategy" / "scripts" / "lib" / "telegram.sh"

    state = load_state(state_path)
    now = now_local()
    fetch_times, _ = report.broker_fetch_times(root)
    pending = []  # (path, text); an alarm is marked sent only after a successful send
    for path, threshold in watched(registry, host):
        repo = root / path
        if not (repo / ".git").exists():
            continue  # absent copies are the morning report's business
        relation, upstream, _ = report.relation(repo)
        label, limit = assess(relation, fetch_times.get((repo, upstream)), threshold, now)
        text = step(state, path, label, limit, now)
        if text:
            reason = last_reader_line(reader_log, path) if label != "equal" else ""
            pending.append((path, text + (f"\nперемотка: {reason}" if reason else "")))

    if not pending:
        status = 0
    elif args.dry_run:
        print("\n\n".join(t for _, t in pending))
        status = 0
    elif in_quiet_hours(now, args.quiet_from, args.quiet_to):
        log_messages(now, "deferred (quiet hours)", pending)
        status = 0
    elif send_telegram(telegram_lib, "🔄 Сходимость git, Мак\n\n" + "\n\n".join(t for _, t in pending)):
        for path, _ in pending:
            if state.get(path, {}).get("recovered"):
                del state[path]
            elif path in state:
                state[path]["alerted"] = True
                state[path]["last_alert"] = now.isoformat()
        log_messages(now, "sent", pending)
        status = 0
    else:
        log_messages(now, "send failed, retried next run", pending)
        status = 1
    if not args.dry_run:
        save_state(state_path, state)
    return status


if __name__ == "__main__":
    sys.exit(main())
