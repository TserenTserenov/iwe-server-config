#!/usr/bin/env bash
# WP-484 F337 (26.11.2026): live cases 22.11 and 25.11, the close asked about reflection
# although the pilot had said «ПСЗ» earlier.
#   A) the shorthand filter misses common forms (first word with a clarification,
#      connective «то», clarification after the last-word shorthand);
#   B) a later message without reflection text («чини и закрывай») erased the recorded skip.
# Usage: bash test-close-gate-reminder-psz-forms.sh [a12-filter] [close_obligation.py]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER="${1:-$HERE/a12-unsolicited-close.py}"
CLOSE_CLI="${2:-$HOME/IWE/DS-my-strategy/scripts/close_obligation.py}"
PYTHONDONTWRITEBYTECODE=1 python3 - "$FILTER" "$CLOSE_CLI" <<'PY'
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

FILTER, CLOSE_CLI = (str(Path(v).resolve(strict=True)) for v in sys.argv[1:])
spec = importlib.util.spec_from_file_location("a12", FILTER)
a12 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a12)


class ShorthandForms(unittest.TestCase):
    def test_recognised(self):
        for text in (
            "ПСЗ",
            "ПСЗ субагентом Fable",
            "ПСЗ, остальное в новой сессии",
            "если все ок, то ПСЗ",
            "если тут все. то ПСЗ субагентом fable",
            "вноси и потом ПСЗ",
        ):
            with self.subTest(text=text):
                self.assertEqual(a12.pilot_shorthand(text)[0], "psz")

    def test_refused(self):
        for text in (
            "ты не понял ПСЗ субагентом",
            "без ПСЗ",
            "ПСЗ не надо",
            "ПСЗ отменяется",
            "ПСЗ отбой",
            "ПСЗ выполнен",
            "ПСЗ это что такое",
            "ПСЗ нельзя",
            "ПСЗ, но сперва покажи дифф",
            "СЗ расшифруй",
            "то ПСЗ",
            "ПСЗ, остальное ты понял неправильно",
            "ПСЗ, остальное не трогай и вообще стоп",
            "лог хука:\nmatched shorthand: ПСЗ субагентом",
            "stdout:\nkind=psz form=trailing\nПСЗ субагентом kimi",
            "объясни разницу между СЗ и ПСЗ",
            "А тут все? если да, то сделай ПСЗ",
        ):
            with self.subTest(text=text):
                self.assertEqual(a12.pilot_shorthand(text), ("", ""))


class SkipSurvivesLaterMessage(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="f337-")
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("IWE_", "CLAUDE_", "GIT_"))}
        self.env.update(IWE_ROOT=str(root), IWE_RUNTIME_DIR=str(root / ".iwe-runtime"),
                        IWE_LEDGER_DIR=str(root / "ledger"), IWE_PROCESS_CARDS_DIR=str(root / "cards"),
                        PYTHONDONTWRITEBYTECODE="1")
        self.cli = root / "DS-my-strategy/scripts/close_obligation.py"
        self.cli.parent.mkdir(parents=True)
        shutil.copy(CLOSE_CLI, self.cli)
        source_dir = Path(CLOSE_CLI).parent
        for module in ("session_local_release.py", "close_expect.py",
                       "lib/ledger_path.py", "lib/ledger-event-diff.py"):
            target = self.cli.parent / module
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(source_dir / module, target)
        self.sid = "f337-" + uuid.uuid4().hex

    def record(self, raw_text, skip, keep="false"):
        subprocess.run([sys.executable, str(self.cli), "record-intent", "--session-id", self.sid,
                        "--raw-text", raw_text, "--skip-reflection", skip, "--keep-skip", keep],
                       env=self.env, check=True, capture_output=True, text=True)

    def read_skip(self):
        out = subprocess.run([sys.executable, str(self.cli), "read-intent", "--session-id", self.sid],
                             env=self.env, check=True, capture_output=True, text=True).stdout
        return json.loads(out)["skip_reflection"]

    def test_keep_flag_preserves_skip(self):
        self.record("", "true")
        self.record("", "false", keep="true")
        self.assertTrue(self.read_skip())

    def test_without_keep_flag_skip_is_replaced(self):
        # A message that mentions reflection itself arrives without the flag.
        self.record("", "true")
        self.record("", "false")
        self.assertFalse(self.read_skip())

    def test_explicit_reflection_text_replaces_skip(self):
        self.record("", "true")
        self.record("итог: всё получилось", "false")
        self.assertFalse(self.read_skip())

    def test_no_previous_skip_stays_false(self):
        self.record("", "false", keep="true")
        self.assertFalse(self.read_skip())

    def test_cancel_close_drops_skip_even_without_an_armed_obligation(self):
        # «ПСЗ» arms nothing; the cancel that follows finds no obligation but must reset the skip.
        self.record("", "true")
        subprocess.run([sys.executable, str(self.cli), "cancel", "--session-id", self.sid,
                        "--action", "cancel-close", "--reason", "test"],
                       env=self.env, check=True, capture_output=True, text=True)
        self.record("", "false", keep="true")
        self.assertFalse(self.read_skip())

    def test_damaged_previous_file_does_not_crash_the_record(self):
        self.record("", "true")
        intent_dir = Path(self.env["IWE_RUNTIME_DIR"]) / "close-intent-records"
        for damaged in intent_dir.glob("*.json"):
            damaged.write_text("{not json")
        self.record("", "false", keep="true")
        self.assertFalse(self.read_skip())


unittest.main(argv=["psz-forms"], verbosity=1)
PY
