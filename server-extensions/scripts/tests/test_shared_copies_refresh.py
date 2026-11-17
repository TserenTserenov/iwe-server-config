"""WP-484, bug-2026-11-17-multiline-note-file-claim-blocks-product-receipt.md, fix 5.

A shared server copy (PACK-*, bot docs) that someone switched to another branch must go back to
main, but only when that loses nothing: clean tree, no half-finished git operation, and the
current tip already contained in the upstream ref.
"""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))
_spec = importlib.util.spec_from_file_location("shared_copies_refresh", SCRIPTS / "shared-copies-refresh.py")
refresh = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(refresh)

ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def git(repo, *args):
    done = subprocess.run(["git", "-C", str(repo), *args], check=False, capture_output=True, text=True, env=ENV)
    assert done.returncode == 0, f"git {' '.join(args)} failed: {done.stderr}"
    return done.stdout.strip()


class SharedCopyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(base / "origin.git")], check=True)
        self.repo = base / "PACK-x"
        subprocess.run(["git", "clone", "-q", str(base / "origin.git"), str(self.repo)],
                       check=True, capture_output=True)
        (self.repo / "f.md").write_text("seed\n")
        git(self.repo, "add", "f.md")
        git(self.repo, "commit", "-q", "-m", "seed")
        git(self.repo, "push", "-q", "origin", "HEAD:main")
        git(self.repo, "fetch", "-q", "origin")
        git(self.repo, "branch", "-q", "feature")  # same tip as origin/main

    def branch(self):
        return git(self.repo, "branch", "--show-current")

    def heal(self, dry_run=False):
        return refresh.heal_one(self.repo, "main", "origin/main", dry_run)

    def test_already_on_main_is_left_alone(self):
        self.assertEqual(self.heal(), "current")

    def test_clean_foreign_branch_with_tip_on_origin_returns_to_main(self):
        git(self.repo, "switch", "-q", "feature")
        self.assertEqual(self.heal(), "returned feature")
        self.assertEqual(self.branch(), "main")

    def test_foreign_branch_with_commit_missing_on_origin_is_kept(self):
        git(self.repo, "switch", "-q", "feature")
        (self.repo / "g.md").write_text("only here\n")
        git(self.repo, "add", "g.md")
        git(self.repo, "commit", "-q", "-m", "local work")
        outcome = self.heal()
        self.assertTrue(outcome.startswith("BLOCKED вершина feature ещё не на origin/main"), outcome)
        self.assertEqual(self.branch(), "feature")

    def test_tracked_change_blocks_the_return(self):
        git(self.repo, "switch", "-q", "feature")
        (self.repo / "f.md").write_text("edited\n")
        outcome = self.heal()
        self.assertTrue(outcome.startswith("BLOCKED незакоммиченные правки"), outcome)
        self.assertEqual(self.branch(), "feature")

    def test_half_finished_operation_blocks_the_return(self):
        git(self.repo, "switch", "-q", "feature")
        git_dir = Path(git(self.repo, "rev-parse", "--absolute-git-dir"))
        (git_dir / "MERGE_HEAD").write_text(git(self.repo, "rev-parse", "HEAD") + "\n")
        outcome = self.heal()
        self.assertTrue(outcome.startswith("BLOCKED незавершённая операция git"), outcome)
        self.assertEqual(self.branch(), "feature")

    def test_detached_head_on_origin_tip_returns_to_main(self):
        git(self.repo, "switch", "-q", "--detach")
        self.assertEqual(self.heal(), "returned (detached)")
        self.assertEqual(self.branch(), "main")

    def test_dry_run_reports_and_changes_nothing(self):
        git(self.repo, "switch", "-q", "feature")
        self.assertEqual(self.heal(dry_run=True), "would return feature")
        self.assertEqual(self.branch(), "feature")

    def test_missing_local_main_is_created_from_upstream(self):
        git(self.repo, "switch", "-q", "feature")
        git(self.repo, "branch", "-q", "-D", "main")
        self.assertEqual(self.heal(), "returned feature")
        self.assertEqual(self.branch(), "main")
        self.assertEqual(git(self.repo, "rev-parse", "HEAD"), git(self.repo, "rev-parse", "origin/main"))

    def test_local_main_with_unpublished_commit_is_flagged_after_the_return(self):
        (self.repo / "g.md").write_text("local main only\n")
        git(self.repo, "add", "g.md")
        git(self.repo, "commit", "-q", "-m", "unpublished on main")
        git(self.repo, "switch", "-q", "feature")
        outcome = self.heal()
        self.assertTrue(outcome.startswith("returned feature; но main расходится с origin/main"), outcome)
        self.assertEqual(self.branch(), "main")

    def test_only_shared_paths_are_selected(self):
        registry = object()
        fake = [({"expected_branch": "main"}, {"path": "PACK-a"}),
                ({"expected_branch": "main"}, {"path": "DS-IT-systems/bot"}),
                ({"expected_branch": "main"}, {"path": "DS-my-strategy"}),
                ({"expected_branch": "main"}, {"path": "iwe-local-config"})]
        original = refresh.repo_registry.checkouts_of_class
        refresh.repo_registry.checkouts_of_class = lambda reg, cls, host: fake if cls == "reader" else []
        try:
            picked = [checkout["path"] for _, checkout in refresh.shared_checkouts(registry, "tsekh-1")]
        finally:
            refresh.repo_registry.checkouts_of_class = original
        self.assertEqual(picked, ["PACK-a", "DS-IT-systems/bot"])


if __name__ == "__main__":
    unittest.main()
