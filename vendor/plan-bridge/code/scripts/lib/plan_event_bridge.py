"""One durable delivery pass for WP-530 Ф85 / WP-561 Ф55.

The trusted host supplies producer verification and a versioned whole-plan
validator. Nothing in this module treats CLI fields, environment variables or
the operating-system uid as producer authentication. No live adapter is assumed.
"""

from collections.abc import Callable, Mapping
from contextlib import contextmanager
from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
from uuid import UUID, uuid4

import yaml
import rfc8785

import plan_event_intake as intake
import plan_event_wal as wal
from plan_bridge_decisions import (
    BridgeError,
    OriginSnapshot,
    PlanView,
    advance_cursor,
    check_confirmation_ancestry,
    confirm_decisions,
    make_cursor,
    resolve_race,
    validate_cursor,
    validate_decision,
)

JOURNAL_PREFIX = "machine/ledger/plan/bridge-v2/"
CURSOR_FILE = "cursor.json"
RETRY_INTERVAL_SECONDS = 25
OVERDUE_SECONDS = 180
MAX_BATCH_RECORDS = 32
MAX_PUBLICATION_FILE_BYTES = 4 * 1024 * 1024
MAX_PUBLICATION_BYTES = 16 * 1024 * 1024
_OID = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
_LOG = logging.getLogger(__name__)


def _unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def _json(raw):
    def reject_constant(_):
        raise ValueError("nonfinite JSON number")

    return json.loads(
        raw, object_pairs_hook=_unique_pairs, parse_constant=reject_constant
    )


class _JournalLoader(yaml.SafeLoader):
    pass


def _yaml_mapping(loader, node):
    return _unique_pairs(
        (
            loader.construct_object(key, deep=True),
            loader.construct_object(value, deep=True),
        )
        for key, value in node.value
    )


_JournalLoader.add_constructor("tag:yaml.org,2002:map", _yaml_mapping)
_JournalLoader.add_constructor(
    "tag:yaml.org,2002:timestamp", lambda loader, node: loader.construct_scalar(node)
)


def _address(address):
    if not isinstance(address, dict) or set(address) != {
        "delivery_id",
        "wal_epoch",
        "intake_seq",
    }:
        raise BridgeError("MALFORMED_ADDRESS", "invalid address fields")
    try:
        UUID(address["delivery_id"])
    except (ValueError, TypeError, AttributeError) as exc:
        raise BridgeError("MALFORMED_ADDRESS", "invalid delivery identity") from exc
    if any(
        type(address[key]) is not int or address[key] < 1
        for key in ("wal_epoch", "intake_seq")
    ):
        raise BridgeError("MALFORMED_ADDRESS", "invalid address sequence")
    return address["delivery_id"], address["wal_epoch"], address["intake_seq"]


def _oid(value):
    if not isinstance(value, str) or not _OID.fullmatch(value):
        raise BridgeError("MALFORMED_REVISION", "expected a complete commit OID")
    return value


def _git_environment():
    env = dict(os.environ)
    for key in (
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
    ):
        env.pop(key, None)
    env.update(GIT_NO_REPLACE_OBJECTS="1", GIT_GRAFT_FILE=os.devnull)
    return env


@dataclass(frozen=True)
class PublishedPlan:
    origin: OriginSnapshot
    requests: dict
    addresses: dict

    def view(self, rules_version, *, ordered_accepted=None):
        decisions = self.origin.decisions
        return PlanView(
            rules_version,
            {
                key: value
                for key, value in self.requests.items()
                if decisions.get(key, {}).get("outcome") == "accepted"
            },
            {key for key, value in decisions.items() if value["outcome"] == "rejected"},
            migration_roots={
                key
                for key, value in decisions.items()
                if value["reason"] == "migration_accepted"
            },
            ordered_accepted=ordered_accepted,
        )


@dataclass(frozen=True)
class PinnedPlanValidator:
    """Host-supplied policy and first-publication order for one exact Git base.

    The host must obtain this order from authoritative publication evidence,
    never from YAML filenames, timestamps or dictionary iteration. The reader
    checks the supplied IDs/dependencies against the complete accepted history.
    """

    base_commit: str
    validator: object
    ordered_accepted: tuple[str, ...]

    @property
    def rules_version(self):
        return self.validator.rules_version

    def validate(self, request, view):
        return self.validator.validate(request, view)


def _insert_unique(target, key, value, code):
    if key in target and not _same_json(target[key], value):
        raise BridgeError(code, "published records disagree")
    target[key] = value


def _canonical_json(value):
    # MappingProxy/tuple are internal immutable views. JSON scalar types remain
    # exact: Python's True == 1 must never establish request/decision identity.
    def plain(item):
        if isinstance(item, Mapping):
            return {key: plain(child) for key, child in item.items()}
        if isinstance(item, (tuple, list)):
            return [plain(child) for child in item]
        return item

    try:
        return rfc8785.dumps(plain(value))
    except (ValueError, TypeError, RecursionError, UnicodeError) as exc:
        raise BridgeError(
            "MALFORMED_JOURNAL", "journal must contain canonical JSON values"
        ) from exc


def _same_json(left, right):
    return _canonical_json(left) == _canonical_json(right)


def parse_journal(commit, documents):
    """Parse the entire v2 namespace before making any decision or confirmation."""
    _oid(commit)
    requests, decisions, addresses = {}, {}, {}
    for raw in documents:
        try:
            depth = 0
            for count, node in enumerate(yaml.parse(raw), 1):
                if (
                    count > 20000
                    or isinstance(node, yaml.AliasEvent)
                    or getattr(node, "anchor", None)
                ):
                    raise ValueError("journal structure exceeds admitted bounds")
                if isinstance(node, (yaml.MappingStartEvent, yaml.SequenceStartEvent)):
                    depth += 1
                elif isinstance(node, (yaml.MappingEndEvent, yaml.SequenceEndEvent)):
                    depth -= 1
                if depth > 32:
                    raise ValueError("journal nesting exceeds admitted bound")
            document = yaml.load(raw, Loader=_JournalLoader)
        except (yaml.YAMLError, ValueError, TypeError, RecursionError) as exc:
            raise BridgeError("MALFORMED_JOURNAL", "journal cannot be decoded") from exc
        _canonical_json(document)
        if not isinstance(document, dict) or document.get("schema") != "plan-events/1":
            raise BridgeError("INCOMPATIBLE_VERSION", "unknown journal schema")
        if (
            set(document) != {"schema", "scale", "period", "events"}
            or document["scale"] != "day"
            or not isinstance(document["period"], str)
            or not isinstance(document["events"], list)
        ):
            raise BridgeError("MALFORMED_JOURNAL", "invalid journal container")
        for event in document["events"]:
            if (
                not isinstance(event, dict)
                or set(event) != {"ts", "source", "kind", "data"}
                or event["source"] != "plan-bridge"
                or not isinstance(event["ts"], str)
            ):
                raise BridgeError("MALFORMED_JOURNAL", "invalid bridge event")
            kind, data = event["kind"], event["data"]
            if not isinstance(data, dict):
                raise BridgeError("MALFORMED_JOURNAL", "missing bridge event data")
            if kind == "plan_request":
                if (
                    set(data)
                    != {"schema_version", "event_id", "request_digest", "request"}
                    or type(data["schema_version"]) is not int
                    or data["schema_version"] != 2
                ):
                    raise BridgeError(
                        "INCOMPATIBLE_VERSION", "unknown request record schema"
                    )
                request = data["request"]
                digest = intake.request_digest(request)
                if (
                    request["event_id"] != data["event_id"]
                    or digest != data["request_digest"]
                ):
                    raise BridgeError(
                        "REQUEST_DIGEST_CONFLICT", "published request binding mismatch"
                    )
                _insert_unique(
                    requests, data["event_id"], request, "REQUEST_DIGEST_CONFLICT"
                )
            elif kind == "plan_decision":
                validate_decision(data)
                _oid(data["base_commit"])
                if not data["final"] or data["outcome"] == "wait":
                    raise BridgeError(
                        "MALFORMED_DECISION", "journal contains a nonfinal proposal"
                    )
                _insert_unique(decisions, data["event_id"], data, "DECISION_CONFLICT")
            elif kind == "plan_delivery":
                if (
                    set(data)
                    != {"schema_version", "event_id", "request_digest", "address"}
                    or type(data["schema_version"]) is not int
                    or data["schema_version"] != 1
                ):
                    raise BridgeError(
                        "INCOMPATIBLE_VERSION", "unknown delivery record schema"
                    )
                _insert_unique(
                    addresses,
                    _address(data["address"]),
                    (data["event_id"], data["request_digest"]),
                    "ADDRESS_CONFLICT",
                )
            else:
                raise BridgeError("INCOMPATIBLE_VERSION", "unknown bridge event kind")
    digests = {key: intake.request_digest(value) for key, value in requests.items()}
    for key, decision in decisions.items():
        if digests.get(key) != decision["request_digest"]:
            raise BridgeError(
                "REQUEST_DIGEST_CONFLICT", "decision has no matching request"
            )
    for event_id, digest in addresses.values():
        if digests.get(event_id) != digest or event_id not in decisions:
            raise BridgeError(
                "ADDRESS_CONFLICT", "delivery has no matching final decision"
            )
    published = PublishedPlan(
        OriginSnapshot(commit, digests, decisions), requests, addresses
    )
    # Structural validation is required even when only recovering old finals.
    # This label is never used to evaluate policy or accept a new request.
    published.view("journal-structure/1")
    return published


class GitPlanReader:
    """Read exact objects from a fresh, private fetch ref, without graph overlays."""

    def __init__(
        self, repository: Path, *, timeout=45, max_journal_bytes=256 * 1024 * 1024
    ):
        self.repository = Path(repository).resolve()
        self.timeout = timeout
        self.max_journal_bytes = max_journal_bytes

    def _git(self, *args, check=True):
        try:
            result = subprocess.run(
                ["git", "-C", str(self.repository), *args],
                env=_git_environment(),
                capture_output=True,
                timeout=self.timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise BridgeError(
                "NO_NETWORK", "Git operation timed out", stop=False
            ) from exc
        if check and result.returncode:
            raise BridgeError(
                "GIT_UNAVAILABLE", "Git evidence could not be read", stop=False
            )
        return result

    def fresh(self):
        ref = "refs/plan-bridge-proof/" + str(uuid4())
        try:
            self._git(
                "fetch",
                "--no-tags",
                "--no-write-fetch-head",
                "origin",
                f"+refs/heads/main:{ref}",
            )
            commit = _oid(self._git("rev-parse", ref).stdout.decode().strip())
            return self.read(commit)
        finally:
            self._git("update-ref", "-d", ref, check=False)

    def read(self, commit):
        _oid(commit)
        entries = self._git(
            "ls-tree", "-r", "-z", commit, "--", JOURNAL_PREFIX
        ).stdout.split(b"\0")
        documents, total = [], 0
        for entry in entries:
            if not entry:
                continue
            header, path = entry.split(b"\t", 1)
            mode, kind, blob = header.split()
            if mode != b"100644" or kind != b"blob" or not path.endswith(b".yaml"):
                raise BridgeError("MALFORMED_JOURNAL", "unexpected journal tree entry")
            size = int(self._git("cat-file", "-s", blob.decode()).stdout)
            total += size
            if total > self.max_journal_bytes:
                raise BridgeError(
                    "JOURNAL_LIMIT", "journal exceeds admitted reader bound"
                )
            documents.append(self._git("cat-file", "blob", blob.decode()).stdout)
        return parse_journal(commit, documents)

    def is_ancestor(self, ancestor, descendant):
        _oid(ancestor)
        _oid(descendant)
        return (
            self._git(
                "merge-base", "--is-ancestor", ancestor, descendant, check=False
            ).returncode
            == 0
        )

    def parents(self, commit):
        _oid(commit)
        return tuple(
            self._git("rev-list", "--parents", "-n", "1", commit)
            .stdout.decode()
            .split()[1:]
        )


def publication_documents(records, decisions, origin):
    """Publish only a continuous decided prefix (К6); wait must block its tail."""
    documents = {}
    total_bytes = 0
    for record in records:
        request = record["request"]
        event_id, digest = request["event_id"], record["request_digest"]
        decision = decisions.get(event_id)
        if decision is None or decision["outcome"] == "wait":
            break
        timestamp = record["registered_at"]
        day = (
            datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
            .astimezone(timezone.utc)
            .date()
            .isoformat()
        )
        events = []

        def append(kind, data):
            events.append(
                dict(ts=timestamp, source="plan-bridge", kind=kind, data=deepcopy(data))
            )

        if event_id not in origin.requests:
            append(
                "plan_request",
                dict(
                    schema_version=2,
                    event_id=event_id,
                    request_digest=digest,
                    request=request,
                ),
            )
        if event_id not in origin.origin.decisions:
            append("plan_decision", {**decision, "final": True})
        if _address(record["address"]) not in origin.addresses:
            append(
                "plan_delivery",
                dict(
                    schema_version=1,
                    event_id=event_id,
                    request_digest=digest,
                    address=record["address"],
                ),
            )
        if events:
            delivery, epoch, seq = _address(record["address"])
            relative = f"plan/bridge-v2/{day[:4]}/{day[5:7]}/plan-{day}-{delivery}-{epoch}-{seq}.yaml"
            data = yaml.safe_dump(
                dict(schema="plan-events/1", scale="day", period=day, events=events),
                allow_unicode=True,
                sort_keys=False,
            ).encode()
            if len(data) > MAX_PUBLICATION_FILE_BYTES:
                raise BridgeError(
                    "PUBLICATION_LIMIT", "record exceeds admitted publication bound"
                )
            if total_bytes + len(data) > MAX_PUBLICATION_BYTES:
                break
            documents[relative] = data
            total_bytes += len(data)
    return documents


@dataclass(frozen=True)
class PublishResult:
    state: str
    receipt: dict | None = None


class LedgerPublisher:
    """One invocation of the existing host-wide publisher and common Git gate."""

    def __init__(
        self,
        script: Path,
        *,
        workspace: Path,
        governance_repo: str,
        checkout: Path,
        timeout=120,
        environment=None,
    ):
        self.script = Path(script).resolve()
        self.workspace = Path(workspace).resolve()
        self.governance_repo = governance_repo
        self.checkout = Path(checkout).resolve()
        self.timeout = timeout
        self.environment = dict(environment or {})

    def publish(self, documents, expected_base, stream_dir):
        _oid(expected_base)
        # Failed candidates remain on their own Git branches. These files are
        # reproducible from WAL + the checked base; never drain the intake here.
        with tempfile.TemporaryDirectory(
            prefix=".plan-attempt-", dir=stream_dir
        ) as temporary:
            source = Path(temporary).resolve()
            for relative, data in documents.items():
                path = source / relative
                if not relative.startswith("plan/bridge-v2/") or any(
                    part in {"..", "."} for part in Path(relative).parts
                ):
                    raise BridgeError("PUBLICATION_SCOPE", "unexpected source path")
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            manifest = {
                key: hashlib.sha256(value).hexdigest()
                for key, value in documents.items()
            }
            snapshot_id = hashlib.sha256(
                json.dumps(manifest, sort_keys=True).encode()
            ).hexdigest()
            env = {
                **_git_environment(),
                **self.environment,
                "IWE_WORKSPACE": str(self.workspace),
                "IWE_GOVERNANCE_REPO": self.governance_repo,
                "LEDGER_PUBLISH_CHECKOUT": str(self.checkout),
            }
            process = subprocess.Popen(
                [
                    "bash",
                    str(self.script),
                    "--source-ledger-dir",
                    str(source),
                    "--expected-base",
                    expected_base,
                ],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            try:
                stdout, _ = process.communicate(timeout=self.timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
                return PublishResult("push_unknown")
            if process.returncode == 31:
                return PublishResult("base_changed")
            if process.returncode != 0:
                return PublishResult("push_unknown")
            if len(stdout) > 16384:
                raise BridgeError(
                    "MALFORMED_RECEIPT", "publisher receipt exceeds limit"
                )
            lines = stdout.splitlines()
            try:
                if len(lines) != 1 or not lines[0].startswith(
                    b"PLAN_PUBLICATION_RECEIPT "
                ):
                    raise ValueError("expected exactly one plan receipt")
                receipt = _json(lines[0].split(b" ", 1)[1])
                if (
                    set(receipt)
                    != {
                        "schema",
                        "state",
                        "reason",
                        "expected_base",
                        "candidate_oid",
                        "origin_oid",
                        "snapshot_id",
                    }
                    or receipt["schema"] != "plan-publication-receipt/1"
                    or receipt["state"] != "published"
                    or receipt["reason"] != "exact_commit_verified"
                    or receipt["expected_base"] != expected_base
                    or receipt["snapshot_id"] != snapshot_id
                ):
                    raise ValueError("receipt binding mismatch")
                _oid(receipt["candidate_oid"])
                _oid(receipt["origin_oid"])
            except (ValueError, TypeError, KeyError, RecursionError) as exc:
                raise BridgeError(
                    "MALFORMED_RECEIPT", "publisher did not prove this attempt"
                ) from exc
            return PublishResult("published", receipt)


@contextmanager
def delivery_lock(stream_dir):
    fd = os.open(
        Path(stream_dir) / ".delivery.lock",
        os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW,
        0o600,
    )
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise BridgeError(
                "LOCK_BUSY", "another delivery pass is active", stop=False
            ) from exc
        yield
    finally:
        os.close(fd)


def read_cursor(stream_dir, metadata):
    path = Path(stream_dir) / CURSOR_FILE
    if not path.exists():
        return make_cursor(metadata["delivery_id"], metadata["wal_epoch"])
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as source:
            raw = source.read(16385)
            if len(raw) > 16384:
                raise ValueError("cursor exceeds its byte limit")
            cursor = _json(raw)
    except (OSError, ValueError, RecursionError) as exc:
        raise BridgeError("MALFORMED_CURSOR", "cursor cannot be decoded") from exc
    validate_cursor(cursor)
    if any(cursor[key] != metadata[key] for key in ("delivery_id", "wal_epoch")):
        raise BridgeError("ADDRESS_CONFLICT", "cursor belongs to another intake")
    return cursor


def _write_cursor(stream_dir, cursor):
    validate_cursor(cursor)
    with tempfile.NamedTemporaryFile(
        dir=stream_dir, prefix=".cursor-", delete=False
    ) as output:
        temporary = Path(output.name)
        try:
            output.write(json.dumps(cursor, sort_keys=True).encode())
            output.flush()
            os.fsync(output.fileno())
            os.replace(temporary, Path(stream_dir) / CURSOR_FILE)
            wal.sync_directory(Path(stream_dir))
        finally:
            temporary.unlink(missing_ok=True)


def _check_snapshot(records, metadata, cursor, current, reader):
    if cursor["confirmed_seq"] > len(records):
        raise BridgeError(
            "CONFIRMED_RECORD_LOST", "WAL is shorter than its confirmed prefix"
        )
    check_confirmation_ancestry(cursor, current.origin.commit, reader.is_ancestor)
    local = {
        _address(record["address"]): (
            record["request"]["event_id"],
            record["request_digest"],
        )
        for record in records
    }
    for address, identity in current.addresses.items():
        if address[0] == metadata["delivery_id"] and local.get(address) != identity:
            raise BridgeError(
                "CONFIRMED_RECORD_LOST",
                "published own address is missing or differs in WAL",
            )
    for record in records:
        event_id, digest = record["request"]["event_id"], record["request_digest"]
        if (
            event_id in current.origin.requests
            and current.origin.requests[event_id] != digest
        ):
            raise BridgeError(
                "REQUEST_DIGEST_CONFLICT", "WAL request differs from origin"
            )
    if cursor["confirmed_seq"]:
        previous = reader.read(cursor["confirmation_commit"])
        _check_preserved(previous, current)
        for record in records[: cursor["confirmed_seq"]]:
            event_id = record["request"]["event_id"]
            address = _address(record["address"])
            identity = (event_id, record["request_digest"])
            before, after = (
                previous.origin.decisions.get(event_id),
                current.origin.decisions.get(event_id),
            )
            if (
                before is None
                or not _same_json(before, after)
                or current.origin.requests.get(event_id) != identity[1]
                or current.addresses.get(address) != identity
                or previous.addresses.get(address) != identity
            ):
                raise BridgeError(
                    "CONFIRMED_RECORD_LOST",
                    "confirmed request/decision/address changed or disappeared",
                )


def _confirmed(records, current):
    requests = {
        record["address"]["intake_seq"]: record["request"]
        for record in records
        if current.addresses.get(_address(record["address"]))
        == (record["request"]["event_id"], record["request_digest"])
    }
    return confirm_decisions(requests, current.origin.decisions, current.origin)


def _check_preserved(previous, current):
    for before, after in (
        (previous.requests, current.requests),
        (previous.origin.decisions, current.origin.decisions),
        (previous.addresses, current.addresses),
    ):
        if any(not _same_json(after.get(key), value) for key, value in before.items()):
            raise BridgeError(
                "CONFIRMED_RECORD_LOST",
                "published records changed after the checked base",
            )


def deliver_once(
    stream_dir: Path,
    *,
    reader: GitPlanReader,
    publisher: LedgerPublisher,
    verifier=None,
    trusted_context=None,
    validator_factory: Callable | None = None,
    now=None,
    batch_size=MAX_BATCH_RECORDS,
):
    """One locked pass; no internal retry and no cursor write on unknown outcome."""
    if type(batch_size) is not int or not 1 <= batch_size <= MAX_BATCH_RECORDS:
        raise BridgeError("INVALID_BATCH_BOUND", "batch must contain 1..32 records")
    stream_dir = Path(stream_dir).resolve()
    with delivery_lock(stream_dir):
        metadata = intake.read_metadata(stream_dir)
        records = intake.read_intake(stream_dir)
        for record in records:
            intake.verify_record(
                record, trusted_context=trusted_context, verifier=verifier
            )
        cursor = read_cursor(stream_dir, metadata)
        current = reader.fresh()
        _check_snapshot(records, metadata, cursor, current, reader)
        pending = records[cursor["confirmed_seq"] :]
        oldest_age = 0
        if pending:
            timestamp = datetime.fromisoformat(
                pending[0]["registered_at"].replace("Z", "+00:00")
            )
            oldest_age = max(
                0, ((now or datetime.now(timezone.utc)) - timestamp).total_seconds()
            )
        batch = pending[:batch_size]
        undecided = [
            record["request"]
            for record in batch
            if record["request"]["event_id"] not in current.origin.decisions
        ]
        decisions = {
            key: dict(value) for key, value in current.origin.decisions.items()
        }
        if undecided:
            if validator_factory is None:
                raise BridgeError(
                    "VALIDATOR_UNAVAILABLE", "no admitted whole-plan validator factory"
                )
            validator = validator_factory(current.origin.commit, reader)
            rules = getattr(validator, "rules_version", None)
            if not isinstance(rules, str) or not rules:
                raise BridgeError(
                    "VALIDATOR_UNAVAILABLE", "validator does not identify current rules"
                )
            order = getattr(validator, "ordered_accepted", None)
            if (
                order is not None
                and getattr(validator, "base_commit", None) != current.origin.commit
            ):
                raise BridgeError(
                    "VALIDATOR_BASE_MISMATCH",
                    "publication order came from another base",
                )
            _, proposals = resolve_race(
                [record["request"] for record in batch],
                current.view(rules, ordered_accepted=order),
                current.origin,
                validator=validator,
            )
            decisions.update({item["event_id"]: item for item in proposals})
        documents = publication_documents(batch, decisions, current)
        state = "confirmed"
        if documents:
            result = publisher.publish(documents, current.origin.commit, stream_dir)
            if result.state != "published":
                return dict(
                    state=result.state,
                    confirmed_seq=cursor["confirmed_seq"],
                    oldest_age_seconds=oldest_age,
                    overdue=oldest_age > OVERDUE_SECONDS,
                )
            refreshed = reader.fresh()
            _check_snapshot(records, metadata, cursor, refreshed, reader)
            receipt = result.receipt
            if (
                receipt is None
                or reader.parents(receipt["candidate_oid"]) != (current.origin.commit,)
                or not reader.is_ancestor(
                    current.origin.commit, refreshed.origin.commit
                )
                or not reader.is_ancestor(
                    receipt["candidate_oid"], refreshed.origin.commit
                )
            ):
                raise BridgeError(
                    "UNCONFIRMED_PUBLICATION",
                    "exact candidate is absent from fresh origin",
                )
            candidate = reader.read(receipt["candidate_oid"])
            _check_preserved(current, candidate)
            _check_preserved(candidate, refreshed)
            current = refreshed
            state = "published"
        confirmed = _confirmed(records, current)
        updated = advance_cursor(cursor, confirmed, current.origin.commit)
        if updated != cursor:
            _write_cursor(stream_dir, updated)
        if updated["confirmed_seq"] < len(records) and state == "confirmed":
            state = "waiting"
        return dict(
            state=state,
            confirmed_seq=updated["confirmed_seq"],
            oldest_age_seconds=oldest_age,
            overdue=oldest_age > OVERDUE_SECONDS,
        )


def receive_and_kick(stream_dir, request, *, kick: Callable, **kwargs):
    """Receipt is durable before the immediate kick; a failed kick keeps it queued."""
    receipt = intake.receive_v2(Path(stream_dir), request, **kwargs)
    try:
        kick()
    except Exception:
        _LOG.warning(
            "plan delivery kick failed; durable intake awaits the independent timer"
        )
    return receipt
