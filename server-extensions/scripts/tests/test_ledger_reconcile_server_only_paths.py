"""WP-484 F327: the journal reconcile must not refuse a clean server-only file next to the journals.

On 22.11 the Mac strategy copy stopped for good after the nightly Day Open added
machine/ledger/plan/boundary/known-ids-<date>.txt: the reconcile demanded the day/week/month
journal grammar from every changed path under machine/ledger and refused the whole fast-forward.
Temporary repositories only, never real session state.
"""
from __future__ import annotations

import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RECONCILE = Path(__file__).resolve().parents[1] / "lib" / "ledger-reconcile-published.py"
EVENT_DIFF = Path(os.environ.get("IWE_ROOT", str(Path.home() / "IWE"))) / "DS-my-strategy/scripts/lib/ledger-event-diff.py"
DAY = "machine/ledger/day/2026/11/day-2026-11-22.yaml"
BOUNDARY = "machine/ledger/plan/boundary/known-ids-2026-11-22.txt"
HEADER = "schema: ledger/v1\nscale: day\nperiod: '2026-11-22'\nevents:\n"
EVENT_1 = "- ts: '2026-11-22T01:00:00Z'\n  source: t\n  kind: a\n  event_id: e1\n"
EVENT_2 = "- ts: '2026-11-22T02:00:00Z'\n  source: t\n  kind: b\n  event_id: e2\n"


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


@unittest.skipUnless(EVENT_DIFF.exists(), f"journal event diff not installed at {EVENT_DIFF}")
class ServerOnlyLedgerPaths(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        self.origin, self.repo = base / "origin", base / "mac"
        git(base, "init", "-q", "-b", "main", str(self.origin))
        for repo in (self.origin,):
            git(repo, "config", "user.name", "Test")
            git(repo, "config", "user.email", "test@example.invalid")
        # Same rule as the real repository: the journal append lock is a flock handle, not content.
        self.write(self.origin, ".gitignore", "machine/ledger/**/*.lock\n")
        self.write(self.origin, DAY, HEADER + EVENT_1)
        self.commit("day open")
        git(base, "clone", "-q", str(self.origin), str(self.repo))
        # The Mac appends an event locally; the server publishes the same event and,
        # at the nightly Day Open, a boundary file that only the server writes.
        self.write(self.repo, DAY, HEADER + EVENT_1 + EVENT_2)
        self.write(self.origin, DAY, HEADER + EVENT_1 + EVENT_2)
        self.write(self.origin, BOUNDARY, "e1\ne2\n")
        self.upstream = self.commit("publish + day open boundary")
        git(self.repo, "fetch", "-q", "origin", "main")

    def write(self, repo: Path, path: str, text: str) -> None:
        target = repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message: str) -> str:
        git(self.origin, "add", "-A")
        git(self.origin, "commit", "-q", "-m", message)
        return git(self.origin, "rev-parse", "HEAD")

    def apply(self) -> subprocess.CompletedProcess:
        lock = str(self.repo / ".git" / "ds-commit.lock")
        fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.dup2(fd, 8)
        try:
            return subprocess.run([sys.executable, str(RECONCILE), "--apply", str(self.repo),
                                   self.upstream, "main", lock],
                                  capture_output=True, text=True, pass_fds=(8,))
        finally:
            os.close(8)
            os.close(fd)

    def test_clean_server_only_file_is_fast_forwarded(self) -> None:
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(self.repo, "rev-parse", "HEAD"), self.upstream)
        self.assertEqual((self.repo / BOUNDARY).read_text(), "e1\ne2\n")
        # No tail of the old journal is left behind for the next tick to trip over.
        self.assertEqual(git(self.repo, "status", "--porcelain", "--untracked-files=all"), "")

    def test_hidden_copy_equal_to_the_target_does_not_stop_the_merge(self) -> None:
        # A runner card the Mac wrote and hid in .git/info/exclude, later published unchanged.
        card = "inbox/agent/tasks/RUN-quick-close-x.md"
        self.write(self.repo, ".git/info/exclude", "inbox/agent/tasks/RUN-*.md\n")
        self.write(self.repo, card, "run card\n")
        self.write(self.origin, card, "run card\n")
        self.upstream = self.commit("publish the runner card")
        git(self.repo, "fetch", "-q", "origin", "main")
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(self.repo, "rev-parse", "HEAD"), self.upstream)
        self.assertEqual((self.repo / card).read_text(), "run card\n")
        self.assertIn("equal to the target replaced by the merge", result.stdout)
        self.assertEqual(list((self.repo / ".git").glob("identical-before-ff-*")), [])

    def test_hidden_copy_that_differs_still_stops_the_merge_and_stays(self) -> None:
        card = "inbox/agent/tasks/RUN-quick-close-y.md"
        self.write(self.repo, ".git/info/exclude", "inbox/agent/tasks/RUN-*.md\n")
        self.write(self.repo, card, "local draft\n")
        self.write(self.origin, card, "published card\n")
        self.upstream = self.commit("publish a different runner card")
        git(self.repo, "fetch", "-q", "origin", "main")
        head = git(self.repo, "rev-parse", "HEAD")
        result = self.apply()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(git(self.repo, "rev-parse", "HEAD"), head)
        self.assertEqual((self.repo / card).read_text(), "local draft\n")

    def test_local_file_on_a_server_only_path_is_still_refused(self) -> None:
        self.write(self.repo, BOUNDARY, "written on the Mac\n")
        head = git(self.repo, "rev-parse", "HEAD")
        result = self.apply()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("refused", result.stderr)
        self.assertIn(BOUNDARY, result.stderr)
        self.assertEqual(git(self.repo, "rev-parse", "HEAD"), head)
        self.assertEqual((self.repo / BOUNDARY).read_text(), "written on the Mac\n")


if __name__ == "__main__":
    unittest.main()
