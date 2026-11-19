"""Tests for scripts/convergence-alarm.py (WP-539 F21 B0): one daytime message per lag episode."""

import contextlib
import copy
import datetime as dt
import importlib.util
import io
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
        self.assertEqual(alarm.step(state, "x", "behind -5", 30, minutes(31)), "⚠️ x: позади на 5 коммитов уже 31 мин (порог 30)")
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
        self.assertTrue(first.startswith("⚠️ x: расходится:"))
        self.assertTrue(again.startswith("⚠️ x: расходится: впереди на 1 коммит, позади на 2 коммита уже 55 мин"))

    def test_relapse_before_recovery_was_sent_continues_the_episode(self):
        state = {"x": {"since": T0.isoformat(), "relation": "behind -1", "alerted": True, "recovered": True}}
        self.assertIsNone(alarm.step(state, "x", "behind -2", 30, minutes(90)))
        self.assertNotIn("recovered", state["x"])

    def test_alarmed_episode_is_repeated_every_six_hours_after_the_last_sent_message(self):
        state = {"x": {"since": T0.isoformat(), "relation": "behind -3", "alerted": True,
                       "last_alert": T0.isoformat()}}
        self.assertIsNone(alarm.step(state, "x", "behind -3", 30, minutes(359)))
        text = alarm.step(state, "x", "behind -3", 30, minutes(360))
        self.assertEqual(text, "⚠️ x: позади на 3 коммита уже 360 мин (порог 30) — повторное сообщение, эпизод не закрыт")

    def test_state_without_last_alert_starts_the_repeat_clock_silently(self):
        state = {"x": {"since": T0.isoformat(), "relation": "detached", "alerted": True}}
        self.assertIsNone(alarm.step(state, "x", "detached", 30, minutes(600)))
        self.assertEqual(state["x"]["last_alert"], minutes(600).isoformat())
        self.assertIsNone(alarm.step(state, "x", "detached", 30, minutes(959)))
        self.assertIn("повторное сообщение", alarm.step(state, "x", "detached", 30, minutes(960)))

    def test_detached_text_names_the_whole_episode_and_when_the_branch_was_lost(self):
        state = {"x": {"since": T0.isoformat(), "relation": "ahead +1", "alerted": False}}
        self.assertIsNone(alarm.step(state, "x", "detached", 30, minutes(12)))  # kind changed, 12 < 30
        text = alarm.step(state, "x", "detached", 30, minutes(31))
        since = minutes(12).astimezone()
        self.assertEqual(text, f"⚠️ x: расхождение длится 31 мин (порог 30); сейчас копия без ветки (с {since:%H:%M})")

    def test_same_kind_with_a_changing_count_keeps_the_kind_clock(self):
        state = {}
        alarm.step(state, "x", "behind -1", 30, minutes(0))
        alarm.step(state, "x", "behind -9", 30, minutes(5))
        self.assertNotIn("kind_since", state["x"])

    def test_humanize_words_and_russian_plural(self):
        self.assertEqual(alarm.humanize("behind -27"), "позади на 27 коммитов")
        self.assertEqual(alarm.humanize("behind -21"), "позади на 21 коммит")
        self.assertEqual(alarm.humanize("behind -12"), "позади на 12 коммитов")
        self.assertEqual(alarm.humanize("ahead +3"), "впереди на 3 коммита")
        self.assertEqual(alarm.humanize("нет подтверждённого получения данных с GitHub"),
                         "нет подтверждённого получения данных с GitHub")

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

    def test_shipped_registry_watches_mac_copies_with_their_limits(self):
        import repo_registry
        registry, errors = repo_registry.load(SCRIPTS / "repo-convergence.registry.yaml")
        self.assertEqual(errors, [])
        limits = dict(alarm.watched(registry, "mac"))
        expected = {".": 30, "MC-sessions": 30, "DS-MCP/knowledge-mcp": 30,
                    "DS-IT-systems/activity-hub": 30, "DS-my-strategy": 90}
        self.assertEqual({p: limits.get(p) for p in expected}, expected)


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
        self.lib.write_text(f'telegram_send() {{ printf "%s\\n--\\n" "$1" >> "{self.sent}"; TELEGRAM_SEND_OUTCOME=sent; }}\n')
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
        self.assertIn("⚠️ a: позади на 1 коммит", text)
        self.assertIn("перемотка: BLOCKED свои коммиты", text)
        self.assertTrue(json.loads(self.state.read_text())["a"]["alerted"])
        self.assertEqual(self.main(), 0)  # no repeat for the same episode
        self.assertEqual(self.sent.read_text().count("⚠️"), 1)

    def test_send_names_its_source_for_the_telegram_gate(self):
        # WP-484 F313: without a source id the gate saw $0 = "_" and the digest
        # quarantined a real alarm as "вне реестра: _".
        caller = self.tmp.name + "/caller.txt"
        self.lib.write_text(f'telegram_send() {{ printf "%s|%s\\n" "$(basename -- "$0")" "${{TELEGRAM_SOURCE_ID:-}}" >> "{caller}"; TELEGRAM_SEND_OUTCOME=sent; }}\n')
        self.main()
        self.main()
        self.assertEqual(Path(caller).read_text().strip(), "convergence-alarm.py|convergence-alarm")

    def test_sent_alarm_records_when_it_was_sent_and_a_failed_send_does_not(self):
        self.main()
        self.main()
        self.assertTrue(json.loads(self.state.read_text())["a"]["last_alert"])
        self.lib.write_text("telegram_send() { return 1; }\n")
        stored = json.loads(self.state.read_text())
        stored["a"]["last_alert"] = "2000-01-01T00:00:00+00:00"  # long ago: a repeat is due now
        self.state.write_text(json.dumps(stored))
        self.assertEqual(self.main(), 1)  # the repeat could not be sent
        self.assertEqual(json.loads(self.state.read_text())["a"]["last_alert"], "2000-01-01T00:00:00+00:00")

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

    def test_log_names_copy_and_kind_of_each_message(self):
        self.main()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.main()  # alarm sent
        self.assertRegex(out.getvalue(), r"convergence-alarm: \S+ sent: ⚠️ a: позади на 1 коммит уже \d+ мин")
        self.catch_up()
        hour = dt.datetime.now().hour
        self.quiet = (hour, (hour + 1) % 24)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.main()
        self.assertIn("deferred (quiet hours): ✅ a: снова совпадает с GitHub", out.getvalue())

    def test_failed_send_keeps_episode_unalerted(self):
        self.lib.write_text("telegram_send() { return 1; }\n")
        self.main()
        self.assertEqual(self.main(), 1)
        self.assertFalse(json.loads(self.state.read_text())["a"]["alerted"])

    def test_quarantined_message_is_not_counted_as_sent(self):
        # WP-484 F316: telegram_send exits 0 when the gate quarantines a message; the alarm used to
        # log "sent" for three days of a stuck copy while nothing reached the pilot.
        self.lib.write_text("telegram_send() { TELEGRAM_SEND_OUTCOME=quarantined; return 0; }\n")
        self.main()
        self.assertEqual(self.main(), 1)
        state = json.loads(self.state.read_text())["a"]
        self.assertFalse(state["alerted"])
        self.assertFalse(state.get("last_alert"))

    def test_message_without_any_outcome_is_not_counted_as_sent(self):
        self.lib.write_text("telegram_send() { return 0; }\n")  # creds missing: send path never reached
        self.main()
        self.assertEqual(self.main(), 1)
        self.assertFalse(json.loads(self.state.read_text())["a"]["alerted"])

    def test_deferred_message_counts_as_delivered(self):
        self.lib.write_text("telegram_send() { TELEGRAM_SEND_OUTCOME=deferred; return 0; }\n")
        self.main()
        self.assertEqual(self.main(), 0)
        self.assertTrue(json.loads(self.state.read_text())["a"]["alerted"])


if __name__ == "__main__":
    unittest.main()
