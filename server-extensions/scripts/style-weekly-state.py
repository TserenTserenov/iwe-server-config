#!/usr/bin/env python3
"""Weekly state check of the style guards (WP-388 F26, F31, F36, F39).

Answers four questions on the computer where it runs, in Russian, for the Week Close report:
  1. Is the end-of-reply style check wired for Claude, Codex and Kimi (config says so)?
  2. Did it actually run: agents with live sessions this week but no check runs = alarm.
  3. Weekly numbers against the previous week (names from code, links, hints, repeats).
  4. Event trigger: enough new A14 hits to repeat the precision measure.

Read-only: never edits hooks, settings or logs. Exit 1 when there is an alarm, else 0.
Env/args: --root (IWE root), --home (home with .claude/logs), --today (YYYY-MM-DD).
"""

import argparse
import datetime as dt
import json
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

AGENTS = ("claude-code", "codex", "kimi")
TRACKED_RULES = ("A14", "A13.1", "A10", "A12_CROSS_TURN_REPEAT")
METRIC_SCRIPT = Path(__file__).with_name("style-symbol-metric.py")


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


def wiring_kimi(home):
    configs = [home / ".kimi" / "config.toml", home / ".kimi-code" / "config.toml"]
    seen, found = [], False
    for cfg in configs:
        try:
            ok = _toml_has_stop_hook(cfg.read_text(encoding="utf-8"))
        except OSError:
            seen.append(f"{cfg.name}: нет файла")
            continue
        found = found or ok
        seen.append(f"{cfg.parent.name}/{cfg.name}: {'есть' if ok else 'нет'} проверки после ответа")
    return found, "; ".join(seen)


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
    """Number of session files touched since cutoff, per agent (direct chats only)."""
    claude = _recent((home / ".claude" / "projects").glob("*/*.jsonl"), cutoff_ts)
    codex_files = (p for p in (home / ".codex" / "sessions").rglob("*.jsonl") if not _codex_is_peer_run(p))
    codex = _recent(codex_files, cutoff_ts)
    kimi_dirs = [d for d in (home / ".kimi-code" / "sessions").glob("wd_*") if "text-only" not in d.name]
    kimi = _recent((p for d in kimi_dirs for p in d.rglob("wire.jsonl")), cutoff_ts)
    return {"claude-code": claude, "codex": codex, "kimi": kimi}


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


def symbol_metric(since, until):
    """All-blocks totals from style-symbol-metric.py, or (None, reason)."""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "m.json"
        cmd = [sys.executable, str(METRIC_SCRIPT), "--since", since, "--until", until, "--json", str(out)]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            if res.returncode != 0:
                return None, f"скрипт замера вернул ошибку: {res.stderr.strip()[:120]}"
            return json.loads(out.read_text(encoding="utf-8"))["totals"]["all_blocks"], ""
        except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
            return None, f"замер недоступен ({exc.__class__.__name__})"


def verdict(wired, sessions, runs):
    """(text, alarm) for one agent."""
    if sessions == 0:
        return ("сессий на этом компьютере за неделю нет" + ("" if wired else ", проверка не подключена")), False
    if not wired:
        return f"ТРЕВОГА: сессий {sessions}, а проверка после ответа не подключена", True
    if runs == 0:
        return f"ТРЕВОГА: сессий {sessions}, проверка подключена, но за неделю не запускалась", True
    return f"в порядке: сессий {sessions}, запусков проверки {runs}", False


def fmt_pair(now, before, unit=""):
    return f"{now}{unit} (неделей раньше {before}{unit})"


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
    wiring = {"claude-code": wiring_claude(root), "codex": wiring_codex(root), "kimi": wiring_kimi(home)}
    sessions = activity(home, cutoff_ts)
    runs = check_runs(logs, since, until)
    alarms = 0
    for agent in AGENTS:
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
        now_m, why = symbol_metric(since, until)
        before_m, _ = symbol_metric(prev_since, prev_until)
        if now_m and before_m:
            for key, title, unit in (
                ("symbol_item_share", "доля пунктов с непояснённым именем из кода", ""),
                ("links_per_reply", "ссылок на документы на ответ", ""),
                ("backticks_per_reply", "имён в обратных кавычках на ответ", ""),
            ):
                print(f"  {title}: {fmt_pair(now_m[key], before_m[key], unit)}")
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
