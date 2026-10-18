"""Observable normalization contracts; no live model calls or private fixtures."""

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "turn_evidence", Path(__file__).resolve().parents[1] / "turn_evidence.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def event(event_type, **payload):
    return {"type": "event_msg", "payload": {"type": event_type, **payload}}


def item(kind, **payload):
    return {"type": "response_item", "payload": {"type": kind, **payload}}


def message(text):
    return item(
        "message",
        role="assistant",
        phase="final_answer",
        content=[{"type": "output_text", "text": text}],
    )


def loop(kind, **payload):
    return {"type": "context.append_loop_event", "event": {"type": kind, **payload}}


def part(text, turn=1):
    return loop(
        "content.part", turnId=turn, step=2, part={"type": "text", "text": text}
    )


class TurnEvidenceTest(unittest.TestCase):
    def normalize(self, rows, runtime="codex", suffix=b""):
        raw = "\n".join(json.dumps(row) for row in rows).encode() + b"\n" + suffix
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "journal.jsonl"
            path.write_bytes(raw)
            result = MODULE.load_turns(path, runtime)
            self.assertEqual(hashlib.sha256(raw).hexdigest(), result["source_sha256"])
            self.assertEqual(raw, path.read_bytes())
            self.assertEqual([path], list(Path(directory).iterdir()))
        return result

    def test_codex_success_and_mirror_do_not_double_count(self):
        result = self.normalize(
            [
                event("task_started", turn_id="a"),
                item(
                    "function_call",
                    call_id="c",
                    name="exec",
                    arguments='{"cmd":"true"}',
                ),
                item("function_call_output", call_id="c", output='{"exit_code":0}'),
                event("agent_message", message="Сделано", phase="final_answer"),
                message("Сделано"),
                event("task_complete", turn_id="a", last_agent_message="Сделано"),
            ]
        )
        self.assertEqual([], result["diagnostics"])
        self.assertEqual(1, len(result["turns"]))
        turn = result["turns"][0]
        self.assertTrue(turn["complete"])
        self.assertEqual("Сделано", turn["final_text"])
        self.assertFalse(turn["tools"][0]["error"])
        self.assertEqual(3, turn["tools"][0]["result_line"])

    def test_codex_custom_call_error_and_unknown_outcome(self):
        result = self.normalize(
            [
                event("task_started", turn_id="a"),
                item("custom_tool_call", call_id="x", name="exec", input="code"),
                item("custom_tool_call_output", call_id="x", output={"isError": True}),
                item("function_call", call_id="y", name="read", arguments={}),
                item("function_call_output", call_id="y", output="opaque"),
                message("Ошибка"),
                event("task_complete", turn_id="a"),
            ]
        )
        tools = result["turns"][0]["tools"]
        self.assertTrue(tools[0]["error"])
        self.assertIsNone(tools[1]["error"])
        self.assertEqual("code", tools[0]["arguments"])

    def test_codex_mirror_only_commentary_is_preserved(self):
        result = self.normalize(
            [
                event("task_started", turn_id="a"),
                event("agent_message", message="Проверяю", phase="commentary"),
                item("function_call", call_id="x", name="exec", arguments={}),
                item("function_call_output", call_id="x", output={"exit_code": 0}),
                event("agent_message", message="Проверено", phase="final_answer"),
                message("Проверено"),
                event("task_complete", turn_id="a", last_agent_message="Проверено"),
            ]
        )
        self.assertEqual(
            [{"text": "Проверяю", "line": 2}, {"text": "Проверено", "line": 6}],
            result["turns"][0]["text_segments"],
        )

    def test_wrong_id_does_not_supply_tool_result(self):
        result = self.normalize(
            [
                event("task_started", turn_id="a"),
                item("function_call", call_id="x", name="exec", arguments={}),
                item("function_call_output", call_id="y", output={"exit_code": 0}),
                message("Готово"),
                event("task_complete", turn_id="a"),
            ]
        )
        self.assertIsNone(result["turns"][0]["tools"][0]["result"])
        self.assertFalse(result["turns"][0]["complete"])
        self.assertIn("unmatched_tool_result", " ".join(result["diagnostics"]))

    def test_result_after_commentary_before_boundary_is_evidence(self):
        result = self.normalize(
            [
                event("task_started", turn_id="a"),
                item("function_call", call_id="x", name="exec", arguments={}),
                message("Готово"),
                item("function_call_output", call_id="x", output={"exit_code": 0}),
                event("task_complete", turn_id="a", last_agent_message="Готово"),
            ]
        )
        turn = result["turns"][0]
        self.assertEqual({"exit_code": 0}, turn["tools"][0]["result"])
        self.assertEqual([{"text": "Готово", "line": 3}], turn["text_segments"])
        self.assertEqual(3, turn["final_line"])
        self.assertEqual(
            {"type": "task_complete", "line": 5, "completed": True}, turn["boundary"]
        )
        self.assertTrue(turn["complete"])

    def test_result_after_terminal_never_changes_closed_turn(self):
        result = self.normalize(
            [
                event("task_started", turn_id="a"),
                message("Запускаю"),
                item("function_call", call_id="x", name="exec", arguments={}),
                event("task_complete", turn_id="a"),
                item("function_call_output", call_id="x", output={"exit_code": 0}),
            ]
        )
        turn = result["turns"][0]
        self.assertIsNone(turn["tools"][0]["result"])
        self.assertGreater(turn["tools"][0]["line"], turn["text_segments"][0]["line"])
        self.assertIn("event_outside_turn", " ".join(result["diagnostics"]))

    def test_cross_turn_result_is_not_joined(self):
        result = self.normalize(
            [
                event("task_started", turn_id="a"),
                item("function_call", call_id="x", name="exec", arguments={}),
                message("Запускаю"),
                event("task_complete", turn_id="a"),
                event("task_started", turn_id="b"),
                item("function_call_output", call_id="x", output={"exit_code": 0}),
                message("Другой ответ"),
                event("task_complete", turn_id="b"),
            ]
        )
        self.assertEqual(2, len(result["turns"]))
        self.assertIsNone(result["turns"][0]["tools"][0]["result"])
        self.assertEqual([], result["turns"][1]["tools"])

    def test_partial_and_corrupt_sources_are_not_clean(self):
        partial = self.normalize([event("task_started", turn_id="a"), message("Часть")])
        self.assertFalse(partial["turns"][0]["complete"])
        corrupt = self.normalize(
            [
                event("task_started", turn_id="a"),
                message("Ответ"),
                event("task_complete", turn_id="a"),
            ],
            suffix=b'{"type":',
        )
        self.assertFalse(corrupt["turns"][0]["complete"])
        self.assertIn("malformed_record", " ".join(corrupt["diagnostics"]))

    def test_foreign_end_and_peer_message(self):
        result = self.normalize(
            [
                event("task_started", turn_id="a"),
                message("Свой ответ"),
                item(
                    "agent_message",
                    author="/root/child",
                    recipient="/root",
                    content="Чужой ответ",
                ),
                event("task_complete", turn_id="b"),
                event("task_complete", turn_id="a"),
            ]
        )
        self.assertEqual("Свой ответ", result["turns"][0]["final_text"])
        self.assertEqual("a", result["turns"][0]["id"])
        self.assertIn("foreign_turn_event", " ".join(result["diagnostics"]))

    def test_duplicate_completion_not_an_extra_turn(self):
        result = self.normalize(
            [
                event("task_started", turn_id="a"),
                message("Ответ"),
                event("task_complete", turn_id="a"),
                event("task_complete", turn_id="a"),
            ]
        )
        self.assertEqual(1, len(result["turns"]))
        self.assertTrue(result["diagnostics"])

    def test_kimi_canonical_events_and_message_mirror(self):
        result = self.normalize(
            [
                {"type": "turn.prompt", "turnId": 1, "agentId": "main"},
                loop(
                    "tool.call",
                    turnId=1,
                    step=1,
                    toolCallId="x",
                    name="Bash",
                    args={"command": "true"},
                ),
                loop(
                    "tool.result",
                    toolCallId="x",
                    parentUuid="p",
                    result={"output": "Process exited with code 0"},
                ),
                part("Ответ"),
                {
                    "type": "agent.message.appended",
                    "message": {"message": {"role": "assistant", "content": "Дубль"}},
                },
                {"type": "turn.ended", "turnId": 1, "reason": "completed"},
            ],
            "kimi",
        )
        self.assertEqual([], result["diagnostics"])
        self.assertEqual("Ответ", result["turns"][0]["final_text"])
        self.assertIsNone(result["turns"][0]["tools"][0]["error"])
        self.assertTrue(result["turns"][0]["complete"])

    def test_kimi_cancelled_and_failed(self):
        for reason in ("cancelled", "failed"):
            with self.subTest(reason=reason):
                result = self.normalize(
                    [
                        {"type": "turn.begin", "turnId": 1},
                        part("Часть"),
                        {"type": "turn.ended", "turnId": 1, "reason": reason},
                    ],
                    "kimi",
                )
                self.assertFalse(result["turns"][0]["complete"])

    def test_kimi_foreign_agent_and_turn(self):
        result = self.normalize(
            [
                {"type": "turn.prompt", "turnId": 1, "agentId": "main"},
                part("Свой"),
                part("Чужой", turn=2),
                {
                    "type": "turn.ended",
                    "agentId": "child",
                    "turnId": 1,
                    "reason": "completed",
                },
                {"type": "turn.ended", "turnId": 1, "reason": "completed"},
            ],
            "kimi",
        )
        self.assertEqual("Свой", result["turns"][0]["final_text"])
        self.assertFalse(result["turns"][0]["complete"])

    def test_kimi_text_fallback_never_claims_full_evidence(self):
        result = self.normalize(
            [
                {"type": "turn.begin", "turnId": 1},
                {
                    "type": "agent.message.appended",
                    "message": {"message": {"role": "assistant", "content": "Ответ"}},
                },
                {"type": "turn.ended", "turnId": 1, "reason": "completed"},
            ],
            "kimi",
        )
        self.assertEqual("Ответ", result["turns"][0]["final_text"])
        self.assertFalse(result["turns"][0]["complete"])

    def test_unknown_schema_and_runtime(self):
        result = self.normalize([{"type": "future_format", "data": "unknown"}])
        self.assertEqual([], result["turns"])
        self.assertIn("no_recognized_turns", " ".join(result["diagnostics"]))
        with self.assertRaises(ValueError):
            self.normalize([], "unknown")

    def test_schema_drift_inside_a_turn_invalidates_completeness(self):
        result = self.normalize(
            [
                event("task_started", turn_id="a"),
                {"type": "new_wire_format"},
                message("Ответ"),
                event("task_complete", turn_id="a"),
            ]
        )
        self.assertFalse(result["turns"][0]["complete"])
        self.assertTrue(result["turns"][0]["boundary"]["completed"])
        self.assertTrue(result["fatal_diagnostics"])
        self.assertIn("unsupported_record_type", " ".join(result["diagnostics"]))

    def test_cancelled_turn_does_not_invalidate_other_completed_turn(self):
        result = self.normalize(
            [
                event("task_started", turn_id="a"),
                message("Часть"),
                event("turn_aborted", turn_id="a"),
                event("task_started", turn_id="b"),
                message("Ответ"),
                event("task_complete", turn_id="b"),
            ]
        )
        self.assertFalse(result["turns"][0]["boundary"]["completed"])
        self.assertTrue(result["turns"][1]["boundary"]["completed"])
        self.assertTrue(result["turns"][1]["complete"])
        self.assertEqual([], result["fatal_diagnostics"])
        self.assertEqual(1, len(result["diagnostics"]))

    def test_failure_wins_conflicting_outcome_fields(self):
        for output in (
            {"isError": False, "exit_code": 1},
            {"is_error": False, "error": True},
            {"exitCode": 0, "error": "failed"},
        ):
            with self.subTest(output=output):
                result = self.normalize(
                    [
                        event("task_started", turn_id="a"),
                        item("function_call", call_id="x", name="exec", arguments={}),
                        item("function_call_output", call_id="x", output=output),
                        message("Ошибка"),
                        event("task_complete", turn_id="a"),
                    ]
                )
                self.assertTrue(result["turns"][0]["tools"][0]["error"])

    def test_unknown_assistant_content_is_not_silent_empty_text(self):
        for content in ({"text": "обещаю"}, None, 42, [{"type": "text"}], ["текст"]):
            with self.subTest(content=content):
                result = self.normalize(
                    [
                        event("task_started", turn_id="a"),
                        item("message", role="assistant", content=content),
                        event("task_complete", turn_id="a"),
                    ]
                )
                self.assertFalse(result["turns"][0]["complete"])
                self.assertTrue(result["turns"][0]["boundary"]["completed"])
                self.assertIn(
                    "unsupported_assistant_content",
                    " ".join(result["fatal_diagnostics"]),
                )

    def test_terminal_fallback_never_inherits_stale_commentary_line(self):
        result = self.normalize(
            [
                event("task_started", turn_id="a"),
                event("agent_message", message="Проверяю", phase="commentary"),
                item("function_call", call_id="x", name="exec", arguments={}),
                item("function_call_output", call_id="x", output={"exit_code": 0}),
                event(
                    "task_complete",
                    turn_id="a",
                    last_agent_message="Сейчас вызываю Codex",
                ),
            ]
        )
        turn = result["turns"][0]
        self.assertEqual(5, turn["final_line"])
        self.assertEqual("Сейчас вызываю Codex", turn["final_text"])
        self.assertGreater(turn["final_line"], turn["tools"][0]["result_line"])
        self.assertFalse(turn["complete"])
        self.assertIn(
            "terminal_text_without_message_order_unknown",
            " ".join(result["fatal_diagnostics"]),
        )

    def test_stdout_status_markers_never_become_exit_evidence(self):
        native = "Chunk ID: abc123\nWall time: 0.01 seconds\nProcess exited with code 0\nFinal output:\n"
        cases = [
            ({"output": "exit code 0"}, None),
            ({"exit_code": 0, "output": "exit code 1"}, False),
            ({"output": native}, None),
            ({"output": {"exit_code": 0}}, None),
            ({"isError": False, "output": {"exit_code": 2}}, False),
            ("fixture: Process exited with code 0", None),
            ("Process exited with code 0", None),
            ("Output:\n" + native, None),
            (native + "fixture: Process exited with code 9", False),
            (native.replace("code 0", "code 1"), True),
            ("Chunk ID: abc123\nOutput:\nProcess exited with code 0", None),
        ]
        for output, expected in cases:
            with self.subTest(output=output):
                result = self.normalize(
                    [
                        event("task_started", turn_id="a"),
                        item("function_call", call_id="x", name="exec", arguments={}),
                        item("function_call_output", call_id="x", output=output),
                        message("Ответ"),
                        event("task_complete", turn_id="a"),
                    ]
                )
                self.assertIs(expected, result["turns"][0]["tools"][0]["error"])

    def test_tool_execution_events_are_not_harmless_metadata(self):
        for kind in ("mcp_tool_call_end", "web_search_end", "patch_apply_end"):
            with self.subTest(kind=kind):
                result = self.normalize(
                    [
                        event("task_started", turn_id="a"),
                        event(kind, call_id="x"),
                        message("Ответ"),
                        event("task_complete", turn_id="a"),
                    ]
                )
                self.assertFalse(result["turns"][0]["complete"])
                self.assertIn(
                    f"unsupported_tool_execution_event:{kind}",
                    " ".join(result["fatal_diagnostics"]),
                )

    def test_subagent_activity_metadata_is_not_a_parent_answer(self):
        result = self.normalize(
            [
                event("task_started", turn_id="a"),
                event("sub_agent_activity", kind="completed", agent_path="/root/child"),
                message("Ответ"),
                event("task_complete", turn_id="a"),
            ]
        )
        self.assertTrue(result["turns"][0]["complete"])
        self.assertEqual([], result["fatal_diagnostics"])

    def test_missing_start_is_diagnostic(self):
        result = self.normalize(
            [part("Ответ"), {"type": "turn.ended", "turnId": 1, "reason": "completed"}],
            "kimi",
        )
        self.assertFalse(result["turns"][0]["complete"])
        self.assertIn("turn_missing_start", " ".join(result["diagnostics"]))


if __name__ == "__main__":
    unittest.main()
