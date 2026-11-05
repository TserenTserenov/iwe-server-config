#!/usr/bin/env python3
"""Tests for scripts/rule-usefulness.py (WP-7 F299, block 2) on fixture rules and journal."""

import json
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "rule-usefulness.py"
)


def rule(path, rule_id, criticality, review, status="active"):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(
            f"---\nid: {rule_id}\ntype: behavioural\npriority: 6\ncriticality: {criticality}\n"
            f"criticality_review: {review}\nstatus: {status}\n---\n\n# {rule_id}\n"
        )


def journal(directory, day, events):
    with open(os.path.join(directory, f"{day}.jsonl"), "a", encoding="utf-8") as handle:
        handle.writelines(
            json.dumps({"ts": f"{day}T10:00:00Z", "rule": rule_id, "verdict": verdict})
            + "\n"
            for rule_id, verdict in events
        )


class UsefulnessTest(unittest.TestCase):
    def run_report(self, days=20):
        with tempfile.TemporaryDirectory() as tmp:
            rules, logs, root = (
                os.path.join(tmp, d) for d in ("rules", "logs", "root")
            )
            for d in (rules, logs, os.path.join(root, ".claude", "rules", "memory")):
                os.makedirs(d)
            rule(
                os.path.join(rules, "AR.001-a.md"), "AR.001", "C2", "confirmed"
            )  # quiet, confirmed -> candidate
            rule(
                os.path.join(rules, "AR.002-b.md"), "AR.002", "C2", "auto"
            )  # quiet but auto -> not
            rule(
                os.path.join(rules, "AR.003-c.md"), "AR.003", "C2", "confirmed"
            )  # prevents -> not
            rule(
                os.path.join(rules, "AR.004-d.md"), "AR.004", "C1", "confirmed"
            )  # safety -> not
            rule(
                os.path.join(rules, "AR.005-e.md"), "AR.005", "C2", "confirmed"
            )  # no data -> not
            rule(
                os.path.join(rules, "AR.006-f.md"),
                "AR.006",
                "C2",
                "confirmed",
                status="draft",
            )
            rule(
                os.path.join(rules, "AR.007-g.md"), "AR.007", "C2", "confirmed"
            )  # quiet but seen only lately
            for n in range(days):
                day = f"2026-10-{n + 1:02d}"
                if n >= days - 3:
                    journal(logs, day, [("AR.007", "ok")])
                journal(
                    logs,
                    day,
                    [
                        ("AR.001", "ok"),
                        ("AR.002", "ok"),
                        ("AR.003", "block"),
                        ("AR.004", "ok"),
                        ("AR.006", "ok"),
                    ],
                )
            with open(
                os.path.join(logs, "2026-10-01-classified.jsonl"), "w", encoding="utf-8"
            ) as handle:
                handle.write(
                    json.dumps({"rule": "AR.001", "verdict": "block"}) + "\n"
                )  # derived copy, ignored
            with open(os.path.join(root, "CLAUDE.md"), "w", encoding="utf-8") as handle:
                handle.write("правило AR.003 в ядре\nещё раз AR.003 и AR.001\n")
            nested = os.path.join(root, ".claude", "rules", "memory", "cold.md")
            with open(nested, "w", encoding="utf-8") as handle:
                handle.write("вложенный файл правил тоже горячий: AR.003\n")
            res = subprocess.run(
                [
                    sys.executable,
                    SCRIPT,
                    "--rules-dir",
                    rules,
                    "--journal-dir",
                    logs,
                    "--root",
                    root,
                    "--json",
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            report = json.loads(res.stdout)
            return report["journal_days"], {r["id"]: r for r in report["rules"]}

    def test_only_quiet_confirmed_active_c2_with_data_is_candidate(self):
        days, rows = self.run_report()
        self.assertEqual(days, 20)
        self.assertEqual({k for k, r in rows.items() if r["candidate"]}, {"AR.001"})

    def test_counts_ignore_classified_copies_and_count_hot_mentions(self):
        _, rows = self.run_report()
        self.assertEqual(
            (rows["AR.001"]["exposures"], rows["AR.001"]["prevented"]), (20, 0)
        )
        self.assertEqual(
            (rows["AR.003"]["prevented"], rows["AR.003"]["hot_mentions"]), (20, 3)
        )
        self.assertEqual(rows["AR.005"]["data_status"], "none")
        self.assertEqual(
            (rows["AR.007"]["observed_days"], rows["AR.007"]["candidate"]), (3, False)
        )

    def test_short_journal_gives_no_candidates(self):
        _, rows = self.run_report(days=5)
        self.assertFalse(any(r["candidate"] for r in rows.values()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
