#!/usr/bin/env python3
"""Tests for scripts/wp-run-journal.py (WP-626 F7).

Each test drives the CLI on a throwaway run folder and asserts the exit code
and what the journal holds afterwards (written event, refusal event, or nothing).
Run: python3 scripts/tests/test_wp_run_journal.py
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = os.environ.get("WP_RUN_JOURNAL") or os.path.realpath(
    os.path.join(os.path.dirname(__file__), "..", "wp-run-journal.py"))
T0 = "2026-12-01T10:00:00Z"


class Run:
    """A run folder plus helpers that call the CLI the way the Manager would."""

    def __init__(self, root: Path):
        self.dir = root / "wp999-2026-12-01-1"
        self.clock = T0
        self.epoch = None

    def cli(self, *args):
        env = {**os.environ, "WP_RUN_JOURNAL_NOW": self.clock}
        res = subprocess.run([sys.executable, TOOL, args[0], "--run-dir", str(self.dir), *args[1:]],
                             capture_output=True, text=True, env=env)
        return res.returncode, res.stdout, res.stderr

    def events(self):
        path = self.dir / "events.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def types(self):
        return [e["type"] for e in self.events()]

    def create(self, holder="mgr-1"):
        code, out, err = self.cli("create", "--wp", "999", "--description-ref", "abc:inbox/WP-999/WP-999.md",
                                  "--host", "tsekh-1", "--holder", holder)
        assert code == 0, err
        self.epoch = json.loads(out)["epoch"]

    def append(self, etype, payload, epoch=None):
        return self.cli("append", "--epoch", str(epoch or self.epoch), "--type", etype,
                        "--payload", json.dumps(payload, ensure_ascii=False))

    def ask(self, rid, decision_id=None):
        (self.dir / "cards").mkdir(parents=True, exist_ok=True)
        (self.dir / "cards" / f"{rid}.md").write_text(f"card {rid}\n")
        payload = {"request_id": rid, "subject": "s", "right": "confirm"}
        if decision_id:
            payload["decision_id"] = decision_id
        code, _, err = self.append("pilot-requested", payload)
        assert code == 0, err

    def pilot_says(self, rid, answer="yes"):
        """What the answer-box hook writes; the agent never writes this file."""
        box = self.dir / "protected" / "pilot-answers.jsonl"
        with open(box, "a") as fh:
            fh.write(json.dumps({"request_id": rid, "answer": answer, "text": f"{rid}: {answer}",
                                 "transcript_ref": "msg-1"}) + "\n")
        code, out, err = self.cli("ingest-answers", "--epoch", str(self.epoch))
        assert code == 0, err
        return json.loads(out)

    def plan(self, phases, version=1, approval=None):
        payload = {"version": version, "graph": {"phases": phases}, "reason": "r"}
        if approval:
            payload["approval_request_id"] = approval
        return self.append("plan-revised", payload)

    def approved_plan(self, phases):
        self.ask("R-plan")
        self.pilot_says("R-plan")
        code, _, err = self.plan(phases, approval="R-plan")
        assert code == 0, err

    def move(self, phase, to, reason="next", **extra):
        return self.append("phase-transitioned", {"phase": phase, "to": to, "reason": reason, **extra})

    def run_to_checking(self, phase, verdict="pass"):
        assert self.move(phase, "ready")[0] == 0
        assert self.append("phase-assigned", {"phase": phase, "executor": "sonnet", "inputs": []})[0] == 0
        attempt = max(e["payload"]["attempt"] for e in self.events()
                      if e["type"] == "phase-assigned" and e["payload"]["phase"] == phase)
        assert self.append("artifact-submitted", {"phase": phase, "attempt": attempt,
                                                  "submission_ref": "s", "submission_sha": "x"})[0] == 0
        assert self.move(phase, "checking")[0] == 0
        assert self.append("verification-recorded", {"phase": phase, "attempt": attempt,
                                                     "verifier": "codex", "verdict": verdict})[0] == 0


TWO = {"A": {"deps": [], "budget_min": 60}, "B": {"deps": ["A"], "budget_min": 60}}


class JournalTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.run = Run(Path(self.tmp.name))
        self.run.create()

    def tearDown(self):
        self.tmp.cleanup()

    def test_create_writes_lease_and_run_and_chain_verifies(self):
        self.assertEqual(self.run.types(), ["lease-taken", "run-created"])
        code, out, _ = self.run.cli("verify")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["events"], 2)

    def test_edit_in_the_middle_breaks_the_chain(self):
        self.run.approved_plan(TWO)
        path = self.run.dir / "events.jsonl"
        lines = path.read_text().splitlines()
        lines[1] = lines[1].replace("tsekh-1", "mac")
        path.write_text("\n".join(lines) + "\n")
        code, _, err = self.run.cli("verify")
        self.assertEqual(code, 4)
        self.assertIn("prev_hash", err)

    def test_manager_cannot_append_pilot_answer(self):
        self.run.approved_plan(TWO)
        self.run.ask("R-1")
        code, _, err = self.run.append("pilot-answered", {"request_id": "R-1", "answer": "yes", "text": "yes"})
        self.assertEqual(code, 2)
        self.assertIn("cannot be appended by the Manager", err)
        answered = [e["payload"]["request_id"] for e in self.run.events() if e["type"] == "pilot-answered"]
        self.assertEqual(answered, ["R-plan"])

    def test_answer_after_card_edit_is_refused(self):
        self.run.ask("R-1")
        (self.run.dir / "cards" / "R-1.md").write_text("changed after the question\n")
        result = self.run.pilot_says("R-1")
        self.assertEqual(result["refused"], ["R-1"])
        self.assertEqual(self.run.types()[-1], "right-refused")

    def test_plan_v1_needs_pilot_approval(self):
        code, _, _ = self.run.plan(TWO)
        self.assertEqual(code, 3)
        self.assertEqual(self.run.types()[-1], "right-refused")
        self.run.approved_plan(TWO)
        self.assertEqual(self.run.types()[-1], "plan-revised")

    def test_one_yes_approves_one_action(self):
        self.run.approved_plan(TWO)
        three = {**TWO, "C": {"deps": [], "budget_min": 30}}
        code, _, err = self.run.plan(three, version=2, approval="R-plan")
        self.assertEqual(code, 3, err)
        self.assertIn("unused approved", err)

    def test_dependency_must_be_accepted_before_ready(self):
        self.run.approved_plan(TWO)
        code, _, err = self.run.move("B", "ready")
        self.assertEqual(code, 3)
        self.assertIn("not accepted", err)

    def test_accept_needs_passing_verdict(self):
        self.run.approved_plan(TWO)
        self.run.run_to_checking("A", verdict="fail")
        code, _, _ = self.run.move("A", "accepted")
        self.assertEqual(code, 3)
        self.assertEqual(self.run.move("A", "rejected")[0], 0)

    def test_accept_with_remarks_needs_pilot(self):
        self.run.approved_plan(TWO)
        self.run.run_to_checking("A", verdict="pass-with-remarks")
        self.assertEqual(self.run.move("A", "accepted")[0], 3)
        self.run.ask("R-5")
        self.run.pilot_says("R-5")
        self.assertEqual(self.run.move("A", "accepted", approval_request_id="R-5")[0], 0)

    def test_third_attempt_needs_pilot(self):
        self.run.approved_plan(TWO)
        for _ in range(2):
            self.run.run_to_checking("A", verdict="fail")
            self.assertEqual(self.run.move("A", "rejected")[0], 0)
        self.assertEqual(self.run.move("A", "ready", reason="new-attempt")[0], 0)
        code, _, err = self.run.append("phase-assigned", {"phase": "A", "executor": "opus", "inputs": []})
        self.assertEqual(code, 3, err)
        self.assertIn("attempt 3", err)

    def test_confirm_decision_needs_its_own_answer(self):
        self.run.approved_plan(TWO)
        decision = {"decision_id": "D-1", "phase": "A", "kind": "goal-risk", "rule": "P8",
                    "status": "decided", "question": "q", "choice": "x", "basis": "Strategy.md#p"}
        self.assertEqual(self.run.append("decision-recorded", decision)[0], 3)
        self.run.ask("R-other", decision_id="D-2")
        self.run.pilot_says("R-other")
        code, _, err = self.run.append("decision-recorded", {**decision, "request_id": "R-other"})
        self.assertEqual(code, 3)
        self.assertIn("not asked about", err)
        self.run.ask("R-8", decision_id="D-1")
        self.run.pilot_says("R-8")
        self.assertEqual(self.run.append("decision-recorded", {**decision, "request_id": "R-8"})[0], 0)
        recorded = self.run.events()[-1]["payload"]
        self.assertEqual((recorded["right"], recorded["risk"]), ("confirm", "high"))

    def test_risk_is_derived_not_taken_from_the_manager(self):
        self.run.approved_plan(TWO)
        self.run.append("decision-recorded", {"decision_id": "D-1", "kind": "rule", "rule": "P2",
                                              "status": "decided", "question": "q", "choice": "sonnet",
                                              "basis": "F5 C1", "risk": "high"})
        self.assertEqual(self.run.events()[-1]["payload"]["risk"], "normal")

    def test_raised_right_from_run_creation_applies(self):
        tmp = tempfile.TemporaryDirectory()
        run = Run(Path(tmp.name))
        rights = Path(tmp.name) / "raises.json"
        rights.write_text(json.dumps({"P2": "confirm"}))
        code, out, err = run.cli("create", "--wp", "1", "--description-ref", "r", "--host", "h",
                                 "--holder", "m", "--rights-json", str(rights))
        self.assertEqual(code, 0, err)
        run.epoch = json.loads(out)["epoch"]
        run.approved_plan(TWO)
        code, _, _ = run.append("decision-recorded", {"decision_id": "D", "kind": "rule", "rule": "P2",
                                                      "status": "decided", "question": "q", "choice": "c",
                                                      "basis": "b"})
        self.assertEqual(code, 3)
        tmp.cleanup()

    def test_unconfirmed_acceptance_blocks_children_until_confirmed(self):
        self.run.approved_plan(TWO)
        self.run.run_to_checking("A")
        self.assertEqual(self.run.move("A", "accepted-unconfirmed", unconfirmed="D-1")[0], 0)
        self.assertEqual(self.run.move("B", "ready")[0], 3)
        self.assertEqual(self.run.move("A", "accepted")[0], 3)

    def test_rollback_of_two_phases_needs_pilot_and_one_yes_covers_it(self):
        self.run.approved_plan(TWO)
        self.run.run_to_checking("A")
        self.assertEqual(self.run.move("A", "accepted")[0], 0)
        self.run.run_to_checking("B")
        self.assertEqual(self.run.move("B", "accepted")[0], 0)
        self.assertEqual(self.run.move("A", "ready", reason="rollback", rollback_of="D-1")[0], 0)
        self.assertEqual(self.run.move("B", "ready", reason="rollback", rollback_of="D-1")[0], 3)
        self.run.ask("R-10")
        self.run.pilot_says("R-10")
        self.assertEqual(self.run.move("B", "ready", reason="rollback", rollback_of="D-1",
                                       approval_request_id="R-10")[0], 0)

    def test_backward_move_needs_reason(self):
        self.run.approved_plan(TWO)
        self.run.run_to_checking("A")
        code, _, err = self.run.move("A", "ready", reason="because")
        self.assertEqual(code, 2)
        self.assertIn("backward", err)

    def test_letter_cycle_is_refused(self):
        self.run.approved_plan(TWO)
        self.assertEqual(self.run.append("letter-sent", {"to_wp": "WP-568", "chain": "c1", "phase": "A",
                                                         "deadline": "2026-12-05"})[0], 0)
        self.assertEqual(self.run.append("letter-received", {"from_wp": "WP-530", "chain": "c1"})[0], 0)
        code, _, err = self.run.append("letter-sent", {"to_wp": "WP-568", "chain": "c1", "phase": "A",
                                                       "deadline": "2026-12-06"})
        self.assertEqual(code, 3)
        self.assertIn("cycle", err)

    def test_stale_epoch_cannot_write_and_expired_lease_moves_epoch(self):
        self.run.approved_plan(TWO)
        self.run.clock = "2026-12-01T13:00:00Z"
        code, _, _ = self.run.append("cost-recorded", {"scope": "manager", "minutes": 5, "source": "unknown"})
        self.assertEqual(code, 2)
        code, out, _ = self.run.cli("lease", "--holder", "mgr-2")
        self.assertEqual(code, 0)
        new_epoch = json.loads(out)["epoch"]
        self.assertEqual(new_epoch, self.run.epoch + 1)
        self.assertEqual(self.run.append("cost-recorded", {"scope": "manager", "minutes": 5, "source": "unknown"},
                                         epoch=self.run.epoch)[0], 2)
        self.assertEqual(self.run.append("cost-recorded", {"scope": "manager", "minutes": 5, "source": "unknown"},
                                         epoch=new_epoch)[0], 0)

    def test_live_lease_of_another_holder_is_not_taken(self):
        code, _, err = self.run.cli("lease", "--holder", "mgr-2")
        self.assertEqual(code, 2)
        self.assertIn("held by mgr-1", err)

    def test_affected_returns_downstream_phases_and_decisions(self):
        self.run.approved_plan(TWO)
        self.run.run_to_checking("A")
        self.assertEqual(self.run.move("A", "accepted")[0], 0)
        self.run.append("decision-recorded", {"decision_id": "D-A", "phase": "A", "kind": "rule", "rule": "P3",
                                              "status": "decided", "question": "q", "choice": "c", "basis": "b"})
        self.run.run_to_checking("B")
        self.run.append("decision-recorded", {"decision_id": "D-B", "phase": "B", "kind": "rule", "rule": "P3",
                                              "status": "decided", "question": "q", "choice": "c", "basis": "b"})
        code, out, _ = self.run.cli("affected", "--decision", "D-A")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out), {"phases": ["A", "B"], "decisions": ["D-B"]})

    def test_state_reports_stop_after_three_rejections(self):
        three = {"A": {"deps": []}, "B": {"deps": []}, "C": {"deps": []}}
        self.run.approved_plan(three)
        for phase in three:
            self.run.run_to_checking(phase, verdict="fail")
            self.assertEqual(self.run.move(phase, "rejected")[0], 0)
        state = json.loads(self.run.cli("state")[1])
        self.assertTrue(state["stop_due"])


if __name__ == "__main__":
    unittest.main()
