#!/usr/bin/env python3
"""Tests for scripts/hot-budget-ratchet.py (WP-7 F299, block 5) on a throwaway git repo."""

import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "hot-budget-ratchet.py"
)
GIT_ENV = dict(
    os.environ,
    GIT_AUTHOR_NAME="t",
    GIT_AUTHOR_EMAIL="t@t",
    GIT_COMMITTER_NAME="t",
    GIT_COMMITTER_EMAIL="t@t",
)


class RatchetTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name
        self.git("init", "-q")
        os.makedirs(os.path.join(self.repo, ".claude", "rules", "memory"))
        self.write("CLAUDE.md", "x" * 1000)
        self.write(".claude/rules/a.md", "y" * 500)
        self.write("other.md", "z" * 10)
        self.base = self.commit("base")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", self.repo, *args],
            capture_output=True,
            text=True,
            check=True,
            env=GIT_ENV,
        ).stdout.strip()

    def write(self, rel, text):
        with open(os.path.join(self.repo, rel), "w", encoding="utf-8") as handle:
            handle.write(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def check(self, *extra, waiver=None):
        args = [
            sys.executable,
            SCRIPT,
            "check",
            "--repo",
            self.repo,
            "--base",
            self.base,
            "--head",
            "HEAD",
            *extra,
        ]
        if waiver is not None:
            path = os.path.join(self.repo, "..", "waiver.txt")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(waiver)
            args += ["--waiver-text-file", path]
        res = subprocess.run(args, capture_output=True, text=True, check=False)
        return res.returncode, res.stdout

    def test_growth_fails_and_nested_rules_count(self):
        self.write(".claude/rules/memory/cold.md", "n" * 50)
        self.commit("grow nested")
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn("+50", out)

    def test_one_for_one_eviction_passes(self):
        self.write("CLAUDE.md", "x" * 900)
        self.write(".claude/rules/b.md", "w" * 100)
        self.commit("swap")
        code, out = self.check()
        self.assertEqual(code, 0, out)

    def test_non_hot_files_are_ignored(self):
        self.write("other.md", "z" * 5000)
        self.commit("other")
        code, out = self.check()
        self.assertEqual(code, 0, out)

    def test_waiver_needs_reason_and_review_date(self):
        self.write("CLAUDE.md", "x" * 1100)
        self.commit("grow")
        self.assertEqual(self.check("--waiver-label", waiver="просто так")[0], 1)
        self.assertEqual(
            self.check(waiver="Причина: срочно\nПересмотр: 2026-12-01")[0], 1
        )  # no label/trailer
        code, out = self.check(
            "--waiver-label",
            waiver="Причина: срочный фикс безопасности\nПересмотр: 2026-12-01",
        )
        self.assertEqual(code, 0, out)
        self.assertTrue(out.startswith("WAIVED"), out)
        trailer = "Hot-Budget-Waiver: да\nПричина: срочно\nПересмотр: 2026-12-01"
        self.assertEqual(self.check(waiver=trailer)[0], 0)

    def test_big_rewrite_above_m2(self):
        lines = ["q" * 99] * 400  # ~40 KB, about 12.9K tokens: above the M2 target
        self.write("CLAUDE.md", "\n".join(lines) + "\n")
        self.base = self.commit("big core above 12K tokens")
        self.write("CLAUDE.md", "\n".join(["r" * 99] * 400) + "\n")
        self.commit("same size rewrite")
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.base = self.git("rev-parse", "HEAD")
        self.write("CLAUDE.md", "\n".join(["r" * 99] * 399 + ["s" * 99]) + "\n")
        self.commit("small fix of one line")
        code, out = self.check()
        self.assertEqual(code, 0, out)

    def test_nested_rewrite(self):
        self.write("CLAUDE.md", "\n".join(["q" * 99] * 400) + "\n")
        self.write(".claude/rules/memory/cold.md", "\n".join(["a" * 99] * 5) + "\n")
        self.base = self.commit("big core with nested rules")
        self.write(".claude/rules/memory/cold.md", "\n".join(["b" * 99] * 5) + "\n")
        self.commit("rewrite nested file, same size")
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn(
            "изменено 990 байт", out
        )  # 10 changed lines of 99 bytes, newlines excluded

    def test_empty_reason_is_rejected(self):
        self.write("CLAUDE.md", "x" * 1100)
        self.commit("grow")
        code, _ = self.check("--waiver-label", waiver="Причина:\nПересмотр: 2026-12-01")
        self.assertEqual(code, 1)

    def test_separator_lines_count_as_change(self):
        self.write("CLAUDE.md", "\n".join(["q" * 99] * 400 + ["---"] * 100) + "\n")
        self.base = self.commit("big core with separators")
        self.write("CLAUDE.md", "\n".join(["q" * 99] * 400 + ["+++"] * 100) + "\n")
        self.commit("separators rewritten")
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn(
            "изменено 600 байт", out
        )  # 100 removed "---" + 100 added "+++", 3 bytes each

    def test_staged_mode_checks_the_index(self):
        self.base = "HEAD"
        self.write("CLAUDE.md", "x" * 1001)
        self.git("add", "CLAUDE.md")
        code, out = self.check_staged()
        self.assertEqual(code, 1, out)
        self.write("CLAUDE.md", "x" * 900)
        self.git("add", "CLAUDE.md")
        self.write("CLAUDE.md", "x" * 5000)  # unstaged growth is not part of the commit
        code, out = self.check_staged()
        self.assertEqual(code, 0, out)
        self.assertIn("(-100)", out)

    def test_staged_deletion_counts_as_freed(self):
        self.base = "HEAD"
        self.git("rm", "-q", "--cached", ".claude/rules/a.md")
        self.write("CLAUDE.md", "x" * 1400)
        self.git("add", "CLAUDE.md")
        code, out = self.check_staged()
        self.assertEqual(code, 0, out)
        self.assertIn("1500 → 1400", out)

    def check_staged(self):
        args = [
            sys.executable,
            SCRIPT,
            "check",
            "--repo",
            self.repo,
            "--base",
            "HEAD",
            "--head",
            ":staged",
        ]
        res = subprocess.run(args, capture_output=True, text=True, check=False)
        return res.returncode, res.stdout


if __name__ == "__main__":
    unittest.main(verbosity=2)
