#!/usr/bin/env bash
# WP-561 (29.09.2026, peer-session 2026-09-29-19-wp561-close-proposal-bias, contracts by Codex):
# a close word that is only MENTIONED (quoted, negated, asked about) must not arm the
# close obligation or record a close intent; a real command still must, even next to a
# quote. The filter is fail-open: unknown = old behaviour (arm).
#
# Live repro 29.09: the task "why do you write «закрывай»?" armed the obligation and the
# Stop gate blocked the turn until a manual cancel-close.
#
# Usage: bash test-close-gate-reminder-quoted-trigger.sh [hook] [close_obligation.py]
set -euo pipefail
HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/close-gate-reminder.sh}"
CLOSE_CLI="${2:-$HOME/IWE/DS-my-strategy/scripts/close_obligation.py}"
PYTHONDONTWRITEBYTECODE=1 python3 - "$HOOK" "$CLOSE_CLI" <<'PY'
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

HOOK, CLOSE_CLI = map(lambda value: str(Path(value).resolve(strict=True)), sys.argv[1:])
FILTER = str(Path(HOOK).with_name("a12-unsolicited-close.py").resolve(strict=True))


class QuotedTriggerTests(unittest.TestCase):
    PEER = False  # PeerQuotedTriggerTests re-runs every scenario in peer-session mode

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="wp561-quoted-", dir="/private/tmp")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.sid = "wp561-" + uuid.uuid4().hex
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("IWE_", "CLAUDE_", "GIT_"))}
        self.env.update(IWE_ROOT=str(self.root), CLAUDE_PROJECT_DIR=str(self.root),
                        IWE_RUNTIME_DIR=str(self.root / ".iwe-runtime"),
                        IWE_LEDGER_DIR=str(self.root / "ledger"),
                        IWE_PROCESS_CARDS_DIR=str(self.root / "cards"),
                        PYTHONDONTWRITEBYTECODE="1")
        self.cli = self.root / "DS-my-strategy/scripts/close_obligation.py"
        self.cli.parent.mkdir(parents=True)
        # A copy, not a symlink: the CLI derives its scripts directory from its own real path, so a
        # symlink would use the real ledger writer. The stub makes cancel-close succeed in the
        # fixture; without it cancel fails on the ledger append and changes nothing.
        shutil.copy(CLOSE_CLI, self.cli)
        stub = self.cli.with_name("ledger-append.sh")
        stub.write_text("#!/bin/bash\nexit 0\n")
        stub.chmod(0o755)
        self.digest = hashlib.sha256(self.sid.encode()).hexdigest()[:32]
        self.intent = self.root / ".iwe-runtime/close-intent-records" / (self.digest + ".json")
        self.obligation = self.root / ".iwe-runtime/close-obligation" / (self.digest + ".json")
        self.sentinel = Path("/tmp/iwe-close-intent") / (self.sid + ".flag")
        self.pending = self.sentinel.with_name(self.sid + ".pending-reflection")
        for path in (self.sentinel, self.pending):
            self.addCleanup(path.unlink, missing_ok=True)
        self.hook_path = HOOK
        if self.PEER:
            semaphore = self.root / ".iwe-runtime/sessions/fixture.open"
            semaphore.parent.mkdir(parents=True)
            semaphore.write_text("session_id: fixture\nharness_session_id: " + self.sid
                                 + "\nclose_path: peer-session\nwp: WP-561\n")

    def run_hook(self, prompt):
        result = subprocess.run(
            ["/bin/bash", self.hook_path], input=json.dumps({"prompt": prompt, "session_id": self.sid}),
            text=True, capture_output=True, env=self.env, cwd=self.root, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("\n") >= 1, True, "hook must print one JSON line")
        return json.loads(result.stdout)

    def state_file(self):
        """What a real command leaves behind: an obligation (normal) or an intent record (peer)."""
        return self.intent if self.PEER else self.obligation

    def assert_not_armed(self, prompt):
        self.run_hook(prompt)
        self.assertFalse(self.obligation.exists(), "obligation armed by a mention: " + prompt)
        self.assertFalse(self.sentinel.exists(), "sentinel written by a mention: " + prompt)
        self.assertFalse(self.intent.exists(), "close intent recorded by a mention: " + prompt)

    def assert_armed(self, prompt):
        self.run_hook(prompt)
        self.assertTrue(self.state_file().exists(), "real command left no state: " + prompt)
        if self.PEER:
            self.assertFalse(self.obligation.exists(), "peer close must not arm an obligation")
        else:
            self.assertTrue(self.sentinel.exists(), "real command wrote no sentinel: " + prompt)

    # --- mentions must not arm ---
    def test_question_about_the_word(self):
        self.assert_not_armed("Почему ты постоянно пишешь «закрывай»?")

    def test_future_conditional_quote(self):
        self.assert_not_armed("Скажу «закрывай» когда закончим")

    def test_bare_quoted_word_is_conservative_no(self):
        # Documented trade-off (Codex, round 4): a lone «закрывай» is ambiguous; not arming is safe.
        self.assert_not_armed("«закрывай»")

    def test_quoted_push_phrase(self):
        self.assert_not_armed("Ты пишешь «заливай и закрывай» в каждом отчёте, зачем?")

    # --- real commands still arm, also next to a quote ---
    def test_plain_command(self):
        self.assert_armed("Закрывай")

    def test_push_and_close(self):
        self.assert_armed("заливай и закрывай")

    def test_command_after_a_quoted_question(self):
        self.assert_armed("Почему ты пишешь «закрывай»? Теперь закрывай.")

    def test_command_with_quoted_argument(self):
        self.assert_armed("Теперь закрывай, сообщение назови «готово»")

    def test_present_tense_trigger_word(self):
        # CLOSE_TRIGGER_RE contains "закрываю"; the filter must not veto what the hook itself accepts.
        self.assert_armed("закрываю сессию")

    # --- an existing obligation is neither re-armed nor cancelled by a mention ---
    def test_existing_obligation_untouched_by_mention(self):
        self.assert_armed("Закрывай")
        before = self.state_file().read_bytes()
        self.run_hook("Почему ты пишешь «закрывай»?")
        self.assertEqual(self.state_file().read_bytes(), before)

    def test_plain_cancel_really_cancels(self):
        # Sanity for the next test: cancel-close removes the armed obligation. Peer sessions arm
        # no obligation, so there is nothing to cancel there.
        if self.PEER:
            self.skipTest("peer sessions arm no obligation")
        self.assert_armed("Закрывай")
        self.run_hook("не закрывай")
        self.assertFalse(self.obligation.exists(), "plain cancel left the obligation armed")

    def test_quoted_cancel_phrase_does_not_cancel(self):
        # A cancel phrase inside a quote is a mention, not a cancellation of a real obligation.
        self.assert_armed("Закрывай")
        before = self.state_file().read_bytes()
        self.run_hook("Он написал «не закрывай пока» в другой сессии")
        self.assertTrue(self.state_file().exists(), "a quoted cancel phrase cancelled the obligation")
        self.assertEqual(self.state_file().read_bytes(), before)

    def test_question_about_a_cancel_phrase_does_not_cancel(self):
        self.assert_armed("Закрывай")
        self.run_hook("Почему ты реагируешь на «не закрывай»?")
        self.assertTrue(self.state_file().exists(), "a question about the phrase cancelled the obligation")

    # --- fail-open: any unknown answer keeps the old behaviour ---
    def with_fake_filter(self, body):
        hooks = self.root / "fake-hooks"
        hooks.mkdir()
        shutil.copy(HOOK, hooks / "close-gate-reminder.sh")
        if body is not None:
            (hooks / "a12-unsolicited-close.py").write_text(body)
        self.hook_path = str(hooks / "close-gate-reminder.sh")

    def test_fail_open_nonzero_exit_even_with_no(self):
        self.with_fake_filter("import sys\nprint('no')\nsys.exit(3)\n")
        self.assert_armed("Почему ты пишешь «закрывай»?")

    def test_fail_open_empty_output(self):
        self.with_fake_filter("")
        self.assert_armed("Почему ты пишешь «закрывай»?")

    def test_fail_open_foreign_output(self):
        self.with_fake_filter("print('maybe')\n")
        self.assert_armed("Почему ты пишешь «закрывай»?")

    def test_fail_open_missing_script(self):
        self.with_fake_filter(None)
        self.assert_armed("Почему ты пишешь «закрывай»?")

    # --- threshold boundary measured on the ORIGINAL text, both modes (Codex, round 5) ---
    def reset_state(self):
        for path in (self.obligation, self.intent, self.sentinel, self.pending):
            path.unlink(missing_ok=True)

    def test_boundary_599_600_601(self):
        self.assert_armed("ж" * 599 + "закрывай")             # command starts at 599
        self.reset_state()
        self.assert_armed("ж" * 600 + "закрывай")             # 600
        self.reset_state()
        self.assert_not_armed("ж" * 601 + "закрывай")        # 601: pasted text

    def test_threshold_is_measured_to_the_first_valid_trigger(self):
        # Pinned choice (Codex, round 6): the prefix is measured up to the first command,
        # not the first raw match. A short quote before a far-away command does not make
        # the command look near; a quote holding the word does not hide a near command.
        self.assert_not_armed("«закрывай» " + "ж" * 700 + " закрывай")      # command at 711
        self.assert_not_armed("ж" * 601 + " «закрывай» и потом закрывай")     # everything past 601
        self.assert_armed("«закрывай» " + "ж" * 300 + " закрывай")            # command at 311

    def test_no_valid_close_word_falls_back_to_the_raw_measure(self):
        # The filter finds no valid trigger word (only a quoted one) but the message is a
        # command through another phrase; the old raw measure must still reject a paste.
        self.assert_not_armed("ж" * 601 + " «закрывай» заливай")

    def test_boundary_with_a_quote_before_the_command(self):
        quote = "«закрывай»" + " "          # 11 chars, the word inside is masked
        self.assert_armed(quote + "ж" * 588 + "закрывай")        # command starts at 599
        self.reset_state()
        self.assert_armed(quote + "ж" * 589 + "закрывай")        # 600
        self.reset_state()
        self.assert_not_armed(quote + "ж" * 590 + "закрывай")    # 601

    def test_boundary_after_a_long_quote_holding_the_word(self):
        quote = "«закрывай" + "ж" * 300 + "»"   # 310 chars, Cyrillic
        for k, armed in ((289, True), (290, True), (291, False)):     # command at 599 / 600 / 601
            self.reset_state()
            prompt = quote + "ж" * k + "закрывай"
            if armed:
                self.assert_armed(prompt)
            else:
                self.assert_not_armed(prompt)

    # --- a filtered mention behaves exactly like a neutral follow-up (pending / skip reflection) ---
    def state_after_followup(self, followup):
        self.reset_state()
        self.run_hook("закрывай сессию")
        self.run_hook(followup)
        intent = json.loads(self.intent.read_text()) if self.intent.exists() else None
        if intent:
            intent = {k: v for k, v in intent.items() if k not in ("created_at", "sentinel_ts", "recorded_at")}
        return (self.pending.exists(), None if self.PEER else self.obligation.exists(), intent)

    def test_mention_equals_neutral_followup(self):
        self.assertEqual(self.state_after_followup("Почему ты пишешь «закрывай»?"),
                         self.state_after_followup("Что нашли?"))

    def test_mention_with_skip_phrase_equals_neutral_skip(self):
        self.assertEqual(self.state_after_followup("Почему ты пишешь «закрывай»? рефлексии нет"),
                         self.state_after_followup("Что нашли? рефлексии нет"))

    def test_real_command_with_skip_phrase_still_records_skip(self):
        self.reset_state()
        self.run_hook("закрывай без рефлексии")
        self.assertTrue(self.intent.exists())
        self.assertTrue(json.loads(self.intent.read_text())["skip_reflection"])

    # --- the CLI contract itself, incl. the shared 600-character boundary ---
    def cli_answer(self, prompt):
        result = subprocess.run([sys.executable, FILTER, "--prompt-intends-close"], input=prompt,
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def valid_prefix(self, prompt, regex="закрывай|закрываю|закрой"):
        result = subprocess.run([sys.executable, FILTER, "--valid-prefix", regex], input=prompt,
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_cli_valid_prefix_skips_quoted_and_negated_mentions(self):
        self.assertEqual(self.valid_prefix("закрывай"), "0")
        self.assertEqual(self.valid_prefix("«закрывай» и закрывай"), "13")
        self.assertEqual(self.valid_prefix("не закрывай, потом закрывай"), "19")
        self.assertEqual(self.valid_prefix("Почему ты пишешь «закрывай»?"), "")
        self.assertEqual(self.valid_prefix("ничего"), "")

    def test_cli_leaves_the_paste_limit_to_the_hook(self):
        # The shell threshold (600, tested in test-close-gate-reminder-prefix-threshold.sh)
        # owns pasted-text handling; the filter must not veto it and change its side effects.
        self.assertEqual(self.cli_answer("ж" * 601 + "закрывай"), "yes")
        self.assertEqual(self.cli_answer("ж" * 600 + "закрывай"), "yes")

    def test_long_prefix_quote_keeps_the_rejected_quote_handling(self):
        # Regression found while wiring the filter: a >600-char paste with a skip phrase
        # must still end the pending reflection window without writing an intent record.
        self.run_hook("закрывай сессию")
        self.assertTrue(self.pending.exists())
        before = self.intent.read_bytes()
        self.run_hook("а" * 601 + "закрывай, рефлексия: Чужая цитата; заливай без рефлексии")
        self.assertFalse(self.pending.exists())
        self.assertEqual(self.intent.read_bytes(), before)


class PeerQuotedTriggerTests(QuotedTriggerTests):
    PEER = True


if __name__ == "__main__":
    unittest.main(argv=["quoted-trigger"], verbosity=2)
PY
