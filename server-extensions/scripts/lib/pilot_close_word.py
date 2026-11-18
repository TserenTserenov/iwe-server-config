#!/usr/bin/env python3
"""Check that a phrase is the pilot's own closing word (WP-561, 18.11.2026).

Used by `session-guard.sh close` for sessions opened with `close_path: peer-session`:
closing needs the pilot's explicit word, and a choice of work scope (an answer to the
Decision Gate) or an approval such as "согласен, делай" is not that word.

Usage: pilot_close_word.py "<verbatim pilot phrase>"
Exit 0 = accepted, 1 = refused (reason on stderr).

Known limit: this checks the form of the phrase, not who said it. An agent can still
paste an invented phrase; the audit line written by the caller makes that visible
afterwards, it does not prevent it.
"""
import re
import sys

MAX_LEN = 160
# Closing words (CLAUDE.md rule 3: «закрывай», «всё»; ПСЗ/СЗ close too). «заливай» alone is
# commit+push (rule 2), not a closing word, so it is not here.
CLOSE_WORD_RE = re.compile(
    r"(?<!\w)(закрывай|закрой|закрыть|закрываем|закроем|псз|сз)(?!\w)", re.IGNORECASE
)
# «всё» counts only as the opening word of a statement, never as a question.
ALL_WORD_RE = re.compile(r"^\W*(всё|все)(?!\w)\s*([,.!]|$)", re.IGNORECASE)
# A negation anywhere makes the phrase unusable: «не закрывай», «пока не закрывай».
NEGATION_RE = re.compile(r"(?<!\w)(не|нет|нельзя|пока не|ни)(?!\w)", re.IGNORECASE)
# Marks of a copied option label or agent text rather than a pilot's phrase.
OPTION_COPY_RE = re.compile(r"→|вариант|только (записать|зафиксировать)|реализовать сейчас", re.IGNORECASE)


def check(phrase: str):
    """Return (ok, reason)."""
    text = (phrase or "").strip()
    if not text:
        return False, "слово пилота пустое"
    if len(text) > MAX_LEN:
        return False, f"фраза длиннее {MAX_LEN} знаков: это не короткая реплика пилота"
    if NEGATION_RE.search(text):
        return False, "в фразе есть отрицание («не закрывай»): это не слово о закрытии"
    if "?" in text:
        return False, "фраза-вопрос не является словом о закрытии"
    if OPTION_COPY_RE.search(text):
        return False, "фраза похожа на подпись варианта выбора, а не на слово пилота о закрытии"
    if CLOSE_WORD_RE.search(text) or ALL_WORD_RE.match(text):
        return True, ""
    return False, "в фразе нет слова о закрытии («закрывай», «всё», ПСЗ, СЗ)"


def main(argv):
    if len(argv) != 2:
        print("usage: pilot_close_word.py <phrase>", file=sys.stderr)
        return 2
    ok, reason = check(argv[1])
    if not ok:
        print(reason, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
