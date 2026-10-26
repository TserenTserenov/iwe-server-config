"""Tests for scripts/concept-kind.py (РП-388 Ф27) against the live registry."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "concept-kind.py"
spec = importlib.util.spec_from_file_location("concept_kind", SCRIPT)
ck = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ck)
DATA, _ = ck.load()


def test_lookup_miss_prints_claimed_kind_test_and_no_draft():
    outcome, lines = ck.lookup(DATA, "борщ", "работа")
    text = "\n".join(lines)
    assert outcome == "miss"
    assert "род не установлен" in text
    assert "A.15.1" in text  # the work kind test
    assert "draft" not in text


def test_lookup_hit_inflected_form():
    outcome, lines = ck.lookup(DATA, "агента", None)
    assert outcome == "hit"
    assert "род «система»" in lines[0]


def test_lookup_overloaded_word_is_ambiguous():
    outcome, _ = ck.lookup(DATA, "результат", None)
    assert outcome == "ambiguous"


def test_check_text_catches_pilot_cases_outside_registry():
    warnings = ck.check_text(
        DATA, "Рецепт борща — метод. А борщ, который варится на плите, это уже работа."
    )
    assert len(warnings) == 2
    assert "род «метод»" in warnings[0]
    assert "род «работа»" in warnings[1]


def test_check_text_catches_kind_conflict_for_known_subject():
    warnings = ck.check_text(DATA, "Инструкция — это метод проверки.")
    assert len(warnings) == 1
    assert "род «описание»" in warnings[0] and "род «метод»" in warnings[0]


def test_check_text_silent_on_negation_quotes_code_and_matching_kind():
    text = (
        "Борщ — это не работа. Агент — это система. Прогон — это работа. "
        "Он сказал: «борщ — это работа». Код: `x — это работа`. Сегодня — пятница. "
        "Как — работает. Вторая ступень — методологическая. Рецепт изменился — человек.\n"
        "## Встреча 9 — Планирование\n| Роли — Агенты |"
    )
    assert ck.check_text(DATA, text) == []


def test_cli_writes_one_log_line_per_call(tmp_path):
    log = tmp_path / "ck.log"
    env = {**os.environ, "CONCEPT_KIND_LOG": str(log)}
    run = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--agent",
            "pytest",
            "lookup",
            "борщ",
            "--claim",
            "работа",
        ],
        capture_output=True,
        text=True,
        env=env,
        check=True,
    )
    assert "род не установлен" in run.stdout
    fields = log.read_text(encoding="utf-8").strip().split("\t")
    assert fields[1] == "pytest" and fields[3:] == ["lookup", "борщ", "miss", "работа"]


def run_cli(tmp_path, *args, stdin=None):
    env = {**os.environ, "CONCEPT_KIND_LOG": str(tmp_path / "ck.log")}
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        input=stdin,
        capture_output=True,
        env=env,
        check=False,
    )


def test_cli_bad_input_is_skipped_with_exit_zero(tmp_path):
    missing = run_cli(tmp_path, "check-text", str(tmp_path / "nope.md"))
    assert missing.returncode == 0
    assert "файл не прочитан" in missing.stderr.decode()
    latin1 = run_cli(
        tmp_path, "check-text", "-", stdin="Борщ — это работа.".encode("cp1251")
    )
    assert latin1.returncode == 0
    assert "предупреждений" in latin1.stdout.decode()


def test_cli_log_line_keeps_seven_columns_with_tabs_in_fields(tmp_path):
    run = run_cli(tmp_path, "--agent", "ag\tx\ny", "lookup", "борщ", "--claim", "р\tа")
    assert run.returncode == 0
    lines = (tmp_path / "ck.log").read_text(encoding="utf-8").splitlines()
    assert len(lines) == 1
    fields = lines[0].split("\t")
    assert len(fields) == 7 and fields[1] == "ag x y" and fields[6] == "р а"
