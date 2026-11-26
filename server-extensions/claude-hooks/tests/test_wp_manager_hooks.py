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

    def test_relative_paths_and_journal_env_overrides_are_denied(self):
        self.assertEqual(self.bash("echo x >> inbox/WP-1/runs/r1/events.jsonl"), "deny")
        cmd = f"IWE_WP_MANAGER_STATE=/tmp/zz python3 scripts/wp-run-journal.py state --run-dir {RUN}"
        self.assertEqual(self.bash(cmd), "deny")
        self.assertEqual(self.bash(f"WP_RUN_JOURNAL_NOW=2030-01-01T00:00:00Z python3 scripts/wp-run-journal.py lease "
                                   f"--run-dir {RUN}"), "deny")

    def test_ordinary_work_is_not_blocked(self):
        self.assertEqual(self.decision("Write", {"file_path": "/home/u/app/runs/exp42/views/index.html"}), "pass")
        self.assertEqual(self.decision("Write", {"file_path": "/home/u/.iwe-runtime/wp-manager-notes/x.md"}), "pass")
        self.assertEqual(self.bash("grep -rn pilot-answers.jsonl scripts/"), "pass")
        self.assertEqual(self.bash("git commit -m 'fix: answer box writes pilot-answers.jsonl'"), "pass")
        self.assertEqual(self.bash(f"cat {RUN}/events.jsonl 2>/dev/null | tail -3"), "pass")
        self.assertEqual(self.bash("cp -r proj/runs/2026-11-01/views/ /tmp/backup"), "pass")

    def test_development_of_the_manager_is_not_blocked(self):
        for cmd in ("grep -n CLAUDE_CODE_SESSION_ID scripts/wp-run-journal.py",
                    "git commit -m 'fix wp-run-journal: holder from CLAUDE_CODE_SESSION_ID'",
                    "git commit -m 'answer box writes protected/pilot-answers.jsonl'",
                    "cat db/protected/seed-data.sql", "cp runs/exp1/events.jsonl /tmp/",
                    "jq . runs/r1/events.jsonl > /tmp/t"):
            self.assertEqual(self.bash(cmd), "pass", cmd)
        self.assertEqual(self.decision("Write", {"file_path": "/home/u/ml/runs/a/events.jsonl"}), "pass")

    def test_reading_or_committing_run_files_is_not_a_write(self):
        heredoc = (f"git add {RUN}/events.jsonl && git commit -m \"$(cat <<'EOF'\nrun log\n\n"
                   "Co-Authored-By: Claude <noreply@anthropic.com>\nEOF\n)\"")
        for cmd in (heredoc, f"git show run/r1:{RUN}/events.jsonl > /tmp/ev.jsonl",
                    f"grep -c phase {RUN}/events.jsonl > /tmp/n.txt", f"cp {RUN}/events.jsonl /tmp/copy.jsonl"):
            self.assertEqual(self.bash(cmd), "pass", cmd)
        for cmd in (f"cp /tmp/forged.jsonl {RUN}/events.jsonl", f"tee -a {RUN}/lease.json < /tmp/x",
                    f"sed -i 1d {RUN}/events.jsonl", f"mv {RUN}/events.jsonl /tmp/"):
            self.assertEqual(self.bash(cmd), "deny", cmd)

    def test_unusual_hook_input_does_not_block(self):
        self.assertEqual(self.decision("Bash", {"command": None}), "pass")
        out = self.call(GUARD, {"session_id": "x", "tool_name": "Write", "tool_input": "oops"})
        self.assertIsNone(out)

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

    def test_bypasses_found_by_review_are_denied(self):
        for cmd in ("bash -c 'git push origin main'", 'sh -c "rm -rf build"', "eval git push origin main",
                    "git -C /repo clean -fdx", "git -C /repo reset --hard HEAD~3", "git -C /repo branch -D run/r1",
                    "git push origin :run/r1", "git push origin run/r1:develop", "gh pr merge 12 --merge",
                    "python3 -c 'import os; os.remove(\"x\")'", "git -C /repo push origin main"):
            self.assertEqual(self.bash(cmd, "mgr"), "deny", cmd)

    def test_second_round_bypasses_are_denied(self):
        run = str(self.run_dir)
        for cmd in ("bash -lc 'git push origin main'", "sh -ec 'rm -rf build'",
                    "bash -euo pipefail -c 'git push origin main'", "nix-shell -p git --run 'git push origin main'",
                    "git push -fu origin run/r1", "/bin/rm -rf build", "git stash drop",
                    f"cd {run}/protected && cat pilot-answers.jsonl", f"cd {run} && echo x >> events.jsonl",
                    f"D={run}; echo x >> $D/events.jsonl", f'cat "{run}/protected/seed"'):
            self.assertEqual(self.bash(cmd, "mgr"), "deny", cmd)

    def test_manager_own_journal_calls_pass(self):
        run = str(self.run_dir)
        for cmd in (f"python3 scripts/wp-run-journal.py state --run-dir {run}",
                    f"python3 scripts/wp-run-journal.py append --run-dir {run} --epoch 1 --type cost-recorded "
                    "--payload '{\"scope\": \"manager\", \"minutes\": 3, \"source\": \"unknown\"}'",
                    f"python3 scripts/wp-run-journal.py ingest-answers --run-dir {run} --epoch 1",
                    f"python3 scripts/wp-run-journal.py lease --run-dir {run}"):
            self.assertEqual(self.bash(cmd, "mgr"), "pass", cmd)

    def test_third_round_cases(self):
        for cmd in ('out="$(git push origin main 2>&1)"; echo "$out"', 'echo "$(rm -rf build)"',
                    f"cd {self.run_dir.parent} && echo x >> {self.run_dir.name}/events.jsonl"):
            self.assertEqual(self.bash(cmd, "mgr"), "deny", cmd)
        for cmd in ("git stash push -m wip", "bash scripts/x.sh -c config",
                    "git push origin origin/main:refs/heads/run/r1", "nix develop", "npm run build"):
            self.assertEqual(self.bash(cmd, "mgr"), "pass", cmd)
        self.assertEqual(self.bash("nix develop --command make", "mgr"), "deny")

    def test_run_id_in_branch_or_worktree_name_is_not_a_write(self):
        rid = self.run_dir.name
        for cmd in (f"git -C /tmp/wt-{rid} diff origin/main run/{rid} > /tmp/d.patch",
                    f"cp /tmp/result.md /tmp/wt-{rid}/docs/result.md", f"git -C /tmp/wt-{rid} mv docs/a.md docs/b.md",
                    f"git -C /tmp/wt-{rid} log | tee /tmp/log.txt",
                    f"git show HEAD:inbox/WP-626/runs/{rid}/events.jsonl > /tmp/x"):
            self.assertEqual(self.bash(cmd, "mgr"), "pass", cmd)

    def test_manager_reads_its_journal_with_stderr_redirect(self):
        self.assertEqual(self.bash(f"tail -3 {self.run_dir}/events.jsonl 2>/dev/null", "mgr"), "pass")
        self.assertEqual(self.bash(f"D={self.run_dir}; tail -3 $D/events.jsonl 2>/dev/null", "mgr"), "pass")

    def test_reading_a_hook_file_named_push_does_not_crash(self):
        self.assertEqual(self.bash("cat .git/hooks/pre-push", "mgr"), "pass")

    def test_explicit_run_branch_push_forms_pass(self):
        for cmd in ("git -C /repo push origin run/wp568-1", "git push origin HEAD:run/wp568-1",
                    "git push -u origin run/wp568-1"):
            self.assertEqual(self.bash(cmd, "mgr"), "pass", cmd)

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


class AnswerBoxStrict(AnswerBox):
    def test_lowercase_prefix_is_normalized(self):
        self.mark_manager()
        self.prompt("r-12: да")
        self.assertEqual([a["request_id"] for a in self.lines("pilot-answers.jsonl")], ["R-12"])

    def test_answer_with_reservation_is_not_a_yes(self):
        self.mark_manager()
        out = self.prompt("Р-12: да, но только после проверки")
        self.assertEqual(self.lines("pilot-answers.jsonl"), [])
        self.assertIn("не распознан", out["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(len(self.lines("pilot-messages.jsonl")), 1)

    def test_conflicting_answers_are_not_recorded(self):
        self.mark_manager()
        out = self.prompt("R-9: нет\nR-9: да")
        self.assertEqual(self.lines("pilot-answers.jsonl"), [])
        self.assertIn("Противоречивые", out["hookSpecificOutput"]["additionalContext"])


if __name__ == "__main__":
    unittest.main()
