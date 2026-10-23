#!/usr/bin/env python3
"""End-to-end close retry for a PREPARED copy that left its snapshot (WP-530 Ф61 G5).

Live case WP-600 (tsekh-1, 14.10): the PREPARED set was delivered under
rewritten OIDs, then the same isolated copy was reset to origin/main and reused
for other work. Every close since refused: the snapshot check (HEAD ==
source_head, clean status) ran before any delivery proof and again before the
copy could be removed. Drives the real _close_delivery_and_transition with
functions extracted from the guard under test (same technique and helpers as
session-guard-declared-terminal-proof-smoke.py).
"""
import importlib.util
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location(
    "declared_terminal_proof_smoke", HERE / "session-guard-declared-terminal-proof-smoke.py")
_suite = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_suite)
SOURCE = _suite.SOURCE

FUNCTIONS = (
    "normalize_remote_url", "_unique_record_field", "_terminal_proof_snapshot_sha",
    "_owned_semaphore_snapshot_sha", "_append_close_fields_atomic", "_record_close_prepared",
    "_record_close_published", "_close_delivery_state", "_worktree_clean_status_sha",
    "_isolated_source_commits_json", "_session_commit_claims_json",
    "_prepared_worktree_status_sha", "_prepared_source_worktree_unchanged",
    "_prepared_source_identity_matches", "_prepared_source_snapshot_matches",
    "_commit_current_tree_has_publish_proof", "_range_commits_have_publish_proof",
    "_prepared_source_set_has_publish_proof", "_prepared_worktree_removal_proof",
    "_publish_prepared_source", "_claimed_commits_have_publish_proof",
    "_worktree_absent_and_unregistered", "_record_close_cleanup", "_prepare_close_receipt",
    "_rename_open_to_closed", "_close_delivery_and_transition", "_reap_orphaned_worktree",
)
SENTINEL = "declared-peer-session:drift-fixture"
FILE = "notes/card.md"


class PreparedDriftCloseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.functions = "\n".join(_suite.extract_function(SOURCE, name) for name in FUNCTIONS)
        cls.functions += "\n" + _suite.receipt_helpers(SOURCE)
        cls.functions += '\nfail() { printf "%s\\n" "$1" >&2; exit "${2:-1}"; }\n'

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="prepared-drift-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.origin = self.root / "origin.git"
        self.run_git(self.root, "init", "-q", "--bare", "-b", "main", str(self.origin))
        self.repo = self.root / "governance"
        self.run_git(self.root, "clone", "-q", str(self.origin), str(self.repo))
        self.identity(self.repo)
        (self.repo / "notes").mkdir()
        (self.repo / FILE).write_text("base\n")
        self.run_git(self.repo, "add", FILE)
        self.run_git(self.repo, "commit", "-qm", "seed")
        self.run_git(self.repo, "push", "-q", "origin", "main")
        self.base = self.rev(self.repo, "HEAD")
        # Fails loudly if a drifted copy is ever pushed from.
        self.push_marker = self.root / "isolate-push-called"
        stub = self.repo / "scripts/isolate-push.sh"
        stub.parent.mkdir()
        stub.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(self.push_marker))}\nexit 99\n")
        stub.chmod(0o755)
        self.branch = "session-isolate/claude-code-one"
        self.worktree = self.root / ".iwe-runtime/isolated-worktrees/claude-code-one"
        self.worktree.parent.mkdir(parents=True)
        self.run_git(self.repo, "worktree", "add", "-q", "-b", self.branch, str(self.worktree), "main")
        self.identity(self.worktree)
        (self.worktree / FILE).write_text("base\nprepared change\n")
        self.run_git(self.worktree, "commit", "-qam", "prepared change")
        self.head = self.rev(self.worktree, "HEAD")
        self.sem = self.root / "claude-code-one.open"
        self.sem.write_text("agent: claude-code\nsession_id: one\nwp: WP-530\nslug: drift\n"
                            f"isolated_worktree: {self.worktree}\nisolated_branch: {self.branch}\n")
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("GIT_", "IWE_", "CLAUDE_"))}
        self.env.update(IWE_ROOT=str(self.root), GOV_REPO="governance", AGENT="claude-code",
                        SESSION_ID="one", SEM_FILE=str(self.sem), MACHINE_CLOSE_MODE="1",
                        ABANDON_PREPARED="0", UNFREEZE_REASON="")
        prepared = self.invoke('''
terminal_sha=$(_terminal_proof_snapshot_sha sentinel "$3")
source_status=$(_worktree_clean_status_sha "$1")
common=$(cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
origin=$(normalize_remote_url "$(git -C "$1" remote get-url origin)")
_record_close_prepared "$SEM_FILE" one "$1" "$common" "$4" "$5" "$source_status" \
    "$(printf '["%s"]' "$5")" '[]' sentinel "$3" "$terminal_sha" "$origin" refs/heads/main >/dev/null
_close_delivery_state "$SEM_FILE" one
''', str(self.worktree), "", SENTINEL, self.base, self.head)
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        self.assertEqual(prepared.stdout.splitlines()[-1], "prepared")

    # --- helpers ---------------------------------------------------------
    def run_git(self, cwd, *args):
        return subprocess.run(["git", "-C", str(cwd), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def identity(self, repo):
        self.run_git(repo, "config", "user.name", "Test")
        self.run_git(repo, "config", "user.email", "test@example.invalid")
        self.run_git(repo, "config", "commit.gpgsign", "false")

    def rev(self, repo, name):
        return self.run_git(repo, "rev-parse", name)

    def invoke(self, command, *args):
        return subprocess.run(["bash", "-c", "set -euo pipefail\n" + self.functions + command,
                               "drift-test", *args], cwd=self.root, env=self.env,
                              capture_output=True, text=True, timeout=120)

    def close(self, extra=""):
        return self.invoke(extra + "\n_close_delivery_and_transition\n")

    def deliver_prepared_under_new_oid(self):
        other = self.root / "other"
        self.run_git(self.root, "clone", "-q", str(self.origin), str(other))
        self.identity(other)
        (other / FILE).write_text("base\nprepared change\n")
        self.run_git(other, "commit", "-qam", "same change, rewritten OID")
        self.run_git(other, "push", "-q", "origin", "main")

    def push_unrelated_upstream(self):
        other = self.root / "upstream"
        self.run_git(self.root, "clone", "-q", str(self.origin), str(other))
        self.identity(other)
        (other / "notes/other.md").write_text("unrelated\n")
        self.run_git(other, "add", "notes/other.md")
        self.run_git(other, "commit", "-qm", "unrelated upstream work")
        self.run_git(other, "push", "-q", "origin", "main")

    def drift_to_origin(self):
        self.run_git(self.worktree, "fetch", "-q", "origin", "+refs/heads/main:refs/remotes/origin/main")
        self.run_git(self.worktree, "reset", "-q", "--hard", "origin/main")

    def field(self, name):
        path = self.sem if self.sem.exists() else self.sem.with_suffix(".open.closed")
        for line in path.read_text().splitlines():
            if line.startswith(name + ": "):
                return line.split(": ", 1)[1]
        return None

    def assert_closed(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.worktree.exists())
        self.assertFalse(self.sem.exists())
        self.assertIn("close_cleanup_proof: worktree-absent/v1\n",
                      self.sem.with_suffix(".open.closed").read_text())

    def assert_retained_published(self, result, reason):
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn(reason, result.stderr)
        self.assertTrue(self.worktree.exists())
        self.assertTrue(self.sem.exists())
        self.assertEqual(self.field("close_publish_proof"), "isolate-push-exit0/v1")

    # --- scenarios -------------------------------------------------------
    def test_drift_clean(self):
        """(a) the live case: set delivered under new OIDs, copy reset and clean -> closes."""
        self.deliver_prepared_under_new_oid()
        self.drift_to_origin()
        result = self.close()
        self.assert_closed(result)
        self.assertFalse(self.push_marker.exists(), "a drifted copy must never be pushed from")
        self.assertIn("ушла от PREPARED-снимка", result.stderr)

    def test_drift_untracked(self):
        """(b) delivered, but an untracked file in the copy -> published, copy kept."""
        self.deliver_prepared_under_new_oid()
        self.drift_to_origin()
        (self.worktree / "notes/draft.md").write_text("not committed anywhere\n")
        result = self.close()
        self.assert_retained_published(result, "не чиста")
        self.assertEqual((self.worktree / "notes/draft.md").read_text(), "not committed anywhere\n")

    def test_drift_unpublished(self):
        """(c) delivered, but a later commit in the copy is nowhere on origin -> copy kept."""
        self.deliver_prepared_under_new_oid()
        self.drift_to_origin()
        (self.worktree / "notes/later.md").write_text("later local work\n")
        self.run_git(self.worktree, "add", "notes/later.md")
        self.run_git(self.worktree, "commit", "-qm", "later local work")
        local = self.rev(self.worktree, "HEAD")
        result = self.close()
        self.assert_retained_published(result, "без доказательства доставки")
        self.assertEqual(self.rev(self.worktree, "HEAD"), local)

    def test_drift_undelivered(self):
        """(d) the set never reached origin, copy reset -> refused, nothing pushed."""
        self.push_unrelated_upstream()
        origin_before = self.run_git(self.origin, "rev-parse", "main")
        self.drift_to_origin()
        result = self.close()
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn("прямого доказательства доставки", result.stderr)
        self.assertIsNone(self.field("close_publish_proof"))
        self.assertTrue(self.worktree.exists())
        self.assertFalse(self.push_marker.exists())
        self.assertEqual(self.run_git(self.origin, "rev-parse", "main"), origin_before)

    def test_drift_ignores_receipt(self):
        """(e) on a drifted copy the checkout-receipt proof walks someone else's line; it must not vouch."""
        self.push_unrelated_upstream()
        self.drift_to_origin()
        result = self.close("_receipt_checkout_has_publish_proof() { return 0; }")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn("прямого доказательства доставки", result.stderr)
        self.assertIsNone(self.field("close_publish_proof"))
        self.assertTrue(self.worktree.exists())

    def test_dirty_only(self):
        """(g) HEAD still on source_head but the copy is dirty, set undelivered -> refused, no push."""
        self.push_unrelated_upstream()
        (self.worktree / "notes/draft.md").write_text("not committed anywhere\n")
        result = self.close()
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn("прямого доказательства доставки", result.stderr)
        self.assertIsNone(self.field("close_publish_proof"))
        self.assertFalse(self.push_marker.exists())
        self.assertEqual(self.rev(self.worktree, "HEAD"), self.head)

    def test_unchanged_path(self):
        """(f) no drift: the ordinary path still proves the set and closes, without replaying it."""
        self.deliver_prepared_under_new_oid()
        result = self.close()
        self.assert_closed(result)
        self.assertNotIn("ушла от PREPARED-снимка", result.stderr)
        self.assertFalse(self.push_marker.exists())


if __name__ == "__main__":
    unittest.main()
