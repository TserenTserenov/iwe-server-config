"""Tests for style-weekly-state.py: wiring detection, silence alarm, windows, event trigger."""

import contextlib
import hashlib
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
        self.assertFalse(sws._toml_has_stop_hook(KIMI_PRE_ONLY))
        self.assertTrue(sws._toml_has_stop_hook(KIMI_WITH_STOP))

    def test_kimi_wiring_is_per_home(self):
        self.f.write(self.f.home / ".kimi" / "config.toml", KIMI_WITH_STOP)
        self.f.write(self.f.home / ".kimi-code" / "config.toml", KIMI_PRE_ONLY)
        homes = {h["name"]: h["wired"] for h in sws.kimi_homes(self.f.home, 0)}
        self.assertEqual(homes, {".kimi": True, ".kimi-code": False})

    def test_kimi_missing_config_is_reported(self):
        _, _, detail = sws.kimi_verdict(sws.kimi_homes(self.f.home, 0), 0)
        self.assertIn("~/.kimi: прямых сессий 0, нет файла настроек", detail)


class ActivityTests(unittest.TestCase):
    def setUp(self):
        self.f = Fake()
        self.addCleanup(self.f.close)
        self.cutoff = time.time() - 7 * 86400

    def test_kimi_text_only_workdir_is_not_a_direct_chat(self):
        base = self.f.home / ".kimi-code" / "sessions"
        self.f.write(base / "wd_kimi-text-only-workdir_8a1b" / "session_1" / "agents" / "main" / "wire.jsonl", "{}")
        self.f.write(base / "wd_iwe_bb" / "session_2" / "agents" / "main" / "wire.jsonl", "{}")
        self.assertEqual(sws.kimi_direct_sessions(self.f.home / ".kimi-code", self.cutoff), 1)

    def test_kimi_session_with_helpers_counts_once(self):
        session = self.f.home / ".kimi-code" / "sessions" / "wd_iwe_bb" / "session_1" / "agents"
        for agent in ("main", "agent-5", "agent-7"):
            self.f.write(session / agent / "wire.jsonl", "{}")
        self.assertEqual(sws.kimi_direct_sessions(self.f.home / ".kimi-code", self.cutoff), 1)

    def test_kimi_cli_home_skips_peer_workdirs_by_kimi_json(self):
        kimi = self.f.home / ".kimi"
        peer_dir = "/var/folders/x/T/tmp.1/kimi-text-only-workdir"
        direct_dir = "/Users/u/IWE"
        self.f.write(kimi / "kimi.json", json.dumps({"work_dirs": [{"path": peer_dir}, {"path": direct_dir}]}))
        for path, sid in ((peer_dir, "a"), (direct_dir, "b"), ("/not/in/index", "c")):
            group = kimi / "sessions" / hashlib.md5(path.encode()).hexdigest()
            self.f.write(group / sid / "wire.jsonl", "{}")
        # peer skipped; known direct and unknown origin both count (unknown = alarm rather than hide)
        self.assertEqual(sws.kimi_direct_sessions(kimi, self.cutoff), 2)

    def test_kimi_json_with_odd_entries_does_not_crash(self):
        kimi = self.f.home / ".kimi"
        self.f.write(kimi / "kimi.json", json.dumps({"work_dirs": ["text", None, {"path": "/w/IWE"}, {"nopath": 1}]}))
        self.assertEqual(sws._kimi_workdirs(kimi), {hashlib.md5(b"/w/IWE").hexdigest(): "/w/IWE"})

    def test_peer_mark_is_the_adapter_folder_not_a_substring(self):
        self.assertTrue(sws._is_peer_origin("wd_kimi-text-only-workdir_8a1b"))
        self.assertTrue(sws._is_peer_origin("/var/folders/x/T/tmp.1/kimi-text-only-workdir"))
        self.assertFalse(sws._is_peer_origin("/Users/u/text-only-notes"))
        self.assertFalse(sws._is_peer_origin("wd_text-only-notes_8a1b"))
        self.assertFalse(sws._is_peer_origin(""))

    def test_only_cli_home_with_sessions_and_wired_is_fine(self):
        self.f.write(self.f.home / ".kimi" / "config.toml", KIMI_WITH_STOP)
        self.f.write(self.f.home / ".kimi-code" / "config.toml", KIMI_PRE_ONLY)
        self.f.write(self.f.home / ".kimi" / "sessions" / "abc" / "s1" / "wire.jsonl", "{}")
        text, alarm, _ = sws.kimi_verdict(sws.kimi_homes(self.f.home, self.cutoff), 2)
        self.assertEqual((text, alarm), ("в порядке: сессий 1, запусков проверки 2", False))

    def test_kimi_old_session_does_not_count(self):
        wire = self.f.write(self.f.home / ".kimi-code" / "sessions" / "wd_iwe_bb" / "session_1" / "agents" / "main" / "wire.jsonl", "{}")
        os.utime(wire, (self.cutoff - 100, self.cutoff - 100))
        self.assertEqual(sws.kimi_direct_sessions(self.f.home / ".kimi-code", self.cutoff), 0)

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


class KimiVerdictTests(unittest.TestCase):
    def test_unwired_home_with_sessions_alarms_even_if_other_home_is_wired(self):
        homes = [{"name": ".kimi", "wired": True, "sessions": 0}, {"name": ".kimi-code", "wired": False, "sessions": 19}]
        text, alarm, _ = sws.kimi_verdict(homes, 4)
        self.assertTrue(alarm)
        self.assertIn("~/.kimi-code (19)", text)

    def test_unwired_home_without_sessions_is_fine(self):
        homes = [{"name": ".kimi", "wired": True, "sessions": 3}, {"name": ".kimi-code", "wired": False, "sessions": 0}]
        self.assertEqual(sws.kimi_verdict(homes, 5)[:2], ("в порядке: сессий 3, запусков проверки 5", False))

    def test_wired_but_silent_alarms(self):
        homes = [{"name": ".kimi", "wired": True, "sessions": 2}, {"name": ".kimi-code", "wired": None, "sessions": 0}]
        self.assertTrue(sws.kimi_verdict(homes, 0)[1])


class MetricTests(unittest.TestCase):
    def test_projects_glob_encodes_the_root_like_claude(self):
        got = sws.claude_projects_glob(Path("/h"), Path("/Users/t.s/IWE"))
        self.assertEqual(got, "/h/.claude/projects/-Users-t-s-IWE*")

    def test_zero_replies_is_no_data_not_zero(self):
        empty = {"replies": 0, "links_per_reply": 0.0}
        full = {"replies": 4, "links_per_reply": 0.5}
        self.assertIn("нет данных (0 ответов", sws.metric_line("ссылок", "links_per_reply", empty, full))
        self.assertEqual(sws.metric_line("ссылок", "links_per_reply", full, empty), "  ссылок: 0.5 (неделей раньше нет данных)")
        self.assertEqual(sws.metric_line("ссылок", "links_per_reply", full, full), "  ссылок: 0.5 (неделей раньше 0.5)")

    def test_real_zero_with_replies_stays_a_number(self):
        none = {"replies": 3, "links_per_reply": 0.0}
        self.assertEqual(sws.metric_line("ссылок", "links_per_reply", none, none), "  ссылок: 0.0 (неделей раньше 0.0)")


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
        # The Mac case of 25.11: the terminal home is wired, the extension home is not.
        self.f.write(self.f.home / ".kimi" / "config.toml", KIMI_WITH_STOP)
        self.f.write(self.f.home / ".kimi-code" / "config.toml", KIMI_PRE_ONLY)
        self.f.write(self.f.home / ".kimi-code" / "sessions" / "wd_iwe_x" / "session_1" / "agents" / "main" / "wire.jsonl", "{}")
        code, text = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("ТРЕВОГА: прямые сессии без проверки после ответа в ~/.kimi-code (1)", text)

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
