"""Tests for a14-acceptance.py: blind bundle, tally against the criterion, resumable run, replay."""

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).with_name("a14-acceptance.py")
spec = importlib.util.spec_from_file_location("a14_acceptance", SCRIPT)
acc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acc)


def claude_stream(*texts):
    """Claude `--output-format stream-json` output: one assistant event per message plus a tool-only one."""
    events = [{"type": "system", "subtype": "init"}]
    for text in texts:
        events.append({"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}})
        events.append({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Read"}]}})
    events.append({"type": "result", "result": texts[-1]})
    return "\n".join(json.dumps(e, ensure_ascii=False) for e in events) + "\n"


def codex_stream(*texts):
    events = [{"type": "thread.started"}, {"type": "item.completed", "item": {"type": "error", "message": "meta"}}]
    events += [{"type": "item.completed", "item": {"type": "agent_message", "text": t}} for t in texts]
    return "\n".join(json.dumps(e, ensure_ascii=False) for e in events) + "\n"


def fake_answers(agents, bad=None):
    out = Path(tempfile.mkdtemp())
    (out / "out").mkdir()
    for agent in agents:
        for n in range(1, len(acc.questions()) + 1):
            text = (bad or {}).get((agent, n), f"Ответ {agent} на вопрос {n}. Дальше: ничего не жду.")
            (out / "out" / f"{agent}-{n:02d}.md").write_text(text, encoding="utf-8")
    return out


class AcceptanceTest(unittest.TestCase):
    def test_twelve_questions(self):
        self.assertEqual(len(acc.questions()), 12)

    def test_blind_hides_authors_and_key_maps_back(self):
        out = fake_answers(["claude", "kimi", "codex"])
        acc.blind(out)
        blind = (out / "blind.md").read_text(encoding="utf-8")
        key = json.loads((out / "blind-key.json").read_text(encoding="utf-8"))
        self.assertEqual(len(key), 36)
        self.assertEqual(set(key.values()), {"claude", "kimi", "codex"})
        label = next(k for k, v in key.items() if v == "kimi" and k.startswith("5"))
        self.assertIn(f"### Ответ {label}", blind)

    def test_blind_is_stable_between_runs(self):
        out = fake_answers(["claude", "kimi"])
        acc.blind(out)
        first = (out / "blind-key.json").read_text(encoding="utf-8")
        acc.blind(out)
        self.assertEqual(first, (out / "blind-key.json").read_text(encoding="utf-8"))

    def test_tally_applies_majority_and_the_criterion(self):
        key = {f"{n}A": "kimi" for n in range(1, 13)} | {f"{n}B": "codex" for n in range(1, 13)}
        clean = " ".join(f"{n}A c" for n in range(1, 13))
        codex_bad_q1 = "1B f " + " ".join(f"{n}B c" for n in range(2, 13))
        grades = {"g1": clean + " " + codex_bad_q1, "g2": clean + " " + codex_bad_q1, "g3": clean + " " + codex_bad_q1}
        result = acc.tally(key, grades)
        self.assertEqual(result["kimi"], {"clean": 12, "fail": 0, "disputed": 0, "fail_q1_3": 0})
        self.assertEqual(result["codex"]["fail_q1_3"], 1)
        self.assertEqual(result["codex"]["clean"], 11)

    def test_tally_minority_failure_does_not_decide(self):
        key = {"1A": "kimi"}
        result = acc.tally(key, {"g1": "1A f", "g2": "1A c", "g3": "1A c"})
        self.assertEqual(result["kimi"]["clean"], 1)

    def test_score_exit_code_follows_the_criterion(self):
        out = fake_answers(["kimi"])
        acc.blind(out)
        key = json.loads((out / "blind-key.json").read_text(encoding="utf-8"))
        good = out / "good.json"
        good.write_text(json.dumps({"g": " ".join(f"{k} c" for k in key)}))
        self.assertEqual(acc.score(out, good), 0)
        bad = out / "bad.json"
        bad.write_text(json.dumps({"g": " ".join(f"{k} {'f' if k.startswith('1') else 'c'}" for k in key)}))
        self.assertEqual(acc.score(out, bad), 1)

    def test_run_is_resumable_and_uses_one_fresh_command_per_question(self):
        out = Path(tempfile.mkdtemp())
        (out / "out").mkdir()
        (out / "out" / "claude-01.md").write_text("уже есть")
        calls = []

        def fake_run(cmd, **kw):
            calls.append(cmd)
            return subprocess.CompletedProcess(cmd, 0, stdout=claude_stream("ответ"), stderr="")

        with mock.patch.object(acc.subprocess, "run", fake_run):
            acc.run(["claude"], out, 5)
        self.assertEqual(len(calls), 11, "question 1 already answered: skipped")
        self.assertTrue(all(c[0] == "claude" and "-p" in c for c in calls))
        self.assertEqual((out / "out" / "claude-01.md").read_text(), "уже есть")

    def test_run_survives_a_timeout_and_keeps_going(self):
        out = Path(tempfile.mkdtemp())

        def fake_run(cmd, **kw):
            if "Из чего состоит ИИ-агент?" in cmd:
                raise subprocess.TimeoutExpired(cmd, 1)
            return subprocess.CompletedProcess(cmd, 0, stdout=claude_stream("ответ"), stderr="")

        with mock.patch.object(acc.subprocess, "run", fake_run):
            acc.run(["claude"], out, 1)
        self.assertFalse((out / "out" / "claude-01.md").exists(), "timed-out question leaves no half answer")
        self.assertTrue((out / "out" / "claude-02.md").exists())

    def test_parse_messages_reads_every_assistant_message(self):
        self.assertEqual(acc.parse_messages("claude", claude_stream("первый", "второй")), ["первый", "второй"])
        self.assertEqual(acc.parse_messages("codex", codex_stream("первый", "второй")), ["первый", "второй"])
        self.assertEqual(acc.parse_messages("kimi", "один ответ"), ["один ответ"])
        self.assertEqual(acc.parse_messages("claude", "Not logged in\n"), [], "plain text is not an answer")

    def test_choose_answer_keeps_the_real_answer_when_a_hook_comment_follows_it(self):
        real = "Длинный содержательный ответ про состав. " * 10
        self.assertEqual(acc.choose_answer([real, "Хук сработал ложно."]), (real, True))
        self.assertEqual(acc.choose_answer([real, "Переписанный ответ " * 12]), ("Переписанный ответ " * 12, False))
        self.assertEqual(acc.choose_answer(["единственный"]), ("единственный", False))
        self.assertEqual(acc.choose_answer([]), ("", False))

    def test_run_saves_the_earlier_answer_and_the_whole_exchange_after_a_hook_comment(self):
        import contextlib
        import io
        out = Path(tempfile.mkdtemp())
        real = "Полный ответ на вопрос о составе. " * 10

        def fake_run(cmd, **kw):
            return subprocess.CompletedProcess(cmd, 0, stdout=codex_stream(real, "Дальше: вы: уточнить.") if cmd[0] == "codex"
                                               else claude_stream(real, "Хук сработал ложно."), stderr="")

        buf = io.StringIO()
        with mock.patch.object(acc.subprocess, "run", fake_run), contextlib.redirect_stdout(buf):
            acc.run(["claude", "codex"], out, 5)
        for agent in ("claude", "codex"):
            self.assertEqual((out / "out" / f"{agent}-01.md").read_text(encoding="utf-8"), real)
            saved = json.loads((out / "out" / f"{agent}-01.messages.json").read_text(encoding="utf-8"))
            self.assertEqual(len(saved), 2)
        self.assertIn("kept the earlier answer", buf.getvalue())
        self.assertEqual(len(acc.answer_files(out)), 24, "the .messages.json sidecar is not counted as an answer")

    def test_agent_commands_match_the_installed_clis(self):
        kimi = acc.agent_command("kimi", "q")
        self.assertEqual(kimi[1:], ["-p", "q"], "kimi CLI has no --quiet/-w; the 30.10 run lost 12 answers to it")
        self.assertIn("--skip-git-repo-check", acc.agent_command("codex", "q"))

    def test_run_prints_redacted_stderr_tail_when_the_agent_fails(self):
        import contextlib
        import io
        out = Path(tempfile.mkdtemp())

        def fake_run(cmd, **kw):
            return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="warn\nNot logged in · token ghp_abcdef0123456789XYZ\n")

        buf = io.StringIO()
        with mock.patch.object(acc.subprocess, "run", fake_run), contextlib.redirect_stdout(buf):
            acc.run(["claude"], out, 5)
        text = buf.getvalue()
        self.assertIn("rc=1", text)
        self.assertIn("Not logged in", text)
        self.assertIn("<REDACTED>", text)
        self.assertNotIn("ghp_abcdef", text)

    def test_replay_survives_a_journal_line_cut_mid_character(self):
        """Hooks before 30.10 wrote `cut -c` byte-truncated lines; the rule id must still be read."""
        import contextlib
        import io
        out = fake_answers(["kimi"])
        broken = "2026-10-30 12:00:00 | kimi | A14 | non-system-as-part | состоя".encode()[:-1] + b"\n"

        def fake_run(cmd, env=None, **kw):
            log = Path(env["HOME"]) / ".claude/logs/style-violations.log"
            log.parent.mkdir(parents=True)
            log.write_bytes(broken)
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        buf = io.StringIO()
        with mock.patch.object(acc.subprocess, "run", fake_run), contextlib.redirect_stdout(buf):
            acc.replay(out)
        self.assertIn("flagged answers: 12 of 12", buf.getvalue())

    def test_replay_flags_a_violating_answer_and_not_a_clean_one(self):
        bad = "ИИ-агент — это система. В ней есть:\n\n- **Память** — хранит сведения.\n- **Правила** — задают границы.\n"
        out = fake_answers(["kimi"], bad={("kimi", 1): bad})
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            acc.replay(out)
        text = buf.getvalue()
        self.assertIn("kimi-01  A14", text)
        self.assertNotIn("kimi-02", text)


if __name__ == "__main__":
    unittest.main()
