#!/usr/bin/env python3
"""PreToolUse gate: agent-made reminders and calendar events before 09:00 MSK.

Rule (CLAUDE.md "Calendar Events — CRITICAL", WP-538/WP-568, 16.11.2026):
reminders and events the agent creates are scheduled before 09:00 Moscow time;
later only with the pilot's explicit approval. Telegram times are UTC with "Z":
the bot drops any offset without converting it (incident 05.11), so a time
without "Z" fires at a different hour than intended.

Decisions:
  deny — Telegram time without "Z" (the agent rewrites it; no pilot needed);
  ask  — 09:00 MSK or later, an event without a known time zone, an
         unparseable time, or an error of this hook: the pilot confirms in
         the interface, the agent cannot answer for them;
  no output — everything else passes.
"""
import json
import sys
from datetime import datetime, time
from zoneinfo import ZoneInfo

MOSCOW = "Europe/Moscow"  # resolved inside the guarded call: no tz database -> ask
DEADLINE = time(9, 0)
TELEGRAM = "mcp__iwe-knowledge__send_telegram_message"
CALENDAR = (
    "mcp__claude_ai_Google_Calendar__create_event",
    "mcp__claude_ai_Google_Calendar__update_event",
)


def decide(decision: str, reason: str) -> None:
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": decision,
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
        ensure_ascii=False,
    )


def late_reason(moscow: datetime) -> str:
    return (
        f"Напоминание на {moscow:%d.%m %H:%M} по Москве, это не раньше 09:00. "
        "Правило: напоминания и события агента ставятся до 09:00 МСК, позже "
        "только с явного согласия пилота. Подтвердите или перенесите раньше."
    )


def check_telegram(args: dict) -> None:
    raw = str(args.get("schedule_at") or "").strip()
    if not raw:
        return  # immediate message, no schedule
    if not raw.upper().endswith("Z"):
        decide(
            "deny",
            f"Время напоминания «{raw}» не в UTC с «Z». Бот отбрасывает пояс без "
            "пересчёта и пришлёт в другой час. Перепишите в UTC с «Z»: например, "
            "08:30 по Москве = «…T05:30:00Z».",
        )
        return
    when = datetime.fromisoformat(raw[:-1] + "+00:00").astimezone(ZoneInfo(MOSCOW))
    if when.time() >= DEADLINE:
        decide("ask", late_reason(when))


def check_calendar(args: dict) -> None:
    raw = str(args.get("startTime") or "").strip()
    if args.get("allDay") is True:
        return  # a whole-day event
    if not raw:
        if args.get("timeZone"):
            decide(
                "ask",
                "Событие переносится в другой часовой пояс без нового времени: "
                "проверка не видит, останется ли оно раньше 09:00 по Москве.",
            )
        return  # time unchanged
    if raw.upper().endswith("Z"):
        raw = raw[:-1] + "+00:00"
    when = datetime.fromisoformat(raw)
    if when.tzinfo is None and args.get("timeZone"):
        when = when.replace(tzinfo=ZoneInfo(str(args["timeZone"])))
    if when.tzinfo is None:
        # The calendar's own zone is unknown here (it may even read it as UTC).
        decide(
            "ask",
            f"Событие на {when:%d.%m %H:%M} без часового пояса: проверка не "
            "может подтвердить, что это раньше 09:00 по Москве. Правило: "
            "события агента до 09:00 МСК, позже только с согласия пилота.",
        )
        return
    moscow = when.astimezone(ZoneInfo(MOSCOW))
    if moscow.time() >= DEADLINE:
        decide("ask", late_reason(moscow))


def main() -> None:
    event = json.load(sys.stdin)
    tool = event.get("tool_name", "")
    args = event.get("tool_input") or {}
    if tool == TELEGRAM:
        check_telegram(args)
    elif tool in CALENDAR:
        check_calendar(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # a broken gate asks the pilot, never waves through
        print(f"[reminder-time-gate ERROR] {exc!r}", file=sys.stderr)
        decide(
            "ask",
            "Проверка времени напоминания не смогла разобрать вызов "
            f"({type(exc).__name__}). Проверьте время вручную: до 09:00 по Москве.",
        )
