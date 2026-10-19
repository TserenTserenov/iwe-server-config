"""WP-603 generator: only reviewed facts may become a final status line."""

import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from next_block_generator import claude_background_state, generate_next_block
from promise_audit import returned_ids


def case(classification="completed", *, tool=True, background=False):
    command = "claude --bg synthetic" if background else "python3 proof.py"
    call = {
        "id": "call-1",
        "name": "exec_command",
        "arguments": {"cmd": command},
        "result": {
            "exit_code": 0,
            "output": "backgrounded · deadbeef\n" if background else "proof complete",
        },
        "error": False,
        "line": 2,
        "result_line": 3,
    }
    current = {
        "id": "turn-1",
        "complete": True,
        "end_line": 6,
        "final_line": 5,
        "final_text": "Проверка сделана. ID deadbeef"
        if background
        else "Проверка сделана.",
        "text_segments": [{"text": "Проверка сделана.", "line": 5}],
        "tools": [call] if tool else [],
    }
    bundle = {
        "schema_version": 1,
        "runtime": "codex",
        "source_sha256": "fixed-source",
        "diagnostics": [],
        "turns": [current],
    }
    decision = {
        "turn_id": "turn-1",
        "classification": classification,
        "reason": "target and whole request assessed",
    }
    if tool:
        decision["bindings"] = [
            {
                "tool_id": "call-1",
                "target": {"kind": "shell.exec", "value": command},
                **({"background_id": "deadbeef"} if background else {}),
            }
        ]
    reviews = {
        "normalizer_version": 1,
        "source_sha256": "fixed-source",
        "reviewer": "test reviewer",
        "decisions": [decision],
    }
    state = {
        "turn_id": "turn-1",
        "scope": "open"
        if background or classification in {"waiting", "blocked"}
        else "complete",
        "open_conditions": []
        if classification in {"completed", "text_only"}
        else ["pending"],
        "available_actions": [],
    }
    return bundle, reviews, state


class NextBlockTests(unittest.TestCase):
    def test_successful_target_and_complete_scope(self):
        bundle, reviews, state = case()
        self.assertEqual(
            generate_next_block(bundle, reviews, state),
            "Дальше: ничего не жду — объём завершён, доступных действий не осталось.",
        )

    def test_text_only_answer_needs_no_tool(self):
        bundle, reviews, state = case("text_only", tool=False)
        self.assertIn("ничего не жду", generate_next_block(bundle, reviews, state))

    def test_available_action_blocks_final(self):
        for verdict, kwargs in (
            ("completed", {}),
            ("background", {"background": True}),
            ("waiting", {"tool": False}),
            ("blocked", {"tool": False}),
        ):
            with self.subTest(verdict=verdict):
                bundle, reviews, state = case(verdict, **kwargs)
                state["available_actions"] = ["check the requested result"]
                with self.assertRaisesRegex(ValueError, "perform available actions"):
                    generate_next_block(bundle, reviews, state)

    def test_incomplete_scope_blocks_false_closure(self):
        bundle, reviews, state = case()
        state["open_conditions"] = ["test not run"]
        with self.assertRaisesRegex(ValueError, "whole request"):
            generate_next_block(bundle, reviews, state)

    def test_failed_or_unrelated_target_cannot_complete(self):
        bundle, reviews, state = case()
        bundle["turns"][0]["tools"][0]["error"] = True
        with self.assertRaisesRegex(ValueError, "no successful result"):
            generate_next_block(bundle, reviews, state)
        bundle, reviews, state = case()
        reviews["decisions"][0]["bindings"][0]["target"]["value"] = "other.py"
        with self.assertRaisesRegex(ValueError, "target call mismatch"):
            generate_next_block(bundle, reviews, state)

    def test_supervised_background_requires_live_session(self):
        bundle, reviews, state = case("background", background=True)
        self.assertIn(
            "ID `deadbeef`",
            generate_next_block(bundle, reviews, state, lambda _: "working"),
        )
        with self.assertRaisesRegex(ValueError, "not confirmed working"):
            generate_next_block(bundle, reviews, state, lambda _: "not_working")

    def test_bash_child_id_does_not_claim_durable_background(self):
        bundle, reviews, state = case("background", background=True)
        bundle["turns"][0]["tools"][0]["arguments"]["cmd"] = "python3 job.py"
        reviews["decisions"][0]["bindings"][0]["target"]["value"] = "python3 job.py"
        with self.assertRaisesRegex(ValueError, "supervised Claude"):
            generate_next_block(bundle, reviews, state, lambda _: "working")

    def test_waiting_requires_external_dependency(self):
        bundle, reviews, state = case("waiting", tool=False)
        with self.assertRaisesRegex(ValueError, "external dependency"):
            generate_next_block(bundle, reviews, state)
        state["external_dependency"] = {
            "kind": "decision",
            "description": "решения пилота по доступу",
        }
        self.assertEqual(
            generate_next_block(bundle, reviews, state),
            "Дальше: жду решения пилота по доступу; поручение остаётся открытым.",
        )

    def test_blocked_requires_external_dependency(self):
        bundle, reviews, state = case("blocked", tool=False)
        state["external_dependency"] = {
            "kind": "permission",
            "description": "разрешение на доступ к источнику",
        }
        self.assertEqual(
            generate_next_block(bundle, reviews, state),
            "Дальше: блокер — разрешение на доступ к источнику; поручение остаётся открытым.",
        )

    @patch("next_block_generator.subprocess.run")
    def test_claude_supervisor_inventory_shape(self, run):
        # Captured schema from Claude Code 2.1.288 `claude agents --json --all`.
        run.return_value.stdout = (
            '[{"id":"deadbeef","kind":"background","state":"working","status":"busy"}]'
        )
        self.assertEqual(claude_background_state("deadbeef"), "working")
        run.assert_called_once_with(
            ["claude", "agents", "--json", "--all"],
            capture_output=True,
            text=True,
            timeout=15,
            check=True,
        )
        run.return_value.stdout = (
            '[{"id":"deadbeef","kind":"background","state":"done","status":"idle"}]'
        )
        self.assertEqual(claude_background_state("deadbeef"), "not_working")

    def test_stale_review_and_missing_state_fail_closed(self):
        bundle, reviews, state = case()
        reviews["source_sha256"] = "old"
        with self.assertRaisesRegex(ValueError, "source digest mismatch"):
            generate_next_block(bundle, reviews, state)
        bundle, reviews, state = case()
        del state["available_actions"]
        with self.assertRaisesRegex(ValueError, "available_actions"):
            generate_next_block(bundle, reviews, state)

    def test_background_identifier_only_from_successful_result(self):
        self.assertEqual(
            returned_ids({"exit_code": 0, "output": "backgrounded · deadbeef\n"}),
            {"deadbeef"},
        )
        self.assertEqual(
            returned_ids({"exit_code": 1, "output": "backgrounded · deadbeef\n"}), set()
        )
        self.assertEqual(returned_ids({"output": "backgrounded · deadbeef\n"}), set())
        self.assertEqual(
            returned_ids({"exit_code": False, "output": "backgrounded · deadbeef\n"}),
            set(),
        )


if __name__ == "__main__":
    unittest.main()
