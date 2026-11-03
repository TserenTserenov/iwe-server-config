#!/usr/bin/env python3
"""Tests for iwe_jargon.py (РП-388 Ф39, pack rule 9).

Run: python3 .claude/hooks/tests/test-iwe-jargon.py
The pack table is read from $IWE_STYLE_PACK, else from
$IWE_ROOT/PACK-digital-platform/... (default ~/IWE). Without the pack the
sync check is reported as skipped, the matching checks still run.
"""
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iwe_jargon import WORDS, find_jargon  # noqa: E402

PACK_REL = "PACK-digital-platform/pack/digital-platform/02-domain-entities/communication-style-base.md"
failures = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f": {detail}"))
    if not ok:
        failures.append(name)


def pack_labels(text):
    """First column of the rule 9 table, in order."""
    start = text.index("9. **Слова внутренней кухни IWE")
    rows = []
    for line in text[start:].splitlines()[1:]:
        cell = re.match(r"^\s*\|\s*([^|]+?)\s*\|", line)
        if cell is None:
            if rows:
                break
            continue
        if cell.group(1) in ("Слово IWE",) or set(cell.group(1)) <= set("-"):
            continue
        rows.append(cell.group(1))
    return rows


pack = Path(os.environ.get("IWE_STYLE_PACK") or Path(os.environ.get("IWE_ROOT", Path.home() / "IWE")) / PACK_REL)
if pack.is_file():
    labels = pack_labels(pack.read_text(encoding="utf-8"))
    check("hook copy matches the pack table of rule 9", labels == [w[0] for w in WORDS],
          f"pack={labels} hook={[w[0] for w in WORDS]}")
else:
    print(f"SKIP pack sync: {pack} not found")

cases = [
    ("finds word forms in IWE talk", "Проверено в изолированной копии корня, в боевом IWE ещё нет.",
     [], ["корня", "боевом", "изолированной копии"]),
    ("ordinary «корень уравнения» is not jargon", "Корень уравнения в скрипте равен двум.", [], []),
    ("«отстаёт на 7 коммитов» is found", "Корень отстаёт на 7 коммитов.", [], ["Корень", "отстаёт на 7 коммитов"]),
    ("a word inside another word is not found", "Каноэ, канонада и боевик в репозитории.", [], []),
    ("the pilot's own word is skipped", "Залил в боевой IWE через маршрутизатор.",
     ["что с маршрутизатором?"], ["боевой"]),
    ("another form of the pilot's word is skipped too", "Канон в репозитории обновлён.", ["канона нет?"], []),
    # Ordinary Russian outside IWE talk (Codex, round 5).
    ("church canon is not jargon", "Церковный канон сложился давно.", [], []),
    ("«боевой характер» is not jargon", "У неё боевой характер.", [], []),
    ("a guard at the gate is not jargon", "Страж охраняет ворота.", [], []),
    ("a derivative in maths is not jargon", "Производная функции равна нулю.", [], []),
    ("freezing vegetables is not jargon", "Заморозка овощей сохраняет вкус.", [], []),
    # The exception is per word, not per dictionary row (Codex, round 5).
    ("pilot's «страж» does not excuse «хук»", "Добавлен хук в репозиторий.", ["Что делает страж?"], ["хук"]),
    ("both words of one row are reported", "В репозитории страж и хук.", [], ["страж", "хук"]),
]
for name, answer, pilot, expected in cases:
    got = find_jargon(answer, pilot)
    check(name, got == expected, f"got {got}, expected {expected}")

print(f"---\nfailed: {len(failures)}")
sys.exit(1 if failures else 0)
