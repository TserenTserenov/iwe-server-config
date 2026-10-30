#!/usr/bin/env python3
"""Durable v2 plan intake; semantic parent and transport CAS are independent.

The caller supplies a trusted verifier, not a producer-controlled identity flag.
This module provides the integration boundary, not a live identity mechanism.
CRC detects damaged frames, not deletion of complete acknowledged frames; the
delivery layer must compare the durable origin/receipt evidence separately.
"""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import tempfile
from typing import Protocol
from uuid import UUID, uuid4

import rfc8785

import plan_event_wal as wal

SCHEMA = "plan-event-wal/2"
METADATA_SCHEMA = "plan-event-intake/2"
METADATA_FILE = "intake.json"
# Leave room for request/decision/address envelopes under the YAML transport's
# depth 32 / 20,000 event ceilings. Nodes include each mapping key separately;
# YAML emits at most two events per such node, plus the small outer envelope.
MAX_REQUEST_DEPTH = 16
MAX_PARSE_DEPTH = 100  # parser guard for stored files; request limit stays 16
MAX_REQUEST_NODES = 4000
MAX_REQUEST_BYTES = 64 * 1024  # JCS bytes, before adding transport/proof metadata.
REQUEST_FIELDS = frozenset(wal.PRODUCER_FIELDS)
RECORD_FIELDS = frozenset(
    {
        "schema",
        "request",
        "request_digest",
        "address",
        "registered_at",
        "producer_proof",
    }
)


class AuthorizationDenied(wal.WalError):
    """The trusted caller could not bind this producer to this exact request."""


class IntakeIntegrityError(wal.WalError):
    """Stored content or address disagrees with the intake's durable identity."""


class ProducerVerifier(Protocol):
    def verify(
        self,
        *,
        producer_id: str,
        request_digest: str,
        trusted_context: object,
        proof: dict | None = None,
    ) -> dict | None:
        """Return nonsecret provenance bound to both arguments, or deny.

        Intake passes proof=None. Delivery passes the stored proof and must
        independently verify it. A shared uid is not an agent identity.
        """
        ...


def _reject_duplicates(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_constant(value: str):
    raise ValueError(f"non-JSON numeric value: {value}")


def _check_parsed_depth(value: object) -> None:
    """Iterative: Python 3.14+ parses deep JSON without RecursionError."""
    stack = [(value, 1)]
    while stack:
        item, depth = stack.pop()
        if type(item) is dict:
            children = item.values()
        elif type(item) is list:
            children = item
        else:
            continue
        if depth > MAX_PARSE_DEPTH:
            raise ValueError("JSON nesting too deep")
        stack.extend((child, depth + 1) for child in children)


def _parse_json(raw: str | bytes):
    value = json.loads(
        raw, object_pairs_hook=_reject_duplicates, parse_constant=_reject_constant
    )
    _check_parsed_depth(value)
    return value


def _check_json_tree(value: object) -> None:
    if type(value) is dict:
        for key, item in value.items():
            if type(key) is not str:
                raise ValueError("JSON object keys must be strings")
            _check_json_tree(item)
    elif type(value) is list:
        for item in value:
            _check_json_tree(item)
    elif value is not None and type(value) not in (str, int, float, bool):
        raise ValueError(f"not a JSON value: {type(value).__name__}")


def _canonical(value: object) -> bytes:
    try:
        _check_json_tree(value)
        return rfc8785.dumps(value)
    except (ValueError, TypeError, RecursionError, UnicodeError) as exc:
        raise wal.MalformedEnvelope(
            f"not representable as RFC 8785 JSON: {exc}"
        ) from exc


def _nonempty_string(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _timestamp(value: object) -> bool:
    if not _nonempty_string(value):
        return False
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.tzinfo is not None and parsed.utcoffset() is not None
    except ValueError:
        return False


def _validate_request_budget(request: dict) -> None:
    pending = [(request, 1)]  # Root is depth one; scalar leaves count too.
    nodes = 0
    while pending:
        value, depth = pending.pop()
        nodes += 1
        if depth > MAX_REQUEST_DEPTH:
            raise wal.MalformedEnvelope(f"request depth exceeds {MAX_REQUEST_DEPTH}")
        children = ()
        if isinstance(value, dict):
            nodes += len(value)  # Mapping keys are YAML scalar events as well.
            children = value.values()
        elif isinstance(value, list):
            children = value
        if nodes + len(pending) + len(children) > MAX_REQUEST_NODES:
            raise wal.MalformedEnvelope(f"request nodes exceed {MAX_REQUEST_NODES}")
        pending.extend((item, depth + 1) for item in children)


def validate_request(request: dict) -> None:
    """Validate the exact explicit producer fields; semantic policy is separate."""
    if not isinstance(request, dict):
        raise wal.MalformedEnvelope("request must be a JSON object")
    if type(request.get("schema_version")) is not int or request["schema_version"] != 2:
        raise wal.IncompatibleVersion("request schema_version must be integer 2")
    if set(request) != REQUEST_FIELDS:
        raise wal.MalformedEnvelope(
            "v2 request must contain exactly the 14 producer fields"
        )
    for key in (
        "event_id",
        "event_type",
        "element_id",
        "stream_id",
        "producer_id",
        "rules_version",
        "occurred_at",
    ):
        if not _nonempty_string(request[key]):
            raise wal.MalformedEnvelope(f"{key} must be a nonempty string")
    parent = request["expected_parent"]
    if parent is not None and not _nonempty_string(parent):
        raise wal.MalformedEnvelope(
            "expected_parent must be a nonempty event_id or null"
        )
    if parent == request["event_id"]:
        raise wal.SelfReferenceCycle(request["event_id"])
    for key in ("actor", "basis", "payload"):
        if not isinstance(request[key], dict):
            raise wal.MalformedEnvelope(f"{key} must be an object")
    version = request["data_version"]
    if not (_nonempty_string(version) or (type(version) is int and version >= 1)):
        raise wal.MalformedEnvelope(
            "data_version must be a nonempty string or positive integer"
        )
    tact = request["tact_ref"]
    if tact is not None and (
        not isinstance(tact, dict)
        or any(
            not _nonempty_string(tact.get(key))
            for key in ("tact_id", "cycle_id", "publication_id")
        )
    ):
        raise wal.MalformedEnvelope(
            "tact_ref must be null or identify tact, cycle and publication"
        )
    if not _timestamp(request["occurred_at"]):
        raise wal.MalformedEnvelope(
            "occurred_at must be an ISO timestamp with timezone"
        )
    _validate_request_budget(request)
    if len(_canonical(request)) > MAX_REQUEST_BYTES:
        raise wal.MalformedEnvelope(f"request JCS bytes exceed {MAX_REQUEST_BYTES}")


def request_digest(request: dict) -> str:
    """SHA256 of the complete immutable request, encoded using RFC 8785 JCS."""
    validate_request(request)
    return hashlib.sha256(_canonical(request)).hexdigest()


def parse_request_json(raw: str | bytes) -> dict:
    """Wire boundary: reject duplicate keys, NaN and nonrepresentable requests."""
    try:
        request = _parse_json(raw)
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise wal.MalformedEnvelope(f"invalid request JSON: {exc}") from exc
    validate_request(request)
    return request


def _proof_matches(proof: object, request: dict, digest: str) -> bool:
    return (
        isinstance(proof, dict)
        and proof.get("producer_id") == request["producer_id"]
        and proof.get("request_digest") == digest
    )


def _authorize(
    request: dict,
    digest: str,
    context: object,
    verifier: ProducerVerifier | None,
    proof=None,
) -> dict:
    if verifier is None:
        raise AuthorizationDenied("no trusted producer verifier configured")
    try:
        verified = verifier.verify(
            producer_id=request["producer_id"],
            request_digest=digest,
            trusted_context=context,
            proof=_parse_json(_canonical(proof)) if proof is not None else None,
        )
    except Exception as exc:
        raise AuthorizationDenied("trusted producer verification failed") from exc
    try:
        verified = _parse_json(_canonical(verified))
    except wal.MalformedEnvelope as exc:
        raise AuthorizationDenied("verifier returned non-JSON provenance") from exc
    if not _proof_matches(verified, request, digest):
        raise AuthorizationDenied(
            "verifier did not bind producer_id and request_digest"
        )
    return verified


def _validate_address(address: object) -> None:
    if not isinstance(address, dict) or set(address) != {
        "delivery_id",
        "wal_epoch",
        "intake_seq",
    }:
        raise IntakeIntegrityError("invalid delivery address fields")
    try:
        UUID(address["delivery_id"])
    except (ValueError, TypeError, AttributeError) as exc:
        raise IntakeIntegrityError("invalid delivery_id") from exc
    for key in ("wal_epoch", "intake_seq"):
        if type(address[key]) is not int or address[key] < 1:
            raise IntakeIntegrityError(f"{key} must be a positive integer")


def _validate_record(record: dict) -> None:
    if not isinstance(record, dict) or record.get("schema") != SCHEMA:
        raise wal.IncompatibleVersion("expected plan-event-wal/2 record")
    if set(record) != RECORD_FIELDS:
        raise IntakeIntegrityError("invalid record fields")
    request = record["request"]
    digest = request_digest(request)
    if record["request_digest"] != digest:
        raise IntakeIntegrityError("stored request digest mismatch")
    _validate_address(record["address"])
    if not _timestamp(record["registered_at"]):
        raise IntakeIntegrityError("invalid registered_at")
    if not _proof_matches(record["producer_proof"], request, digest):
        raise IntakeIntegrityError("stored producer proof binding mismatch")
    _canonical(record["producer_proof"])


def verify_record(
    record: dict,
    *,
    trusted_context: object = None,
    verifier: ProducerVerifier | None = None,
) -> None:
    """Delivery rechecks trusted provenance; reading CRC alone never authenticates."""
    _validate_record(record)
    _authorize(
        record["request"],
        record["request_digest"],
        trusted_context,
        verifier,
        record["producer_proof"],
    )


def read_metadata(stream_dir: Path) -> dict:
    """Read the stable directory identity; never invent one during recovery."""
    try:
        metadata = _parse_json((stream_dir / METADATA_FILE).read_bytes())
    except (OSError, ValueError, UnicodeError, RecursionError) as exc:
        raise IntakeIntegrityError("missing or unreadable intake metadata") from exc
    if not isinstance(metadata, dict) or metadata.get("schema") != METADATA_SCHEMA:
        raise wal.IncompatibleVersion("unsupported intake metadata schema")
    if set(metadata) != {"schema", "delivery_id", "wal_epoch"}:
        raise IntakeIntegrityError("invalid intake metadata fields")
    _validate_address(
        {
            "delivery_id": metadata["delivery_id"],
            "wal_epoch": metadata["wal_epoch"],
            "intake_seq": 1,
        }
    )
    return metadata


def _load_intake(stream_dir: Path, metadata: dict) -> tuple[list[dict], int]:
    records, valid_length = wal.load_framed_records(stream_dir, json_loader=_parse_json)
    seen = set()
    for seq, record in enumerate(records, 1):
        _validate_record(record)
        address = record["address"]
        if address != {
            "delivery_id": metadata["delivery_id"],
            "wal_epoch": metadata["wal_epoch"],
            "intake_seq": seq,
        }:
            raise IntakeIntegrityError(
                "record address disagrees with intake identity or sequence"
            )
        event_id = record["request"]["event_id"]
        if event_id in seen:
            raise IntakeIntegrityError("duplicate accepted event_id")
        seen.add(event_id)
    return records, valid_length


def read_intake(stream_dir: Path) -> list[dict]:
    """Read validated records under the writer lock; does not authenticate them."""
    if not stream_dir.exists():
        return []
    with wal.locked_stream(stream_dir):
        return _load_intake(stream_dir, read_metadata(stream_dir))[0]


def _durable_directory(stream_dir: Path) -> None:
    missing = []
    directory = stream_dir
    while not directory.exists():
        missing.append(directory)
        directory = directory.parent
    for directory in reversed(missing):
        directory.mkdir(exist_ok=True)
        wal.sync_directory(directory.parent)
    # Also repairs a previous attempt whose mkdir succeeded before fsync failed.
    wal.sync_directory(stream_dir.parent)


def _metadata_for_receive(stream_dir: Path) -> dict:
    if (stream_dir / METADATA_FILE).exists():
        return read_metadata(stream_dir)
    log = stream_dir / "wal.log"
    if log.exists() and log.stat().st_size:
        raise IntakeIntegrityError("nonempty WAL has no v2 identity; refusing adoption")
    metadata = {"schema": METADATA_SCHEMA, "delivery_id": str(uuid4()), "wal_epoch": 1}
    with tempfile.NamedTemporaryFile(
        dir=stream_dir, prefix=".intake-", delete=False
    ) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(_canonical(metadata))
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(temporary, stream_dir / METADATA_FILE)
            wal.sync_directory(stream_dir)
        finally:
            temporary.unlink(missing_ok=True)
    return metadata


def _receipt(record: dict) -> dict:
    return {
        "event_id": record["request"]["event_id"],
        "request_digest": record["request_digest"],
        **record["address"],
    }


def receive_v2(
    stream_dir: Path,
    request: dict,
    *,
    expected_wal_tip: str | None,
    trusted_context: object = None,
    verifier: ProducerVerifier | None = None,
    max_record_bytes: int = wal.DEFAULT_MAX_RECORD_BYTES,
    max_stream_records: int = wal.DEFAULT_MAX_STREAM_RECORDS,
    max_stream_bytes: int = wal.DEFAULT_MAX_STREAM_BYTES,
) -> dict:
    """Authenticate, then replay before transport CAS/capacity; acknowledge fsync.

    expected_wal_tip is the transport event_id, never request.expected_parent.
    A replay returns the exact original receipt even after the tip/cap changes.
    """
    validate_request(request)
    request = _parse_json(
        _canonical(request)
    )  # Caller mutation cannot change acceptance.
    digest = request_digest(request)
    proof = _authorize(request, digest, trusted_context, verifier)
    if expected_wal_tip is not None and not _nonempty_string(expected_wal_tip):
        raise wal.MalformedEnvelope(
            "expected_wal_tip must be a nonempty event_id or null"
        )
    _durable_directory(stream_dir)
    with wal.locked_stream(stream_dir):
        metadata = _metadata_for_receive(stream_dir)
        records, valid_length = _load_intake(stream_dir, metadata)
        for prior in records:
            if prior["request"]["event_id"] == request["event_id"]:
                if prior["request_digest"] != digest:
                    raise wal.IdempotencyConflict(
                        "event_id already accepted with a different request"
                    )
                wal.sync_stream(stream_dir)
                return _receipt(prior)
        tip = records[-1]["request"]["event_id"] if records else None
        if expected_wal_tip != tip:
            raise wal.ParentMismatch(expected_wal_tip, tip)
        record = {
            "schema": SCHEMA,
            "request": request,
            "request_digest": digest,
            "address": {
                "delivery_id": metadata["delivery_id"],
                "wal_epoch": metadata["wal_epoch"],
                "intake_seq": len(records) + 1,
            },
            "registered_at": datetime.now(timezone.utc).isoformat(),
            "producer_proof": proof,
        }
        encoded_size = len(wal.encode_framed_record(record))
        if encoded_size > max_record_bytes:
            raise wal.RecordTooLarge(
                f"{encoded_size} bytes > max_record_bytes={max_record_bytes}"
            )
        if (
            len(records) >= max_stream_records
            or valid_length + encoded_size > max_stream_bytes
        ):
            raise wal.QueueFull("v2 intake capacity would be exceeded")
        wal.append_framed_record_locked(stream_dir, record, valid_length)
        return _receipt(record)
