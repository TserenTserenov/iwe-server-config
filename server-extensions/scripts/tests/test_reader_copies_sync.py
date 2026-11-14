"""Tests for scripts/reader-copies-sync.py (WP-539): which reader copies move and which stay blocked."""

import importlib.util
import os
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


class CopyFixture(unittest.TestCase):
    """An origin and its clone; the clone has already fetched (the broker's job)."""

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


class SyncOneTest(CopyFixture):

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

    def add_upstream_file(self, name, text):
        (self.origin / name).parent.mkdir(parents=True, exist_ok=True)
        (self.origin / name).write_text(text)
        run(self.origin, "add", name)
        run(self.origin, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "add " + name)
        run(self.copy, "fetch", "-q", "origin")

    def test_identical_untracked_copy_does_not_block(self):
        """A writer that published elsewhere left a byte-equal copy behind (elar-window, 14.11)."""
        (self.copy / "w").mkdir()
        (self.copy / "w" / "day.md").write_text("same\n")
        self.add_upstream_file("w/day.md", "same\n")
        self.assertEqual(self.outcome(), "moved 1 (одинаковые локальные копии отложены в .git/reader-sync-parked: 1)")
        self.assertEqual(head(self.copy), head(self.origin))
        self.assertEqual((self.copy / "w" / "day.md").read_text(), "same\n")
        parked = list((self.copy / ".git" / "reader-sync-parked").rglob("day.md"))
        self.assertEqual([f.read_text() for f in parked], ["same\n"])  # set aside, never deleted

    def test_symlink_in_the_way_blocks(self):
        (self.copy / "real.md").write_text("same\n")
        (self.copy / "day.md").symlink_to("real.md")
        self.add_upstream_file("day.md", "same\n")
        before = head(self.copy)
        self.assertTrue(self.outcome().startswith("BLOCKED перемотка заменит"))
        self.assertTrue((self.copy / "day.md").is_symlink())
        self.assertEqual(head(self.copy), before)

    def test_file_changed_after_check_is_put_back(self):
        """A writer that rewrites the file between the check and the move: nothing moves, its bytes stay."""
        (self.copy / "day.md").write_text("same\n")
        self.add_upstream_file("day.md", "same\n")
        before = head(self.copy)
        real = sync.files_in_the_way

        def check_then_writer_rewrites(repo, target):
            result = real(repo, target)
            (self.copy / "day.md").write_text("rewritten by the writer\n")
            return result

        sync.files_in_the_way = check_then_writer_rewrites
        try:
            self.assertEqual(self.outcome(), "BLOCKED файл day.md изменился во время перемотки")
        finally:
            sync.files_in_the_way = real
        self.assertEqual((self.copy / "day.md").read_text(), "rewritten by the writer\n")
        self.assertEqual(head(self.copy), before)

    def test_differing_untracked_file_blocks_and_is_kept(self):
        (self.copy / "day.md").write_text("local edit\n")
        self.add_upstream_file("day.md", "upstream\n")
        before = head(self.copy)
        self.assertTrue(self.outcome().startswith("BLOCKED перемотка заменит игнорируемые или неотслеживаемые"))
        self.assertEqual(head(self.copy), before)
        self.assertEqual((self.copy / "day.md").read_text(), "local edit\n")

    def test_missing_upstream_ref_blocks(self):
        self.assertTrue(sync.sync_one(self.copy, "main", "origin/nope", False).startswith("BLOCKED нет ссылки"))

    def test_branch_switched_between_check_and_merge_blocks(self):
        """A manual checkout that lands after the first checks (no lock) is caught right before the merge."""
        self.advance_origin()
        before = head(self.copy)
        real = sync.files_in_the_way

        def switch_then_check(repo, target):
            run(self.copy, "switch", "-q", "-c", "topic")
            return real(repo, target)

        sync.files_in_the_way = switch_then_check
        try:
            self.assertEqual(self.outcome(), "BLOCKED ветка или HEAD сменились во время проверки")
        finally:
            sync.files_in_the_way = real
        self.assertEqual(head(self.copy), before)


class SharedLockTest(CopyFixture):
    """The Mac root (`shared_lock: ds-commit`): moved only while the shared lock is free."""

    def setUp(self):
        super().setUp()
        self.lock_file = Path(self.tmp.name) / "ds-commit.lock"
        self.old_env = os.environ.get("DS_COMMIT_LOCK_FILE")
        os.environ["DS_COMMIT_LOCK_FILE"] = str(self.lock_file)

    def tearDown(self):
        if self.old_env is None:
            os.environ.pop("DS_COMMIT_LOCK_FILE", None)
        else:
            os.environ["DS_COMMIT_LOCK_FILE"] = self.old_env
        super().tearDown()

    def shared_outcome(self):
        return sync.sync_shared(self.copy, Path(self.tmp.name), "main", "origin/main", False)

    def test_free_lock_moves(self):
        self.advance_origin()
        self.assertEqual(self.shared_outcome(), "moved 1")
        self.assertEqual(head(self.copy), head(self.origin))

    def test_busy_lock_skips_without_touching_copy(self):
        self.advance_origin()
        before = head(self.copy)
        holder = subprocess.Popen([sys.executable, "-c", (
            "import fcntl, sys, time\n"
            "f = open(sys.argv[1], 'a'); fcntl.flock(f, fcntl.LOCK_EX); print('held', flush=True); time.sleep(30)\n"
        ), str(self.lock_file)], stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(holder.stdout.readline().strip(), "held")
            self.assertTrue(self.shared_outcome().startswith("SKIP общий замок занят"))
        finally:
            holder.kill()
            holder.wait()
            holder.stdout.close()
        self.assertEqual(head(self.copy), before)


if __name__ == "__main__":
    unittest.main()
