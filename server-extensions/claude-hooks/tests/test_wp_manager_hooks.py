#!/usr/bin/env python3
"""Tests for the WP Manager hooks (WP-626 F7): wp-manager-guard.py and wp-manager-answer-box.py.

Each case feeds the hook the JSON Claude Code sends and asserts the decision
(deny or pass) or what landed in the answer and message boxes.
Run: python3 .claude/hooks/tests/test_wp_manager_hooks.py
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HOOKS = Path(__file__).resolve().parent.parent
GUARD = os.environ.get("WP_MANAGER_GUARD") or str(HOOKS / "wp-manager-guard.py")
BOX = os.environ.get("WP_MANAGER_ANSWER_BOX") or str(HOOKS / "wp-manager-answer-box.py")
RUN = "/home/u/IWE/DS-my-strategy/inbox/WP-568/runs/wp568-2026-12-01-1"


class HookTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name) / "state"
        self.run_dir = Path(self.tmp.name) / "runs" / "wp1-1"
        (self.state / "sessions").mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def mark_manager(self, session="mgr"):
        (self.state / "sessions" / f"{session}.json").write_text(json.dumps({"run_dir": str(self.run_dir)}))

    def call(self, hook, event):
        env = {**os.environ, "IWE_WP_MANAGER_STATE": str(self.state)}
        res = subprocess.run([sys.executable, hook], input=json.dumps(event), capture_output=True,
                             text=True, env=env)
        self.assertEqual(res.returncode, 0, res.stderr)
        return json.loads(res.stdout) if res.stdout.strip() else None

    def decision(self, tool, tool_input, session="other"):
        out = self.call(GUARD, {"session_id": session, "tool_name": tool, "tool_input": tool_input})
        return out["hookSpecificOutput"]["permissionDecision"] if out else "pass"

    def bash(self, command, session="other"):
        return self.decision("Bash", {"command": command}, session)


class GuardEverySession(HookTest):
    def test_direct_write_to_journal_is_denied(self):
        self.assertEqual(self.decision("Write", {"file_path": f"{RUN}/events.jsonl"}), "deny")
        self.assertEqual(self.decision("Edit", {"file_path": f"{RUN}/protected/pilot-answers.jsonl"}), "deny")
        self.assertEqual(self.decision("Write", {"file_path": "/home/u/.iwe-runtime/wp-manager/sessions/x.json"}),
                         "deny")

    def test_ordinary_files_and_cards_pass(self):
        self.assertEqual(self.decision("Write", {"file_path": f"{RUN}/cards/R-1.md"}), "pass")
        self.assertEqual(self.decision("Edit", {"file_path": "/home/u/IWE/DS-my-strategy/inbox/WP-568/WP-568.md"}),
                         "pass")

    def test_shell_write_to_journal_is_denied_but_read_passes(self):
        self.assertEqual(self.bash(f"echo '{{}}' >> {RUN}/events.jsonl"), "deny")
        self.assertEqual(self.bash(f"sed -i 1d {RUN}/lease.json"), "deny")
        self.assertEqual(self.bash(f"tail -3 {RUN}/events.jsonl"), "pass")

    def test_answer_box_and_seed_are_not_touched_by_shell(self):
        self.assertEqual(self.bash(f"cat {RUN}/protected/seed"), "deny")
        self.assertEqual(self.bash(f"echo x >> {RUN}/protected/pilot-answers.jsonl"), "deny")

    def test_plain_journal_call_passes_even_with_symbols_in_payload(self):
        cmd = (f"python3 scripts/wp-run-journal.py append --run-dir {RUN} --epoch 1 "
               "--type decision-recorded --payload '{\"choice\": \"A -> B | C\"}'")
        self.assertEqual(self.bash(cmd), "pass")

    def test_journal_call_chained_with_box_write_is_denied(self):
        cmd = (f"python3 scripts/wp-run-journal.py state --run-dir {RUN}; "
               f"echo x >> {RUN}/protected/pilot-answers.jsonl")
        self.assertEqual(self.bash(cmd), "deny")

    def test_git_rules_do_not_apply_outside_manager_sessions(self):
        self.assertEqual(self.bash("git push origin main"), "pass")
        self.assertEqual(self.bash("rm -f /tmp/x"), "pass")


class GuardManagerSession(HookTest):
    def setUp(self):
        super().setUp()
        self.mark_manager()

    def test_push_only_to_run_branch(self):
        self.assertEqual(self.bash("git push origin run/wp568-2026-12-01-1", "mgr"), "pass")
        self.assertEqual(self.bash("git push origin main", "mgr"), "deny")
        self.assertEqual(self.bash("git push", "mgr"), "deny")
        self.assertEqual(self.bash("git push origin run/x:main", "mgr"), "deny")
        self.assertEqual(self.bash("git push --force origin run/x", "mgr"), "deny")
        self.assertEqual(self.bash("git push origin +run/x", "mgr"), "deny")

    def test_publishing_gateways_to_main_are_denied(self):
        self.assertEqual(self.bash("scripts/isolate-push.sh /tmp/wt main", "mgr"), "deny")

    def test_deletion_is_denied(self):
        for cmd in ("rm -rf build", "git rm old.md", "git clean -fd", "git branch -D run/x",
                    "git reset --hard HEAD~1", "git checkout -- file.md", "find . -name x -delete"):
            self.assertEqual(self.bash(cmd, "mgr"), "deny", cmd)

    def test_words_inside_quotes_are_not_commands(self):
        self.assertEqual(self.bash('git commit -m "fix: rm old wording, then git push origin main"', "mgr"),
                         "pass")
        self.assertEqual(self.bash("python3 scripts/wp-run-journal.py append --payload '{\"why\": \"rm x\"}'", "mgr"),
                         "pass")
        self.assertEqual(self.bash("git restore --staged notes.md", "mgr"), "pass")


class AnswerBox(HookTest):
    def prompt(self, text, session="mgr"):
        return self.call(BOX, {"session_id": session, "prompt": text})

    def lines(self, name):
        path = self.run_dir / "protected" / name
        return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []

    def test_outside_manager_session_nothing_is_written(self):
        self.assertIsNone(self.prompt("R-1: да", session="other"))
        self.assertEqual(self.lines("pilot-answers.jsonl"), [])

    def test_answers_are_normalized_and_only_the_line_is_kept(self):
        self.mark_manager()
        out = self.prompt("Посмотрел.\nР-12: да\nR-plan: вариант 2\nR-3 — нет")
        answers = {(a["request_id"], a["answer"]) for a in self.lines("pilot-answers.jsonl")}
        self.assertEqual(answers, {("R-12", "yes"), ("R-plan", "choice:2"), ("R-3", "no")})
        self.assertTrue(all("Посмотрел" not in a["text"] for a in self.lines("pilot-answers.jsonl")))
        self.assertIn("R-12 → yes", out["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(self.lines("pilot-messages.jsonl"), [])

    def test_other_message_is_an_intervention(self):
        self.mark_manager()
        self.assertIsNone(self.prompt("почему ты выбрал Sonnet для Ф25?"))
        self.assertEqual(len(self.lines("pilot-messages.jsonl")), 1)
        self.assertEqual(self.lines("pilot-answers.jsonl"), [])


if __name__ == "__main__":
    unittest.main()
