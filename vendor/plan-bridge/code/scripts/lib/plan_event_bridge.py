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
# A pass waits this long for the queue lock between intake writes instead of
# giving up at the first busy moment (steady intake starved delivery, WP-530 Ф85).
READ_LOCK_WAIT_SECONDS = 10
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


# libyaml is several times faster on the full-journal scan each pass makes
# (WP-530 Ф85, К13 measurement 09.11); constructors below are the same.
_SAFE_LOADER = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
# Same for writing: the pure-Python emitter took ~1.8 s per 32 large records
# (WP-530 Ф85, package B); readers parse the YAML, the byte layout is not a contract.
_SAFE_DUMPER = getattr(yaml, "CSafeDumper", yaml.SafeDumper)


class _JournalLoader(_SAFE_LOADER):
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
        # Every request here passed validate_request when the plan was built
        # (request_digest binds it to the published digest).
        return PlanView.from_checked_requests(
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

    def check_history(self, view):
        check = getattr(self.validator, "check_history", None)
        if check is not None:
            check(view)

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


def decode_journal_document(raw):
    """YAML bytes -> plain data, with the structural bounds of the journal."""
    try:
        depth = 0
        for count, node in enumerate(yaml.parse(raw, Loader=_SAFE_LOADER), 1):
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
        return yaml.load(raw, Loader=_JournalLoader)
    except (yaml.YAMLError, ValueError, TypeError, RecursionError) as exc:
        raise BridgeError("MALFORMED_JOURNAL", "journal cannot be decoded") from exc


def parse_journal(commit, documents):
    """Parse the entire v2 namespace before making any decision or confirmation."""
    return build_published_plan(
        commit, [decode_journal_document(raw) for raw in documents]
    )


@dataclass(frozen=True)
class _DocumentEntries:
    """One journal document checked on its own, in event order.

    entries holds (kind, key, value, request digest or None). A document that
    fails its own checks keeps the entries before the failure and the error, so
    a merge raises conflicts with earlier documents first, exactly where the
    single-pass check used to stop.
    """

    entries: tuple
    error: Exception | None


def _check_request_event(data):
    if (
        set(data) != {"schema_version", "event_id", "request_digest", "request"}
        or type(data["schema_version"]) is not int
        or data["schema_version"] != 2
    ):
        raise BridgeError("INCOMPATIBLE_VERSION", "unknown request record schema")
    request = data["request"]
    digest = intake.request_digest(request)
    if request["event_id"] != data["event_id"] or digest != data["request_digest"]:
        raise BridgeError(
            "REQUEST_DIGEST_CONFLICT", "published request binding mismatch"
        )
    return ("request", data["event_id"], request, digest)


def _check_decision_event(data):
    validate_decision(data)
    _oid(data["base_commit"])
    if not data["final"]:
        raise BridgeError("MALFORMED_DECISION", "journal contains a nonfinal proposal")
    return ("decision", data["event_id"], data, None)


def _check_delivery_event(data):
    if (
        set(data) != {"schema_version", "event_id", "request_digest", "address"}
        or type(data["schema_version"]) is not int
        or data["schema_version"] != 1
    ):
        raise BridgeError("INCOMPATIBLE_VERSION", "unknown delivery record schema")
    return (
        "delivery",
        _address(data["address"]),
        (data["event_id"], data["request_digest"]),
        None,
    )


_EVENT_CHECKS = {
    "plan_request": _check_request_event,
    "plan_decision": _check_decision_event,
    "plan_delivery": _check_delivery_event,
}


def _document_events(document):
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
        check = _EVENT_CHECKS.get(kind)
        if check is None:
            raise BridgeError("INCOMPATIBLE_VERSION", "unknown bridge event kind")
        yield check(data)


def _document_entries(document):
    """Check one decoded document; the first failure is kept, not raised.

    Any exception counts (a malformed request raises the intake's own error
    types): it is re-raised by the merge at the same point in event order.
    """
    entries = []
    try:
        for entry in _document_events(document):
            entries.append(entry)
    except Exception as exc:  # re-raised by _build_from_entries, never dropped
        return _DocumentEntries(tuple(entries), exc)
    return _DocumentEntries(tuple(entries), None)


_ENTRY_TARGET = {
    "request": "REQUEST_DIGEST_CONFLICT",
    "decision": "DECISION_CONFLICT",
    "delivery": "ADDRESS_CONFLICT",
}


def build_published_plan(commit, decoded):
    """Validate decoded journal documents into a fresh PublishedPlan."""
    return _build_from_entries(commit, [_document_entries(item) for item in decoded])


def _build_from_entries(commit, checked):
    """Merge per-document entries in document order into a PublishedPlan.

    The caller owns the values in checked: they become the plan's contents.
    """
    _oid(commit)
    found = {"request": {}, "decision": {}, "delivery": {}}
    digests = {}
    for document in checked:
        for kind, key, value, digest in document.entries:
            _insert_unique(found[kind], key, value, _ENTRY_TARGET[kind])
            if digest is not None:
                digests[key] = digest
        if document.error is not None:
            raise document.error
    requests, decisions, addresses = (
        found["request"],
        found["decision"],
        found["delivery"],
    )
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


@dataclass(frozen=True)
class _CachedBlob:
    size: int
    decoded: object


# History files a walk loads in one batch; past this they are read one by one,
# so a long history does not hold its whole decoded content at once.
_PREFETCH_BYTES = 32 * 1024 * 1024


def _git_evidence_unreadable():
    # Same transient class as a failed git call: the next pass retries.
    return BridgeError("GIT_UNAVAILABLE", "Git evidence could not be read", stop=False)


class GitPlanReader:
    """Read exact objects from a fresh, private fetch ref, without graph overlays."""

    def __init__(
        self, repository: Path, *, timeout=45, max_journal_bytes=256 * 1024 * 1024
    ):
        self.repository = Path(repository).resolve()
        self.timeout = timeout
        self.max_journal_bytes = max_journal_bytes
        # A pass reads several commits that share almost all journal files, and
        # the history walk reads them again; a blob oid names immutable content,
        # so each file is decoded and checked once per reader (WP-530 Ф85 B).
        self._blobs = {}
        self._checked = {}  # tip files only; history files are never plan-checked
        self._cached_bytes = 0
        self.cache_resets = 0
        if _SAFE_LOADER is yaml.SafeLoader:
            _LOG.warning("libyaml unavailable: journal parsing runs in pure Python")

    def _git(self, *args, check=True, stdin=None):
        try:
            result = subprocess.run(
                ["git", "-C", str(self.repository), *args],
                env=_git_environment(),
                input=stdin,
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
        return _build_from_entries(
            commit, [self._checked_copy(blob) for blob in self._journal_blobs(commit)]
        )

    def _checked_copy(self, blob):
        """One file's plan entries, owned by the caller (the cache keeps its own)."""
        checked = self._checked.get(blob)
        if checked is None:
            checked = _document_entries(self._blobs[blob].decoded)
            self._checked[blob] = checked
        if checked.error is not None:
            # Check again for a fresh exception: a cached one re-raised by every
            # read would grow its traceback and keep its frames alive.
            return _document_entries(deepcopy(self._blobs[blob].decoded))
        return _DocumentEntries(deepcopy(checked.entries), None)

    def history_document(self, blob, max_bytes):
        """Decoded journal file of a history commit, bounded per file.

        A missing object raises GIT_UNAVAILABLE (the history walk reports it as
        HISTORY_UNSAFE); a file over max_bytes is MALFORMED_JOURNAL before it is
        read or taken from the cache.
        """
        blob = blob.encode() if isinstance(blob, str) else blob
        cached = self._blobs.get(blob)
        if cached is None:
            sizes = self._sizes([blob], tolerate_missing=True)
            if sizes[0] is None:
                raise _git_evidence_unreadable()
            if sizes[0] > max_bytes:
                raise BridgeError(
                    "MALFORMED_JOURNAL", "journal file exceeds admitted size"
                )
            self._make_room(sizes[0])
            self._load([blob], sizes)
            cached = self._blobs[blob]
        elif cached.size > max_bytes:
            raise BridgeError("MALFORMED_JOURNAL", "journal file exceeds admitted size")
        return deepcopy(cached.decoded)

    def prefetch(self, blobs, max_bytes):
        """Best effort: load in one batch the files a history walk will ask for.

        Nothing here refuses. Missing, oversized (never read) and undecodable
        files, and a failed batch read, are left to history_document, which
        reports them when the walk reaches their commit, as single reads did.
        """
        wanted = list(dict.fromkeys(blob for blob in blobs if blob not in self._blobs))
        if not wanted:
            return
        try:
            sizes = self._sizes(wanted, tolerate_missing=True)
            present, total = [], 0
            for blob, size in zip(wanted, sizes):
                if size is None or size > max_bytes:
                    continue
                if total + size > _PREFETCH_BYTES:
                    break  # the rest is read file by file, in walk order
                present.append((blob, size))
                total += size
            if not present:
                return
            self._make_room(total)
            blobs = [blob for blob, _ in present]
            contents = self._contents(blobs, [size for _, size in present])
        except BridgeError as exc:
            _LOG.warning("history prefetch skipped (%s); reading per file", exc.code)
            return
        for blob, raw in zip(blobs, contents):
            try:
                decoded = decode_journal_document(raw)
            except BridgeError:
                continue  # history_document raises it when the walk reaches it
            self._remember(blob, len(raw), decoded)

    def _make_room(self, incoming):
        """Keep at most two journals' worth of files; True if the cache was reset.

        A reset only costs a re-read; the tip and one history walk fit together.
        """
        if self._cached_bytes + incoming <= 2 * self.max_journal_bytes:
            return False
        self._blobs.clear()
        self._checked.clear()
        self._cached_bytes = 0
        self.cache_resets += 1
        return True

    def _remember(self, blob, size, decoded):
        self._blobs[blob] = _CachedBlob(size, decoded)
        self._cached_bytes += size

    def _load(self, blobs, sizes):
        for blob, raw in zip(blobs, self._contents(blobs, sizes)):
            self._remember(blob, len(raw), decode_journal_document(raw))

    def _sizes(self, blobs, *, tolerate_missing=False):
        request = b"".join(blob + b"\n" for blob in blobs)
        output = self._git("cat-file", "--batch-check", stdin=request).stdout
        return self._batch_headers(output, blobs, tolerate_missing=tolerate_missing)

    def _contents(self, blobs, sizes):
        request = b"".join(blob + b"\n" for blob in blobs)
        raw = self._git("cat-file", "--batch", stdin=request).stdout
        documents, pos = [], 0
        for blob, size in zip(blobs, sizes):
            line_end = raw.find(b"\n", pos)
            if line_end < 0 or raw[pos:line_end] != b"%s blob %d" % (blob, size):
                raise _git_evidence_unreadable()
            end = line_end + 1 + size
            if raw[end : end + 1] != b"\n":
                raise _git_evidence_unreadable()
            documents.append(raw[line_end + 1 : end])
            pos = end + 1
        if pos != len(raw):
            raise _git_evidence_unreadable()
        return documents

    def _journal_blobs(self, commit):
        """Journal blob oids at commit, each decoded and checked in the cache."""
        entries = self._git(
            "ls-tree", "-r", "-z", commit, "--", JOURNAL_PREFIX
        ).stdout.split(b"\0")
        blobs = []
        for entry in entries:
            if not entry:
                continue
            header, path = entry.split(b"\t", 1)
            mode, kind, blob = header.split()
            if mode != b"100644" or kind != b"blob" or not path.endswith(b".yaml"):
                raise BridgeError("MALFORMED_JOURNAL", "unexpected journal tree entry")
            blobs.append(blob)
        if not blobs:
            return []
        # Sizes of the whole tree first, so the bound covers cached files too
        # and is enforced before any new content is read.
        sizes = self._sizes(blobs)
        if sum(sizes) > self.max_journal_bytes:
            raise BridgeError("JOURNAL_LIMIT", "journal exceeds admitted reader bound")
        # The same content under two paths is one blob: read and counted once.
        unique = dict(zip(blobs, sizes))
        uncached = {
            blob: size for blob, size in unique.items() if blob not in self._blobs
        }
        if self._make_room(sum(uncached.values())):
            uncached = unique
        load = list(uncached.items())
        if load:
            self._load([blob for blob, _ in load], [size for _, size in load])
        return blobs

    @staticmethod
    def _batch_headers(output, blobs, *, tolerate_missing=False):
        lines = output.split(b"\n")
        if len(lines) != len(blobs) + 1 or lines[-1] != b"":
            raise _git_evidence_unreadable()
        sizes = []
        for blob, line in zip(blobs, lines):
            if tolerate_missing and line == blob + b" missing":
                sizes.append(None)
                continue
            fields = line.split(b" ")
            if (
                len(fields) != 3
                or fields[0] != blob
                or fields[1] != b"blob"
                or not fields[2].isdigit()
            ):
                raise _git_evidence_unreadable()
            sizes.append(int(fields[2]))
        return sizes

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
    """Publish only a continuous decided prefix (К6): stop at the first record
    this pass has no decision for (the batch is shorter than the queue)."""
    documents = {}
    total_bytes = 0
    for record in records:
        request = record["request"]
        event_id, digest = request["event_id"], record["request_digest"]
        decision = decisions.get(event_id)
        if decision is None:
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
            data = yaml.dump(
                dict(schema="plan-events/1", scale="day", period=day, events=events),
                Dumper=_SAFE_DUMPER,
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


class GitCasPublisher:
    """Publish one candidate by compare-and-swap of main, inside the bridge itself.

    The candidate commit has the single parent B and differs from B only by the
    added journal files (every bridge record has its own file); the push
    succeeds only while origin main still equals B. A lost reply needs no recovery here: the next pass reads fresh origin and
    finds the records already published. The whole write path lives in this
    module, so it stays inside the rules version the pilot approves.
    """

    AUTHOR = ("plan-bridge", "plan-bridge@iwe.invalid")

    def __init__(self, repository: Path, *, ref="refs/heads/main", timeout=60):
        self.repository = Path(repository).resolve()
        self.ref = ref
        self.timeout = timeout

    def _git(self, *args, env=None, input=None):
        try:
            return subprocess.run(
                ["git", "-C", str(self.repository), *args],
                env={**_git_environment(), **(env or {})},
                input=input,
                capture_output=True,
                timeout=self.timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise BridgeError(
                "NO_NETWORK", "Git operation timed out", stop=False
            ) from exc

    def _checked(self, *args, env=None, input=None):
        result = self._git(*args, env=env, input=input)
        if result.returncode:
            raise BridgeError("GIT_UNAVAILABLE", f"git {args[0]} failed", stop=False)
        return result.stdout.decode().strip()

    def _check_destination(self):
        """The push must go exactly where the plan is read from."""
        fetch = self._checked("remote", "get-url", "origin")
        pushes = self._checked("remote", "get-url", "--push", "--all", "origin")
        if set(pushes.splitlines()) != {fetch}:
            raise BridgeError(
                "PUBLICATION_DESTINATION", "push and fetch URLs of origin differ"
            )

    def _candidate(self, documents, base):
        paths = {}
        for relative, data in documents.items():
            parts = Path(relative).parts
            if not relative.startswith("plan/bridge-v2/") or {"..", "."} & set(parts):
                raise BridgeError("PUBLICATION_SCOPE", "unexpected source path")
            path = "machine/ledger/" + relative
            if not self._git("cat-file", "-e", f"{base}:{path}").returncode:
                raise BridgeError("PUBLICATION_SCOPE", f"path exists at base: {path}")
            paths[path] = self._checked("hash-object", "-w", "--stdin", input=data)
        with tempfile.TemporaryDirectory(prefix="plan-index-") as temporary:
            index = {"GIT_INDEX_FILE": str(Path(temporary) / "index")}
            self._checked("read-tree", base, env=index)
            for path, blob in paths.items():
                self._checked(
                    "update-index",
                    "--add",
                    "--cacheinfo",
                    f"100644,{blob},{path}",
                    env=index,
                )
            tree = self._checked("write-tree", env=index)
        name, email = self.AUTHOR
        identity = {
            "GIT_AUTHOR_NAME": name,
            "GIT_AUTHOR_EMAIL": email,
            "GIT_COMMITTER_NAME": name,
            "GIT_COMMITTER_EMAIL": email,
        }
        candidate = self._checked(
            "commit-tree",
            tree,
            "-p",
            base,
            "-m",
            "plan-bridge: publish decided records",
            env=identity,
        )
        changes = self._checked(
            "diff-tree", "--no-renames", "--name-status", "-r", base, candidate
        ).splitlines()
        if sorted(changes) != sorted(f"A\t{path}" for path in paths):
            raise BridgeError(
                "PUBLICATION_SCOPE", "candidate changes more than records"
            )
        return candidate

    def publish(self, documents, expected_base, stream_dir):
        _oid(expected_base)
        self._check_destination()
        candidate = _oid(self._candidate(documents, expected_base))
        try:
            pushed = self._git(
                "push",
                "--porcelain",
                f"--force-with-lease={self.ref}:{expected_base}",
                "origin",
                f"{candidate}:{self.ref}",
            )
        except BridgeError:
            return PublishResult("push_unknown")
        report = pushed.stdout.decode()
        if pushed.returncode == 0:
            manifest = {
                key: hashlib.sha256(value).hexdigest()
                for key, value in documents.items()
            }
            return PublishResult(
                "published",
                dict(
                    schema="plan-publication-receipt/2",
                    expected_base=expected_base,
                    candidate_oid=candidate,
                    snapshot_id=hashlib.sha256(
                        json.dumps(manifest, sort_keys=True).encode()
                    ).hexdigest(),
                ),
            )
        # Porcelain marks the ref line with "!": a lease or fast-forward refusal
        # means origin moved; any other refusal (a hook, protection) is not ours
        # to retry blindly and is reported apart from a moved base.
        if re.search(
            r"^!\t.*\[rejected\] \((stale info|fetch first|non-fast-forward)\)",
            report,
            re.M,
        ):
            return PublishResult("base_changed")
        if re.search(r"^!\t.*\[remote rejected\]", report, re.M):
            return PublishResult("push_refused")
        return PublishResult("push_unknown")


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
    # Requests are compared by their digests (SHA256 of the same RFC 8785 bytes
    # _same_json compares): re-serializing every large request on each call was
    # a major cost of a pass at a near-full queue (WP-530 Ф85, package B).
    if any(
        current.origin.requests.get(key) != digest
        for key, digest in previous.origin.requests.items()
    ):
        raise BridgeError(
            "CONFIRMED_RECORD_LOST", "published records changed after the checked base"
        )
    for before, after in (
        (previous.origin.decisions, current.origin.decisions),
        (previous.addresses, current.addresses),
    ):
        if any(not _same_json(after.get(key), value) for key, value in before.items()):
            raise BridgeError(
                "CONFIRMED_RECORD_LOST",
                "published records changed after the checked base",
            )


def _check_batch_size(batch_size):
    if type(batch_size) is not int or not 1 <= batch_size <= MAX_BATCH_RECORDS:
        raise BridgeError("INVALID_BATCH_BOUND", "batch must contain 1..32 records")


def deliver_once(
    stream_dir: Path,
    *,
    reader: GitPlanReader,
    publisher: GitCasPublisher,
    verifier=None,
    trusted_context=None,
    validator_factory: Callable | None = None,
    now=None,
    batch_size=MAX_BATCH_RECORDS,
):
    """One locked pass; no internal retry and no cursor write on unknown outcome."""
    _check_batch_size(batch_size)
    stream_dir = Path(stream_dir).resolve()
    with delivery_lock(stream_dir):
        return deliver_locked(
            stream_dir,
            reader=reader,
            publisher=publisher,
            verifier=verifier,
            trusted_context=trusted_context,
            validator_factory=validator_factory,
            now=now,
            batch_size=batch_size,
        )


def deliver_locked(
    stream_dir: Path,
    *,
    reader: GitPlanReader,
    publisher: GitCasPublisher,
    verifier=None,
    trusted_context=None,
    validator_factory: Callable | None = None,
    now=None,
    batch_size=MAX_BATCH_RECORDS,
    observation: dict | None = None,
):
    """The pass body; the caller already holds delivery_lock(stream_dir).

    Calling deliver_once() from inside that lock would fail with LOCK_BUSY
    against the caller's own flock, so a coordinator that must act under the
    same lock (the service health file, WP-530 F85) calls this directly.
    `observation`, when given, is filled as the pass learns facts: once the
    intake and cursor are read it holds the snapshot, so the caller can still
    report the queue when the pass raises later (for example Git is down).
    """
    _check_batch_size(batch_size)
    stream_dir = Path(stream_dir).resolve()
    seen = observation if observation is not None else {}
    metadata = intake.read_metadata(stream_dir)
    records = intake.read_intake(stream_dir, wait_seconds=READ_LOCK_WAIT_SECONDS)
    for record in records:
        intake.authorize_read_record(
            record, trusted_context=trusted_context, verifier=verifier
        )
    cursor = read_cursor(stream_dir, metadata)
    seen.update(
        snapshot_at=(now or datetime.now(timezone.utc)).isoformat(),
        delivery_id=metadata["delivery_id"],
        wal_epoch=metadata["wal_epoch"],
        records=records,
        confirmed_seq_before=cursor["confirmed_seq"],
        confirmed_seq=cursor["confirmed_seq"],
        confirmed_origin_commit=cursor.get("confirmation_commit"),
    )
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
    decisions = {key: dict(value) for key, value in current.origin.decisions.items()}
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
            or not reader.is_ancestor(current.origin.commit, refreshed.origin.commit)
            or not reader.is_ancestor(receipt["candidate_oid"], refreshed.origin.commit)
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
    seen.update(
        confirmed_seq=updated["confirmed_seq"],
        confirmed_origin_commit=updated.get("confirmation_commit"),
    )
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
