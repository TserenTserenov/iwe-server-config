#!/usr/bin/env python3
"""Synthetic-repo test for scripts/canon-subset-check.py (WP-530 Ф72).

Builds a throwaway origin + canon clone, then asserts the verdict the tool prints
for each path: EQUAL / ANCESTRAL_PATH / SUBSET / UNIQUE, plus the exit code.
Run: python3 scripts/tests/test_canon_subset_check.py
"""
import os
import re
import subprocess
import sys
import tempfile
import unittest

TOOL = os.environ.get("CANON_SUBSET_CHECK") or os.path.realpath(
    os.path.join(os.path.dirname(__file__), "..", "canon-subset-check.py"))  # override lets a mutated copy be tested
ROW_RE = re.compile(r"^\s+(EQUAL|ANCESTRAL_PATH|SUBSET|UNIQUE)\s+(?:\[(..)\] )?(\S+)")
GIT_ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t", "GIT_NO_REPLACE_OBJECTS": "1"}


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True, env=GIT_ENV).stdout


def write(repo, name, text):
    with open(os.path.join(repo, name), "w", encoding="utf-8") as fh:
        fh.write(text)


def commit(repo, msg, *paths):
    git(repo, "add", "--", *paths)
    git(repo, "commit", "-q", "-m", msg)


def run_tool(canon):
    proc = subprocess.run([sys.executable, TOOL, canon, "origin/main"], capture_output=True, text=True, env=GIT_ENV)
    verdicts = {}
    for line in proc.stdout.splitlines():
        m = ROW_RE.match(line)
        if m:
            verdicts[m.group(3)] = m.group(1)
    return proc.returncode, verdicts, proc.stdout


class CanonSubsetCheck(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = os.path.realpath(self._tmp.name)
        self.origin = os.path.join(root, "origin.git")
        self.canon = os.path.join(root, "canon")
        pub = os.path.join(root, "pub")
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", self.origin], check=True, env=GIT_ENV)
        subprocess.run(["git", "clone", "-q", self.origin, pub], check=True, capture_output=True, env=GIT_ENV)
        git(pub, "checkout", "-q", "-b", "main")
        # history on origin: a.txt v1 -> v2 -> v3, eq.txt old -> new, feed.md 3 lines, gone.txt created then deleted
        write(pub, "a.txt", "v1\n"); write(pub, "eq.txt", "old\n"); write(pub, "feed.md", "L1\nL2\nL3\n")
        write(pub, "gone.txt", "g1\n"); write(pub, "u.txt", "base\n")
        commit(pub, "base", "a.txt", "eq.txt", "feed.md", "gone.txt", "u.txt")
        git(pub, "push", "-q", "origin", "main")
        subprocess.run(["git", "clone", "-q", self.origin, self.canon], check=True, capture_output=True, env=GIT_ENV)
        write(pub, "a.txt", "v2\n"); commit(pub, "a v2", "a.txt")
        write(pub, "a.txt", "v3\n"); write(pub, "eq.txt", "new\n"); write(pub, "gone.txt", "g2\n")
        commit(pub, "a v3, eq new, gone g2", "a.txt", "eq.txt", "gone.txt")
        git(pub, "rm", "-q", "gone.txt"); git(pub, "commit", "-q", "-m", "drop gone")
        git(pub, "push", "-q", "origin", "main")
        git(self.canon, "fetch", "-q", "origin")

    def test_dirty_path_verdicts(self):
        write(self.canon, "eq.txt", "new\n")            # equals the origin tip
        write(self.canon, "a.txt", "v2\n")              # earlier origin version of a live path
        write(self.canon, "feed.md", "L1\nL3\n")        # never a whole blob on origin, every line is
        write(self.canon, "u.txt", "novel line\n")      # origin has nothing like it
        code, verdicts, out = run_tool(self.canon)
        self.assertEqual(verdicts["eq.txt"], "EQUAL", out)
        self.assertEqual(verdicts["a.txt"], "ANCESTRAL_PATH", out)
        self.assertEqual(verdicts["feed.md"], "SUBSET", out)
        self.assertEqual(verdicts["u.txt"], "UNIQUE", out)
        self.assertEqual(code, 1, out)
        self.assertIn("UNIQUE paths: 1", out)

    def test_nothing_unique_exits_zero(self):
        write(self.canon, "eq.txt", "new\n")
        write(self.canon, "a.txt", "v2\n")
        write(self.canon, "feed.md", "L1\nL3\n")
        code, verdicts, out = run_tool(self.canon)
        self.assertEqual(sorted(verdicts.values()), ["ANCESTRAL_PATH", "EQUAL", "SUBSET"], out)
        self.assertEqual(code, 0, out)
        self.assertIn("UNIQUE paths: 0", out)

    def test_deleted_path_on_origin_is_never_ancestral(self):
        write(self.canon, "gone.txt", "g2\n")           # a real earlier version, but the path no longer exists on origin
        code, verdicts, out = run_tool(self.canon)
        self.assertEqual(verdicts["gone.txt"], "UNIQUE", out)
        self.assertIn("absent on origin", out)
        self.assertEqual(code, 1, out)

    def test_local_only_commit_paths_are_classified(self):
        # eq.txt rides along so the commit is not patch-equivalent to origin's own "a v2" commit (git cherry would skip it)
        write(self.canon, "a.txt", "v2\n"); write(self.canon, "eq.txt", "new\n")
        commit(self.canon, "local a v2 and eq new", "a.txt", "eq.txt")
        write(self.canon, "u.txt", "novel line\n"); commit(self.canon, "local novel u", "u.txt")
        code, verdicts, out = run_tool(self.canon)
        self.assertEqual(verdicts["a.txt"], "ANCESTRAL_PATH", out)
        self.assertEqual(verdicts["eq.txt"], "EQUAL", out)
        self.assertEqual(verdicts["u.txt"], "UNIQUE", out)
        self.assertEqual(code, 1, out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
