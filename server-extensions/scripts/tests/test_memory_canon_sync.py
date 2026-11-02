#!/usr/bin/env python3
"""Synthetic-repo test for scripts/memory-canon-sync.py (WP-529 F248).

Builds a throwaway origin + root clone with .claude/memory-canon/, a memory/
git repo, and asserts which copies the tool rewrites and which it leaves.
Run: python3 scripts/tests/test_memory_canon_sync.py
"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parent.parent / "memory-canon-sync.py"
GIT_ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True,
                          text=True, env=GIT_ENV).stdout


class MemoryCanonSyncTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="memory-canon-sync-")
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        self.origin = base / "origin.git"
        git(base, "init", "-q", "--bare", "-b", "main", str(self.origin))
        self.root = base / "root"
        git(base, "clone", "-q", str(self.origin), str(self.root))
        self.memory = base / "memory"
        self.memory.mkdir()
        git(self.memory, "init", "-q", "-b", "main")
        git(self.memory, "commit", "-q", "--allow-empty", "-m", "init")
        self.state = base / "state.tsv"

    def publish(self, name, text):
        path = self.root / ".claude/memory-canon" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        git(self.root, "add", "--", str(path))
        git(self.root, "commit", "-q", "-m", f"canon {name}")
        git(self.root, "push", "-q", "origin", "main")

    def run_tool(self):
        result = subprocess.run(
            ["python3", str(TOOL), "--root", str(self.root), "--memory", str(self.memory),
             "--state", str(self.state)],
            capture_output=True, text=True, env=GIT_ENV)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_missing_copy_is_written_and_committed(self):
        self.publish("protocol-close.md", "v1\n")
        result = self.run_tool()
        self.assertEqual((self.memory / "protocol-close.md").read_text(), "v1\n")
        self.assertIn("обновлено 1", result.stdout)
        self.assertIn("memory-canon-sync", git(self.memory, "log", "-1", "--format=%s"))

    def test_untouched_copy_follows_new_canon(self):
        self.publish("protocol-close.md", "v1\n")
        self.run_tool()
        self.publish("protocol-close.md", "v2\n")
        self.run_tool()
        self.assertEqual((self.memory / "protocol-close.md").read_text(), "v2\n")

    def test_hand_edit_is_left_alone(self):
        self.publish("protocol-close.md", "v1\n")
        self.run_tool()
        (self.memory / "protocol-close.md").write_text("v1\nlocal edit\n")
        self.publish("protocol-close.md", "v2\n")
        result = self.run_tool()
        self.assertEqual((self.memory / "protocol-close.md").read_text(), "v1\nlocal edit\n")
        self.assertIn("правка мимо канона", result.stderr)

    def test_first_run_accepts_copy_of_older_canon_only(self):
        self.publish("protocol-close.md", "v1\n")
        self.publish("protocol-work.md", "w1\n")
        (self.memory / "protocol-close.md").write_text("v1\n")
        (self.memory / "protocol-work.md").write_text("never in canon\n")
        self.publish("protocol-close.md", "v2\n")
        self.publish("protocol-work.md", "w2\n")
        result = self.run_tool()
        self.assertEqual((self.memory / "protocol-close.md").read_text(), "v2\n")
        self.assertEqual((self.memory / "protocol-work.md").read_text(), "never in canon\n")
        self.assertIn("обновлено 1, остановлено 1", result.stdout)

    def test_unpublished_canon_commit_is_not_used(self):
        self.publish("protocol-close.md", "v1\n")
        self.run_tool()
        path = self.root / ".claude/memory-canon/protocol-close.md"
        path.write_text("local only\n")
        git(self.root, "commit", "-q", "-am", "not pushed")
        self.run_tool()
        self.assertEqual((self.memory / "protocol-close.md").read_text(), "v1\n")

    def test_git_failure_leaves_memory_untouched(self):
        (self.memory / "protocol-close.md").write_text("keep\n")
        result = self.run_tool()  # no canon published: origin/main does not exist yet
        self.assertEqual((self.memory / "protocol-close.md").read_text(), "keep\n")
        self.assertIn("память не тронута", result.stderr)


if __name__ == "__main__":
    unittest.main()
