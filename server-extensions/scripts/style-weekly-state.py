#!/usr/bin/env python3
"""Weekly state check of the style guards (WP-388 F26, F31, F36, F39).

Answers four questions on the computer where it runs, in Russian, for the Week Close report:
  1. Is the end-of-reply style check wired for Claude, Codex and Kimi (config says so)?
  2. Did it actually run: agents with live sessions this week but no check runs = alarm.
  3. Weekly numbers against the previous week (names from code, links, hints, repeats).
  4. Event trigger: enough new A14 hits to repeat the precision measure.

Read-only: never edits hooks, settings or logs. Exit 1 when there is an alarm, else 0.
Env/args: --root (IWE root), --home (home with .claude/logs), --today (YYYY-MM-DD).

Kimi keeps two homes on one computer, each with its own config (WP-388 F41, Mac run 25.11):
~/.kimi (CLI started from a terminal) and ~/.kimi-code (the VS Code extension). The wiring
is judged per home against that home's own direct sessions, never "wired in any of them".
"""

import argparse
import datetime as dt
import hashlib
import json
import re
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

AGENTS = ("claude-code", "codex", "kimi")
TRACKED_RULES = ("A14", "A13.1", "A10", "A12_CROSS_TURN_REPEAT")
METRIC_SCRIPT = Path(__file__).with_name("style-symbol-metric.py")
KIMI_HOMES = (".kimi", ".kimi-code")
# The peer adapter runs Kimi in "$TMP_ROOT/kimi-text-only-workdir" (kimi-peer-adapter.sh).
KIMI_PEER_WORKDIR = "kimi-text-only-workdir"


def _commands(hook_groups):
    """Flat list of command strings from a Claude/Codex hooks list."""
    return [
        str(h.get("command", ""))
        for group in hook_groups or []
        for h in (group.get("hooks") or [])
    ]


def wiring_claude(root):
    path = root / ".claude" / "settings.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return False, f"нет читаемого {path} ({exc.__class__.__name__})"
    found = any("response-clarity-hook" in c for c in _commands(data.get("hooks", {}).get("Stop")))
    return found, "в настройках Claude есть проверка после ответа" if found else "в настройках Claude нет проверки после ответа"


def wiring_codex(root):
    path = root / ".codex" / "hooks.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return False, f"нет читаемого {path} ({exc.__class__.__name__})"
    found = any("style_check_stop" in c for c in _commands(data.get("hooks", {}).get("Stop")))
    return found, "в настройках Codex есть проверка после ответа" if found else "в настройках Codex нет проверки после ответа"


def _toml_has_stop_hook(text):
    """True if some [[hooks]] block has event = "Stop" and a command with kimi-style-stop."""
    for block in text.split("[[hooks]]")[1:]:
        block = block.split("\n[", 1)[0]
        if 'event = "Stop"' in block and "kimi-style-stop" in block:
            return True
    return False


def _kimi_workdirs(kimi_home):
    """md5(work dir path) -> path, from <home>/kimi.json; the CLI names session folders so."""
    try:
        entries = json.loads((kimi_home / "kimi.json").read_text(encoding="utf-8")).get("work_dirs") or []
    except (OSError, ValueError, AttributeError):
        return {}
    paths = [str(e["path"]) for e in entries if isinstance(e, dict) and e.get("path")]
    return {hashlib.md5(path.encode()).hexdigest(): path for path in paths}


def _is_peer_origin(origin):
    """wd_<name>_<hash> folder (~/.kimi-code) or work dir path (~/.kimi) of a peer-adapter run."""
    if origin.startswith("wd_"):
        return origin[3:].rsplit("_", 1)[0] == KIMI_PEER_WORKDIR
    return Path(origin).name == KIMI_PEER_WORKDIR


def _subdirs(path):
    """Child folders; an unreadable or vanished folder yields none (the count stays conservative)."""
    try:
        return [p for p in path.iterdir() if p.is_dir()]
    except OSError as exc:
        print(f"  (папка {path} не прочитана: {exc.__class__.__name__})", file=sys.stderr)
        return []


def _is_fresh_session(session_dir, cutoff_ts):
    """A session counts once if any journal under it (main agent or helpers) is fresh."""
    for p in session_dir.rglob("wire.jsonl"):
        try:
            if p.stat().st_mtime >= cutoff_ts:
                return True
        except OSError:
            continue
    return False


def kimi_direct_sessions(kimi_home, cutoff_ts):
    """Fresh direct sessions in one Kimi home; peer-adapter work dirs are skipped.

    Layouts: ~/.kimi-code/sessions/wd_<name>_<hash>/session_*/agents/*/wire.jsonl and
    ~/.kimi/sessions/<md5(work dir)>/<session>/wire.jsonl. An unknown work dir counts as
    direct: an alarm is better than a hidden session.
    """
    base = kimi_home / "sessions"
    if not base.is_dir():
        return 0
    workdirs = _kimi_workdirs(kimi_home)
    count = 0
    for group in _subdirs(base):
        origin = group.name if group.name.startswith("wd_") else workdirs.get(group.name, "")
        if _is_peer_origin(origin):
            continue
        count += sum(1 for s in _subdirs(group) if _is_fresh_session(s, cutoff_ts))
    return count


def kimi_homes(home, cutoff_ts):
    """Per Kimi home: config wiring (None = no config file) and fresh direct sessions."""
    result = []
    for name in KIMI_HOMES:
        try:
            wired = _toml_has_stop_hook((home / name / "config.toml").read_text(encoding="utf-8"))
        except OSError:
            wired = None
        result.append({"name": name, "wired": wired, "sessions": kimi_direct_sessions(home / name, cutoff_ts)})
    return result


def kimi_verdict(homes, runs):
    """(text, alarm, detail) for Kimi: every home with direct sessions needs its own hook."""
    detail = "; ".join(
        f"~/{h['name']}: прямых сессий {h['sessions']}, "
        + ("нет файла настроек" if h["wired"] is None else ("проверка после ответа есть" if h["wired"] else "проверки после ответа нет"))
        for h in homes
    )
    bare = [h for h in homes if h["sessions"] and not h["wired"]]
    if bare:
        where = ", ".join(f"~/{h['name']} ({h['sessions']})" for h in bare)
        return f"ТРЕВОГА: прямые сессии без проверки после ответа в {where}", True, detail
    total = sum(h["sessions"] for h in homes)
    text, alarm = verdict(True, total, runs)
    return text, alarm, detail


def _recent(paths, cutoff_ts):
    count = 0
    for p in paths:
        try:
            if p.stat().st_mtime >= cutoff_ts:
                count += 1
        except OSError:
            continue
    return count


def _codex_is_peer_run(path):
    """Peer-adapter runs start in /tmp/codex-peer-*; their checks are logged as codex-peer."""
    try:
        with path.open(encoding="utf-8", errors="replace") as fh:
            first = json.loads(fh.readline())
    except (OSError, ValueError):
        return False  # unknown start: count it as a direct session (alarm rather than hide)
    cwd = str((first.get("payload") or first).get("cwd", "")) if isinstance(first, dict) else ""
    return "codex-peer" in cwd


def activity(home, cutoff_ts):
    """Session files touched since cutoff for Claude and Codex (direct chats only); Kimi: kimi_homes."""
    claude = _recent((home / ".claude" / "projects").glob("*/*.jsonl"), cutoff_ts)
    codex_files = (p for p in (home / ".codex" / "sessions").rglob("*.jsonl") if not _codex_is_peer_run(p))
    codex = _recent(codex_files, cutoff_ts)
    return {"claude-code": claude, "codex": codex}


def _read_lines(path):
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []


def check_runs(logs, since, until):
    """Check runs per agent from style-checks-total.log ('YYYY-MM-DD HH:MM:SS | agent')."""
    runs = {a: 0 for a in AGENTS}
    for line in _read_lines(logs / "style-checks-total.log"):
        parts = line.split(" | ")
        if len(parts) >= 2 and since <= parts[0][:10] <= until and parts[1].strip() in runs:
            runs[parts[1].strip()] += 1
    return runs


def rule_counts(logs, since, until):
    counts = {r: 0 for r in TRACKED_RULES}
    for line in _read_lines(logs / "style-violations.log"):
        parts = line.split(" | ")
        if len(parts) >= 3 and since <= parts[0][:10] <= until and parts[2] in counts:
            counts[parts[2]] += 1
    return counts


def lines_in_window(path, since, until, sep=None):
    n = 0
    for line in _read_lines(path):
        day = line.split(sep)[0][:10] if sep else line[:10]
        if since <= day <= until:
            n += 1
    return n


def concept_kind_calls(logs, since, until):
    per_agent = {}
    for line in _read_lines(logs / "concept-kind.log"):
        cols = line.split("\t")
        if len(cols) >= 2 and since <= cols[0][:10] <= until:
            per_agent[cols[1]] = per_agent.get(cols[1], 0) + 1
    return per_agent


def a14_new_hits(logs, after_day):
    return sum(
        1
        for line in _read_lines(logs / "style-violations.log")
        for parts in [line.split(" | ")]
        if len(parts) >= 3 and parts[0][:10] > after_day and parts[2] == "A14"
    )


def claude_projects_glob(home, root):
    """Claude names a project folder after its path, every non-alphanumeric char -> '-'."""
    return str(home / ".claude" / "projects" / (re.sub(r"[^A-Za-z0-9]", "-", str(root)) + "*"))


def symbol_metric(projects_glob, since, until):
    """All-blocks totals from style-symbol-metric.py, or (None, reason)."""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "m.json"
        cmd = [sys.executable, str(METRIC_SCRIPT), "--since", since, "--until", until,
               "--root", projects_glob, "--json", str(out)]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            if res.returncode != 0:
                return None, f"скрипт замера вернул ошибку: {res.stderr.strip()[:120]}"
            return json.loads(out.read_text(encoding="utf-8"))["totals"]["all_blocks"], ""
        except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
            return None, f"замер недоступен ({exc.__class__.__name__})"


NO_REPLIES = "нет данных (0 ответов в беседах этого компьютера)"


def metric_line(title, key, now_m, before_m):
    """A share per reply is undefined with zero replies: say so instead of printing 0.0."""
    if not now_m.get("replies"):
        return f"  {title}: {NO_REPLIES}"
    before = before_m[key] if before_m.get("replies") else "нет данных"
    return f"  {title}: {fmt_pair(now_m[key], before)}"


def verdict(wired, sessions, runs):
    """(text, alarm) for one agent."""
    if sessions == 0:
        return ("сессий на этом компьютере за неделю нет" + ("" if wired else ", проверка не подключена")), False
    if not wired:
        return f"ТРЕВОГА: сессий {sessions}, а проверка после ответа не подключена", True
    if runs == 0:
        return f"ТРЕВОГА: сессий {sessions}, проверка подключена, но за неделю не запускалась", True
    return f"в порядке: сессий {sessions}, запусков проверки {runs}", False


def fmt_pair(now, before):
    return f"{now} (неделей раньше {before})"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(Path.home() / "IWE"))
    ap.add_argument("--home", default=str(Path.home()))
    ap.add_argument("--today", default=dt.date.today().isoformat())
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--a14-after", default="2026-11-24", help="count A14 hits after this day (narrowing, PR 306)")
    ap.add_argument("--a14-need", type=int, default=20, help="hits needed to repeat the precision measure (writer proposal)")
    ap.add_argument("--skip-metric", action="store_true")
    args = ap.parse_args(argv)

    root, home = Path(args.root), Path(args.home)
    logs = home / ".claude" / "logs"
    today = dt.date.fromisoformat(args.today)
    since = (today - dt.timedelta(days=args.days - 1)).isoformat()
    prev_until = (today - dt.timedelta(days=args.days)).isoformat()
    prev_since = (today - dt.timedelta(days=2 * args.days - 1)).isoformat()
    cutoff_ts = dt.datetime.combine(today - dt.timedelta(days=args.days), dt.time()).timestamp()
    until = today.isoformat()

    print(f"## Проверка стражей стиля ({until}, компьютер {socket.gethostname()})")
    wiring = {"claude-code": wiring_claude(root), "codex": wiring_codex(root)}
    sessions = activity(home, cutoff_ts)
    runs = check_runs(logs, since, until)
    alarms = 0
    for agent in AGENTS:
        if agent == "kimi":
            text, alarm, detail = kimi_verdict(kimi_homes(home, cutoff_ts), runs[agent])
        else:
            wired, detail = wiring[agent]
            text, alarm = verdict(wired, sessions[agent], runs[agent])
        alarms += alarm
        print(f"  {agent}: {text}")
        print(f"      настройки: {detail}")

    print()
    print(f"## Числа недели {since}..{until} против {prev_since}..{prev_until}")
    now_c, before_c = rule_counts(logs, since, until), rule_counts(logs, prev_since, prev_until)
    for rule in TRACKED_RULES:
        print(f"  срабатываний {rule}: {fmt_pair(now_c[rule], before_c[rule])}")
    hints = {
        "подсказок следующего хода": "style-next-turn-hints.log",
        "подсказок о словах IWE": "style-jargon-hints.log",
    }
    for title, name in hints.items():
        print(f"  {title}: {fmt_pair(lines_in_window(logs / name, since, until), lines_in_window(logs / name, prev_since, prev_until))}")
    calls = concept_kind_calls(logs, since, until)
    print("  обращений к реестру родов по агентам: " + (", ".join(f"{a} {n}" for a, n in sorted(calls.items())) or "нет"))
    if not args.skip_metric:
        projects = claude_projects_glob(home, root)
        now_m, why = symbol_metric(projects, since, until)
        before_m, _ = symbol_metric(projects, prev_since, prev_until)
        if now_m and before_m:
            for key, title in (
                ("symbol_item_share", "доля пунктов с непояснённым именем из кода"),
                ("links_per_reply", "ссылок на документы на ответ"),
                ("backticks_per_reply", "имён в обратных кавычках на ответ"),
            ):
                print(metric_line(title, key, now_m, before_m))
        else:
            print(f"  замер имён из кода пропущен: {why or 'нет данных за прошлую неделю'}")

    print()
    hits = a14_new_hits(logs, args.a14_after)
    print(f"## Повторный замер A14 (по событию, порог {args.a14_need} срабатываний после {args.a14_after})")
    if hits >= args.a14_need:
        print(f"  ПОРА: набралось {hits}. Разметить срабатывания слепо двумя оценщиками и решить про блокировку для Kimi и Codex (нужна точность не ниже 0,7).")
    else:
        print(f"  набрано {hits} из {args.a14_need}, замер рано")

    print()
    print("Итог: " + (f"тревог {alarms}, разобрать до закрытия недели." if alarms else "тревог нет."))
    return 1 if alarms else 0


if __name__ == "__main__":
    sys.exit(main())
