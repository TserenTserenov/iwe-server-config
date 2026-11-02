"""Tests for canon-to-server memory delivery (WP-529 Ф248).

Covers classify-memory.py (canon snapshot wins over the Mac's live memory)
and the overwrite guard in modules/iwe-extensions-sync.nix, run as plain bash
against synthetic directories after substituting the Nix interpolations.

Run: python3 -m unittest scripts/tests/test_canon_delivery.py
"""

import hashlib
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CLASSIFIER = REPO / "scripts" / "classify-memory.py"
MODULE = REPO / "modules" / "iwe-extensions-sync.nix"

MANAGED = "---\ndelivery: managed\ndelivery_authority: root-repository\n---\n"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def guard_script(src, home):
    """The overwrite-guard subshell of the activation script, made runnable outside NixOS."""
    text = MODULE.read_text()
    start = text.index("        (\n          LIVE_MEMORY=")
    end = text.index("\n        )\n", start) + len("\n        )\n")
    snippet = text[start:end]
    snippet = re.sub(r"\$\{pkgs\.[a-z]+\}/bin/", "", snippet)
    snippet = snippet.replace("-o ${cfg.user} -g users ", "")
    snippet = re.sub(r"chown -R \$\{cfg\.user\}:users [^\n]*", ":", snippet)
    snippet = snippet.replace("/home/${cfg.user}/.claude/projects/-home-${cfg.user}-IWE/memory", f"{home}/memory")
    snippet = snippet.replace("/home/${cfg.user}/IWE/.iwe-runtime", f"{home}/runtime")
    snippet = snippet.replace("${src}", str(src))
    assert "${" not in snippet, "unsubstituted Nix interpolation left in guard snippet"
    return snippet


class ClassifierTest(unittest.TestCase):
    def run_classifier(self, mac, root, staging):
        env = {**os.environ, "CLASSIFY_MEMORY_MAC_DIR": str(mac), "IWE_EXTENSIONS_SOURCE_ROOT": str(root),
               "CLASSIFY_MEMORY_STAGING": str(staging)}
        return subprocess.run([sys.executable, str(CLASSIFIER)], env=env, capture_output=True, text=True)

    def test_canon_snapshot_wins_over_live_mac_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            mac, canon, staging = tmp / "mac", tmp / "root/.claude/memory-canon", tmp / "staging"
            mac.mkdir()
            canon.mkdir(parents=True)
            (canon / "protocol-open.md").write_text("canon text\n")
            (canon / "roles.md").write_text("canon roles\n")
            (mac / "protocol-open.md").write_text(MANAGED + "edited on mac, not published\n")
            (mac / "lessons_day_rituals.md").write_text(MANAGED + "managed non-canon\n")
            (mac / "personal.md").write_text("---\nowner: agent\n---\nprivate\n")

            r = self.run_classifier(mac, tmp / "root", staging)

            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual((staging / "protocol-open.md").read_text(), "canon text\n")
            self.assertEqual((staging / "roles.md").read_text(), "canon roles\n")
            self.assertEqual((staging / "lessons_day_rituals.md").read_text(), MANAGED + "managed non-canon\n")
            self.assertFalse((staging / "personal.md").exists())
            self.assertEqual((staging / "managed-memory-manifest.txt").read_text().split(),
                             ["lessons_day_rituals.md", "protocol-open.md", "roles.md"])

    def test_missing_canon_refuses_without_writing(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "mac").mkdir()
            (tmp / "mac" / "x.md").write_text(MANAGED + "x\n")
            r = self.run_classifier(tmp / "mac", tmp / "root", tmp / "staging")
            self.assertEqual(r.returncode, 1)
            self.assertFalse((tmp / "staging").exists())


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.src, self.home = self.tmp / "src", self.tmp / "home"
        (self.src / "memory").mkdir(parents=True)
        (self.home / "memory").mkdir(parents=True)
        (self.home / "runtime").mkdir()

    def deliver(self):
        r = subprocess.run(["bash", "-c", guard_script(self.src, self.home)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stderr

    def state(self):
        lines = (self.home / "runtime" / "memory-delivered.sha256").read_text().split("\n")
        return {l.split("  ")[1]: l.split("  ")[0] for l in lines if l}

    def test_first_delivery_creates_file_and_records_hash(self):
        (self.src / "memory" / "protocol-open.md").write_text("v1\n")
        self.deliver()
        live = self.home / "memory" / "protocol-open.md"
        self.assertEqual(live.read_text(), "v1\n")
        self.assertEqual(self.state()["protocol-open.md"], sha(live))

    def test_unedited_file_is_updated(self):
        (self.src / "memory" / "protocol-open.md").write_text("v1\n")
        self.deliver()
        (self.src / "memory" / "protocol-open.md").write_text("v2\n")
        self.deliver()
        self.assertEqual((self.home / "memory" / "protocol-open.md").read_text(), "v2\n")
        self.assertFalse((self.home / "runtime" / "memory-canon-pending" / "protocol-open.md").exists())

    def test_edit_on_server_stops_overwrite_and_parks_new_version(self):
        (self.src / "memory" / "protocol-open.md").write_text("v1\n")
        self.deliver()
        v1_sha = self.state()["protocol-open.md"]
        (self.home / "memory" / "protocol-open.md").write_text("v1 + server agent note\n")
        (self.src / "memory" / "protocol-open.md").write_text("v2\n")

        err = self.deliver()

        self.assertIn("правка мимо канона", err)
        self.assertEqual((self.home / "memory" / "protocol-open.md").read_text(), "v1 + server agent note\n")
        self.assertEqual((self.home / "runtime" / "memory-canon-pending" / "protocol-open.md").read_text(), "v2\n")
        self.assertEqual(self.state()["protocol-open.md"], v1_sha)

    def test_unrecorded_differing_file_is_not_overwritten(self):
        (self.home / "memory" / "roles.md").write_text("server-only history\n")
        (self.src / "memory" / "roles.md").write_text("canon\n")
        self.deliver()
        self.assertEqual((self.home / "memory" / "roles.md").read_text(), "server-only history\n")
        self.assertNotIn("roles.md", self.state())

    def test_non_markdown_files_are_copied_unguarded(self):
        (self.home / "memory" / "managed-memory-manifest.txt").write_text("old\n")
        (self.src / "memory" / "managed-memory-manifest.txt").write_text("new\n")
        self.deliver()
        self.assertEqual((self.home / "memory" / "managed-memory-manifest.txt").read_text(), "new\n")


if __name__ == "__main__":
    unittest.main()
