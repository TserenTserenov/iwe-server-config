#!/usr/bin/env python3
"""Synthetic test for scripts/host-memory-import.py (WP-529 F248).

Uses a local directory as the "other host" and a throwaway memory/ git repo,
then asserts which notes are imported, skipped, refused and reported.
Run: python3 scripts/tests/test_host_memory_import.py
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parent.parent / "host-memory-import.py"
GIT_ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True,
                          text=True, env=GIT_ENV).stdout


@unittest.skipUnless(shutil.which("gitleaks"), "gitleaks not installed")
class HostMemoryImportTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="host-memory-import-")
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        self.root = base / "root"
        (self.root / ".claude/memory-canon").mkdir(parents=True)
        (self.root / ".claude/memory-canon/protocol-close.md").write_text("canon\n")
        self.source = base / "other-host"
        self.source.mkdir()
        self.memory = base / "memory"
        self.memory.mkdir()
        git(self.memory, "init", "-q", "-b", "main")
        (self.memory / "shared.md").write_text("mac text\n")
        (self.memory / "deleted_here.md").write_text("old\n")
        git(self.memory, "add", "--", "shared.md", "deleted_here.md")
        git(self.memory, "commit", "-q", "-m", "init")
        git(self.memory, "rm", "-q", "--", "deleted_here.md")
        git(self.memory, "commit", "-q", "-m", "drop")
        self.runtime = base / "runtime"

    def put(self, name, text):
        (self.source / name).write_text(text)

    def run_tool(self, *extra):
        result = subprocess.run(
            ["python3", str(TOOL), "--root", str(self.root), "--memory", str(self.memory),
             "--runtime", str(self.runtime), "--source", f"{self.source}/", "--force", *extra],
            capture_output=True, text=True, env=GIT_ENV)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_only_never_seen_names_are_imported_and_committed(self):
        self.put("lessons_new.md", "new lesson\n")
        self.put("shared.md", "other host text\n")
        self.put("deleted_here.md", "old\n")
        self.put("protocol-close.md", "host copy of canon\n")
        self.put("MEMORY.md", "host index\n")
        result = self.run_tool()
        self.assertIn("перенесено 1", result.stdout)
        self.assertEqual((self.memory / "lessons_new.md").read_text(), "new lesson\n")
        self.assertEqual((self.memory / "shared.md").read_text(), "mac text\n")
        self.assertFalse((self.memory / "deleted_here.md").exists())
        self.assertFalse((self.memory / "protocol-close.md").exists())
        self.assertFalse((self.memory / "MEMORY.md").exists())
        self.assertIn("host-memory-import: 1", git(self.memory, "log", "-1", "--format=%s"))
        report = (self.runtime / "report.md").read_text()
        self.assertIn("## Есть на обоих хостах, на источнике есть строки, которых нет здесь (1)\n\n- shared.md",
                      report)

    def test_old_copy_of_note_rewritten_here_is_not_reported(self):
        (self.memory / "shared.md").write_text("rewritten here\n")
        git(self.memory, "commit", "-q", "-am", "rewrite")
        self.put("shared.md", "mac text\n")
        result = self.run_tool()
        self.assertIn("расходятся 0", result.stdout)

    def test_frontmatter_only_drift_is_not_reported(self):
        (self.memory / "dated.md").write_text("---\nupdated: 2026-10-01\n---\nbody\n")
        self.put("dated.md", "---\nupdated: 2026-11-01\ndescription: other\n---\nbody\n")
        result = self.run_tool()
        self.assertIn("расходятся 0", result.stdout)

    def test_note_with_secret_is_refused(self):
        self.put("reference_db.md", "url: postgresql://owner:Xk9vQ2mLp7Rt4Zs8Wn3Bd6Hy@ep-x.neon.tech/db\n"
                 "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n"
                 "token: ghp_aB3dE5fG7hI9jK1lM3nO5pQ7rS9tU1vW3xY5\n")
        result = self.run_tool()
        self.assertIn("отказ сканера 1", result.stdout)
        self.assertFalse((self.memory / "reference_db.md").exists())

    def test_note_changed_at_source_after_import_is_reported_not_overwritten(self):
        self.put("lessons_new.md", "v1\n")
        self.run_tool()
        self.put("lessons_new.md", "v2\n")
        result = self.run_tool()
        self.assertIn("изменены на источнике 1", result.stdout)
        self.assertEqual((self.memory / "lessons_new.md").read_text(), "v1\n")

    def test_dry_run_writes_nothing_to_memory(self):
        self.put("lessons_new.md", "new lesson\n")
        result = self.run_tool("--dry-run")
        self.assertIn("пробный прогон, перенесено 1", result.stdout)
        self.assertFalse((self.memory / "lessons_new.md").exists())

    def test_second_run_same_day_is_skipped_without_force(self):
        self.put("lessons_new.md", "new lesson\n")
        self.run_tool()
        result = subprocess.run(
            ["python3", str(TOOL), "--root", str(self.root), "--memory", str(self.memory),
             "--runtime", str(self.runtime), "--source", f"{self.source}/"],
            capture_output=True, text=True, env=GIT_ENV)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
