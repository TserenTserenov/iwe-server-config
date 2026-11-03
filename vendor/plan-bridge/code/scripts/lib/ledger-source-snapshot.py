#!/usr/bin/env python3
"""Pin and verify an opt-in ledger/v1 source. Never acknowledge the live queue.

The manifest identifies per-file versions, not an atomic multi-file cut, domain
event identity, intake durability or permission to execute a plan decision.
Diagnostics deliberately exclude source paths and YAML values (personal data).
"""
import errno
import hashlib
import json
import math
import os
import fcntl
from contextlib import contextmanager
from pathlib import Path
import re
import runpy
import socket
import stat
import subprocess
import sys
import time
import uuid

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ledger_path import expected_schema, ledger_path_rel  # noqa: E402


DIFF = runpy.run_path(str(Path(__file__).with_name("ledger-event-diff.py")))
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
# Reviewed hook profiles live in the governance repo next to scripts/lib/;
# a clone of the repo never carries an authoritative copy (WP-484 Ф207 §7.7).
PROFILES_DIR = Path(__file__).resolve().parent.parent / "reviewed-hook-profiles"
# Registry metadata allowed to sit next to the declared hook files in a flat
# profile directory; it is never executable and never enters the hook set.
PROFILE_METADATA_FILES = {"profile.json", "smoke.sh"}
MAX_FILES = 64
MAX_FILE_BYTES = 4 * 1024 * 1024
MAX_TOTAL_BYTES = 16 * 1024 * 1024
MAX_ENTRIES = 1024
MAX_DIRECTORY_DEPTH = 16
# A day file grows by appending. The event cap bounds parse cost, not just size:
# measured 01.11.2026 on the real 30.10 file (20 415 events, 266 KiB) one
# document() call takes 1-3.3 s with the pure-Python loader, up to ~0.16 ms per
# event. 120 000 is ~6x the busiest day so far (up to ~20 s per call); the 4 MiB
# byte cap is the other bound. One publisher run parses a large destination file
# 6-8 times (check-destination, history, install, receipt, event diffs), so a few
# files near the cap can approach the unit's TimeoutStartSec=600.
MAX_YAML_EVENTS = 120000
MAX_YAML_DEPTH = 32
WARN_FILE_BYTES = MAX_FILE_BYTES * 3 // 4
# Exit code of main() when a size or event bound is exceeded; the publisher maps
# it to the `yaml_bounds` failure reason instead of a generic invalid_* one.
BOUNDS_EXIT = 3


class BoundsError(ValueError):
    """A ledger file is over the size or event bound (not a malformed one)."""


def directory_fd(path):
    """Open every component without following symlinks, including ancestors."""
    if not path.startswith("/") or any(p in (".", "..", "") for p in path.split("/")[1:]):
        raise ValueError("absolute physical source directory required")
    fd = os.open("/", DIR_FLAGS)
    try:
        for part in path.split("/")[1:]:
            child = os.open(part, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def bounded_document_check(data):
    """Size, event, alias/anchor and depth bounds of one ledger file.

    The single contract shared by every reader (via document()) and by `install`
    (the writer), so a file the publisher writes is a file it can read back.
    """
    if len(data) > MAX_FILE_BYTES:
        raise BoundsError("ledger file over byte bound")
    depth = 0
    for count, event in enumerate(yaml.parse(data), start=1):
        if count > MAX_YAML_EVENTS:
            raise BoundsError("ledger file over YAML event bound")
        if isinstance(event, yaml.AliasEvent) or getattr(event, "anchor", None):
            raise ValueError("YAML structure outside bounded contract")
        if isinstance(event, (yaml.MappingStartEvent, yaml.SequenceStartEvent)):
            depth += 1
        elif isinstance(event, (yaml.MappingEndEvent, yaml.SequenceEndEvent)):
            depth -= 1
        if depth > MAX_YAML_DEPTH:
            raise ValueError("YAML structure too deep")


def document(data, rel):
    """Parse one ledger file; `rel` (its path) decides which schema it may declare."""
    bounded_document_check(data)
    doc = yaml.load(data, Loader=DIFF["DuplicateKeyLoader"])
    if not isinstance(doc, dict) or doc.get("schema") != expected_schema(rel):
        raise ValueError("unsupported ledger")
    if doc.get("scale") not in ("day", "week", "month", "session") or not isinstance(doc.get("period"), str):
        raise ValueError("invalid ledger header")
    if set(doc) != {"schema", "scale", "period", "events"}:
        raise ValueError("unknown header")
    if not isinstance(doc["events"], list) or any(not isinstance(e, dict) for e in doc["events"]):
        raise ValueError("invalid ledger events")
    return doc


def walk_source(fd, budget, prefix="", depth=0):
    if depth > MAX_DIRECTORY_DEPTH:
        raise ValueError("source directory too deep")
    names = []
    with os.scandir(fd) as entries:
        for entry in entries:
            budget["entries"] += 1
            if budget["entries"] > MAX_ENTRIES:
                raise ValueError("too many source entries")
            names.append(entry.name)
    for name in sorted(names):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
            raise ValueError("unsupported source entry name")
        info = os.stat(name, dir_fd=fd, follow_symlinks=False)
        rel = prefix + name
        if stat.S_ISDIR(info.st_mode):
            child = os.open(name, DIR_FLAGS, dir_fd=fd)
            try:
                yield from walk_source(child, budget, rel + "/", depth + 1)
            finally:
                os.close(child)
        elif stat.S_ISREG(info.st_mode):
            # Producer lock/temp files are not ledger input. Links and special
            # files are rejected even when their names do not end in .yaml.
            if not name.endswith(".yaml"):
                continue
            budget["files"] += 1
            if budget["files"] > MAX_FILES:
                raise ValueError("too many source files")
            child = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            with os.fdopen(child, "rb") as stream:
                before = os.fstat(stream.fileno())
                if not stat.S_ISREG(before.st_mode):
                    raise ValueError("source changed type")
                data = stream.read(MAX_FILE_BYTES + 1)
                after = os.fstat(stream.fileno())
            budget["bytes"] += len(data)
            if len(data) > MAX_FILE_BYTES:
                raise BoundsError("source file exceeds byte limit")
            if budget["bytes"] > MAX_TOTAL_BYTES:
                raise ValueError("source exceeds byte limit")
            if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                raise ValueError("source changed during read")
            document(data, rel)
            yield rel, data
        else:
            raise ValueError("source contains link or special file")


def scan(source, destination=None):
    fd = directory_fd(source)
    manifest = {}
    try:
        for rel, data in walk_source(fd, {"entries": 0, "files": 0, "bytes": 0}):
            manifest[rel] = hashlib.sha256(data).hexdigest()
            if destination is not None:
                target = Path(destination, "ledger", rel)
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open("xb") as stream:
                    stream.write(data)
    finally:
        os.close(fd)
    return manifest


def capture(source, snapshot, *excluded):
    for other in excluded:
        common = os.path.commonpath((os.path.realpath(source), os.path.realpath(other)))
        if common in (os.path.realpath(source), os.path.realpath(other)):
            raise ValueError("overlapping source")
    manifest = scan(source, snapshot)
    if not manifest:
        raise ValueError("empty source cannot establish a publication receipt")
    Path(snapshot, "manifest.json").write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")


def read_manifest(snapshot):
    return json.loads(Path(snapshot, "manifest.json").read_text(encoding="utf-8"))


def check_destination(snapshot, checkout):
    for rel in read_manifest(snapshot):
        archive = Path(checkout, "archive", "ledger", rel)
        if archive.exists() or archive.is_symlink():
            raise ValueError("period already archived")
        target = Path(checkout)
        components = ("machine/ledger/" + rel).split("/")
        for index, component in enumerate(components):
            target = target / component
            if target.is_symlink():
                raise ValueError("destination contains link")
            if target.exists() and not (target.is_file() if index == len(components) - 1 else target.is_dir()):
                raise ValueError("destination has wrong type")
        if target.is_file():
            DIFF["_check_header"](document(Path(snapshot, "ledger", rel).read_bytes(), rel), document(target.read_bytes(), rel))


def tree_has_path(checkout, revision, path):
    raw = os.fsencode(path)
    return git_bytes(checkout, "ls-tree", "-r", "--name-only", "-z", revision, "--", raw) == raw + b"\0"


def guard_archive_paths(checkout, base, paths):
    """Check the final push candidate against its fresh origin parent."""
    for rel in paths:
        raw = os.fsencode(rel)
        if not raw.endswith(b".yaml") or any(part in (b"", b".", b"..") for part in raw.split(b"/")):
            raise ValueError("invalid source path")
        active = b"machine/ledger/" + raw
        archived = b"archive/ledger/" + raw
        if not tree_has_path(checkout, "HEAD", active):
            continue  # An archive move may itself delete the active path.
        for revision in (base, "HEAD"):
            if tree_has_path(checkout, revision, archived):
                raise ValueError("period already archived")


def guard_archive(snapshot, checkout, base):
    manifest = read_manifest(snapshot)
    if not manifest:
        raise ValueError("empty source manifest")
    # Validate each replayed commit as well as the net tree. Two intermediate
    # changes outside the ledger can cancel in base..HEAD while still entering
    # the published history.
    check_history(checkout, base, snapshot)
    # A stale backlog was allowlisted before rebase. Recheck the actual
    # candidate tree: a rename on origin can redirect that old patch into
    # archive/ledger even though the original commit named machine/ledger.
    changed = git_bytes(checkout, "diff", "--no-renames", "--name-only", "-z",
                        base, "HEAD")
    for raw in changed.split(b"\0"):
        if not raw:
            continue
        if not re.fullmatch(rb"machine/ledger/[A-Za-z0-9_./-]+\.yaml", raw) or b".." in raw.split(b"/"):
            raise ValueError("external candidate outside ledger")
        if not tree_has_path(checkout, "HEAD", raw.decode("ascii")):
            raise ValueError("external candidate deletes ledger")
    guard_archive_paths(checkout, base, manifest)
    for rel in manifest:
        if not tree_has_path(checkout, "HEAD", "machine/ledger/" + rel):
            raise ValueError("source not in candidate")


def guard_archive_commits(checkout, base, commits):
    paths = set()
    def add_ledger_paths(changed):
        for raw in changed.split(b"\0"):
            for prefix in (b"machine/ledger/", b"archive/ledger/"):
                if raw.startswith(prefix) and raw.endswith(b".yaml"):
                    paths.add(raw.removeprefix(prefix))

    for commit in commits:
        if not re.fullmatch(r"[0-9a-fA-F]{40,64}", commit):
            raise ValueError("invalid commit")
        changed = git_bytes(checkout, "diff-tree", "--root", "--no-renames",
                            "--no-commit-id", "--name-only", "-r", "-z", commit)
        add_ledger_paths(changed)
    add_ledger_paths(git_bytes(checkout, "diff", "--no-renames", "--name-only",
                               "-z", base, "HEAD", "--", "machine/ledger", "archive/ledger"))
    guard_archive_paths(checkout, base, paths)


def check_checkout(checkout):
    root = Path(checkout).resolve()
    top = Path(git_bytes(checkout, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    common = git_bytes(checkout, "rev-parse", "--git-common-dir").decode().strip()
    if top != root or (root / common).resolve() != root / ".git":
        raise ValueError("shared Git directory or redirected worktree")
    # Hooks may write canon even when they are legitimate protective hooks.
    # Refuse an unreviewed profile; never turn its protections off. Conditional
    # includes can activate another hooksPath only in gateway worktrees.
    for pattern in (r"^core\.hookspath$", r"^(include|includeif)\."):
        result = subprocess.run(
            ["git", "-C", checkout, "config", "--get-regexp", pattern],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if result.returncode != 1:
            raise ValueError("unreviewed Git hook configuration")
    hooks = root / ".git" / "hooks"
    if hooks.exists() and any(p.is_file() and not p.name.endswith(".sample") and os.access(p, os.X_OK) for p in hooks.iterdir()):
        raise ValueError("active Git hooks require a reviewed transport profile")
    for directory, dirs, files in os.walk(root / ".git", followlinks=False):
        for name in dirs + files:
            path = Path(directory, name)
            if path.is_symlink():
                raise ValueError("linked Git metadata")
            if path.is_file() and path.stat().st_nlink != 1:
                raise ValueError("shared Git metadata inode")
        # Local clones hardlink immutable objects; Git never edits their inode.
        # Do not scan the entire object database on every queue publication.
        if Path(directory) == root / ".git":
            dirs[:] = [name for name in dirs if name != "objects"]
    ledger = Path(checkout, "machine", "ledger")
    for path in (Path(checkout, "machine"), ledger, *ledger.rglob("*")):
        if path.is_symlink():
            raise ValueError("linked checkout path")
        if path.is_file() and path.stat().st_nlink != 1:
            raise ValueError("shared checkout inode")


def check_profile(profile_name, profiles_dir=None):
    """Validate a reviewed hook profile: status, exact-set, dependencies.

    Fail closed on anything unexpected: the profile is security input, not a
    convenience configuration. `profiles_dir` is an optional override used only
    by the smoke script against a temp copy; the publisher always reads the
    authoritative directory derived from this script's location (§7.7: the
    automation clone must never be able to authorise itself).
    """
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", profile_name):
        raise ValueError("invalid profile name")
    base = Path(profiles_dir).resolve() if profiles_dir else PROFILES_DIR
    profile_dir = base / profile_name
    _check_profile_dir_chain(profile_dir)
    record = json.loads(Path(profile_dir, "profile.json").read_text(encoding="utf-8"))
    status = record.get("status")
    if status not in ("proposed", "approved"):
        raise ValueError("profile status is not active")
    declared = {}
    for item in record.get("files") or []:
        name = item.get("name", "")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", name) or name in declared:
            raise ValueError("invalid profile file record")
        declared[name] = item
    if not declared:
        raise ValueError("profile declares no files")
    # Flat-directory exact-set without following symlinks (§10.7): enumerate
    # every entry with lstat; a link, directory or special file aborts before
    # any comparison; the surviving regular files must equal the declared set
    # (metadata files excepted, and they must not be executable).
    with os.scandir(profile_dir) as entries:
        names = [entry.name for entry in entries]
    for name in names:
        info = os.lstat(profile_dir / name)
        if stat.S_ISLNK(info.st_mode):
            raise ValueError("profile contains link")
        if stat.S_ISDIR(info.st_mode):
            raise ValueError("profile contains directory")
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("profile contains special file")
        mode = stat.S_IMODE(info.st_mode)
        if name in declared:
            item = declared.pop(name)
            # The declared mode carries the regular-file type bits ("100644");
            # lstat here yields permission bits only.
            if format(mode, "o") != str(item.get("mode", "")).removeprefix("100"):
                raise ValueError("profile file mode mismatch")
            digest = hashlib.sha256(Path(profile_dir, name).read_bytes()).hexdigest()
            if digest != item.get("sha256"):
                raise ValueError("profile file digest mismatch")
        elif name in PROFILE_METADATA_FILES:
            if mode & 0o111:
                raise ValueError("profile metadata is executable")
        else:
            raise ValueError("profile contains undeclared file")
    if declared:
        raise ValueError("profile file missing")
    # Dependencies are mandatory for profiles with external calls; a null
    # digest is tolerated only while the profile is unsigned (proposed).
    for dep in (record.get("dependencies") or {}).values():
        rel = dep.get("path", "")
        digest = dep.get("sha256")
        if not rel or rel.startswith("/") or any(part in ("", ".", "..") for part in rel.split("/")):
            raise ValueError("invalid dependency path")
        if digest is None:
            if status == "approved":
                raise ValueError("approved profile requires dependency digest")
            continue
        root = os.environ.get("IWE_ROOT")
        if not root:
            raise ValueError("IWE_ROOT required for dependency check")
        target = Path(root, rel)
        info = os.lstat(target)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("dependency is not a regular file")
        if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise ValueError("dependency digest mismatch")


def _check_profile_dir_chain(profile_dir):
    """resolve_and_check for the profile directory itself (§8.3)."""
    path = Path(profile_dir)
    if not str(path).startswith("/"):
        raise ValueError("profile directory must be absolute")
    uid = os.getuid()
    current = Path("/")
    for part in path.parts[1:]:
        current = current / part
        info = os.lstat(current)
        if not stat.S_ISDIR(info.st_mode):
            raise ValueError("profile path component is not a directory")
        if stat.S_ISLNK(info.st_mode):
            raise ValueError("profile path contains link")
        if info.st_uid not in (0, uid):
            raise ValueError("profile path foreign owner")
        # Group/other-writable directories are trusted only with the sticky
        # bit set (the /tmp convention, §8.3 exception).
        if info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX:
            raise ValueError("profile path is group/other-writable")


def install(source, checkout, relative):
    if not re.fullmatch(r"machine/ledger/[A-Za-z0-9_./-]+\.yaml", relative) or ".." in relative.split("/"):
        raise ValueError("invalid destination")
    parts = relative.split("/")
    fd = directory_fd(os.path.realpath(checkout))
    temporary = ".ledger-" + uuid.uuid4().hex
    try:
        for part in parts[:-1]:
            child = os.open(part, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
        data = Path(source).read_bytes()
        # Writer side of the shared bound: never put a file on the checkout that
        # document() would refuse to read back (that stalled publication 30.10).
        bounded_document_check(data)
        if len(data) > WARN_FILE_BYTES:
            print("ledger bounds warning: a ledger file passed 75% of the byte bound", file=sys.stderr)
        out = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=fd)
        try:
            with os.fdopen(out, "wb") as stream:
                stream.write(data)
            os.replace(temporary, parts[-1], src_dir_fd=fd, dst_dir_fd=fd)
        finally:
            try:
                os.unlink(temporary, dir_fd=fd)
            except FileNotFoundError:
                pass
    finally:
        os.close(fd)


def git_bytes(checkout, *args):
    return subprocess.run(["git", "-C", checkout, *args], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          env={**os.environ, "GIT_NO_REPLACE_OBJECTS": "1",
                               "GIT_GRAFT_FILE": os.devnull}).stdout


def check_history(checkout, base, snapshot=None, *, budget_from_base=True):
    allowed = read_manifest(snapshot) if snapshot else None
    outgoing_events = {}
    addition_budget = {}
    commits = git_bytes(checkout, "rev-list", f"{base}..HEAD").decode().splitlines()
    for commit in commits:
        parents = git_bytes(
            checkout, "rev-list", "--parents", "-n", "1", commit
        ).split()
        if len(parents) > 2:
            raise ValueError("merge backlog requires separate review")
        paths = git_bytes(
            checkout,
            "diff-tree",
            "--root",
            "--no-renames",
            "--no-commit-id",
            "--name-only",
            "-r",
            "-z",
            commit,
        )
        for path in paths.split(b"\0"):
            if path and not re.fullmatch(
                rb"machine/ledger/[A-Za-z0-9_./-]+\.yaml", path
            ):
                raise ValueError("nonledger history")
            if not path:
                continue
            rel = path.decode()
            source_rel = rel.removeprefix("machine/ledger/")
            if allowed is not None and source_rel not in allowed:
                raise ValueError("outgoing path not owned by snapshot")
            # A deleted file cannot be read here and is refused, as are edits
            # that remove existing events. Validate each commit, not net diff.
            current = document(git_bytes(checkout, "show", f"{commit}:{rel}"), rel)
            previous_events = []
            if len(parents) == 2:
                parent = parents[1].decode()
                entries = git_bytes(checkout, "ls-tree", parent, "--", rel)
                if entries:
                    previous = document(
                        git_bytes(checkout, "show", f"{parent}:{rel}"), rel
                    )
                    DIFF["_check_header"](previous, current)
                    if DIFF["missing_events"](previous["events"], current["events"]):
                        raise ValueError("backlog removes events")
                    previous_events = previous["events"]
            if allowed is not None:
                source_data = Path(snapshot, "ledger", source_rel).read_bytes()
                if hashlib.sha256(source_data).hexdigest() != allowed[source_rel]:
                    raise ValueError("snapshot changed")
                source_doc = document(source_data, source_rel)
                DIFF["_check_header"](source_doc, current)
                if source_rel not in addition_budget:
                    base_events = []
                    if budget_from_base and tree_has_path(checkout, base, rel):
                        base_doc = document(
                            git_bytes(checkout, "show", f"{base}:{rel}"), rel
                        )
                        DIFF["_check_header"](base_doc, source_doc)
                        base_events = base_doc["events"]
                    # Events already on the publication base cannot authorize
                    # another occurrence anywhere in the outgoing history.
                    addition_budget[source_rel] = DIFF["missing_events"](
                        source_doc["events"], base_events
                    )
                additions = DIFF["missing_events"](current["events"], previous_events)
                outgoing_events.setdefault(source_rel, []).extend(additions)
                if DIFF["missing_events"](
                    outgoing_events[source_rel], addition_budget[source_rel]
                ):
                    raise ValueError("outgoing event not owned by snapshot")


def check_backlog(checkout, branch, snapshot=None):
    # Before alignment, origin may contain equivalent events under different
    # commit IDs. Check ownership now; guard_archive checks the remaining
    # multiplicity against the exact publication base after alignment.
    check_history(checkout, f"origin/{branch}", snapshot, budget_from_base=False)


def check_snapshot_scope(snapshot, scope):
    paths = read_manifest(snapshot)
    if scope not in {"plan", "nonplan"} or not paths:
        raise ValueError("invalid snapshot scope")
    for rel in paths:
        if (rel.startswith("plan/")) != (scope == "plan"):
            raise ValueError("snapshot outside route scope")


def conditional_receipt(source, snapshot, checkout, base, candidate, oid):
    for revision in (base, candidate, oid):
        if not re.fullmatch(r"[0-9a-f]{40,64}", revision):
            raise ValueError("invalid conditional revision")
    parents = git_bytes(checkout, "rev-list", "--parents", "-n", "1", candidate).decode().split()
    if parents != [candidate, base]:
        raise ValueError("candidate not based on expected revision")
    git_bytes(checkout, "merge-base", "--is-ancestor", candidate, oid)
    if git_bytes(checkout, "rev-parse", "HEAD").decode().strip() != candidate:
        raise ValueError("candidate changed")
    guard_archive(snapshot, checkout, base)
    receipt_data = verified_receipt(source, snapshot, checkout, oid)
    result = {
        "schema": "plan-publication-receipt/1",
        "state": "published",
        "reason": "exact_commit_verified",
        "expected_base": base,
        "candidate_oid": candidate,
        "origin_oid": oid,
        "snapshot_id": receipt_data["snapshot_id"],
    }
    print("PLAN_PUBLICATION_RECEIPT " + json.dumps(result, sort_keys=True))


def verified_receipt(source, snapshot, checkout, oid):
    if not re.fullmatch(r"[0-9a-f]{40,64}", oid):
        raise ValueError("invalid revision")
    manifest = read_manifest(snapshot)
    for rel, digest in manifest.items():
        if not re.fullmatch(r"[A-Za-z0-9_./-]+\.yaml", rel) or any(
            part in ("", ".", "..") for part in rel.split("/")
        ):
            raise ValueError("invalid snapshot path")
        data = Path(snapshot, "ledger", rel).read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError("snapshot changed")
        local = document(data, rel)
        remote = document(
            git_bytes(checkout, "show", f"{oid}:machine/ledger/{rel}"), rel
        )
        DIFF["_check_header"](local, remote)
        if DIFF["missing_events"](local["events"], remote["events"]):
            raise ValueError("snapshot not fully published")
    try:
        changed = scan(source) != manifest
    except (OSError, ValueError, yaml.YAMLError):
        changed = None
    snapshot_id = hashlib.sha256(
        json.dumps(manifest, sort_keys=True).encode()
    ).hexdigest()
    return {
        "state": "published",
        "reason": "snapshot_verified",
        "snapshot_id": snapshot_id,
        "origin_oid": oid,
        "source_changed": changed,
        "files": len(manifest),
    }


def receipt(source, snapshot, checkout, oid):
    print(
        "LEDGER_SOURCE_RECEIPT "
        + json.dumps(verified_receipt(source, snapshot, checkout, oid), sort_keys=True)
    )


def _identified_events(events):
    by_id = {}
    for event in events:
        identity = event.get("event_id")
        if not isinstance(identity, str) or not re.fullmatch(r"[0-9a-f]{32}", identity):
            raise ValueError("buffer event lacks a unique identity")
        if identity in by_id:
            raise ValueError("duplicate buffer event identity")
        by_id[identity] = event
    return by_id


def _ensure_relative_parent(root, rel):
    parent = directory_fd(root)
    try:
        for part in Path(rel).parts[:-1]:
            try:
                os.mkdir(part, 0o700, dir_fd=parent)
            except FileExistsError:
                pass
            child = os.open(part, DIR_FLAGS, dir_fd=parent)
            os.close(parent)
            parent = child
    finally:
        os.close(parent)


def _read_regular(path):
    parent = directory_fd(str(path.parent))
    try:
        descriptor = os.open(
            path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent
        )
        with os.fdopen(descriptor, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError("buffer source is not a regular file")
            return stream.read()
    finally:
        os.close(parent)


def _atomic_document(path, doc):
    data = yaml.safe_dump(doc, allow_unicode=True, sort_keys=False).encode("utf-8")
    # Same writer-side bound as install(): acknowledged/pending copies are read
    # back through document(), so never write one that would be refused.
    bounded_document_check(data)
    temporary = path.name + ".ack." + uuid.uuid4().hex
    parent = directory_fd(str(path.parent))
    created = False
    try:
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=parent,
        )
        created = True
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent)
        os.fsync(parent)
    finally:
        if created:
            try:
                os.unlink(temporary, dir_fd=parent)
            except FileNotFoundError:
                pass
        os.close(parent)


def _dead_owner(parent, lock_dir):
    """Return a same-host dead PID only for a complete writer owner record."""
    directory = os.open(lock_dir, DIR_FLAGS, dir_fd=parent)
    try:
        owner = os.open("owner", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        try:
            raw = os.read(owner, 256).decode("utf-8")
        finally:
            os.close(owner)
    finally:
        os.close(directory)
    lines = raw.splitlines()
    if (
        len(lines) != 2
        or not lines[0].startswith("host=")
        or not lines[1].startswith("pid=")
    ):
        return None
    host = lines[0][5:]
    pid = lines[1][4:]
    if (
        host != (os.environ.get("HOSTNAME") or socket.gethostname())
        or not pid.isdecimal()
        or int(pid) <= 0
    ):
        return None
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return pid
    return None


def _reclaim_dead_lock(parent, lock_dir):
    try:
        dead_pid = _dead_owner(parent, lock_dir)
    except (OSError, UnicodeError, ValueError):
        return False
    if dead_pid is None:
        return False
    reclaim = lock_dir + ".reclaim"
    try:
        os.mkdir(reclaim, dir_fd=parent)
    except FileExistsError:
        return False
    try:
        if _dead_owner(parent, lock_dir) != dead_pid:
            return False
        directory = os.open(lock_dir, DIR_FLAGS, dir_fd=parent)
        try:
            with os.scandir(directory) as entries:
                if {entry.name for entry in entries} != {"owner"}:
                    return False
            os.unlink("owner", dir_fd=directory)
        finally:
            os.close(directory)
        os.rmdir(lock_dir, dir_fd=parent)
        return True
    finally:
        os.rmdir(reclaim, dir_fd=parent)


@contextmanager
def _hold_transfer_lock(pending, locks_root, rel):
    """Hold both writer lock forms while moving one period's events."""
    _ensure_relative_parent(locks_root, rel)
    pending_parent = directory_fd(str(pending.parent))
    try:
        lock_parent = directory_fd(str(Path(locks_root, rel).parent))
        try:
            lock_fd = os.open(
                pending.name + ".lock",
                os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
                0o600,
                dir_fd=lock_parent,
            )
            try:
                if not stat.S_ISREG(os.fstat(lock_fd).st_mode):
                    raise ValueError("invalid pending lock")
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                lock_dir = pending.name + ".lockdir"
                try:
                    os.mkdir(lock_dir, dir_fd=lock_parent)
                except FileExistsError:
                    if not _reclaim_dead_lock(lock_parent, lock_dir):
                        raise
                    os.mkdir(lock_dir, dir_fd=lock_parent)
                try:
                    yield pending_parent
                finally:
                    os.rmdir(lock_dir, dir_fd=lock_parent)
            finally:
                os.close(lock_fd)
        finally:
            os.close(lock_parent)
    finally:
        os.close(pending_parent)


def _transfer_snapshot_file(pending, retained, snapshot, rel, pending_parent):
    snapshot_doc = document(Path(snapshot, "ledger", rel).read_bytes(), rel)
    try:
        pending_doc = document(_read_regular(pending), rel)
    except FileNotFoundError:
        pending_doc = None
    try:
        retained_doc = document(_read_regular(retained), rel)
    except FileNotFoundError:
        retained_doc = None
    for doc in (pending_doc, retained_doc):
        if doc is not None:
            DIFF["_check_header"](doc, snapshot_doc)
    selected = _identified_events(snapshot_doc["events"])
    live = _identified_events(pending_doc["events"] if pending_doc else [])
    kept = _identified_events(retained_doc["events"] if retained_doc else [])
    for identity in live.keys() & kept.keys():
        if live[identity] != kept[identity]:
            raise ValueError("buffer identity conflict across zones")
    for identity, event in selected.items():
        if identity in live and live[identity] != event:
            raise ValueError("pending identity changed")
        if identity in kept and kept[identity] != event:
            raise ValueError("acknowledged identity changed")
        if identity not in live and identity not in kept:
            raise ValueError("snapshot event vanished before acknowledgement")
    desired = dict(retained_doc or snapshot_doc)
    desired["events"] = list(retained_doc["events"] if retained_doc else []) + [
        event for identity, event in selected.items() if identity not in kept
    ]
    _atomic_document(retained, desired)
    if pending_doc is not None:
        remaining = [e for e in pending_doc["events"] if e["event_id"] not in selected]
        if remaining:
            pending_doc["events"] = remaining
            _atomic_document(pending, pending_doc)
        else:
            os.unlink(pending.name, dir_fd=pending_parent)
            os.fsync(pending_parent)


def check_acknowledgement(source, snapshot, acknowledged):
    """Reject an unusable acknowledgement route before any Git publication."""
    if (
        Path(source).name != "pending"
        or Path(acknowledged).name != "acknowledged"
        or Path(source).parent != Path(acknowledged).parent
    ):
        raise ValueError("expected sibling pending and acknowledged directories")
    for root in (source, acknowledged):
        descriptor = directory_fd(root)
        os.close(descriptor)
    for rel in read_manifest(snapshot):
        snapshot_doc = document(Path(snapshot, "ledger", rel).read_bytes(), rel)
        selected = _identified_events(snapshot_doc["events"])
        retained = Path(acknowledged, rel)
        try:
            retained_doc = document(_read_regular(retained), rel)
        except FileNotFoundError:
            continue
        DIFF["_check_header"](retained_doc, snapshot_doc)
        kept = _identified_events(retained_doc["events"])
        if any(identity in kept and kept[identity] != event for identity, event in selected.items()):
            raise ValueError("acknowledged identity conflict")


def acknowledge(source, snapshot, checkout, oid, acknowledged):
    """Retain a verified snapshot outside Git, then drain only its pending IDs."""
    check_acknowledgement(source, snapshot, acknowledged)
    result = verified_receipt(source, snapshot, checkout, oid)
    buffer_root = str(Path(source).parent)
    root_fd = directory_fd(buffer_root)
    try:
        try:
            os.mkdir("locks", 0o700, dir_fd=root_fd)
        except FileExistsError:
            pass
    finally:
        os.close(root_fd)
    locks_root = str(Path(buffer_root, "locks"))
    lock_root_fd = directory_fd(locks_root)
    os.close(lock_root_fd)
    for rel in read_manifest(snapshot):
        pending = Path(source, rel)
        retained = Path(acknowledged, rel)
        _ensure_relative_parent(acknowledged, rel)
        with _hold_transfer_lock(pending, locks_root, rel) as pending_parent:
            _transfer_snapshot_file(pending, retained, snapshot, rel, pending_parent)
    result["acknowledged_files"] = len(read_manifest(snapshot))
    print("LEDGER_SOURCE_RECEIPT " + json.dumps(result, sort_keys=True))


class AuditError(ValueError):
    """Content-free reason; never expose a path, YAML value or Git diagnostic."""


def _audit_stamp(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _audit_os_reason(exc):
    if isinstance(exc, FileNotFoundError):
        return "missing_source"
    if exc.errno in (errno.ELOOP, errno.ENOTDIR):
        return "unsafe_path"
    return "unreadable_source"


def _audit_inventory(root):
    """Bounded metadata walk, including directories, for end-of-audit recheck."""
    entries, files = {}, []

    def visit(fd, prefix="", depth=0):
        if depth > MAX_DIRECTORY_DEPTH:
            raise AuditError("inventory_limit")
        entries[prefix] = _audit_stamp(os.fstat(fd))
        with os.scandir(fd) as children:
            for entry in children:
                if len(entries) >= MAX_ENTRIES:
                    raise AuditError("inventory_limit")
                info = entry.stat(follow_symlinks=False)
                rel = prefix + entry.name
                entries[rel] = _audit_stamp(info)
                if stat.S_ISDIR(info.st_mode):
                    child = os.open(entry.name, DIR_FLAGS, dir_fd=fd)
                    try:
                        visit(child, rel + "/", depth + 1)
                    finally:
                        os.close(child)
                elif not stat.S_ISREG(info.st_mode):
                    raise AuditError("unsafe_path")
                elif entry.name.endswith(".yaml"):
                    files.append(rel)
                    if len(files) > MAX_FILES:
                        raise AuditError("inventory_limit")

    fd = directory_fd(root)
    try:
        visit(fd)
    finally:
        os.close(fd)
    return sorted(files), entries


def _audit_read(path):
    parent = directory_fd(str(path.parent))
    try:
        fd = os.open(
            path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent
        )
        with os.fdopen(fd, "rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise AuditError("unsafe_path")
            data = stream.read(MAX_FILE_BYTES + 1)
            after = os.fstat(stream.fileno())
        current = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        if _audit_stamp(before) != _audit_stamp(after) or _audit_stamp(
            after
        ) != _audit_stamp(current):
            raise AuditError("changed_during_audit")
        if len(data) > MAX_FILE_BYTES:
            raise AuditError("byte_limit")
        return data, _audit_stamp(after)
    finally:
        os.close(parent)


def _audit_identity(rel):
    match = re.fullmatch(
        r"(day|week|month|plan)/[0-9/]+/(?:day|week|month|plan)-([0-9W-]+)\.yaml", rel
    )
    if not match or rel != ledger_path_rel(match[1], match[2]):
        raise AuditError("invalid_ledger_path")
    scale, period = match.groups()
    if not re.fullmatch(
        {
            "day": r"\d{4}-\d{2}-\d{2}",
            "plan": r"\d{4}-\d{2}-\d{2}",
            "week": r"\d{4}-W\d{2}",
            "month": r"\d{4}-\d{2}",
        }[scale],
        period,
    ):
        raise AuditError("invalid_ledger_path")
    return scale, period


def _audit_json_values(document):
    """Exact-record comparison must never coerce YAML keys or scalar types."""
    pending = [document]
    while pending:
        value = pending.pop()
        if type(value) is dict:
            if any(type(key) is not str for key in value):
                raise ValueError("non-string mapping key")
            pending.extend(value.values())
        elif type(value) is list:
            pending.extend(value)
        elif type(value) is float:
            if not math.isfinite(value):
                raise ValueError("non-finite number")
        elif type(value) not in (str, int, bool, type(None)):
            raise ValueError("unsupported scalar type")


def _audit_document(data, rel):
    scale, period = _audit_identity(rel)
    try:
        doc = document(data, rel)
        if (
            doc["scale"] != ("day" if scale == "plan" else scale)
            or doc["period"] != period
        ):
            raise ValueError("identity mismatch")
        _audit_json_values(doc)
        # Validate canonical event encoding even when there is nothing to compare.
        for event in doc["events"]:
            DIFF["canonical"](event)
        return doc
    except BoundsError:
        raise AuditError("yaml_bounds") from None
    except (ValueError, TypeError, yaml.YAMLError):
        raise AuditError("invalid_document") from None


def _audit_local(checkout, rel):
    sources, stamps = [], []
    for zone in ("machine/ledger", "archive/ledger"):
        try:
            data, stamp = _audit_read(Path(checkout, zone, rel))
            sources.append(data)
            stamps.append(stamp)
        except FileNotFoundError:
            stamps.append(None)
    if len(sources) == 2:
        return {"state": "duplicate_sources"}, tuple(stamps)
    if not sources:
        return {"state": "missing_source"}, tuple(stamps)
    return _audit_document(sources[0], rel), tuple(stamps)


def _audit_git(checkout, *args):
    # -C is not authoritative while GIT_DIR, object/config overrides, etc. survive.
    # Clear the entire Git environment namespace, then set a read-only contract.
    env = {
        key: value for key, value in os.environ.items() if not key.startswith("GIT_")
    }
    env.update(
        GIT_CONFIG_NOSYSTEM="1",
        GIT_CONFIG_SYSTEM=os.devnull,
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_OPTIONAL_LOCKS="0",
        GIT_NO_REPLACE_OBJECTS="1",
        GIT_NO_LAZY_FETCH="1",
        GIT_ALLOW_PROTOCOL="",
        GIT_PROTOCOL_FROM_USER="0",
        GIT_TERMINAL_PROMPT="0",
    )
    return subprocess.run(
        # An older Git that cannot enforce this flag must report unknown. A
        # promisor object must never cause an implicit fetch or write objects.
        ["git", "--no-lazy-fetch", "-c", "protocol.allow=never", "-C", checkout, *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=10,
        env=env,
    ).stdout


def _audit_origin(checkout, oid, rel):
    sources = []
    for zone in ("machine/ledger", "archive/ledger"):
        path = zone + "/" + rel
        entry = _audit_git(checkout, "ls-tree", "-z", oid, "--", path)
        if not entry:
            continue
        metadata, returned_path = entry.rstrip(b"\0").split(b"\t", 1)
        mode, kind, blob = metadata.split()
        if mode != b"100644" or kind != b"blob" or returned_path != path.encode():
            raise AuditError("unsafe_path")
        size = int(_audit_git(checkout, "cat-file", "-s", blob.decode()))
        if size > MAX_FILE_BYTES:
            raise AuditError("byte_limit")
        sources.append(_audit_git(checkout, "cat-file", "blob", blob.decode()))
    if len(sources) == 2:
        return {"state": "duplicate_sources"}
    return _audit_document(sources[0], rel) if sources else {"state": "missing_source"}


def _audit_comparison(acknowledged, source):
    if "state" in source:
        return source
    missing = len(DIFF["missing_events"](acknowledged["events"], source["events"]))
    return {
        "state": "missing_events" if missing else "match",
        "events": len(source["events"]),
        "missing_events": missing,
    }


def _audit_observe(function, *args):
    try:
        return function(*args)
    except AuditError as exc:
        return {"state": str(exc)}
    except OSError as exc:
        return {"state": _audit_os_reason(exc)}
    except (ValueError, TypeError, subprocess.SubprocessError):
        return {"state": "unreadable_source"}


def acknowledgement_audit(source, checkout):
    """Advisory observations only: neither fresh remote state nor reader fencing."""
    result = {
        "schema": "ledger-buffer-audit/v1",
        "mode": "audit_only",
        "deletion_authorized": False,
        "reason": "readers_not_fenced",
        "local_scope": "current_checkout_active_and_archive_only",
        "origin": {
            "ref": "origin/main",
            "freshness": "cached_not_verified",
            "oid": None,
        },
        "acknowledged_state": "unreadable_source",
        "snapshot_digest": None,
        "files": [],
    }
    try:
        checkout_fd = directory_fd(checkout)
        os.close(checkout_fd)
        oid = (
            _audit_git(
                checkout, "rev-parse", "--verify", "refs/remotes/origin/main^{commit}"
            )
            .decode()
            .strip()
        )
        if not re.fullmatch(r"[0-9a-f]{40,64}", oid):
            raise AuditError("origin_ref_unavailable")
        result["origin"]["oid"] = oid
    except (OSError, ValueError, subprocess.SubprocessError):
        result["origin"]["state"] = "origin_ref_unavailable"
    inventory = _audit_observe(_audit_inventory, source)
    if isinstance(inventory, dict):
        result["acknowledged_state"] = inventory["state"]
        result["audit_complete"] = False
        return result
    paths, before = inventory
    result["acknowledged_state"] = "observed" if paths else "empty"
    manifests, local_stamps, byte_count = {}, {}, 0
    for rel in paths:
        row = {"state": "unreadable_source"}
        result["files"].append(row)
        try:
            scale, period = _audit_identity(rel)
            row.update(scale=scale, period=period)
            if byte_count >= MAX_TOTAL_BYTES:
                raise AuditError("byte_limit")
            data, stamp = _audit_read(Path(source, rel))
            if stamp != before[rel]:
                raise AuditError("changed_during_audit")
            byte_count += len(data)
            if byte_count > MAX_TOTAL_BYTES:
                raise AuditError("byte_limit")
            doc = _audit_document(data, rel)
            manifests[rel] = hashlib.sha256(data).hexdigest()
            row.update(
                state="observed",
                snapshot_digest=manifests[rel],
                events=len(doc["events"]),
                file_mtime_age_seconds=max(
                    0, int(time.time() - stamp[3] / 1_000_000_000)
                ),
            )
            local = _audit_observe(_audit_local, checkout, rel)
            if isinstance(local, tuple):
                local, local_stamps[rel] = local
            row["local"] = _audit_comparison(doc, local)
            origin = (
                _audit_observe(_audit_origin, checkout, result["origin"]["oid"], rel)
                if result["origin"]["oid"]
                else {"state": "origin_ref_unavailable"}
            )
            row["origin"] = _audit_comparison(doc, origin)
        except AuditError as exc:
            row["state"] = str(exc)
        except OSError as exc:
            row["state"] = _audit_os_reason(exc)
    after = _audit_observe(_audit_inventory, source)
    if not isinstance(after, tuple) or after != inventory:
        result["acknowledged_state"] = "changed_during_audit"
    for rel, row in zip(paths, result["files"]):
        if rel in local_stamps:
            local = _audit_observe(_audit_local, checkout, rel)
            if not isinstance(local, tuple) or local[1] != local_stamps[rel]:
                row["local"] = {"state": "changed_during_audit"}
    if result["acknowledged_state"] in {"observed", "empty"} and len(manifests) == len(
        paths
    ):
        result["snapshot_digest"] = hashlib.sha256(
            json.dumps(manifests, sort_keys=True).encode()
        ).hexdigest()
    observed = {"match", "missing_events", "missing_source", "duplicate_sources"}
    result["audit_complete"] = (
        result["acknowledged_state"] in {"observed", "empty"}
        and result["origin"]["oid"] is not None
        and all(
            row["state"] == "observed"
            and all(row[side]["state"] in observed for side in ("local", "origin"))
            for row in result["files"]
        )
    )
    return result


def main(args):
    try:
        if args[0] == "audit-acknowledged" and len(args) == 3:
            result = acknowledgement_audit(*args[1:])
            print(json.dumps(result, sort_keys=True))
            return 0 if result["audit_complete"] else 1
        elif args[0] == "capture" and len(args) == 6:
            capture(*args[1:])
        elif args[0] == "check-destination" and len(args) == 3:
            check_destination(*args[1:])
        elif args[0] == "guard-archive" and len(args) == 4:
            guard_archive(*args[1:])
        elif args[0] == "guard-archive-commits" and len(args) >= 3:
            guard_archive_commits(args[1], args[2], args[3:])
        elif args[0] == "check-backlog" and len(args) in (3, 4):
            check_backlog(*args[1:])
        elif args[0] == "check-snapshot-scope" and len(args) == 3:
            check_snapshot_scope(*args[1:])
        elif args[0] == "conditional-receipt" and len(args) == 7:
            conditional_receipt(*args[1:])
        elif args[0] == "check-checkout" and len(args) == 2:
            check_checkout(*args[1:])
        elif args[0] == "check-profile" and len(args) in (2, 3):
            check_profile(args[1], args[2] if len(args) == 3 else None)
        elif args[0] == "check-bounds" and len(args) == 2:
            with open(args[1], "rb") as stream:
                bounded_document_check(stream.read(MAX_FILE_BYTES + 1))
        elif args[0] == "install" and len(args) == 4:
            install(*args[1:])
        elif args[0] == "receipt" and len(args) == 5:
            receipt(*args[1:])
        elif args[0] == "check-acknowledgement" and len(args) == 4:
            check_acknowledgement(*args[1:])
        elif args[0] == "acknowledge" and len(args) == 6:
            acknowledge(*args[1:])
        else:
            raise ValueError("invalid invocation")
        return 0
    except BoundsError:
        print("ledger source bounds exceeded (content withheld)", file=sys.stderr)
        return BOUNDS_EXIT
    except (OSError, ValueError, yaml.YAMLError, subprocess.CalledProcessError):
        print("ledger source validation failed (content withheld)", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
