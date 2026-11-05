#!/usr/bin/env python3
# claude-hook: false — вызывается из kimi-style-stop.py (Kimi Stop hook в
# ~/.kimi/config.toml), не из settings.json; см. check-orphan-hooks.sh.
# ortho-check.py <agent> <text-file> — орфографическая проверка одного ответа
# агента (РП-388 Ф26, решение пилота 25.10: журнал + напоминание, НЕ блок).
#
# Контур тот же, что у стиля: словарь LibreOffice ru_RU через spylls
# (~/.iwe/ortho/rudict.*, venv ~/.iwe/venvs/ortho — машинные, не в git),
# белый список жаргона IWE — ortho-jargon.txt рядом со скриптом (600 слов,
# собраны ручной классификацией флагов Ф25). Строки в тот же журнал
# ~/.claude/logs/style-violations.log, формат TS | agent | ORTHO | misspelling |
# word :: context, чтобы style-feedback-loop.py агрегировал без изменений
# (порог 3/нед → fault-reminder, см. Ф6/Ф10).
#
# Пропускаются: fenced-блоки и inline-backtick спаны (код), латиница,
# аббревиатуры КАПСОМ, слова короче 2 букв, слова из белого списка.
# Пир-режим (IWE_STYLE_CONTEXT=peer) не проверяет и не пишет — там проверку
# делает адаптер (Ф24), чтобы не задваивать строки; подключение орфо в
# адаптер — отдельное решение пилота.
#
# Три класса находок (Ф26 → расширение 05.11, запрос пилота «исправить
# системно»):
#   misspelling — слова нет в словаре hunspell (склейки, опечатки);
#   rare-word   — слово есть в словаре, но частота в языке ≈ 0 (обрезки
#                 типа «опечат» — hunspell пропускает как основу);
#   truncated   — слово есть и встречается, но является началом слова с
#                 частотой выше на ≥2 порядка («пиш» → «пишет»).
# Частоты — wordfreq (zipf) в том же venv ~/.iwe/venvs/ortho.
#
# Найденные слова печатаются в stdout (одно на строку) — их подхватывает
# kimi-style-stop.py и возвращает агенту как напоминание до показа ответа
# пилоту (механика Ф21; пилот видит только итоговый, исправленный ответ).
#
# Fail-open: любая ошибка → молчаливый exit 0. Никогда не блокирует ответ.

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

VENV_PYTHON = os.path.expanduser("~/.iwe/venvs/ortho/bin/python")
DICT_BASE = os.path.expanduser("~/.iwe/ortho/rudict")
LOG_FILE = os.path.expanduser("~/.claude/logs/style-violations.log")
JARGON_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ortho-jargon.txt")

MAX_ROWS_PER_REPLY = 10  # защита журнала от развала словаря/кодировки

WORD_RE = re.compile(r"[А-Яа-яЁё]+(?:-[А-Яа-яЁё]+)*")
FENCE_RE = re.compile(r"```.*?```", re.DOTALL)
BACKTICK_RE = re.compile(r"`[^`\n]*`")

# Словарь и частоты грузим в дочернем процессе venv: системный python не
# содержит spylls/wordfreq, а хук не может зависеть от пакетов глобального
# окружения. Хелпер решает все три класса находок и печатает "причина слово".
HELPER = r"""
import sys
from spylls.hunspell import Dictionary
from wordfreq import zipf_frequency

RARE_ZIPF = 1.5          # ниже — слово практически не встречается в языке
TRUNC_MAX_ZIPF = 3.5     # у частых слов обрезок не детектируем
TRUNC_GAP = 2.0          # обрезок: продолжение частотнее на ≥2 порядка

d = Dictionary.from_files(sys.argv[1])
letters = "абвгдежзийклмнопрстуфхцчшщъыьэюя"
for raw in sys.stdin.read().splitlines():
    w = raw.strip().lower().replace("ё", "е")
    if not w:
        continue
    if not d.lookup(w):
        print("misspelling " + raw)
        continue
    z = zipf_frequency(w, "ru")
    if z < RARE_ZIPF:
        print("rare-word " + raw)
        continue
    if len(w) >= 3 and z <= TRUNC_MAX_ZIPF:
        for c in letters:
            if zipf_frequency(w + c, "ru") >= z + TRUNC_GAP:
                print("truncated " + raw)
                break
"""


def load_jargon() -> set[str]:
    try:
        with open(JARGON_FILE, encoding="utf-8") as fh:
            return {line.strip().lower() for line in fh if line.strip()}
    except OSError:
        return set()


def extract_words(text: str, jargon: set[str]) -> tuple[str, list[str]]:
    """Чистый от кодовых спанов текст + уникальные слова на проверку."""
    body = FENCE_RE.sub(" ", text)
    body = BACKTICK_RE.sub(" ", body)
    words: list[str] = []
    seen: set[str] = set()
    for match in WORD_RE.finditer(body):
        word = match.group(0)
        low = word.lower()
        if len(word) < 2 or word.isupper() or low in jargon or low in seen:
            continue
        seen.add(low)
        words.append(word)
    return body, words


def spellcheck(words: list[str]) -> list[tuple[str, str]]:
    """Возвращает (причина, слово) для всех классов находок. Сбой → пусто (fail-open)."""
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", suffix=".py", delete=False
    ) as hf:
        hf.write(HELPER)
        helper_path = hf.name
    try:
        done = subprocess.run(
            [VENV_PYTHON, helper_path, DICT_BASE],
            input="\n".join(words),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=15,
            check=False,
        )
    except Exception:
        return []
    finally:
        try:
            os.unlink(helper_path)
        except OSError:
            pass
    bad = []
    for line in (done.stdout or "").splitlines():
        reason, _, word = line.partition(" ")
        if reason and word:
            bad.append((reason.strip(), word))
    return bad


def main() -> int:
    try:
        if os.environ.get("IWE_STYLE_CONTEXT") == "peer":
            return 0
        if len(sys.argv) < 3:
            return 0
        agent = sys.argv[1]
        path = sys.argv[2]
        if not os.path.isfile(path) or not os.path.isfile(VENV_PYTHON):
            return 0
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        if not text.strip():
            return 0

        body, words = extract_words(text, load_jargon())
        if not words:
            return 0
        bad = spellcheck(words)
        if not bad:
            return 0

        timestamp = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S")
        rows = []
        for reason, word in bad[:MAX_ROWS_PER_REPLY]:
            match = re.search(re.escape(word), body)
            ctx = ""
            if match:
                start = max(0, match.start() - 25)
                end = min(len(body), match.end() + 25)
                ctx = body[start:end].replace("\n", " ").replace("|", "¦").strip()
            rows.append(f"{timestamp} | {agent} | ORTHO | {reason} | {word} :: {ctx}")
        with open(LOG_FILE, "a", encoding="utf-8") as lf:
            lf.write("\n".join(rows) + "\n")
        # stdout — для kimi-style-stop.py: напоминание агенту до показа ответа.
        for _, word in bad[:MAX_ROWS_PER_REPLY]:
            print(word)
    except Exception:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
