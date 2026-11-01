"""Tests for style-symbol-metric.py: turn grouping, item rule, buckets, JSON base."""

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("style-symbol-metric.py")
spec = importlib.util.spec_from_file_location("style_symbol_metric", SCRIPT)
metric = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metric)
rule = sys.modules["a13_1_symbols"]


def human(text, **extra):
    return {"type": "user", "message": {"content": [{"type": "text", "text": text}]}, **extra}


def assistant(text, ts="2026-10-30T10:00:00Z", **extra):
    msg = {"content": [{"type": "text", "text": text}]}
    msg.update(extra.pop("message", {}))
    return {"type": "assistant", "timestamp": ts, "message": msg, **extra}


def tool_result():
    return {"type": "user", "message": {"content": [{"type": "tool_result", "content": "ok"}]}}


def write_jsonl(path, rows):
    path.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")


class ItemRule(unittest.TestCase):
    def test_numbered_items_split_and_continuation_stays(self):
        text = "1. Первый `WLD_CTX`\n2. Токен WLD_CTX без глоссы.\n\n- вводим `WLD_CTX`\n\n  глосса: контекст"
        self.assertEqual(rule.split_items(text), [
            "1. Первый `WLD_CTX`", "2. Токен WLD_CTX без глоссы.", "- вводим `WLD_CTX`\n  глосса: контекст"])

    def test_list_then_blank_then_paragraph_at_zero_indent(self):
        self.assertEqual(rule.split_items("- a\n  продолжение\n\nабзац"), ["- a\n  продолжение", "абзац"])

    def test_nested_marker_is_its_own_item(self):
        self.assertEqual(rule.split_items("- a\n  - b"), ["- a", "- b"])

    def test_table_rows_are_items_header_and_separator_dropped(self):
        text = "| поле | смысл |\n|---|---|\n| `WLD_CTX` | |\n| a | b |"
        self.assertEqual(rule.split_items(text), ["| `WLD_CTX` | |", "| a | b |"])

    def test_table_without_outer_pipes(self):
        self.assertEqual(rule.split_items("a | b\n--- | ---\nx | y\nz | w"), ["x | y", "z | w"])

    def test_horizontal_rule_after_table_keeps_last_row(self):
        text = "| h |\n|---|\n| r1 |\n| r2 |\n\n---\n\nтекст"
        self.assertEqual(rule.split_items(text), ["| r1 |", "| r2 |", "текст"])

    def test_headings_fences_and_next_line_are_not_items(self):
        text = "## Итог\nСделал.\n\n```\ncode_paths = 1\n```\n\nДальше: вы: решить."
        self.assertEqual(rule.split_items(text), ["Сделал."])


class Measure(unittest.TestCase):
    def test_buckets_and_share(self):
        stats = dict.fromkeys(metric.COUNTERS, 0)
        metric.measure("Коммит `1a41c5f`, а `code_paths` сломан.\n\nСм. [PR](https://github.com/x/y/pull/1), "
                       "«цитата».\n\nВсё `ok`.", stats)
        self.assertEqual((stats["items"], stats["items_with_symbol"]), (3, 1))
        self.assertEqual((stats["bt_address"], stats["bt_symbol"], stats["bt_other"]), (1, 1, 1))
        self.assertEqual((stats["quotes"], stats["links"]), (1, 1))

    def test_totals_weigh_days_by_size(self):
        days = {"d1": {**dict.fromkeys(metric.COUNTERS, 0), "items": 1, "items_with_symbol": 1, "replies": 1},
                "d2": {**dict.fromkeys(metric.COUNTERS, 0), "items": 9, "replies": 1}}
        self.assertEqual(metric.totals(days)["symbol_item_share"], 0.1)


class Turns(unittest.TestCase):
    def test_non_human_records_do_not_split_a_turn(self):
        rows = [human("сделай"), assistant("Начинаю."), tool_result(), assistant("Готово, `code_paths` поправил."),
                human("<task-notification>x</task-notification>"), human("<system-reminder>y</system-reminder>"),
                human("<local-command-stdout>z</local-command-stdout>"), human("meta", isMeta=True),
                human("This session is being continued", isCompactSummary=True),
                human("subagent prompt", isSidechain=True), assistant("Итог."),
                human("спасибо"), assistant("Пожалуйста.")]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "s1.jsonl")
            write_jsonl(path, rows)
            self.assertEqual(list(metric.turns(str(path))), [
                ("2026-10-30", ["Начинаю.", "Готово, `code_paths` поправил.", "Итог."]),
                ("2026-10-30", ["Пожалуйста."])])

    def test_synthetic_errors_and_headless_runs_are_skipped(self):
        rows = [human("a"), assistant("Not logged in", message={"model": "<synthetic>"}),
                assistant("API Error", isApiErrorMessage=True), assistant("Ответ."),
                human("b", entrypoint="sdk-cli"), assistant("`code_paths`", entrypoint="sdk-cli")]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "s2.jsonl")
            write_jsonl(path, rows)
            seen = set()
            self.assertEqual(list(metric.turns(str(path), seen)), [("2026-10-30", ["Ответ."])])
            self.assertEqual(seen, {"sdk-cli"})

    def test_json_base_carries_rule_totals_and_exclusion(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_jsonl(Path(tmp, "keep.jsonl"), [human("a"), assistant("Начал."), human("b"),
                                                  assistant("Готово, `code_paths` поправил.")])
            write_jsonl(Path(tmp, "skip-me.jsonl"), [human("a"), assistant("`code_paths`")])
            out = Path(tmp, "base.json")
            with contextlib.redirect_stdout(io.StringIO()):
                metric.main(["--since", "2026-10-30", "--until", "2026-10-30", "--root", tmp,
                             "--exclude-session", "skip-me", "--json", str(out)])
            base = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual((base["rule"], base["day_tz"], base["transcripts"]), ("item-v2", "UTC", 1))
            self.assertEqual(base["totals"]["all_blocks"]["replies"], 2)
            self.assertEqual(base["totals"]["all_blocks"]["items_with_symbol"], 1)
            self.assertEqual(len(base["script_sha256"]), 12)

    def test_exclusion_matches_whole_session_id_only(self):
        paths = ["/x/abcd1234.jsonl", "/x/abcd1234-other.jsonl"]
        self.assertEqual(metric.kept_paths(paths, ["abcd1234"]), ["/x/abcd1234-other.jsonl"])

    def test_empty_exclusion_is_rejected(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            metric.main(["--since", "2026-10-30", "--until", "2026-10-30", "--exclude-session", ""])


if __name__ == "__main__":
    unittest.main()
