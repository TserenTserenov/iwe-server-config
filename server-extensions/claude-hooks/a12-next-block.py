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
ADDRESSEE_RE = re.compile(
    r"\bты\b|\bтебе\b|\bтебя\b|\bтво(?:й|я|е|ё|его|ей|ему|ём|ем|им|ими|их|ю|и)\b|от\s+тебя"
    r"|подтверди(?:те)?|выбери(?:те)?|реши(?:те)?|скажи(?:те)?|ответь(?:те)?"
    r"|проверь(?:те)?|посмотри(?:те)?|одобри(?:те)?|согласуй(?:те)?"
    r"|напиши(?:те)?|пришли(?:те)?|дай(?:те)?",
    re.IGNORECASE,
)
GLOBAL_NO_EXPECTATION_RE = re.compile(
    r"ничего\s+не\s+(?:жду|нужно|требуется)|от\s+тебя\s+ничего|решения\s+не\s+жду",
    re.IGNORECASE,
)


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
    """Returns (missing: bool, no_addressee_line: str | None)."""
    # The profile covers replies to the pilot only. A peer's turn in a peer
    # session is addressed to the writer, so neither signal applies there
    # (style-check-text.sh sets STYLE_CONTEXT=peer for peer adapters).
    if os.environ.get("STYLE_CONTEXT") == "peer":
        return False, None
    rows = list(_a12._rows(path))
    tail = final_assistant_lines(rows)
    next_line = next((m.group(1) for ln in tail if (m := NEXT_LINE_RE.match(ln))), None)
    if next_line is None:
        return True, None
    has_signal = ADDRESSEE_RE.search(next_line) or GLOBAL_NO_EXPECTATION_RE.search(next_line)
    return False, (None if has_signal else next_line)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: a12-next-block.py <transcript.jsonl>")
    missing, no_addressee_line = detect(sys.argv[1])
    print("MISSING" if missing else "")
    print(no_addressee_line or "")
