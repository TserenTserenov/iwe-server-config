"""Close route classifier (WP-561 F61 stage 1): the pilot's scheme WP-484 F304 as a fact table.

Rows follow Fable's check table: what the conversation did; who closes and how;
what confirms it (declared / proven / signed); how it goes (normal / resume /
cleanup), including the forbidden combinations.
"""
import json
from pathlib import Path
import subprocess
import sys
import unittest

LIB = Path(__file__).resolve().parents[1] / "lib"
sys.path.insert(0, str(LIB))
import close_route as cr  # noqa: E402


def facts(**overrides):
    base = {
        "semaphores": 1,
        "declared": "unknown",
        "wp": "WP-561",
        "housekeeping": False,
        "resume_state": "none",
        "isolated": True,
        "no_changes": "refused",
        "no_changes_reason": "в изолированной копии есть несохранённые изменения",
        "peer_evidence": "no",
    }
    base.update(overrides)
    return base


class OrderOfQuestions(unittest.TestCase):
    def test_unfinished_close_wins_over_changes_and_declaration(self):
        out = cr.classify(facts(resume_state="prepared", declared="peer-session", peer_evidence="yes"))
        self.assertEqual(out["route"], cr.RESUME)
        self.assertEqual(out["owner_command"], "close")
        self.assertFalse(out["mismatch"])

    def test_unfinished_machine_run_is_resumed_by_its_own_command(self):
        out = cr.classify(facts(resume_state="prepared", declared="machine-publish-only"))
        self.assertEqual(out["route"], cr.RESUME)
        self.assertEqual(out["owner_command"], "machine-close")

    def test_unfinished_close_is_never_released_as_empty(self):
        out = cr.classify(facts(resume_state="prepared", no_changes="proven"))
        self.assertNotEqual(out["route"], cr.RELEASE_EMPTY)

    def test_new_close_of_machine_run_or_day_protocol_is_out_of_scope(self):
        for case in (facts(declared="pipeline"), facts(declared="machine-publish-only"),
                     facts(wp="day-close"), facts(housekeeping=True)):
            with self.subTest(case=case):
                out = cr.classify(case)
                self.assertIsNone(out["route"])
                self.assertEqual(out["refuse"], "out-of-scope")

    def test_publish_only_is_reported_as_service_act_not_closed(self):
        out = cr.classify(facts(declared="publish-only", no_changes="proven"))
        self.assertIsNone(out["route"])
        self.assertEqual(out["refuse"], "service-act")

    def test_no_mark_means_nothing_to_close_with_the_limit_stated(self):
        out = cr.classify(facts(semaphores=0))
        self.assertEqual(out["route"], cr.NOTHING)
        self.assertIn("в обход учёта", out["pilot_phrase"])

    def test_selector_missing_an_open_mark_is_refused_not_nothing(self):
        out = cr.classify(facts(semaphores=-1))
        self.assertIsNone(out["route"])
        self.assertEqual(out["refuse"], "unresolved")

    def test_several_marks_are_refused_not_guessed(self):
        out = cr.classify(facts(semaphores=2))
        self.assertIsNone(out["route"])
        self.assertEqual(out["refuse"], "ambiguous")


class NoChangesProof(unittest.TestCase):
    def test_proven_in_isolated_copy_releases_without_declaration(self):
        out = cr.classify(facts(no_changes="proven", declared="unknown"))
        self.assertEqual(out["route"], cr.RELEASE_EMPTY)
        self.assertIn("ничего не менялось", out["pilot_phrase"])
        self.assertTrue(out["mismatch"])  # declaration said ordinary close

    def test_declared_no_changes_and_proven_is_not_a_mismatch(self):
        out = cr.classify(facts(no_changes="proven", declared="no-code-changes"))
        self.assertEqual(out["route"], cr.RELEASE_EMPTY)
        self.assertFalse(out["mismatch"])

    def test_shared_copy_never_proves_no_changes(self):
        # Pilot decision 12.11: proof only in an isolated copy.
        out = cr.classify(facts(isolated=False, no_changes="proven"))
        self.assertEqual(out["route"], cr.CLOSE_CHANGES)
        self.assertTrue(any("общая копия" in r for r in out["reasons"]))

    def test_declared_no_changes_but_not_proven_goes_to_ordinary_close(self):
        out = cr.classify(facts(declared="no-code-changes", no_changes="refused"))
        self.assertEqual(out["route"], cr.CLOSE_CHANGES)
        self.assertTrue(out["mismatch"])


class PeerStep(unittest.TestCase):
    def test_peer_traces_add_the_peer_step(self):
        out = cr.classify(facts(declared="peer-session", peer_evidence="yes"))
        self.assertEqual(out["route"], cr.CLOSE_CHANGES)
        self.assertTrue(out["peer_step"])
        self.assertFalse(out["mismatch"])

    def test_declared_peer_session_without_traces_is_flagged_only(self):
        # Turning this into a refusal is WP-484's repair, not F61.
        out = cr.classify(facts(declared="peer-session", peer_evidence="no"))
        self.assertEqual(out["route"], cr.CLOSE_CHANGES)
        self.assertFalse(out["peer_step"])
        self.assertIsNone(out["refuse"])
        self.assertTrue(out["mismatch"])

    def test_peer_traces_without_declaration_still_get_the_peer_step(self):
        out = cr.classify(facts(declared="unknown", peer_evidence="yes"))
        self.assertTrue(out["peer_step"])
        self.assertTrue(out["mismatch"])

    def test_ordinary_session_with_changes_matches_its_declaration(self):
        for declared in ("unknown", "quick-close"):
            with self.subTest(declared=declared):
                out = cr.classify(facts(declared=declared))
                self.assertEqual(out["route"], cr.CLOSE_CHANGES)
                self.assertFalse(out["mismatch"])


class CommandLine(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(LIB / "close_route.py"), *args],
                              capture_output=True, text=True, check=True).stdout

    def test_json_output_carries_the_outcome(self):
        out = json.loads(self.run_cli("--semaphores", "1", "--isolated", "1", "--no-changes", "proven"))
        self.assertEqual(out["route"], cr.RELEASE_EMPTY)

    def test_text_output_states_observation_mode(self):
        text = self.run_cli("--format", "text", "--semaphores", "1", "--declared", "peer-session",
                            "--peer-evidence", "yes")
        self.assertIn("close-changes + публикация журнала", text)
        self.assertIn("Этап 1", text)


if __name__ == "__main__":
    unittest.main()
