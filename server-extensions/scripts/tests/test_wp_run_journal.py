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
        self.dir = root / "inbox" / "WP-999" / "runs" / "wp999-2026-12-01-1"
        self.state_dir = root / "state"
        self.clock = T0
        self.holder = "mgr-1"
        self.host = "tsekh-1"
        self.epoch = None

    def cli(self, *args):
        env = {**os.environ, "WP_RUN_JOURNAL_NOW": self.clock, "IWE_WP_MANAGER_STATE": str(self.state_dir),
               "CLAUDE_CODE_SESSION_ID": self.holder, "IWE_WP_MANAGER_HOST": self.host}
        res = subprocess.run([sys.executable, TOOL, args[0], "--run-dir", str(self.dir), *args[1:]],
                             capture_output=True, text=True, env=env)
        return res.returncode, res.stdout, res.stderr

    def events(self):
        path = self.dir / "events.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def types(self):
        return [e["type"] for e in self.events()]

    def create(self, *extra):
        code, out, err = self.cli("create", "--wp", "999", "--description-ref", "abc:inbox/WP-999/WP-999.md", *extra)
        assert code == 0, err
        self.epoch = json.loads(out)["epoch"]

    def append(self, etype, payload, epoch=None):
        return self.cli("append", "--epoch", str(epoch or self.epoch), "--type", etype,
                        "--payload", json.dumps(payload, ensure_ascii=False))

    def ask(self, rid, decision_id=None, action=None):
        (self.dir / "cards").mkdir(parents=True, exist_ok=True)
        (self.dir / "cards" / f"{rid}.md").write_text(f"card {rid}\n")
        payload = {"request_id": rid, "subject": "s", "right": "confirm",
                   "action": action or {"type": "decision-recorded"}}
        if decision_id:
            payload["decision_id"] = decision_id
        code, _, err = self.append("pilot-requested", payload)
        assert code == 0, err

    def pilot_says(self, rid, answer="yes"):
        """What the answer-box hook writes; the agent never writes this file."""
        box = self.dir / "protected" / "pilot-answers.jsonl"
        with open(box, "a") as fh:
            fh.write(json.dumps({"request_id": rid, "answer": answer, "text": f"{rid}: {answer}",
                                 "transcript_ref": "msg-1", "ts": self.clock}) + "\n")
        code, out, err = self.cli("ingest-answers", "--epoch", str(self.epoch))
        assert code == 0, err
        return json.loads(out)

    def plan(self, phases, version=1, approval=None):
        payload = {"version": version, "graph": {"phases": phases}, "reason": "r"}
        if approval:
            payload["approval_request_id"] = approval
        return self.append("plan-revised", payload)

    def approved_plan(self, phases):
        self.ask("R-plan", action={"type": "plan-revised", "version": 1})
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
        for _ in range(2):
            self.run.run_to_checking("A", verdict="fail")
            self.assertEqual(self.run.move("A", "rejected")[0], 0)
        self.run.ask("R-6", action={"type": "phase-assigned", "phase": "A"})
        self.run.pilot_says("R-6")
        self.assertEqual(self.run.move("A", "ready", reason="new-attempt")[0], 0)
        assign = {"phase": "A", "executor": "opus", "inputs": [], "approval_request_id": "R-6"}
        self.assertEqual(self.run.append("phase-assigned", assign)[0], 0)
        self.run.append("artifact-submitted", {"phase": "A", "attempt": 3, "submission_ref": "s",
                                               "submission_sha": "x"})
        self.run.move("A", "checking")
        self.run.append("verification-recorded", {"phase": "A", "attempt": 3, "verifier": "codex", "verdict": "fail"})
        self.assertEqual(self.run.move("A", "rejected")[0], 0)
        self.assertEqual(self.run.move("A", "ready", reason="new-attempt")[0], 0)
        code, _, err = self.run.append("phase-assigned", assign)
        self.assertEqual(code, 3)
        self.assertIn("unused", err)

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
        self.run.ask("R-5", action={"type": "phase-transitioned", "phase": "A", "to": "accepted"})
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
        run.create("--rights-json", str(rights))
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
        self.run.ask("R-10", action={"type": "phase-transitioned", "phase": "B", "to": "ready", "rollback_of": "D-1"})
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
        self.run.holder = "mgr-2"
        code, out, _ = self.run.cli("lease")
        self.assertEqual(code, 0)
        new_epoch = json.loads(out)["epoch"]
        self.assertEqual(new_epoch, self.run.epoch + 1)
        self.assertEqual(self.run.append("cost-recorded", {"scope": "manager", "minutes": 5, "source": "unknown"},
                                         epoch=self.run.epoch)[0], 2)
        self.assertEqual(self.run.append("cost-recorded", {"scope": "manager", "minutes": 5, "source": "unknown"},
                                         epoch=new_epoch)[0], 0)

    def test_live_lease_of_another_holder_is_not_taken(self):
        self.run.holder = "mgr-2"
        code, _, err = self.run.cli("lease")
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

    def test_session_mark_lifecycle(self):
        mark = self.run.state_dir / "sessions" / "mgr-1.json"
        self.assertEqual(json.loads(mark.read_text())["run_dir"], str(self.run.dir.resolve()))
        one = {"A": {"deps": []}}
        tmp = tempfile.TemporaryDirectory()
        done = Run(Path(tmp.name))
        done.holder = "mgr-done"
        done.create()
        done.approved_plan(one)
        done.run_to_checking("A")
        self.assertEqual(done.move("A", "accepted")[0], 0)
        self.assertEqual(done.append("run-completed", {"report_ref": "r.md"})[0], 0)
        self.assertFalse((done.state_dir / "sessions" / "mgr-done.json").exists())
        tmp.cleanup()
        self.run.approved_plan(TWO)
        self.assertEqual(self.run.append("run-stopped", {"reason": "test"})[0], 0)
        self.assertTrue(mark.exists(), "a stopped run keeps the session under the Manager rules")

    def test_decision_class_phase_is_never_accepted_straight_from_checking(self):
        self.run.approved_plan({"C": {"deps": [], "class": "Ц"}})
        self.run.run_to_checking("C")
        self.assertEqual(self.run.move("C", "accepted", reason="P4")[0], 3)
        self.assertEqual(self.run.move("C", "accepted-unconfirmed", reason="P4", unconfirmed="D")[0], 3)

    def test_class_change_needs_pilot(self):
        self.run.approved_plan({"C": {"deps": [], "class": "Ц"}})
        self.assertEqual(self.run.plan({"C": {"deps": [], "class": "И"}}, version=2)[0], 3)

    def test_transition_approval_names_phase_and_target(self):
        self.run.approved_plan(TWO)
        (self.run.dir / "cards" / "R-x.md").write_text("x\n")
        loose = {"request_id": "R-x", "subject": "s", "right": "confirm", "action": {"type": "phase-transitioned"}}
        self.assertEqual(self.run.append("pilot-requested", loose)[0], 2)
        self.run.ask("R-acc", action={"type": "phase-transitioned", "phase": "A", "to": "accepted"})
        self.run.pilot_says("R-acc")
        code, _, _ = self.run.move("A", "cancelled", reason="drop", approval_request_id="R-acc")
        self.assertEqual(code, 3)

    def test_proposed_decision_does_not_spend_its_request(self):
        self.run.approved_plan(TWO)
        base = {"decision_id": "D-15", "kind": "goal-risk", "rule": "P15", "question": "q", "choice": "c",
                "basis": "WP card", "request_id": "R-15"}
        self.run.ask("R-15", decision_id="D-15")
        self.assertEqual(self.run.append("decision-recorded", {**base, "status": "proposed"})[0], 0)
        self.run.pilot_says("R-15")
        self.assertEqual(self.run.append("decision-recorded", {**base, "status": "confirmed"})[0], 0)

    def test_one_yes_rolls_back_three_phases_of_one_decision(self):
        chain = {"A": {"deps": []}, "B": {"deps": ["A"]}, "C": {"deps": ["B"]}}
        self.run.approved_plan(chain)
        for phase in chain:
            self.run.run_to_checking(phase)
            self.assertEqual(self.run.move(phase, "accepted")[0], 0)
        self.assertEqual(self.run.move("A", "ready", reason="rollback", rollback_of="D-1")[0], 0)
        self.run.ask("R-rb", action={"type": "phase-transitioned", "to": "ready", "rollback_of": "D-1"})
        self.run.pilot_says("R-rb")
        for phase in ("B", "C"):
            self.assertEqual(self.run.move(phase, "ready", reason="rollback", rollback_of="D-1",
                                           approval_request_id="R-rb")[0], 0, phase)
        self.run.ask("R-other", action={"type": "phase-transitioned", "to": "ready", "rollback_of": "D-2"})
        self.run.pilot_says("R-other")
        self.assertEqual(self.run.move("A", "rejected", reason="x", approval_request_id="R-other")[0], 2)

    def test_event_that_would_break_the_projection_is_not_written(self):
        self.run.approved_plan(TWO)
        before = len(self.run.events())
        for etype, payload in (("letter-received", {"from_wp": "WP-530", "chain": ["626", "530"]}),
                               ("cost-recorded", {"scope": ["x"], "minutes": 1, "source": "reported"})):
            code, _, err = self.run.append(etype, payload)
            self.assertEqual(code, 2, etype)
            self.assertRegex(err, "unreadable|non-empty strings")
        decision = {"decision_id": 5, "kind": "rule", "rule": "P2", "status": "decided", "question": "q",
                    "choice": "c", "basis": "b"}
        code, _, err = self.run.append("decision-recorded", decision)
        self.assertEqual(code, 2)
        self.assertIn("non-empty strings", err)
        self.assertEqual(len(self.run.events()), before)
        self.assertEqual(self.run.cli("state")[0], 0)
        self.assertEqual(self.run.cli("sample")[0], 0)

    def test_dry_apply_rejects_an_event_that_breaks_the_projection(self):
        """Second line of defence behind the field checks: applied directly, without them."""
        import importlib.util
        spec = importlib.util.spec_from_file_location("journal", TOOL)
        journal = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(journal)
        with self.assertRaises(journal.Invalid):
            journal.dry_apply([], "letter-received", {"from_wp": "WP-1", "chain": ["a", "b"]})
        journal.dry_apply([], "letter-received", {"from_wp": "WP-1", "chain": "c1"})

    def test_append_runs_dry_apply_even_without_field_checks(self):
        """append must call dry_apply itself: switch the first line of defence off and the event is still refused."""
        import contextlib
        import importlib.util
        import io
        self.run.approved_plan(TWO)
        before = len(self.run.events())
        spec = importlib.util.spec_from_file_location("journal_inproc", TOOL)
        journal = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(journal)
        journal.ID_FIELDS = ()
        env = {"WP_RUN_JOURNAL_NOW": self.run.clock, "IWE_WP_MANAGER_STATE": str(self.run.state_dir),
               "CLAUDE_CODE_SESSION_ID": self.run.holder, "IWE_WP_MANAGER_HOST": self.run.host}
        saved = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                code = journal.main(["append", "--run-dir", str(self.run.dir), "--epoch", str(self.run.epoch),
                                     "--type", "letter-received",
                                     "--payload", json.dumps({"from_wp": "WP-1", "chain": ["a", "b"]})])
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
        self.assertEqual(code, 2)
        self.assertEqual(len(self.run.events()), before)

    def test_malformed_payload_is_a_usage_error(self):
        self.run.approved_plan(TWO)
        code, _, err = self.run.append("cost-recorded", {"scope": "phase", "minutes": None, "source": "x"})
        self.assertEqual(code, 2)
        self.assertNotIn("Traceback", err)

    def test_pilot_messages_become_interventions_once(self):
        self.run.approved_plan(TWO)
        box = self.run.dir / "protected" / "pilot-messages.jsonl"
        box.write_text(json.dumps({"text_ref": "s:1"}) + "\n" + json.dumps({"text_ref": "s:2"}) + "\n")
        for _ in range(2):
            self.assertEqual(self.run.cli("ingest-answers", "--epoch", str(self.run.epoch))[0], 0)
        self.assertEqual(self.run.types().count("pilot-intervention"), 2)
        code, _, _ = self.run.append("pilot-intervention", {"text_ref": "forged"})
        self.assertEqual(code, 2)

    def test_decision_phase_is_accepted_only_after_the_decision(self):
        self.run.approved_plan({"C": {"deps": [], "class": "Ц"}})
        self.run.run_to_checking("C")
        self.assertEqual(self.run.move("C", "awaiting-decision", reason="card")[0], 0)
        self.assertEqual(self.run.move("C", "accepted", reason="decided")[0], 3)
        self.run.ask("R-c", decision_id="D-c")
        self.run.pilot_says("R-c", "choice:2")
        self.assertEqual(self.run.append("decision-recorded", {
            "decision_id": "D-c", "phase": "C", "kind": "goal-risk", "rule": "P8", "status": "confirmed",
            "request_id": "R-c", "question": "q", "choice": "2", "basis": "Strategy.md"})[0], 0)
        self.assertEqual(self.run.move("C", "accepted", reason="decided")[0], 0)

    def test_run_completes_only_with_all_phases_accepted(self):
        self.run.approved_plan(TWO)
        code, _, err = self.run.append("run-completed", {"report_ref": "r.md"})
        self.assertEqual(code, 2)
        self.assertIn("run-stopped", err)
        self.assertNotIn("run-completed", self.run.types())

    # --- findings of the Fable review 25.11 (each reproduced a bypass before the fix)

    def test_manual_assignment_and_submission_are_not_transitions(self):
        self.run.approved_plan(TWO)
        self.assertEqual(self.run.move("A", "ready")[0], 0)
        code, _, err = self.run.move("A", "assigned")
        self.assertEqual(code, 2)
        self.assertIn("not allowed", err)

    def test_only_checked_decision_phase_awaits_a_decision(self):
        self.run.approved_plan({"I": {"deps": []}, "C": {"deps": [], "class": "Ц"}})
        self.assertEqual(self.run.move("C", "ready")[0], 0)
        self.assertEqual(self.run.move("C", "awaiting-decision", reason="card")[0], 2)
        self.run.run_to_checking("I")
        self.assertEqual(self.run.move("I", "awaiting-decision", reason="card")[0], 3)

    def test_yes_to_another_action_does_not_approve(self):
        self.run.approved_plan(TWO)
        self.run.ask("R-chat", action={"type": "pilot-chat"})
        self.run.pilot_says("R-chat")
        code, _, _ = self.run.move("B", "cancelled", reason="drop", approval_request_id="R-chat")
        self.assertEqual(code, 3)
        self.assertEqual(self.run.events()[-1]["type"], "right-refused")

    def test_option_choice_is_not_an_approval_of_an_action(self):
        self.run.approved_plan(TWO)
        self.run.ask("R-v2", action={"type": "plan-revised", "version": 2})
        self.run.pilot_says("R-v2", "choice:2")
        three = {**TWO, "C": {"deps": []}}
        self.assertEqual(self.run.plan(three, version=2, approval="R-v2")[0], 3)

    def test_answer_typed_before_the_question_is_not_used(self):
        self.run.approved_plan(TWO)
        box = self.run.dir / "protected" / "pilot-answers.jsonl"
        with open(box, "a") as fh:
            fh.write(json.dumps({"request_id": "R-7", "answer": "yes", "text": "R-7: да",
                                 "transcript_ref": "m", "ts": "2026-12-01T09:00:00Z"}) + "\n")
        self.run.ask("R-7")
        out = json.loads(self.run.cli("ingest-answers", "--epoch", str(self.run.epoch))[1])
        self.assertEqual((out["ingested"], out["unmatched"]), ([], ["R-7"]))

    def test_request_id_cannot_be_reused(self):
        self.run.ask("R-1")
        payload = {"request_id": "R-1", "subject": "s", "right": "confirm", "action": {"type": "x"}}
        self.assertEqual(self.run.append("pilot-requested", payload)[0], 2)

    def test_holder_must_be_a_plain_session_id(self):
        tmp = tempfile.TemporaryDirectory()
        run = Run(Path(tmp.name))
        run.holder = "../../escape"
        code, _, err = run.cli("create", "--wp", "1", "--description-ref", "r")
        self.assertEqual(code, 2)
        self.assertFalse((Path(tmp.name) / "escape.json").exists())
        code, _, err = self.run.cli("lease", "--holder", "someone-else")
        self.assertEqual(code, 2)
        self.assertIn("CLAUDE_CODE_SESSION_ID", err)
        tmp.cleanup()

    def test_dependency_change_needs_pilot(self):
        self.run.approved_plan(TWO)
        loose = {"A": {"deps": [], "budget_min": 60}, "B": {"deps": [], "budget_min": 60}}
        code, _, err = self.run.plan(loose, version=2)
        self.assertEqual(code, 3)
        self.assertIn("dependencies", err)

    def test_cost_and_verification_sanity(self):
        self.run.approved_plan(TWO)
        self.assertEqual(self.run.append("cost-recorded", {"scope": "phase", "phase": "A", "minutes": -100,
                                                           "source": "reported"})[0], 2)
        self.assertEqual(self.run.move("A", "ready")[0], 0)
        self.assertEqual(self.run.append("phase-assigned", {"phase": "A", "executor": "sonnet", "inputs": []})[0], 0)
        self.assertEqual(self.run.append("verification-recorded", {"phase": "A", "attempt": 1, "verifier": "codex",
                                                                   "verdict": "pass"})[0], 2)
        self.run.append("artifact-submitted", {"phase": "A", "attempt": 1, "submission_ref": "s",
                                               "submission_sha": "x"})
        self.run.move("A", "checking")
        self.assertEqual(self.run.append("verification-recorded", {"phase": "A", "attempt": 1, "verifier": "sonnet",
                                                                   "verdict": "pass"})[0], 3)

    def test_run_folder_place_host_and_torn_line(self):
        code, _, err = self.run.cli("state", "--run-dir", "/tmp/anywhere")  # argparse: last --run-dir wins
        self.assertEqual(code, 2)
        self.run.host = "mac"
        self.assertEqual(self.run.cli("lease")[0], 2)
        self.run.host = "tsekh-1"
        with open(self.run.dir / "events.jsonl", "a") as fh:
            fh.write('{"seq": 3, "torn')
        self.assertEqual(self.run.cli("verify")[0], 4)

    def test_sample_hides_seed_until_run_closes(self):
        self.run.approved_plan(TWO)
        for n in range(10):
            self.run.append("decision-recorded", {"decision_id": f"D{n}", "kind": "rule", "rule": "P3",
                                                  "status": "decided", "question": "q", "choice": "c", "basis": "b"})
        out = json.loads(self.run.cli("sample")[1])
        self.assertIsNone(out["seed"])
        self.assertTrue(set(out["review"]) <= {f"D{n}" for n in range(10)})
        self.run.append("run-stopped", {"reason": "test"})
        closed = json.loads(self.run.cli("sample")[1])
        self.assertEqual(closed["review"], out["review"])
        self.assertEqual(len(closed["seed"]), 32)

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
