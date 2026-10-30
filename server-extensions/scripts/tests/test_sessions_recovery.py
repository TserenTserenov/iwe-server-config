"""WP-484 F269: note-publication recovers an MC-sessions receipt in PREPARED close state."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS / "lib"))
import publication_receipt as receipts  # noqa: E402
import session_receipt_scope as scope  # noqa: E402

GUARD = SCRIPTS / "session-guard.sh"
ORZ = "2026-10/2026-10-02-WP-7.md"
NOTE = "notes/a.md"
SESSION_ID = "sid-f269"


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True,
                                   stderr=subprocess.DEVNULL).strip()


def identity(repo: Path) -> None:
    git(repo, "config", "user.name", "Test")
    git(repo, "config", "user.email", "test@example.invalid")


class RecoveryFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.remote = self.base / "remote.git"
        subprocess.run(["git", "init", "--bare", "--initial-branch=main", str(self.remote)],
                       check=True, capture_output=True)
        self.repo = self.base / "MC-sessions"
        subprocess.run(["git", "clone", str(self.remote), str(self.repo)],
                       check=True, capture_output=True)
        identity(self.repo)
        for path, text in ((ORZ, "report\n"), (NOTE, "note\n"), ("other.txt", "other\n"),
                           ("inbox/open-sessions.log", "log\n")):
            self.put(self.repo, path, text)
        git(self.repo, "add", "--", ".")
        git(self.repo, "commit", "-m", "base")
        git(self.repo, "push", "origin", "HEAD:main")
        self.second = self.base / "second"
        subprocess.run(["git", "clone", str(self.remote), str(self.second)],
                       check=True, capture_output=True)
        identity(self.second)
        self.gov = self.base / "DS-gov"
        subprocess.run(["git", "init", "--quiet", str(self.gov)], check=True, capture_output=True)
        git(self.gov, "remote", "add", "origin", "https://example.invalid/DS-gov.git")
        (self.base / "foreign" / ".git").mkdir(parents=True)
        (self.base / "DS-prod" / ".git").mkdir(parents=True)
        self.sessions_dir = self.base / ".iwe-runtime" / "sessions"
        self.sessions_dir.mkdir(parents=True)
        self.sem = self.sessions_dir / f"claude-code-{SESSION_ID}.open"

    @staticmethod
    def put(repo: Path, path: str, text: str) -> None:
        target = repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def local_commit(self, changes: dict[str, str | None]) -> str:
        """Commit in the shared checkout; None deletes, 'link:<t>' adds a symlink."""
        for path, text in changes.items():
            target = self.repo / path
            if text is None:
                git(self.repo, "rm", "-q", "--", path)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            if text.startswith("link:"):
                target.unlink(missing_ok=True)
                os.symlink(text[5:], target)
            else:
                target.write_text(text)
            git(self.repo, "add", "--", path)
        git(self.repo, "commit", "-m", "session work")
        return git(self.repo, "rev-parse", "HEAD")

    def publish_by_cherry_pick(self, source: str) -> str:
        """Advance origin/main independently, then cherry-pick the session commit onto it."""
        self.put(self.second, "advance.txt", "remote advance\n")
        git(self.second, "add", "--", "advance.txt")
        git(self.second, "commit", "-m", "remote advance")
        git(self.second, "fetch", str(self.repo), "HEAD")
        git(self.second, "cherry-pick", source)
        git(self.second, "push", "origin", "HEAD:main")
        git(self.repo, "fetch", "--quiet", "origin", "+refs/heads/main:refs/remotes/origin/main")
        return git(self.second, "rev-parse", "HEAD")

    def write_semaphore(self, sources: list[str], own: list[str], frozen: list[str] | None = None) -> None:
        commits = [f"MC-sessions {sha}" for sha in sources]
        frozen_claims = sorted(set(commits)) if frozen is None else frozen
        source_commits: list[str] = []
        fields = {
            "close_delivery_version": "isolate-push/v2",
            "close_attempt_id": "5f1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b",
            "close_delivery_session_id": SESSION_ID,
            "close_delivery_worktree": str(self.base / "DS-prod"),
            "close_delivery_common_dir": str(self.base / "DS-prod" / ".git"),
            "close_delivery_origin": "github.com/example/DS-prod",
            "close_delivery_target_ref": "refs/heads/main",
            "close_delivery_source_base": "a" * 40,
            "close_delivery_source_head": "b" * 40,
            "close_delivery_source_commits": json.dumps(source_commits, separators=(",", ":")),
            "close_delivery_source_commits_digest": hashlib.sha256(
                json.dumps(source_commits, separators=(",", ":")).encode()).hexdigest(),
            "close_delivery_source_status_sha256": "c" * 64,
            "close_delivery_expected_commits": json.dumps(source_commits, separators=(",", ":")),
            "close_delivery_claimed_commits": json.dumps(frozen_claims, separators=(",", ":")),
            "close_delivery_terminal_kind": "sentinel",
            "close_delivery_terminal_reference": "declared-peer-session:f269",
            "close_delivery_terminal_sha256": "d" * 64,
            "close_delivery_semaphore_sha256": "e" * 64,
        }
        payload = {
            "version": fields["close_delivery_version"],
            "close_attempt_id": fields["close_attempt_id"],
            "session_id": SESSION_ID,
            "worktree": fields["close_delivery_worktree"],
            "common_dir": fields["close_delivery_common_dir"],
            "origin": fields["close_delivery_origin"],
            "target_ref": fields["close_delivery_target_ref"],
            "source_base": fields["close_delivery_source_base"],
            "source_head": fields["close_delivery_source_head"],
            "source_commits": source_commits,
            "source_commits_digest": fields["close_delivery_source_commits_digest"],
            "source_status_sha256": fields["close_delivery_source_status_sha256"],
            "expected_commits": source_commits,
            "claimed_commits": frozen_claims,
            "terminal_kind": fields["close_delivery_terminal_kind"],
            "terminal_reference": fields["close_delivery_terminal_reference"],
            "terminal_sha256": fields["close_delivery_terminal_sha256"],
            "semaphore_sha256": fields["close_delivery_semaphore_sha256"],
        }
        fields["close_delivery_prepare_digest"] = hashlib.sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        head = [f"agent: claude-code", "wp: WP-7", "slug: f269", f"session_id: {SESSION_ID}",
                "guard_schema: 1", "close_path: peer-session",
                f"orz_sessions_dir: {self.repo}", f"orz_file: {ORZ}",
                f"governance_worktree: {self.gov}"]
        head += [f"{key}: {value}" for key, value in fields.items()]
        body = [f"file: {ORZ}", "file: inbox/open-sessions.log"]
        for path in own:
            body += [f"file: {path}", "file_v2: " + json.dumps(
                {"path": path, "repo": str(self.repo / ".git")})]
        body += [f"file: src/x.ts",
                 "file_v2: " + json.dumps({"path": "src/x.ts", "repo": str(self.base / "foreign" / ".git")})]
        body += [f"commit: {row}" for row in commits]
        self.sem.write_text("---\n" + "\n".join(head) + "\n---\n" + "\n".join(body) + "\n")

    def semaphore_without_receipts(self) -> str:
        return "".join(line for line in self.sem.read_text().splitlines(keepends=True)
                       if not line.startswith(receipts.PREFIX))

    def receipt_lines(self) -> list[str]:
        return [line for line in self.sem.read_text().splitlines() if line.startswith(receipts.PREFIX)]

    def guard(self, *extra: str, repo: str = "MC-sessions", sha: str | None = None
              ) -> subprocess.CompletedProcess:
        env = {**os.environ, "IWE_ROOT": str(self.base), "IWE_GOVERNANCE_REPO": "DS-gov",
               "IWE_AGENT": "claude-code"}
        return subprocess.run(["bash", str(GUARD), "note-publication", sha or self.published,
                               "--repo", repo, "--session-id", SESSION_ID, *extra],
                              env=env, capture_output=True, text=True, timeout=120)

    def prepare_standard(self) -> None:
        self.source = self.local_commit({ORZ: "report v2\n", NOTE: "note v2\n"})
        self.published = self.publish_by_cherry_pick(self.source)
        self.write_semaphore([self.source], [NOTE])


class PreparedRecoveryTest(RecoveryFixture):
    def test_a_receipt_appended_and_scope_accepts(self) -> None:
        self.prepare_standard()
        result = self.guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.receipt_lines()), 1)
        record = json.loads(self.receipt_lines()[0][len(receipts.PREFIX):])
        self.assertEqual((record["proof"], record["anchor_commit"]), ("exact-replay", self.published))
        self.assertEqual(self.receipt_lines()[0], receipts.PREFIX + json.dumps(
            receipts.reconstruct_receipt(self.repo, receipts.snapshot(self.sem), "MC-sessions",
                                         self.source, record), sort_keys=True, separators=(",", ":")))
        scope.verify_scope(self.sem, self.repo, git(self.repo, "rev-parse", "origin/main"))

    def test_b_foreign_path_is_refused(self) -> None:
        self.source = self.local_commit({ORZ: "report v2\n", NOTE: "note v2\n", "other.txt": "changed\n"})
        self.published = self.publish_by_cherry_pick(self.source)
        self.write_semaphore([self.source], [NOTE])
        result = self.guard()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("вне собственных файлов", result.stderr)
        self.assertEqual(self.receipt_lines(), [])

    def test_c_commit_outside_frozen_claims_is_refused(self) -> None:
        self.prepare_standard()
        self.write_semaphore([self.source], [NOTE], frozen=[])
        result = self.guard()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.receipt_lines(), [])

    def test_d_target_not_main_is_refused(self) -> None:
        self.prepare_standard()
        result = self.guard("--target-ref", "refs/heads/pilot")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.receipt_lines(), [])

    def test_d_root_governance_hint(self) -> None:
        self.prepare_standard()
        for name in ("iwe-root", "DS-gov"):
            result = self.guard(repo=name)
            self.assertNotEqual(result.returncode, 0, name)
            self.assertIn("пишет само закрытие, повторите close", result.stderr, name)
        self.assertEqual(self.receipt_lines(), [])

    def test_d_unknown_repository_is_refused(self) -> None:
        self.prepare_standard()
        result = self.guard(repo="nosuchrepo")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.receipt_lines(), [])

    def test_d_failed_sessions_conditions_name_the_working_path(self) -> None:
        self.prepare_standard()
        self.write_semaphore([self.source], [NOTE], frozen=[])
        result = self.guard()
        self.assertIn("ds-publish.sh с IWE_PUBLICATION_SESSION_ID", result.stderr)

    def test_e_repeat_is_idempotent(self) -> None:
        self.prepare_standard()
        self.assertEqual(self.guard().returncode, 0)
        before = self.sem.read_text()
        again = self.guard()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(self.sem.read_text(), before)
        self.assertEqual(len(self.receipt_lines()), 1)

    def test_e_stale_duplicate_receipt_is_refused(self) -> None:
        self.prepare_standard()
        self.assertEqual(self.guard().returncode, 0)
        record = json.loads(self.receipt_lines()[0][len(receipts.PREFIX):])
        record["published_paths"][0]["entry"]["oid"] = "0" * 40
        text = self.sem.read_text().replace(self.receipt_lines()[0],
                                            receipts.PREFIX + json.dumps(record, sort_keys=True))
        self.sem.write_text(text)
        before = self.sem.read_text()
        result = self.guard()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("не проходит проверку", result.stderr)
        self.assertEqual(self.sem.read_text(), before)

    def test_g_symlink_is_refused(self) -> None:
        self.source = self.local_commit({ORZ: "report v2\n", NOTE: "link:other.txt"})
        self.published = self.publish_by_cherry_pick(self.source)
        self.write_semaphore([self.source], [NOTE])
        result = self.guard()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("удаление, симлинк", result.stderr)
        self.assertEqual(self.receipt_lines(), [])

    def test_g_deletion_is_refused(self) -> None:
        self.source = self.local_commit({ORZ: "report v2\n", NOTE: None})
        self.published = self.publish_by_cherry_pick(self.source)
        self.write_semaphore([self.source], [NOTE])
        result = self.guard()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("удаление, симлинк", result.stderr)
        self.assertEqual(self.receipt_lines(), [])

    def test_h_digest_and_claims_stay_unchanged(self) -> None:
        self.prepare_standard()
        before = self.sem.read_text()
        self.assertEqual(self.guard().returncode, 0)
        self.assertEqual(self.semaphore_without_receipts(), before)

    def test_i_unproven_claim_reports_and_keeps_recorded(self) -> None:
        self.prepare_standard()
        self.put(self.repo, "notes/b.md", "unpublished\n")
        git(self.repo, "add", "--", "notes/b.md")
        git(self.repo, "commit", "-m", "never published")
        extra = git(self.repo, "rev-parse", "HEAD")
        self.write_semaphore([self.source, extra], [NOTE])
        result = self.guard()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("добавлено: " + self.source, result.stdout)
        self.assertIn("осталось недоказанным: " + extra, result.stdout)
        self.assertEqual(len(self.receipt_lines()), 1)


if __name__ == "__main__":
    unittest.main()
