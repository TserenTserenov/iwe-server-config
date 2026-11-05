#!/usr/bin/env python3
"""A12-next-block detector (РП-605 Ф1, 22.10.2026).

Four independent warn-only signals about the mandatory "Дальше:" line (A12,
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
    r"^(?:вы|я)\s*[,\-—]?\s*(?:в\s+этом\s+(?:чате|диалоге|окне)|в\s+этой\s+(?:беседе|сессии)|здесь)\s*[:,]",
    re.IGNORECASE,
)


def this_chat_place_line(next_line):
    """The "Дальше:" text if it names this chat as the place of a step."""
    if LEADING_THIS_CHAT_RE.match(next_line):
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


def detect(path):
    """Returns (missing, empty_content_line, unnamed_launcher_line, this_chat_line)."""
    # Rule 6 covers replies to the pilot only. A peer's turn in a peer
    # session is addressed to the writer, so no signal applies there
    # (style-check-text.sh sets STYLE_CONTEXT=peer for peer adapters).
    if os.environ.get("STYLE_CONTEXT") == "peer":
        return False, None, None, None
    rows = list(_a12._rows(path))
    tail = final_assistant_lines(rows)
    next_line = next((m.group(1) for ln in tail if (m := NEXT_LINE_RE.match(ln))), None)
    if next_line is None:
        return not shown_before_guard_feedback(rows), None, None, None
    if not LETTER_RE.search(next_line):
        return False, next_line, None, None
    return False, None, unnamed_launcher_line(next_line), this_chat_place_line(next_line)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: a12-next-block.py <transcript.jsonl>")
    missing, empty_content_line, unnamed_line, this_chat_line = detect(sys.argv[1])
    print("MISSING" if missing else "")
    print(empty_content_line or "")
    print(unnamed_line or "")
    print(this_chat_line or "")
