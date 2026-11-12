"""Bookkeeping of the intent gate at close (WP-484 И-13): taking files, merge, verdicts, retry file."""
from pathlib import Path
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import intent_gate_close as igc  # noqa: E402


class IntentGateCloseTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.sessions = self.dir / "sessions"
        self.sessions.mkdir()
        self.own = self.dir / "me.open.intents"

    def test_a_late_append_after_taking_lands_in_a_new_file_that_is_not_removed(self):
        self.own.write_text("intent-1 agent-a MC:x.md\n")
        orphan = self.dir / "gone.open.intents"
        orphan.write_text("intent-2 agent-a MC:y.md\n")
        sources = igc.take_sources(self.dir, self.own, self.sessions)
        # A claim that passed the semaphore check before close appends now.
        with open(self.own, "a") as f:
            f.write("intent-3 agent-a MC:z.md\n")
        taken = sources
        self.assertNotIn(self.own, taken)
        self.assertNotIn(orphan, taken)
        self.assertEqual(len(taken), 2)
        self.assertTrue(all(".closing." in p.name for p in taken))
        self.assertEqual(self.own.read_text(), "intent-3 agent-a MC:z.md\n")

    def test_an_open_sessions_intents_are_not_taken(self):
        (self.sessions / "live.open").write_text("")
        live = self.dir / "live.open.intents"
        live.write_text("intent-4 agent-b MC:w.md\n")
        self.assertEqual(igc.take_sources(self.dir, self.own, self.sessions), [])
        self.assertTrue(live.exists())

    def test_same_intent_in_two_files_is_merged_with_the_larger_count(self):
        closing = self.dir / "me.open.intents.closing.1.0"
        closing.write_text("intent-5 agent-a MC:x.md\n")
        retry = self.dir / "old.open.intents.retry"
        retry.write_text("intent-5 agent-a 484 1 timeout\n")
        first_seen = int(time.time()) - 600
        retry.write_text(f"intent-5 agent-a - 1 timeout {first_seen}\n")
        entries, lapsed, unreadable = igc.read_entries([closing, retry], time.time(), 172800)
        self.assertEqual(list(entries), ["intent-5"])
        self.assertEqual(entries["intent-5"]["attempts"], 1)
        # The earlier of the two sightings wins.
        self.assertEqual(entries["intent-5"]["first_seen"], first_seen)
        self.assertEqual((lapsed, unreadable), ([], []))

    def test_age_follows_the_intent_not_the_rewritten_file(self):
        retry = self.dir / "old.open.intents.retry"
        retry.write_text("intent-6 agent-a - 7 origin_unreachable 1700000000\n")
        entries, lapsed, _ = igc.read_entries([retry], 1700000000 + 172801, 172800)
        self.assertEqual(entries, {})
        self.assertEqual([(i, r["attempts"], reason) for i, r, reason in lapsed], [("intent-6", 7, "origin_unreachable")])

    def test_settle_sorts_verdicts(self):
        entries = {i: {"agent": "a", "attempts": a, "reason": "-", "first_seen": 5}
                   for i, a in (("r", 0), ("al", 0), ("own", 0), ("nf1", 0), ("nf2", 1), ("lost", 0))}
        verdicts = {"r": ("resolved", ""), "al": ("already", ""), "own": ("refused", "owner_mismatch"),
                    "nf1": ("refused", "not_found"), "nf2": ("refused", "not_found")}
        retry, rows, counts = igc.settle(entries, [], verdicts, 4)
        self.assertEqual(counts, {"resolved": 1, "already": 1, "retry": 2, "lapsed": 2})
        self.assertEqual(sorted(retry), ["lost a - 1 origin_unreachable 5", "nf1 a - 1 not_found 5"])
        self.assertIn("lapsed\town a attempts=1 reason=owner_mismatch", rows)
        self.assertIn("lapsed\tnf2 a attempts=2 reason=not_found", rows)

    def test_publish_retry_without_leftovers_removes_an_older_file(self):
        retry_out = self.dir / "me.open.intents.retry"
        retry_out.write_text("stale\n")
        igc.publish_retry(retry_out, [])
        self.assertFalse(retry_out.exists())
        igc.publish_retry(retry_out, ["x a - 1 timeout 5"])
        self.assertEqual(retry_out.read_text(), "x a - 1 timeout 5\n")
        self.assertEqual(list(self.dir.glob("*.tmp.*")), [])

    def test_lock_is_exclusive_and_released_with_its_holder(self):
        lock = self.dir / "resolve.lock"
        first = igc.take_lock(lock, 0)
        self.assertIsNotNone(first)
        self.assertIsNone(igc.take_lock(lock, 0.3))
        igc.os.close(first)
        second = igc.take_lock(lock, 0)
        self.assertIsNotNone(second)
        igc.os.close(second)


if __name__ == "__main__":
    unittest.main()
