"""Behavioral counterexamples for the WP-603 evidence classifier."""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from promise_audit import apply_reviews, audit, classify, direct_peer_command


def turn(text="Сейчас вызываю Codex", tools=None):
    return {
        "id": "1",
        "complete": True,
        "end_line": 10,
        "final_text": text,
        "final_line": 2,
        "text_segments": [{"text": text, "line": 2}],
        "tools": tools or [],
    }


def tool(name="Bash", cmd="bash /scripts/codex-peer-adapter.sh", **updates):
    value = {
        "id": "call-1",
        "name": name,
        "arguments": {"command": cmd},
        "result": {"exit_code": 0},
        "error": False,
        "line": 3,
        "result_line": 4,
    }
    value.update(updates)
    return value


class PromiseAuditTests(unittest.TestCase):
    def test_all_file_claims_on_one_line_required(self):
        read = tool(name="Read", arguments={"file_path": "a.md"})
        result = classify(
            turn("Сейчас читаю файл `a.md`. Сейчас читаю файл `b.md`.", [read])
        )
        self.assertEqual(result["status"], "violation_no_attempt")
        self.assertEqual(len(result["findings"]), 2)

    def test_prior_vendor_not_part_of_new_claim(self):
        for text in (
            "Codex уже проверил. Сейчас вызываю Grok.",
            "Codex уже проверил, сейчас вызываю Grok.",
        ):
            result = classify(turn(text, [tool(cmd="bash grok-peer-adapter.sh")]))
            self.assertEqual(result["status"], "verified_structural")
            self.assertEqual(len(result["findings"]), 1)

    def test_other_sentence_cannot_suppress_promise(self):
        for suffix in (
            "Рекомендую сохранить результат.",
            "Не запускаю Codex.",
            "Что дальше?",
        ):
            result = classify(turn("Сейчас читаю файл `a.md`. " + suffix))
            self.assertEqual(result["status"], "violation_no_attempt")

    def test_quotes_inside_command_preserved(self):
        command = 'python -c "print(1)"'
        result = classify(
            turn("Сейчас выполняю `" + command + "`", [tool(cmd=command)])
        )
        self.assertEqual(result["status"], "verified_structural")

    def test_unbalanced_quote_is_unknown(self):
        for quote in ("«", "“", '"', "`"):
            self.assertEqual(
                classify(turn(quote + "Сейчас вызываю Codex"))["status"], "unknown"
            )

    def test_indirect_read_not_proven_absent(self):
        for call in (
            tool(cmd="cat a.md"),
            tool(name="mcp__filesystem__read_file", arguments={"path": "a.md"}),
        ):
            self.assertEqual(
                classify(turn("Сейчас читаю файл `a.md`", [call]))["status"],
                "review_required",
            )

    def test_incidental_peer_not_structural_target(self):
        result = classify(
            turn(
                "Сейчас вызываю Grok после проверки Codex.",
                [tool(cmd="bash grok-peer-adapter.sh")],
            )
        )
        self.assertEqual(result["status"], "heuristic_violation")

    def test_negative_neighbor_cannot_hide_read(self):
        result = classify(turn("Сейчас читаю файл `a.md`, но не запускаю Codex."))
        self.assertNotEqual(result["status"], "no_commitment")

    def test_target_after_promise_succeeds(self):
        result = classify(turn(tools=[tool()]))
        self.assertEqual(result["status"], "verified_structural")
        self.assertEqual(result["findings"][0]["matched_call_id"], "call-1")

    def test_absence(self):
        self.assertEqual(classify(turn())["status"], "violation_no_attempt")

    def test_previous_call_does_not_satisfy_future(self):
        self.assertEqual(
            classify(turn(tools=[tool(line=1, result_line=2)]))["status"],
            "violation_no_attempt",
        )

    def test_wrong_vendor(self):
        self.assertEqual(
            classify(turn(tools=[tool(cmd="bash grok-peer-adapter.sh")]))["status"],
            "violation_no_attempt",
        )

    def test_failed_call(self):
        self.assertEqual(
            classify(turn(tools=[tool(error=True, result={"exit_code": 1})]))["status"],
            "violation_attempt_failed",
        )

    def test_unknown_exit_cannot_prove_success(self):
        self.assertEqual(classify(turn(tools=[tool(error=None)]))["status"], "unknown")

    def test_late_result(self):
        self.assertEqual(
            classify(turn(tools=[tool(result_line=11)]))["status"], "unknown"
        )

    def test_both_named_vendors_required(self):
        self.assertEqual(
            classify(turn("Сейчас вызываю Codex и Claude", [tool()]))["status"],
            "violation_no_attempt",
        )

    def test_echo_is_not_launch(self):
        self.assertFalse(
            direct_peer_command("echo bash codex-peer-adapter.sh", "codex")
        )
        self.assertFalse(
            direct_peer_command("python -c 'bash codex-peer-adapter.sh'", "codex")
        )

    def test_orchestration_requires_review(self):
        self.assertEqual(
            classify(
                turn(tools=[tool(name="functions.exec", arguments={"code": "..."})])
            )["status"],
            "review_required",
        )

    def test_quote_and_fence(self):
        for text in (
            "Пример: «Сейчас вызываю Codex»",
            "> Сейчас вызываю Codex",
            "```\nСейчас вызываю Codex\n```",
        ):
            with self.subTest(text=text):
                self.assertEqual(classify(turn(text))["status"], "no_commitment")

    def test_broken_quote_is_unknown(self):
        self.assertEqual(classify(turn("«Сейчас вызываю Codex"))["status"], "unknown")

    def test_text_wait_and_negative_are_not_promises(self):
        for text in (
            "Перевод: доброе утро",
            "Жду решения о публикации",
            "Не вызываю Codex",
            "Не продолжу без разрешения",
        ):
            with self.subTest(text=text):
                self.assertEqual(classify(turn(text))["status"], "no_commitment")

    def test_future_unbound_is_only_heuristic(self):
        self.assertEqual(
            classify(turn("Дальше: ничего не жду; продолжу устранять замечания"))[
                "status"
            ],
            "heuristic_violation",
        )

    def test_read_exact_path(self):
        read = tool(name="Read", arguments={"file_path": "a.md"})
        self.assertEqual(
            classify(turn("Сейчас читаю файл `a.md`", [read]))["status"],
            "verified_structural",
        )
        self.assertEqual(
            classify(turn("Сейчас читаю файл `b.md`", [read]))["status"],
            "violation_no_attempt",
        )

    def test_shell_command_exact(self):
        self.assertEqual(
            classify(turn("Сейчас выполняю `pytest -q`", [tool(cmd="pytest -q")]))[
                "status"
            ],
            "verified_structural",
        )

    def test_denominator_includes_no_commitment_and_excludes_incomplete(self):
        pending = turn()
        pending["complete"] = False
        bundle = {
            "runtime": "codex",
            "source_sha256": "abc",
            "diagnostics": [],
            "turns": [turn(), turn("Готово"), pending],
        }
        result = audit(bundle)
        self.assertEqual(result["n_completed"], 2)
        self.assertEqual(sum(result["counts"].values()), 2)
        self.assertEqual(result["n_incomplete"], 1)
        self.assertEqual(result["structural_rate"], 0.5)
        self.assertNotIn("Готово", json.dumps(result, ensure_ascii=False))
        self.assertNotIn("command", json.dumps(result))

    def test_parse_error_never_clean(self):
        result = audit(
            {
                "runtime": "kimi",
                "source_sha256": "x",
                "diagnostics": ["bad json"],
                "turns": [turn()],
            }
        )
        self.assertFalse(result["denominator_complete"])
        self.assertEqual(result["counts"]["unknown"], 1)

    def review_case(self, result, classification="background", identifier="job-17"):
        current = turn(
            "Запущено, ID job-17",
            [tool(name="exec_command", result=result, error=None)],
        )
        current["final_line"] = 5
        current["text_segments"] = [{"text": current["final_text"], "line": 5}]
        bundle = {
            "schema_version": 1,
            "runtime": "codex",
            "source_sha256": "fixed",
            "diagnostics": [],
            "turns": [current],
        }
        reviews = {
            "normalizer_version": 1,
            "source_sha256": "fixed",
            "reviewer": "test reviewer",
            "decisions": [
                {
                    "turn_id": "1",
                    "classification": classification,
                    "reason": "checked target and result",
                    "bindings": [
                        {
                            "tool_id": "call-1",
                            "target": {"kind": "peer.launch", "value": "codex"},
                            "background_id": identifier,
                        }
                    ],
                }
            ],
        }
        return bundle, reviews

    def test_real_background_id(self):
        bundle, reviews = self.review_case({"session_id": "job-17"})
        report = audit(bundle)
        apply_reviews(report, bundle, reviews)
        self.assertEqual(report["semantic_review"]["counts"], {"background": 1})
        self.assertEqual(report["counts"]["no_commitment"], 1)

    def test_fabricated_background_id(self):
        bundle, reviews = self.review_case({"session_id": "job-18"})
        with self.assertRaises(ValueError):
            apply_reviews(audit(bundle), bundle, reviews)

    def test_arguments_are_not_background_evidence(self):
        bundle, reviews = self.review_case({"output": "ordinary output"})
        bundle["turns"][0]["tools"][0]["arguments"]["session_id"] = "job-17"
        with self.assertRaises(ValueError):
            apply_reviews(audit(bundle), bundle, reviews)

    def test_source_pin_rejects_stale_review(self):
        bundle, reviews = self.review_case({"session_id": "job-17"})
        reviews["source_sha256"] = "old"
        with self.assertRaises(ValueError):
            apply_reviews(audit(bundle), bundle, reviews)

    def test_review_cannot_certify_failed_target(self):
        bundle, reviews = self.review_case({"exit_code": 1}, classification="completed")
        bundle["turns"][0]["tools"][0]["error"] = True
        with self.assertRaises(ValueError):
            apply_reviews(audit(bundle), bundle, reviews)

    def test_review_cannot_use_other_tool(self):
        bundle, reviews = self.review_case({"session_id": "job-17"})
        reviews["decisions"][0]["bindings"][0]["target"]["value"] = "grok"
        with self.assertRaises(ValueError):
            apply_reviews(audit(bundle), bundle, reviews)

    def test_malformed_completed_boundary_stays_in_denominator(self):
        current = turn()
        current.update(complete=False, boundary={"completed": True})
        result = audit(
            {
                "runtime": "codex",
                "source_sha256": "x",
                "diagnostics": [],
                "turns": [current],
            }
        )
        self.assertEqual(result["n_completed"], 1)
        self.assertEqual(result["counts"]["unknown"], 1)

    def test_multiple_exact_calls_require_review(self):
        calls = [tool(), tool(id="call-2", line=5, result_line=6)]
        self.assertEqual(classify(turn(tools=calls))["status"], "review_required")

    def test_alternative_vendors_not_conjunction(self):
        self.assertEqual(
            classify(turn("Сейчас вызываю Codex или Claude"))["status"],
            "heuristic_violation",
        )

    def test_target_attached_to_verb(self):
        read = tool(name="Read", arguments={"file_path": "a.md"})
        self.assertEqual(
            classify(turn("Для `a.md` сейчас читаю файл `b.md`", [read]))["status"],
            "violation_no_attempt",
        )

    def test_help_is_not_peer_launch(self):
        self.assertFalse(
            direct_peer_command("bash codex-peer-adapter.sh --help", "codex")
        )

    def test_file_contents_are_not_execution_handle(self):
        bundle, reviews = self.review_case(
            {"exit_code": 0, "content": {"task_id": "job-17"}}
        )
        with self.assertRaises(ValueError):
            apply_reviews(audit(bundle), bundle, reviews)

    def test_printed_handle_is_not_execution_handle(self):
        for output in (
            "Process running with session ID job-17",
            "Chunk ID: a\nProcess exited with code 0\nFinal output:\nProcess running with session ID job-17",
        ):
            bundle, reviews = self.review_case(output)
            with self.assertRaises(ValueError):
                apply_reviews(audit(bundle), bundle, reviews)


if __name__ == "__main__":
    unittest.main()
