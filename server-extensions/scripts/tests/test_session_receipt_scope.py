"""Exact session receipt proof with a diverged shared MC-sessions checkout."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

LIB = Path(__file__).resolve().parents[1] / "lib"
sys.path.insert(0, str(LIB))
import publication_receipt as receipts  # noqa: E402
import session_receipt_scope as scope  # noqa: E402


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


class SessionReceiptScopeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name).resolve()
        self.remote = base / "remote.git"
        (base / "foreign" / ".git").mkdir(parents=True)
        subprocess.run(["git", "init", "--bare", "--initial-branch=main", str(self.remote)],
                       check=True, capture_output=True)
        self.repo = base / "MC-sessions"
        subprocess.run(["git", "clone", str(self.remote), str(self.repo)],
                       check=True, capture_output=True)
        self._identity(self.repo)
        self.orz = "2026-10/2026-10-02-WP-7.md"
        own = self.repo / self.orz
        own.parent.mkdir(parents=True)
        own.write_text("Session report\n")
        git(self.repo, "add", "--", self.orz)
        git(self.repo, "commit", "-m", "own session")
        self.source = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "push", "origin", "HEAD:main")
        git(self.repo, "fetch", "origin", "main")
        common = git(self.repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
        self.sem = base / "session.open"
        self.sem.write_text(
            "---\nagent: codex\nsession_id: test-session\nclose_path: unknown\n"
            f"orz_sessions_dir: {self.repo}\norz_file: {self.orz}\n---\n"
            f"file: {self.orz}\nfile: inbox/open-sessions.log\n"
            f"file: src/server.ts\nfile_v2: {json.dumps({'path': 'src/server.ts', 'repo': str(base / 'foreign' / '.git')})}\n"
            f"commit: MC-sessions {self.source}\n"
        )
        receipts.record(self.repo, self.sem, "MC-sessions", self.source)

        # The shared local branch contains unrelated unpublished work, while
        # origin/main advances independently. The exact owned receipt still
        # proves this session's publication.
        (self.repo / "foreign.txt").write_text("local unpublished\n")
        git(self.repo, "add", "--", "foreign.txt")
        git(self.repo, "commit", "-m", "foreign local")
        self.second = base / "second"
        subprocess.run(["git", "clone", str(self.remote), str(self.second)],
                       check=True, capture_output=True)
        self._identity(self.second)
        (self.second / "other.txt").write_text("remote advance\n")
        git(self.second, "add", "--", "other.txt")
        git(self.second, "commit", "-m", "remote advance")
        git(self.second, "push", "origin", "HEAD:main")
        git(self.repo, "fetch", "origin", "main")

    @staticmethod
    def _identity(repo: Path) -> None:
        git(repo, "config", "user.name", "Test")
        git(repo, "config", "user.email", "test@example.invalid")

    def verify(self) -> None:
        scope.verify_scope(self.sem, self.repo, git(self.repo, "rev-parse", "origin/main"))

    def test_diverged_shared_checkout_with_exact_receipt(self) -> None:
        self.verify()

    def test_dirty_owned_file_is_refused(self) -> None:
        (self.repo / self.orz).write_text("unpublished edit\n")
        with self.assertRaises(receipts.ProofError):
            self.verify()

    def test_tampered_receipt_is_refused(self) -> None:
        lines = self.sem.read_text().splitlines()
        for i, line in enumerate(lines):
            if line.startswith(receipts.PREFIX):
                record = json.loads(line[len(receipts.PREFIX):])
                record["published_paths"][0]["entry"]["oid"] = "0" * 40
                lines[i] = receipts.PREFIX + json.dumps(record)
                break
        self.sem.write_text("\n".join(lines) + "\n")
        with self.assertRaises(receipts.ProofError):
            self.verify()

    def test_unpaired_foreign_path_is_refused(self) -> None:
        self.sem.write_text(self.sem.read_text() + "file: src/unknown.ts\n")
        with self.assertRaises(receipts.ProofError):
            self.verify()

    def test_same_name_foreign_claim_does_not_change_own_scope(self) -> None:
        foreign = self.repo.parent / "foreign" / ".git"
        self.sem.write_text(self.sem.read_text() +
                            f"file: {self.orz}\nfile_v2: " +
                            json.dumps({"path": self.orz, "repo": str(foreign)}) + "\n")
        self.verify()

    def test_malformed_foreign_repository_identity_is_refused(self) -> None:
        text = self.sem.read_text().replace(str(self.repo.parent / "foreign" / ".git"),
                                             str(self.repo.parent / "missing" / ".git"))
        self.sem.write_text(text)
        with self.assertRaises((receipts.ProofError, OSError)):
            self.verify()

    def test_remote_replacement_of_owned_file_is_refused(self) -> None:
        (self.second / self.orz).write_text("later replacement\n")
        git(self.second, "add", "--", self.orz)
        git(self.second, "commit", "-m", "replace session report")
        git(self.second, "push", "origin", "HEAD:main")
        git(self.repo, "fetch", "origin", "main")
        with self.assertRaises(receipts.ProofError):
            self.verify()

    def test_ignored_remote_only_file_changed_during_proof_is_refused(self) -> None:
        remote_only = "ignored-remote-only.txt"
        (self.second / remote_only).write_text("published bytes\n")
        git(self.second, "add", "--", remote_only)
        git(self.second, "commit", "-m", "add remote-only file")
        source = git(self.second, "rev-parse", "HEAD")
        git(self.second, "push", "origin", "HEAD:main")
        git(self.repo, "fetch", "origin", "main")
        self.sem.write_text(self.sem.read_text() +
                            f"file: {remote_only}\nfile_v2: " +
                            json.dumps({"path": remote_only, "repo": str(self.repo / ".git")}) + "\n" +
                            f"commit: MC-sessions {source}\n")
        receipts.record(self.repo, self.sem, "MC-sessions", source)
        (self.repo / ".git" / "info").mkdir(exist_ok=True)
        (self.repo / ".git" / "info" / "exclude").write_text(remote_only + "\n")
        (self.repo / remote_only).write_text("published bytes\n")
        original = scope.local_entry
        seen = False

        def change_after_first_read(repo: Path, path: str, algorithm: str):
            nonlocal seen
            result = original(repo, path, algorithm)
            if path == remote_only and not seen:
                seen = True
                (repo / path).write_text("unpublished replacement\n")
            return result

        with patch.object(scope, "local_entry", side_effect=change_after_first_read):
            with self.assertRaises(receipts.ProofError):
                self.verify()

    def test_older_owned_version_cannot_override_latest_receipt(self) -> None:
        remote_only = "remote-only.txt"
        (self.second / remote_only).write_text("first owned version\n")
        git(self.second, "add", "--", remote_only)
        git(self.second, "commit", "-m", "first owned version")
        first = git(self.second, "rev-parse", "HEAD")
        git(self.second, "push", "origin", "HEAD:main")
        git(self.repo, "fetch", "origin", "main")
        self.sem.write_text(self.sem.read_text() +
                            f"file: {remote_only}\nfile_v2: " +
                            json.dumps({"path": remote_only, "repo": str(self.repo / ".git")}) + "\n" +
                            f"commit: MC-sessions {first}\n")
        receipts.record(self.repo, self.sem, "MC-sessions", first)
        (self.second / remote_only).write_text("second owned version\n")
        git(self.second, "add", "--", remote_only)
        git(self.second, "commit", "-m", "second owned version")
        second = git(self.second, "rev-parse", "HEAD")
        git(self.second, "push", "origin", "HEAD:main")
        git(self.repo, "fetch", "origin", "main")
        self.sem.write_text(self.sem.read_text() + f"commit: MC-sessions {second}\n")
        receipts.record(self.repo, self.sem, "MC-sessions", second)
        self.verify()
        # A later foreign commit restores the first owned version. It matches
        # one valid receipt, but not the latest owned receipt for this path.
        (self.second / remote_only).write_text("first owned version\n")
        git(self.second, "add", "--", remote_only)
        git(self.second, "commit", "-m", "revert owned version")
        git(self.second, "push", "origin", "HEAD:main")
        git(self.repo, "fetch", "origin", "main")
        with self.assertRaises(receipts.ProofError):
            self.verify()


class EmptyGovernanceScopeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.governance = self.make_repo("strategy")
        self.sessions = self.make_repo("MC-sessions")
        self.source = git(self.sessions, "rev-parse", "HEAD")
        self.orz = "2026-10/session.md"
        self.sem = self.base / "session.open"
        self.original = (
            "---\nagent: codex\nsession_id: own\nwp: WP-484\nslug: fixture\n"
            "harness_session_id: native-owner\nhost: fixture\nclose_path: unknown\n"
            f"governance_worktree: {self.governance}\norz_sessions_dir: {self.sessions}\n"
            f"orz_file: {self.orz}\n---\nfile: {self.orz}\nfile: inbox/open-sessions.log\n"
            f"file: report.md\nfile_v2: {json.dumps({'path': 'report.md', 'repo': str(self.sessions / '.git')})}\n"
            f"commit: MC-sessions {self.source}\n"
        )
        self.sem.write_text(self.original)
        # A real runtime projection must not become a deliverable just because
        # it exists in governance; unrelated unpublished work is preserved.
        (self.governance / "inbox").mkdir()
        (self.governance / "inbox/open-sessions.log").write_text("runtime projection\n")
        (self.governance / "foreign.txt").write_text("unpublished work\n")

    def make_repo(self, name: str) -> Path:
        path = self.base / name
        subprocess.run(["git", "init", "--initial-branch=main", str(path)],
                       check=True, capture_output=True)
        git(path, "config", "user.name", "Test")
        git(path, "config", "user.email", "test@example.invalid")
        git(path, "remote", "add", "origin", str(self.base / (name + "-remote.git")))
        (path / "report.md").write_text("report\n")
        git(path, "add", "--", "report.md")
        git(path, "commit", "-m", "fixture")
        return path

    def verify(self) -> None:
        scope.verify_empty_governance_scope(self.sem, self.governance)

    def test_positive_external_attribution_preserves_dirty_governance(self) -> None:
        before = git(self.governance, "status", "--porcelain=v1", "--untracked-files=all")
        self.verify()
        self.assertEqual(before, git(self.governance, "status", "--porcelain=v1", "--untracked-files=all"))
        self.assertEqual(self.sem.read_text(), self.original)

    def test_own_missing_same_name_and_directory_claims_refuse(self) -> None:
        for path in ("deleted.txt", "report.md", "inbox/", "inbox/open-sessions.log"):
            with self.subTest(path=path):
                self.sem.write_text(self.original + f"file: {path}\nfile_v2: " +
                                    json.dumps({"path": path, "repo": str(self.governance / ".git")}) + "\n")
                with self.assertRaises(receipts.ProofError):
                    self.verify()

    def test_unqualified_unknown_empty_and_malformed_scope_refuse(self) -> None:
        cases = [
            self.original + "file: vanished.txt\n",
            self.original + "file: report.md\n",
            self.original + 'file_v2: {}\n',
            self.original + 'file: bad.md\nfile_v2: {"path":"bad.md","path":"bad.md","repo":"/tmp/.git"}\n',
            self.original + "file:bad.md\n",
            self.original.replace(f"commit: MC-sessions {self.source}\n", ""),
            self.original.replace("file: inbox/open-sessions.log\n", ""),
            self.original + f"commit: strategy {self.source}\n",
            self.original + f"commit: unknown {self.source}\n",
            self.original + "commit: MC-sessions not-a-sha\n",
        ]
        for text in cases:
            with self.subTest(text=text):
                self.sem.write_text(text)
                with self.assertRaises(receipts.ProofError):
                    self.verify()

    def test_separate_clone_of_governance_is_not_foreign(self) -> None:
        other = self.make_repo("separate-clone")
        git(other, "remote", "set-url", "origin", git(self.governance, "remote", "get-url", "origin"))
        self.sem.write_text(self.original + "file: report.md\nfile_v2: " +
                            json.dumps({"path": "report.md", "repo": str(other / ".git")}) + "\n")
        with self.assertRaises(receipts.ProofError):
            self.verify()

    def test_third_repository_uncommitted_output_cannot_prove_empty_scope(self) -> None:
        other = self.make_repo("product")
        (other / "report.md").write_text("unpublished product work\n")
        self.sem.write_text(self.original + "file: report.md\nfile_v2: " +
                            json.dumps({"path": "report.md", "repo": str(other / ".git")}) + "\n")
        with self.assertRaises(receipts.ProofError):
            self.verify()

    def test_legacy_or_isolated_scope_cannot_claim_empty(self) -> None:
        for text in (self.original.replace("harness_session_id: native-owner\n", ""),
                     self.original + f"isolated_worktree: {self.governance}\n",
                     self.original.replace(str(self.sessions), str(self.governance))):
            with self.subTest(text=text):
                self.sem.write_text(text)
                with self.assertRaises(receipts.ProofError):
                    self.verify()

    def test_mutation_during_classification_refuses(self) -> None:
        original_identity = receipts.repository_identity

        def mutate(path):
            identity = original_identity(path)
            self.sem.write_text(self.original + "file: unpublished.md\n")
            return identity

        with patch.object(receipts, "repository_identity", side_effect=mutate):
            with self.assertRaises(receipts.ProofError):
                self.verify()


if __name__ == "__main__":
    unittest.main()
