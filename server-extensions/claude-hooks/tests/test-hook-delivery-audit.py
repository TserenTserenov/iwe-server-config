#!/usr/bin/env python3
"""Tests for scripts/hook-delivery-audit.py (WP-7 F299) on synthetic transcripts."""

import datetime
import json
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..",
    "..",
    "..",
    "scripts",
    "hook-delivery-audit.py",
)
NOW = datetime.datetime.now(datetime.timezone.utc)  # noqa: UP017


def record(session, minutes_ago, text):
    when = (NOW - datetime.timedelta(minutes=minutes_ago)).strftime(
        "%Y-%m-%dT%H:%M:%S.000Z"
    )
    attachment = {
        "type": "hook_additional_context",
        "content": [text],
        "hookName": "UserPromptSubmit",
    }
    return json.dumps(
        {
            "type": "attachment",
            "sessionId": session,
            "timestamp": when,
            "attachment": attachment,
        }
    )


def persisted(head):
    return f"<persisted-output>\nOutput too large (26.4KB). Full output saved to: /x\n\nPreview (first 2KB):\n{head}\nтекст"


def run(lines):
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "proj"))
        with open(
            os.path.join(tmp, "proj", "s.jsonl"), "w", encoding="utf-8"
        ) as handle:
            handle.write("\n".join(lines) + "\n")
        res = subprocess.run(
            [sys.executable, SCRIPT, "--projects-dir", tmp, "--json"],
            capture_output=True,
            text=True,
            check=False,
        )
        return res.returncode, json.loads(res.stdout)


class AuditTest(unittest.TestCase):
    def test_all_inline_pass(self):
        code, report = run(
            [record("s1", m, "Главное правило\nтекст") for m in range(1, 30)]
        )
        self.assertEqual((code, report["verdict"], report["persisted"]), (0, "PASS", 0))
        self.assertEqual(report["injections"], 29)

    def test_single_persisted_is_warning(self):
        lines = [record("s1", m, "Главное правило\nтекст") for m in range(2, 40)]
        lines.append(record("s1", 1, persisted("## Стиль")))
        code, report = run(lines)
        self.assertEqual((code, report["verdict"]), (0, "WARN"))
        self.assertEqual(report["persisted_chars"], int(26.4 * 1024))

    def test_single_persisted_in_small_sample_is_still_warning(self):
        lines = [record("s1", m, "Главное правило\nтекст") for m in range(2, 11)]
        lines.append(record("s1", 1, persisted("## Стиль")))
        code, report = run(lines)
        self.assertGreater(report["persisted_ratio"], 0.05)
        self.assertEqual((code, report["verdict"]), (0, "WARN"))

    def test_streak_of_three_fails_even_below_ratio(self):
        lines = [record("s1", m, "Главное правило\nтекст") for m in range(10, 200)]
        lines += [record("s2", m, persisted("## Стиль")) for m in (3, 2, 1)]
        code, report = run(lines)
        self.assertLess(report["persisted_ratio"], 0.05)
        self.assertEqual(
            (code, report["verdict"], report["persisted_streak_max"]), (1, "FAIL", 3)
        )

    def test_inline_resets_streak_and_old_records_ignored(self):
        lines = [
            record("s1", 3000, persisted("## Стиль")) for _ in range(5)
        ]  # older than 24h
        lines += [record("s1", m, "## Стиль\nтекст") for m in range(30, 60)]
        lines += [
            record("s1", 5, persisted("## Стиль")),
            record("s1", 4, "## Стиль\nтекст"),
            record("s1", 3, persisted("## Стиль")),
        ]
        code, report = run(lines)
        self.assertEqual(code, 1)
        self.assertEqual(report["persisted"], 2)
        self.assertEqual(report["persisted_streak_max"], 1)
        self.assertEqual(report["verdict"], "FAIL")  # 2 of 33 > 5 %


if __name__ == "__main__":
    unittest.main(verbosity=2)
