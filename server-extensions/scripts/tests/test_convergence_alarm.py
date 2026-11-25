"""Tests for scripts/convergence-alarm.py (WP-539 F21 B0): one daytime message per lag episode."""

import contextlib
import copy
import datetime as dt
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
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
    def test_sync_refusal_of_this_episode_is_named_with_an_action(self):
        # WP-484 F327: the strategy copy alarm must say why the sync service refuses and what to do.
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "sync.err.log"
            log.write_text("dirty-overlap: old cause from an earlier episode\n")
            bookmark = alarm.log_bookmark(log)
            with log.open("a") as stream:
                stream.write("ledger-publish: ok\n"
                             "dirty-ff-admission: dirty-overlap: чужие правки на путях, которые меняет перемотка: a.md\n"
                             "mac-canon-sync-backstop: publisher=0 sync=1 observer=0\n")
            reason = alarm.last_sync_refusal(log, bookmark)
            self.assertIn("dirty-overlap: чужие правки", reason)
            self.assertIn("опубликовать или сохранить", alarm.sync_action(reason))
            self.assertIn("проверь копию Мака",
                          alarm.sync_action("ledger-reconcile: refused: unsupported changed ledger path: x"))

    def test_refusal_written_before_the_episode_is_not_reported_even_if_the_log_grows(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "sync.err.log"
            log.write_text("ledger-reconcile: refused: old cause\n")
            bookmark = alarm.log_bookmark(log)
            with log.open("a") as stream:
                stream.write("git-dirty-guard: clean (or untracked-only)\n")  # every run adds lines like this
            self.assertEqual(alarm.last_sync_refusal(log, bookmark), "")
            self.assertEqual(alarm.last_sync_refusal(Path(tmp) / "missing.log", {"offset": 0}), "")
            log.write_text("short\n")  # rotated: shorter than the bookmark -> read from the start
            self.assertEqual(alarm.last_sync_refusal(log, {"offset": 10_000}), "")

    def test_rotated_log_that_regrew_past_the_bookmark_is_read_from_its_start(self):
        # WP-484 F327, Codex review 23.11: a size bookmark alone misses a new cause once the
        # rotated log grows past the old size again.
        old = "git-dirty-guard: clean (or untracked-only)\n" * 3
        new = ("ledger-reconcile: refused: unsupported changed ledger path: x\n"
               + "git-dirty-guard: clean (or untracked-only)\n" * 4)
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "sync.err.log"
            # replaced by a new file (rename rotation)
            log.write_text(old)
            bookmark = alarm.log_bookmark(log)
            replacement = Path(tmp) / "fresh.log"
            replacement.write_text(new)
            os.replace(replacement, log)
            self.assertIn("unsupported changed ledger path", alarm.last_sync_refusal(log, bookmark))
            # truncated in place and rewritten (copy-truncate rotation, same file)
            log.write_text(old)
            bookmark = alarm.log_bookmark(log)
            with log.open("r+") as stream:
                stream.truncate(0)
                stream.write(new)
            self.assertIn("unsupported changed ledger path", alarm.last_sync_refusal(log, bookmark))

    def test_lag_alarms_once_after_threshold_then_recovers_silently(self):
        state = {}
        self.assertIsNone(alarm.step(state, "x", "behind -3", 30, minutes(0)))
        self.assertIsNone(alarm.step(state, "x", "behind -5", 30, minutes(29)))
        self.assertEqual(alarm.step(state, "x", "behind -5", 30, minutes(31)), "⚠️ x: позади на 5 коммитов уже 31 мин (порог 30)")
        state["x"]["alerted"] = True  # main() marks it after a successful send
        self.assertIsNone(alarm.step(state, "x", "behind -6", 30, minutes(60)))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertIsNone(alarm.step(state, "x", "equal", 30, minutes(61)))  # no chat message (25.11)
        self.assertEqual(state, {})
        self.assertIn("recovered, not sent: x", out.getvalue())

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

    def test_old_state_with_recovered_flag_continues_the_episode(self):
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
        # 6 h for every copy: pilot decision 25.11.2026 (WP-568 F14), above the normal 1-3 h lag
        expected = {".": 360, "MC-sessions": 360, "DS-MCP/knowledge-mcp": 360,
                    "DS-IT-systems/activity-hub": 360, "DS-my-strategy": 360}
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
        self.notify = base / "iwe-notify"
        self.secrets = base / "tg-bots"
        self.secrets.write_text("export TELEGRAM_BOT_TOKEN=t TELEGRAM_CHAT_ID=c\n")
        self.fake_notify(f'printf "%s\\n--\\n" "$5" >> "{self.sent}"; echo "iwe-notify: outcome=direct-sent"')
        self.state = base / "state.json"
        self.log = base / "reader.log"
        fresh = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        self.log.write_text(f"[{fresh}] [reader-copies-sync] a: BLOCKED свои коммиты\n")
        self.quiet = (0, 0)  # no quiet hours
        self.copy_dir = copy_dir

    def tearDown(self):
        self.tmp.cleanup()

    def fake_notify(self, body):
        """A stand-in for scripts/iwe-notify: `body` runs with the caller's arguments $1..$5."""
        self.notify.write_text("#!/bin/bash\n" + body + "\n")
        self.notify.chmod(0o755)

    def main(self):
        argv = ["convergence-alarm.py", "--root", str(self.root), "--registry", str(self.registry),
                "--host", "mac", "--state", str(self.state), "--reader-log", str(self.log),
                "--notify", str(self.notify), "--secrets", str(self.secrets), "--quiet-from", str(self.quiet[0]), "--quiet-to", str(self.quiet[1])]
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
        self.assertIn("копия не перематывается: свои коммиты", text)
        self.assertIn("что сделать: опубликовать коммиты этой копии", text)
        self.assertNotIn("BLOCKED", text)
        self.assertTrue(json.loads(self.state.read_text())["a"]["alerted"])
        self.assertEqual(self.main(), 0)  # no repeat for the same episode
        self.assertEqual(self.sent.read_text().count("⚠️"), 1)

    def test_send_goes_direct_with_its_source_and_the_bot_keys(self):
        # WP-484 F316 item 1: the alarm never goes through the strategy repo's gateway, whose sender list
        # was stale exactly when the alarm mattered; the keys come from the secrets file.
        calls = Path(self.tmp.name) / "calls.txt"
        self.fake_notify(f'printf "%s|%s|%s|%s|%s\\n" "$1" "$2" "$3" "$4" "${{TELEGRAM_BOT_TOKEN:-}}" >> "{calls}"; '
                         'echo "iwe-notify: outcome=direct-sent"')
        self.main()
        self.main()
        self.assertEqual(calls.read_text().strip(), "--direct|--source|convergence-alarm|--|t")

    def test_keys_assigned_without_export_still_reach_notify(self):
        # Cold review 20.11: `. file` then `exec` hands over only exported variables; under launchd
        # nothing else exports the keys, so an alarm would be "not-sent" forever.
        calls = Path(self.tmp.name) / "calls.txt"
        self.secrets.write_text("TELEGRAM_BOT_TOKEN=t\nTELEGRAM_CHAT_ID=c\n")
        self.fake_notify(f'printf "%s|%s\\n" "${{TELEGRAM_BOT_TOKEN:-}}" "${{TELEGRAM_CHAT_ID:-}}" >> "{calls}"; '
                         'echo "iwe-notify: outcome=direct-sent"')
        clean = {k: v for k, v in os.environ.items() if not k.startswith("TELEGRAM_")}
        with mock.patch.dict(os.environ, clean, clear=True):
            self.main()
            self.assertEqual(self.main(), 0)
        self.assertEqual(calls.read_text().strip(), "t|c")

    def test_secrets_file_cannot_change_the_arguments(self):
        calls = Path(self.tmp.name) / "calls.txt"
        self.secrets.write_text("set -- forged forged forged forged\nexport TELEGRAM_BOT_TOKEN=t\n")
        self.fake_notify(f'printf "%s|%s|%s\\n" "$1" "$3" "$5" >> "{calls}"; echo "iwe-notify: outcome=direct-sent"')
        self.main()
        self.main()
        self.assertTrue(calls.read_text().startswith("--direct|convergence-alarm|🔄 Сходимость git"))

    def test_missing_secrets_file_still_calls_notify_which_reports_not_sent(self):
        self.secrets.unlink()
        self.fake_notify('echo "iwe-notify: outcome=not-sent"')
        self.main()
        self.assertEqual(self.main(), 1)
        self.assertFalse(json.loads(self.state.read_text())["a"]["alerted"])

    def test_sent_alarm_records_when_it_was_sent_and_a_failed_send_does_not(self):
        self.main()
        self.main()
        self.assertTrue(json.loads(self.state.read_text())["a"]["last_alert"])
        self.fake_notify('echo "iwe-notify: outcome=direct-failed"; exit 1')
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

    def test_recovery_sends_nothing_and_ends_the_episode(self):
        self.main()
        self.main()  # alarm sent
        sent_before = self.sent.read_text()
        self.catch_up()
        self.assertEqual(self.main(), 0)
        self.assertEqual(self.sent.read_text(), sent_before)  # no "снова совпадает" in the chat (25.11)
        self.assertEqual(json.loads(self.state.read_text()), {})

    def test_log_names_copy_and_kind_of_each_message(self):
        self.main()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.main()  # alarm sent
        self.assertRegex(out.getvalue(), r"convergence-alarm: \S+ sent: ⚠️ a: позади на 1 коммит уже \d+ мин")
        self.catch_up()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.main()
        self.assertIn("recovered, not sent: a", out.getvalue())

    def test_failed_send_keeps_episode_unalerted(self):
        self.fake_notify('echo "iwe-notify: outcome=direct-failed"; exit 1')
        self.main()
        self.assertEqual(self.main(), 1)
        self.assertFalse(json.loads(self.state.read_text())["a"]["alerted"])

    def assert_not_delivered(self):
        self.main()
        self.assertEqual(self.main(), 1)
        state = json.loads(self.state.read_text())["a"]
        self.assertFalse(state["alerted"])
        self.assertFalse(state.get("last_alert"))

    def test_gateway_outcomes_are_not_counted_as_delivered(self):
        # Only a direct send confirmed by Telegram counts; a gateway verdict here means the flag was ignored.
        for outcome in ("sent", "deferred", "quarantined", "not-sent", "direct-failed"):
            with self.subTest(outcome=outcome):
                self.state.unlink(missing_ok=True)
                self.fake_notify(f'echo "iwe-notify: outcome={outcome}"')
                self.assert_not_delivered()

    def test_message_without_any_outcome_is_not_counted_as_sent(self):
        self.fake_notify("exit 0")  # an old iwe-notify without --direct dies on the flag before any outcome
        self.assert_not_delivered()

    def test_direct_sent_with_late_failure_is_not_repeated(self):
        self.fake_notify('echo "iwe-notify: outcome=direct-sent"; exit 1')
        self.main()
        self.assertEqual(self.main(), 0)
        self.assertTrue(json.loads(self.state.read_text())["a"]["alerted"])

    def test_the_last_outcome_line_wins(self):
        self.fake_notify('echo "iwe-notify: outcome=direct-sent"; echo "iwe-notify: outcome=direct-failed"')
        self.assert_not_delivered()

    def test_secrets_file_output_cannot_forge_the_outcome(self):
        self.secrets.write_text('echo "iwe-notify: outcome=direct-sent"\nexport TELEGRAM_BOT_TOKEN=t\n')
        self.fake_notify('echo "iwe-notify: outcome=direct-failed"; exit 1')
        self.assert_not_delivered()

    def test_failing_secrets_file_stops_before_notify(self):
        calls = Path(self.tmp.name) / "calls.txt"
        self.secrets.write_text("return 3\n")
        self.fake_notify(f'echo called >> "{calls}"; echo "iwe-notify: outcome=direct-sent"')
        self.assert_not_delivered()
        self.assertFalse(calls.exists())


class LocalBackupTest(unittest.TestCase):
    """WP-484 F324: a copy whose upstream is a bare repository on this disk (agent memory)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.backup, self.copy = base / "backup.git", base / "memory"
        run(base, "init", "-q", "--bare", "-b", "main", str(self.backup))
        run(base, "init", "-q", "-b", "main", str(self.copy))
        run(self.copy, "remote", "add", "origin", str(self.backup))
        self.commit(self.copy, "one")
        run(self.copy, "push", "-q", "-u", "origin", "main")

    def tearDown(self):
        self.tmp.cleanup()

    def commit(self, repo, message):
        run(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", message)

    def push_from_a_stale_clone(self):
        """What happened on 15.11: another copy pushed a commit the main copy never fetched."""
        other = Path(self.tmp.name) / "other"
        run(Path(self.tmp.name), "clone", "-q", str(self.backup), str(other))
        self.commit(other, "from the stale copy")
        run(other, "push", "-q", "origin", "main")

    def test_equal_and_unpushed_commits_are_not_an_episode(self):
        self.assertEqual(alarm.local_backup_label(self.copy), "equal")
        self.commit(self.copy, "not pushed yet")
        self.assertEqual(alarm.local_backup_label(self.copy), "equal")

    def test_a_push_from_another_copy_is_seen_without_a_manual_fetch(self):
        self.push_from_a_stale_clone()
        self.assertEqual(alarm.local_backup_label(self.copy), "behind -1")
        self.commit(self.copy, "local work")
        self.assertEqual(alarm.local_backup_label(self.copy), "diverged +1/-1")

    def test_relative_and_file_url_backups_are_watched(self):
        for url in ("../backup.git", f"file://{self.backup}"):
            with self.subTest(url=url):
                run(self.copy, "remote", "set-url", "origin", url)
                self.assertEqual(alarm.local_backup_label(self.copy), "equal")
        self.push_from_a_stale_clone()
        self.assertEqual(alarm.local_backup_label(self.copy), "behind -1")

    def test_fetch_leaves_no_fetch_head(self):
        self.push_from_a_stale_clone()
        alarm.local_backup_label(self.copy)
        self.assertFalse((self.copy / ".git" / "FETCH_HEAD").exists())

    def test_hung_git_is_an_episode_not_a_crash(self):
        with mock.patch.object(alarm.report, "relation", side_effect=subprocess.TimeoutExpired("git", 30)):
            self.assertEqual(alarm.local_backup_label(self.copy), "резервная копия не читается: TimeoutExpired")

    def test_unreadable_backup_is_an_episode(self):
        run(self.copy, "remote", "set-url", "origin", str(Path(self.tmp.name) / "gone.git"))
        self.assertTrue(alarm.local_backup_label(self.copy).startswith("резервная копия не читается"))

    def test_network_or_missing_upstream_is_not_checked_here(self):
        for url in ("https://example.invalid/memory.git", "git@example.invalid:memory.git"):
            run(self.copy, "remote", "set-url", "origin", url)
            self.assertIsNone(alarm.local_backup_label(self.copy))
        run(self.copy, "remote", "remove", "origin")
        self.assertIsNone(alarm.local_backup_label(self.copy))

    def test_main_alarms_on_diverged_memory(self):
        root = Path(self.tmp.name) / "root"
        root.mkdir()
        (root / "memory").symlink_to(self.copy)
        registry = Path(self.tmp.name) / "registry.yaml"
        registry.write_text(json.dumps({"version": 1, "repos": [  # one absent copy: the registry may not be empty
            {"repo_id": "a", "class": "reader", "checkouts": [{"host": "mac", "path": "a"}],
             "decision_owner": {"ref": "p", "scope": "repo"}, "thresholds": {"behind_observed_for_min": 0}}]}))
        sent = Path(self.tmp.name) / "sent.txt"
        notify = Path(self.tmp.name) / "iwe-notify"
        notify.write_text(f'#!/bin/bash\nprintf "%s\\n--\\n" "$5" >> "{sent}"; echo "iwe-notify: outcome=direct-sent"\n')
        notify.chmod(0o755)
        state = Path(self.tmp.name) / "state.json"
        argv = ["convergence-alarm.py", "--root", str(root), "--registry", str(registry), "--host", "mac",
                "--state", str(state), "--notify", str(notify), "--secrets", str(Path(self.tmp.name) / "none"),
                "--quiet-from", "0", "--quiet-to", "0"]
        self.push_from_a_stale_clone()
        self.commit(self.copy, "local work")
        with mock.patch.object(sys, "argv", argv), mock.patch.object(alarm, "LOCAL_BACKUPS", (("memory", 0),)):
            self.assertEqual(alarm.main(), 0)  # opens the episode
            self.assertEqual(alarm.main(), 0)  # threshold 0: alarm now
            self.assertIn("⚠️ memory: расходится: впереди на 1 коммит, позади на 1 коммит", sent.read_text())
            run(self.copy, "-c", "user.name=t", "-c", "user.email=t@t", "merge", "-q", "-s", "ours", "--no-edit", "origin/main")
            self.assertEqual(alarm.main(), 0)
        self.assertNotIn("✅", sent.read_text())  # recovery is not a chat message (25.11)
        self.assertEqual(json.loads(state.read_text()), {})


class ReaderReasonTest(unittest.TestCase):
    """The mover's log line reaches the pilot in words, never as the raw BLOCKED/SKIP token (WP-568, 24.11)."""

    def setUp(self):
        self.now = dt.datetime.now().astimezone()

    def reason(self, outcome, minutes_ago=1):
        return alarm.reader_reason(self.now - dt.timedelta(minutes=minutes_ago), outcome, self.now)

    def test_uncommitted_edits_get_words_and_an_action(self):
        text = self.reason("BLOCKED незакоммиченные правки (1)")
        self.assertEqual(text.splitlines()[0], "копия не перематывается: незакоммиченные правки (1)")
        self.assertIn("опубликовать их или осознанно отменить", text)

    def test_unknown_block_has_no_action(self):
        self.assertEqual(self.reason("BLOCKED не читается ветка"), "копия не перематывается: не читается ветка")

    def test_branch_advice_only_for_a_wrong_branch(self):
        self.assertIn("вернуть копию на основную ветку", self.reason("BLOCKED ветка wp-1 вместо main"))
        self.assertNotIn("вернуть копию", self.reason("BLOCKED ветка или HEAD сменились во время проверки"))

    def test_skip_moved_and_unknown(self):
        self.assertEqual(self.reason("SKIP другой запуск держит замок"), "перемотка отложена: другой запуск держит замок")
        self.assertIn("перемотали: 2 (одинаковые копии: 1);", self.reason("moved 2 (одинаковые копии: 1)"))
        self.assertIn("перемотали; сверка", self.reason("moved"))
        self.assertEqual(self.reason("absent (optional)"), "последняя запись журнала перемотки: absent (optional)")
        self.assertEqual(self.reason(""), "")

    def test_old_line_is_reported_as_silence_not_as_current_state(self):
        old = self.now - dt.timedelta(hours=20)
        text = alarm.reader_reason(old, "moved 2", self.now)
        self.assertEqual(text, f"журнал перемотки об этой копии молчит с {old:%d.%m %H:%M}: перемотка, похоже, не запускается")
        self.assertNotIn("только что", text)

    def test_last_reader_line_reads_the_time(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "reader.log"
            log.write_text("[2026-11-23 22:50:01] [reader-copies-sync] a: moved 1\n"
                           "[2026-11-23 22:55:02] [reader-copies-sync] b: BLOCKED свои коммиты\n")
            stamp, outcome = alarm.last_reader_line(log, "a")
            self.assertEqual((stamp.strftime("%Y-%m-%d %H:%M:%S"), outcome), ("2026-11-23 22:50:01", "moved 1"))
            self.assertEqual(alarm.last_reader_line(log, "c"), (None, ""))


if __name__ == "__main__":
    unittest.main()
