"""close_scope_gaps: unclaimed files of claimed commits are reported before PREPARED (WP-484 F310).

bug-2026-11-17-multiline-note-file-claim-blocks-product-receipt: two changed files of a claimed
bot commit were claimed only inside one glued multi-line note-file claim; the product receipt
refused after PREPARED, when the scope could no longer be completed.
"""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "close_scope_gaps", Path(__file__).parents[1] / "lib/close_scope_gaps.py")
gaps_tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gaps_tool)


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


class CloseScopeGapsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.product = self.make_repo(self.root / "product")
        self.nested = self.make_repo(self.root / "DS-IT-systems" / "nested")
        self.governance = self.make_repo(self.root / "governance")
        self.commit = self.commit_files(self.product, ["src/a.py", "tests/test_a.py", "docs/a.md"])

    def make_repo(self, path):
        path.mkdir(parents=True)
        git(path, "init", "-qb", "main")
        git(path, "config", "user.name", "Test")
        git(path, "config", "user.email", "test@example.invalid")
        git(path, "remote", "add", "origin", f"https://example.invalid/{path.name}.git")
        (path / "seed").write_text("seed\n")
        git(path, "add", "seed")
        git(path, "commit", "-qm", "seed")
        return path

    def commit_files(self, repo, paths):
        for rel in paths:
            target = repo / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(rel + "\n")
        git(repo, "add", *paths)
        git(repo, "commit", "-qm", "change")
        return git(repo, "rev-parse", "HEAD")

    def common(self, repo):
        return str(Path(git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve())

    def semaphore(self, name, commit, repo, claimed_paths):
        lines = ["agent: claude-code", "session_id: s1",
                 f"governance_worktree: {self.governance}",
                 f"commit: {name} {commit} - -"]
        for path in claimed_paths:
            lines += [f"file: {path}", "file_v2: " + json.dumps({"repo": self.common(repo), "path": path})]
        return ("\n".join(lines) + "\n").encode()

    def test_fully_claimed_commit_has_no_gaps(self):
        raw = self.semaphore("product", self.commit, self.product, ["src/a.py", "tests/test_a.py", "docs/a.md"])
        self.assertEqual(gaps_tool.gaps(raw, self.root), [])

    def test_unclaimed_files_are_reported(self):
        raw = self.semaphore("product", self.commit, self.product, ["src/a.py"])
        self.assertEqual(gaps_tool.gaps(raw, self.root),
                         [("product", self.commit, ["docs/a.md", "tests/test_a.py"])])

    def test_glued_multiline_claim_covers_nothing(self):
        # the 13.11 case: several paths glued into one claim through newlines
        glued = "src/a.py\ntests/test_a.py\ndocs/a.md"
        raw = self.semaphore("product", self.commit, self.product, [])
        raw += ("file_v2: " + json.dumps({"repo": self.common(self.product), "path": glued}) + "\n").encode()
        self.assertEqual(gaps_tool.gaps(raw, self.root),
                         [("product", self.commit, ["docs/a.md", "src/a.py", "tests/test_a.py"])])

    def test_directory_claim_covers_its_files(self):
        raw = self.semaphore("product", self.commit, self.product, ["src/", "tests/", "docs/"])
        self.assertEqual(gaps_tool.gaps(raw, self.root), [])

    def test_claims_of_another_repository_do_not_count(self):
        raw = self.semaphore("product", self.commit, self.governance, ["src/a.py", "tests/test_a.py", "docs/a.md"])
        self.assertEqual(len(gaps_tool.gaps(raw, self.root)[0][2]), 3)

    def test_governance_and_nested_repositories_are_out_of_scope(self):
        gov_commit = self.commit_files(self.governance, ["plan.md"])
        nested_commit = self.commit_files(self.nested, ["bot.py"])
        raw = self.semaphore("governance", gov_commit, self.governance, [])
        raw += f"commit: nested {nested_commit} - -\n".encode()
        self.assertEqual(gaps_tool.gaps(raw, self.root), [])

    def test_unreadable_claims_never_raise(self):
        raw = b"commit: product not-a-sha - -\ncommit: missing " + b"a" * 40 + b" - -\n"
        self.assertEqual(gaps_tool.gaps(raw, self.root), [])
        self.assertEqual(gaps_tool.main([str(self.root / "no-such.open"), str(self.root)]), 0)


if __name__ == "__main__":
    unittest.main()
