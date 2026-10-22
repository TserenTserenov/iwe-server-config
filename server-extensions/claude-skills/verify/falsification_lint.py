#!/usr/bin/env python3
"""Deterministic checks for /verify: the falsification condition before the
sub-agent runs, and the shape of the verdict it returns.

Usage:
    falsification_lint.py condition < condition.txt
    falsification_lint.py verdict [--condition-file condition.txt] < verdict.md

Write the input files with a file-writing tool, not through the shell: text
in double quotes or in a heredoc can execute backticks, $(...) or break out
at a line equal to the delimiter.

Exit 0 and "OK" when valid; exit 1 and one "INVALID: <reason>" line per
problem otherwise.
"""

import argparse
import re
import sys
from pathlib import Path

VERDICTS = ("PASS", "CONDITIONAL", "FAIL", "UNKNOWN", "NOT_VERIFIABLE")

MIN_CONDITION_LENGTH = 20

# An anchor names something observable in the artifact. Quotes are weak: they
# can wrap any generic word, so they do not rescue a vague phrase.
STRONG_ANCHORS = (
    re.compile(r"`[^`\n]+`"),
    re.compile(r"[\w./-]+\.(?:py|sh|md|ts|tsx|js|yaml|yml|json|toml|sql)\b"),
    re.compile(r"\b(?:строк[аеиу]|line)\s*\d+", re.IGNORECASE),
    re.compile(r"[\w./-]*[A-Za-z_.][\w./-]*:\d+\b"),
)
WEAK_ANCHORS = (
    re.compile(r"«[^»\n]{2,}»"),
    re.compile(r'"[^"\n]{2,}"'),
)

# Rejected whatever anchors surround them: they name no observable at all.
VAGUE_PHRASES = (
    "если найдены ошибки",
    "если есть ошибки",
    "если найдены несоответствия",
    "если есть несоответствия",
    "если код не работает",
    "если что-то не так",
    "если что-то сломано",
    "если проверка не пройдена",
    "if errors are found",
    "if something is wrong",
    "if it does not work",
    "в любом файле",
    "любые ошибки",
)
# Common in precise conditions too; rejected only without a strong anchor.
SOFT_VAGUE_WORDS = ("что-то", "что-либо", "какие-либо")

# Several conditions on one line: "; FAIL…", "; и если…", ", а также если…".
CONDITION_SPLIT = re.compile(
    r";\s*(?:и\s+)?(?=(?:FAIL|если)\b)|,\s*а\s+также\s+(?=если\b)", re.IGNORECASE
)
LIST_MARKER = re.compile(r"^[ \t]*(?:[-*+>][ \t]+|\d+[.)][ \t]+)")
CODE_FENCE = re.compile(r"^[ \t]*(?:```|~~~)")

# Accepts natural variants (bold, backticks, [PASS], table cell, emoji, a
# trailing remark after a dash or parenthesis) but rejects templates and prose
# such as "[PASS / FAIL]", "PASS/FAIL" or "Pass with remarks".
VERDICT_LINE = re.compile(
    r"^[ \t]*\|?[ \t]*(?:\*\*)?#{0,4}[ \t]*(?:\*\*)?(?:[^\w\s|*#][ \t]*){0,2}(?:\*\*)?"
    r"(?:Verdict|Вердикт)(?:\*\*)?[ \t]*(?::|\|)[ \t]*(?:[^\w\s|/][ \t]*){0,4}"
    r"([A-Za-z_]+)"
    r"(?:\*\*|`|\])*[ \t]*[.!]?[ \t]*\|?[ \t]*(?:(?:[—–-]|\(|[^\w\s/|])[^\n]*)?$",
    re.MULTILINE | re.IGNORECASE,
)

PLACEHOLDER = re.compile(r"\[[^\]]*\]")

CONDITION_SECTION = "Условие опровержения"
CHECKED_SECTION = "Что проверено"
MISMATCHES_SECTION = "Несоответствия"
# Canonical order. A section body runs until a heading of a LATER section, so
# sub-headings and mentions of earlier sections inside a body stay its content.
KNOWN_SECTIONS = (
    CONDITION_SECTION,
    CHECKED_SECTION,
    MISMATCHES_SECTION,
    "Сводка",
    "Рекомендация",
)


def _heading_pattern(name: str) -> re.Pattern:
    numbered = r"(?:\d+[.)][ \t]*)?"
    title = re.escape(name)
    suffix = r"[ \t]*(?:\([^)\n]*\))?[ \t]*:?[ \t]*"
    return re.compile(
        rf"^[ \t]*(?:#{{1,6}}[ \t]*{numbered}{title}{suffix}"
        rf"|\*\*[ \t]*{numbered}{title}{suffix}\*\*[ \t]*:?[ \t]*(?P<inline>[^\n]*))$",
        re.MULTILINE,
    )


def _outside_code(text: str) -> str:
    """Blank out fenced code blocks, keeping offsets."""
    lines = text.splitlines(keepends=True)
    in_fence = False
    kept = []
    for line in lines:
        if CODE_FENCE.match(line):
            in_fence = not in_fence
            kept.append(" " * (len(line) - 1) + ("\n" if line.endswith("\n") else ""))
            continue
        kept.append(re.sub(r"[^\n]", " ", line) if in_fence else line)
    return "".join(kept)


def _has_content(text: str) -> bool:
    stripped = PLACEHOLDER.sub("", text)
    return re.search(r"\w", stripped) is not None


def _find_section(text: str, name: str) -> tuple[int, str] | None:
    """Return (start offset, body) of a section, or None if absent."""
    plain = _outside_code(text)
    heading = _heading_pattern(name).search(plain)
    if not heading:
        return None
    body_end = len(text)
    later = KNOWN_SECTIONS[KNOWN_SECTIONS.index(name) + 1 :]
    for other in later:
        nxt = _heading_pattern(other).search(plain, heading.end())
        if nxt and nxt.start() < body_end:
            body_end = nxt.start()
    inline = heading.group("inline") or ""
    return heading.start(), (inline + "\n" + text[heading.end() : body_end]).strip()


def _field_value(text: str, label: str) -> str:
    match = re.search(
        rf"^[ \t]*(?:[-*][ \t]+)?\**{re.escape(label)}\**[ \t]*[:：][ \t]*\**[ \t]*(\S.*)$",
        text,
        re.MULTILINE,
    )
    if not match:
        return ""
    value = match.group(1).strip().strip("*").strip()
    return value if _has_content(value) else ""


def _condition_lines(text: str) -> list[str]:
    """Non-empty lines of a condition, without list markers and code fences."""
    lines = []
    for line in text.splitlines():
        if CODE_FENCE.match(line):
            continue
        line = LIST_MARKER.sub("", line).strip()
        if line:
            lines.append(line)
    return lines


def _conditions(text: str) -> list[tuple[str, str]]:
    """(fragment, context) pairs.

    A fragment starting with FAIL is an independent condition and is its own
    context; a continuation («и если…», «а также если…») is judged within its
    whole line, so it inherits the line's subject and anchor.
    """
    pairs = []
    for line in _condition_lines(text):
        for part in CONDITION_SPLIT.split(line):
            part = part.strip()
            if part:
                independent = re.match(r"FAIL\b", part, re.IGNORECASE)
                pairs.append((part, part if independent else line))
    return pairs


def _has_anchor(text: str, patterns: tuple[re.Pattern, ...]) -> bool:
    return any(pattern.search(text) for pattern in patterns)


def _check_one_condition(fragment: str, context: str) -> str | None:
    if len(context) < MIN_CONDITION_LENGTH:
        return f"условие короче {MIN_CONDITION_LENGTH} символов"
    lowered = fragment.lower()
    vague = [phrase for phrase in VAGUE_PHRASES if phrase in lowered]
    if vague:
        return f"пустая формула без наблюдаемого: «{vague[0]}»"
    soft = [word for word in SOFT_VAGUE_WORDS if word in lowered]
    if soft and not _has_anchor(context, STRONG_ANCHORS):
        return f"размытое «{soft[0]}» без точного якоря (код, путь, строка, файл:N)"
    if _has_anchor(context, STRONG_ANCHORS + WEAK_ANCHORS):
        return None
    return (
        "нет якоря наблюдаемого (код/идентификатор в обратных кавычках, путь "
        'с расширением, строка N, файл:N, цитата в «» или "")'
    )


def check_condition(text: str) -> list[str]:
    """Each independent condition must carry an anchor and name an observable."""
    conditions = _conditions(text)
    if not conditions:
        return ["условие пустое"]
    problems = []
    for number, (fragment, context) in enumerate(conditions, start=1):
        problem = _check_one_condition(fragment, context)
        if problem:
            prefix = f"условие {number}: " if len(conditions) > 1 else ""
            problems.append(prefix + problem)
    return problems


# Summary labels are plural counts ("Критических: 1", "| Critical | 1 |");
# a findings row carries a singular severity value in its own cell.
SUMMARY_LABELS = {
    "critical": r"(?:Критически[хе]|Критичных|Critical)",
    "high": r"(?:Высоки[хе]|High)",
}
SEVERITY_VALUES = {
    "critical": r"(?:критическ(?:ий|ая|ое)|critical)",
    "high": r"(?:высок(?:ий|ая|ое)|high)",
}


def _severity_count(text: str, level: str) -> int | None:
    """Largest count seen in the summary (any line layout) or the findings table.

    None when the answer states nothing about this level at all.
    """
    summary = re.findall(
        rf"\**{SUMMARY_LABELS[level]}(?:[ \t]+[^\W\d]+)?\**[ \t]*(?::|\||—|–|-)\**[ \t]*(\d+)",
        text,
        re.IGNORECASE,
    )
    # A cell holding a severity value, not followed by a number cell (that
    # shape is a summary table row such as "| Critical | 1 |").
    rows = len(
        re.findall(
            rf"\|[ \t]*\**{SEVERITY_VALUES[level]}\**[ \t]*\|(?![ \t]*\d+[ \t]*\|)",
            text,
            re.IGNORECASE,
        )
    )
    if not summary and not rows:
        return None
    return max([rows, *(int(number) for number in summary)])


def _summary_problems(verdict: str, text: str) -> list[str]:
    # A FAIL is never downgraded by its own bookkeeping: see SKILL.md Шаг 3.
    if verdict == "FAIL":
        return []
    critical = _severity_count(text, "critical")
    high = _severity_count(text, "high")
    if critical:
        return [
            f"{verdict} при критических несоответствиях ({critical}) — должен быть FAIL"
        ]
    if verdict == "PASS" and high:
        return [f"PASS при высоких несоответствиях ({high})"]
    if verdict == "CONDITIONAL" and high == 0:
        return ["CONDITIONAL без высоких несоответствий"]
    return []


def _normalize_condition(text: str) -> str:
    return " ".join(" ".join(_condition_lines(text)).split())


def check_verdict(text: str, expected_condition: str | None = None) -> list[str]:
    statuses = {match.upper() for match in VERDICT_LINE.findall(_outside_code(text))}
    if not statuses:
        return ["нет строки «## Verdict: <статус>»"]
    if len(statuses) > 1:
        return [
            f"несколько строк вердикта с разными статусами: {', '.join(sorted(statuses))}"
        ]
    verdict = statuses.pop()
    if verdict not in VERDICTS:
        return [f"недопустимый статус {verdict}; допустимы: {', '.join(VERDICTS)}"]

    if verdict == "NOT_VERIFIABLE":
        if not _field_value(text, "Причина"):
            return ["NOT_VERIFIABLE без непустой строки «Причина:»"]
        return []

    problems = []
    condition = _find_section(text, CONDITION_SECTION)
    checked = _find_section(text, CHECKED_SECTION)
    mismatches = _find_section(text, MISMATCHES_SECTION)
    for name, section in ((CONDITION_SECTION, condition), (CHECKED_SECTION, checked)):
        if section is None:
            problems.append(f"нет раздела «{name}»")
        elif not _has_content(section[1]):
            problems.append(f"пустой раздел «{name}»")
    if condition and checked and condition[0] > checked[0]:
        problems.append(f"«{CONDITION_SECTION}» должно стоять до «{CHECKED_SECTION}»")
    if mismatches and checked and checked[0] > mismatches[0]:
        problems.append(f"«{CHECKED_SECTION}» должно стоять до «Несоответствий»")
    if (
        expected_condition is not None
        and condition
        and _has_content(condition[1])
        and _normalize_condition(expected_condition)
        not in _normalize_condition(condition[1])
    ):
        problems.append(
            "«Условие опровержения» в ответе не совпадает с поданным на вход"
        )

    if verdict == "UNKNOWN":
        for label in ("Недостающее свидетельство", "Как получить"):
            if not _field_value(text, label):
                problems.append(f"UNKNOWN без непустой строки «{label}:»")
    problems.extend(_summary_problems(verdict, text))
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("mode", choices=("condition", "verdict"))
    parser.add_argument(
        "--condition-file",
        type=Path,
        help="verdict mode: the condition given to the sub-agent; must appear verbatim",
    )
    args = parser.parse_args(argv)
    text = sys.stdin.read()
    if args.mode == "condition":
        problems = check_condition(text)
    else:
        expected = (
            args.condition_file.read_text(encoding="utf-8")
            if args.condition_file
            else None
        )
        problems = check_verdict(text, expected)
    if problems:
        for problem in problems:
            print(f"INVALID: {problem}")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
