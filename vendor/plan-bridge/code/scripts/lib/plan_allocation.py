#!/usr/bin/env python3
"""plan_allocation.py -- allocation_confirmed semantics (WP-561 F33, DR-03) on
top of plan_event_wal.py's transport-level WAL.

plan_event_wal.py is explicitly NOT this layer (see its own module docstring,
confirmed by Kimi in peer-session 2026-10-12-11-wp561-dynamic-day): it gives a
CAS on the stream's tip, not an opinion about who may hold an exclusive
resource. This module is that opinion -- a pure projection over the WAL's
records, plus admission operations that pair a semantic check with the WAL's
own CAS so the check and the write cannot race apart (DR-03 condition 3, and
the check-then-act gap Kimi found in this module's design round 1:
MC-sessions:2026-10/12/2026-10-12-14-wp561-f33-allocation-confirmed/01-peer-kimi.md).

Six conditions from DR-03 (inbox/WP-561/drr/DR-03-f33-archgate-allocation-confirmed.md):
  1. State machine: confirmed -> {started | cancelled_before_start | expired}.
  2. Fencing token (monotonic generation per resource).
  3. Atomic admission+liveness check at start time.
  4. Explicit resource-type migration for the legacy claims_exclusive_resource
     flag, plus a replay test on a historical journal.
  5. An independent invariant observer ("no start after the basis was revoked").
  6. A numeric validator budget before live producers -- explicitly the
     pilot's own decision/implementation per DR-03, not part of this module.

Round 3 (cold review, Fable, 2026-10-13) found this module's first version
left condition 1 two-thirds done (no `expired`, so a holder that crashed
after confirming but before starting blocked its resource forever) and its
own idempotent-retry story broken at the semantic layer (a legitimate retry
of one's own successful `action_started`, after a lost response, came back
as a `SemanticRejection` indistinguishable from a real competing start).
Both are fixed here; see `_find_idempotent_replay` and `try_expire_allocation`.
"""

import hashlib
from pathlib import Path
from typing import NamedTuple, Optional

import plan_event_wal as wal

RESOURCE_TYPE_UNKNOWN = "unknown"
RESOURCE_TYPE_PLAN_HOUR = "plan_hour"

# A generation is "live" (still holds the resource) in exactly these two
# states; used identically by the admission preconditions and by the
# observer's violation detection (round 1 cold review: these two checks had
# drifted into two separately hand-written tuples; unified so they cannot
# disagree).
_LIVE_STATES = frozenset({"confirmed", "started"})


class AllocationError(Exception):
    pass


class SemanticRejection(AllocationError):
    """The semantic check (generation match, current state, resource type,
    envelope/resource consistency, holder identity) failed before any WAL
    write was attempted -- no race, just an invalid request on its own
    terms."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


class StatusConflict(AllocationError):
    """Lost the WAL-CAS race: by the time this admission attempted its
    write, the stream's tip had already moved past what the semantic check
    saw (`ParentMismatch`), or another writer held the stream's lock at the
    exact moment of the attempt (`StreamBusy` -- round 3, Fable: the
    original version let this one leak out of `plan_event_wal` undocumented
    and uncaught, a second, differently-shaped exception callers had no
    reason to expect). Per DR-03 condition 1 / Test A, the resource's state
    is NOT changed by a losing attempt in either case -- it is simply
    rejected."""


class AllocationState(NamedTuple):
    """One resource's current projection: `generation` (condition 2's
    fencing token), `state` (condition 1's state machine, `None` if the
    resource has never been allocated), and `holder` (the `producer_id` that
    confirmed the current generation -- round 3, Fable: without this, any
    agent could `action_started` on a generation someone else confirmed, and
    no check anywhere would catch it)."""

    generation: int
    state: Optional[str]
    holder: Optional[str]


def _tip_of(records: list[dict]) -> Optional[str]:
    return records[-1]["envelope"]["event_id"] if records else None


def _resource_id(envelope: dict) -> Optional[str]:
    return (envelope.get("payload") or {}).get("resource_id")


def resolve_resource_type(envelope: dict) -> str:
    """Condition 4 / Test D. Three-way split, not two (writer's original
    design had only "explicit type" vs "default to plan_hour"; Codex's round-1
    finding added the third branch): an event missing BOTH fields is `unknown`,
    never silently granted an exclusive claim.

    1. `payload.resource_type` present -> return it as-is (current producers).
    2. absent, but `payload.claims_exclusive_resource is True` explicitly ->
       `"plan_hour"` (Test D: replaying the pre-resource_type journal, where
       this flag was the only signal of an exclusive claim -- that journal
       always carries `resource_id` too; see `TestDWiredIntoRealSemantics`
       for the end-to-end replay, not just this classifier in isolation).
    3. neither field present -> `"unknown"` (a plain non-exclusive change, or
       an old event that never claimed a resource at all).
    """
    payload = envelope.get("payload") or {}
    explicit = payload.get("resource_type")
    if explicit is not None:
        return explicit
    if payload.get("claims_exclusive_resource") is True:
        return RESOURCE_TYPE_PLAN_HOUR
    return RESOURCE_TYPE_UNKNOWN


def _producer_identity_digest(envelope: dict) -> str:
    """The identity of a producer's REQUEST, independent of `expected_parent`
    -- this module (not the producer) assigns `expected_parent` fresh at the
    moment of each admission attempt, so two attempts of the same logical
    request made against different stream tips must still be recognized as
    the same request. `wal.content_digest` cannot be reused directly: it
    deliberately includes `expected_parent` as a producer field (T3's frozen
    contract), correct for the WAL's own idempotency, but wrong for this
    module's retry detection (round 3, Fable)."""
    fields = {
        key: value
        for key, value in envelope.items()
        if key in wal.PRODUCER_FIELDS and key != "expected_parent"
    }
    return hashlib.sha256(wal.canonical_json(fields)).hexdigest()


def _find_idempotent_replay(records: list[dict], envelope: dict) -> Optional[int]:
    """Looks for a prior record with the same `event_id`. If its producer
    identity (ignoring `expected_parent`) matches this envelope, this is a
    genuine retry -- return that record's `intake_seq` so the caller gets the
    same outcome back instead of a semantic check running against the
    now-advanced state (round 3, Fable: the original version had no such
    lookup, so retrying one's own successful `action_started` after a lost
    response came back `SemanticRejection: ... not 'confirmed'`,
    indistinguishable from a real competing start). A different identity
    under the same `event_id` is a producer bug, not a retry -- raised here
    rather than left to surface later as whatever `wal.append` happens to
    throw once the rest of this function's checks have already run."""
    event_id = envelope.get("event_id")
    if event_id is None:
        return None
    for record in records:
        if record["envelope"].get("event_id") != event_id:
            continue
        if _producer_identity_digest(record["envelope"]) == _producer_identity_digest(envelope):
            return record["intake_seq"]
        raise SemanticRejection(
            f"event_id {event_id!r} was already accepted with different content "
            "(not a retry of the same request)"
        )
    return None


def _violation(resource_id: Optional[str], generation: Optional[int], envelope: dict, reason: str) -> dict:
    return {
        "resource_id": resource_id,
        "generation": generation,
        "event_id": envelope.get("event_id"),
        "reason": reason,
    }


def _walk_detailed(records: list[dict], resource_id: str) -> tuple[AllocationState, list[dict]]:
    """The one pass both the admission operations and the observer run --
    unifying them here (round 1 cold review) is what makes condition 4's
    resource-type migration and condition 5's violation detection apply
    identically everywhere, instead of hand-written copies silently drifting
    apart.

    Reads all of DR-03's state machine, not just the three states the
    writer's first draft implemented (round 3, Fable): `allocation_expired`
    closes `confirmed -> expired` (a generation nobody started in time, or
    whose holder crashed before starting); `outcome_confirmed` and
    `cancellation_compensated` close `started -> completed` and
    `started -> compensated` respectively (an actor reporting its own
    result, not contending for the resource -- no dedicated admission
    operation needed for either, unlike `allocation_expired`, which DOES go
    through `try_expire_allocation`'s CAS since it ends a generation on
    someone else's behalf).
    """
    current_gen = 0
    current_state: Optional[str] = None
    current_holder: Optional[str] = None
    violations: list[dict] = []
    for record in records:
        envelope = record["envelope"]
        if _resource_id(envelope) != resource_id:
            continue
        event_type = envelope.get("event_type")
        if event_type == "allocation_confirmed":
            if resolve_resource_type(envelope) == RESOURCE_TYPE_UNKNOWN:
                continue
            if current_state in _LIVE_STATES:
                violations.append(
                    _violation(
                        resource_id,
                        current_gen,
                        envelope,
                        f"allocation_confirmed while a prior generation was still "
                        f"{current_state!r} (not cancelled/expired first)",
                    )
                )
                continue
            current_gen += 1
            current_state = "confirmed"
            current_holder = envelope.get("producer_id")
        elif event_type == "action_started":
            if current_state != "confirmed":
                violations.append(
                    _violation(
                        resource_id,
                        current_gen,
                        envelope,
                        f"action_started while allocation state was {current_state!r}, not 'confirmed'",
                    )
                )
            elif envelope.get("producer_id") != current_holder:
                violations.append(
                    _violation(
                        resource_id,
                        current_gen,
                        envelope,
                        f"action_started by {envelope.get('producer_id')!r} does not match "
                        f"the confirmed holder {current_holder!r}",
                    )
                )
            else:
                current_state = "started"
        elif event_type == "change_rejected" and current_state == "confirmed":
            current_state = "cancelled_before_start"
        elif event_type == "allocation_expired" and current_state == "confirmed":
            current_state = "expired"
        elif event_type == "outcome_confirmed" and current_state == "started":
            current_state = "completed"
        elif event_type == "cancellation_compensated" and current_state == "started":
            current_state = "compensated"
        # Any other event type for this resource_id is outside this module's
        # read vocabulary and is deliberately ignored, not a violation.
    return AllocationState(current_gen, current_state, current_holder), violations


def _walk(records: list[dict], resource_id: str) -> AllocationState:
    """Admission-facing view of `_walk_detailed`: the state, without the
    violation list (admission operations refuse a bad request outright;
    they don't collect a report about it)."""
    return _walk_detailed(records, resource_id)[0]


def generation(records: list[dict], resource_id: str) -> int:
    """Condition 2 / Test C: the fencing token, as a computed projection over
    already-accepted WAL records -- not a separately stored counter."""
    return _walk(records, resource_id).generation


def _validate_envelope_shape(envelope: dict, resource_id: str, expected_event_type: str) -> None:
    """Round 3, Fable (Medium-3): none of the admission operations checked
    that the envelope they were about to write actually matched what the
    caller claimed it was for. Without this, `try_confirm_allocation(sd,
    "A", envelope_for_B)` would write `envelope_for_B` while running its
    semantic check against `"A"`, and a confirmation whose own
    `resource_type` resolves to `unknown` would be written and accepted by
    the WAL while never counting as a real claim to any later reader."""
    if envelope.get("event_type") != expected_event_type:
        raise SemanticRejection(
            f"envelope.event_type {envelope.get('event_type')!r} != {expected_event_type!r}"
        )
    if _resource_id(envelope) != resource_id:
        raise SemanticRejection(f"envelope's resource_id does not match {resource_id!r}")


def _begin_admission(
    stream_dir: Path,
    resource_id: str,
    envelope: dict,
    expected_event_type: str,
    records: Optional[list[dict]],
) -> tuple[list[dict], Optional[int]]:
    """Common opening shared by all three admission operations (round 4
    cold review, Medium: this was duplicated three times -- P2's "third
    repetition" threshold). Resolves `records`, checks for an idempotent
    retry, and validates the envelope's own shape. Returns `(records,
    replay_seq)`; a non-`None` `replay_seq` means the caller should return it
    immediately without running its own semantic checks."""
    if records is None:
        records = wal.read_all(stream_dir)
    replay_seq = _find_idempotent_replay(records, envelope)
    if replay_seq is not None:
        return records, replay_seq
    _validate_envelope_shape(envelope, resource_id, expected_event_type)
    return records, None


def _attempt_write(stream_dir: Path, resource_id: str, envelope: dict, records: list[dict], race_label: str) -> int:
    """Shared CAS-write tail of all three admission operations. By the time
    control reaches here, the caller's own semantic precondition checks have
    already passed; only the race against a concurrent writer remains."""
    tip = _tip_of(records)
    envelope = dict(envelope, expected_parent=tip)
    try:
        return wal.append(stream_dir, envelope, expected_parent=tip)
    except (wal.ParentMismatch, wal.StreamBusy) as exc:
        raise StatusConflict(f"resource {resource_id!r}: lost {race_label} race") from exc


def try_confirm_allocation(
    stream_dir: Path,
    resource_id: str,
    envelope: dict,
    *,
    records: Optional[list[dict]] = None,
) -> int:
    """Condition 1 (the "confirmed" state itself) / Test A.

    `records`: an optional pre-captured snapshot -- what the caller observed
    when it decided to attempt this confirmation. Two near-simultaneous
    agents, each independently reading the stream before either has written,
    both see the same snapshot and the same tip; the WAL's own CAS (not a
    second lock this module invents) decides which attempt's write actually
    lands. Passing the same snapshot into two calls is how test A models
    "almost simultaneous" without threads. Omitting it means "read fresh now"
    -- the ordinary single-agent path.

    A resource whose current generation is still "confirmed" or "started" is
    not re-offered for allocation: granting a second `allocation_confirmed`
    while the first is still live would defeat fencing even though no WAL-CAS
    conflict would ever fire (the two writes don't contend for the same tip
    if they aren't concurrent).
    """
    records, replay_seq = _begin_admission(stream_dir, resource_id, envelope, "allocation_confirmed", records)
    if replay_seq is not None:
        return replay_seq
    if resolve_resource_type(envelope) == RESOURCE_TYPE_UNKNOWN:
        raise SemanticRejection(
            f"resource {resource_id!r}: envelope has no resolvable resource_type -- not a valid claim"
        )
    state = _walk(records, resource_id)
    if state.state in _LIVE_STATES:
        raise SemanticRejection(
            f"resource {resource_id!r}: generation still {state.state!r}, not re-offerable"
        )
    return _attempt_write(stream_dir, resource_id, envelope, records, "allocation")


def try_admit_start(
    stream_dir: Path,
    resource_id: str,
    generation_claimed: int,
    envelope: dict,
    *,
    records: Optional[list[dict]] = None,
) -> int:
    """Condition 3 (atomic admission at start). Closes the check-then-act gap
    Kimi found in this module's design round 1: a one-pass semantic check
    (generation match, state is "confirmed", holder identity matches) is not
    itself atomic, so the actual `action_started` write goes through the
    same WAL-CAS (`expected_parent=tip`) that already serializes
    `allocation_confirmed`. A losing concurrent `try_admit_start` gets
    `StatusConflict` from the WAL itself, not a silently accepted double
    start.

    `records`: same pre-captured-snapshot convention as
    `try_confirm_allocation`, for the same reason.
    """
    records, replay_seq = _begin_admission(stream_dir, resource_id, envelope, "action_started", records)
    if replay_seq is not None:
        return replay_seq
    state = _walk(records, resource_id)
    if state.generation != generation_claimed:
        raise SemanticRejection(
            f"resource {resource_id!r}: generation {generation_claimed} is stale "
            f"(current generation is {state.generation})"
        )
    if state.state != "confirmed":
        raise SemanticRejection(
            f"resource {resource_id!r}: generation {generation_claimed} is "
            f"{state.state!r}, not 'confirmed'"
        )
    if envelope.get("producer_id") != state.holder:
        raise SemanticRejection(
            f"resource {resource_id!r}: generation {generation_claimed} is held by "
            f"{state.holder!r}, not {envelope.get('producer_id')!r}"
        )
    return _attempt_write(stream_dir, resource_id, envelope, records, "start")


def try_expire_allocation(
    stream_dir: Path,
    resource_id: str,
    generation_claimed: int,
    envelope: dict,
    *,
    records: Optional[list[dict]] = None,
) -> int:
    """Condition 1's third branch off "confirmed" (round 3, Fable, High-2):
    the writer's first version implemented `started` and
    `cancelled_before_start` but never `expired`, so a holder that crashed
    after confirming but before starting blocked its resource forever --
    `try_confirm_allocation` refuses to re-offer a still-"confirmed"
    resource, and nothing could move it out of that state. This is a
    separate admission operation, not a side effect of `_walk_detailed`
    reading a clock: deciding "this has timed out" is a policy choice made
    by whoever/whatever calls this (a human, a future sweeper script) and
    recorded as an explicit event, not inferred from wall-clock time inside
    the projection itself -- that would make the projection
    non-deterministic and break the S(T,K) snapshot contract Ф33 already
    froze (replaying the same records later must give the same state).

    Only valid from `"confirmed"` -- a generation that has already started
    is released by `outcome_confirmed` or `cancellation_compensated`
    instead (read directly by `_walk_detailed`; those report an actor's own
    outcome on a resource it already held, not a contested admission, so
    they don't need this function's CAS-guarded shape).
    """
    records, replay_seq = _begin_admission(stream_dir, resource_id, envelope, "allocation_expired", records)
    if replay_seq is not None:
        return replay_seq
    state = _walk(records, resource_id)
    if state.generation != generation_claimed:
        raise SemanticRejection(
            f"resource {resource_id!r}: generation {generation_claimed} is stale "
            f"(current generation is {state.generation})"
        )
    if state.state != "confirmed":
        raise SemanticRejection(
            f"resource {resource_id!r}: generation {generation_claimed} is "
            f"{state.state!r}, not 'confirmed' -- expiry only applies before a start is recorded"
        )
    return _attempt_write(stream_dir, resource_id, envelope, records, "expiry")


def _group_by_resource(records: list[dict]) -> dict[str, list[dict]]:
    """Shared grouping pass both `scan_invariant_violations` and
    `project_all` run -- unifying it here means both external callers get
    identical resource_id routing by construction, not two copies that
    could silently drift apart (the same unification argument already
    applied to `_walk_detailed` above)."""
    by_resource: dict[str, list[dict]] = {}
    for record in records:
        resource_id = _resource_id(record["envelope"])
        if resource_id is not None:
            by_resource.setdefault(resource_id, []).append(record)
    return by_resource


def project_all(records: list[dict]) -> dict[str, AllocationState]:
    """Public read-only projection of every resource_id seen in `records`
    onto its current `AllocationState` -- for external read-only
    observers (e.g. a dashboard) that need the same state machine
    `scan_invariant_violations` already runs, without reaching into this
    module's private `_walk`/`_resource_id` (added WP-561 F34, peer-session
    MC-sessions:2026-10/13/2026-10-13-04-wp561-dynamic-day-f34, cold review
    High finding). Records with no resolvable `resource_id` are not part of
    any resource's projection and are omitted here; `scan_invariant_violations`
    still flags them directly.
    """
    return {
        resource_id: _walk(resource_records, resource_id)
        for resource_id, resource_records in _group_by_resource(records).items()
    }


def scan_invariant_violations(records: list[dict]) -> list[dict]:
    """Condition 5 / Test E. An offline/periodic pass, not part of the
    admission hot path (the independent observer DR-03 asks for, kept
    structurally separate from the admission operations above). Runs
    `_walk_detailed` per resource and returns whatever violations that single
    shared pass found. Never raises, and does not decide what the caller
    does with the result (DR-03 condition 5: the signal goes to the
    pipeline's owner, this function only detects).

    An `allocation_confirmed` or `action_started` with no `resource_id` at
    all is flagged directly, before grouping (round 3, Fable, Medium-2): the
    per-resource pass can only ever see records it can route by
    `resource_id`, so a producer that omits it would otherwise evade
    condition 5 entirely rather than tripping it.
    """
    violations: list[dict] = []
    for record in records:
        envelope = record["envelope"]
        if _resource_id(envelope) is None and envelope.get("event_type") in (
            "allocation_confirmed",
            "action_started",
        ):
            violations.append(
                _violation(
                    None,
                    None,
                    envelope,
                    f"{envelope.get('event_type')} has no resource_id -- cannot verify admission",
                )
            )
    for resource_id, resource_records in _group_by_resource(records).items():
        _, resource_violations = _walk_detailed(resource_records, resource_id)
        violations.extend(resource_violations)
    return violations
