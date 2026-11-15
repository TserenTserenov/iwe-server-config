"""AR.005 integration cases use temporary repositories, never real session state."""
from __future__ import annotations

import json
import datetime as dt
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

LIB = Path(__file__).resolve().parents[1] / "lib"
sys.path.insert(0, str(LIB))
import publication_receipt as proof  # noqa: E402
import session_close_evidence as close  # noqa: E402


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True,
                                   stderr=subprocess.DEVNULL).strip()


class SessionCloseEvidenceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / "workspace"
        self.root.mkdir()
        self.gov = self.clone("DS-my-strategy")
        self.reports = self.clone("MC-sessions")
        self.report = "2026-11/2026-11-14-WP-484.md"
        self.content = "# Сессия\n\n## Главный инсайт\n\nПроверяем сохранность работы.\n\n## Достигнуто\n\nРезультат.\n"
        self.gov_sha = self.publish(self.gov, "inbox/WP-484.md", "Own work\n")
        self.report_sha = self.publish(self.reports, self.report, self.content)
        self.sem = self.root / ".iwe-runtime/sessions/codex-owned.open"
        self.sem.parent.mkdir(parents=True)
        self.sem.write_text(
            "---\nagent: codex\nsession_id: owned\nharness_session_id: native-thread\n"
            "close_path: quick-close\n"
            f"governance_worktree: {self.gov}\norz_sessions_dir: {self.reports}\n"
            f"orz_file: {self.report}\n---\n"
            f"file: {self.report}\nfile: inbox/open-sessions.log\n"
            + self.file_claim(self.gov, "inbox/WP-484.md")
            + self.file_claim(self.reports, self.report)
            + f"commit: DS-my-strategy {self.gov_sha}\n"
            + f"commit: MC-sessions {self.report_sha}\n"
        )

    def clone(self, name: str) -> Path:
        remote = self.base / (name + ".git")
        subprocess.run(["git", "init", "--bare", "--initial-branch=main", str(remote)],
                       check=True, capture_output=True)
        repo = self.root / name
        subprocess.run(["git", "clone", str(remote), str(repo)], check=True, capture_output=True)
        git(repo, "config", "user.name", "Test")
        git(repo, "config", "user.email", "test@example.invalid")
        return repo

    @staticmethod
    def file_claim(repo: Path, path: str) -> str:
        return f"file: {path}\nfile_v2: {json.dumps({'path': path, 'repo': str(repo / '.git')})}\n"

    def publish(self, repo: Path, path: str, content: str) -> str:
        target = repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        git(repo, "add", "--", path)
        git(repo, "commit", "-m", path)
        git(repo, "push", "origin", "HEAD:main")
        return git(repo, "rev-parse", "HEAD")

    def verify(self) -> dict:
        return close.verify_session(self.root, "codex", "owned", "native-thread")

    def refused(self) -> None:
        with self.assertRaises((proof.ProofError, OSError, ValueError)):
            self.verify()

    def test_published_session_with_yesterday_report(self) -> None:
        result = self.verify()
        self.assertEqual(result["result"], "ok")
        self.assertEqual(result["files_checked"], 2)
        self.assertEqual(result["commits_checked"], 2)
        self.assertEqual(result["report"], str(self.reports / self.report))

    def test_foreign_dirty_and_unpublished_files_do_not_block(self) -> None:
        (self.gov / "foreign").write_text("foreign work\n")
        git(self.gov, "add", "foreign")
        git(self.gov, "commit", "-m", "foreign unpublished work")
        (self.gov / "foreign").write_text("foreign edit\n")
        self.assertEqual(self.verify()["result"], "ok")

    def test_dirty_owned_file_blocks(self) -> None:
        (self.gov / "inbox/WP-484.md").write_text("Unpublished\n")
        self.refused()

    def test_staged_owned_file_blocks(self) -> None:
        (self.gov / "inbox/WP-484.md").write_text("Unpublished\n")
        git(self.gov, "add", "inbox/WP-484.md")
        self.refused()

    def test_staged_edit_with_published_working_bytes_blocks(self) -> None:
        target = self.gov / "inbox/WP-484.md"
        original = target.read_text()
        target.write_text("Unpublished staged edit\n")
        git(self.gov, "add", "inbox/WP-484.md")
        target.write_text(original)
        self.assertTrue(git(self.gov, "diff", "--cached", "--", "inbox/WP-484.md"))
        self.refused()

    def test_clean_unclaimed_commit_on_owned_path_blocks(self) -> None:
        (self.gov / "inbox/WP-484.md").write_text("Unpublished\n")
        git(self.gov, "add", "inbox/WP-484.md")
        git(self.gov, "commit", "-m", "unregistered unpublished work")
        self.refused()

    def test_missing_owned_report_blocks(self) -> None:
        (self.reports / self.report).unlink()
        self.refused()

    def test_published_empty_insight_blocks(self) -> None:
        sha = self.publish(self.reports, self.report, "# Session\n\n## Главный инсайт\n\n## Достигнуто\nDone\n")
        self.sem.write_text(self.sem.read_text().replace(self.report_sha, sha))
        self.refused()

    def test_foreign_harness_blocks(self) -> None:
        with self.assertRaises(proof.ProofError):
            close.verify_session(self.root, "codex", "owned", "different-thread")

    def test_missing_session_does_not_fall_back(self) -> None:
        with self.assertRaises(OSError):
            close.verify_session(self.root, "codex", "missing", "native-thread")

    def test_mismatched_identity_blocks(self) -> None:
        self.sem.write_text(self.sem.read_text().replace("session_id: owned", "session_id: foreign"))
        self.refused()

    def test_symlink_semaphore_blocks(self) -> None:
        target = self.sem.with_suffix(".saved")
        self.sem.rename(target)
        self.sem.symlink_to(target)
        self.refused()

    def test_missing_report_attribution_blocks(self) -> None:
        self.sem.write_text(self.sem.read_text().replace(f"orz_file: {self.report}", "orz_file: ../foreign"))
        self.refused()

    def test_unqualified_file_blocks(self) -> None:
        self.sem.write_text(self.sem.read_text() + "file: unexpected.txt\n")
        self.refused()

    def test_ignored_owned_file_blocks(self) -> None:
        (self.gov / ".git/info").mkdir(exist_ok=True)
        (self.gov / ".git/info/exclude").write_text("secret-output\n")
        (self.gov / "secret-output").write_text("not published\n")
        self.sem.write_text(self.sem.read_text() + self.file_claim(self.gov, "secret-output"))
        self.refused()

    def test_duplicate_attribution_key_blocks(self) -> None:
        self.sem.write_text(self.sem.read_text().replace('"path": "inbox/WP-484.md"',
                           '"path": "wrong", "path": "inbox/WP-484.md"'))
        self.refused()

    def test_malformed_commit_blocks(self) -> None:
        self.sem.write_text(self.sem.read_text() + "commit: malformed\n")
        self.refused()

    def test_claim_prefix_without_delimiter_blocks(self) -> None:
        original = self.sem.read_text()
        for extra in ("file:unpublished", "file_v2:{}", "commit:unpublished", " file: hidden", "commit : hidden"):
            with self.subTest(extra=extra):
                self.sem.write_text(original + extra + "\n")
                self.refused()

    def test_recorded_report_checkout_is_always_checked(self) -> None:
        checkout = self.base / "report-worktree"
        git(self.reports, "worktree", "add", "-b", "report-owned", str(checkout))
        self.sem.write_text(self.sem.read_text().replace(f"orz_sessions_dir: {self.reports}",
                                                       f"orz_sessions_dir: {checkout}"))
        self.assertEqual(self.verify()["result"], "ok")
        (checkout / self.report).write_text(self.content + "Unpublished report change\n")
        self.refused()

    def test_unregistered_report_checkout_blocks(self) -> None:
        checkout = self.base / "report-worktree"
        git(self.reports, "worktree", "add", "-b", "report-owned", str(checkout))
        copied = self.base / "copied-worktree"
        shutil.copytree(checkout, copied)
        self.sem.write_text(self.sem.read_text().replace(f"orz_sessions_dir: {self.reports}",
                                                       f"orz_sessions_dir: {copied}"))
        self.refused()

    def test_published_untracked_report_projection_requires_exact_bytes_and_empty_index(self) -> None:
        checkout = self.base / "report-source"
        git(self.reports, "worktree", "add", "-b", "report-source", str(checkout))
        new_report = "2026-11/2026-11-15-WP-484.md"
        source = self.publish(checkout, new_report, self.content)
        self.sem.write_text(self.sem.read_text().replace(self.report, new_report).replace(
            f"commit: MC-sessions {self.report_sha}",
            f"commit: MC-sessions {source} {checkout} report-source"))
        target = self.reports / new_report
        target.write_text(self.content)
        self.assertTrue(git(self.reports, "status", "--porcelain", "--", new_report).startswith("??"))
        self.assertEqual(self.verify()["result"], "ok")
        target.write_text("Unpublished projection\n")
        self.refused()
        git(self.reports, "add", new_report)
        target.write_text(self.content)
        self.refused()

    def test_missing_remote_blocks(self) -> None:
        git(self.gov, "remote", "set-url", "origin", str(self.base / "nonexistent"))
        self.refused()

    def test_remote_deleted_after_previous_fetch_blocks(self) -> None:
        remote = Path(git(self.gov, "remote", "get-url", "origin"))
        git(remote, "update-ref", "-d", "refs/heads/main")
        self.refused()

    def test_cherry_pick_in_registered_worktree(self) -> None:
        worktree = self.base / "owned-worktree"
        git(self.gov, "worktree", "add", "-b", "owned", str(worktree))
        (worktree / "inbox/WP-484.md").write_text("Owned change\n")
        git(worktree, "add", "inbox/WP-484.md")
        git(worktree, "commit", "-m", "own change")
        source = git(worktree, "rev-parse", "HEAD")
        self.publish(self.gov, "foreign", "parallel remote change\n")
        git(self.gov, "cherry-pick", source)
        git(self.gov, "push", "origin", "HEAD:main")
        anchor = git(self.gov, "rev-parse", "HEAD")
        self.sem.write_text(self.sem.read_text().replace(f"governance_worktree: {self.gov}",
                            f"governance_worktree: {worktree}").replace(
                            f"commit: DS-my-strategy {self.gov_sha}",
                            f"commit: DS-my-strategy {source} {worktree} owned"))
        proof.record(self.gov, self.sem, "DS-my-strategy", anchor)
        (self.gov / "inbox/WP-484.md").write_text("another agent's ongoing edit\n")
        self.assertEqual(self.verify()["result"], "ok")
        self.sem.write_text("\n".join(line for line in self.sem.read_text().splitlines()
                                     if not line.startswith(proof.PREFIX)) + "\n")
        self.refused()

    def test_changed_path_missing_from_scope_blocks(self) -> None:
        self.sem.write_text(self.sem.read_text().replace(self.file_claim(self.gov, "inbox/WP-484.md"),
                           self.file_claim(self.gov, "unrelated")))
        self.refused()

    def test_multiple_owned_commits_in_one_squash(self) -> None:
        checkout = self.base / "squashed-worktree"
        git(self.gov, "worktree", "add", "-b", "owned-squash", str(checkout))
        sources = []
        for content in ("First owned change\n", "Second owned change\n"):
            (checkout / "inbox/WP-484.md").write_text(content)
            git(checkout, "add", "inbox/WP-484.md")
            git(checkout, "commit", "-m", "owned change")
            sources.append(git(checkout, "rev-parse", "HEAD"))
        git(self.gov, "merge", "--squash", "owned-squash")
        git(self.gov, "commit", "-m", "published squash")
        git(self.gov, "push", "origin", "HEAD:main")
        anchor = git(self.gov, "rev-parse", "HEAD")
        claims = "\n".join(f"commit: DS-my-strategy {sha} {checkout} owned-squash" for sha in sources)
        self.sem.write_text(self.sem.read_text().replace(f"governance_worktree: {self.gov}",
                            f"governance_worktree: {checkout}").replace(
                            f"commit: DS-my-strategy {self.gov_sha}", claims))
        proof.record(self.gov, self.sem, "DS-my-strategy", anchor)
        self.assertEqual(self.verify()["result"], "ok")

    def trace(self, session_id: str = "owned", manual_marker: bool = False,
              section: str | None = "Quick Close") -> subprocess.CompletedProcess:
        protocol = self.base / "protocol.md"
        protocol.write_text("## Quick Close\n\n1. Publish [[gate:AR.005]]\n")
        state = self.base / "state"
        state.mkdir(exist_ok=True)
        if manual_marker:
            (state / "trace-owned-AR.005.done").touch()
        env = dict(os.environ, IWE_ROOT=str(self.root), IWE_AGENT="codex", IWE_SESSION_ID=session_id,
                   CODEX_THREAD_ID="native-thread", CLAUDE_SESSION_ID="owned",
                   RULE_SESSION_STATE_DIR=str(state), RULE_JOURNAL_DIR=str(self.base / "logs"))
        hook = LIB.parents[1] / ".claude/hooks/rule-engine.sh"
        command = ["bash", str(hook), "check-trace-satisfaction", "--protocol", str(protocol)]
        if section is not None:
            command.extend(["--section", section])
        return subprocess.run(command, env=env, text=True, capture_output=True)

    def test_rule_engine_consumes_real_session_proof(self) -> None:
        result = self.trace()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        parsed = json.loads(result.stdout)
        self.assertEqual(parsed["verdict"], "ok")
        self.assertEqual(parsed["publication_evidence"]["commits_checked"], 2)

    def test_manual_marker_cannot_override_failed_publication(self) -> None:
        (self.gov / "inbox/WP-484.md").write_text("not published\n")
        result = self.trace(manual_marker=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["unsatisfied"][0]["key"], "AR.005")

    def test_rule_engine_unknown_session_blocks(self) -> None:
        result = self.trace(session_id="missing", manual_marker=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["verdict"], "block")

    def test_rule_engine_missing_identity_blocks(self) -> None:
        result = self.trace(session_id="", manual_marker=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        parsed = json.loads(result.stdout)
        self.assertEqual(parsed["publication_evidence"]["result"], "block")
        self.assertEqual(parsed["unsatisfied"][0]["key"], "AR.005")

    def test_short_or_omitted_scope_cannot_restore_legacy_permission(self) -> None:
        for section in ("Quick", None):
            with self.subTest(section=section):
                result = self.trace(session_id="", manual_marker=True, section=section)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(json.loads(result.stdout)["publication_evidence"]["result"], "block")

    def calendar_trace(self, section: str | None) -> subprocess.CompletedProcess:
        today = dt.date.today()
        self.publish(self.gov, f"sessions/{today:%Y-%m}/{today:%Y-%m-%d}-calendar.md", self.content)
        protocol = self.root / ".claude/skills/day-close/SKILL.md"
        protocol.parent.mkdir(parents=True)
        protocol.write_text("## " + (section or "Day Close") + "\n\n1. Publish [[gate:AR.005]]\n")
        env = dict(os.environ, IWE_ROOT=str(self.root), IWE_AGENT="codex", IWE_SESSION_ID="",
                   CODEX_THREAD_ID="native-thread", RULE_REPO_DIR=str(self.gov),
                   RULE_SESSION_STATE_DIR=str(self.base / "calendar-state"),
                   RULE_JOURNAL_DIR=str(self.base / "calendar-logs"))
        command = ["bash", str(LIB.parents[1] / ".claude/hooks/rule-engine.sh"),
                   "check-trace-satisfaction", "--protocol", str(protocol)]
        if section is not None:
            command.extend(["--section", section])
        return subprocess.run(command, env=env, text=True, capture_output=True)

    def test_explicit_calendar_scope_keeps_existing_proof(self) -> None:
        result = self.calendar_trace("Week Close")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["verdict"], "ok")

    def test_registered_day_close_keeps_existing_proof(self) -> None:
        result = self.calendar_trace(None)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["verdict"], "ok")


if __name__ == "__main__":
    unittest.main()
