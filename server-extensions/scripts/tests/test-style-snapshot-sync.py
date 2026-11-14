#!/usr/bin/env python3
"""Tests for scripts/style-snapshot-sync.py (WP-7 F309) on a throwaway pack repo."""

import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "style-snapshot-sync.py")
PACK_FILE = "pack/digital-platform/02-domain-entities/communication-style-base.md"
GIT_ENV = dict(
    os.environ,
    GIT_AUTHOR_NAME="t",
    GIT_AUTHOR_EMAIL="t@t",
    GIT_COMMITTER_NAME="t",
    GIT_COMMITTER_EMAIL="t@t",
)


class SnapshotSyncTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.pack = os.path.join(self.tmp.name, "pack")
        self.snapshot = os.path.join(self.tmp.name, "s0-core.md")
        os.makedirs(os.path.join(self.pack, os.path.dirname(PACK_FILE)))
        self.git("init", "-q")
        self.write_pack("---\nname: base\n---\n\n# Стиль\n\n6. Дальше: кто[, где]: что\n")
        self.git("add", PACK_FILE)
        self.git("commit", "-q", "-m", "pack v1")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", self.pack, *args], capture_output=True, text=True, check=True, env=GIT_ENV
        ).stdout.strip()

    def write_pack(self, text):
        with open(os.path.join(self.pack, PACK_FILE), "w", encoding="utf-8") as handle:
            handle.write(text)

    def run_tool(self, mode):
        res = subprocess.run(
            [sys.executable, SCRIPT, mode, "--pack-dir", self.pack, "--snapshot", self.snapshot],
            capture_output=True, text=True, check=False,
        )
        return res.returncode, res.stdout + res.stderr

    def read_snapshot(self):
        with open(self.snapshot, encoding="utf-8") as handle:
            return handle.read()

    def test_write_then_check_passes_and_body_is_the_pack_body(self):
        self.assertEqual(self.run_tool("--write")[0], 0)
        text = self.read_snapshot()
        self.assertIn(f'source_sha: "{self.git("rev-parse", "HEAD")}"', text)
        self.assertTrue(text.endswith("\n# Стиль\n\n6. Дальше: кто[, где]: что\n"), text)
        self.assertNotIn("name: base", text)
        code, out = self.run_tool("--check")
        self.assertEqual(code, 0, out)

    def test_one_changed_byte_fails_check(self):
        self.run_tool("--write")
        text = self.read_snapshot().replace("Дальше", "Дальшe")  # Cyrillic е -> Latin e
        with open(self.snapshot, "w", encoding="utf-8") as handle:
            handle.write(text)
        code, out = self.run_tool("--check")
        self.assertEqual(code, 1, out)
        self.assertIn("differs from", out)

    def test_unknown_sha_fails(self):
        self.run_tool("--write")
        text = self.read_snapshot()
        sha = self.git("rev-parse", "HEAD")
        with open(self.snapshot, "w", encoding="utf-8") as handle:
            handle.write(text.replace(sha, "0" * 40))
        code, out = self.run_tool("--check")
        self.assertEqual(code, 2, out)

    def test_missing_pack_file_at_sha_fails(self):
        self.run_tool("--write")
        self.git("rm", "-q", PACK_FILE)
        self.git("commit", "-q", "-m", "drop file")
        text = self.read_snapshot()
        with open(self.snapshot, "w", encoding="utf-8") as handle:
            handle.write(text.replace(text.split('source_sha: "')[1][:40], self.git("rev-parse", "HEAD")))
        code, out = self.run_tool("--check")
        self.assertEqual(code, 2, out)

    def test_pack_moving_on_keeps_check_green_and_drift_reports(self):
        self.run_tool("--write")
        self.write_pack("---\nname: base\n---\n\n# Стиль v2\n")
        self.git("commit", "-q", "-am", "pack v2")
        self.assertEqual(self.run_tool("--check")[0], 0)
        code, out = self.run_tool("--drift")
        self.assertEqual(code, 1, out)
        self.assertIn("pack moved", out)

    def test_write_refuses_uncommitted_pack_edit(self):
        self.write_pack("---\nname: base\n---\n\nuncommitted\n")
        code, out = self.run_tool("--write")
        self.assertEqual(code, 2, out)
        self.assertFalse(os.path.exists(self.snapshot))

    def test_missing_pack_checkout_fails(self):
        res = subprocess.run(
            [sys.executable, SCRIPT, "--check", "--pack-dir", os.path.join(self.tmp.name, "nope"),
             "--snapshot", self.snapshot],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(res.returncode, 2, res.stderr)


if __name__ == "__main__":
    unittest.main()
