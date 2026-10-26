"""Unit tests for falsification_lint.py."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from falsification_lint import check_condition, check_verdict, main

VALID_BODY = """
### Условие опровержения
`publish_commit` вызывается без `IWE_AGENT` в окружении.

### Что проверено
Прочитан scripts/lib/publish-gate.sh строки 10-40.

### Несоответствия
| # | Severity |
"""


def test_condition_with_backtick_anchor_is_valid():
    assert (
        check_condition("FAIL, если `session_id` попадает в путь без проверки формата")
        == []
    )


def test_condition_with_path_and_line_is_valid():
    assert (
        check_condition(
            "FAIL, если в scripts/post-culture-fact.py строка 98 принимает только 200"
        )
        == []
    )


def test_condition_with_quoted_output_is_valid():
    assert (
        check_condition("FAIL, если вывод содержит «Traceback» при пустом --evidence")
        == []
    )


def test_vague_condition_without_anchor_is_rejected():
    problems = check_condition(
        "Вердикт FAIL, если найдены ошибки в коде проверяемого модуля"
    )
    assert len(problems) == 1
    assert "если найдены ошибки" in problems[0]


def test_vague_phrase_is_rejected_even_with_anchor():
    assert check_condition(
        "Если найдены ошибки в `build_envelope` при пустом account_id"
    ) == ["пустая формула без наблюдаемого: «если найдены ошибки»"]


def test_condition_without_any_anchor_is_rejected():
    problems = check_condition(
        "Проверка провалится, когда логика будет неправильной вообще"
    )
    assert len(problems) == 1
    assert "нет якоря" in problems[0]


def test_short_condition_is_rejected():
    assert check_condition("`x`") == ["условие короче 20 символов"]


def test_pass_verdict_with_sections_in_order_is_valid():
    assert check_verdict("## Verdict: PASS\n" + VALID_BODY) == []


def test_unknown_verdict_needs_missing_evidence_and_how_to_get():
    problems = check_verdict("## Verdict: UNKNOWN\n" + VALID_BODY)
    assert problems == [
        "UNKNOWN без непустой строки «Недостающее свидетельство:»",
        "UNKNOWN без непустой строки «Как получить:»",
    ]


def test_unknown_verdict_with_both_fields_is_valid():
    text = (
        "## Verdict: UNKNOWN\n"
        + VALID_BODY
        + "\n**Недостающее свидетельство:** поведение при таймауте gateway\n"
        + "**Как получить:** прогнать с IWE_EVENT_GATEWAY_URL на заглушку с задержкой 15с\n"
    )
    assert check_verdict(text) == []


def test_sections_out_of_order_are_rejected():
    text = "## Verdict: FAIL\n### Что проверено\nx\n### Условие опровержения\ny\n### Несоответствия\n"
    assert check_verdict(text) == [
        "«Условие опровержения» должно стоять до «Что проверено»"
    ]


def test_checked_after_mismatches_is_rejected():
    text = "## Verdict: CONDITIONAL\n### Условие опровержения\ny\n### Несоответствия\nz\n### Что проверено\nx\n"
    assert check_verdict(text) == ["«Что проверено» должно стоять до «Несоответствий»"]


def test_missing_sections_are_reported():
    assert check_verdict("## Verdict: PASS\n### Несоответствия\n") == [
        "нет раздела «Условие опровержения»",
        "нет раздела «Что проверено»",
    ]


def test_unknown_status_token_is_rejected():
    problems = check_verdict("## Verdict: MAYBE\n" + VALID_BODY)
    assert len(problems) == 1
    assert problems[0].startswith("недопустимый статус MAYBE")


def test_missing_verdict_line_is_rejected():
    assert check_verdict(VALID_BODY) == ["нет строки «## Verdict: <статус>»"]


def test_not_verifiable_needs_reason():
    assert check_verdict("## Verdict: NOT_VERIFIABLE\n") == [
        "NOT_VERIFIABLE без непустой строки «Причина:»"
    ]


def test_not_verifiable_with_reason_is_valid():
    text = "## Verdict: NOT_VERIFIABLE\n**Причина:** условие опровержения не сформулировано\n"
    assert check_verdict(text) == []


def test_cli_exit_codes(monkeypatch, capsys):
    import io

    monkeypatch.setattr(
        sys, "stdin", io.StringIO("если что-то не так с модулем вообще")
    )
    assert main(["condition"]) == 1
    assert capsys.readouterr().out.startswith("INVALID: пустая формула")

    monkeypatch.setattr(sys, "stdin", io.StringIO("## Verdict: PASS\n" + VALID_BODY))
    assert main(["verdict"]) == 0
    assert capsys.readouterr().out.strip() == "OK"


# --- cases found by the cold review (iteration 2) ---


def test_empty_field_followed_by_another_line_is_rejected():
    text = (
        "## Verdict: UNKNOWN\n"
        + VALID_BODY
        + "\n**Недостающее свидетельство:**\n**Как получить:** запустить smoke\n"
    )
    assert check_verdict(text) == [
        "UNKNOWN без непустой строки «Недостающее свидетельство:»"
    ]


def test_reason_prefix_word_does_not_count():
    text = "## Verdict: NOT_VERIFIABLE\nПричинами могут быть разные\n"
    assert check_verdict(text) == ["NOT_VERIFIABLE без непустой строки «Причина:»"]


def test_empty_reason_before_next_heading_is_rejected():
    text = "## Verdict: NOT_VERIFIABLE\nПричина:\n\n### Рекомендация\nповторить\n"
    assert check_verdict(text) == ["NOT_VERIFIABLE без непустой строки «Причина:»"]


def test_template_placeholder_is_not_a_value():
    text = (
        "## Verdict: UNKNOWN\n"
        + VALID_BODY
        + "\n**Недостающее свидетельство:** [что именно решило бы условие опровержения]\n"
        + "**Как получить:** запустить smoke\n"
    )
    assert check_verdict(text) == [
        "UNKNOWN без непустой строки «Недостающее свидетельство:»"
    ]


def test_common_verdict_line_variants_are_recognized():
    for line in (
        "## **Verdict:** PASS",
        "**Verdict: PASS**",
        "Verdict: PASS",
        "#### Verdict: PASS",
        "  ## Verdict: PASS",
        "## Verdict: [PASS]",
        "## Verdict: pass",
        "## Verdict: **PASS**",
    ):
        assert check_verdict(line + "\n" + VALID_BODY) == [], line


def test_bold_section_labels_are_recognized():
    text = (
        "## Verdict: PASS\n"
        "**Условие опровержения:**\n`x` пишет файл вне каталога.\n\n"
        "**Что проверено**\nПрочитан run.py строки 1-20.\n\n"
        "### Несоответствия\n"
    )
    assert check_verdict(text) == []


def test_empty_section_is_rejected():
    text = "## Verdict: PASS\n### Условие опровержения\n\n### Что проверено\nx\n"
    assert check_verdict(text) == ["пустой раздел «Условие опровержения»"]


def test_clock_time_is_not_an_anchor():
    problems = check_condition("Проверка провалится, если запуск в 10:30 утра")
    assert len(problems) == 1
    assert "нет якоря" in problems[0]


def test_file_colon_line_is_an_anchor():
    assert check_condition("FAIL, если Makefile:12 вызывает цель без зависимости") == []


def test_each_condition_line_needs_its_own_anchor():
    text = (
        "- FAIL, если `publish_commit` вызывается без `IWE_AGENT`\n"
        "- FAIL, если найдены ошибки в обработке\n"
    )
    problems = check_condition(text)
    assert problems == [
        "условие 2: пустая формула без наблюдаемого: «если найдены ошибки»"
    ]


def test_condition_must_match_input_verbatim():
    expected = "`publish_commit` вызывается без `IWE_AGENT` в окружении."
    assert check_verdict("## Verdict: PASS\n" + VALID_BODY, expected) == []
    problems = check_verdict(
        "## Verdict: PASS\n" + VALID_BODY, "`other` пишет мимо лога"
    )
    assert problems == [
        "«Условие опровержения» в ответе не совпадает с поданным на вход"
    ]


def test_cli_condition_file(tmp_path, monkeypatch, capsys):
    import io

    condition = tmp_path / "condition.txt"
    condition.write_text("`other` пишет мимо лога", encoding="utf-8")
    monkeypatch.setattr(sys, "stdin", io.StringIO("## Verdict: PASS\n" + VALID_BODY))
    assert main(["verdict", "--condition-file", str(condition)]) == 1
    assert "не совпадает" in capsys.readouterr().out


# --- cases found by the cold review (iteration 3) ---


def test_unfilled_verdict_template_is_rejected():
    for line in (
        "## Verdict: [PASS / CONDITIONAL / FAIL / UNKNOWN]",
        "## Verdict: PASS/FAIL",
        "## Verdict: Pass with remarks",
    ):
        assert check_verdict(line + "\n" + VALID_BODY) == [
            "нет строки «## Verdict: <статус>»"
        ], line


def test_subheadings_inside_checked_section_are_body():
    text = (
        "## Verdict: FAIL\n"
        "### Условие опровержения\n`run` пишет мимо лога.\n"
        "### Что проверено\n#### scripts/lib/x.sh\nстроки 1-20 прочитаны\n"
        "**scripts/lib/y.sh**\n- вызов `run` без лога\n"
        "### Несоответствия\n| 1 | критический |\n"
        "### Сводка\n- **Критических:** 1\n"
    )
    assert check_verdict(text) == []


def test_inline_numbered_and_suffixed_section_headings():
    text = (
        "## Verdict: PASS\n"
        "### 1. Условие опровержения (дословно)\n`run` пишет мимо лога.\n"
        "**Что проверено:** прочитан run.py целиком\n"
        "### Несоответствия\n"
    )
    assert check_verdict(text) == []


def test_condition_in_code_block_with_hash_line():
    text = (
        "## Verdict: PASS\n### Условие опровержения\n```\n# условие\n`run` пишет мимо лога\n```\n"
        "### Что проверено\nпрочитан run.py\n"
    )
    assert check_verdict(text, "`run` пишет мимо лога") == []


def test_dash_only_body_and_dash_field_are_empty():
    assert check_verdict(
        "## Verdict: PASS\n### Условие опровержения\n-\n### Что проверено\nx\n"
    ) == ["пустой раздел «Условие опровержения»"]
    text = (
        "## Verdict: UNKNOWN\n"
        + VALID_BODY
        + "\nНедостающее свидетельство: —\nКак получить: запуск\n"
    )
    assert check_verdict(text) == [
        "UNKNOWN без непустой строки «Недостающее свидетельство:»"
    ]


def test_quoted_verdict_in_code_block_is_ignored():
    text = "```\n## Verdict: PASS\n```\n## Verdict: UNKNOWN\n" + VALID_BODY
    assert check_verdict(text) == [
        "UNKNOWN без непустой строки «Недостающее свидетельство:»",
        "UNKNOWN без непустой строки «Как получить:»",
    ]


def test_two_different_verdict_lines_are_rejected():
    text = "## Verdict: PASS\n" + VALID_BODY + "\n## Verdict: FAIL\n"
    assert check_verdict(text) == [
        "несколько строк вердикта с разными статусами: FAIL, PASS"
    ]


def test_verdict_must_match_summary():
    body = VALID_BODY + "\n### Сводка\n- **Критических:** 3\n- **Высоких:** 0\n"
    assert check_verdict("## Verdict: PASS\n" + body) == [
        "PASS при критических несоответствиях (3) — должен быть FAIL"
    ]
    assert check_verdict("## Verdict: FAIL\n" + body) == []
    no_high = VALID_BODY + "\n### Сводка\n- **Критических:** 0\n- **Высоких:** 0\n"
    assert check_verdict("## Verdict: CONDITIONAL\n" + no_high) == [
        "CONDITIONAL без высоких несоответствий"
    ]


def test_list_markers_do_not_break_condition_match():
    expected = "- FAIL, если `a` пуст\n- FAIL, если `b` пишет мимо лога\n"
    answer = (
        "## Verdict: PASS\n### Условие опровержения\n1. FAIL, если `a` пуст\n"
        "> FAIL, если `b` пишет мимо лога\n### Что проверено\nx\n"
    )
    assert check_verdict(answer, expected) == []


def test_vague_phrase_with_only_quotes_is_rejected():
    assert check_condition("FAIL, если что-то не так в «коде» модуля") == [
        "пустая формула без наблюдаемого: «если что-то не так»"
    ]


def test_semicolon_joined_conditions_are_checked_separately():
    problems = check_condition(
        "FAIL, если `session_id` пуст в run.py; FAIL, если что-то не так с отчётом"
    )
    assert problems == [
        "условие 2: пустая формула без наблюдаемого: «если что-то не так»"
    ]


def test_answer_with_delimiter_line_is_plain_data():
    text = "## Verdict: PASS\n" + VALID_BODY + "\nIWE_FALSIFICATION_EOF\n$(echo x)\n"
    assert check_verdict(text) == []


# --- cases found by the cold review (iteration 4) ---


def test_natural_verdict_variants_are_recognized():
    for line in (
        "## Verdict: PASS ✅",
        "## Verdict: PASS.",
        "## Verdict: `PASS`",
        "## Verdict: PASS — условие не сработало",
        "## Verdict: PASS (условие не сработало)",
        "## Вердикт: PASS",
        "## ✅ Verdict: PASS",
        "| Verdict | PASS |",
    ):
        assert check_verdict(line + "\n" + VALID_BODY) == [], line


def test_subheading_named_like_a_section_stays_in_body():
    text = (
        "## Verdict: PASS\n### Условие опровержения\n`run` пишет мимо лога.\n"
        "### Что проверено\n#### Сводка по файлам\nrun.py строки 1-9\n"
        "**Условие опровержения** не сработало: run.py:5 ок\n### Несоответствия\n"
    )
    assert check_verdict(text) == []


def test_summary_in_table_or_other_layout_is_seen():
    for summary in (
        "| Критических | 1 |",
        "Критические: 1",
        "Критических: 1, Высоких: 0",
    ):
        text = "## Verdict: PASS\n" + VALID_BODY + "\n### Сводка\n" + summary + "\n"
        assert check_verdict(text) == [
            "PASS при критических несоответствиях (1) — должен быть FAIL"
        ], summary
    one_line = "## Verdict: PASS\n" + VALID_BODY + "\nКритических: 0, Высоких: 2\n"
    assert check_verdict(one_line) == ["PASS при высоких несоответствиях (2)"]


def test_critical_row_in_findings_overrides_zero_summary():
    text = (
        "## Verdict: PASS\n### Условие опровержения\n`run` пишет мимо лога.\n"
        "### Что проверено\nrun.py\n### Несоответствия\n"
        "| 1 | критический | run.py | 5 | пишет мимо лога |\n"
        "### Сводка\n- **Критических:** 0\n"
    )
    assert check_verdict(text) == [
        "PASS при критических несоответствиях (1) — должен быть FAIL"
    ]


def test_fail_is_never_downgraded_by_summary():
    text = "## Verdict: FAIL\n" + VALID_BODY + "\n### Сводка\n- **Критических:** 0\n"
    assert check_verdict(text) == []


def test_backticked_generic_word_and_any_file_are_vague():
    assert check_condition("FAIL, если найдены ошибки в `коде` модуля") == [
        "пустая формула без наблюдаемого: «если найдены ошибки»"
    ]
    assert check_condition("FAIL, если ломается логика в любом файле x.py") == [
        "пустая формула без наблюдаемого: «в любом файле»"
    ]


def test_continuation_inherits_line_anchor_but_independent_fail_does_not():
    for text in (
        "FAIL, если `session_id` пуст в run.py; и если `foo` пуст",
        "FAIL, если `foo()` падает, а также если возвращает None при пустом входе",
    ):
        assert check_condition(text) == [], text
    problems = check_condition(
        "FAIL, если `session_id` пуст в run.py; FAIL, если отчёт без даты вообще"
    )
    assert len(problems) == 1
    assert problems[0].startswith("условие 2: нет якоря")


def test_continuation_is_still_checked_for_vague_phrases():
    problems = check_condition(
        "FAIL, если `session_id` пуст в run.py; и если что-то не так с отчётом"
    )
    assert problems == [
        "условие 2: пустая формула без наблюдаемого: «если что-то не так»"
    ]


# --- cases found by the final review (iteration 5) ---


def test_findings_row_without_summary_does_not_crash():
    text = (
        "## Verdict: CONDITIONAL\n### Условие опровержения\n`run` пишет мимо лога.\n"
        "### Что проверено\nrun.py\n### Несоответствия\n| 1 | высокий | run.py | 5 | x |\n"
    )
    assert check_verdict(text) == []


def test_summary_table_is_not_a_findings_row():
    text = (
        "## Verdict: PASS\n" + VALID_BODY + "\n### Сводка\n"
        "| Уровень | Число |\n| Критических | 0 |\n| Высоких | 0 |\n"
    )
    assert check_verdict(text) == []


def test_soft_vague_words_pass_with_a_strong_anchor():
    for text in (
        "FAIL, если `parse_args()` возвращает что-то кроме Namespace",
        "FAIL, если в scripts/x.sh есть какие-либо вызовы `git add -A`",
        "FAIL, если `x` содержит «что-либо» из списка",
    ):
        assert check_condition(text) == [], text
    assert check_condition("FAIL, если модуль возвращает что-то лишнее вообще") == [
        "размытое «что-то» без точного якоря (код, путь, строка, файл:N)"
    ]


def test_english_and_worded_severity_are_counted():
    english = "## Verdict: PASS\n" + VALID_BODY + "| 1 | Critical | run.py | 5 | x |\n"
    assert check_verdict(english) == [
        "PASS при критических несоответствиях (1) — должен быть FAIL"
    ]
    for summary in ("Критических находок: 1", "Критических — 1"):
        text = "## Verdict: PASS\n" + VALID_BODY + "\n" + summary + "\n"
        assert check_verdict(text) == [
            "PASS при критических несоответствиях (1) — должен быть FAIL"
        ], summary


def test_emoji_after_colon_is_accepted():
    assert check_verdict("## Verdict: ✅ PASS\n" + VALID_BODY) == []


# --- WP-595 Ф16: условия опровержения для rubric/ontological/pack режимов ---

ONTOLOGICAL_CONDITION = (
    "FAIL, если specificity-скор PACK-personal/pack/personal-development "
    "по шкале verify-ontological-adequacy.md ниже 40%"
)

ONTOLOGICAL_ANSWER = """
### Условие опровержения
FAIL, если specificity-скор PACK-personal/pack/personal-development по шкале verify-ontological-adequacy.md ниже 40%

### Что проверено
Прочитан 00-pack-manifest.md и 01B-distinctions.md, разобрано 14 claim'ов.

### Несоответствия
| # | Severity |
"""


def test_new_style_condition_with_anchor_path_passes_condition_lint():
    assert check_condition(ONTOLOGICAL_CONDITION) == []


def test_assembled_verdict_with_verbatim_condition_passes_verdict_lint(tmp_path):
    import io

    condition_file = tmp_path / "check.condition.txt"
    condition_file.write_text(ONTOLOGICAL_CONDITION, encoding="utf-8")
    monkeypatch_stdin = io.StringIO("## Verdict: PASS\n" + ONTOLOGICAL_ANSWER)
    old_stdin = sys.stdin
    try:
        sys.stdin = monkeypatch_stdin
        assert main(["verdict", "--condition-file", str(condition_file)]) == 0
    finally:
        sys.stdin = old_stdin


def test_unknown_without_evidence_lines_is_rejected_new_modes():
    text = "## Verdict: UNKNOWN\n" + ONTOLOGICAL_ANSWER
    problems = check_verdict(text)
    assert problems == [
        "UNKNOWN без непустой строки «Недостающее свидетельство:»",
        "UNKNOWN без непустой строки «Как получить:»",
    ]


def test_broken_section_order_is_rejected_new_modes():
    text = (
        "## Verdict: CONDITIONAL\n### Что проверено\nПрочитан 00-pack-manifest.md\n"
        "### Условие опровержения\n" + ONTOLOGICAL_CONDITION + "\n### Несоответствия\n"
        "| 1 | высокий | 00-pack-manifest.md | 5 | x |\n"
    )
    assert check_verdict(text) == [
        "«Условие опровержения» должно стоять до «Что проверено»"
    ]
