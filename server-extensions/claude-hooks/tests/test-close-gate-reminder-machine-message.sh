#!/usr/bin/env bash
# WP-484 (19.11, independent review): close-gate-reminder.sh must not record a close
# intent from a background-task notification or a subagent hand-back that merely
# contains the word "закрывай"; a plain pilot command must still record it.
# Usage: bash test-close-gate-reminder-machine-message.sh [hook] [close_obligation.py]
set -euo pipefail
HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/close-gate-reminder.sh}"
CLOSE_CLI="${2:-$HOME/IWE/DS-my-strategy/scripts/close_obligation.py}"
PYTHONDONTWRITEBYTECODE=1 python3 - "$HOOK" "$CLOSE_CLI" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

HOOK, CLOSE_CLI = map(lambda value: str(Path(value).resolve(strict=True)), sys.argv[1:])


class MachineMessageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="wp484-machine-msg-", dir=os.environ.get("TMPDIR", "/tmp"))
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.sid = "mm-" + uuid.uuid4().hex
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("IWE_", "CLAUDE_", "GIT_"))}
        self.env.update(IWE_ROOT=str(self.root), CLAUDE_PROJECT_DIR=str(self.root),
                        IWE_RUNTIME_DIR=str(self.root / ".iwe-runtime"),
                        IWE_LEDGER_DIR=str(self.root / "ledger"),
                        IWE_PROCESS_CARDS_DIR=str(self.root / "cards"),
                        PYTHONDONTWRITEBYTECODE="1")
        cli = self.root / "DS-my-strategy/scripts/close_obligation.py"
        cli.parent.mkdir(parents=True)
        cli.symlink_to(CLOSE_CLI)
        semaphore = self.root / ".iwe-runtime/sessions/fixture.open"
        semaphore.parent.mkdir(parents=True)
        semaphore.write_text(
            "session_id: fixture\nharness_session_id: " + self.sid
            + "\nclose_path: peer-session\nwp: WP-484\n"
        )
        digest = hashlib.sha256(self.sid.encode()).hexdigest()[:32]
        self.intent = self.root / ".iwe-runtime/close-intent-records" / (digest + ".json")
        self.sentinel = Path("/tmp/iwe-close-intent") / (self.sid + ".flag")
        self.addCleanup(self.sentinel.unlink, missing_ok=True)

    def hook(self, prompt):
        result = subprocess.run(
            ["/bin/bash", HOOK], input=json.dumps({"prompt": prompt, "session_id": self.sid}),
            text=True, capture_output=True, env=self.env, cwd=self.root, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_plain_pilot_command_still_records_the_intent(self):
        self.hook("закрывай сессию")
        self.assertTrue(self.intent.exists(), "control: a pilot command must record the close intent")

    def test_subagent_hand_back_with_close_word_records_nothing(self):
        self.hook('<agent-message from="a7296090177c0e1a3">\n[Subagent hand-back] отчёт: закрывай сессию после правки\n</agent-message>')
        self.assertFalse(self.intent.exists())
        self.assertFalse(self.sentinel.exists())

    def test_notification_with_preamble_records_nothing(self):
        self.hook("[SYSTEM NOTIFICATION - NOT USER INPUT]\nавтоматическое событие, закрывай\n"
                  "<task-notification><summary>закрой окно</summary></task-notification>")
        self.assertFalse(self.intent.exists())

    def test_bare_notification_with_leading_blanks_records_nothing(self):
        self.hook("\r\n  <task-notification>закрой</task-notification>")
        self.assertFalse(self.intent.exists())

    def test_text_that_only_mentions_the_tag_is_still_a_pilot_command(self):
        self.hook("закрывай сессию, тег <agent-message from= упомянут как пример")
        self.assertTrue(self.intent.exists(), "mid-sentence mention must not hide a pilot command")


unittest.main(argv=["x"], verbosity=2)
PY
