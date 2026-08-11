#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tests for artifactor.py schema_version 2 (WP-481 Ф7 шаги 3-4).

Ранее (WP-421) существовал только ручной прогон 23 фраз, не сохранённый как
pytest — первое персистентное покрытие для этого файла (05.08.2026, консенсус
пир-сессии 2026-08-05-14-codex-wp481-f7-impl).
"""

import json
import os
import subprocess
import sys

import pytest

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARTIFACTOR = os.path.join(SCRIPTS, "artifactor.py")

sys.path.insert(0, SCRIPTS)
import artifactor as af  # noqa: E402 — путь добавлен строкой выше


def run_artifactor(text, env_extra=None):
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        [sys.executable, ARTIFACTOR, text],
        capture_output=True, text=True, env=env, check=False,
    )


ALL_KEYWORDS = list(af.KEYWORD_MAP.items())


@pytest.mark.parametrize("kw,expected", ALL_KEYWORDS, ids=[kw for kw, _ in ALL_KEYWORDS])
def test_every_keyword_produces_valid_schema_v2(kw, expected):
    """Каждая из всех записей KEYWORD_MAP классифицируется без падения и
    возвращает согласованную форму (schema_version 2, WP-481 Ф7)."""
    task_type, cls, kind_id, artifact = expected
    r = run_artifactor(kw)
    assert r.returncode == 0, r.stderr
    result = json.loads(r.stdout)
    assert result["task_type"] == task_type
    assert result["class"] == cls
    assert result["schema_version"] == 2
    assert result["confidence"] == "high"
    assert result["resolution_path"] == "keyword"
    assert result["artifact"] == artifact
    assert result["artifact"]
    if kind_id is None:
        assert result["expected_result_kind"] is None
        assert result["result_kind_resolution"] == af.SPECIAL_RESOLUTION[task_type]
    else:
        assert result["expected_result_kind"] == kind_id
        assert result["result_kind_resolution"] == "static"


def test_ke_review_is_choice_result_not_episteme():
    """Живая находка Codex (ход 3): решение accept/reject/defer (R15), не граф
    claim'ов — регрессия против прежней (неверной) карты."""
    r = run_artifactor("нужен разбор ke кандидатов знания")
    result = json.loads(r.stdout)
    assert result["expected_result_kind"] == "ChoiceResult"


def test_content_plan_is_choice_result_not_episteme():
    """Живая находка Codex: реальный процесс выбирает тему+аудиторию+день, не
    просто перечисляет кандидатов."""
    r = run_artifactor("нужны темы для постов на неделю")
    result = json.loads(r.stdout)
    assert result["expected_result_kind"] == "ChoiceResult"


def test_strategy_has_a_title_for_wp_creation():
    """Стратегический запрос должен сразу дать название РП, а не пустую
    строку, из-за которой create-wp.sh не может быть вызван корректно."""
    r = run_artifactor("актуализируй стратегию")
    result = json.loads(r.stdout)
    assert result["task_type"] == "strategy"
    assert result["artifact"] == "Актуализированная стратегия"


def test_spec_writing_is_unresolved_not_method_description():
    """Живая находка Codex: запрещённая подмена ближайшим kind-ом — ни один из
    шести не покрывает описание поведения интерфейса (эталон WP-421)."""
    r = run_artifactor("сценарии тз для WP-281")
    result = json.loads(r.stdout)
    assert result["expected_result_kind"] is None
    assert result["result_kind_resolution"] == "unresolved"


def test_peer_session_is_deferred_not_static():
    """Мета-триггер — kind решается на Decision Gate внутри самой сессии, не в
    момент классификации запроса."""
    r = run_artifactor("начнём peer-сессия с codex")
    result = json.loads(r.stdout)
    assert result["expected_result_kind"] is None
    assert result["result_kind_resolution"] == "deferred-to-session"


def test_insufficient_input_unchanged():
    r = run_artifactor("коротко")
    assert r.returncode == 1
    assert r.stdout.strip() == "INSUFFICIENT_INPUT"


def test_no_keyword_match_unchanged():
    r = run_artifactor("текст без единого совпадения ключевых слов вообще никак")
    assert r.returncode == 2
    assert r.stdout.strip() == "NO_KEYWORD_MATCH"


def test_config_error_on_missing_registry():
    """Fail-closed (не тихий откат к schema 1) — тот же принцип, что в
    check-result-kind.py."""
    r = run_artifactor("открывай день", env_extra={"IWE_ROOT": "/tmp/nonexistent-iwe-root-test"})
    assert r.returncode == 3
    assert "CONFIG_ERROR" in r.stderr


def test_config_error_on_registry_drift(tmp_path):
    """KEYWORD_MAP ссылается на kind_id, которого нет в живом реестре —
    дрейф между хардкодом и SoT должен падать явно, не молча."""
    reg_dir = tmp_path / "PACK-digital-platform" / "pack" / "digital-platform"
    reg_dir.mkdir(parents=True)
    (reg_dir / "result-kinds-registry.yaml").write_text(
        "kinds:\n  - kind_id: SomethingElse\n    gate_ready: true\n", encoding="utf-8"
    )
    r = run_artifactor("открывай день", env_extra={"IWE_ROOT": str(tmp_path)})
    assert r.returncode == 3
    assert "дрейф" in r.stderr


def test_special_resolution_covers_exactly_the_none_kind_ids():
    """Инвариант модуля: kind_id=None в KEYWORD_MAP допустим ТОЛЬКО с записью
    в SPECIAL_RESOLUTION — иначе resolve_result_kind падает AssertionError
    (осознанный пропуск, не забытая карта)."""
    none_task_types = {tt for tt, _, kind_id, _ in af.KEYWORD_MAP.values() if kind_id is None}
    assert none_task_types == set(af.SPECIAL_RESOLUTION.keys())
