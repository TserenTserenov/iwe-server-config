"""Tests for scripts/convergence-alarm.py (WP-539 F21 B0): one daytime message per lag episode."""

import copy
import datetime as dt
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))
_spec = importlib.util.spec_from_file_location("convergence_alarm", SCRIPTS / "convergence-alarm.py")
alarm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(alarm)

T0 = dt.datetime(2026, 11, 13, 12, 0, tzinfo=dt.timezone.utc)


def minutes(n):
    return T0 + dt.timedelta(minutes=n)


class StepTest(unittest.TestCase):
    def test_lag_alarms_once_after_threshold_then_recovers(self):
        state = {}
        self.assertIsNone(alarm.step(state, "x", "behind -3", 30, minutes(0)))
        self.assertIsNone(alarm.step(state, "x", "behind -5", 30, minutes(29)))
        self.assertEqual(alarm.step(state, "x", "behind -5", 30, minutes(31)), "⚠️ x: behind -5 уже 31 мин (порог 30)")
        state["x"]["alerted"] = True  # main() marks it after a successful send
        self.assertIsNone(alarm.step(state, "x", "behind -6", 30, minutes(60)))
        self.assertEqual(alarm.step(state, "x", "equal", 30, minutes(61)), "✅ x: снова совпадает с GitHub")
        self.assertTrue(state["x"]["recovered"])  # removed by main() only after the send succeeded

    def test_short_lag_that_heals_is_silent(self):
        state = {}
        alarm.step(state, "x", "behind -1", 30, minutes(0))
        self.assertIsNone(alarm.step(state, "x", "equal", 30, minutes(10)))
        self.assertEqual(state, {})

    def test_unsent_alarm_is_repeated_next_run(self):
        state = {}
        alarm.step(state, "x", "diverged +1/-2", 30, minutes(0))
        first = alarm.step(state, "x", "diverged +1/-2", 30, minutes(40))
        again = alarm.step(state, "x", "diverged +1/-2", 30, minutes(55))
        self.assertTrue(first.startswith("⚠️ x: diverged"))
        self.assertTrue(again.startswith("⚠️ x: diverged +1/-2 уже 55 мин"))

    def test_relapse_before_recovery_was_sent_continues_the_episode(self):
        state = {"x": {"since": T0.isoformat(), "relation": "behind -1", "alerted": True, "recovered": True}}
        self.assertIsNone(alarm.step(state, "x", "behind -2", 30, minutes(90)))
        self.assertNotIn("recovered", state["x"])

    def test_quiet_hours_wrap_midnight_and_equal_bounds_mean_none(self):
        night = dt.datetime(2026, 11, 13, 23, 30)
        early = dt.datetime(2026, 11, 14, 7, 59)
        day = dt.datetime(2026, 11, 14, 8, 0)
        self.assertTrue(alarm.in_quiet_hours(night, 23, 8))
        self.assertTrue(alarm.in_quiet_hours(early, 23, 8))
        self.assertFalse(alarm.in_quiet_hours(day, 23, 8))
        self.assertTrue(alarm.in_quiet_hours(dt.datetime(2026, 11, 14, 3, 0), 1, 5))
        self.assertFalse(alarm.in_quiet_hours(dt.datetime(2026, 11, 14, 5, 0), 1, 5))
        self.assertFalse(alarm.in_quiet_hours(night, 8, 8))


class AssessTest(unittest.TestCase):
    def test_equal_counts_only_with_a_fresh_fetch(self):
        self.assertEqual(alarm.assess("equal", minutes(-10), 30, T0), ("equal", 30))
        self.assertEqual(alarm.assess("equal", minutes(-121), 30, T0), ("данные с GitHub не обновлялись 121 мин", 0))
        self.assertEqual(alarm.assess("equal", None, 30, T0),
                         ("нет подтверждённого получения данных с GitHub", alarm.FETCH_STALE_MIN))

    def test_ahead_gets_grace_behind_keeps_threshold(self):
        self.assertEqual(alarm.assess("ahead +1", minutes(-1), 30, T0), ("ahead +1", alarm.AHEAD_GRACE_MIN))
        self.assertEqual(alarm.assess("behind -4", None, 30, T0), ("behind -4", 30))
        self.assertEqual(alarm.assess("diverged +1/-2", minutes(-1), 30, T0), ("diverged +1/-2", 30))


class WatchedTest(unittest.TestCase):
    REGISTRY = {"version": 1, "repos": [
        {"repo_id": "a", "class": "reader", "checkouts": [{"host": "mac", "path": "a"}],
         "decision_owner": {"ref": "p", "scope": "repo"}, "thresholds": {"behind_observed_for_min": 30}},
        {"repo_id": "b", "class": "reader", "checkouts": [{"host": "mac", "path": "b"}],
         "decision_owner": {"ref": "p", "scope": "repo"}, "thresholds": {"behind_observed_for_min": None}},
        {"repo_id": "c", "class": "working", "checkouts": [{"host": "mac", "path": "c"}],
         "decision_owner": {"ref": "p", "scope": "repo"}, "thresholds": {"behind_observed_for_min": 30}},
    ]}

    def test_only_managed_copies_with_a_threshold(self):
        self.assertEqual(alarm.watched(copy.deepcopy(self.REGISTRY), "mac"), [("a", 30)])
        self.assertEqual(alarm.watched(copy.deepcopy(self.REGISTRY), "tsekh-1"), [])

    def test_shipped_registry_watches_the_four_mac_copies(self):
        import repo_registry
        registry, errors = repo_registry.load(SCRIPTS / "repo-convergence.registry.yaml")
        self.assertEqual(errors, [])
        paths = {p for p, _ in alarm.watched(registry, "mac")}
        self.assertTrue({".", "MC-sessions", "DS-MCP/knowledge-mcp", "DS-IT-systems/activity-hub"} <= paths, paths)


def run(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True)


class MainTest(unittest.TestCase):
    """End to end on a real behind copy, with a fake telegram library that records what it sends."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.root = base / "root"
        origin, copy_dir = base / "origin", self.root / "a"
        run(base, "init", "-q", "-b", "main", str(origin))
        run(origin, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "one")
        self.root.mkdir()
        run(base, "clone", "-q", str(origin), str(copy_dir))
        run(origin, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "two")
        run(copy_dir, "fetch", "-q", "origin")  # behind -1
        self.registry = base / "registry.yaml"
        self.registry.write_text(json.dumps({"version": 1, "repos": [
            {"repo_id": "a", "class": "reader", "checkouts": [{"host": "mac", "path": "a"}],
             "decision_owner": {"ref": "p", "scope": "repo"}, "thresholds": {"behind_observed_for_min": 0}}]}))
        self.sent = base / "sent.txt"
        self.lib = base / "telegram.sh"
        self.lib.write_text(f'telegram_send() {{ printf "%s\\n--\\n" "$1" >> "{self.sent}"; }}\n')
        self.state = base / "state.json"
        self.log = base / "reader.log"
        self.log.write_text("[2026-11-13 12:00:00] [reader-copies-sync] a: BLOCKED свои коммиты\n")
        self.quiet = (0, 0)  # no quiet hours
        self.copy_dir = copy_dir

    def tearDown(self):
        self.tmp.cleanup()

    def main(self):
        argv = ["convergence-alarm.py", "--root", str(self.root), "--registry", str(self.registry),
                "--host", "mac", "--state", str(self.state), "--reader-log", str(self.log),
                "--telegram-lib", str(self.lib), "--quiet-from", str(self.quiet[0]), "--quiet-to", str(self.quiet[1])]
        old = sys.argv
        sys.argv = argv
        try:
            return alarm.main()
        finally:
            sys.argv = old

    def test_second_run_sends_once_with_reason_and_marks_alerted(self):
        self.assertEqual(self.main(), 0)  # opens the episode
        self.assertFalse(self.sent.exists())
        self.assertEqual(self.main(), 0)  # threshold 0: alarm now
        text = self.sent.read_text()
        self.assertIn("⚠️ a: behind -1", text)
        self.assertIn("перемотка: BLOCKED свои коммиты", text)
        self.assertTrue(json.loads(self.state.read_text())["a"]["alerted"])
        self.assertEqual(self.main(), 0)  # no repeat for the same episode
        self.assertEqual(self.sent.read_text().count("⚠️"), 1)

    def catch_up(self):
        run(self.copy_dir, "merge", "-q", "--ff-only", "origin/main")
        broker = self.root / ".iwe-runtime" / "refs-sync-broker" / "broker.log"
        broker.parent.mkdir(parents=True, exist_ok=True)
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        broker.write_text(f"{stamp} OK a <- origin +refs/heads/main:refs/remotes/origin/main\n")

    def test_recovery_waits_out_quiet_hours_then_is_sent_once(self):
        self.main()
        self.main()  # alarm sent
        self.catch_up()
        hour = dt.datetime.now().hour
        self.quiet = (hour, (hour + 1) % 24)  # now is quiet
        self.assertEqual(self.main(), 0)
        self.assertNotIn("✅", self.sent.read_text())
        self.assertTrue(json.loads(self.state.read_text())["a"]["recovered"])
        self.quiet = (0, 0)
        self.assertEqual(self.main(), 0)
        self.assertEqual(self.sent.read_text().count("✅ a: снова совпадает"), 1)
        self.assertEqual(json.loads(self.state.read_text()), {})
        self.main()
        self.assertEqual(self.sent.read_text().count("✅"), 1)

    def test_failed_recovery_send_is_retried(self):
        self.main()
        self.main()
        self.catch_up()
        good = self.lib.read_text()
        self.lib.write_text("telegram_send() { return 1; }\n")
        self.assertEqual(self.main(), 1)
        self.assertTrue(json.loads(self.state.read_text())["a"]["recovered"])
        self.lib.write_text(good)
        self.assertEqual(self.main(), 0)
        self.assertIn("✅ a: снова совпадает", self.sent.read_text())

    def test_failed_send_keeps_episode_unalerted(self):
        self.lib.write_text("telegram_send() { return 1; }\n")
        self.main()
        self.assertEqual(self.main(), 1)
        self.assertFalse(json.loads(self.state.read_text())["a"]["alerted"])


if __name__ == "__main__":
    unittest.main()
