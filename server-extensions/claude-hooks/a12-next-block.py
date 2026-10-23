#!/usr/bin/env python3
"""A12-next-block detector (РП-605 Ф1, 22.10.2026).

Two independent warn-only signals about the mandatory "Дальше:" line (A12,
`feedback_response_clarity_for_pilot.md`), one per output line so a caller
can tell "no signal" from "detector found nothing to say" by line count:

  A12_NEXT_MISSING             none of the assistant's last 3 non-empty
                                lines starts with "Дальше:".
  A12_NEXT_NO_PILOT_ADDRESSEE  a "Дальше:" line exists, but its text has
                                neither addressee wording (ты/тебе/подтверди...)
                                nor a global "nothing expected from you" clause
                                -- the Codex live case this rule was written
                                for ("синхронизировать рабочую копию...
                                Алёне ничего писать не нужно") is a LOCAL
                                negation about someone else, not either form.

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

# Possessive "твой" is listed form by form: a stem match (тво\w*) would also
# hit "творчество"/"творить". Oblique cases were missing until 22.10 and gave
# two live false positives ("жду твоего «да»", "Без твоего решения").
#
# Polite "вы" forms added 22.10.2026 (РП-605 Ф4, live log finding: "жду вашего
# решения", "жду вашего «да»", "жду от вас выбор", "нужно ваше решение" all
# missed by the ты-only lexicon). Same word-list approach, same reason: a stem
# match on "ваш" would also hit unrelated words sharing the prefix, and \bвы\b
# as a bare token must not fire inside "выбор"/"вывод" -- \b already excludes
# those because there is no boundary between "вы" and the rest of those words.
ADDRESSEE_RE = re.compile(
    r"\bты\b|\bтебе\b|\bтебя\b|\bтво(?:й|я|е|ё|его|ей|ему|ём|ем|им|ими|их|ю|и)\b|от\s+тебя"
    r"|\bвы\b|\bвас\b|\bвам\b|\bвами\b|\bваш(?:а|е|и|его|ему|ем|им|ей|у|их|ими)?\b|от\s+вас"
    r"|подтверди(?:те)?|выбери(?:те)?|реши(?:те)?|скажи(?:те)?|ответь(?:те)?"
    r"|проверь(?:те)?|посмотри(?:те)?|одобри(?:те)?|согласуй(?:те)?"
    r"|напиши(?:те)?|пришли(?:те)?|дай(?:те)?",
    re.IGNORECASE,
)
GLOBAL_NO_EXPECTATION_RE = re.compile(
    r"ничего\s+не\s+(?:жду|нужно|требуется)|от\s+тебя\s+ничего|решения\s+не\s+жду",
    re.IGNORECASE,
)

# A12_NEXT_EMPTY_CONTENT (РП-605, 22.10.2026, пир-сессия Claude+Kimi+Codex
# 2026-10-22-23-codex-hook-gap-next): live case "Дальше: 👉" / "Дальше: 🏃" --
# a line that technically starts with "Дальше:" but carries zero letters, only
# emoji/punctuation/whitespace. ADDRESSEE_RE/GLOBAL_NO_EXPECTATION_RE already
# fail this (no match either way, same as a text clause missing the
# addressee), but the two cases are qualitatively different: one forgot the
# addressee wording, the other wrote no clause at all. Separate signal for
# that distinction in telemetry, not a stricter gate class -- still warn-only,
# see CONSENSUS in that session's report.md for the revisit criterion.
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


def detect(path):
    """Returns (missing, empty_content_line, no_addressee_line).

    `empty_content_line` and `no_addressee_line` are mutually exclusive: an
    emoji/punctuation-only clause is a stricter failure than one that has
    words but forgot the addressee, so it is reported once under its own
    signal, not double-counted under both.
    """
    # The profile covers replies to the pilot only. A peer's turn in a peer
    # session is addressed to the writer, so neither signal applies there
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
    has_signal = ADDRESSEE_RE.search(next_line) or GLOBAL_NO_EXPECTATION_RE.search(next_line)
    return False, None, (None if has_signal else next_line)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: a12-next-block.py <transcript.jsonl>")
    missing, empty_content_line, no_addressee_line = detect(sys.argv[1])
    print("MISSING" if missing else "")
    print(empty_content_line or "")
    print(no_addressee_line or "")
