#!/usr/bin/env bash
# WP-484 Ф156: observe fresh close-intent records and unchanged peer release gates.
# Usage: bash test-close-gate-reminder-peer-intent.sh [hook] [close_obligation.py]
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


class PeerIntentTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="wp484-peer-intent-", dir="/private/tmp")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.sid = "f156-" + uuid.uuid4().hex
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("IWE_", "CLAUDE_", "GIT_"))}
        self.env.update(IWE_ROOT=str(self.root), CLAUDE_PROJECT_DIR=str(self.root),
                        IWE_RUNTIME_DIR=str(self.root / ".iwe-runtime"),
                        IWE_LEDGER_DIR=str(self.root / "ledger"),
                        IWE_PROCESS_CARDS_DIR=str(self.root / "cards"),
                        PYTHONDONTWRITEBYTECODE="1")
        self.cli = self.root / "DS-my-strategy/scripts/close_obligation.py"
        self.cli.parent.mkdir(parents=True)
        self.cli.symlink_to(CLOSE_CLI)
        self.semaphore = self.root / ".iwe-runtime/sessions/fixture.open"
        self.semaphore.parent.mkdir(parents=True)
        self.semaphore.write_text(
            "session_id: fixture\nharness_session_id: " + self.sid
            + "\nclose_path: peer-session\nwp: WP-484\n"
        )
        self.digest = hashlib.sha256(self.sid.encode()).hexdigest()[:32]
        self.intent = self.root / ".iwe-runtime/close-intent-records" / (self.digest + ".json")
        self.obligation = self.root / ".iwe-runtime/close-obligation" / (self.digest + ".json")
        self.sentinel = Path("/tmp/iwe-close-intent") / (self.sid + ".flag")
        self.pending = self.sentinel.with_name(self.sid + ".pending-reflection")
        for path in (self.sentinel, self.pending):
            self.addCleanup(path.unlink, missing_ok=True)

    def hook(self, prompt):
        result = subprocess.run(
            ["/bin/bash", HOOK], input=json.dumps({"prompt": prompt, "session_id": self.sid}),
            text=True, capture_output=True, env=self.env, cwd=self.root, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def read_intent(self):
        result = subprocess.run(
            [sys.executable, str(self.cli), "read-intent", "--session-id", self.sid],
            text=True, capture_output=True, check=True, env=self.env, cwd=self.root, timeout=15,
        )
        return json.loads(result.stdout)

    def assert_peer_unarmed(self):
        self.assertFalse(self.sentinel.exists(), "peer close must not arm a commit sentinel")
        self.assertFalse(self.obligation.exists(), "peer close must not arm a runner obligation")

    def assert_fresh_skip(self, prompt):
        self.assertFalse(self.intent.exists())
        output = self.hook(prompt)
        self.assertIn("пир-сессия", output["additionalContext"])
        record = self.read_intent()
        self.assertTrue(record["fresh"], record)
        self.assertTrue(record["skip_reflection"], record)
        self.assert_peer_unarmed()

    def test_peer_close_records_skip(self):
        self.assert_fresh_skip("закрывай сессию и заливай. рефлексии нет")

    def test_standalone_skip_uses_a_fresh_session(self):
        self.assert_fresh_skip("нет рефлексии")

    def test_peer_close_records_marked_reflection(self):
        self.hook("закрывай сессию, рефлексия: Всё проверили")
        record = self.read_intent()
        self.assertTrue(record["fresh"], record)
        self.assertEqual(record["raw_text"], "Всё проверили")
        self.assertFalse(record["skip_reflection"])
        self.assert_peer_unarmed()

    def test_peer_push_records_marked_reflection(self):
        self.hook("заливай, рефлексия: Всё проверили")
        self.assertEqual(self.read_intent()["raw_text"], "Всё проверили")
        self.assert_peer_unarmed()

    def test_neutral_peer_prompt_has_no_intent(self):
        self.hook("просто продолжаем работу")
        self.assertFalse(self.intent.exists())
        self.assert_peer_unarmed()

    def test_peer_cancellation_precedes_close_trigger(self):
        for prompt in ("не закрывай", "отмена закрытия", "не закрывай, рефлексии нет"):
            with self.subTest(prompt=prompt):
                output = self.hook(prompt)
                self.assertIn("cancel-close", output["additionalContext"])
                self.assertFalse(self.intent.exists())
                self.assert_peer_unarmed()

    def test_peer_day_close_is_not_session_intent(self):
        output = self.hook("закрывай день")
        self.assertIn("day-close", output["additionalContext"])
        self.assertFalse(self.intent.exists())
        self.assert_peer_unarmed()

    def test_peer_large_prefix_is_not_a_close_command(self):
        self.hook("а" * 601 + "закрывай, рефлексия: Чужая цитата")
        self.assertFalse(self.intent.exists())
        self.assert_peer_unarmed()

    def test_peer_multiline_large_prefix_is_not_a_close_command(self):
        self.hook(("лог чужой сессии\n" * 60) + "закрывай, рефлексия: Чужая цитата")
        self.assertFalse(self.intent.exists())
        self.assert_peer_unarmed()

    def assert_rejected_quote_ends_pending(self, peer):
        if not peer:
            self.semaphore.unlink()
        self.hook("закрывай сессию")
        self.assertTrue(self.pending.exists())
        before = self.intent.read_bytes()
        obligation = self.obligation.read_bytes() if self.obligation.exists() else None
        output = self.hook("а" * 601 + "закрывай, рефлексия: Чужая цитата; заливай без рефлексии")
        self.assertFalse(self.pending.exists(), "Rejected quote must end the previous follow-up window")
        self.assertEqual(self.intent.read_bytes(), before, "Quote must not change the intent record")
        record = json.loads(self.intent.read_text())
        self.assertEqual(record["raw_text"], "")
        self.assertFalse(record["skip_reflection"])
        if peer:
            self.assertIn("пир-сессия", output["additionalContext"])
            self.assert_peer_unarmed()
        else:
            self.assertEqual(output, {})
            self.assertFalse(self.sentinel.exists())
            self.assertEqual(self.obligation.read_bytes(), obligation)
        self.hook("рефлексия: Третья реплика")
        self.assertEqual(self.intent.read_bytes(), before, "Expired pending must not consume a later marker")

    def test_peer_rejected_quote_ends_pending_without_recording(self):
        self.assert_rejected_quote_ends_pending(peer=True)

    def test_plain_rejected_quote_ends_pending_without_recording(self):
        self.assert_rejected_quote_ends_pending(peer=False)

    def test_peer_prefix_boundary_accepts_600_characters(self):
        self.hook("а" * 600 + "закрывай, рефлексия: Текущий ответ")
        self.assertEqual(self.read_intent()["raw_text"], "Текущий ответ")
        self.assert_peer_unarmed()

    def test_peer_pending_reflection_accepts_next_marked_reply(self):
        self.hook("закрывай сессию")
        self.assertTrue(self.pending.exists())
        self.hook("рефлексия: Всё проверили")
        record = self.read_intent()
        self.assertTrue(record["fresh"], record)
        self.assertEqual(record["raw_text"], "Всё проверили")
        self.assertFalse(self.pending.exists())
        self.assert_peer_unarmed()

    def test_peer_pending_reflection_drops_unrelated_reply(self):
        self.hook("закрывай сессию")
        self.assertTrue(self.intent.exists())
        before = self.intent.read_bytes()
        self.hook("просто продолжаем работу")
        self.assertEqual(self.intent.read_bytes(), before)
        self.assertFalse(self.pending.exists())
        self.assert_peer_unarmed()

    def test_plain_close_preserves_obligation_and_intent(self):
        self.semaphore.unlink()
        output = self.hook("закрывай, рефлексия: Всё проверили")
        self.assertIn("БЛОКИРУЮЩЕЕ", output["additionalContext"])
        self.assertEqual(self.read_intent()["raw_text"], "Всё проверили")
        self.assertTrue(self.sentinel.exists())
        self.assertTrue(self.obligation.exists())

    def test_plain_standalone_skip_does_not_cancel_close(self):
        self.semaphore.unlink()
        self.assertEqual(self.hook("нет рефлексии"), {})
        self.assertTrue(self.read_intent()["skip_reflection"])
        self.assert_peer_unarmed()

    def test_foreign_harness_prefix_does_not_exempt_plain_close(self):
        self.semaphore.write_text(self.semaphore.read_text().replace(self.sid, self.sid + "-other"))
        output = self.hook("закрывай")
        self.assertIn("БЛОКИРУЮЩЕЕ", output["additionalContext"])
        self.assertTrue(self.sentinel.exists())
        self.assertTrue(self.obligation.exists())


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
