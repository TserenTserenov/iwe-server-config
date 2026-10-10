#!/usr/bin/env python3
"""Smoke test for session-semaphore-classify.py classification logic."""
import datetime as dt
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parent.parent / "session-semaphore-classify.py"
_spec = importlib.util.spec_from_file_location("session_semaphore_classify", SCRIPT_PATH)
classify_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(classify_mod)


def make_repo(tmp: Path, name: str) -> tuple[Path, str]:
    repo = tmp / name
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "t@example.com"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "t"], check=True)
    (repo / "f.txt").write_text("x")
    subprocess.run(["git", "-C", str(repo), "add", "f.txt"], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-q", "-m", "init"], check=True)
    sha = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"],
                          capture_output=True, text=True, check=True).stdout.strip()
    return repo, sha


def iso_hours_ago(hours: float) -> str:
    when = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=hours)
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


class TestClassify(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.repo, self.real_sha = make_repo(self.tmp, "myrepo")
        self.repo_map = {"myrepo": [self.repo]}

    def write_semaphore(self, name: str, body: str) -> Path:
        p = self.tmp / name
        p.write_text(body)
        return p

    def test_class_a_when_all_commits_found(self):
        sem = classify_mod.parse_semaphore(self.write_semaphore(
            "a.open",
            f"---\nwp: WP-1\ncreated_at: {iso_hours_ago(72)}\n---\n"
            f"commit: myrepo {self.real_sha}\n",
        ))
        result = classify_mod.classify(sem, self.repo_map)
        self.assertEqual(result["class"], "A")

    def test_needs_review_when_commit_missing(self):
        fake_sha = "f" * 40
        sem = classify_mod.parse_semaphore(self.write_semaphore(
            "b.open",
            f"---\nwp: WP-2\ncreated_at: {iso_hours_ago(72)}\n---\n"
            f"commit: myrepo {fake_sha}\n",
        ))
        result = classify_mod.classify(sem, self.repo_map)
        self.assertEqual(result["class"], "needs-review")

    def test_needs_review_when_no_commit_refs(self):
        sem = classify_mod.parse_semaphore(self.write_semaphore(
            "c.open", f"---\nwp: WP-3\ncreated_at: {iso_hours_ago(72)}\n---\n"
        ))
        result = classify_mod.classify(sem, self.repo_map)
        self.assertEqual(result["class"], "needs-review")

    def test_fresh_overrides_published_evidence(self):
        sem = classify_mod.parse_semaphore(self.write_semaphore(
            "d.open",
            f"---\nwp: WP-4\ncreated_at: {iso_hours_ago(2)}\n---\n"
            f"commit: myrepo {self.real_sha}\n",
        ))
        result = classify_mod.classify(sem, self.repo_map)
        self.assertEqual(result["class"], "fresh")

    def test_active_when_pid_alive(self):
        import os
        sem = classify_mod.parse_semaphore(self.write_semaphore(
            "e.open",
            f"---\nwp: WP-5\ncreated_at: {iso_hours_ago(72)}\npid: {os.getpid()}\n---\n",
        ))
        result = classify_mod.classify(sem, self.repo_map)
        self.assertEqual(result["class"], "active")

    def test_dead_pid_falls_back_to_evidence_based_classification(self):
        sem = classify_mod.parse_semaphore(self.write_semaphore(
            "f.open",
            f"---\nwp: WP-6\ncreated_at: {iso_hours_ago(72)}\npid: 999999999\n---\n"
            f"commit: myrepo {self.real_sha}\n",
        ))
        result = classify_mod.classify(sem, self.repo_map)
        self.assertEqual(result["class"], "A")

    def test_pid_owned_by_another_user_counts_as_alive(self):
        # pid 1 (launchd/init) always exists but this test process never owns
        # it - kill(1, 0) raises PermissionError, not ProcessLookupError.
        # Regression test for the bug the subagent review found: the old
        # code collapsed PermissionError into "not alive".
        self.assertTrue(classify_mod.pid_alive("1"))

    def test_needs_review_when_created_at_missing(self):
        sem = classify_mod.parse_semaphore(self.write_semaphore(
            "g.open", f"---\nwp: WP-7\n---\ncommit: myrepo {self.real_sha}\n"
        ))
        result = classify_mod.classify(sem, self.repo_map)
        self.assertEqual(result["class"], "needs-review")

    def test_receipt_json_parsed_regardless_of_key_order(self):
        # The old regex only matched because one writer happens to emit
        # anchor_commit before repo, sorted-keys, single-line. A receipt
        # with keys in the opposite order must still be found.
        receipt = f'{{"repo":"myrepo","anchor_commit":"{self.real_sha}"}}'
        sem = classify_mod.parse_semaphore(self.write_semaphore(
            "h.open",
            f"---\nwp: WP-8\ncreated_at: {iso_hours_ago(72)}\n---\n"
            f"publication_receipt_v2: {receipt}\n",
        ))
        self.assertIn(("myrepo", self.real_sha), sem["commits"])
        result = classify_mod.classify(sem, self.repo_map)
        self.assertEqual(result["class"], "A")

    def test_commit_found_when_repo_name_collides_across_two_real_checkouts(self):
        # Regression test for the bug the subagent review confirmed live on
        # this filesystem: a bare repo name can match two independently-
        # diverged checkouts. A commit that exists in the SECOND candidate
        # (not the first one find_repo_map happens to record) must still
        # resolve as found, not "missing" because only the first was checked.
        other_repo, other_sha = make_repo(self.tmp, "collider-real")
        colliding_map = {"shared-name": [self.tmp / "no-such-path", other_repo]}
        self.assertEqual(
            classify_mod.commit_exists(colliding_map, "shared-name", other_sha),
            "found",
        )


class TestFindRepoMap(unittest.TestCase):
    def test_two_real_checkouts_sharing_a_basename_both_become_candidates(self):
        tmp = Path(tempfile.mkdtemp())
        (tmp / "a").mkdir()
        (tmp / "b").mkdir()
        repo1, _ = make_repo(tmp / "a", "shared-name")
        repo2, _ = make_repo(tmp / "b", "shared-name")
        repo_map = classify_mod.find_repo_map(tmp)
        self.assertCountEqual(repo_map["shared-name"], [repo1, repo2])


if __name__ == "__main__":
    unittest.main()
