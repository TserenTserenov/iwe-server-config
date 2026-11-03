"""Tests for scripts/reader-copies-sync.py (WP-539): which reader copies move and which stay blocked."""

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))
_spec = importlib.util.spec_from_file_location("reader_copies_sync", SCRIPTS / "reader-copies-sync.py")
sync = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sync)


def run(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True)


def head(repo):
    return subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], check=True,
                          capture_output=True, text=True).stdout.strip()


class SyncOneTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.origin, self.copy = base / "origin", base / "copy"
        run(base, "init", "-q", "-b", "main", str(self.origin))
        (self.origin / "f.txt").write_text("v1\n")
        run(self.origin, "add", "f.txt")
        run(self.origin, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "one")
        run(base, "clone", "-q", str(self.origin), str(self.copy))

    def tearDown(self):
        self.tmp.cleanup()

    def advance_origin(self):
        """A new upstream commit, already fetched into the copy (the broker's job)."""
        run(self.origin, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "two")
        run(self.copy, "fetch", "-q", "origin")

    def outcome(self, dry_run=False):
        return sync.sync_one(self.copy, "main", "origin/main", dry_run)

    def test_current_stays(self):
        self.assertEqual(self.outcome(), "current")

    def test_behind_moves(self):
        self.advance_origin()
        self.assertEqual(self.outcome(), "moved 1")
        self.assertEqual(head(self.copy), head(self.origin))

    def test_dry_run_only_reports(self):
        self.advance_origin()
        before = head(self.copy)
        self.assertEqual(self.outcome(dry_run=True), "would move 1")
        self.assertEqual(head(self.copy), before)

    def test_dirty_blocks(self):
        self.advance_origin()
        (self.copy / "f.txt").write_text("local edit\n")
        self.assertTrue(self.outcome().startswith("BLOCKED незакоммиченные правки"))
        self.assertEqual((self.copy / "f.txt").read_text(), "local edit\n")

    def test_own_commit_blocks(self):
        self.advance_origin()
        run(self.copy, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "mine")
        before = head(self.copy)
        self.assertTrue(self.outcome().startswith("BLOCKED свои коммиты"))
        self.assertEqual(head(self.copy), before)

    def test_other_branch_blocks(self):
        run(self.copy, "switch", "-q", "-c", "topic")
        self.assertEqual(self.outcome(), "BLOCKED ветка topic вместо main")

    def test_paused_merge_blocks(self):
        self.advance_origin()
        Path(self.copy, ".git", "CHERRY_PICK_HEAD").write_text(head(self.copy) + "\n")
        self.assertEqual(self.outcome(), "BLOCKED незавершённая операция git (CHERRY_PICK_HEAD)")

    def test_skip_worktree_blocks(self):
        self.advance_origin()
        run(self.copy, "update-index", "--skip-worktree", "f.txt")
        self.assertTrue(self.outcome().startswith("BLOCKED есть файлы со скрытыми правками"))

    def test_ignored_file_kept(self):
        """An ignored local file that upstream starts tracking would be replaced silently: block."""
        (self.copy / ".git" / "info").mkdir(exist_ok=True)  # templates may omit info/
        (self.copy / ".git" / "info" / "exclude").write_text("new.txt\n")
        (self.copy / "new.txt").write_text("local\n")
        (self.origin / "new.txt").write_text("upstream\n")
        run(self.origin, "add", "-f", "new.txt")
        run(self.origin, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "add")
        run(self.copy, "fetch", "-q", "origin")
        self.assertTrue(self.outcome().startswith("BLOCKED перемотка заменит игнорируемые"))
        self.assertEqual((self.copy / "new.txt").read_text(), "local\n")

    def test_missing_upstream_ref_blocks(self):
        self.assertTrue(sync.sync_one(self.copy, "main", "origin/nope", False).startswith("BLOCKED нет ссылки"))


if __name__ == "__main__":
    unittest.main()
