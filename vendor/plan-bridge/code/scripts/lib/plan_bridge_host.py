"""Trusted host adapter for the plan-event bridge (WP-561 Ф55, contracts П1-П7).

Loaded by scripts/plan-event-bridge.py through create_host_adapter(). Everything
here fails closed: a missing or unsafe host file, a history the order cannot be
read from, or a rules hash the pilot has not approved stops the stream.

Trust boundary (К12, DR-06 "Контракт host-adapter"): the key, the host config
and the approved-rules file must belong to a host-service uid that is NOT an
agent uid. The config path is fixed in this module, so neither an environment
variable nor a CLI argument redirects it. That holds only while this module, its
sibling modules and the interpreter are not writable by agents either:
create_host_adapter() checks that (check_code_ownership) and refuses to start
otherwise.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import hmac
import json
import os
from pathlib import Path
import stat
import sys

import yaml

import plan_event_bridge as bridge
from plan_bridge_allocation import AllocationPlanValidator, _project_checked_history
from plan_bridge_decisions import BridgeError

DEFAULT_CONFIG_PATH = Path("/etc/iwe-plan-bridge/host.json")
DEFAULT_TRUSTED_UIDS = (0,)
CONFIG_SCHEMA = "plan-bridge-host/1"
PROOF_SCHEME = "hmac-sha256/1"
RULES_PREFIX = "plan-rules/1:"
MIN_KEY_BYTES = 32
MAX_HISTORY_COMMITS = 5000
MAX_JOURNAL_FILE_BYTES = bridge.MAX_PUBLICATION_FILE_BYTES
MAX_FILES_PER_COMMIT = 4 * bridge.MAX_BATCH_RECORDS
_CODE_MODULES = (
    "plan_bridge_host",
    "plan_event_bridge",
    "plan_event_intake",
    "plan_event_wal",
    "plan_bridge_decisions",
    "plan_bridge_allocation",
    "plan_allocation",
    "__main__",
    "yaml",
    "rfc8785",
)
_CONFIG_FIELDS = frozenset(
    {
        "schema",
        "host_id",
        "key_path",
        "approved_rules_path",
        "agent_uids",
        "rules_paths",
        "producers_path",
        "limits_path",
        "intra_commit_order_trusted",
        "code_root",
        "code_paths",
    }
)
_ACTIVE_STATES = frozenset({"confirmed", "started"})


class HostAdapterError(Exception):
    """The host adapter could not prove what it is asked to vouch for."""


def _secure_file(path: Path, trusted_uids, *, private: bool):
    """Regular, non-symlink file owned by a trusted uid; private => no group/world."""
    try:
        info = os.lstat(path)
    except OSError as exc:
        raise HostAdapterError(f"host file unavailable: {path}") from exc
    if not stat.S_ISREG(info.st_mode):
        raise HostAdapterError(f"host file is not a regular file: {path}")
    if info.st_uid not in trusted_uids:
        raise HostAdapterError(f"host file has an untrusted owner: {path}")
    forbidden = 0o077 if private else 0o022
    if info.st_mode & forbidden:
        raise HostAdapterError(f"host file mode is too open: {path}")
    return info


def _trusted_directory(directory, owners):
    info = os.lstat(directory)
    sticky = info.st_mode & stat.S_ISVTX
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid not in owners
        or (info.st_mode & 0o022 and not sticky)
    ):
        raise HostAdapterError(f"host directory is not trusted: {directory}")


def _secure_parent(path: Path, trusted_uids):
    """Every directory above the file must be trusted, before and after symlinks.

    A symlink is accepted only when a trusted owner (or root) made it; the
    directories it leads through are checked as well.
    """
    owners = {0, *trusted_uids}
    absolute = Path(os.path.abspath(path))
    for directory in absolute.parents:
        info = os.lstat(directory)
        if stat.S_ISLNK(info.st_mode):
            if info.st_uid not in owners:
                raise HostAdapterError(f"host symlink is not trusted: {directory}")
        else:
            _trusted_directory(directory, owners)
    for directory in Path(os.path.realpath(path)).parents:
        _trusted_directory(directory, owners)


@dataclass(frozen=True)
class HostConfig:
    host_id: str
    key_path: Path
    approved_rules_path: Path
    agent_uids: frozenset
    rules_paths: tuple
    producers_path: str
    limits_path: str
    intra_commit_order_trusted: bool
    code_root: Path
    code_paths: tuple


def load_host_config(path=DEFAULT_CONFIG_PATH, trusted_uids=DEFAULT_TRUSTED_UIDS):
    path = Path(path)
    _secure_parent(path, trusted_uids)
    _secure_file(path, trusted_uids, private=False)
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise HostAdapterError("host config is not valid JSON") from exc
    if (
        not isinstance(raw, dict)
        or set(raw) != _CONFIG_FIELDS
        or raw["schema"] != CONFIG_SCHEMA
    ):
        raise HostAdapterError("host config has unexpected fields or schema")
    texts = (
        "host_id",
        "key_path",
        "approved_rules_path",
        "producers_path",
        "limits_path",
    )
    if not all(isinstance(raw[name], str) and raw[name] for name in texts):
        raise HostAdapterError("host config text fields must be non-empty strings")
    uids, rules = raw["agent_uids"], raw["rules_paths"]
    if not (
        isinstance(uids, list)
        and uids
        and all(type(uid) is int and uid >= 0 for uid in uids)
    ):
        raise HostAdapterError("agent_uids must list at least one uid")
    if not (
        isinstance(rules, list)
        and rules
        and len(set(rules)) == len(rules)
        and all(isinstance(item, str) and item for item in rules)
    ):
        raise HostAdapterError("rules_paths must be unique non-empty strings")
    for name in ("producers_path", "limits_path"):
        if raw[name] not in rules:
            raise HostAdapterError(f"{name} must be listed in rules_paths")
    if type(raw["intra_commit_order_trusted"]) is not bool:
        raise HostAdapterError("intra_commit_order_trusted must be a boolean")
    code = raw["code_paths"]
    if not (
        isinstance(code, list)
        and code
        and len(set(code)) == len(code)
        and set(code) <= set(rules)
    ):
        raise HostAdapterError("code_paths must be unique and listed in rules_paths")
    if not (isinstance(raw["code_root"], str) and Path(raw["code_root"]).is_absolute()):
        raise HostAdapterError("code_root must be an absolute path")
    return HostConfig(
        raw["host_id"],
        Path(raw["key_path"]),
        Path(raw["approved_rules_path"]),
        frozenset(uids),
        tuple(sorted(rules)),
        raw["producers_path"],
        raw["limits_path"],
        raw["intra_commit_order_trusted"],
        Path(raw["code_root"]),
        tuple(sorted(code)),
    )


def _load_key(config: HostConfig, trusted_uids):
    """The key must belong to the uid running this process and to no agent uid."""
    owner = os.geteuid()
    if owner in config.agent_uids:
        raise HostAdapterError("process runs under an agent uid")
    _secure_parent(config.key_path, (owner, *trusted_uids))
    _secure_file(config.key_path, (owner,), private=True)
    key = config.key_path.read_bytes()
    if len(key) < MIN_KEY_BYTES:
        raise HostAdapterError("producer key is too short")
    return key


def deployed_code_matches_base(reader, commit, code_root, code_paths):
    """The code that runs must be byte-identical to the Git objects of the base.

    Hashing the rules in Git proves nothing if the module executed from disk is
    another file: each deployed file is hashed the way Git hashes a blob and
    compared with the blob recorded at the base.
    """
    for path in sorted(code_paths):
        _, oid = _blob_at(reader, commit, path)
        deployed = Path(code_root) / path
        try:
            info = os.lstat(deployed)
            if not stat.S_ISREG(info.st_mode):
                raise OSError("not a regular file")
            data = deployed.read_bytes()
        except OSError as exc:
            raise BridgeError(
                "CODE_NOT_AT_BASE", f"deployed code is unreadable: {path}"
            ) from exc
        algorithm = hashlib.sha1 if len(oid) == 40 else hashlib.sha256
        digest = algorithm(b"blob %d\0" % len(data) + data).hexdigest()
        if digest != oid:
            raise BridgeError(
                "CODE_NOT_AT_BASE", f"deployed code differs from the base: {path}"
            )


def _runtime_code_paths():
    paths = [os.path.realpath(sys.executable)]
    for name in _CODE_MODULES:
        location = getattr(sys.modules.get(name), "__file__", None)
        if location:
            paths.append(location)
    return paths


def check_code_ownership(paths, agent_uids):
    """The code that holds the key must not be writable by an agent uid.

    Without this the uid split of key and config proves nothing: an agent could
    edit the module the service runs. Each file and every directory above it
    must be owned by a non-agent uid and closed to group and world writes.
    """
    for path in paths:
        resolved = Path(os.path.realpath(path))
        for target in (resolved, *resolved.parents):
            info = os.lstat(target)
            sticky = info.st_mode & stat.S_ISVTX
            if info.st_uid in agent_uids or (info.st_mode & 0o022 and not sticky):
                raise HostAdapterError(f"code is writable by an agent: {target}")


@dataclass(frozen=True)
class ChannelContext:
    """Meant to be built only by the trusted receiver, after it identified the caller.

    The receiver is not written yet, and nothing here stops another caller from
    constructing one: its process boundary is what would make it trustworthy.
    """

    host_id: str
    admitted_producers: frozenset


def _mac_message(host_id, producer_id, request_digest):
    return json.dumps(
        [PROOF_SCHEME, host_id, producer_id, request_digest],
        ensure_ascii=True,
        separators=(",", ":"),
    ).encode()


class HmacProducerVerifier:
    """П1. The proof is re-derived from the stored proof itself, never echoed.

    Issuing and checking are told apart only by `proof`: a context with admitted
    producers must never be handed to the delivery side.
    """

    def __init__(self, key: bytes, host_id: str):
        self._key = key
        self.host_id = host_id

    def _mac(self, host_id, producer_id, request_digest):
        message = _mac_message(host_id, producer_id, request_digest)
        return hmac.new(self._key, message, hashlib.sha256).hexdigest()

    def verify(self, *, producer_id, request_digest, trusted_context, proof=None):
        if proof is None:
            if (
                not isinstance(trusted_context, ChannelContext)
                or trusted_context.host_id != self.host_id
                or producer_id not in trusted_context.admitted_producers
            ):
                raise HostAdapterError("producer is not admitted on this channel")
            return dict(
                scheme=PROOF_SCHEME,
                host_id=self.host_id,
                producer_id=producer_id,
                request_digest=request_digest,
                mac=self._mac(self.host_id, producer_id, request_digest),
            )
        fields = {"scheme", "host_id", "producer_id", "request_digest", "mac"}
        if not isinstance(proof, dict) or set(proof) != fields:
            raise HostAdapterError("stored proof has unexpected fields")
        if proof["scheme"] != PROOF_SCHEME or proof["host_id"] != self.host_id:
            raise HostAdapterError("stored proof is from another scheme or host")
        if not all(isinstance(proof[name], str) for name in fields):
            raise HostAdapterError("stored proof fields must be text")
        expected = self._mac(
            proof["host_id"], proof["producer_id"], proof["request_digest"]
        )
        if not hmac.compare_digest(expected, proof["mac"]):
            raise HostAdapterError("stored proof does not verify")
        if (
            proof["producer_id"] != producer_id
            or proof["request_digest"] != request_digest
        ):
            raise HostAdapterError("stored proof belongs to another request")
        return dict(proof)


def _blob_at(reader, commit, path):
    """Return (mode, oid) of a regular blob at commit, or stop."""
    listing = reader._git("ls-tree", "-z", commit, "--", path).stdout.split(b"\0")
    entries = [item for item in listing if item]
    if len(entries) != 1:
        raise BridgeError("RULES_UNAVAILABLE", f"rules file missing at base: {path}")
    header, name = entries[0].split(b"\t", 1)
    mode, _, oid = header.split()
    if name.decode() != path or mode not in (b"100644", b"100755"):
        raise BridgeError(
            "RULES_UNAVAILABLE", f"rules entry is not a plain file: {path}"
        )
    return mode.decode(), oid.decode()


def rules_version_at(reader, commit, rules_paths):
    """П3: a hash of exact Git objects of the base; the working copy is never read."""
    parts = []
    for path in sorted(rules_paths):
        mode, oid = _blob_at(reader, commit, path)
        parts.append([path, mode, oid])
    digest = hashlib.sha256(
        json.dumps(parts, ensure_ascii=True, separators=(",", ":")).encode()
    ).hexdigest()
    return RULES_PREFIX + digest


def _read_blob_json(reader, commit, path, schema):
    _, oid = _blob_at(reader, commit, path)
    try:
        value = json.loads(reader._git("cat-file", "blob", oid).stdout.decode())
    except ValueError as exc:
        raise BridgeError("RULES_UNAVAILABLE", f"{path} is not valid JSON") from exc
    if not isinstance(value, dict) or value.get("schema") != schema:
        raise BridgeError("RULES_UNAVAILABLE", f"{path} has an unexpected schema")
    return value


def load_limits(reader, commit, path):
    """П7. Missing or invalid limits stop the stream; no model capacity is used."""
    value = _read_blob_json(reader, commit, path, "plan-limits/1")
    limits = {"max_active_allocations": value.get("max_active_allocations")}
    if set(value) != {"schema", *limits} or not all(
        type(item) is int and item >= 1 for item in limits.values()
    ):
        raise BridgeError("BUDGET_VALIDATOR_UNAVAILABLE", "plan limits are invalid")
    return limits


def load_producers(reader, commit, path):
    value = _read_blob_json(reader, commit, path, "plan-producers/1")
    producers = value.get("producers")
    if (
        set(value) != {"schema", "producers"}
        or not isinstance(producers, dict)
        or not producers
    ):
        raise BridgeError(
            "PRODUCER_REGISTRY_UNAVAILABLE", "producer registry is empty or invalid"
        )
    for name, entry in producers.items():
        types = entry.get("event_types") if isinstance(entry, dict) else None
        if not (
            isinstance(name, str)
            and name
            and isinstance(types, list)
            and types
            and all(isinstance(item, str) and item for item in types)
        ):
            raise BridgeError(
                "PRODUCER_REGISTRY_UNAVAILABLE", "producer registry entry is invalid"
            )
    return {name: frozenset(entry["event_types"]) for name, entry in producers.items()}


def read_approved_rules(path, trusted_uids):
    path = Path(path)
    _secure_parent(path, trusted_uids)
    _secure_file(path, trusted_uids, private=False)
    text = path.read_text(encoding="utf-8").strip()
    if not text or "\n" in text:
        raise BridgeError(
            "VALIDATOR_UNAVAILABLE", "approved rules file must hold one line"
        )
    return text


def _freeze(value):
    return json.dumps(value, sort_keys=True, default=str)


def _check_history_is_trustworthy(reader):
    if reader._git("rev-parse", "--is-shallow-repository").stdout.strip() != b"false":
        raise BridgeError(
            "HISTORY_UNSAFE", "shallow history cannot prove publication order"
        )
    if reader._git("for-each-ref", "refs/replace").stdout.strip():
        raise BridgeError("HISTORY_UNSAFE", "replace refs are present")


def _load_bounded(raw):
    """Decode one historical journal file under the same bounds as the tip reader."""
    if len(raw) > MAX_JOURNAL_FILE_BYTES:
        raise BridgeError("MALFORMED_JOURNAL", "journal file exceeds admitted size")
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
        events = yaml.load(raw, Loader=bridge._JournalLoader)["events"]
        return [
            (event["kind"], event["data"]["event_id"], event["data"])
            for event in events
            if event["kind"] in ("plan_decision", "plan_delivery")
        ]
    except (yaml.YAMLError, ValueError, KeyError, TypeError, RecursionError) as exc:
        raise BridgeError(
            "MALFORMED_JOURNAL", "journal file cannot be decoded"
        ) from exc


def _blob_events(reader, revision, name):
    return _load_bounded(reader._git("cat-file", "blob", f"{revision}:{name}").stdout)


def _commit_events(reader, commit):
    """Accepted decisions and delivery addresses this commit added (rename-safe).

    A file that was only modified contributes just the records absent from its
    previous version, so appending to an existing file counts as new records.
    """
    fields = reader._git(
        "diff-tree",
        "--root",
        "--no-commit-id",
        "--no-renames",
        "-r",
        "-z",
        "--diff-filter=AM",
        "--name-status",
        commit,
        "--",
        bridge.JOURNAL_PREFIX,
    ).stdout.split(b"\0")
    changes = list(zip(fields[0::2], fields[1::2]))
    if len(changes) > MAX_FILES_PER_COMMIT:
        raise BridgeError("HISTORY_UNSAFE", "commit changes too many journal files")
    accepted, addresses = [], {}
    for status, name in changes:
        name = name.decode()
        before = set()
        if status == b"M":
            before = {
                (kind, event_id, _freeze(data))
                for kind, event_id, data in _blob_events(reader, f"{commit}^", name)
            }
        for kind, event_id, data in _blob_events(reader, commit, name):
            if (kind, event_id, _freeze(data)) in before:
                continue
            if kind == "plan_decision" and data["outcome"] == "accepted":
                accepted.append(event_id)
            elif kind == "plan_delivery":
                address = bridge._address(data["address"])
                if addresses.setdefault(event_id, address) != address:
                    raise BridgeError(
                        "ORDER_AMBIGUOUS", "one record has two delivery addresses"
                    )
    return accepted, addresses


def publication_order(reader, base_commit, *, trust_intra_commit_order):
    """П4/П5: order accepted event IDs by first appearance in history, else stop.

    Order inside one commit comes from delivery sequence numbers, which are only
    as trustworthy as the closed direct-write path (П6): until the host config
    says so, a commit that adds several accepted records stops the stream.
    """
    _check_history_is_trustworthy(reader)
    lines = (
        reader._git(
            "rev-list",
            "--full-history",
            "--simplify-merges",
            "--parents",
            "--reverse",
            "--topo-order",
            base_commit,
            "--",
            bridge.JOURNAL_PREFIX,
        )
        .stdout.decode()
        .splitlines()
    )
    if len(lines) > MAX_HISTORY_COMMITS:
        raise BridgeError("HISTORY_UNSAFE", "journal history exceeds admitted bound")
    seen, order = set(), []
    for line in lines:
        commit, *parents = line.split()
        if len(parents) > 1:
            raise BridgeError(
                "HISTORY_UNSAFE", "journal changed on both sides of a merge"
            )
        try:
            accepted, addresses = _commit_events(reader, commit)
        except BridgeError as exc:
            if exc.code != "GIT_UNAVAILABLE":
                raise
            raise BridgeError(
                "HISTORY_UNSAFE", "a history object is unreadable"
            ) from exc
        fresh = [item for item in dict.fromkeys(accepted) if item not in seen]
        if len(fresh) > 1:
            fresh = _order_inside_commit(fresh, addresses, trust_intra_commit_order)
        order.extend(fresh)
        seen.update(fresh)
    return tuple(order)


def _order_inside_commit(fresh, addresses, trusted):
    if not trusted:
        raise BridgeError(
            "ORDER_AMBIGUOUS", "order inside one commit is not trusted before П6"
        )
    if any(item not in addresses for item in fresh):
        raise BridgeError("ORDER_AMBIGUOUS", "no delivery address for new records")
    if len({addresses[item][0] for item in fresh}) != 1:
        raise BridgeError("ORDER_AMBIGUOUS", "several deliveries in one commit")
    keys = [addresses[item][1:] for item in fresh]
    if len(set(keys)) != len(keys):
        raise BridgeError("ORDER_AMBIGUOUS", "duplicate delivery address")
    return sorted(fresh, key=lambda item: addresses[item][1:])


class HostPlanValidator:
    """Producer registry plus DR-03 transitions plus the plan limits, on one base."""

    def __init__(self, rules_version, producers, limits):
        self.rules_version = rules_version
        self._producers = producers

        def budget(candidate, view):
            # Plan integrity (DR-03 transitions) is checked by the inner validator;
            # capacity is the number of resources currently held. Requests that do
            # not claim a resource are not capacity-limited (DR-06, pilot's choice).
            if candidate["event_type"] != "allocation_confirmed":
                return True
            active = sum(
                state.state in _ACTIVE_STATES
                for state in _project_checked_history(view).values()
            )
            return active < limits["max_active_allocations"]

        self._inner = AllocationPlanValidator(
            rules_version=rules_version, whole_plan_budget=budget
        )

    def validate(self, request, view):
        allowed = self._producers.get(request["producer_id"])
        if allowed is None or request["event_type"] not in allowed:
            raise BridgeError(
                "PRODUCER_NOT_ADMITTED", "producer or event type is not in the registry"
            )
        return self._inner.validate(request, view)


@dataclass(frozen=True)
class HostAdapter:
    verifier: HmacProducerVerifier
    trusted_context: ChannelContext
    validator_factory: object


def create_host_adapter(
    config_path=DEFAULT_CONFIG_PATH,
    trusted_uids=DEFAULT_TRUSTED_UIDS,
    ownership_paths=None,
):
    config = load_host_config(config_path, trusted_uids)
    key = _load_key(config, trusted_uids)
    if ownership_paths is None:
        deployed = [config.code_root / item for item in config.code_paths]
        ownership_paths = [*_runtime_code_paths(), *deployed]
    check_code_ownership(ownership_paths, config.agent_uids)

    def validator_factory(base_commit, reader):
        deployed_code_matches_base(
            reader, base_commit, config.code_root, config.code_paths
        )
        version = rules_version_at(reader, base_commit, config.rules_paths)
        approved = read_approved_rules(config.approved_rules_path, trusted_uids)
        if version != approved:
            raise BridgeError(
                "VALIDATOR_UNAVAILABLE",
                "rules at the base are not the approved version",
            )
        validator = HostPlanValidator(
            version,
            load_producers(reader, base_commit, config.producers_path),
            load_limits(reader, base_commit, config.limits_path),
        )
        return bridge.PinnedPlanValidator(
            base_commit,
            validator,
            publication_order(
                reader,
                base_commit,
                trust_intra_commit_order=config.intra_commit_order_trusted,
            ),
        )

    return HostAdapter(
        HmacProducerVerifier(key, config.host_id),
        ChannelContext(config.host_id, frozenset()),
        validator_factory,
    )


def _step(results, name, action):
    try:
        detail = action()
    except (HostAdapterError, BridgeError, OSError) as exc:
        results.append({"check": name, "ok": False, "detail": str(exc)})
        return None
    results.append({"check": name, "ok": True, "detail": detail or ""})
    return detail


def readiness_report(
    config_path=DEFAULT_CONFIG_PATH,
    trusted_uids=DEFAULT_TRUSTED_UIDS,
    repository=None,
    base=None,
):
    """Read-only list of checks a host must pass before the bridge may start.

    Mints no proof and publishes nothing. With a repository and a base revision
    it also checks the Git-side files (rules hash, deployed code, registry,
    limits, publication order).
    """
    results = []
    config = _step(
        results, "host config", lambda: load_host_config(config_path, trusted_uids)
    )
    if config is None:
        return results
    _step(results, "producer key", lambda: bool(_load_key(config, trusted_uids)))
    _step(
        results,
        "code not writable by agents",
        lambda: check_code_ownership(
            [
                *_runtime_code_paths(),
                *[config.code_root / item for item in config.code_paths],
            ],
            config.agent_uids,
        ),
    )
    approved = _step(
        results,
        "approved rules version",
        lambda: read_approved_rules(config.approved_rules_path, trusted_uids),
    )
    if repository is None or base is None:
        return results
    reader = bridge.GitPlanReader(repository)
    _step(
        results,
        "deployed code equals base",
        lambda: deployed_code_matches_base(
            reader, base, config.code_root, config.code_paths
        ),
    )
    version = _step(
        results,
        "rules hash at base",
        lambda: rules_version_at(reader, base, config.rules_paths),
    )
    if version is not None and approved is not None and version != approved:
        results.append(
            {"check": "rules hash is approved", "ok": False, "detail": version}
        )
    _step(
        results,
        "producer registry",
        lambda: sorted(load_producers(reader, base, config.producers_path)),
    )
    _step(
        results,
        "plan limits",
        lambda: load_limits(reader, base, config.limits_path),
    )
    _step(
        results,
        "publication order",
        lambda: len(
            publication_order(
                reader,
                base,
                trust_intra_commit_order=config.intra_commit_order_trusted,
            )
        ),
    )
    return results


def _main(argv):
    import argparse

    parser = argparse.ArgumentParser(description="Host readiness report (read-only)")
    parser.add_argument("--readiness", action="store_true", required=True)
    parser.add_argument("--repository")
    parser.add_argument("--base")
    arguments = parser.parse_args(argv)
    results = readiness_report(repository=arguments.repository, base=arguments.base)
    for item in results:
        print(json.dumps(item, ensure_ascii=False, sort_keys=True))
    return 0 if all(item["ok"] for item in results) else 1


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
