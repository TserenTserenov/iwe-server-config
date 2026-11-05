#!/usr/bin/env python3
"""Tests for lib/style_rotation.py (WP-7 F299): lossless parts, hard cap, schedule."""

import json
import os
import subprocess
import sys
import tempfile
import unittest

LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib")
sys.path.insert(0, LIB)
import itertools

import style_rotation as sr
from platform_limits import HOOK_CONTEXT_HARD_CAP, PLATFORM_HOOK_CONTEXT_CHAR_LIMIT

PACK_DISPATCHER = os.path.expanduser(
    "~/IWE/PACK-rhetoric/pack/language-style/registry/dispatcher.py"
)


def synthetic_style():
    rules = ["# Стиль", "**Для кого:** все.", "## Базовые правила"]
    for n in range(1, 10):
        title = {
            6: "«Дальше:» - кто делает шаг",
            8: "Онтологическая чистота: роды",
        }.get(n, f"Правило {n}")
        body = "\n\n".join(
            f"Абзац {k} правила {n}. " + "текст " * 120
            for k in range(1, 4 if n != 8 else 12)
        )
        rules.append(f"{n}. **{title}.** {body}")
    return "\n".join(rules) + "\n"


def real_style():
    if not os.path.exists(PACK_DISPATCHER):
        return None
    out = subprocess.run(
        [
            sys.executable,
            PACK_DISPATCHER,
            "--event",
            "userpromptsubmit-ide",
            "--quiet",
            "--no-cache",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    return out.stdout or None


class PartsTest(unittest.TestCase):
    def check_text(self, text):
        parts, periods = sr.make_parts_with_periods(text)
        self.assertEqual(
            "".join(parts), text, "parts must concatenate to the source exactly"
        )
        self.assertTrue(
            all(len(p) <= sr.PART_MAX_CHARS for p in parts), [len(p) for p in parts]
        )
        self.assertEqual(len(parts), len(periods))
        return parts, periods

    def test_synthetic_lossless_and_sized(self):
        parts, _periods = self.check_text(synthetic_style())
        self.assertGreater(len(parts), 1)

    def test_oversize_rule_pieces_keep_priority(self):
        parts, periods = self.check_text(synthetic_style())
        for part, period in zip(parts, periods):
            if "правила 8" in part:
                self.assertEqual(period, sr.PRIORITY_PERIOD, part[:80])

    def test_priority_not_triggered_by_mentions(self):
        text = "1. **Обычное правило.** пример со словом A12 и «Дальше:» внутри\n"
        _, periods = sr.make_parts_with_periods(text)
        self.assertEqual(periods, [sr.DEFAULT_PERIOD])

    def test_real_pack_style_if_available(self):
        text = real_style()
        if text is None:
            self.skipTest("PACK-rhetoric dispatcher not available")
        self.check_text(text)


class ScheduleTest(unittest.TestCase):
    def test_warmup_then_priority_every_three(self):
        periods = [12, 3, 12, 3, 12]
        last = [None] * len(periods)
        sent = []
        for turn in range(1, 61):
            index = sr.choose_part(turn, last, periods)
            sent.append(index)
            if index is not None:
                last[index] = turn
        self.assertEqual(sent[:5], [0, 1, 2, 3, 4])
        for k, period in enumerate(periods):
            turns = [t + 1 for t, i in enumerate(sent) if i == k and t >= 5]
            gaps = [b - a for a, b in itertools.pairwise(turns)]
            self.assertTrue(gaps, f"part {k} never repeated")
            self.assertLessEqual(max(gaps), period + 2, f"part {k} gaps {gaps}")


class CliTest(unittest.TestCase):
    def run_turns(self, text, turns, hint):
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "src.md")
            with open(src, "w", encoding="utf-8") as handle:
                handle.write(text)
            outputs = []
            env = dict(os.environ, STYLE_PREFIX="A0 " * 140, STYLE_SUFFIX=hint)
            for turn in range(1, turns + 1):
                res = subprocess.run(
                    [
                        sys.executable,
                        os.path.join(LIB, "style_rotation.py"),
                        "--source",
                        src,
                        "--state",
                        os.path.join(tmp, "st.json"),
                        "--turn",
                        str(turn),
                        "--log",
                        os.path.join(tmp, "log.tsv"),
                    ],
                    capture_output=True,
                    text=True,
                    env=env,
                    check=True,
                )
                outputs.append(res.stdout)
            with open(os.path.join(tmp, "log.tsv"), encoding="utf-8") as handle:
                log = [line.rstrip("\n").split("\t") for line in handle]
            return outputs, log

    def test_output_never_exceeds_cap_and_all_parts_delivered(self):
        text = synthetic_style()
        parts = sr.make_parts(text)
        outputs, log = self.run_turns(text, 40, hint="подсказка " * 300)
        self.assertLess(HOOK_CONTEXT_HARD_CAP, PLATFORM_HOOK_CONTEXT_CHAR_LIMIT)
        self.assertTrue(
            all(len(o) <= HOOK_CONTEXT_HARD_CAP for o in outputs),
            max(len(o) for o in outputs),
        )
        delivered = {row[3].split("/")[0] for row in log if not row[3].startswith("-")}
        self.assertEqual(delivered, {str(k + 1) for k in range(len(parts))})
        for k, part in enumerate(parts):
            self.assertTrue(
                any(part in o for o in outputs), f"part {k + 1} never delivered whole"
            )

    def test_oversize_prefix_defers_part_instead_of_cutting(self):
        text = synthetic_style()
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "src.md")
            state = os.path.join(tmp, "st.json")
            with open(src, "w", encoding="utf-8") as handle:
                handle.write(text)
            env = dict(
                os.environ,
                STYLE_PREFIX="A" * (HOOK_CONTEXT_HARD_CAP - 300),
                STYLE_SUFFIX="",
            )
            res = subprocess.run(
                [
                    sys.executable,
                    os.path.join(LIB, "style_rotation.py"),
                    "--source",
                    src,
                    "--state",
                    state,
                    "--turn",
                    "1",
                ],
                capture_output=True,
                text=True,
                env=env,
                check=True,
            )
            self.assertLessEqual(len(res.stdout), HOOK_CONTEXT_HARD_CAP)
            self.assertIn("deferred", res.stderr)
            with open(state, encoding="utf-8") as handle:
                self.assertEqual(
                    json.load(handle)["last_sent"][0],
                    None,
                    "deferred part must stay due",
                )

    def run_cli(self, tmp, prefix, turn=None):
        cmd = [
            sys.executable,
            os.path.join(LIB, "style_rotation.py"),
            "--source",
            os.path.join(tmp, "src.md"),
            "--state",
            os.path.join(tmp, "st.json"),
            "--log",
            os.path.join(tmp, "log.tsv"),
        ]
        if turn is not None:
            cmd += ["--turn", str(turn)]
        env = dict(os.environ, STYLE_PREFIX=prefix, STYLE_SUFFIX="")
        return subprocess.run(cmd, capture_output=True, text=True, env=env, check=True)

    def test_deferred_oversize_recovery_and_turn_counter_in_state(self):
        text = synthetic_style()
        parts = sr.make_parts(text)
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "src.md"), "w", encoding="utf-8") as handle:
                handle.write(text)
            for _ in range(3):
                res = self.run_cli(tmp, "A" * (HOOK_CONTEXT_HARD_CAP - 300))
                self.assertNotIn(
                    parts[0], res.stdout, "a deferred part must not be sent, even cut"
                )
            res = self.run_cli(tmp, "A0")
            self.assertIn(
                parts[0], res.stdout, "the deferred part goes out once there is room"
            )
            self.assertTrue(res.stdout.rstrip().endswith(sr.BLOCK_END))
            self.assertLessEqual(
                len(res.stdout),
                HOOK_CONTEXT_HARD_CAP,
                "closing mark included in the cap",
            )
            with open(os.path.join(tmp, "st.json"), encoding="utf-8") as handle:
                state = json.load(handle)
            self.assertEqual(
                state["turn"], 4, "turn counter lives in the rotation state"
            )
            self.assertEqual(state["last_sent"][0], 4)
            with open(os.path.join(tmp, "log.tsv"), encoding="utf-8") as handle:
                modes = [line.split("\t")[5] for line in handle]
            self.assertEqual(modes, ["deferred-oversize"] * 3 + ["inline"])

    def test_source_change_restarts_warmup(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = os.path.join(tmp, "st.json")
            with open(state, "w", encoding="utf-8") as handle:
                json.dump({"src": "old", "last_sent": [1, 2]}, handle)
            fresh = sr.load_state(state, "new", 3)
            self.assertEqual(fresh["last_sent"], [None, None, None])


if __name__ == "__main__":
    unittest.main(verbosity=2)
