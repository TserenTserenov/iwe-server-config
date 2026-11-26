#!/usr/bin/env python3
"""wp-run-journal.py -- event journal of a WP Manager run (WP-626 F7, contract F4 + revision 2).

The journal is the single source of truth of a run: one JSON event per line in
<run-dir>/events.jsonl, append-only, hash-chained, written only by this program
under a per-run lock and a lease with an epoch. The Manager (an AI agent) never
writes the file itself; it asks this program to append, and the program refuses
anything the rights table does not allow, recording the refusal as an event.

Design sources (DS-my-strategy, inbox/WP-626/):
  F4/state-contract-v0-draft.md    event types, phase statuses, recovery
  F6/revision-2-fixes.md           rights by substance, lease, hash chain,
                                   pilot answers only from the answer box
  F2/role-and-rights-draft.md      rights table P1-P19

Usage:
  wp-run-journal.py create  --run-dir D --wp N --description-ref REF
                            [--preset lead|ask] [--rights-json FILE] [--budget-json JSON]
  wp-run-journal.py lease   --run-dir D [--ttl-min 120]
  wp-run-journal.py append  --run-dir D --epoch E --type T --payload JSON [--actor A] [--caused-by N]
  wp-run-journal.py ingest-answers --run-dir D --epoch E
  wp-run-journal.py state   --run-dir D
  wp-run-journal.py verify  --run-dir D
  wp-run-journal.py affected --run-dir D --decision ID
  wp-run-journal.py views   --run-dir D
  wp-run-journal.py sample  --run-dir D      decisions picked for the pilot's spot check

Run folder: must be <repo>/inbox/WP-<N>/runs/<run_id> (F4 section 1).
Holder: the Claude Code session id from CLAUDE_CODE_SESSION_ID (a --holder flag
is accepted only when that variable is absent, e.g. in tests, and must match it
when present). Host: the run is bound to the host that created it
(IWE_WP_MANAGER_HOST overrides the host name).

Exit codes: 0 ok; 2 usage, schema or lease error (nothing written);
3 refused by the rights rules (a right-refused event is written);
4 journal integrity broken (hash chain or sequence).

Test clock: WP_RUN_JOURNAL_NOW (ISO-8601 UTC) overrides the current time.
Session marks: taking a lease writes $IWE_WP_MANAGER_STATE/sessions/<holder>.json
(default ~/.iwe-runtime/wp-manager); only run-completed removes it (a stopped run keeps
the session under the Manager rules).
The hooks wp-manager-answer-box.py and wp-manager-guard.py read these marks.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import socket
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

EVENTS = "events.jsonl"
LEASE = "lease.json"
LOCK = ".lock"
ANSWER_BOX = "protected/pilot-answers.jsonl"
PILOT_MESSAGES = "protected/pilot-messages.jsonl"
CARDS = "cards"


RUN_DIR_RE = re.compile(r"/inbox/WP-\d+/runs/[A-Za-z0-9][A-Za-z0-9._-]*$")
HOLDER_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
# What an approval request must pin down, per approved event type (Fable review round 2).
ACTION_KEYS = {"phase-transitioned": ("phase", "to"), "phase-assigned": ("phase",), "plan-revised": ("version",)}


def session_marker_dir() -> Path:
    """Where the program marks sessions that run a Manager (read by the hooks)."""
    return Path(os.environ.get("IWE_WP_MANAGER_STATE")
                or Path.home() / ".iwe-runtime" / "wp-manager") / "sessions"

RIGHT_ORDER = {"auto": 0, "confirm": 1, "pilot-only": 2}
# Default rights table, F2 section 2 (accepted by the pilot 25.11.2026).
DEFAULT_RIGHTS = {
    "P1": "auto", "P2": "auto", "P3": "auto", "P4": "auto", "P5": "confirm",
    "P6": "auto", "P7": "auto", "P8": "confirm", "P9": "auto", "P10": "confirm",
    "P11": "confirm", "P12": "auto", "P13": "confirm", "P14": "pilot-only",
    "P15": "pilot-only", "P16": "pilot-only", "P17": "pilot-only",
    "P18": "pilot-only", "P19": "auto",
}
# Revision 2 section 2: risk is derived from the rule, never set by the Manager.
HIGH_RISK_RULES = {"P8", "P11", "P13", "P14", "P15", "P16", "P17", "P18"}

REQUIRED = {
    "run-created": ["wp", "description_ref", "host"],
    "lease-taken": ["holder", "epoch"],
    "plan-revised": ["version", "graph", "reason"],
    "phase-assigned": ["phase", "executor", "inputs", "contract_version", "ceiling"],
    "artifact-submitted": ["phase", "attempt", "submission_ref", "submission_sha", "contract_version"],
    "verification-recorded": ["phase", "attempt", "verifier", "verdict"],
    "decision-recorded": ["decision_id", "kind", "rule", "status", "question", "choice", "basis"],
    "assumption-changed": ["assumption_id", "from", "to", "evidence"],
    "phase-transitioned": ["phase", "to", "reason"],
    "pilot-requested": ["request_id", "subject", "right", "action"],
    "pilot-answered": ["request_id", "answer", "text"],
    "cost-recorded": ["scope", "minutes", "source"],
    "run-stopped": ["reason"],
    "run-completed": ["report_ref"],
    "right-refused": ["attempted_type", "why"],
    "letter-sent": ["to_wp", "chain", "phase", "deadline"],
    "letter-received": ["from_wp", "chain"],
    "pilot-intervention": ["text_ref"],
}
# Types the Manager may ask to append. pilot-answered and pilot-intervention come
# only from the hook-filled boxes (ingest-answers); run-created and lease-taken
# only from their commands; right-refused only from the program itself.
MANAGER_TYPES = set(REQUIRED) - {"run-created", "lease-taken", "pilot-answered", "right-refused",
                                  "pilot-intervention"}

# Allowed phase transitions (F4 section 4 + revision 2 section 3).
# ready -> assigned and assigned/unknown -> submitted happen only through the
# phase-assigned and artifact-submitted events, never as manual transitions:
# otherwise attempt counting (P6) and budget ceilings (P13) are bypassed.
TRANSITIONS = {
    ("waiting", "ready"), ("assigned", "unknown"), ("unknown", "ready"),
    ("submitted", "checking"), ("checking", "accepted"), ("checking", "rejected"),
    ("checking", "accepted-unconfirmed"), ("accepted", "accepted-unconfirmed"), ("rejected", "ready"),
    ("ready", "blocked"), ("assigned", "blocked"), ("checking", "blocked"),
    ("blocked", "ready"), ("accepted", "ready"), ("assigned", "ready"),
    ("submitted", "ready"), ("checking", "ready"),
    ("checking", "awaiting-decision"), ("awaiting-decision", "accepted"),
    ("accepted-unconfirmed", "accepted"), ("accepted-unconfirmed", "ready"),
}
BACKWARD_REASONS = {"rollback", "ceiling", "stuck", "new-attempt", "recovery"}
STOP_REJECTS_IN_A_ROW = 3


class Refused(Exception):
    """The rights rules refuse the event; it is recorded as right-refused."""


class Invalid(Exception):
    """Usage, schema or lease error; nothing is written."""


class Broken(Exception):
    """The journal fails its integrity check."""


def now() -> datetime:
    forced = os.environ.get("WP_RUN_JOURNAL_NOW")
    if forced:
        return datetime.fromisoformat(forced.replace("Z", "+00:00"))
    return datetime.now(timezone.utc)


def iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


@contextmanager
def run_lock(run_dir: Path):
    run_dir.mkdir(parents=True, exist_ok=True)
    with open(run_dir / LOCK, "a+") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)
    dir_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)


def read_lines(run_dir: Path) -> list[str]:
    path = run_dir / EVENTS
    if not path.exists():
        return []
    return [line for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def load_events(run_dir: Path) -> list[dict]:
    """Read and verify the chain; raise Broken on any gap or edit."""
    events, prev = [], ""
    for number, line in enumerate(read_lines(run_dir), start=1):
        try:
            event = json.loads(line)
        except json.JSONDecodeError as error:
            raise Broken(f"line {number} is not JSON ({error})") from error
        if event.get("seq") != number:
            raise Broken(f"seq {event.get('seq')} at line {number}")
        if event.get("prev_hash") != prev:
            raise Broken(f"prev_hash mismatch at seq {number}")
        prev = sha256_text(line)
        events.append(event)
    return events


def write_event(run_dir: Path, events: list[dict], etype: str, payload: dict,
                actor: str, epoch: int, caused_by: int | None) -> dict:
    lines = read_lines(run_dir)
    event = {
        "seq": len(events) + 1,
        "ts": iso(now()),
        "run_id": run_dir.name,
        "epoch": epoch,
        "type": etype,
        "actor": actor,
        "caused_by": caused_by,
        "prev_hash": sha256_text(lines[-1]) if lines else "",
        "payload": payload,
    }
    line = json.dumps(event, ensure_ascii=False, sort_keys=True)
    with open(run_dir / EVENTS, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    events.append(event)
    return event


# ---------------------------------------------------------------- state

class State:
    """Projection of the journal; nothing here is stored separately."""

    def __init__(self, events: list[dict]):
        self.events = events
        self.rights = dict(DEFAULT_RIGHTS)
        self.plans: list[dict] = []
        self.status: dict[str, str] = {}
        self.attempts: dict[str, int] = {}
        self.verdicts: dict[tuple[str, int], str] = {}
        self.executors: dict[tuple[str, int], str] = {}
        # (phase, attempt) -> contract version named at assignment; absent in journals
        # written before the field became mandatory.
        self.contract_versions: dict[tuple[str, int], str] = {}
        self.requests: dict[str, dict] = {}
        self.answers: dict[str, dict] = {}
        self.decisions: dict[str, dict] = {}
        self.cost: dict[str, float] = {}
        self.rollbacks: dict[str, set] = {}
        self.chains: dict[str, list] = {}
        self.unconfirmed: dict[str, str] = {}
        # approval request id -> what used it; one pilot "yes" approves one action
        # (a multi-phase rollback of the same decision may reuse it).
        self.consumed: dict[str, str] = {}
        self.rejects_in_a_row = 0
        self.closed = False
        for event in events:
            self.apply(event)

    @property
    def plan(self) -> dict:
        return self.plans[-1]["graph"] if self.plans else {"phases": {}}

    def right_of(self, rule: str) -> str:
        if rule not in self.rights:
            raise Invalid(f"unknown rule {rule}")
        return self.rights[rule]

    def unused(self, request_id: str, reuse_key: str | None) -> bool:
        used_by = self.consumed.get(request_id)
        return used_by is None or (reuse_key is not None and used_by == reuse_key)

    def decision_answered(self, request_id: str) -> bool:
        """A decision request is settled by "yes" or a chosen option."""
        answer = self.answers.get(request_id)
        return bool(answer) and str(answer["answer"]).lower().startswith(("yes", "choice:")) \
            and self.unused(request_id, None)

    def action_approved(self, request_id: str, etype: str, payload: dict, reuse_key: str | None) -> bool:
        """An action request is settled only by a plain "yes" to that very action."""
        answer = self.answers.get(request_id)
        action = self.requests.get(request_id, {}).get("action") or {}
        if not answer or str(answer["answer"]).lower() != "yes" or action.get("type") != etype:
            return False
        for key in ("phase", "version", "rollback_of", "to"):
            if key in action and action[key] != payload.get(key):
                return False
        return self.unused(request_id, reuse_key)

    def apply(self, event: dict) -> None:
        etype, p = event["type"], event["payload"]
        settles = not (etype == "decision-recorded" and p.get("status") == "proposed")
        for field in ("approval_request_id", "request_id"):
            rid = p.get(field)
            if rid and settles and etype not in ("pilot-requested", "pilot-answered", "right-refused"):
                self.consumed.setdefault(rid, p.get("rollback_of") or f"seq{event['seq']}")
        if etype == "run-created":
            for rule, right in (p.get("raises") or {}).items():
                if RIGHT_ORDER[right] > RIGHT_ORDER[self.rights[rule]]:
                    self.rights[rule] = right
        elif etype == "plan-revised":
            self.plans.append(p)
            for phase in p["graph"]["phases"]:
                self.status.setdefault(phase, "waiting")
            for phase in set(self.status) - set(p["graph"]["phases"]):
                self.status[phase] = "cancelled"
        elif etype == "phase-assigned":
            self.attempts[p["phase"]] = p["attempt"]
            self.executors[(p["phase"], p["attempt"])] = str(p["executor"])
            if "contract_version" in p:
                self.contract_versions[(p["phase"], p["attempt"])] = str(p["contract_version"])
            self.status[p["phase"]] = "assigned"
        elif etype == "artifact-submitted":
            self.status[p["phase"]] = "submitted"
        elif etype == "verification-recorded" and p.get("scope") != "run":
            self.verdicts[(p["phase"], p["attempt"])] = p["verdict"]
        elif etype == "phase-transitioned":
            self.status[p["phase"]] = p["to"]
            if p["to"] == "accepted-unconfirmed":
                self.unconfirmed[p["phase"]] = p["unconfirmed"]
            if p["to"] == "rejected":
                self.rejects_in_a_row += 1
            elif p["to"] in ("accepted", "accepted-unconfirmed"):
                self.rejects_in_a_row = 0
            if p.get("rollback_of"):
                self.rollbacks.setdefault(p["rollback_of"], set()).add(p["phase"])
        elif etype == "pilot-requested":
            self.requests[p["request_id"]] = {**p, "asked_at": event["ts"]}
        elif etype == "pilot-answered":
            self.answers[p["request_id"]] = p
        elif etype == "decision-recorded":
            self.decisions[p["decision_id"]] = {**p, "seq": event["seq"]}
        elif etype == "cost-recorded":
            key = p.get("phase") or p["scope"]
            self.cost[key] = self.cost.get(key, 0) + float(p["minutes"])
        elif etype in ("letter-sent", "letter-received"):
            self.chains.setdefault(p["chain"], []).append(p.get("to_wp") or p.get("from_wp"))
        elif etype in ("run-stopped", "run-completed"):
            self.closed = True

    def deps(self, phase: str) -> list[str]:
        return list(self.plan["phases"].get(phase, {}).get("deps", []))

    def downstream(self, phase: str) -> set[str]:
        """Phases that depend on `phase`, transitively (revision 2 section 5)."""
        found, frontier = set(), {phase}
        while frontier:
            nxt = {name for name, spec in self.plan["phases"].items()
                   if set(spec.get("deps", [])) & frontier} - found
            found |= nxt
            frontier = nxt
        return found

    def summary(self) -> dict:
        return {
            "seq": len(self.events),
            "plan_version": self.plans[-1]["version"] if self.plans else None,
            "phases": self.status,
            "attempts": self.attempts,
            "open_requests": sorted(set(self.requests) - set(self.answers)),
            "cost_minutes": self.cost,
            "rejects_in_a_row": self.rejects_in_a_row,
            "stop_due": self.rejects_in_a_row >= STOP_REJECTS_IN_A_ROW,
            "all_blocked": bool(self.status) and all(
                s in ("blocked", "accepted", "cancelled", "awaiting-decision")
                for s in self.status.values()) and "blocked" in self.status.values(),
            "closed": self.closed,
        }


# ---------------------------------------------------------------- rules

# Fields that name things (and become dict keys or hashed text) must be non-empty strings.
ID_FIELDS = ("decision_id", "request_id", "approval_request_id", "phase", "assumption_id", "chain", "rule",
             "from_wp", "to_wp", "rollback_of", "unconfirmed", "scope", "kind", "status", "to")


def require_fields(etype: str, payload: dict) -> None:
    missing = [name for name in REQUIRED[etype] if name not in payload]
    if missing:
        raise Invalid(f"{etype}: missing {', '.join(missing)}")
    bad = [name for name in ID_FIELDS if name in payload and not (isinstance(payload[name], str) and payload[name])]
    if bad:
        raise Invalid(f"{etype}: {', '.join(bad)} must be non-empty strings")


def need_approval(state: State, etype: str, payload: dict, what: str, reuse_key: str | None = None) -> None:
    rid = payload.get("approval_request_id") or ""
    if not state.action_approved(rid, etype, payload, reuse_key):
        raise Refused(f"{what} needs an unused pilot 'yes' to a request about this very {etype} "
                      "(approval_request_id; the request's action names type and phase/version)")


def check_plan(state: State, p: dict) -> None:
    graph = p["graph"]
    phases = graph.get("phases") if isinstance(graph, dict) else None
    if not isinstance(phases, dict) or not phases:
        raise Invalid("plan-revised: graph.phases must be a non-empty object")
    for name, spec in phases.items():
        if not isinstance(spec, dict) or not isinstance(spec.get("deps", []), list):
            raise Invalid(f"plan-revised: phase {name} must be an object with a deps list")
        unknown = set(spec.get("deps", [])) - set(phases)
        if unknown:
            raise Invalid(f"plan-revised: {name} depends on unknown {sorted(unknown)}")
    if not state.plans:
        need_approval(state, "plan-revised", p, "plan v1 (M1)")
        return
    base, previous = state.plans[0]["graph"]["phases"], state.plan["phases"]
    if set(phases) != set(previous):
        need_approval(state, "plan-revised", p, "change of phase composition (P11)")
        return
    if any(sorted(spec.get("deps", [])) != sorted(previous[name].get("deps", []))
           or spec.get("class") != previous[name].get("class") for name, spec in phases.items()):
        need_approval(state, "plan-revised", p, "change of phase dependencies or class (P11)")
        return
    for name, spec in phases.items():
        limit = base.get(name, {}).get("budget_min")
        if limit and spec.get("budget_min", 0) > limit:
            need_approval(state, "plan-revised", p, f"budget of {name} above plan v1 (P13)")
            return


# A ceiling as written in phase contracts: "5h", "90min", "3" (hours) or a number.
CEILING_TEXT = re.compile(r"(\d+(?:\.\d+)?)\s*(h|min)?")


def positive_ceiling(ceiling) -> bool:
    if isinstance(ceiling, bool):
        return False
    if isinstance(ceiling, (int, float)):
        return 0 < ceiling < float("inf")  # NaN fails both comparisons
    match = CEILING_TEXT.fullmatch(ceiling.strip()) if isinstance(ceiling, str) else None
    return bool(match) and float(match.group(1)) > 0


def assignment_gaps(p: dict) -> list[str]:
    """Present-but-empty fields of phase-assigned: an executor must not guess them."""
    gaps = []
    version = p["contract_version"]
    if not (isinstance(version, str) and version and version == version.strip()):
        gaps.append("contract_version (non-empty string without surrounding spaces)")
    if not positive_ceiling(p["ceiling"]):
        gaps.append("ceiling (positive number, or text like 5h / 90min)")
    inputs = p["inputs"]
    if not (isinstance(inputs, list) and inputs and all(inputs)):
        gaps.append("inputs (non-empty list of non-empty entries)")
    return gaps


def check_assignment(state: State, p: dict) -> None:
    phase = p["phase"]
    gaps = assignment_gaps(p)
    if gaps:
        raise Invalid(f"phase-assigned: needs clarification, empty: {'; '.join(gaps)}")
    if state.status.get(phase) != "ready":
        raise Invalid(f"phase-assigned: {phase} is {state.status.get(phase)}, not ready")
    attempt = state.attempts.get(phase, 0) + 1
    if p.setdefault("attempt", attempt) != attempt:
        raise Invalid(f"phase-assigned: attempt must be {attempt}")
    if attempt >= 3:
        need_approval(state, "phase-assigned", p, f"attempt {attempt} of {phase} (P6)")
        return
    limit = state.plans[0]["graph"]["phases"].get(phase, {}).get("budget_min")
    if limit and state.cost.get(phase, 0) >= 1.5 * limit:
        need_approval(state, "phase-assigned", p, f"{phase} spent 1.5x its budget (P13)")


def check_submission_contract(state: State, p: dict) -> None:
    """The executor must have worked on the current attempt's assigned contract version."""
    phase, attempt = p["phase"], p["attempt"]
    current = state.attempts.get(phase)
    if type(attempt) is not int or attempt != current:
        raise Invalid(f"artifact-submitted: attempt must be the current attempt {current} of {phase}, "
                      f"got {attempt!r}")
    assigned = state.contract_versions.get((phase, attempt))
    if assigned is None:
        raise Invalid(f"artifact-submitted: attempt {attempt} of {phase} was assigned without a "
                      "contract_version (journal written before F8); assign a new attempt")
    if p["contract_version"] != assigned:
        raise Invalid(f"artifact-submitted: contract_version {p['contract_version']!r} differs from "
                      f"assigned {assigned!r} for attempt {p['attempt']} of {p['phase']}")


def check_transition(state: State, p: dict) -> None:
    phase, target = p["phase"], p["to"]
    current = state.status.get(phase)
    if current is None:
        raise Invalid(f"phase-transitioned: unknown phase {phase}")
    if target == "cancelled":
        need_approval(state, "phase-transitioned", p, "cancelling a phase (P11)")
        return
    if (current, target) not in TRANSITIONS:
        raise Invalid(f"phase-transitioned: {current} -> {target} not allowed")
    backward = target == "ready" and current not in ("waiting", "rejected", "blocked", "unknown")
    if backward and p["reason"] not in BACKWARD_REASONS:
        raise Invalid(f"phase-transitioned: backward move needs reason in {sorted(BACKWARD_REASONS)}")
    if current == "waiting":
        pending = [dep for dep in state.deps(phase) if state.status.get(dep) != "accepted"]
        if pending:
            raise Refused(f"{phase} not ready: dependencies {pending} are not accepted")
    if target in ("accepted", "accepted-unconfirmed") and current == "checking" \
            and state.plan["phases"].get(phase, {}).get("class") == "Ц":
        raise Refused(f"{phase} is a class Ц phase: it is accepted only through awaiting-decision")
    if target in ("accepted", "accepted-unconfirmed") and current == "checking":
        verdict = state.verdicts.get((phase, state.attempts.get(phase, 0)))
        if verdict == "pass-with-remarks":
            need_approval(state, "phase-transitioned", p, "accepting with remarks (P5)")
        elif verdict != "pass":
            raise Refused(f"{phase} has no passing verdict for its current attempt (P4)")
    if target == "accepted-unconfirmed" and not p.get("unconfirmed"):
        raise Invalid("accepted-unconfirmed needs the unconfirmed decision id")
    if target == "awaiting-decision":
        verdict = state.verdicts.get((phase, state.attempts.get(phase, 0)))
        if state.plan["phases"].get(phase, {}).get("class") != "Ц" or verdict not in ("pass", "pass-with-remarks"):
            raise Refused("only a class Ц phase whose decision card passed checking may await a decision")
    if current == "awaiting-decision" and target == "accepted":
        settled = [d for d in state.decisions.values()
                   if d.get("phase") == phase and d["kind"] == "goal-risk" and d["status"] == "confirmed"]
        if not settled:
            raise Refused(f"{phase} waits for a goal/risk decision confirmed by the pilot")
    if current == "accepted-unconfirmed" and target == "accepted":
        decision = state.decisions.get(state.unconfirmed.get(phase, ""), {})
        if decision.get("status") != "confirmed":
            raise Refused(f"{phase} rests on an unconfirmed decision; confirm it first")
    if p.get("rollback_of"):
        size = len(state.rollbacks.get(p["rollback_of"], set()) | {phase})
        if size > 1:
            need_approval(state, "phase-transitioned", p, f"rollback of {size} phases for one decision (P10)",
                          reuse_key=p["rollback_of"])


def check_decision(state: State, p: dict) -> None:
    if p["kind"] not in ("rule", "fact", "goal-risk"):
        raise Invalid("decision-recorded: kind must be rule, fact or goal-risk")
    if not str(p["basis"]).strip():
        raise Refused("a decision needs a basis with a reference")
    right = state.right_of(p["rule"])
    p["right"] = right
    p["risk"] = "high" if p["rule"] in HIGH_RISK_RULES else "normal"
    status = p["status"]
    if status == "proposed":
        return
    if status == "decided" and right == "auto":
        return
    rid = p.get("request_id") or ""
    asked = state.requests.get(rid, {})
    if rid and asked.get("decision_id") != p["decision_id"]:
        raise Refused(f"request {rid} was not asked about decision {p['decision_id']}")
    answer = state.answers.get(rid)
    if status in ("decided", "confirmed") and not (rid and state.decision_answered(rid)):
        raise Refused(f"{p['rule']} is {right}: deciding needs the pilot's approval")
    if status == "rejected" and not answer:
        raise Refused("a rejection must reference the pilot's answer")
    if status not in ("decided", "confirmed", "rejected"):
        raise Invalid("decision-recorded: status must be proposed, decided, confirmed or rejected")


def check_verification(state: State, p: dict) -> None:
    if p.get("scope") == "run":
        return
    phase, attempt = p["phase"], p["attempt"]
    if state.status.get(phase) != "checking" or attempt != state.attempts.get(phase):
        raise Invalid(f"verification-recorded: {phase} attempt {attempt} is not the one being checked")
    if str(p["verifier"]) == state.executors.get((phase, attempt)):
        raise Refused(f"the executor of {phase} attempt {attempt} cannot verify it")


def check_letter(state: State, p: dict) -> None:
    trail = state.chains.get(p["chain"], [])
    if p["to_wp"] in trail:
        raise Refused(f"letter chain {p['chain']} returns to {p['to_wp']}: cycle, ask the pilot (P14)")


def check_request(run_dir: Path, state: State, p: dict) -> None:
    if p["request_id"] in state.requests:
        raise Invalid(f"pilot-requested: request {p['request_id']} already exists")
    action = p["action"]
    if not isinstance(action, dict) or "type" not in action:
        raise Invalid("pilot-requested: action must name the event type it approves (and phase/version)")
    must = ACTION_KEYS.get(action["type"], ())
    if action["type"] == "phase-transitioned" and "rollback_of" in action:
        must = ("to",)  # one approval covers every phase of the rollback of one decision
    missing = [key for key in must if key not in action]
    if missing:
        raise Invalid(f"pilot-requested: an approval of {action['type']} must name {', '.join(missing)}")
    card = run_dir / CARDS / f"{p['request_id']}.md"
    if not card.exists():
        raise Invalid(f"pilot-requested: card {card.name} not found")
    p["card_sha"] = sha256_text(card.read_text(encoding="utf-8"))


def validate(run_dir: Path, state: State, etype: str, p: dict) -> None:
    if state.closed:
        raise Invalid("run is closed")
    if not state.plans and etype not in ("plan-revised", "pilot-requested", "run-stopped", "cost-recorded"):
        raise Invalid("no plan yet: only plan-revised, pilot-requested, cost-recorded or run-stopped")
    if etype == "plan-revised":
        check_plan(state, p)
    elif etype == "phase-assigned":
        check_assignment(state, p)
    elif etype == "artifact-submitted":
        if state.status.get(p["phase"]) not in ("assigned", "unknown"):
            raise Invalid(f"artifact-submitted: {p['phase']} is not assigned")
        check_submission_contract(state, p)
    elif etype == "phase-transitioned":
        check_transition(state, p)
    elif etype == "decision-recorded":
        check_decision(state, p)
    elif etype == "letter-sent":
        check_letter(state, p)
    elif etype == "pilot-requested":
        check_request(run_dir, state, p)
    elif etype == "cost-recorded":
        if float(p["minutes"]) < 0:
            raise Invalid("cost-recorded: minutes cannot be negative")
    elif etype == "verification-recorded":
        check_verification(state, p)
    elif etype == "run-completed":
        open_phases = sorted(name for name, status in state.status.items()
                             if status not in ("accepted", "cancelled"))
        if open_phases:
            raise Invalid(f"run-completed: phases {open_phases} are not accepted; use run-stopped")


# ---------------------------------------------------------------- lease

def read_lease(run_dir: Path) -> dict | None:
    path = run_dir / LEASE
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def check_epoch(run_dir: Path, epoch: int) -> None:
    lease = read_lease(run_dir)
    if not lease or lease["epoch"] != epoch:
        raise Invalid(f"stale or missing lease: epoch {epoch} is not current")
    if datetime.fromisoformat(lease["expires_at"].replace("Z", "+00:00")) < now():
        raise Invalid("lease expired: take it again with `lease`")


def current_host() -> str:
    return os.environ.get("IWE_WP_MANAGER_HOST") or socket.gethostname()


def session_holder(flag: str | None) -> str:
    """The lease holder is the Claude Code session, so the hooks can recognise it."""
    env = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if flag and env and flag != env:
        raise Invalid("--holder must equal this session's CLAUDE_CODE_SESSION_ID")
    holder = env or flag or ""
    if not HOLDER_RE.match(holder):
        raise Invalid("holder must be a session id of letters, digits, '-' or '_'")
    return holder


def check_host(events: list[dict]) -> None:
    created = next((e for e in events if e["type"] == "run-created"), None)
    if created and created["payload"]["host"] != current_host():
        raise Invalid(f"run is bound to host {created['payload']['host']}, this is {current_host()}")


def take_lease(run_dir: Path, events: list[dict], holder: str, ttl_min: int) -> int:
    check_host(events)
    lease = read_lease(run_dir)
    expired = bool(lease) and datetime.fromisoformat(
        lease["expires_at"].replace("Z", "+00:00")) < now()
    if lease and not expired and lease["holder"] != holder:
        raise Invalid(f"lease held by {lease['holder']} until {lease['expires_at']}")
    renew = bool(lease) and not expired and lease["holder"] == holder
    epoch = lease["epoch"] if renew else (lease["epoch"] + 1 if lease else 1)
    atomic_write(run_dir / LEASE, json.dumps(
        {"holder": holder, "epoch": epoch, "expires_at": iso(now() + timedelta(minutes=ttl_min))}))
    if not renew:
        write_event(run_dir, events, "lease-taken", {"holder": holder, "epoch": epoch},
                    "program", epoch, None)
    atomic_write(session_marker_dir() / f"{holder}.json",
                 json.dumps({"run_dir": str(run_dir.resolve()), "epoch": epoch}))
    return epoch


def release_session_marks(run_dir: Path) -> None:
    """A closed run no longer turns its sessions into Manager sessions."""
    target = str(run_dir.resolve())
    for mark in session_marker_dir().glob("*.json"):
        if json.loads(mark.read_text(encoding="utf-8")).get("run_dir") == target:
            mark.unlink()


# ---------------------------------------------------------------- commands

def cmd_create(args) -> int:
    run_dir = Path(args.run_dir)
    with run_lock(run_dir):
        if read_lines(run_dir):
            raise Invalid("run already exists")
        raises = json.loads(Path(args.rights_json).read_text()) if args.rights_json else {}
        unknown = set(raises) - set(DEFAULT_RIGHTS)
        if unknown or any(r not in RIGHT_ORDER for r in raises.values()):
            raise Invalid(f"rights: unknown rules or rights {sorted(unknown) or raises}")
        seed = os.urandom(16).hex()
        atomic_write(run_dir / "protected" / "seed", seed)
        events: list[dict] = []
        epoch = take_lease(run_dir, events, session_holder(args.holder), args.ttl_min)
        write_event(run_dir, events, "run-created", {
            "wp": args.wp, "description_ref": args.description_ref, "host": current_host(),
            "preset": args.preset, "raises": raises,
            "budget": json.loads(args.budget_json or "{}"),
            "seed_sha": sha256_text(seed),
        }, "manager", epoch, None)
    print(json.dumps({"run_id": run_dir.name, "epoch": epoch}))
    return 0


def cmd_lease(args) -> int:
    run_dir = Path(args.run_dir)
    with run_lock(run_dir):
        events = load_events(run_dir)
        epoch = take_lease(run_dir, events, session_holder(args.holder), args.ttl_min)
    print(json.dumps({"epoch": epoch}))
    return 0


def dry_apply(events: list[dict], etype: str, payload: dict) -> None:
    """Apply the candidate to a copy of the state first: an event that breaks the
    projection (e.g. a list where an id is expected) would make the run unreadable forever."""
    candidate = {"seq": len(events) + 1, "ts": iso(now()), "type": etype, "payload": payload}
    try:
        state = State(events + [candidate])
        json.dumps(state.summary())
        sample_ids(state, "dry-run-seed")
    except (TypeError, ValueError, KeyError, AttributeError) as error:
        raise Invalid(f"{etype}: payload would make the run unreadable ({error})") from error


def append_checked(run_dir: Path, epoch: int, etype: str, payload: dict,
                   actor: str, caused_by: int | None) -> dict:
    """Validate under the lock and write; a refusal is written as right-refused."""
    with run_lock(run_dir):
        events = load_events(run_dir)
        check_epoch(run_dir, epoch)
        require_fields(etype, payload)
        state = State(events)
        try:
            validate(run_dir, state, etype, payload)
        except Refused as refusal:
            write_event(run_dir, events, "right-refused",
                        {"attempted_type": etype, "attempted": payload, "why": str(refusal)},
                        "program", epoch, caused_by)
            raise
        dry_apply(events, etype, payload)
        event = write_event(run_dir, events, etype, payload, actor, epoch, caused_by)
        if etype == "run-completed":  # a stopped run keeps its session restricted until the pilot decides
            release_session_marks(run_dir)
        return event


def cmd_append(args) -> int:
    if args.type not in MANAGER_TYPES:
        raise Invalid(f"type {args.type} cannot be appended by the Manager")
    payload = json.loads(args.payload)
    if not isinstance(payload, dict):
        raise Invalid("payload must be a JSON object")
    event = append_checked(Path(args.run_dir), args.epoch, args.type, payload,
                           args.actor, args.caused_by)
    print(json.dumps({"seq": event["seq"]}))
    return 0


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def ingest_interventions(run_dir: Path, events: list[dict], epoch: int) -> int:
    """Pilot messages that answer nothing: one pilot-intervention event each (H-358, number 2)."""
    seen = sum(1 for e in events if e["type"] == "pilot-intervention")
    fresh = read_jsonl(run_dir / PILOT_MESSAGES)[seen:]
    for message in fresh:
        write_event(run_dir, events, "pilot-intervention", {"text_ref": message["text_ref"]},
                    "pilot", epoch, None)
    return len(fresh)


def cmd_ingest_answers(args) -> int:
    """Turn pilot messages captured by the answer-box hook into journal events."""
    run_dir = Path(args.run_dir)
    ingested, refused = [], []
    with run_lock(run_dir):
        events = load_events(run_dir)
        check_epoch(run_dir, args.epoch)
        interventions = ingest_interventions(run_dir, events, args.epoch)
        state = State(events)
        unmatched = []
        for answer in read_jsonl(run_dir / ANSWER_BOX):
            rid = answer.get("request_id")
            if rid in state.answers:
                continue
            if rid not in state.requests or str(answer.get("ts", "")) < state.requests[rid]["asked_at"]:
                unmatched.append(rid)  # no such question, or answered before it was asked
                continue
            card = run_dir / CARDS / f"{rid}.md"
            current = sha256_text(card.read_text(encoding="utf-8")) if card.exists() else ""
            if current != state.requests[rid].get("card_sha"):
                write_event(run_dir, events, "right-refused", {
                    "attempted_type": "pilot-answered", "attempted": answer,
                    "why": "card changed after the question"}, "program", args.epoch, None)
                refused.append(rid)
                continue
            payload = {k: answer[k] for k in ("request_id", "answer", "text", "transcript_ref")
                       if k in answer}
            write_event(run_dir, events, "pilot-answered", payload, "pilot", args.epoch, None)
            state.apply(events[-1])
            ingested.append(rid)
    print(json.dumps({"ingested": ingested, "refused": refused, "unmatched": sorted(set(unmatched)),
                      "interventions": interventions}))
    return 0


def cmd_state(args) -> int:
    print(json.dumps(State(load_events(Path(args.run_dir))).summary(), ensure_ascii=False, indent=2))
    return 0


def cmd_verify(args) -> int:
    events = load_events(Path(args.run_dir))
    print(json.dumps({"ok": True, "events": len(events)}))
    return 0


def cmd_affected(args) -> int:
    """Phases to roll back when a decision is rejected (closure over the plan graph)."""
    state = State(load_events(Path(args.run_dir)))
    decision = state.decisions.get(args.decision)
    if not decision:
        raise Invalid(f"unknown decision {args.decision}")
    origin = decision.get("phase")
    phases = ({origin} | state.downstream(origin)) if origin else set()
    touched = sorted(p for p in phases if state.status.get(p) not in ("waiting", "cancelled", None))
    later = sorted(d for d, rec in state.decisions.items()
                   if rec.get("phase") in phases and d != args.decision)
    print(json.dumps({"phases": touched, "decisions": later}, ensure_ascii=False))
    return 0


def sample_ids(state: State, seed: str) -> list[str]:
    return sorted(d for d, rec in state.decisions.items() if rec["right"] == "auto" and (
        rec["risk"] == "high" or int(sha256_text(seed + d)[:8], 16) % 5 == 0))


def cmd_sample(args) -> int:
    """Pick auto decisions for the pilot's spot check: every high-risk one plus a seeded fifth.

    The seed sits in protected/ (the guard keeps the agent from reading it); its hash is in
    run-created, and the seed itself is printed only once the run is closed.
    """
    run_dir = Path(args.run_dir)
    state = State(load_events(run_dir))
    seed = (run_dir / "protected" / "seed").read_text(encoding="utf-8").strip()
    print(json.dumps({"review": sample_ids(state, seed), "seed": seed if state.closed else None}))
    return 0


def cmd_views(args) -> int:
    run_dir = Path(args.run_dir)
    state = State(load_events(run_dir))
    rows = [f"| {name} | {status} | {state.attempts.get(name, 0)} | {state.cost.get(name, 0):g} |"
            for name, status in sorted(state.status.items())]
    atomic_write(run_dir / "views" / "phases.md",
                 "| Фаза | Статус | Попыток | Минут |\n|---|---|---|---|\n" + "\n".join(rows) + "\n")
    rows = [f"| {d} | {r.get('phase', '')} | {r['rule']} | {r['right']} | {r['risk']} | {r['status']} | {r['choice']} |"
            for d, r in sorted(state.decisions.items())]
    atomic_write(run_dir / "views" / "decisions.md",
                 "| Решение | Фаза | Правило | Право | Риск | Статус | Выбор |\n|---|---|---|---|---|---|---|\n"
                 + "\n".join(rows) + "\n")
    print(json.dumps({"views": ["phases.md", "decisions.md"]}))
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = root.add_subparsers(dest="command", required=True)

    def command(name, func):
        cmd = sub.add_parser(name)
        cmd.add_argument("--run-dir", required=True)
        cmd.set_defaults(func=func)
        return cmd

    create = command("create", cmd_create)
    for flag in ("--wp", "--description-ref"):
        create.add_argument(flag, required=True)
    create.add_argument("--holder")
    create.add_argument("--preset", choices=("lead", "ask"), default="lead")
    create.add_argument("--rights-json")
    create.add_argument("--budget-json")
    create.add_argument("--ttl-min", type=int, default=120)
    lease = command("lease", cmd_lease)
    lease.add_argument("--holder")
    lease.add_argument("--ttl-min", type=int, default=120)
    append = command("append", cmd_append)
    append.add_argument("--epoch", type=int, required=True)
    append.add_argument("--type", required=True)
    append.add_argument("--payload", required=True)
    append.add_argument("--actor", default="manager")
    append.add_argument("--caused-by", type=int)
    ingest = command("ingest-answers", cmd_ingest_answers)
    ingest.add_argument("--epoch", type=int, required=True)
    command("state", cmd_state)
    command("verify", cmd_verify)
    affected = command("affected", cmd_affected)
    affected.add_argument("--decision", required=True)
    command("views", cmd_views)
    command("sample", cmd_sample)
    return root


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if not RUN_DIR_RE.search(str(Path(args.run_dir).resolve())):
            raise Invalid("--run-dir must be <repo>/inbox/WP-<N>/runs/<run_id>")
        return args.func(args)
    except Refused as refusal:
        print(f"refused: {refusal}", file=sys.stderr)
        return 3
    except Broken as broken:
        print(f"journal integrity broken: {broken}", file=sys.stderr)
        return 4
    except (Invalid, KeyError, ValueError, TypeError, AttributeError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
