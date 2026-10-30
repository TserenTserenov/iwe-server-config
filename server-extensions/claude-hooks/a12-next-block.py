#!/usr/bin/env python3
"""A12-next-block detector (РП-605 Ф1, 22.10.2026).

Three independent warn-only signals about the mandatory "Дальше:" line (A12,
pack `communication-style-base.md` rule 6), one per output line so a caller
can tell "no signal" from "detector found nothing to say" by line count:

  A12_NEXT_MISSING             none of the assistant's last 3 non-empty lines
                               starts with "Дальше:".
  A12_NEXT_EMPTY_CONTENT       a "Дальше:" line exists but carries no letters.
  A12_NEXT_UNNAMED_LAUNCHER    the line promises a "следующая сессия" and names
                               nobody who starts it (added 30.10.2026).

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


def detect(path):
    """Returns (missing, empty_content_line, unnamed_launcher_line)."""
    # Rule 6 covers replies to the pilot only. A peer's turn in a peer
    # session is addressed to the writer, so no signal applies there
    # (style-check-text.sh sets STYLE_CONTEXT=peer for peer adapters).
    if os.environ.get("STYLE_CONTEXT") == "peer":
        return False, None, None
    rows = list(_a12._rows(path))
    tail = final_assistant_lines(rows)
    next_line = next((m.group(1) for ln in tail if (m := NEXT_LINE_RE.match(ln))), None)
    if next_line is None:
        return True, None, None
    if not LETTER_RE.search(next_line):
        return False, next_line, None
    return False, None, unnamed_launcher_line(next_line)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: a12-next-block.py <transcript.jsonl>")
    missing, empty_content_line, unnamed_line = detect(sys.argv[1])
    print("MISSING" if missing else "")
    print(empty_content_line or "")
    print(unnamed_line or "")
