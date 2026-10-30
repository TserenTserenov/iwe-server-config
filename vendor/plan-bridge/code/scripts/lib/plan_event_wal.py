#!/usr/bin/env python3
"""plan_event_wal.py -- append-only WAL for one plan-event stream (WP-561 F33,
narrow transport slice: T3/T4/T5/T6/T16/T17/T18/T20; see
MC-sessions:2026-10/12/2026-10-12-11-wp561-dynamic-day/report.md).

This is the transport layer only -- a CAS on the WAL tip, under one flock, so
two writers can't both extend the same stream from the same parent. It is
NOT the allocation_confirmed semantics of DR-03 (fencing token for resource
ownership, state machine, independent observer): those apply to who may act
on a plan element, not to who may append the next WAL record, and are not
implemented here.
"""

from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import struct
import time
from typing import Optional
import zlib

SCHEMA = "plan-event-wal/1"

# Fixed, explicit list -- the content digest must not shift when the
# producer's wire format gains or drops an optional key, and must not
# include anything the receiver/publisher adds (registered_at, intake_seq).
PRODUCER_FIELDS = (
    "schema_version",
    "event_id",
    "event_type",
    "element_id",
    "stream_id",
    "producer_id",
    "data_version",
    "actor",
    "basis",
    "rules_version",
    "expected_parent",
    "occurred_at",
    "tact_ref",
    "payload",
)

_HEADER = struct.Struct(">I I I")  # payload length, CRC32(length), CRC32(payload)

SUPPORTED_SCHEMA_VERSIONS = frozenset({1})

# T12/T22: plan-event payloads are small structured data (a plan element's
# fields), not attachments -- these ceilings exist because T12/T22 name them
# as contract requirements, not as speculative "might need this" headroom.
DEFAULT_MAX_RECORD_BYTES = 1_000_000
DEFAULT_MAX_STREAM_RECORDS = 100_000
DEFAULT_MAX_STREAM_BYTES = 64_000_000


class WalError(Exception):
    pass


class ParentMismatch(WalError):
    """CAS failure: `expected_parent` does not match the stream's current tip."""

    def __init__(self, expected, actual):
        super().__init__(f"expected_parent {expected!r} != tip {actual!r}")
        self.expected = expected
        self.actual = actual


class SelfReferenceCycle(WalError):
    def __init__(self, event_id):
        super().__init__(f"event {event_id!r} names itself as its own parent")


class StreamBusy(WalError):
    pass


class MidStreamCorruption(WalError):
    """A record that is not the tail failed its checksum -- the tail-truncation
    tolerance (crash mid-write) does not apply to a hole in the middle."""


class MalformedEnvelope(WalError):
    """A producer envelope is missing a field this module itself depends on
    (currently just `event_id`, which every tip/CAS/cycle check reads).
    Rejected before the lock is even taken -- writing it would silently brick
    the stream, since every later `_tip()` call would KeyError on it."""


class IncompatibleVersion(WalError):
    """T11: `envelope["schema_version"]` is not one this module knows how to
    read. Rejected before the lock, like `MalformedEnvelope`."""


class IdempotencyConflict(WalError):
    """T1: the same `event_id` was already accepted with a *different*
    `content_digest`. A replay of the identical envelope is not an error
    (see `append`'s idempotent-replay branch); this is a producer bug or a
    genuine identifier collision, not a retry."""


class QueueFull(WalError):
    """T12: the stream has reached its configured record-count or byte-size
    ceiling. Already-accepted records are never evicted to make room."""


class RecordTooLarge(WalError):
    """T22: a single record's encoded size exceeds the per-record ceiling,
    independent of (and checked separately from) the whole-stream ceiling
    in `QueueFull`."""


def canonical_json(fields: dict) -> bytes:
    """T3/T16/T20: sorted keys, no incidental whitespace, ASCII-escaped --
    deterministic across producers and independent of key insertion order."""
    return json.dumps(
        fields, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")


def content_digest(envelope: dict) -> str:
    """T3: digest covers only PRODUCER_FIELDS present in `envelope`. T16: it is
    therefore independent of receiver-assigned fields (registered_at,
    intake_seq) and of any `ts`/`source`/`kind` projection a caller derives
    from the envelope afterwards -- those are never in PRODUCER_FIELDS."""
    fields = {k: envelope[k] for k in PRODUCER_FIELDS if k in envelope}
    return hashlib.sha256(canonical_json(fields)).hexdigest()


def _crc(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def _encode_record(record: dict) -> bytes:
    payload = canonical_json(record)
    length_field = struct.pack(">I", len(payload))
    return (
        _HEADER.pack(len(payload), _crc(length_field), _crc(payload)) + payload + b"\n"
    )


def _decode_records(
    raw: bytes, *, json_loader=json.loads
) -> tuple[list[dict], int, Optional[int]]:
    """Returns (records, consumed_bytes, resume_check_pos).

    `consumed_bytes` is how much of `raw` is trustworthy records.
    `resume_check_pos` is where to keep looking for a record not created by
    this same append (None if the gap at `consumed_bytes` has no determinable
    end -- the header itself didn't fully arrive, a true incomplete tail that
    by construction has nothing real behind it). A record whose header's
    `length` checks out, but whose payload CRC/trailing newline fails, still
    has a determinable end, so scanning can resume right after it -- that is
    what lets `read_all` tell a crash tail (nothing valid follows) apart from
    mid-stream corruption (T24: a valid record follows).

    The header's `length` field carries its own CRC (`length_crc`), separate
    from the payload's, and a failure there raises immediately rather than
    returning a resume point: an untrustworthy `length` means the record's
    true end is unknown, so there is no byte offset safe to resume scanning
    from (unlike a payload CRC failure, where `length` itself is still
    trusted and the end is exact). Treating it as "maybe just a tail" would
    let `append()` truncate away real committed records sitting behind it
    without ever knowing they existed (cold review, 2026-10-12).
    """
    records = []
    pos = 0
    while True:
        if pos + _HEADER.size > len(raw):
            return records, pos, None
        length, length_crc, payload_crc = _HEADER.unpack_from(raw, pos)
        if _crc(struct.pack(">I", length)) != length_crc:
            raise MidStreamCorruption(
                f"record length field corrupted at byte {pos} (length_crc mismatch) "
                "-- the true end of this record cannot be determined, so scanning "
                "cannot safely resume past it"
            )
        end = pos + _HEADER.size + length + 1  # +1 for the trailing newline
        if end > len(raw):
            return records, pos, None
        payload = raw[pos + _HEADER.size : pos + _HEADER.size + length]
        if _crc(payload) != payload_crc or raw[end - 1 : end] != b"\n":
            return records, pos, end
        try:
            record = json_loader(payload.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            # The 1-in-~4-billion case where corruption still happens to
            # match the stored CRC: still a determinable-length record, so
            # still resumable right after it, just not a parseable one.
            return records, pos, end
        records.append(record)
        pos = end


def _load(stream_dir: Path) -> tuple[list[dict], int]:
    """Records plus the byte length they actually occupy -- the latter is
    what `append` truncates the file to before writing the next record, so a
    tolerated crash tail (T4) is discarded rather than left as unreachable
    garbage ahead of the new record. Raises `MidStreamCorruption` the same
    way `read_all` does (T24)."""
    path = stream_dir / "wal.log"
    if not path.is_file():
        return [], 0
    raw = path.read_bytes()
    records, consumed, resume_at = _decode_records(raw)
    if resume_at is not None:
        remainder, _, _ = _decode_records(raw[resume_at:])
        if remainder:
            raise MidStreamCorruption(
                f"{path}: unparseable region at byte {consumed} followed by "
                f"{len(remainder)} further valid record(s)"
            )
    return records, consumed


def read_all(stream_dir: Path) -> list[dict]:
    """Linear read of a stream's WAL; see `_load` for the corruption rule."""
    records = _load(stream_dir)[0]
    _require_v1(stream_dir, records)
    return records


def _require_v1(stream_dir: Path, records: list[dict]) -> None:
    # A v2 directory is incompatible even before its first accepted record.
    if (stream_dir / "intake.json").exists():
        raise IncompatibleVersion("v1 reader cannot open a v2 intake directory")
    for record in records:
        if (
            not isinstance(record, dict)
            or "request" in record
            or record.get("schema", SCHEMA) != SCHEMA
        ):
            raise IncompatibleVersion("v1 reader cannot interpret this WAL record")
        envelope = record.get("envelope", {})
        if (
            not isinstance(envelope, dict)
            or envelope.get("schema_version") not in SUPPORTED_SCHEMA_VERSIONS
        ):
            raise IncompatibleVersion("unsupported stored envelope schema_version")


def encode_framed_record(record: dict) -> bytes:
    """Encode one frame using the shared length/CRC framing, not request JCS."""
    return _encode_record(record)


def load_framed_records(
    stream_dir: Path, *, json_loader=json.loads
) -> tuple[list[dict], int]:
    """Strict framing for new formats: only an incomplete final frame is ignored.

    Every fully present frame must pass its checks, including the final frame.
    This cannot detect removal of a whole frame; acknowledgement evidence must
    be checked separately by the delivery layer. The v1 loader is unchanged.
    """
    path = stream_dir / "wal.log"
    if not path.is_file():
        return [], 0
    try:
        records, consumed, corrupt_end = _decode_records(
            path.read_bytes(), json_loader=json_loader
        )
    except RecursionError as exc:
        raise MidStreamCorruption(f"{path}: frame JSON exceeds nesting limit") from exc
    if corrupt_end is not None:
        raise MidStreamCorruption(f"{path}: completed frame corrupt at byte {consumed}")
    return records, consumed


def sync_directory(directory: Path) -> None:
    """Persist directory entries after a caller creates or replaces a file."""
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def sync_stream(stream_dir: Path) -> None:
    """Make an existing record durable before returning a replay receipt."""
    with open(stream_dir / "wal.log", "rb") as stream:
        os.fsync(stream.fileno())
    sync_directory(stream_dir)


def append_framed_record_locked(
    stream_dir: Path, record: dict, valid_length: int
) -> None:
    """Append under locked_stream after validation; discard only the known tail.

    A write/fsync error is propagated without removing the accepted prefix.
    The caller must not acknowledge until this function returns successfully.
    """
    encoded = encode_framed_record(record)
    path = stream_dir / "wal.log"
    with open(path, "r+b" if path.is_file() else "wb") as stream:
        stream.truncate(valid_length)
        stream.seek(valid_length)
        stream.write(encoded)
        stream.flush()
        os.fsync(stream.fileno())
    sync_directory(stream_dir)


DECISION_INTENT_EVENT_TYPE = "decision_intent"
DECISION_OUTCOME_EVENT_TYPE = "decision_outcome"


DECISION_STATES = ("pending", "closed", "conflicted")


def _decision_outcomes_conflict(
    outcome_records: list[tuple[Optional[str], Optional[str]]],
) -> bool:
    """WP-561 Ф35 С2 (full, cross-host, consensus 2026-10-15 round 3-4,
    Claude+Kimi+Codex): `outcome_records` is one `decision_id`'s
    `(origin_host, outcome)` pairs, one per `decision_outcome` event seen
    for it so far, in order. `origin_host`/`outcome` are optional payload
    fields -- `None` means absent, not a value.

    Any record with `origin_host` missing makes the whole `decision_id`
    fall back to the C2-narrow count rule (2+ records -> conflict): an
    absent host is not the same as "same host", and does not get an
    invented identity either -- Codex, round 3, "нельзя трактовать как
    общий неизвестный хост, нельзя присваивать каждой записи вымышленный
    хост". Only once EVERY record carries `origin_host` can host identity
    decide anything.

    With `origin_host` present on every record: different hosts means a
    real cross-host collision (conflict), regardless of whether `outcome`
    happens to match -- two hosts independently agreeing is not reconciliation.
    Same host with a differing `outcome` is a same-host producer bug
    (conflict). Same host with the same `outcome` on every record is a
    legitimate retry, not a conflict -- the rest of the payload is not
    compared, per this session's round 2: the conflict criterion is the
    `outcome` field alone.

    Compares the whole lifetime of `decision_id`'s `decision_outcome`
    records, not just those since the last `decision_intent` -- a
    re-opening intent (`decision_intent_states` resets an unconflicted
    `decision_id` to "pending") does not clear this history, so a
    same-host outcome that legitimately revises an earlier one after
    re-opening still reads as a producer-bug conflict (cold review,
    Fable, 2026-10-15: flagged as a genuine semantic fork -- per-epoch
    comparison would also change the cross-host reading -- left for a
    future session, not decided here).
    """
    if len(outcome_records) <= 1:
        return False
    hosts = [host for host, _ in outcome_records]
    if any(not host for host in hosts):
        # "" counts as absent too (not a real host identity), same as
        # `event_id` truthiness elsewhere in this module (cold review,
        # Fable, 2026-10-15).
        return True
    outcomes = [outcome for _, outcome in outcome_records]
    if any(outcome is None for outcome in outcomes):
        # Symmetric with the `origin_host` rule above (round 5, Kimi+Codex,
        # 2026-10-15): an absent `outcome` cannot be confirmed equal to
        # anything, so it falls back to the count rule too, same as an
        # absent host -- otherwise a producer that never fills `outcome`
        # gets a free retry-pass that a producer who DOES fill it does
        # not (Kimi's "perverse incentive" argument).
        return True
    # Equality, not a set: `origin_host`/`outcome` are producer-supplied
    # payload values, not guaranteed hashable (cold review, Fable,
    # 2026-10-15 -- a structured `outcome` dict crashed the whole stream's
    # classification with TypeError, losing every decision_id's reading,
    # not just the malformed one).
    if any(host != hosts[0] for host in hosts):
        return True
    outcomes = [outcome for _, outcome in outcome_records]
    return any(outcome != outcomes[0] for outcome in outcomes)


def decision_intent_states(records: list[dict]) -> dict[str, str]:
    """WP-561 Ф35 С3/С2 (acceptance scenario, consensus 2026-10-15,
    peer-session Claude+Kimi+Codex; cold review 2026-10-15 made "conflicted"
    sticky, see below): classify each `decision_id`'s WAL sequence as
    "pending" (a `decision_intent` with no `decision_outcome` yet, or an
    unconflicted one), "closed" (one or more `decision_outcome` seen but
    not conflicting, per `_decision_outcomes_conflict`), or "conflicted"
    (its `decision_outcome` events conflict -- the card's already-agreed
    contract, section F35 round 6, 2026-10-15: "competing records from two
    hosts -> unknown until reconciled, no agent gets first-write
    advantage"). See `_decision_outcomes_conflict` for exactly what counts
    as conflicting -- same-host identical-outcome retries do not.

    "conflicted" is sticky and never reverts to "pending": no event type in
    this module represents reconciliation (that is a future layer's job,
    per the card: "кто производит сведение итогового outcome -- деталь
    реализации чтения, не записи"), so a later `decision_intent` for an
    already-conflicted `decision_id` would otherwise hide the conflict from
    every reader until the next outcome arrives -- exactly the "first-write
    advantage" the contract forbids, just shifted to whoever writes the next
    intent instead of the next outcome. Only unconflicted `decision_id`s
    reset to "pending" on a fresh intent.

    Read-only transport-layer fact, same boundary as the rest of this
    module (see module docstring): whether "pending" means "still being
    worked" (process alive) or "unknown, process crashed before recording
    an outcome" is a judgement the CALLER makes by the circumstances of the
    read -- e.g. a fresh read right after this module's own process started
    treats every "pending" entry as unknown, since nothing in the WAL
    itself records process liveness. A same-host retry that re-emits the
    same intent (no new event_id -- already collapsed by `append`'s T1
    idempotency, so it never reaches this function as a second record)
    still just reads as plain "pending" for an otherwise-unconflicted
    `decision_id`. Likewise, a `decision_outcome` with no prior
    `decision_intent` for its `decision_id` (a producer bug, not a contract
    case this module validates) reads back as "closed" exactly like a real
    close -- there is no separate state here for "outcome without a
    matching intent".
    """
    states: dict[str, str] = {}
    outcome_records: dict[str, list[tuple[Optional[str], Optional[str]]]] = {}
    for record in records:
        envelope = record["envelope"]
        event_type = envelope.get("event_type")
        payload = envelope.get("payload")
        decision_id = payload.get("decision_id") if isinstance(payload, dict) else None
        if decision_id is None:
            continue
        if event_type == DECISION_OUTCOME_EVENT_TYPE:
            outcome_records.setdefault(decision_id, []).append(
                (payload.get("origin_host"), payload.get("outcome"))
            )
        if _decision_outcomes_conflict(outcome_records.get(decision_id, [])):
            states[decision_id] = "conflicted"  # sticky: nothing here reconciles it
        elif event_type == DECISION_INTENT_EVENT_TYPE:
            states[decision_id] = "pending"
        elif event_type == DECISION_OUTCOME_EVENT_TYPE:
            states[decision_id] = "closed"
    return states


def _tip(records: list[dict]) -> Optional[str]:
    return records[-1]["envelope"]["event_id"] if records else None


@contextmanager
def _locked(stream_dir: Path):
    stream_dir.mkdir(parents=True, exist_ok=True)
    fd = os.open(stream_dir / ".wal.lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        os.close(fd)
        raise StreamBusy(f"{stream_dir}: another writer holds .wal.lock") from exc
    try:
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


@contextmanager
def locked_stream(stream_dir: Path):
    """Public shared nonblocking flock; callers own format and CAS validation."""
    with _locked(stream_dir):
        yield


def append(
    stream_dir: Path,
    envelope: dict,
    expected_parent: Optional[str],
    *,
    max_record_bytes: int = DEFAULT_MAX_RECORD_BYTES,
    max_stream_records: int = DEFAULT_MAX_STREAM_RECORDS,
    max_stream_bytes: int = DEFAULT_MAX_STREAM_BYTES,
) -> int:
    """T5: exclusive, non-blocking flock -- a second concurrent writer fails
    immediately with `StreamBusy` rather than queueing (card decision:
    "при занятом замке второй процесс не пишет и падает сразу"). T17: the CAS
    on the tip happens inside the same locked section as the append, so
    read-tip-then-write cannot race against another process's append.

    T1: a replay of an `event_id` already accepted with the identical
    `content_digest` returns that record's `intake_seq` without writing
    again; the same `event_id` with a *different* digest is
    `IdempotencyConflict`. This covers only accepted replays -- a rejected
    attempt (`ParentMismatch`, `QueueFull`, ...) is never written to the WAL,
    so it has no recorded outcome to replay; calling `append` again with the
    same arguments just re-runs the same checks against (possibly changed)
    current state. That is a deliberate boundary of this slice, not an
    oversight (peer-session 2026-10-12-11-wp561-dynamic-day, round 2).

    The idempotency index is built from the same full read of the stream
    that `_load` already does to find the tip and the valid byte length --
    it is not an additional scan, and not a persistent index kept across
    calls (this module trusts only the file, by the same design as
    `read_all`). That existing O(n)-per-append cost is a known scaling limit
    this slice does not remove.

    T12: `max_stream_records`/`max_stream_bytes` are an ADMISSION ceiling,
    checked against the stream's size BEFORE this record is added -- not a
    hard cap on the file's final size. A stream already one record away from
    `max_stream_bytes` still accepts that one more record (whatever its own
    size), then rejects the next. If the T12 contract instead requires the
    file to never exceed N bytes, this check needs to budget for the
    about-to-be-written record's own size too; that stricter reading was not
    what this slice implements (cold review, round 2).
    """
    event_id = envelope.get("event_id")
    if not event_id:
        raise MalformedEnvelope("envelope is missing required field: event_id")
    envelope_parent = envelope.get("expected_parent")
    if envelope_parent is not None and envelope_parent != expected_parent:
        # `expected_parent` is also one of PRODUCER_FIELDS (it's part of the
        # digest), but the CAS decision below always uses the function
        # argument, never this field. Letting the two silently disagree
        # would mean the digest a replay is checked against doesn't reflect
        # what the CAS actually did (cold review, round 2).
        raise MalformedEnvelope(
            f"envelope.expected_parent {envelope_parent!r} != expected_parent argument {expected_parent!r}"
        )
    if envelope.get("schema_version") not in SUPPORTED_SCHEMA_VERSIONS:
        raise IncompatibleVersion(
            f"schema_version {envelope.get('schema_version')!r} not in {sorted(SUPPORTED_SCHEMA_VERSIONS)}"
        )
    if event_id == expected_parent:
        raise SelfReferenceCycle(event_id)
    digest = content_digest(envelope)
    with _locked(stream_dir):
        records, valid_length = _load(stream_dir)
        _require_v1(stream_dir, records)
        # Keeps only the LAST record per event_id if the WAL ever somehow
        # holds two (this module's own write path never produces that --
        # the idempotency check below is exactly what prevents it going
        # forward -- but this dict comprehension would silently mask it for
        # data written some other way). Not defended against here; flagged
        # by cold review, round 2, accepted as a pre-existing WAL-integrity
        # concern outside this slice's scope, not a new one.
        by_event_id = {r["envelope"]["event_id"]: r for r in records}
        prior = by_event_id.get(event_id)
        if prior is not None:
            if prior["content_digest"] == digest:
                return prior["intake_seq"]
            raise IdempotencyConflict(
                f"event_id {event_id!r} already accepted with a different content_digest"
            )
        tip = _tip(records)
        if expected_parent != tip:
            raise ParentMismatch(expected_parent, tip)
        if len(records) >= max_stream_records or valid_length >= max_stream_bytes:
            raise QueueFull(
                f"{stream_dir}: at capacity ({len(records)} records, {valid_length} bytes)"
            )
        record = {
            "intake_seq": len(records) + 1,
            "registered_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "envelope": envelope,
            "content_digest": digest,
        }
        encoded = _encode_record(record)
        if len(encoded) > max_record_bytes:
            raise RecordTooLarge(
                f"{len(encoded)} bytes > max_record_bytes={max_record_bytes}"
            )
        path = stream_dir / "wal.log"
        # A tolerated crash tail (T4) is garbage bytes sitting past
        # `valid_length`; truncate it away first, or the new record would
        # land unreachable behind it (the next reader's header-length scan
        # from that garbage would swallow it).
        with open(path, "r+b" if path.is_file() else "wb") as stream:
            stream.truncate(valid_length)
            stream.seek(valid_length)
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        dir_fd = os.open(stream_dir, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
        return record["intake_seq"]
