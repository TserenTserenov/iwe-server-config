"""Tests for style-weekly-state.py: wiring detection, silence alarm, windows, event trigger."""

import contextlib
import importlib.util
import io
import json
import os
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("style-weekly-state.py")
spec = importlib.util.spec_from_file_location("style_weekly_state", SCRIPT)
sws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sws)

KIMI_WITH_STOP = '''
[[hooks]]
event = "PreToolUse"
command = "env IWE_AGENT=kimi /x/session-open-gate.sh"

[[hooks]]
event = "Stop"
command = "python3 /x/kimi-style-stop.py"
'''
KIMI_PRE_ONLY = '''
[[hooks]]
event = "PreToolUse"
command = "env IWE_AGENT=kimi /x/session-open-gate.sh"
'''


class Fake:
    """A throwaway home with root=home/IWE and logs=home/.claude/logs."""

    def __init__(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name)
        self.root = self.home / "IWE"
        self.logs = self.home / ".claude" / "logs"
        self.logs.mkdir(parents=True)
        self.root.mkdir()

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def close(self):
        self._tmp.cleanup()


class WiringTests(unittest.TestCase):
    def setUp(self):
        self.f = Fake()
        self.addCleanup(self.f.close)

    def test_claude_wired_when_stop_has_clarity_hook(self):
        settings = {"hooks": {"Stop": [{"hooks": [{"command": "$X/response-clarity-hook.sh"}]}]}}
        self.f.write(self.f.root / ".claude" / "settings.json", json.dumps(settings))
        self.assertTrue(sws.wiring_claude(self.f.root)[0])

    def test_claude_not_wired_without_stop_or_file(self):
        self.assertFalse(sws.wiring_claude(self.f.root)[0])
        self.f.write(self.f.root / ".claude" / "settings.json", json.dumps({"hooks": {"Stop": []}}))
        self.assertFalse(sws.wiring_claude(self.f.root)[0])

    def test_codex_wired_only_by_stop_entry(self):
        hooks = {"hooks": {"Stop": [{"hooks": [{"command": "python3 style_check_stop.py"}]}]}}
        self.f.write(self.f.root / ".codex" / "hooks.json", json.dumps(hooks))
        self.assertTrue(sws.wiring_codex(self.f.root)[0])
        other = {"hooks": {"UserPromptSubmit": [{"hooks": [{"command": "style_check_stop.py"}]}]}}
        self.f.write(self.f.root / ".codex" / "hooks.json", json.dumps(other))
        self.assertFalse(sws.wiring_codex(self.f.root)[0])

    def test_kimi_needs_stop_event_with_style_command(self):
        self.f.write(self.f.home / ".kimi" / "config.toml", KIMI_PRE_ONLY)
        wired, detail = sws.wiring_kimi(self.f.home)
        self.assertFalse(wired)
        self.assertIn("нет проверки после ответа", detail)
        self.f.write(self.f.home / ".kimi-code" / "config.toml", KIMI_WITH_STOP)
        self.assertTrue(sws.wiring_kimi(self.f.home)[0])

    def test_kimi_missing_files_are_not_wired(self):
        wired, detail = sws.wiring_kimi(self.f.home)
        self.assertFalse(wired)
        self.assertIn("нет файла", detail)


class ActivityTests(unittest.TestCase):
    def setUp(self):
        self.f = Fake()
        self.addCleanup(self.f.close)
        self.cutoff = time.time() - 7 * 86400

    def test_kimi_text_only_workdir_is_not_a_direct_chat(self):
        base = self.f.home / ".kimi-code" / "sessions"
        self.f.write(base / "wd_kimi-text-only-workdir_aa" / "s1" / "wire.jsonl", "{}")
        self.f.write(base / "wd_iwe_bb" / "s2" / "wire.jsonl", "{}")
        self.assertEqual(sws.activity(self.f.home, self.cutoff)["kimi"], 1)

    def test_codex_peer_runs_are_not_direct_sessions(self):
        base = self.f.home / ".codex" / "sessions" / "2026" / "11" / "24"
        peer = {"payload": {"cwd": "/tmp/codex-peer-abc/empty-root"}}
        direct = {"payload": {"cwd": "/home/u/IWE"}}
        self.f.write(base / "peer.jsonl", json.dumps(peer) + "\n")
        self.f.write(base / "direct.jsonl", json.dumps(direct) + "\n")
        self.f.write(base / "broken.jsonl", "not json\n")
        self.assertEqual(sws.activity(self.f.home, self.cutoff)["codex"], 2)

    def test_old_files_do_not_count(self):
        old = self.f.write(self.f.home / ".claude" / "projects" / "p" / "a.jsonl", "{}")
        os.utime(old, (self.cutoff - 100, self.cutoff - 100))
        self.f.write(self.f.home / ".claude" / "projects" / "p" / "b.jsonl", "{}")
        self.assertEqual(sws.activity(self.f.home, self.cutoff)["claude-code"], 1)


class VerdictTests(unittest.TestCase):
    def test_no_sessions_is_not_an_alarm(self):
        text, alarm = sws.verdict(False, 0, 0)
        self.assertFalse(alarm)
        self.assertIn("не подключена", text)

    def test_sessions_without_wiring_alarm(self):
        self.assertTrue(sws.verdict(False, 3, 0)[1])

    def test_wired_but_silent_alarm(self):
        text, alarm = sws.verdict(True, 3, 0)
        self.assertTrue(alarm)
        self.assertIn("не запускалась", text)

    def test_wired_and_running_is_fine(self):
        self.assertEqual(sws.verdict(True, 3, 10)[1], False)


class LogTests(unittest.TestCase):
    def setUp(self):
        self.f = Fake()
        self.addCleanup(self.f.close)

    def test_check_runs_counts_only_window_and_known_agents(self):
        self.f.write(
            self.f.logs / "style-checks-total.log",
            "2026-11-10 10:00:00 | kimi\n2026-11-10 10:01:00 | kimi-peer\n2026-11-01 10:00:00 | kimi\n2026-11-11 09:00:00 | codex\n",
        )
        runs = sws.check_runs(self.f.logs, "2026-11-08", "2026-11-14")
        self.assertEqual(runs, {"claude-code": 0, "codex": 1, "kimi": 1})

    def test_rule_counts_match_exact_rule_names(self):
        self.f.write(
            self.f.logs / "style-violations.log",
            "2026-11-10 10:00:00 | claude-code | A14 | x | a\n"
            "2026-11-10 10:00:01 | claude-code | A14_AMBIGUOUS | x | a\n"
            "2026-11-10 10:00:02 | claude-code | A13.1 | x | a\n",
        )
        counts = sws.rule_counts(self.f.logs, "2026-11-08", "2026-11-14")
        self.assertEqual((counts["A14"], counts["A13.1"]), (1, 1))

    def test_a14_new_hits_are_exclusive_of_the_cutoff_day(self):
        self.f.write(
            self.f.logs / "style-violations.log",
            "2026-11-24 09:00:00 | codex-peer | A14 | x | a\n"
            "2026-11-25 09:00:00 | codex-peer | A14 | x | a\n"
            "2026-11-26 09:00:00 | codex-peer | A14_AMBIGUOUS | x | a\n"
            "2026-11-26 09:00:01 | claude-code | A14 | x | a\n",
        )
        self.assertEqual(sws.a14_new_hits(self.f.logs, "2026-11-24"), 2)

    def test_concept_kind_calls_group_by_agent(self):
        self.f.write(
            self.f.logs / "concept-kind.log",
            "2026-11-10T10:00:00Z\tclaude\th\tlookup\n2026-11-10T10:00:01Z\tclaude\th\tlookup\n2026-11-10T10:00:02Z\tcodex\th\tlookup\n",
        )
        self.assertEqual(sws.concept_kind_calls(self.f.logs, "2026-11-08", "2026-11-14"), {"claude": 2, "codex": 1})


class EndToEndTests(unittest.TestCase):
    def setUp(self):
        self.f = Fake()
        self.addCleanup(self.f.close)

    def run_main(self, *extra):
        out = io.StringIO()
        argv = ["--root", str(self.f.root), "--home", str(self.f.home), "--today", "2026-11-24", "--skip-metric", *extra]
        with contextlib.redirect_stdout(out):
            code = sws.main(argv)
        return code, out.getvalue()

    def test_quiet_host_has_no_alarm(self):
        code, text = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn("тревог нет", text)

    def test_kimi_with_live_session_and_no_hook_alarms(self):
        self.f.write(self.f.home / ".kimi" / "config.toml", KIMI_PRE_ONLY)
        self.f.write(self.f.home / ".kimi-code" / "sessions" / "wd_iwe_x" / "s" / "wire.jsonl", "{}")
        code, text = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("ТРЕВОГА: сессий 1, а проверка после ответа не подключена", text)

    def test_event_trigger_fires_at_the_threshold(self):
        self.f.write(
            self.f.logs / "style-violations.log",
            "2026-11-25 09:00:00 | codex-peer | A14 | x | a\n2026-11-26 09:00:00 | codex-peer | A14 | x | a\n",
        )
        _, text = self.run_main("--a14-need", "2")
        self.assertIn("ПОРА: набралось 2", text)
        _, text = self.run_main("--a14-need", "3")
        self.assertIn("набрано 2 из 3", text)


if __name__ == "__main__":
    unittest.main()
