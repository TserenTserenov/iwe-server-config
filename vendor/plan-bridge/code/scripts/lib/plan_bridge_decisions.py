"""Versioned decision rules for the plan bridge (WP-530 Ф85 / WP-561 Ф55).

This module computes proposals; it never publishes or finalizes them. Only a
fresh Git reader may supply an OriginSnapshot. The delivery layer must check
its commit ancestry before using confirmations and writing the cursor.
Resource accounting belongs to an explicitly installed, versioned validator.
There is deliberately no default capacity model or permissive validator.
"""

from collections.abc import Callable, Mapping, Sequence
from copy import deepcopy
from dataclasses import dataclass
import hashlib
import re
from types import MappingProxyType
from typing import Protocol

import rfc8785

from plan_event_intake import request_digest, validate_request


DECISION_SCHEMA_VERSION = 1
CURSOR_SCHEMA_VERSION = 1
FINAL_OUTCOMES = frozenset({"accepted", "rejected"})
REASON_ORDER = (
    "dependency_rejected",
    "status_conflict",
    "stale_version",
    "constraint_violation",
)
RETRYABLE_RESULTS = frozenset(
    {"no_network", "lock_busy", "push_unknown", "base_changed"}
)
_DIGEST = re.compile(r"[0-9a-f]{64}\Z")
_DECISION_FIELDS = frozenset(
    {
        "schema_version",
        "event_id",
        "request_digest",
        "outcome",
        "reason",
        "dependency_ref",
        "decision_digest",
        "base_commit",
        "basis",
        "final",
    }
)
_CURSOR_FIELDS = frozenset(
    {
        "schema_version",
        "delivery_id",
        "wal_epoch",
        "confirmed_seq",
        "confirmation_commit",
    }
)
_CONFIRMATION_AUTHORITY = object()


class BridgeError(Exception):
    """A stream stop, rather than an ordinary domain rejection."""

    def __init__(self, code: str, message: str, *, stop: bool = True):
        super().__init__(message)
        self.code = code
        self.stop = stop


def _text(value):
    return isinstance(value, str) and bool(value)


def _digest(value):
    return isinstance(value, str) and _DIGEST.fullmatch(value) is not None


def decision_digest(event_id, req_digest, outcome, reason, dependency_ref=None):
    """Identity excludes publication base and explanatory basis (К3)."""
    fields = {
        "event_id": event_id,
        "request_digest": req_digest,
        "outcome": outcome,
        "reason": reason,
        "dependency_ref": dependency_ref,
    }
    return hashlib.sha256(rfc8785.dumps(fields)).hexdigest()


def validate_decision(decision: Mapping) -> None:
    if not isinstance(decision, Mapping):
        raise BridgeError("MALFORMED_DECISION", "decision is not an object")
    if (
        type(decision.get("schema_version")) is not int
        or decision["schema_version"] != 1
    ):
        raise BridgeError("INCOMPATIBLE_VERSION", "unknown decision schema_version")
    if set(decision) != _DECISION_FIELDS:
        raise BridgeError("MALFORMED_DECISION", "unexpected decision fields")
    if not _text(decision["event_id"]) or not _digest(decision["request_digest"]):
        raise BridgeError("MALFORMED_DECISION", "invalid decision identity")
    outcome, reason, dependency = (
        decision["outcome"],
        decision["reason"],
        decision["dependency_ref"],
    )
    if (
        not isinstance(outcome, str)
        or outcome not in FINAL_OUTCOMES | {"wait"}
        or type(decision["final"]) is not bool
    ):
        raise BridgeError("MALFORMED_DECISION", "invalid outcome/final flag")
    if dependency is not None and not _text(dependency):
        raise BridgeError("MALFORMED_DECISION", "invalid dependency reference")
    if outcome == "rejected" and reason not in REASON_ORDER:
        raise BridgeError("MALFORMED_DECISION", "invalid rejection reason")
    if outcome == "accepted" and reason not in (None, "migration_accepted"):
        raise BridgeError("MALFORMED_DECISION", "invalid acceptance reason")
    if outcome == "wait" and (reason is not None or decision["final"]):
        raise BridgeError("MALFORMED_DECISION", "waiting is not a final decision")
    if reason in {"dependency_rejected", "status_conflict"} and dependency is None:
        raise BridgeError("MALFORMED_DECISION", "rejection requires its dependency")
    if not _text(decision["base_commit"]):
        raise BridgeError("MALFORMED_DECISION", "decision must name its checked base")
    expected = decision_digest(
        decision["event_id"], decision["request_digest"], outcome, reason, dependency
    )
    if decision["decision_digest"] != expected:
        raise BridgeError(
            "DECISION_DIGEST_CONFLICT", "decision content does not match digest"
        )


def make_decision(
    request, outcome, reason=None, dependency_ref=None, *, base_commit, basis=None
):
    digest = request_digest(request)
    decision = {
        "schema_version": DECISION_SCHEMA_VERSION,
        "event_id": request["event_id"],
        "request_digest": digest,
        "outcome": outcome,
        "reason": reason,
        "dependency_ref": dependency_ref,
        "decision_digest": decision_digest(
            request["event_id"], digest, outcome, reason, dependency_ref
        ),
        "base_commit": base_commit,
        "basis": deepcopy(basis),
        "final": False,
    }
    validate_decision(decision)
    return decision


def _element_key(request):
    return request["stream_id"], request["element_id"]


class PlanView:
    """Accepted history and rejected IDs on one complete plan snapshot."""

    def __init__(
        self,
        rules_version,
        accepted=None,
        rejected=(),
        tips=None,
        *,
        migration_roots=(),
        ordered_accepted: Sequence[str] | None = None,
    ):
        if not _text(rules_version):
            raise BridgeError("MALFORMED_PLAN", "missing current rules version")
        self.rules_version = rules_version
        self.accepted = deepcopy(dict(accepted or {}))
        self.rejected = set(rejected)
        self.migration_roots = frozenset(migration_roots)
        if not self.migration_roots <= self.accepted.keys():
            raise BridgeError(
                "MALFORMED_PLAN", "migration exception must name an accepted record"
            )
        for event_id, request in self.accepted.items():
            validate_request(request)
            if event_id != request["event_id"] or event_id in self.rejected:
                raise BridgeError("MALFORMED_PLAN", "contradictory accepted history")
        if not all(_text(event_id) for event_id in self.rejected):
            raise BridgeError("MALFORMED_PLAN", "invalid rejected event ID")
        self.tips = self._derive_tips()
        if tips is not None and dict(tips) != self.tips:
            raise BridgeError("MALFORMED_PLAN", "tips do not match accepted history")
        self.ordered_accepted = self._validate_order(ordered_accepted)

    def _validate_order(self, order):
        if order is None:
            return None
        if (
            not isinstance(order, Sequence)
            or isinstance(order, (str, bytes))
            or not all(_text(event_id) for event_id in order)
        ):
            raise BridgeError(
                "MALFORMED_PLAN", "accepted order must be an explicit sequence of IDs"
            )
        if len(order) != len(set(order)) or set(order) != self.accepted.keys():
            raise BridgeError(
                "MALFORMED_PLAN",
                "accepted order must name every accepted request exactly once",
            )
        positions = {event_id: pos for pos, event_id in enumerate(order)}
        for event_id, request in self.accepted.items():
            parent = request["expected_parent"]
            if parent in positions and positions[parent] >= positions[event_id]:
                raise BridgeError(
                    "MALFORMED_PLAN",
                    "accepted order must place a parent before its child",
                )
        return tuple(order)

    def _derive_tips(self):
        superseded = set()
        for request in self.accepted.values():
            parent = self.accepted.get(request["expected_parent"])
            if (
                parent is None
                and request["expected_parent"] is not None
                and request["event_id"] not in self.migration_roots
            ):
                raise BridgeError(
                    "MALFORMED_PLAN", "accepted history is missing an accepted parent"
                )
            if parent is not None:
                if _element_key(parent) != _element_key(request):
                    raise BridgeError(
                        "MALFORMED_PLAN", "parent belongs to another element"
                    )
                superseded.add(parent["event_id"])
        self._check_cycles()
        tips = {}
        for event_id, request in self.accepted.items():
            if event_id not in superseded:
                element = _element_key(request)
                if element in tips:
                    raise BridgeError(
                        "MALFORMED_PLAN", "accepted history has competing tips"
                    )
                tips[element] = event_id
        elements = {_element_key(r) for r in self.accepted.values()}
        if set(tips) != elements:
            raise BridgeError("MALFORMED_PLAN", "accepted history contains a cycle")
        return tips

    def _check_cycles(self):
        complete = set()
        for event_id in self.accepted:
            path = set()
            current = event_id
            while current in self.accepted and current not in complete:
                if current in path:
                    raise BridgeError(
                        "MALFORMED_PLAN", "accepted history contains a cycle"
                    )
                path.add(current)
                current = self.accepted[current]["expected_parent"]
            complete.update(path)

    def copy(self):
        return PlanView(
            self.rules_version,
            self.accepted,
            self.rejected,
            self.tips,
            migration_roots=self.migration_roots,
            ordered_accepted=self.ordered_accepted,
        )

    def accept(self, request):
        self.accepted[request["event_id"]] = deepcopy(request)
        self.tips[_element_key(request)] = request["event_id"]
        if self.ordered_accepted is not None:
            self.ordered_accepted += (request["event_id"],)

    def reject(self, event_id):
        self.rejected.add(event_id)


class PlanValidator(Protocol):
    rules_version: str

    def validate(self, request: dict, view: PlanView) -> bool:
        """True iff the proposed transition satisfies the whole-plan constraint."""


def _require_validator(validator, view):
    if validator is None or not callable(getattr(validator, "validate", None)):
        raise BridgeError("VALIDATOR_UNAVAILABLE", "no whole-plan validator installed")
    if getattr(validator, "rules_version", None) != view.rules_version:
        raise BridgeError(
            "VALIDATOR_VERSION_MISMATCH", "validator does not implement current rules"
        )


def _evaluate(request, view, validator):
    parent = request["expected_parent"]
    if parent is not None:
        if parent in view.rejected:
            return "rejected", "dependency_rejected", parent
        if parent not in view.accepted:
            return "wait", None, parent
    if view.tips.get(_element_key(request)) != parent:
        for other in view.accepted.values():
            if (
                _element_key(other) == _element_key(request)
                and other["expected_parent"] == parent
                and other["rules_version"]
                == request["rules_version"]
                == view.rules_version
            ):
                return "rejected", "status_conflict", other["event_id"]
        return "rejected", "stale_version", None
    if request["rules_version"] != view.rules_version:
        return "rejected", "stale_version", None
    result = validator.validate(deepcopy(request), view.copy())
    if type(result) is not bool:
        raise BridgeError(
            "INVALID_VALIDATOR_RESULT", "validator must return an explicit boolean"
        )
    return (
        ("accepted", None, None)
        if result
        else ("rejected", "constraint_violation", None)
    )


def evaluate_batch(
    requests: Sequence[dict], view: PlanView, *, base_commit: str, validator=None
):
    """Evaluate in intake order, exposing provisional effects only in this batch."""
    if not _text(base_commit):
        raise BridgeError("MISSING_BASE", "proposals require an exact checked base")
    if not requests:
        return []
    _require_validator(validator, view)
    local = view.copy()
    decisions, seen = [], {}
    blocked_by = None
    for request in requests:
        digest = request_digest(request)
        event_id = request["event_id"]
        if event_id in seen:
            previous = seen[event_id]
            if previous["request_digest"] != digest:
                raise BridgeError(
                    "REQUEST_DIGEST_CONFLICT", f"{event_id} reused inside batch"
                )
            decisions.append(deepcopy(previous))
            continue
        if event_id in local.accepted or event_id in local.rejected:
            raise BridgeError(
                "DECISION_ALREADY_EXISTS", f"{event_id} must be confirmed from origin"
            )
        outcome, reason, dependency = (
            ("wait", None, blocked_by)
            if blocked_by
            else _evaluate(request, local, validator)
        )
        decision = make_decision(
            request, outcome, reason, dependency, base_commit=base_commit
        )
        seen[event_id] = decision
        decisions.append(decision)
        if outcome == "wait" and blocked_by is None:
            blocked_by = event_id
        elif outcome == "accepted":
            local.accept(request)
        elif outcome == "rejected":
            local.reject(event_id)
    return decisions


@dataclass(frozen=True)
class OriginSnapshot:
    """Data read at one fresh origin commit, supplied by the trusted Git reader.

    Constructing this value validates data, not freshness or ancestry. Those
    facts require actual Git and are obligations of the delivery layer.
    """

    commit: str
    requests: Mapping[str, str]
    decisions: Mapping[str, Mapping]

    def __post_init__(self):
        if not _text(self.commit):
            raise BridgeError("MISSING_BASE", "origin snapshot has no commit")
        if not isinstance(self.requests, Mapping) or not isinstance(
            self.decisions, Mapping
        ):
            raise BridgeError("MALFORMED_ORIGIN", "origin identities must be mappings")
        requests = dict(self.requests)
        if not all(_text(key) and _digest(value) for key, value in requests.items()):
            raise BridgeError("MALFORMED_ORIGIN", "invalid origin request identity")
        decisions = {}
        for event_id, decision in self.decisions.items():
            validate_decision(decision)
            if event_id != decision["event_id"]:
                raise BridgeError(
                    "MALFORMED_ORIGIN", "decision indexed by another event ID"
                )
            if (
                event_id in requests
                and requests[event_id] != decision["request_digest"]
            ):
                raise BridgeError(
                    "REQUEST_DIGEST_CONFLICT", "origin request and decision disagree"
                )
            decisions[event_id] = MappingProxyType(deepcopy(dict(decision)))
        object.__setattr__(self, "requests", MappingProxyType(requests))
        object.__setattr__(self, "decisions", MappingProxyType(decisions))


@dataclass(frozen=True, init=False)
class ConfirmedDecision:
    """A checked request/decision match for an intake sequence on one commit.

    Delivery must additionally bind the sequence to delivery_id/wal_epoch and
    check the exact published address-to-event mapping before supplying it.
    """

    _decision: Mapping
    _commit: str
    _intake_seq: int

    def __init__(self, decision, commit, *, intake_seq=None, _authority=None):
        if _authority is not _CONFIRMATION_AUTHORITY:
            raise BridgeError(
                "UNVERIFIED_CONFIRMATION",
                "obtain confirmation through origin comparison",
            )
        object.__setattr__(
            self, "_decision", MappingProxyType(deepcopy(dict(decision)))
        )
        object.__setattr__(self, "_commit", commit)
        object.__setattr__(self, "_intake_seq", intake_seq)

    @property
    def decision(self):
        return deepcopy(dict(self._decision))

    @property
    def confirmation_commit(self):
        return self._commit

    @property
    def intake_seq(self):
        return self._intake_seq


def is_confirmed(request, local_decision, origin: OriginSnapshot):
    validate_decision(local_decision)
    digest = request_digest(request)
    event_id = request["event_id"]
    if (
        local_decision["event_id"] != event_id
        or local_decision["request_digest"] != digest
    ):
        return False
    if origin.requests.get(event_id) != digest:
        return False
    published = origin.decisions.get(event_id)
    return bool(
        published is not None
        and published["final"]
        and published["outcome"] in FINAL_OUTCOMES
        and published["request_digest"] == digest
        and published["decision_digest"] == local_decision["decision_digest"]
    )


def confirm_decisions(requests_by_seq, local_decisions, origin: OriginSnapshot):
    confirmed = {}
    for seq, request in requests_by_seq.items():
        if type(seq) is not int or seq < 1:
            raise BridgeError(
                "MALFORMED_ADDRESS", "intake_seq must be a positive integer"
            )
        local = local_decisions.get(request["event_id"])
        if local is not None and is_confirmed(request, local, origin):
            confirmed[seq] = ConfirmedDecision(
                origin.decisions[request["event_id"]],
                origin.commit,
                intake_seq=seq,
                _authority=_CONFIRMATION_AUTHORITY,
            )
    return confirmed


def resolve_race(requests, view, origin: OriginSnapshot, *, validator=None):
    """Confirm winners on the new base; return newly computed remaining proposals."""
    confirmed, remaining = [], []
    for request in requests:
        event_id, digest = request["event_id"], request_digest(request)
        if event_id in origin.requests and origin.requests[event_id] != digest:
            raise BridgeError(
                "REQUEST_DIGEST_CONFLICT", f"{event_id} differs on origin"
            )
        published = origin.decisions.get(event_id)
        if published is not None and published["request_digest"] != digest:
            raise BridgeError(
                "REQUEST_DIGEST_CONFLICT", f"{event_id} decided for another request"
            )
        if published is not None and is_confirmed(request, published, origin):
            confirmed.append(dict(published))
        else:
            remaining.append(request)
    return confirmed, evaluate_batch(
        remaining, view, base_commit=origin.commit, validator=validator
    )


def make_cursor(delivery_id, wal_epoch, confirmed_seq=0, confirmation_commit=None):
    cursor = dict(
        schema_version=CURSOR_SCHEMA_VERSION,
        delivery_id=delivery_id,
        wal_epoch=wal_epoch,
        confirmed_seq=confirmed_seq,
        confirmation_commit=confirmation_commit,
    )
    validate_cursor(cursor)
    return cursor


def validate_cursor(cursor):
    if not isinstance(cursor, Mapping):
        raise BridgeError("MALFORMED_CURSOR", "cursor is not an object")
    if type(cursor.get("schema_version")) is not int or cursor["schema_version"] != 1:
        raise BridgeError("INCOMPATIBLE_VERSION", "unknown cursor schema_version")
    if set(cursor) != _CURSOR_FIELDS:
        raise BridgeError("MALFORMED_CURSOR", "unexpected cursor fields")
    if (
        not _text(cursor["delivery_id"])
        or type(cursor["wal_epoch"]) is not int
        or cursor["wal_epoch"] < 1
    ):
        raise BridgeError("MALFORMED_CURSOR", "invalid delivery identity")
    if type(cursor["confirmed_seq"]) is not int or cursor["confirmed_seq"] < 0:
        raise BridgeError("MALFORMED_CURSOR", "invalid confirmed prefix")
    commit = cursor["confirmation_commit"]
    if (cursor["confirmed_seq"] > 0 and not _text(commit)) or (
        commit is not None and not _text(commit)
    ):
        raise BridgeError("MALFORMED_CURSOR", "confirmed prefix requires a commit")


def advance_cursor(cursor, confirmed_by_seq, confirmation_commit):
    """Advance only through a continuous prefix of checked origin matches."""
    validate_cursor(cursor)
    for seq, confirmed in confirmed_by_seq.items():
        if (
            type(seq) is not int
            or seq < 1
            or not isinstance(confirmed, ConfirmedDecision)
        ):
            raise BridgeError(
                "UNVERIFIED_CONFIRMATION", "cursor requires checked confirmations"
            )
        validate_decision(confirmed.decision)
        if seq != confirmed.intake_seq:
            raise BridgeError(
                "CONFIRMATION_ADDRESS_MISMATCH",
                "confirmation was assigned to another intake sequence",
            )
        if confirmed.confirmation_commit != confirmation_commit:
            raise BridgeError(
                "CONFIRMATION_BASE_MISMATCH",
                "confirmations came from different snapshots",
            )
    seq = cursor["confirmed_seq"]
    while seq + 1 in confirmed_by_seq:
        seq += 1
    if seq == cursor["confirmed_seq"]:
        return dict(cursor)
    return make_cursor(
        cursor["delivery_id"], cursor["wal_epoch"], seq, confirmation_commit
    )


def check_confirmation_ancestry(
    cursor, origin_commit, is_ancestor: Callable[[str, str], bool]
):
    validate_cursor(cursor)
    previous = cursor["confirmation_commit"]
    if previous is not None and is_ancestor(previous, origin_commit) is not True:
        raise BridgeError(
            "ORIGIN_ROLLBACK", "confirmation commit is not an ancestor of fresh origin"
        )


def apply_publish_result(cursor, result):
    validate_cursor(cursor)
    if result not in RETRYABLE_RESULTS:
        raise BridgeError("UNKNOWN_PUBLISH_RESULT", f"unclassified result {result!r}")
    return dict(cursor)


def may_redecide(existing_decision):
    if existing_decision is None:
        return True
    validate_decision(existing_decision)
    return not existing_decision["final"]


def check_stop(
    local_requests, local_decisions, origin_requests, origin_decisions, confirmed_ids
):
    findings = []
    for decisions in (local_decisions, origin_decisions):
        for event_id, decision in decisions.items():
            try:
                validate_decision(decision)
            except BridgeError as exc:
                finding = (exc.code, event_id)
                if finding not in findings:
                    findings.append(finding)
    for event_id, digest in local_requests.items():
        if event_id in origin_requests and origin_requests[event_id] != digest:
            findings.append(("REQUEST_DIGEST_CONFLICT", event_id))
    for event_id, local in local_decisions.items():
        remote = origin_decisions.get(event_id)
        if (
            remote is not None
            and local.get("final")
            and remote.get("final")
            and remote.get("request_digest") == local.get("request_digest")
            and remote.get("decision_digest") != local.get("decision_digest")
        ):
            findings.append(("DECISION_CONFLICT", event_id))
    for event_id in confirmed_ids:
        remote = origin_decisions.get(event_id)
        if event_id not in origin_requests or remote is None or not remote.get("final"):
            findings.append(("CONFIRMED_RECORD_LOST", event_id))
    return findings


def _address_key(address):
    fields = {"delivery_id", "wal_epoch", "intake_seq"}
    if not isinstance(address, Mapping) or set(address) != fields:
        raise BridgeError("MALFORMED_ADDRESS", "unexpected delivery-address fields")
    if not _text(address["delivery_id"]) or any(
        type(address[k]) is not int or address[k] < 1
        for k in ("wal_epoch", "intake_seq")
    ):
        raise BridgeError("MALFORMED_ADDRESS", "invalid delivery address")
    return address["delivery_id"], address["wal_epoch"], address["intake_seq"]


def startup_findings(
    own_delivery_id,
    published_addresses,
    local_addresses,
    local_requests,
    origin_requests,
):
    local_keys = [_address_key(address) for address in local_addresses]
    if len(local_keys) != len(set(local_keys)):
        raise BridgeError("ADDRESS_CONFLICT", "local WAL repeats a delivery address")
    findings = []
    local_set = set(local_keys)
    for address in published_addresses:
        key = _address_key(address)
        if key[0] == own_delivery_id and key not in local_set:
            findings.append(("PUBLISHED_ADDRESS_MISSING_LOCALLY", key[1:]))
    to_publish = []
    for event_id, digest in local_requests.items():
        if event_id not in origin_requests:
            to_publish.append(event_id)
        elif origin_requests[event_id] != digest:
            findings.append(("REQUEST_DIGEST_CONFLICT", event_id))
    return {"stop": findings, "to_publish": to_publish}


def account_for_records(local_requests, origin_requests, origin_decisions):
    fates = {}
    for event_id, digest in local_requests.items():
        decision = origin_decisions.get(event_id)
        if decision is not None:
            validate_decision(decision)
        if event_id in origin_requests and origin_requests[event_id] != digest:
            fate = "conflict"
        elif event_id not in origin_requests:
            fate = "unpublished"
        elif decision is not None and decision["request_digest"] != digest:
            fate = "conflict"
        elif decision is not None and decision["final"]:
            fate = "confirmed"
        else:
            fate = "awaiting_decision"
        fates[event_id] = fate
    return fates


def import_probe_records(mapped_requests, wal_requests):
    """Pure import proposal; callers must explicitly map the historical format."""
    added, seen = [], dict(wal_requests)
    for request in mapped_requests:
        digest, event_id = request_digest(request), request["event_id"]
        if event_id in seen and seen[event_id] != digest:
            raise BridgeError(
                "REQUEST_DIGEST_CONFLICT", f"{event_id} differs in migration input"
            )
        if event_id not in seen:
            added.append(event_id)
            seen[event_id] = digest
    return added


def migration_decision(
    request, approved_requests, existing_decisions=None, *, base_commit
):
    """Propose a migration outcome only for the pilot-approved exact ID+digest.

    No approval is inferred, no request is rewritten, and no effect is applied.
    The caller obtains this explicit list from the pilot, not from a CLI flag.
    """
    digest, event_id = request_digest(request), request["event_id"]
    if event_id in (existing_decisions or {}):
        raise BridgeError(
            "MIGRATION_ALREADY_DECIDED", f"{event_id} already has a decision"
        )
    if (
        not isinstance(approved_requests, Mapping)
        or approved_requests.get(event_id) != digest
    ):
        raise BridgeError(
            "MIGRATION_NOT_CONFIRMED", f"{event_id} not in the pilot's exact list"
        )
    return make_decision(
        request, "accepted", "migration_accepted", base_commit=base_commit
    )


def retry_overdue(wal_durable_at, last_attempt_at, now):
    anchor = max(
        wal_durable_at,
        last_attempt_at if last_attempt_at is not None else wal_durable_at,
    )
    return now - anchor > 30
