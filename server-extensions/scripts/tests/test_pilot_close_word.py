"""Tests for scripts/lib/pilot_close_word.py (WP-561, 18.11.2026 incident)."""
import importlib.util
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "pilot_close_word", Path(__file__).resolve().parents[1] / "lib" / "pilot_close_word.py"
)
mod = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(mod)


def test_accepts_explicit_closing_words():
    for phrase in ("закрывай", "Заливай и закрывай", "всё", "Всё.", "Всё, спасибо", "все", "ПСЗ", "давай закроем", "закрывай, потом ещё раз проверь"):
        ok, reason = mod.check(phrase)
        assert ok, f"{phrase!r} must be accepted, got: {reason}"


def test_refuses_scope_choice_and_approval():
    # The 18.11 incident: choice of a work variant is not a closing word.
    for phrase in ("Только записать", "согласен, делай", "Б", "ждем 30.11, остальное согласен и делай"):
        ok, _ = mod.check(phrase)
        assert not ok, f"{phrase!r} must be refused"


def test_refuses_copied_option_label_even_with_closing_word():
    label = "А. Только записать → отчёт, закрыть сессию"
    ok, reason = mod.check(label)
    assert not ok and "подпись варианта" in reason


def test_refuses_empty_and_long_text():
    assert not mod.check("")[0]
    assert not mod.check("   ")[0]
    assert not mod.check("закрывай " + "x" * 200)[0]


def test_refuses_negation_question_and_push_only():
    for phrase in ("не закрывай", "пока не закрывай", "НЕ закрывай пока", "не закрыть", "сз не нужно", "всё?", "заливай"):
        ok, _ = mod.check(phrase)
        assert not ok, f"{phrase!r} must be refused"
