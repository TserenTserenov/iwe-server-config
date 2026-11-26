"""iwe-chat-rule: the chat rule of the pilot's chat (WP-625 F14 step 2, stage 3; ArchGate 26.11).

The cases the DRR names: planned/urgent/empty/missing action, the host's daily share, a counter safe against two
senders at once, the Cyprus day boundary, the expiry and return of a reservation, fail-open on a broken rule.
"""

import datetime as dt
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parent.parent / "iwe-chat-rule"
_loader = importlib.machinery.SourceFileLoader("iwe_chat_rule", str(SCRIPT))
_spec = importlib.util.spec_from_loader("iwe_chat_rule", _loader)
rule = importlib.util.module_from_spec(_spec)
_loader.exec_module(rule)

BUDGET = (
    "calm\t0\tx\tпилот 26.11.2026: допущен\t-\n"
    "loud\t0\tx\tпилот 26.11.2026: допущен\tсрочное: пилот 26.11.2026: сервер упал\n"
    "remind\tplanned\tx\tпилот 26.11.2026: допущен\n"
)


class RuleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        (self.dir / "budget.conf").write_text(BUDGET, encoding="utf-8")
        (self.dir / "shares.conf").write_text("# host\\tshare\ntsekh-1\t1\nMacBook\t2\n", encoding="utf-8")
        self.env = {**os.environ, "DS_PUBLISH_ADMISSION_DIR": str(self.dir / "adm"),
                    "IWE_CHAT_RULE_BUDGET": str(self.dir / "budget.conf"),
                    "IWE_CHAT_RULE_SHARES": str(self.dir / "shares.conf"),
                    "IWE_CHAT_RULE_HOST": "tsekh-1", "NOTIFY_DIGEST_TZ": "Asia/Nicosia"}
        self.env.pop("IWE_CHAT_RULE_ENFORCE", None)

    def tearDown(self):
        self.tmp.cleanup()

    def run_rule(self, *args, enforce=True, env=None):
        full = {**self.env, **(env or {})}
        if enforce:
            full["IWE_CHAT_RULE_ENFORCE"] = "1"
        done = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=full, check=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout)

    def decide(self, source, action="present", channel="live", kind="", **kw):
        return self.run_rule("decide", "--source", source, "--channel", channel, "--kind", kind,
                             "--action", action, **kw)

    def test_planned_sender_and_planned_kinds_pass_and_are_not_counted(self):
        self.assertEqual(self.decide("remind", action="missing")["reason"], "planned")
        self.assertEqual(self.decide("any", channel="sink", action="missing")["reason"], "planned")
        for kind in ("plan", "question"):
            self.assertEqual(self.decide("any", channel="kind", kind=kind, action="missing")["reason"], "planned")
        # none of them used the host's share
        self.assertEqual(self.decide("calm")["verdict"], "send")

    def test_empty_action_goes_to_the_digest_even_when_urgent(self):
        for source in ("calm", "loud"):
            result = self.decide(source, action="empty")
            self.assertEqual((result["verdict"], result["reason"]), ("digest", "action-empty"), source)

    def test_missing_action_urgent_is_sent_not_urgent_goes_to_the_digest(self):
        self.assertEqual(self.decide("calm", action="missing")["reason"], "action-missing")
        self.assertEqual(self.decide("calm", action="missing")["verdict"], "digest")
        result = self.decide("loud", action="missing")
        self.assertEqual(result["verdict"], "send")
        self.assertIn("urgent-action-missing", result["reason"])

    def test_share_of_the_host_is_one_and_only_urgent_breaks_it(self):
        self.assertEqual(self.decide("calm")["verdict"], "send")                    # the 1st of 1
        second = self.decide("calm")
        self.assertEqual((second["verdict"], second["reason"]), ("digest", "over-share(1/1)"))
        urgent = self.decide("loud")
        self.assertEqual((urgent["verdict"], urgent["reason"]), ("send", "urgent-over-share"))
        self.assertEqual(self.decide("calm")["reason"], "over-share(2/1)")          # the urgent one was counted

    def test_share_comes_from_the_host_row_and_defaults_to_one(self):
        env = {"IWE_CHAT_RULE_HOST": "MacBook"}
        verdicts = [self.run_rule("decide", "--source", "calm", "--channel", "live", "--action", "present",
                                  env=env)["verdict"] for _ in range(3)]
        self.assertEqual(verdicts, ["send", "send", "digest"])                      # share 2
        # A host is one machine with one counter file: the unknown host gets its own folder here.
        env = {"IWE_CHAT_RULE_HOST": "unknown-host", "DS_PUBLISH_ADMISSION_DIR": str(self.dir / "other-host")}
        verdicts = [self.run_rule("decide", "--source", "calm", "--channel", "live", "--action", "present",
                                  env=env)["verdict"] for _ in range(2)]
        self.assertEqual(verdicts, ["send", "digest"])                              # default share 1

    def test_observe_mode_never_digests_and_logs_what_enforcement_would_do(self):
        first = self.decide("calm", enforce=False)
        second = self.decide("calm", enforce=False)
        self.assertEqual((first["verdict"], first["mode"], first["would"]), ("send", "observe", "send"))
        self.assertEqual((second["verdict"], second["would"]), ("send", "digest"))
        self.assertEqual(self.decide("calm", action="empty", enforce=False)["verdict"], "send")
        rows = (self.dir / "adm" / "chat-rule-observe.tsv").read_text(encoding="utf-8").splitlines()
        self.assertEqual([r.split("\t")[3:6] for r in rows],
                         [["send", "within-share", "observe"], ["digest", "over-share(1/1)", "observe"],
                          ["digest", "action-empty", "observe"]])

    def test_two_senders_at_once_cannot_both_pass_a_share_of_one(self):
        env = {**self.env, "IWE_CHAT_RULE_ENFORCE": "1"}
        procs = [subprocess.Popen([sys.executable, str(SCRIPT), "decide", "--source", "calm", "--channel", "live",
                                   "--action", "present"], stdout=subprocess.PIPE, text=True, env=env)
                 for _ in range(8)]
        verdicts = [json.loads(p.communicate()[0])["verdict"] for p in procs]
        self.assertEqual(verdicts.count("send"), 1, verdicts)
        self.assertEqual(verdicts.count("digest"), 7, verdicts)

    def test_released_reservation_gives_the_share_back_and_confirmed_one_keeps_it(self):
        token = self.decide("calm")["token"]
        self.assertEqual(self.decide("calm")["verdict"], "digest")
        self.token_call("release", token)
        token = self.decide("calm")["token"]
        self.token_call("confirm", token)
        self.assertEqual(self.decide("calm")["verdict"], "digest")

    def token_call(self, action, token):
        subprocess.run([sys.executable, str(SCRIPT), action, "--token", token], check=True,
                       env={**self.env, "IWE_CHAT_RULE_ENFORCE": "1"})

    def test_expired_reservation_is_dropped_confirmed_one_is_not(self):
        adm = self.dir / "adm"
        adm.mkdir(parents=True)
        old = dt.datetime.now(dt.timezone.utc).timestamp() - rule.RESERVATION_TTL_SECONDS - 60
        day = dt.datetime.now(dt.timezone.utc).astimezone(rule.zone()).date().isoformat()
        (adm / "chat-day-counter.json").write_text(json.dumps({"day": day, "entries": [
            {"token": "a", "source": "calm", "ts": old, "state": "reserved"}]}), encoding="utf-8")
        self.assertEqual(self.decide("calm")["verdict"], "send")                     # the stale reservation expired
        (adm / "chat-day-counter.json").write_text(json.dumps({"day": day, "entries": [
            {"token": "a", "source": "calm", "ts": old, "state": "sent"}]}), encoding="utf-8")
        self.assertEqual(self.decide("calm")["verdict"], "digest")                   # a sent message never expires

    def test_the_day_changes_at_midnight_in_cyprus_not_in_utc(self):
        # 22:30 UTC on 25.11 is 00:30 on 26.11 in Cyprus (UTC+2): a new day, a fresh share.
        before = dt.datetime(2026, 11, 25, 21, 30, tzinfo=dt.timezone.utc)
        after = dt.datetime(2026, 11, 25, 22, 30, tzinfo=dt.timezone.utc)
        with mock.patch.dict(os.environ, self.env), mock.patch.object(rule, "now_utc", return_value=before):
            with rule.Counter(before.astimezone(rule.zone()).date().isoformat()) as counter:
                counter.reserve("calm")
                self.assertEqual(counter.used(), 1)
        with mock.patch.dict(os.environ, self.env), mock.patch.object(rule, "now_utc", return_value=after):
            day = after.astimezone(rule.zone()).date().isoformat()
            self.assertEqual(day, "2026-11-26")
            with rule.Counter(day) as counter:
                self.assertEqual(counter.used(), 0)

    def test_a_broken_rule_is_fail_open_and_logged(self):
        (self.dir / "budget.conf").unlink()
        result = self.decide("calm")
        self.assertEqual((result["verdict"], result["mode"]), ("send", "error"))
        log = (self.dir / "adm" / "chat-rule-failures.log").read_text(encoding="utf-8")
        self.assertIn("calm", log)
        self.assertIn("FileNotFoundError", log)

    def test_a_corrupt_counter_starts_a_fresh_day_and_is_logged(self):
        adm = self.dir / "adm"
        adm.mkdir(parents=True)
        (adm / "chat-day-counter.json").write_text("{not json", encoding="utf-8")
        self.assertEqual(self.decide("calm")["verdict"], "send")
        self.assertIn("counter-corrupt", (adm / "chat-rule-failures.log").read_text(encoding="utf-8"))

    def test_a_stuck_lock_ends_the_call_after_the_deadline_instead_of_holding_the_message(self):
        import fcntl
        import time
        adm = self.dir / "adm"
        adm.mkdir(parents=True)
        with open(adm / "chat-day-counter.lock", "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            started = time.monotonic()
            done = subprocess.run([sys.executable, str(SCRIPT), "decide", "--source", "calm", "--channel", "live",
                                   "--action", "present"], capture_output=True, text=True, env=self.env, check=False)
            elapsed = time.monotonic() - started
        self.assertNotEqual(done.returncode, 0)                                  # killed by the alarm, no verdict
        self.assertLess(elapsed, rule.RULE_DEADLINE_SECONDS + 3)
        self.assertEqual(done.stdout, "")                                        # the caller reads silence as "send"

    def test_usage_error_is_the_only_nonzero_exit(self):
        done = subprocess.run([sys.executable, str(SCRIPT), "decide", "--source", "x"], capture_output=True, text=True,
                              env=self.env, check=False)
        self.assertEqual(done.returncode, 2)


if __name__ == "__main__":
    unittest.main()
