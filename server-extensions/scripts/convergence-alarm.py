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
    The strategy copy is not moved by the reader mover but by the hourly Mac sync service; for it the
    WHY is that service's last refusal written during the episode, plus one line of what to do
    (WP-484 F327, 22.11: the alarm said only "behind by 340 commits" and nobody could act on it).
  * LOCAL BACKUPS (WP-484 F324, 20.11): a repository whose upstream is a bare repository on this disk
    (agent memory -> .iwe-runtime/backups/memory.git) is not on GitHub, so it is not in the registry and
    no broker fetches it. Memory and its backup diverged on 15.11 and stayed so for five days without a
    word. Such a copy is fetched here (local path only, never the network); `ahead` is its normal state
    (pushes are manual), only behind/diverged/unreachable open an episode.
  * HOW IT IS SENT (WP-484 F316 item 1, 20.11): straight to Telegram through the root `iwe-notify --direct`
    with the bot keys from the secrets file, never through the gateway of the strategy repository. The
    alarm is about copies falling behind, the strategy repository among them; its gateway and sender
    list were stale exactly when the alarm mattered (16-19.11: the alarms went to quarantine).
Exit code: 0 on success, 1 when the registry is broken or a message could not be sent (the episode
stays unsent and is retried on the next run).
"""

import argparse
import datetime as dt
import hashlib
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
LOG_HEAD_BYTES = 4096  # first bytes of the sync log that identify one file across rotation
FETCH_STALE_MIN = 120  # the broker runs every few minutes; two hours without a confirmed fetch is broken
AHEAD_GRACE_MIN = 120  # a session commit normally reaches GitHub within minutes
REPEAT_MIN = 360  # an alarmed episode that lasts is repeated this often (6 h), only after a message was really sent
# (path relative to the root, threshold in minutes) of copies whose upstream is a local bare repository.
LOCAL_BACKUPS = (("memory", 60),)
LOCAL_FETCH_TIMEOUT = 60


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


# What to do for a known reader-mover refusal: (prefix of the BLOCKED reason, action line).
READER_ACTIONS = (
    ("незакоммиченные правки", "что сделать: посмотреть эти правки в копии; опубликовать их или осознанно "
                               "отменить, после этого копия догонит сервер сама"),
    ("свои коммиты", "что сделать: опубликовать коммиты этой копии или разобрать, откуда они взялись"),
    ("ветка ", "что сделать: если работа на этой ветке закончена, вернуть копию на основную ветку"),
)


def reader_reason(outcome):
    """The reader mover's last outcome for a copy that is off its upstream, in words, plus what to do.

    The mover logs 'current', 'moved N', 'SKIP ...' or 'BLOCKED <reason>' (scripts/reader-copies-sync.py);
    until 24.11 the alarm pasted that line raw ("перемотка: BLOCKED незакоммиченные правки (1)", WP-568)."""
    if not outcome:
        return ""
    kind, _, rest = outcome.partition(" ")
    if kind == "BLOCKED":
        action = next((a for prefix, a in READER_ACTIONS if rest.startswith(prefix)), "")
        return f"копия не перематывается: {rest}" + (f"\n{action}" if action else "")
    if kind == "SKIP":
        return f"перемотка отложена: {rest}"
    if kind == "current":
        # The mover saw the copy at its upstream, the alarm sees it off: the two disagree, say so.
        return "журнал перемотки считает копию совпадающей с сервером, а сверка видит расхождение"
    if kind == "moved":
        how_far = f" ({rest})" if rest else ""
        return f"копию только что перемотали{how_far}, сверка догонит на следующем проходе"
    return f"последняя запись журнала перемотки: {outcome}"


# Copies moved by a sync service of their own instead of the reader mover: copy -> its error log.
SYNC_LOGS = {"DS-my-strategy": "DS-my-strategy/logs/mac-canon-sync-backstop.err.log"}
SYNC_REFUSAL_MARKERS = ("refused:", "dirty-overlap:", "ignored-overlap:", "proven fast-forward failed")
SYNC_REASON_MAX = 300
SYNC_ACTIONS = (
    ("dirty-overlap:", "что сделать: незакоммиченные правки на путях, которые меняет сервер — опубликовать или сохранить их, затем копия догонит сама"),
    ("ignored-overlap:", "что сделать: скрытый файл на пути сервера — сверить с версией сервера и убрать из папки, если совпадает"),
    ("refused:", "что сделать: отказ проверки перемотки — разобрать строку выше в беседе («проверь копию Мака»)"),
)


def _head_digest(stream, length):
    stream.seek(0)
    return hashlib.sha256(stream.read(length)).hexdigest()


def log_bookmark(log_path):
    """Where the sync log stood when an episode began: its size, its file identity and a digest of its
    first bytes. The log has no timestamps, so this is the only way to tell this episode's lines apart."""
    try:
        with Path(log_path).open("rb") as stream:
            stat = os.fstat(stream.fileno())
            head_len = min(stat.st_size, LOG_HEAD_BYTES)
            return {"offset": stat.st_size, "ino": stat.st_ino,
                    "head_len": head_len, "head": _head_digest(stream, head_len)}
    except OSError:
        return {"offset": 0}


def _same_log(stream, size, bookmark):
    """True while the file is the one the bookmark was taken on and has only grown since: same inode,
    not shorter, same first bytes. A rotated log (renamed away, or truncated and rewritten) fails one
    of these even after it regrows past the old size."""
    offset = bookmark.get("offset", 0)
    if not 0 <= offset <= size:
        return False
    if "ino" in bookmark and bookmark["ino"] != os.fstat(stream.fileno()).st_ino:
        return False
    if "head" in bookmark and _head_digest(stream, bookmark.get("head_len", 0)) != bookmark["head"]:
        return False
    return True


def last_sync_refusal(log_path, bookmark):
    """Last refusal line the sync service wrote after the episode's bookmark (see log_bookmark), or ''.
    The log carries no timestamps and gains lines on every run, so a file time proves nothing; only
    the bytes written after the bookmark belong to this episode. A rotated log is read from its start."""
    log_path = Path(log_path)
    try:
        with log_path.open("rb") as stream:
            size = os.fstat(stream.fileno()).st_size
            start = bookmark.get("offset", 0) if _same_log(stream, size, bookmark) else 0
            stream.seek(start)
            lines = stream.read().decode("utf-8", errors="replace").splitlines()[-READER_LOG_TAIL:]
    except OSError:
        return ""
    for line in reversed(lines):
        if any(marker in line for marker in SYNC_REFUSAL_MARKERS):
            return " ".join(line.split())[:SYNC_REASON_MAX]
    return ""


def sync_action(reason):
    """One deterministic line of what to do for a sync refusal, or ''."""
    for marker, action in SYNC_ACTIONS:
        if marker in reason:
            return action
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


def local_backup_path(repo, url):
    """Filesystem path of a local `origin` URL, or None for a network URL (scheme:// or host:path)."""
    if url.startswith("file://"):
        return Path(url[len("file://"):])
    if "://" in url:
        return None
    path = Path(url).expanduser()
    if path.is_absolute():
        return path
    if ":" in url.split("/", 1)[0]:
        return None  # scp-like host:path
    return Path(repo) / path  # git resolves a relative URL against the repository


def run_git(repo, what, *args):
    """(returncode, stdout) of `git -C repo *args`, or (None, reason) when git hung or could not start.
    `what` names the call in messages."""
    try:
        proc = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                              timeout=LOCAL_FETCH_TIMEOUT, check=False)
    except subprocess.TimeoutExpired:
        return None, f"git {what} дольше {LOCAL_FETCH_TIMEOUT} с"
    except OSError as exc:
        return None, f"git {what}: {exc.__class__.__name__}"
    if proc.returncode != 0 and proc.stderr.strip():
        print(f"convergence-alarm: {repo}: git {what}: {proc.stderr.strip()[-300:]}", file=sys.stderr)
    return proc.returncode, proc.stdout


def local_backup_label(repo):
    """Relation label of a copy to its bare backup on this disk, or None when the copy has no such backup.

    The backup is fetched here: it is a local path, nothing else updates the remote-tracking ref. The fetch
    touches only refs/remotes/origin/* and objects; it writes no FETCH_HEAD and runs no auto maintenance,
    because agents commit to this repository all day. `ahead` (commits not pushed yet) is the normal state
    and counts as `equal`; a copy that cannot push any more (behind or diverged) or a backup that cannot be
    read is an episode."""
    rc, out = run_git(repo, "remote", "remote", "get-url", "origin")
    if rc == 2:
        return None  # no remote "origin": no backup configured
    if rc != 0:
        return f"резервная копия не читается: git remote {out if rc is None else f'код {rc}'}"
    url = out.strip()
    if local_backup_path(repo, url) is None:
        print(f"convergence-alarm: {repo}: origin {url} is not a local path, backup check skipped", file=sys.stderr)
        return None
    rc, out = run_git(repo, "fetch", "-c", "maintenance.auto=false", "-c", "gc.auto=0",
                      "fetch", "-q", "--no-write-fetch-head", "origin")
    if rc != 0:
        return f"резервная копия не читается: git fetch {out if rc is None else f'код {rc}'}"
    try:
        relation, _, _ = report.relation(repo)
    except (subprocess.SubprocessError, OSError) as exc:
        return f"резервная копия не читается: {exc.__class__.__name__}"
    return "equal" if relation.startswith("ahead") else relation


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


RECOVERED_GITHUB = "снова совпадает с GitHub"
RECOVERED_BACKUP = "резервная копия снова принимает отправку"


def step(state, path, label, threshold, now, recovered=RECOVERED_GITHUB):
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
        return f"✅ {path}: {recovered}"
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
OUTCOME_PREFIX = "iwe-notify: outcome="
DELIVERED_OUTCOME = "direct-sent"


def send_telegram(notify, secrets, text):
    """Send `text` with `iwe-notify --direct`, the bot keys sourced from `secrets`; True when delivered.

    Only `direct-sent` (Telegram answered ok:true) counts: not-sent (no keys), direct-failed or no
    outcome line at all keep the episode unsent, retried on the next run. The secrets file is sourced
    with its stdout sent to stderr, so nothing but iwe-notify can print an outcome line; the last such
    line wins. A send that went out and then failed late (outcome direct-sent, non-zero exit) is
    delivered and must not be repeated every 15 minutes."""
    # set -a: a secrets file that assigns without `export` still hands the keys to iwe-notify (a new
    # process); the arguments are copied first, so `set --` or `shift` in that file cannot change them.
    script = ('secrets=$1 notify=$2 source_id=$3 text=$4; '
              'if [ -f "$secrets" ]; then set -a; . "$secrets" >&2 || exit 1; set +a; fi; '
              'exec "$notify" --direct --source "$source_id" -- "$text"')
    try:
        proc = subprocess.run(["bash", "-c", script, Path(__file__).name, str(secrets), str(notify),
                               TELEGRAM_SOURCE_ID, text],
                              capture_output=True, text=True, timeout=60, check=False)
    except subprocess.TimeoutExpired:
        print("convergence-alarm: iwe-notify did not finish in 60 s - episode stays unsent", file=sys.stderr)
        return False
    outcome = next((line[len(OUTCOME_PREFIX):] for line in reversed(proc.stdout.splitlines())
                    if line.startswith(OUTCOME_PREFIX)), "")
    if outcome == DELIVERED_OUTCOME:
        if proc.returncode != 0:
            print(f"convergence-alarm: iwe-notify exited {proc.returncode} after outcome {outcome}; counted as delivered",
                  file=sys.stderr)
        return True
    print(f"convergence-alarm: message not delivered (outcome: {outcome or 'none'}, exit {proc.returncode}): "
          f"{proc.stderr.strip()[-300:]} - episode stays unsent", file=sys.stderr)
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
    parser.add_argument("--notify", default=str(SCRIPTS / "iwe-notify"))
    parser.add_argument("--secrets", default=os.environ.get("TG_SECRETS_FILE") or str(Path.home() / ".secrets" / "tg-bots"),
                        help="sourceable file exporting TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID")
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
        if path in SYNC_LOGS and path in state and "sync_log_bookmark" not in state[path]:
            state[path]["sync_log_bookmark"] = log_bookmark(root / SYNC_LOGS[path])
        if text:
            reason = reader_reason(last_reader_line(reader_log, path)) if label != "equal" else ""
            if not reason and label != "equal" and path in SYNC_LOGS:
                refusal = last_sync_refusal(root / SYNC_LOGS[path], state[path].get("sync_log_bookmark", {"offset": 0}))
                if refusal:
                    reason = f"перемотка: {refusal}" + (f"\n{sync_action(refusal)}" if sync_action(refusal) else "")
            pending.append((path, text + (f"\n{reason}" if reason else "")))
    for path, threshold in LOCAL_BACKUPS:
        repo = root / path
        if not (repo / ".git").exists():
            continue
        label = local_backup_label(repo)
        if label is None:
            continue
        text = step(state, path, label, threshold, now, recovered=RECOVERED_BACKUP)
        if text:
            pending.append((path, text))

    if not pending:
        status = 0
    elif args.dry_run:
        print("\n\n".join(t for _, t in pending))
        status = 0
    elif in_quiet_hours(now, args.quiet_from, args.quiet_to):
        log_messages(now, "deferred (quiet hours)", pending)
        status = 0
    elif send_telegram(args.notify, args.secrets, "🔄 Сходимость git, Мак\n\n" + "\n\n".join(t for _, t in pending)):
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
