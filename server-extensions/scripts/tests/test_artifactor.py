#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tests for artifactor.py schema_version 4 (WP-575 Ф2, Ф4).

Ранее (WP-421) существовал только ручной прогон 23 фраз, не сохранённый как
pytest — первое персистентное покрытие для этого файла (05.08.2026, консенсус
пир-сессии 2026-08-05-14-codex-wp481-f7-impl).
"""

import json
import os
import re
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
def test_every_keyword_produces_valid_schema_v4(kw, expected):
    """Каждая из всех записей KEYWORD_MAP классифицируется без падения и
    возвращает согласованную форму (schema_version 4, WP-575 Ф2/Ф4)."""
    task_type, cls, kind_id, artifact, result_type = expected
    r = run_artifactor(kw)
    assert r.returncode == 0, r.stderr
    result = json.loads(r.stdout)
    assert result["task_type"] == task_type
    assert result["class"] == cls
    assert result["schema_version"] == 4
    assert result["pair_link"] == {"status": "agent_check_required", "producer": None, "output": None}
    assert result["confidence"] == "high"
    assert result["resolution_path"] == "keyword"
    assert result["artifact"] == artifact
    assert result["artifact"]
    assert result["result_type"] == result_type
    assert result["hypothesis_relation"] == "unclassified"
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
    assert result["artifact"] == "Документ стратегии"


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
    r = run_artifactor("начнём пир-сессию с codex")
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
    none_task_types = {tt for tt, _, kind_id, _, _ in af.KEYWORD_MAP.values() if kind_id is None}
    assert none_task_types == set(af.SPECIAL_RESOLUTION.keys())


def test_pair_statuses_have_no_duplicates():
    """Перечень статусов связки «документ ↔ производитель» (WP-575 Ф4) без повторов."""
    assert len(af.VALID_PAIR_STATUSES) == len(set(af.VALID_PAIR_STATUSES))
    assert af.KEYWORD_PAIR_LINK["status"] in af.VALID_PAIR_STATUSES


def test_skill_pair_status_list_matches_code_constant():
    """Строка схемы pair_link в SKILL.md артефактора перечисляет ровно те же
    статусы, что константа в скрипте: рассинхрон описания и кода падает здесь."""
    skill = os.path.join(os.path.dirname(SCRIPTS), ".claude", "skills", "artifactor", "SKILL.md")
    with open(skill, encoding="utf-8") as f:
        text = f.read()
    match = re.search(r'"pair_link": \{"status": "([^"]+)"', text)
    assert match, "в SKILL.md нет строки схемы pair_link с перечнем статусов"
    listed = [s.strip() for s in match.group(1).split("|")]
    assert listed == list(af.VALID_PAIR_STATUSES)


MINI_REGISTRY = """\
schema_version: 1
kinds:
  - {id: system, name: система, test: "t", part_relation: "p"}
  - {id: document, name: документ, test: "t", part_relation: "p"}
  - {id: description, name: описание, test: "t", part_relation: "p"}
  - {id: ambiguous, name: неоднозначно, test: "t", part_relation: "p"}
terms:
  - {term: платформа, kind: system, stems: ["платформ"], basis: "b", status: pilot}
  - {term: описание, kind: description, stems: ["описани"], basis: "b", status: pilot}
  - {term: реестр, kind: document, stems: ["реестр"], basis: "b", status: pilot}
  - {term: хранилище, kind: ambiguous, stems: ["хранилищ"], basis: "b", status: pilot}
"""


def check_registry_cli(tmp_path, artifact, result_type, registry=MINI_REGISTRY, extra=()):
    """Запускает --check-registry на временном реестре; возвращает (код, вывод)."""
    reg = tmp_path / "registry.yaml"
    if registry is not None:
        reg.write_text(registry, encoding="utf-8")
    res = tmp_path / "result.json"
    res.write_text(json.dumps({"artifact": artifact, "result_type": result_type}), encoding="utf-8")
    env = dict(os.environ, CONCEPT_KINDS_REGISTRY=str(reg), CONCEPT_KIND_LOG=str(tmp_path / "ck.log"))
    r = subprocess.run(
        [sys.executable, ARTIFACTOR, "--check-registry", str(res), *extra],
        capture_output=True, text=True, env=env, check=False,
    )
    return r.returncode, r.stdout.strip()


@pytest.mark.parametrize(
    "artifact,result_type,code,fragment",
    [
        ("Платформа обучения", "system", 0, "REGISTRY_OK registry платформа/system"),
        ("Реестр опросов программ МИМ и IWE", "episteme", 0, "REGISTRY_OK registry реестр/document"),
        ("Система «Аналитик чата»", "system", 0, "REGISTRY_OK registry система/system"),
        ("Реестр опросов", "system", 4, "род «document»"),
        ("Платформа обучения", "episteme", 4, "род «system»"),
        ("Аналитик чата", "system", 4, "нет в реестре"),
        ("Хранилище материалов", "episteme", 4, "неоднозначно"),
        ("Реестр и журнал событий", "episteme", 4, "составная голова"),
        ("Реестр", "unresolved", 4, "не определён"),
    ],
)
def test_check_registry_outcomes(tmp_path, artifact, result_type, code, fragment):
    rc, out = check_registry_cli(tmp_path, artifact, result_type)
    assert rc == code, out
    assert fragment in out


def test_check_registry_blocks_when_registry_unreadable(tmp_path):
    """Реестра нет → fail-closed: блок, а не тихий пропуск."""
    rc, out = check_registry_cli(tmp_path, "Платформа обучения", "system", registry=None)
    assert rc == 4
    assert out.startswith("REGISTRY_BLOCK")


def test_create_wp_defines_escape_before_registry_gate():
    """Registry Gate зовёт yaml_dq_escape — функция обязана быть определена выше
    по файлу (bash не поднимает определения, иначе «command not found» в блоке)."""
    path = os.path.join(SCRIPTS, "create-wp.sh")
    with open(path, encoding="utf-8") as f:
        text = f.read()
    assert 0 <= text.index("yaml_dq_escape() {") < text.index("# --- Registry Gate")


@pytest.mark.parametrize(
    "artifact,result_type,extra,code,fragment",
    [
        # Слова нет, ИИ уверен и ответил на проверочный вопрос → пропуск с записью источника.
        ("Шаблон договора", "episteme", ("--ai-kind", "document", "--ai-answer", "файл-носитель описания"),
         0, "REGISTRY_OK ai шаблон/document: файл-носитель описания"),
        # Слова нет, ИИ не уверен («Библиотека» — здание или набор документов) → нужен пилот.
        ("Библиотека методов", "episteme",
         ("--ai-kind", "document", "--ai-answer", "набор документов", "--ai-unsure"),
         5, "REGISTRY_ASK"),
        # То же с решением пилота → пропуск, источник «pilot».
        ("Библиотека методов", "episteme",
         ("--ai-kind", "document", "--ai-answer", "набор документов", "--ai-unsure",
          "--pilot-decision", "документ, не здание"),
         0, "REGISTRY_OK pilot библиотека/document: документ, не здание"),
        # Неоднозначное в реестре слово всегда уходит пилоту, даже при «уверенном» ИИ.
        ("Хранилище материалов", "episteme", ("--ai-kind", "document", "--ai-answer", "набор файлов"),
         5, "REGISTRY_ASK"),
        # Род ИИ не подходит типу результата → блок, пилот не спрашивается.
        ("Шаблон договора", "system", ("--ai-kind", "document", "--ai-answer", "файл"),
         4, "результат — system"),
        # Выдуманный род → блок.
        ("Шаблон договора", "episteme", ("--ai-kind", "волшебство", "--ai-answer", "x"),
         4, "не из реестра"),
        # Пустой ответ на вопрос → блок.
        ("Шаблон договора", "episteme", ("--ai-kind", "document", "--ai-answer", "  "),
         4, "нет ответа на проверочный вопрос"),
        # Реестр знает слово, род противоречит: ответ ИИ и решение пилота не перебивают.
        ("Реестр опросов", "system",
         ("--ai-kind", "system", "--ai-answer", "x", "--pilot-decision", "пусть будет"),
         4, "род «document»"),
        # Составная голова разбирается ИИ вместе с пилотом, не молча.
        ("Реестр и журнал событий", "episteme",
         ("--ai-kind", "document", "--ai-answer", "два носителя"), 5, "REGISTRY_ASK"),
    ],
)
def test_check_registry_ai_and_pilot_levels(tmp_path, artifact, result_type, extra, code, fragment):
    rc, out = check_registry_cli(tmp_path, artifact, result_type, extra=extra)
    assert rc == code, out
    assert fragment in out


@pytest.mark.parametrize(
    "result_type,extra,expect_advice",
    [
        ("episteme", (), True),                              # документ без названного производителя → подсказка
        ("episteme", ("--producer", "session"), False),      # производитель назван → тихо
        ("episteme", ("--producer", "  "), True),            # пустой производитель = не назван
        ("system", (), False),                               # система — не документ
        ("unresolved", (), False),
    ],
)
def test_producer_advice_only_for_documents_without_producer(tmp_path, result_type, extra, expect_advice):
    """Подсказка «документ создаёт система» не блокирует (код 0) и не шумит там,
    где производитель назван или результат — не документ (WP-575 Ф5)."""
    res = tmp_path / "result.json"
    res.write_text(json.dumps({"artifact": "Шаблон IWE", "result_type": result_type}), encoding="utf-8")
    r = subprocess.run(
        [sys.executable, ARTIFACTOR, "--advice", str(res), *extra],
        capture_output=True, text=True, check=False,
    )
    assert r.returncode == 0
    assert ("создаёт система" in r.stdout) is expect_advice


# --- Поведение замка в create-wp.sh (WP-575 Ф5): запуск во временном рабочем месте ---

CREATE_WP = os.path.join(SCRIPTS, "create-wp.sh")


@pytest.fixture
def workspace(tmp_path):
    """Временное рабочее место: репо управления с реестром РП и мини-реестр понятий."""
    gov = tmp_path / "gov"
    for sub in ("docs", "inbox", "current", "archive/wp-contexts"):
        (gov / sub).mkdir(parents=True)
    (gov / "docs" / "WP-REGISTRY.md").write_text(
        "| # | P | Название | Статус | Репо | Ставка | Бюджет | Прогресс |\n"
        "|---|---|----------|--------|------|--------|--------|----------|\n"
        "| 1 | P3 | **Стартовый РП** | 🔄 | x | — | 1h | — |\n",
        encoding="utf-8",
    )
    (tmp_path / "registry.yaml").write_text(MINI_REGISTRY, encoding="utf-8")
    return tmp_path


def run_create_wp(ws, artifact, result_type, *flags, log=None):
    result = ws / "result.json"
    result.write_text(
        json.dumps({"artifact": artifact, "result_type": result_type, "resolution_path": "llm"}),
        encoding="utf-8",
    )
    env = dict(
        os.environ,
        IWE_ROOT=str(ws),
        IWE_GOVERNANCE_REPO="gov",
        CONCEPT_KINDS_REGISTRY=str(ws / "registry.yaml"),
        CONCEPT_KIND_LOG=log or str(ws / "ck.log"),
    )
    return subprocess.run(
        ["bash", CREATE_WP, "--artifactor-result", str(result), "--budget", "1h",
         "--priority", "P3", "--no-consent-check", *flags],
        capture_output=True, text=True, env=env, check=False,
    )


def created_cards(ws):
    return sorted((ws / "gov" / "inbox").glob("WP-*/WP-*.md"))


def test_gate_blocks_unknown_word_without_ai_answer_and_creates_nothing(workspace):
    r = run_create_wp(workspace, "Шаблон IWE", "episteme")
    assert r.returncode != 0
    assert "Registry Gate" in r.stderr
    assert created_cards(workspace) == []


def test_gate_asks_pilot_when_ai_is_unsure_and_creates_nothing(workspace):
    r = run_create_wp(workspace, "Библиотека методов", "episteme",
                      "--name-kind", "document", "--name-kind-answer", "набор документов", "--name-kind-unsure")
    assert r.returncode != 0
    assert "решение пилота" in r.stderr
    assert created_cards(workspace) == []


def test_gate_records_ai_decision_and_missing_producer_in_card(workspace):
    r = run_create_wp(workspace, "Шаблон IWE", "episteme",
                      "--name-kind", "document", "--name-kind-answer", "файл-носитель")
    assert r.returncode == 0, r.stderr
    card = created_cards(workspace)[0].read_text(encoding="utf-8")
    assert 'registry_check: "ai"' in card
    assert 'producer: "не указан"' in card
    assert "создаёт система" in r.stderr  # рекомендательная подсказка не блокирует


def test_gate_records_named_producer_and_silences_advice(workspace):
    r = run_create_wp(workspace, "Шаблон IWE", "episteme",
                      "--name-kind", "document", "--name-kind-answer", "файл", "--producer", "session")
    assert r.returncode == 0, r.stderr
    assert 'producer: "session"' in created_cards(workspace)[0].read_text(encoding="utf-8")
    assert "создаёт система" not in r.stderr


def test_gate_pilot_decision_resolves_unsure_word(workspace):
    r = run_create_wp(workspace, "Библиотека методов", "episteme",
                      "--name-kind", "document", "--name-kind-answer", "набор документов",
                      "--name-kind-unsure", "--name-kind-pilot", "документ, не здание")
    assert r.returncode == 0, r.stderr
    assert 'registry_check: "pilot"' in created_cards(workspace)[0].read_text(encoding="utf-8")


def test_gate_registry_conflict_blocks_and_waiver_with_reason_passes(workspace):
    blocked = run_create_wp(workspace, "Реестр опросов", "system",
                            "--name-kind", "system", "--name-kind-answer", "x")
    assert blocked.returncode != 0 and created_cards(workspace) == []
    waived = run_create_wp(workspace, "Реестр опросов", "system", "--registry-waiver", "решение пилота: это сервис")
    assert waived.returncode == 0, waived.stderr
    card = created_cards(workspace)[0].read_text(encoding="utf-8")
    assert 'registry_check: "waived"' in card
    assert "registry_waiver_reason: \"решение пилота: это сервис\"" in card


def test_gate_empty_waiver_does_not_bypass(workspace):
    r = run_create_wp(workspace, "Реестр опросов", "system", "--registry-waiver", "  ")
    assert r.returncode != 0 and created_cards(workspace) == []


def test_gate_leading_adjective_judged_by_ai_kind_not_refused_outright(workspace):
    """«Новый реестр опросов» как система: ИИ, назвавший предмет документом, не проходит;
    ИИ, назвавший систему, проходит с предупреждением (жёсткого отказа за прилагательное нет)."""
    blocked = run_create_wp(workspace, "Новый реестр опросов", "system",
                            "--name-kind", "document", "--name-kind-answer", "реестр — документ")
    assert blocked.returncode != 0 and created_cards(workspace) == []
    passed = run_create_wp(workspace, "Новый реестр опросов", "system",
                           "--name-kind", "system", "--name-kind-answer", "сервис опросов")
    assert passed.returncode == 0, passed.stderr
    assert "начинается не с существительного" in passed.stderr  # предупреждение пилоту


def test_gate_log_warning_does_not_corrupt_source_marker(workspace):
    """Нечитаемый журнал даёт предупреждение в stderr; источник проверки в карточке не страдает."""
    r = run_create_wp(workspace, "Реестр опросов", "episteme", log="/dev/null/ck.log")
    assert r.returncode == 0, r.stderr
    assert 'registry_check: "registry"' in created_cards(workspace)[0].read_text(encoding="utf-8")


@pytest.mark.parametrize("registry", ["", "just: a string\n", "kinds: [", "kinds: []\n"])
def test_check_registry_broken_registry_fails_closed_without_traceback(tmp_path, registry):
    rc, out = check_registry_cli(tmp_path, "Платформа обучения", "system", registry=registry)
    assert rc == 4
    assert out.startswith("REGISTRY_BLOCK")
    assert "Traceback" not in out


def test_unwritable_log_really_warns_on_stderr_but_stdout_stays_clean(tmp_path):
    """Страхует тест выше: предупреждение о журнале действительно идёт в stderr,
    а ответ проверки в stdout остаётся одной чистой строкой."""
    res = tmp_path / "result.json"
    res.write_text(json.dumps({"artifact": "Реестр опросов", "result_type": "episteme"}), encoding="utf-8")
    reg = tmp_path / "registry.yaml"
    reg.write_text(MINI_REGISTRY, encoding="utf-8")
    env = dict(os.environ, CONCEPT_KINDS_REGISTRY=str(reg), CONCEPT_KIND_LOG="/dev/null/ck.log")
    r = subprocess.run([sys.executable, ARTIFACTOR, "--check-registry", str(res)],
                       capture_output=True, text=True, env=env, check=False)
    assert r.returncode == 0
    assert "журнал не записан" in r.stderr
    assert r.stdout.strip().startswith("REGISTRY_OK registry")
    assert "\n" not in r.stdout.strip()


def test_internal_check_error_is_closed_refusal_and_distinguishable(tmp_path, monkeypatch):
    """Ошибка самой проверки после успешной загрузки реестра — отказ (4), но с отдельным текстом."""
    reg = tmp_path / "registry.yaml"
    reg.write_text(MINI_REGISTRY, encoding="utf-8")
    monkeypatch.setenv("CONCEPT_KINDS_REGISTRY", str(reg))
    monkeypatch.setenv("CONCEPT_KIND_LOG", str(tmp_path / "ck.log"))

    def boom(*_args, **_kwargs):
        raise TypeError("синтетический сбой")

    monkeypatch.setattr(af, "registry_verdict", boom)
    code, text = af.check_registry({"artifact": "Платформа", "result_type": "system"})
    assert code == 4
    assert "внутренняя ошибка проверки" in text and "TypeError" in text


@pytest.mark.parametrize(
    "artifact",
    ["Реестр, журнал событий", "Платформа «Аналитик»", "Реестр: система опросов"],
)
def test_punctuation_after_known_head_does_not_change_verdict(tmp_path, artifact):
    kind = "episteme" if artifact.startswith("Реестр") else "system"
    rc, out = check_registry_cli(tmp_path, artifact, kind)
    assert rc == 0, out
    assert out.startswith("REGISTRY_OK registry")


INTRODUCTORY_TITLES = [
    "Системный журнал", "Серверный реестр", "Файловая система", "Рабочая платформа обучения",
    "Нового реестр", "Первого реестр", "Наш реестр", "Два реестра", "10 реестров", "1-й реестр",
    "Для реестра", "Не реестр", "Мини реестр", "Супер платформа", "(Новый) реестр",
]


@pytest.mark.parametrize("artifact", INTRODUCTORY_TITLES)
def test_title_starting_with_modifier_is_not_a_hard_refusal(tmp_path, artifact):
    """Решение пилота: жёсткого отказа за начало не с существительного нет. Без ответа ИИ
    название не проходит (нужен ответ о предмете), с ответом проходит с предупреждением."""
    bare_rc, bare_out = check_registry_cli(tmp_path, artifact, "episteme")
    assert bare_rc == 4 and "начинается не с существительного" in bare_out
    rc, out = check_registry_cli(
        tmp_path, artifact, "episteme", extra=("--ai-kind", "document", "--ai-answer", "предмет — журнал"),
    )
    assert rc == 0, out
    assert out.startswith("REGISTRY_OK ai ") and " ⚠ название начинается не с существительного" in out


def test_title_starting_with_modifier_still_checks_the_ai_kind_against_result_type(tmp_path):
    """Предупреждение не открывает замок: ИИ, назвавший род предмета, должен подойти типу результата."""
    rc, out = check_registry_cli(
        tmp_path, "Системный журнал", "system", extra=("--ai-kind", "document", "--ai-answer", "журнал"),
    )
    assert rc == 4 and "результат — system" in out


@pytest.mark.parametrize("artifact", ["Реестр и журнал событий", "Реестр или журнал", "Платформа и реестр"])
def test_coordination_after_the_head_goes_to_pilot(tmp_path, artifact):
    """Составное название разбирает пилот: формальный ответ ИИ замок не открывает."""
    kind = "system" if artifact.startswith("Платформа") else "document"
    result_type = "system" if kind == "system" else "episteme"
    rc, out = check_registry_cli(tmp_path, artifact, result_type,
                                 extra=("--ai-kind", kind, "--ai-answer", "x"))
    assert rc == 5, out
    assert "REGISTRY_ASK" in out and "составная голова" in out


@pytest.mark.parametrize("artifact", ["«Реестр» опросов", "Реестр, большой и новый", "Реестр: система опросов"])
def test_known_head_with_punctuation_still_conflicts_for_a_system(tmp_path, artifact):
    rc, out = check_registry_cli(
        tmp_path, artifact, "system",
        extra=("--ai-kind", "system", "--ai-answer", "x", "--pilot-decision", "пусть будет"),
    )
    assert rc == 4, out
    assert "род «document»" in out


@pytest.mark.parametrize("artifact", ["Описание сервиса", "Описание", "Описания протоколов"])
def test_noun_that_looks_like_adjective_is_judged_by_registry_first(tmp_path, artifact):
    """«Описание» оканчивается на «-ие», но реестр знает его род: система с таким названием
    отказывает жёстко, ответ ИИ и решение пилота не помогают."""
    rc, out = check_registry_cli(
        tmp_path, artifact, "system",
        extra=("--ai-kind", "system", "--ai-answer", "x", "--pilot-decision", "пусть будет"),
    )
    assert rc == 4, out
    assert "род «description»" in out
    rc, out = check_registry_cli(tmp_path, artifact, "episteme")
    assert rc == 0 and "REGISTRY_OK registry описание/description" in out


def test_registry_stem_far_from_an_adjective_like_word_is_not_trusted(tmp_path):
    """«Платформенный» только начинается как слово реестра «платформа»: реестр ему не верит,
    название идёт в мягкий путь (нужен ответ ИИ) и получает предупреждение."""
    rc, out = check_registry_cli(tmp_path, "Платформенный журнал", "episteme")
    assert rc == 4 and "начинается не с существительного" in out
    rc, out = check_registry_cli(tmp_path, "Платформенный журнал", "episteme",
                                 extra=("--ai-kind", "document", "--ai-answer", "журнал"))
    assert rc == 0 and out.startswith("REGISTRY_OK ai") and " ⚠ " in out


@pytest.mark.parametrize(
    "stems,word,expected",
    [
        (["описани"], "описание", 1),          # падежное окончание: доверяем (порог ≤ 2)
        (["описани"], "описания", 1),
        (["описани"], "описаниями", 3),        # дальше порога
        (["платформ"], "платформенный", 5),    # суффикс прилагательного: далеко
        (["платформ"], "платформа", 1),
        ([], "любое", 5),                      # нет основ — остаток равен длине слова
        (["неподходящая"], "описание", 8),     # основа не совпала — остаток равен длине слова
    ],
)
def test_stem_remainder_boundaries(stems, word, expected):
    assert af.stem_remainder({"stems": stems}, word) == expected


@pytest.mark.parametrize(
    "word,found",
    [
        ("описание", True),       # остаток 1
        ("описания", True),       # остаток 1
        ("описаниями", False),    # остаток 3: слишком далеко
        ("описательный", False),  # другое слово с той же основой
        ("системный", False),
    ],
)
def test_close_kind_by_name_boundaries(word, found):
    data = {"kinds": [
        {"id": "ambiguous", "name": "неоднозначно"},
        {"id": "description", "name": "описание"},
        {"id": "system", "name": "система"},
    ]}
    kind = af.close_kind_by_name(data, word)
    assert (kind is not None) is found
    if found:
        assert kind["id"] == "description"
