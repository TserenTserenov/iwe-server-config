#!/usr/bin/env python3
"""Exercise Stop feedback with an isolated close-obligation response."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HOOK = Path(__file__).resolve().parents[1] / "protocol-stop-gate.sh"
DIAGNOSTIC_NOTES = (
    "close_path=peer-session — раннер не требуется, "
    "Stop-гейт пропускает",
    "close_path=peer-session (obligation взведено внутри пир-сессии) — "
    "раннер не требуется, Stop-гейт пропускает",
    "close obligation verified and cleared",
)


class StopGateContextTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="iwe-stop-context-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.transcript = self.root / "transcript.jsonl"
        self.transcript.write_text('{"type":"user"}\n', encoding="utf-8")
        obligation_cli = self.root / "DS-my-strategy" / "scripts" / "close_obligation.py"
        obligation_cli.parent.mkdir(parents=True)
        obligation_cli.write_text(
            'import os\nprint(os.environ["STOP_CHECK_REPLY"])\n', encoding="utf-8"
        )

    def run_hook(self, reply, *, stop_hook_active=False):
        environment = os.environ.copy()
        environment.update(
            WORKSPACE_DIR=str(self.root),
            IWE_ROOT=str(self.root),
            IWE_GOVERNANCE_REPO="DS-my-strategy",
            IWE_RUNTIME_DIR=str(self.root / "runtime"),
            STOP_CHECK_REPLY=json.dumps(reply, ensure_ascii=False),
        )
        environment.pop("STOP_HOOK_ACTIVE", None)
        environment.pop("CLAUDE_SESSION_ID", None)
        payload = {
            "hook_event_name": "Stop",
            "session_id": "test-session",
            "transcript_path": str(self.transcript),
            "stop_hook_active": stop_hook_active,
        }
        result = subprocess.run(
            ["bash", str(HOOK)],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            env=environment,
            check=True,
            timeout=5,
        )
        return json.loads(result.stdout)

    def test_diagnostic_allow_notes_do_not_continue_turn(self):
        for note in DIAGNOSTIC_NOTES:
            with self.subTest(note=note):
                self.assertEqual(self.run_hook({"action": "allow", "note": note}), {})

    def test_actionable_allow_note_reaches_claude_once(self):
        note = (
            "quick-close ждёт ввода на шаге review — "
            "покажи пилоту pending-вопрос"
        )
        reply = {"action": "allow", "note": note}
        self.assertEqual(
            self.run_hook(reply),
            {
                "hookSpecificOutput": {
                    "hookEventName": "Stop",
                    "additionalContext": f"CLOSE-OBLIGATION (Ф74б): {note}",
                }
            },
        )
        self.assertEqual(self.run_hook(reply, stop_hook_active=True), {})

    def test_warning_reaches_claude_once(self):
        reply = {"action": "warn", "reason": "quick-close ждёт ввода"}
        output = self.run_hook(reply)
        self.assertEqual(output["hookSpecificOutput"]["hookEventName"], "Stop")
        context = output["hookSpecificOutput"]["additionalContext"]
        self.assertIn("quick-close ждёт ввода", context)
        self.assertEqual(self.run_hook(reply, stop_hook_active=True), {})

    def test_real_block_still_blocks_follow_up_stop(self):
        output = self.run_hook(
            {"action": "block", "reason": "runner still active"},
            stop_hook_active=True,
        )
        self.assertEqual(output["decision"], "block")
        self.assertIn("runner still active", output["reason"])


if __name__ == "__main__":
    unittest.main()
