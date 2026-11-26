#!/usr/bin/env python3
"""A12-next-block detector (РП-605 Ф1, 22.10.2026).

Five independent warn-only signals about the mandatory "Дальше:" line (A12,
pack `communication-style-base.md` rule 6), one per output line so a caller
can tell "no signal" from "detector found nothing to say" by line count:

  A12_NEXT_MISSING             none of the assistant's last 3 non-empty lines
                               starts with "Дальше:".
  A12_NEXT_EMPTY_CONTENT       a "Дальше:" line exists but carries no letters.
  A12_NEXT_UNNAMED_LAUNCHER    the line promises a "следующая сессия" and names
                               nobody who starts it (added 30.10.2026).
  A12_NEXT_PLACE_THIS_CHAT     the line names this very chat as the place
                               ("вы, в этом чате: ...") and no other place
                               (added 01.11.2026, pilot permission).
  A12_NEXT_I_NO_WAKE           the line starts with "я" but the transcript holds no
                               unfinished background task and no wake-up alarm
                               (added 24.11.2026, pilot permission, journal mode).

The former A12_NEXT_NO_PILOT_ADDRESSEE signal was removed in РП-605 Ф6
(23.10.2026): rule 6 now asks "who and when takes the next step", and a line
like "следующая сессия по РП-511 начнётся с ..." legitimately has no
addressee wording. Ambiguity is checked by sampling, not by a lexicon.

Reuses the transcript-walk helpers from a12-unsolicited-close.py (_rows,
role/content extraction) instead of a third copy of the same JSONL parsing --
that file's own module name has a hyphen, so it is loaded via importlib
rather than a plain `import` statement.

Usage: a12-next-block.py <transcript.jsonl>
"""
import importlib.util
import json
import os
import re
import sys
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "a12_unsolicited_close", Path(__file__).parent / "a12-unsolicited-close.py"
)
_a12 = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_a12)

NEXT_LINE_RE = re.compile(r"^Дальше:\s*(.*)$")

# A12_NEXT_EMPTY_CONTENT (РП-605, 22.10.2026, пир-сессия Claude+Kimi+Codex
# 2026-10-22-23-codex-hook-gap-next): live case "Дальше: 👉" / "Дальше: 🏃" --
# a line that technically starts with "Дальше:" but carries zero letters, only
# emoji/punctuation/whitespace. Warn-only; see CONSENSUS in that session's
# report.md for the revisit criterion.
LETTER_RE = re.compile(r"[A-Za-zА-Яа-яЁё]")


def final_assistant_lines(rows, limit=3):
    """Last `limit` non-empty lines of the assistant's final-turn text."""
    last_user = max((i for i, r in enumerate(rows) if _a12._role(r) == "user"), default=-1)
    texts = []
    for row in rows[last_user + 1:]:
        if _a12._role(row) == "assistant":
            texts.extend(_a12._text_blocks(row))
    lines = [ln.strip() for ln in "\n".join(texts).splitlines() if ln.strip()]
    return lines[-limit:]


# A12_NEXT_UNNAMED_LAUNCHER (РП-605 Ф6, 30.10.2026, разрешение пилота на правку
# хуков): rule 6 says a "next session" step must name who or what starts it.
# Live case: "следующая сессия на Маке выполнит замер ...". The earlier decision
# (25.10) not to ship a lexical detector stands for MEANING; this one is narrow
# and warn-only: it fires only when the line has a "следующая сессия/беседа"
# phrase and no word that can name the launcher. The list is explicit (P13),
# extend it from real misses, no stemming.
NEXT_SESSION_RE = re.compile(r"следующ\w+\s+(?:сесси\w+|бесед\w+)", re.IGNORECASE)
LAUNCHER_NAMED_RE = re.compile(
    r"\bвы\b|\bвас\b|\bвам\b|\bвами\b|\bваш\w*|пилот\w*"
    r"|\bя\s+(?:запущу|открою|начну)"
    r"|планировщик\w*|расписани\w+|назначен\w*|по\s+таймеру|\bcron\b|launchd"
    r"|по\s+(?:слову|поручению|запросу)",
    re.IGNORECASE,
)


CLAUSE_SPLIT_RE = re.compile(r"[;.]")


def unnamed_launcher_line(next_line):
    """The "Дальше:" text if a clause promises a next session without naming its launcher.

    Checked per clause: "вы" in another clause ("вы: сказать «закрывай»; следующая
    сессия выполнит замер") does not name who starts that session.
    """
    for clause in CLAUSE_SPLIT_RE.split(next_line):
        if NEXT_SESSION_RE.search(clause) and not LAUNCHER_NAMED_RE.search(clause):
            return next_line
    return None


# A12_NEXT_PLACE_THIS_CHAT (РП-605 Ф6, 01.11.2026, разрешение пилота): rule 6 says
# the place ("где") is named only when it is NOT this chat. Measured on 193 lines of
# 12 conversations that read the new rule at start: 74 lines ("вы, в этом чате: ...")
# broke it, so the habit survives a one-sentence text rule. Warn-only (a blocking
# Stop hook already produced duplicate "Дальше:" lines, РП-605 30.10). The line may
# legitimately contrast places ("вы, в новой беседе ...; потом в этом чате ..."), so
# the signal fires only when no other place is named. Lists are explicit (P13).
THIS_CHAT_RE = re.compile(
    r"в\s+этом\s+(?:чате|диалоге|окне)|в\s+этой\s+(?:беседе|сессии)",
    re.IGNORECASE,
)
OTHER_PLACE_RE = re.compile(
    r"в\s+нов\w+\s+(?:бесед\w+|чат\w*|сесси\w+)|вне\s+чата|в\s+чате\s+\w+"
    r"|на\s+(?:Маке|Mac|Цехе)|в\s+(?:терминале|zulip|telegram|slack|браузере|панели|файле|репозитори\w+)|на\s+сервере",
    re.IGNORECASE,
)


# The opening "<actor>, в этом чате:" formula places the first step in this chat even
# when a later step names another place ("вы, в этом чате: 1) ...; 2) вы, в Zulip: ...").
# Bare "здесь" counts only in this opening position ("вы, здесь:"): elsewhere it often
# means "in the document" ("проверить, что здесь изменилось"), which is not a place of the step.
LEADING_THIS_CHAT_RE = re.compile(
    # A step number ("1) вы, здесь: ...") or a later step after ";" opens the formula too
    # (live case 26.11: the numbered line "1) вы, здесь: сказать «заливай ветку хуков»"
    # was written after the session was closed, and the old anchor missed it).
    r"(?:^|[;.]\s+)(?:\d+[.)]\s*)?(?:вы|я)\s*[,\-—]?\s*(?:в\s+этом\s+(?:чате|диалоге|окне)|в\s+этой\s+(?:беседе|сессии)|здесь)\s*[:,]",
    re.IGNORECASE,
)


def this_chat_place_line(next_line):
    """The "Дальше:" text if it names this chat as the place of a step."""
    if LEADING_THIS_CHAT_RE.search(next_line):
        return next_line
    if THIS_CHAT_RE.search(next_line) and not OTHER_PLACE_RE.search(next_line):
        return next_line
    return None


# РП-605 Ф6 (05.11.2026, пир-сессия 2026-11-05-04-wp605-next-dup): the style guard's
# block comes back as an isMeta user record "Stop hook feedback:". It resets
# `last_user`, so the rewrite is analysed alone and, with the new block text that
# says "do not repeat the line", it would be flagged MISSING although the line was
# already shown. A line shown in the reply just before the feedback counts.
FEEDBACK_PREFIX = "stop hook feedback:"


def shown_before_guard_feedback(rows):
    """True if the last user record is guard feedback and the reply shown right
    before it ended with a "Дальше:" line (no other record in between)."""
    last_user = max((i for i, r in enumerate(rows) if _a12._role(r) == "user"), default=-1)
    if last_user < 1:
        return False
    texts = _a12._text_blocks(rows[last_user])
    if not texts or not texts[0].lstrip().lower().startswith(FEEDBACK_PREFIX):
        return False
    shown = []
    for row in reversed(rows[:last_user]):
        if _a12._role(row) == "user":
            break
        if _a12._role(row) == "assistant":
            shown = _a12._text_blocks(row) + shown
    lines = [ln.strip() for ln in "\n".join(shown).splitlines() if ln.strip()]
    return any(NEXT_LINE_RE.match(ln) for ln in lines[-3:])


# A12_NEXT_I_NO_WAKE (РП-605 Ф7, 24.11.2026, решение пилота, journal mode first):
# "Дальше: я ..." promises the agent's own step, but nothing in the transcript will
# wake the agent: no background task started and not yet finished, no alarm. Measured
# 21-24.11 on 161 "я" lines: 150 honest ones all had a pending task or alarm, 7 of 7
# empty promises had none (a lexical check caught only 2 of the 7). A promise resting
# on a task from an EARLIER turn is honest (30 of 150), so the whole transcript is
# scanned, not only the current turn. Warn-only until the journal shows no false hits.
I_LINE_RE = re.compile(
    r"^(?:\d+[.)]\s*)?\**я\**(?=[\s,:\-—])|;\s*\d+[.)]\s*\**я\**(?=[\s,:\-—])", re.IGNORECASE
)
# Start markers are trusted only in the result of the tool that really starts a task:
# the same text inside a Read/grep result (a test file, a transcript) is not a task.
AGENT_START_RE = re.compile(r"agentId:\s*(\w+)|resumedAgentId\W+(\w+)|Resuming agent\s+(\w+)")
BASH_START_RE = re.compile(r"running in background with ID:\s*(\w+)|moved to the background \(ID:\s*(\w+)\)")
MONITOR_START_RE = re.compile(r"Monitor started \(task\s+(\w+)")
START_BY_TOOL = (
    (("Agent", "Task", "SendMessage"), AGENT_START_RE),
    (("Bash",), BASH_START_RE),
    (("Monitor",), MONITOR_START_RE),
)
# A task ends with a notification that carries a final status (a Monitor sends one
# notification per event, without a status, while it keeps running), with the
# "Monitor expired" event, or with the result of TaskStop. One notification may list
# several task ids (summary of abandoned tasks after a session resume).
NOTIFICATION_RE = re.compile(r"<task-notification>(.*?)</task-notification>", re.DOTALL)
TASK_ID_RE = re.compile(r"<task-id>([^<\s]+)</task-id>")
FINAL_STATUS_RE = re.compile(r"<status>(?:completed|failed|killed|stopped|cancelled)</status>")
MONITOR_EXPIRED_RE = re.compile(r"Monitor expired")
# A helper that stopped with background work of its own still running sends a "completed"
# notification marked as interim; the same id notifies again later (live case 25.11 22:04,
# the first false hit of A12_NEXT_I_NO_WAKE). Such a notification is not an end.
INTERIM_RE = re.compile(
    r"background work of its own still running|result below may be interim", re.IGNORECASE
)
STOPPED_RE = re.compile(r"Successfully stopped task:\s*(\w+)")
WAKEUP_TOOL = "ScheduleWakeup"
CRON_TOOL = "CronCreate"
CRON_DELETE_TOOL = "CronDelete"


def _ids(regex, text):
    # First 7 characters only: a resumed agent is announced with a short id
    # ("Resuming agent a0f5052") and finishes under the full one.
    return {g[:7] for m in regex.finditer(text) for g in m.groups() if g}


def _done_ids(text):
    done = _ids(STOPPED_RE, text)
    for m in NOTIFICATION_RE.finditer(text):
        body = m.group(1)
        if INTERIM_RE.search(body):
            continue
        if FINAL_STATUS_RE.search(body) or MONITOR_EXPIRED_RE.search(body):
            done |= {i[:7] for i in TASK_ID_RE.findall(body)}
    return done


def _blocks(row, kind):
    content = _a12._content(row)
    if not isinstance(content, list):
        return []
    return [b for b in content if isinstance(b, dict) and b.get("type") == kind]


def _started_ids(row, tool_names):
    """Ids of background tasks started by the tool results of a user record."""
    result = row.get("toolUseResult")
    foreground = isinstance(result, dict) and result.get("status") == "completed"
    found = set()
    for block in _blocks(row, "tool_result"):
        name = tool_names.get(block.get("tool_use_id"))
        text = json.dumps(block.get("content"), ensure_ascii=False)
        for tools, regex in START_BY_TOOL:
            # A helper that finished in the foreground leaves no notification to wait for.
            if name in tools and not (regex is AGENT_START_RE and foreground):
                found |= _ids(regex, text)
    return found


def has_wake_source(rows):
    """True if a started background task is not finished, or a wake-up alarm is set."""
    # Records are replayed in order, so a resumed agent (same id started again after it
    # finished) counts as pending again: the last event of each id wins.
    pending = set()
    tool_names = {}
    humans = [i for i, r in enumerate(rows) if _a12._human_text(r) is not None]
    alarm_from = humans[-2] if len(humans) >= 2 else 0
    cron_alive = False
    wakeup_set = False
    for i, row in enumerate(rows):
        role = _a12._role(row)
        if role == "assistant":
            for block in _blocks(row, "tool_use"):
                tool_names[block.get("id")] = block.get("name")
                name = block.get("name")
                recurring = (block.get("input") or {}).get("recurring", True)
                if name == CRON_TOOL and recurring is not False:
                    cron_alive = True  # a repeating job keeps waking the agent in later turns too
                elif name == CRON_DELETE_TOOL:
                    cron_alive = False
                elif name in (WAKEUP_TOOL, CRON_TOOL) and i >= alarm_from:
                    wakeup_set = True
        if role == "user":
            pending |= _started_ids(row, tool_names)
        if role in ("user", "attachment") or "attachment" in row:
            pending -= _done_ids(json.dumps(row, ensure_ascii=False))
    return bool(pending) or cron_alive or wakeup_set


def i_without_wake_line(next_line, rows):
    """The "Дальше:" text if it promises the agent's own step and nothing will wake it."""
    if I_LINE_RE.search(next_line) and not has_wake_source(rows):
        return next_line
    return None


# Two kinds of an empty "я" (РП-605 Ф9, 26.11.2026, review by Fable): a step that waits
# for the pilot's word or for a later session ("я ... если вы скажете", "я в следующей
# сессии") is a mislabelled "вы" line, and sending the turn back would only produce a
# rewritten line, the second block the pilot complained about on 25.11. A step with no
# such condition could simply be done now, and the second answer is the work itself.
# Explicit list (P13), extend it from real misses.
CONDITIONAL_RE = re.compile(
    r"(?:если|когда|как\s+только)\s+(?:вы\s+)?(?:скажете|напишете|согласны|одобрите|разрешите|дадите|подтвердите)"
    r"|(?:по|при|после)\s+ваш\w+\s+(?:слов[оаеу]\b|команд\w*|одобрени\w*|подтверждени\w*|ответ\w*|согласи\w*)"
    r"|ваш\w*\s+слов[оаеу]\b"
    r"|следующ\w+\s+(?:сесси\w+|бесед\w+)|в\s+нов\w+\s+(?:сесси\w+|бесед\w+)"
    # Waits found by the review of 26.11 (Fable): the pilot's decision / signal / "да", "как скажете",
    # "если не против / хотите", "жду", and a third party's answer.
    r"|(?<!без )ваш\w*\s+[«\"“]?(?:решени\w+|сигнал\w*|да\b|нет\b|ответ\w*|согласи\w+|выбор\w*)"
    r"|как\s+(?:скажете|захотите)|если\s+(?:вы\s+)?(?:не\s+против|хотите|захотите)"
    r"|когда\s+(?:вы\s+)?ответите|\bжду\b|ожида\w+"
    r"|ответ\w*\s+(?:Гермес\w*|Ким[иа]\w*|Kimi|Кодекс\w*|Codex|Андре\w+|Ильшат\w*)",
    re.IGNORECASE,
)
# A "вы" step before the "я" step in one line ("1) вы: сказать «да»; 2) я: залью"): the "я" step
# waits for it by construction, so it is a mislabelled "вы" line, not an empty promise.
YOU_STEP_BEFORE_RE = re.compile(r"(?:^|[;.]\s*)(?:\d+[.)]\s*)?\**вы\**\s*[,:\-—]", re.IGNORECASE)


def no_wake_kind(no_wake_line):
    """"COND" for a step that waits for the pilot or a later session, "FREE" otherwise, "" for none."""
    if not no_wake_line:
        return ""
    first_i = I_LINE_RE.search(no_wake_line)
    if first_i and YOU_STEP_BEFORE_RE.search(no_wake_line[: first_i.start()]):
        return "COND"
    return "COND" if CONDITIONAL_RE.search(no_wake_line) else "FREE"


def detect(path):
    """Returns (missing, empty_content_line, unnamed_launcher_line, this_chat_line, i_no_wake_line)."""
    # Rule 6 covers replies to the pilot only. A peer's turn in a peer
    # session is addressed to the writer, so no signal applies there
    # (style-check-text.sh sets STYLE_CONTEXT=peer for peer adapters).
    if os.environ.get("STYLE_CONTEXT") == "peer":
        return False, None, None, None, None
    rows = list(_a12._rows(path))
    tail = final_assistant_lines(rows)
    next_line = next((m.group(1) for ln in tail if (m := NEXT_LINE_RE.match(ln))), None)
    if next_line is None:
        return not shown_before_guard_feedback(rows), None, None, None, None
    if not LETTER_RE.search(next_line):
        return False, next_line, None, None, None
    return (
        False,
        None,
        unnamed_launcher_line(next_line),
        this_chat_place_line(next_line),
        i_without_wake_line(next_line, rows),
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: a12-next-block.py <transcript.jsonl>")
    missing, empty_content_line, unnamed_line, this_chat_line, no_wake_line = detect(sys.argv[1])
    print("MISSING" if missing else "")
    print(empty_content_line or "")
    print(unnamed_line or "")
    print(this_chat_line or "")
    print(no_wake_line or "")
    print(no_wake_kind(no_wake_line))  # sixth line: "COND" / "FREE" / empty
