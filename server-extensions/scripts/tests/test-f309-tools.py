#!/usr/bin/env python3
"""Tests for the WP-7 F309 tools: blocking-rules digest, memory sweep proposal,
pilot English-word collector. Fixtures only; no real memory or transcripts."""

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent


def run(script, *args):
    res = subprocess.run([sys.executable, str(SCRIPTS / script), *args], capture_output=True, text=True, check=False)
    return res.returncode, res.stdout + res.stderr


class DigestTest(unittest.TestCase):
    def test_real_agents_file_fits_window_and_lists_every_critical_section(self):
        code, out = run("blocking-rules-digest.py", "--agents", str(ROOT / "AGENTS.md"), "--print")
        self.assertEqual(code, 0, out)
        self.assertLessEqual(len(out), 10000)
        agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
        critical = [line[3:].strip() for line in agents.splitlines() if line.startswith("## ") and "CRITICAL" in line]
        self.assertTrue(critical)
        for heading in critical:
            self.assertIn(f"**{heading}.**", out)
        self.assertIn("**A12 (", out)
        self.assertIn("**A14 (", out)

    def test_check_detects_stale_digest(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "AGENTS.md"
            self.assertEqual(run("blocking-rules-digest.py", "--agents", str(ROOT / "AGENTS.md"), "--write", str(target))[0], 0)
            self.assertEqual(run("blocking-rules-digest.py", "--agents", str(ROOT / "AGENTS.md"), "--check", str(target))[0], 0)
            target.write_text(target.read_text(encoding="utf-8") + "x", encoding="utf-8")
            self.assertEqual(run("blocking-rules-digest.py", "--agents", str(ROOT / "AGENTS.md"), "--check", str(target))[0], 1)

    def test_oversized_digest_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            agents = Path(tmp) / "AGENTS.md"
            agents.write_text("".join(f"## Rule {i} — CRITICAL\n\n**{'x' * 300}.**\n\n" for i in range(40)), encoding="utf-8")
            code, out = run("blocking-rules-digest.py", "--agents", str(agents), "--print")
            self.assertEqual(code, 1, out)
            self.assertIn("over the 10000 window", out)


class SweepTest(unittest.TestCase):
    def test_groups(self):
        with tempfile.TemporaryDirectory() as tmp:
            mem, reg = Path(tmp) / "memory", Path(tmp) / "WP-REGISTRY.md"
            mem.mkdir()
            reg.write_text("| ~~100~~ | ~~P2~~ | ~~Old~~ | ✅ | ~~x~~ |\n| 200 | P1 | Live | 🔄 | x |\n", encoding="utf-8")
            (mem / "MEMORY.md").write_text("index", encoding="utf-8")
            (mem / "project_wp100_done.md").write_text("---\ndescription: РП-100 status\n---\n", encoding="utf-8")
            (mem / "project_wp200_live.md").write_text("---\ndescription: РП-200 status\n---\n", encoding="utf-8")
            old = mem / "lessons_wp100_old.md"
            old.write_text("---\ndescription: lesson of WP-100\n---\n", encoding="utf-8")
            past = time.time() - 60 * 86400
            os.utime(old, (past, past))
            for name in ("project_wp100_done.md", "project_wp200_live.md"):
                os.utime(mem / name, (past, past))
            (mem / "feedback_new.md").write_text("---\ndescription: fresh\n---\n", encoding="utf-8")
            code, out = run("memory-sweep-propose.py", "--memory", str(mem), "--registry", str(reg))
            self.assertEqual(code, 0, out)
            delete = out.split("## Кандидаты на удаление")[1].split("## ")[0]
            review = out.split("## На разбор")[1].split("## ")[0]
            new = out.split("## Новые")[1]
            self.assertIn("project_wp100_done.md", delete)
            self.assertNotIn("project_wp200_live.md", out)
            self.assertIn("lessons_wp100_old.md", review)
            self.assertIn("feedback_new.md", new)
            self.assertNotIn("MEMORY.md`", out)


class EnglishWordsTest(unittest.TestCase):
    def test_counts_only_pilot_russian_messages_and_skips_known_words(self):
        with tempfile.TemporaryDirectory() as tmp:
            s1 = Path(tmp) / "s1.md"
            s1.write_text("**Whitelist** (можно без перевода): commit, push. Пополняется.\n", encoding="utf-8")
            project = Path(tmp) / "projects" / "-Users-x-IWE"
            project.mkdir(parents=True)
            rows = [
                {"type": "user", "message": {"content": "сделай, пожалуйста, rebase и commit, проверь результат, потом снова rebase"}},
                {"type": "user", "message": {"content": "This is a long English skill text with rebase rebase rebase"}},
                {"type": "user", "isSidechain": True, "message": {"content": "агент пишет rollout rollout"}},
                {"type": "user", "message": {"content": "посмотри `deploy` в файле deploy.sh и /tmp/deploy"}},
                {"type": "user", "message": {"content": "Марат и Grok, проверьте Grok, пожалуйста, ещё раз"}},
                {"type": "assistant", "message": {"content": "ответ про rollout rollout"}},
            ]
            (project / "t.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows), encoding="utf-8")
            code, out = run("pilot-english-words.py", "--s1", str(s1), "--transcripts", str(Path(tmp) / "projects"))
            self.assertEqual(code, 0, out)
            self.assertIn("- rebase — 2", out)
            for absent in ("commit", "rollout", "deploy", "english", "grok"):
                self.assertNotIn(f"- {absent} ", out)


if __name__ == "__main__":
    unittest.main()
