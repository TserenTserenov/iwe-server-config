#!/usr/bin/env python3
"""Local session release (WP-484 F228). No Git mutation or publication.

The RUN card is the durable transaction record. The retained semaphore is a
projection, not delivery evidence. A prepared release fences mutations even
when a later ledger/marker operation fails. Retrying finishes that transaction.
Lock order: admission -> transition -> sorted worktrees -> publication -> RUN
start -> hook -> obligation -> marker. The release itself never waits: a busy
lock means "not performed, retry". Publishers, cleanup and hooks are ordinary
work that used to queue behind each other, so they wait up to a bounded time
instead of failing on contention. Waiting publishers must acquire publication
before worktree; publication_scope rejects an inverse acquisition with an
inherited worktree descriptor. Release uses nonblocking acquisitions throughout,
so its opposite ordering never waits while holding a worktree. Publishers retain
locks in child processes; nested publishers validate inherited descriptors.
The note-publication callback takes transition nonblocking: ordinary close holds
transition while calling a worktree publisher. Waiting on that inverse edge
would otherwise form a transition/worktree cycle.
"""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import fcntl
import hashlib
import json
import math
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

import yaml

# Seconds a publisher/cleanup waits for a busy lock before giving up; hooks run
# on every tool call and must not stall a turn, so they wait far less.
PUBLISH_WAIT_S = 30.0
HOOK_WAIT_S = 2.0  # Codex prompt/pretool has a 10s total hook budget.
TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,255}\Z")
VERSION = "local-release/v1"
SUFFIX = ".closed-local"


class ReleaseError(RuntimeError):
    pass


class LockBusy(ReleaseError):
    pass


RECORD_ERRORS = (RuntimeError, OSError, ValueError, TypeError, KeyError, yaml.YAMLError)
AGENT_FAMILIES = ("codex", "claude-code")


def configured_wait(name: str, default: float, maximum: float) -> float:
    # Lazy parsing: a publisher setting must not break status or release imports.
    try:
        value = float(os.environ.get(name, default))
    except (ValueError, TypeError) as exc:
        raise ReleaseError(
            f"{name} must be a finite number from 0 to {maximum:g}"
        ) from exc
    require(
        math.isfinite(value) and 0 <= value <= maximum,
        f"{name} must be a finite number from 0 to {maximum:g}",
    )
    return value


@contextlib.contextmanager
def publication_budget():
    """One inherited queue budget, below the shortest supported caller (100s)."""
    key = "IWE_LOCAL_RELEASE_WAIT_DEADLINE"
    previous = os.environ.get(key)
    deadline = time.monotonic() + configured_wait(
        "IWE_LOCAL_RELEASE_PUBLISH_WAIT_S", PUBLISH_WAIT_S, 30.0
    )
    if previous is not None:
        inherited = float(previous)
        require(
            math.isfinite(inherited) and inherited >= 0,
            "invalid inherited wait deadline",
        )
        deadline = min(deadline, inherited)
    os.environ[key] = str(deadline)
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = previous


def publication_wait() -> float:
    return max(
        0.0, float(os.environ["IWE_LOCAL_RELEASE_WAIT_DEADLINE"]) - time.monotonic()
    )


def acquire_flock(fd: int, wait: float):
    require(math.isfinite(wait) and 0 <= wait <= 900.0, "invalid lock wait budget")
    deadline = time.monotonic() + wait
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError as exc:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise LockBusy(
                    "close/publish or another transition is running; lock wait exhausted"
                ) from exc
            time.sleep(min(0.05, remaining))
            if time.monotonic() >= deadline:
                raise LockBusy(
                    "close/publish or another transition is running; lock wait exhausted"
                ) from exc


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def root() -> Path:
    return Path(os.environ.get("IWE_ROOT", str(Path.home() / "IWE"))).resolve()


def runtime() -> Path:
    return root() / ".iwe-runtime"


def cards_dir() -> Path:
    # Never cwd: receipts must survive closing/retaining a worktree.
    return (
        root()
        / os.environ.get("IWE_GOVERNANCE_REPO", "DS-my-strategy")
        / "inbox/agent/tasks"
    )


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def safe_read(path: Path) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(
            stat.S_ISREG(before.st_mode)
            and before.st_uid == os.geteuid()
            and before.st_nlink == 1
            and not before.st_mode & 0o022
            and 0 < before.st_size <= 4 * 1024 * 1024,
            f"unsafe record: {path}",
        )
        raw = b""
        while len(raw) <= before.st_size:
            chunk = os.read(fd, min(65536, before.st_size + 1 - len(raw)))
            if not chunk:
                break
            raw += chunk
        after, current = os.fstat(fd), path.lstat()
        keys = (
            "st_dev",
            "st_ino",
            "st_mode",
            "st_nlink",
            "st_size",
            "st_mtime_ns",
            "st_ctime_ns",
        )
        require(
            all(
                getattr(before, k) == getattr(after, k) == getattr(current, k)
                for k in keys
            )
            and len(raw) == before.st_size,
            f"record changed while reading: {path}",
        )
        return raw
    finally:
        os.close(fd)


def metadata(raw: bytes) -> dict:
    lines = raw.decode("utf-8").splitlines()
    require(lines and lines[0] == "---" and "---" in lines[1:], "missing frontmatter")
    header = "\n".join(lines[1 : lines.index("---", 1)])
    node = yaml.compose(header, Loader=yaml.SafeLoader)
    require(isinstance(node, yaml.MappingNode), "frontmatter must be a mapping")
    keys = [key.value for key, _ in node.value if isinstance(key, yaml.ScalarNode)]
    require(
        len(keys) == len(node.value) == len(set(keys)) and "<<" not in keys,
        "duplicate or merged frontmatter keys",
    )
    result = yaml.safe_load(header)
    for key, value in node.value:
        if key.value in {
            "agent",
            "session_id",
            "harness_session_id",
            "owner_session_id",
        }:
            require(isinstance(value, yaml.ScalarNode), "identity must be a scalar")
            result[key.value] = value.value
    return result


def sync_directory(path: Path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write(path: Path, raw: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() or path.is_symlink():
        safe_read(path)
    fd, name = tempfile.mkstemp(prefix=".local-release-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        sync_directory(path.parent)
    finally:
        Path(name).unlink(missing_ok=True)


def write_card(path: Path, card: dict):
    # process-runner.write_card auto-commits terminal cards. This path must not.
    raw = (
        "---\n"
        + yaml.safe_dump(card, allow_unicode=True, sort_keys=False)
        + "---\n\nLocal release receipt. Publication remains pending.\n"
    ).encode()
    atomic_write(path, raw)


@contextlib.contextmanager
def exclusive_lock(path: Path, mode: int = 0o600, wait: float = 0.0):
    """Take an exclusive flock; zero never waits, otherwise use a finite budget."""
    require(math.isfinite(wait) and 0 <= wait <= 900.0, "invalid lock wait budget")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    parent = path.parent.lstat()
    require(
        stat.S_ISDIR(parent.st_mode)
        and parent.st_uid == os.geteuid()
        and not parent.st_mode & 0o022,
        "unsafe lock directory",
    )
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        # Shell children use low descriptors for receipts and their own locks
        # (ledger-publish uses 3/9; ds-publish also closes 9 before exec).
        # Preserve this open file description outside that range, as the
        # owner lock in lib/day-close-ledger-route.py does. Only pass_fds may
        # intentionally carry it across exec; the inode checks stay unchanged.
        low_fd = fd
        fd = fcntl.fcntl(fd, fcntl.F_DUPFD, 32)
        os.close(low_fd)
        os.set_inheritable(fd, False)
        info = os.fstat(fd)
        require(
            stat.S_ISREG(info.st_mode)
            and info.st_uid == os.geteuid()
            and info.st_nlink == 1
            and stat.S_IMODE(info.st_mode) in {mode, 0o600},
            "unsafe lock file",
        )
        acquire_flock(fd, wait)
        current, current_parent = path.lstat(), path.parent.lstat()
        require(
            stat.S_ISREG(current.st_mode)
            and current.st_uid == os.geteuid()
            and stat.S_IMODE(current.st_mode) in {mode, 0o600}
            and current.st_nlink == 1
            and (info.st_dev, info.st_ino) == (current.st_dev, current.st_ino)
            and (parent.st_dev, parent.st_ino)
            == (current_parent.st_dev, current_parent.st_ino),
            "lock path changed",
        )
        yield fd
    finally:
        os.close(fd)


def transition_lock(semaphore: Path) -> Path:
    return (
        runtime()
        / "session-transition-locks"
        / (digest(str(semaphore).encode()) + ".lock")
    )


def worktree_lock(worktree: Path) -> Path:
    info = worktree.resolve(strict=True).stat()
    require(stat.S_ISDIR(info.st_mode), "worktree lock requires an existing directory")
    return (
        runtime()
        / "session-transition-locks"
        / f"worktree-{info.st_dev}-{info.st_ino}.lock"
    )


def exclusive_rename(source: Path, destination: Path):
    """Atomic no-replace rename on the supported Mac/Linux hosts."""
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        function = libc.renamex_np
        function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        result = function(
            os.fsencode(source), os.fsencode(destination), 0x4
        )  # RENAME_EXCL
    elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        function = libc.renameat2
        function.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        result = function(
            -100, os.fsencode(source), -100, os.fsencode(destination), 1
        )  # NOREPLACE
    else:
        raise ReleaseError("atomic no-replace rename is unavailable on this host")
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def agent_aliases(agent: str) -> tuple[str, ...]:
    return ("claude-code", "claude") if agent in {"claude-code", "claude"} else (agent,)


def hook_lock_path(agent: str, harness: str) -> Path:
    require(
        bool(TOKEN.fullmatch(agent)) and bool(TOKEN.fullmatch(harness)),
        "invalid hook identity",
    )
    return (
        runtime()
        / "session-transition-locks"
        / ("hook-" + digest(f"{agent_aliases(agent)[0]}:{harness}".encode()) + ".lock")
    )


def validated_lock_fd(fd, path: Path) -> int | None:
    if type(fd) is not int or fd < 3:
        return None
    try:
        actual, expected = os.fstat(fd), path.lstat()
        require(
            stat.S_ISREG(actual.st_mode)
            and actual.st_uid == os.geteuid()
            and actual.st_nlink == 1
            and stat.S_IMODE(actual.st_mode) == 0o600
            and (actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino),
            "invalid inherited lock",
        )
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except OSError:
        return None


def inherited_hook_fd(agent: str, harness: str) -> int | None:
    entry = json.loads(os.environ.get("IWE_RELEASE_HOOK_FD", "{}"))
    if not isinstance(entry, dict) or entry.get("identity") != [
        agent_aliases(agent)[0],
        harness,
    ]:
        return None
    return validated_lock_fd(entry.get("fd"), hook_lock_path(agent, harness))


def run_hook(
    agent: str, harness: str, command: list[str], event: str | None = None
) -> int:
    payload = sys.stdin.read()
    event = event or json.loads(payload).get("hook_event_name", "Stop")
    try:
        wait = configured_wait("IWE_LOCAL_RELEASE_HOOK_WAIT_S", HOOK_WAIT_S, 2.0)
        with exclusive_lock(hook_lock_path(agent, harness), wait=wait) as fd:
            if release_status(agent, harness).get("released"):
                return 0
            if mutation_fenced(agent, harness):
                response = {
                    "decision": "block",
                    "reason": "Локальное освобождение не завершено. Повтори release-local; маркеры не восстановлены.",
                }
                print(
                    json.dumps(response if event == "Stop" else {}, ensure_ascii=False)
                )
                return 0
            env = dict(
                os.environ,
                IWE_RELEASE_HOOK_FD=json.dumps(
                    {"identity": [agent_aliases(agent)[0], harness], "fd": fd}
                ),
            )
            return subprocess.run(
                command, input=payload, text=True, env=env, pass_fds=(fd,)
            ).returncode
    except RECORD_ERRORS as exc:
        reason = "Не удалось проверить состояние сессии; повтори действие. " + str(exc)
        if event == "Stop":
            response = {"decision": "block", "reason": reason}
        elif event == "PreToolUse":
            response = {
                "hookSpecificOutput": {
                    "hookEventName": event,
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        else:
            response = {
                "hookSpecificOutput": {
                    "hookEventName": event,
                    "additionalContext": reason,
                }
            }
        print(json.dumps(response, ensure_ascii=False))
        return 0


def native_identity(agent: str) -> str:
    key = {
        "codex": "CODEX_THREAD_ID",
        "claude-code": "CLAUDE_CODE_SESSION_ID",
        "claude": "CLAUDE_CODE_SESSION_ID",
    }.get(agent)
    value = os.environ.get(key, "") if key else ""
    require(
        bool(TOKEN.fullmatch(value)),
        "exact native harness identity is required; no PID/slug/cwd fallback",
    )
    return value


def matching_records(agent: str, harness: str) -> list[tuple[Path, dict, bytes]]:
    found = []
    aliases = agent_aliases(agent)
    paths = {
        p
        for alias in aliases
        for p in (runtime() / "sessions").glob(f"{alias}-*.open*")
    }
    for path in sorted(paths):
        if path.name.endswith((".lease", ".lock")) or ".lease." in path.name:
            continue
        raw = safe_read(path)
        # Unrelated malformed records do not establish ownership. Duplicate
        # matching identity fields still reach the strict parser and refuse.
        if not re.search(
            rb"^harness_session_id:\s*[\"']?"
            + re.escape(harness.encode())
            + rb"[\"']?\s*$",
            raw,
            re.M,
        ):
            continue
        fields = metadata(raw)
        require(
            fields.get("agent") in aliases
            and fields.get("harness_session_id") == harness,
            "ambiguous agent/harness identity",
        )
        require(
            bool(TOKEN.fullmatch(str(fields.get("session_id", "")))),
            "invalid guard identity",
        )
        expected = f"{fields['agent']}-{fields['session_id']}.open"
        housekeeping = fields.get("housekeeping")
        legacy_housekeeping_closed = (
            path.name.endswith(".open.closed")
            and isinstance(housekeeping, str)
            and bool(TOKEN.fullmatch(housekeeping))
            and path.name
            == f"{fields['agent']}-housekeeping-{housekeeping}.open.closed"
        )
        legacy_housekeeping_active = (
            path.name.endswith(".open")
            and isinstance(housekeeping, str)
            and bool(TOKEN.fullmatch(housekeeping))
            and fields.get("slug") == housekeeping
            and "wp" not in fields
            and path.name == f"{fields['agent']}-housekeeping-{housekeeping}.open"
        )
        ordinary_name = path.name == expected or path.name.startswith(expected + ".")
        valid_name = (
            legacy_housekeeping_closed or legacy_housekeeping_active
            if housekeeping is not None
            else ordinary_name
        )
        require(valid_name, "semaphore filename/identity mismatch")
        found.append((path, fields, raw))
    return found


def receipt_path(agent: str, guard: str) -> Path:
    require(
        bool(TOKEN.fullmatch(agent)) and bool(TOKEN.fullmatch(guard)),
        "unsafe receipt identity",
    )
    return cards_dir() / f"RUN-local-release-{agent}-{guard}.md"


def load_receipt(path: Path) -> dict:
    card = metadata(safe_read(path))
    require(
        card.get("process_id") == "local-release"
        and card.get("release_version") == VERSION
        and card.get("publication") == "pending"
        and card.get("retention") == "held"
        and card.get("status") in {"releasing", "completed"},
        "invalid local-release receipt",
    )
    sem = card.get("semaphore", {})
    require(
        isinstance(sem, dict)
        and path == receipt_path(card.get("agent", ""), sem.get("session_id", "")),
        "receipt path/identity mismatch",
    )
    require(
        card.get("owner_session_id") == sem.get("harness_session_id")
        and card.get("agent") == sem.get("agent"),
        "receipt owner mismatch",
    )
    require(
        card.get("run_id") == path.stem.removeprefix("RUN-"),
        "receipt run identity mismatch",
    )
    require(
        card.get("ownership")
        == {"releasing": "releasing", "completed": "released"}[card["status"]],
        "receipt ownership/status mismatch",
    )
    require(
        isinstance(card.get("ledger_date"), str)
        and bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}", card["ledger_date"])),
        "invalid receipt ledger date",
    )
    datetime.fromisoformat(card["ledger_date"])
    receipt_semaphore(card)
    require(
        isinstance(card.get("worktrees"), list) and card["worktrees"],
        "receipt has no retained worktree",
    )
    paths = []
    for item in card["worktrees"]:
        require(
            isinstance(item, dict) and isinstance(item.get("path"), str),
            "invalid worktree snapshot",
        )
        worktree = Path(item["path"])
        require(
            worktree.is_absolute() and str(worktree.resolve()) == item["path"],
            "invalid worktree path",
        )
        identity = item.get("directory_identity")
        require(
            isinstance(identity, list)
            and len(identity) == 2
            and all(type(value) is int and value >= 0 for value in identity),
            "invalid directory identity",
        )
        require(
            type(item.get("exclusive_worktree")) is bool,
            "missing exclusive worktree classification",
        )
        require(
            item["exclusive_worktree"]
            == (runtime() / "isolated-worktrees" in worktree.parents),
            "inconsistent worktree classification",
        )
        for key in ("head", "branch", "common_dir", "publication_observation"):
            require(
                isinstance(item.get(key), str) and item[key],
                "incomplete worktree snapshot: " + key,
            )
        for key in ("unpublished_commits", "modified_paths", "untracked_paths"):
            value = item.get(key)
            require(
                value == "unknown"
                or isinstance(value, list)
                and all(isinstance(v, str) for v in value),
                "incomplete worktree snapshot: " + key,
            )
        paths.append(worktree)
    require(
        len(paths) == len(set(paths)) and sorted(paths) == declared_worktrees(sem),
        "receipt omits or adds a declared worktree",
    )
    require(isinstance(card.get("markers"), list), "receipt has no marker inventory")
    allowed = {str(p) for p in marker_paths(card["agent"], card["owner_session_id"])}
    for item in card["markers"]:
        require(
            isinstance(item, dict)
            and item.get("path") in allowed
            and isinstance(item.get("sha256"), str)
            and bool(re.fullmatch("[a-f0-9]{64}", item["sha256"])),
            "invalid receipt marker",
        )
    return card


def git_read(worktree: Path, *args) -> str | None:
    env = dict(
        os.environ,
        GIT_OPTIONAL_LOCKS="0",
        GIT_NO_REPLACE_OBJECTS="1",
        GIT_GRAFT_FILE="/dev/null/iwe-no-grafts",
    )
    try:
        result = subprocess.run(
            ["git", "-C", str(worktree), *args],
            env=env,
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return (
        result.stdout.decode("utf-8", "surrogateescape")
        if result.returncode == 0
        else None
    )


def snapshot(worktree: Path) -> dict:
    require(
        worktree.is_dir() and not worktree.is_symlink(),
        f"retained worktree is missing/unsafe: {worktree}",
    )
    top = git_read(worktree, "rev-parse", "--show-toplevel")
    require(
        top is not None and Path(top.strip()).resolve() == worktree,
        "not an exact Git worktree",
    )
    if (worktree / ".git").is_file():
        require(
            runtime() / "isolated-worktrees" in worktree.parents,
            "linked worktree outside the managed store; cleanup contract unavailable",
        )
    head = git_read(worktree, "rev-parse", "--verify", "HEAD")
    branch = git_read(worktree, "symbolic-ref", "--quiet", "--short", "HEAD")
    status = git_read(
        worktree, "status", "--porcelain=v1", "-z", "--untracked-files=all"
    )
    changed, untracked = [], []
    if status is not None:
        entries = iter(status.split("\0"))
        for entry in entries:
            if not entry:
                continue
            (untracked if entry[:2] == "??" else changed).append(entry[3:])
            if "R" in entry[:2] or "C" in entry[:2]:
                changed.append(next(entries))
    upstream = git_read(worktree, "rev-parse", "--symbolic-full-name", "@{upstream}")
    commits = git_read(worktree, "rev-list", "@{upstream}..HEAD") if upstream else None
    info = worktree.stat()
    common = git_read(
        worktree, "rev-parse", "--path-format=absolute", "--git-common-dir"
    )
    return {
        "path": str(worktree),
        "directory_identity": [info.st_dev, info.st_ino],
        "common_dir": common.strip() if common else "unknown",
        "exclusive_worktree": (worktree / ".git").is_file(),
        "head": head.strip() if head else "unknown",
        "branch": branch.strip() if branch else "unknown",
        "unpublished_commits": commits.splitlines()
        if commits is not None
        else "unknown",
        "publication_observation": "local tracking ref only; remote freshness unknown",
        "modified_paths": sorted(set(changed)) if status is not None else "unknown",
        "untracked_paths": sorted(untracked) if status is not None else "unknown",
    }


def declared_worktrees(fields: dict) -> list[Path]:
    paths = {
        Path(fields[k]).resolve()
        for k in ("isolated_worktree", "governance_worktree", "orz_sessions_dir")
        if fields.get(k)
    }
    require(paths, "no declared worktree; cannot claim retention")
    return sorted(paths)


def warn_damaged_record(path: Path, error):
    print(
        f"WARNING: damaged local-release record {path}: {error}; "
        "only attributable ownership/worktrees are fenced; manual review required",
        file=sys.stderr,
    )


def untrusted_metadata(path: Path) -> dict:
    """Discovery/hints only. Never use this to authorize release or mutation."""
    try:
        return metadata(safe_read(path))
    except RECORD_ERRORS as exc:
        warn_damaged_record(path, exc)
        return {}


def embedded_semaphores(card: dict):
    fields = card.get("semaphore")
    if isinstance(fields, dict):
        yield fields
    text = card.get("semaphore_text")
    if isinstance(text, str):
        try:
            yield metadata(text.encode())
        except RECORD_ERRORS as exc:
            # The other surviving hints still apply independently.
            print(
                f"WARNING: damaged embedded release semaphore: {exc}", file=sys.stderr
            )


def receipt_paths() -> list[Path]:
    directory = cards_dir()
    require(not directory.is_symlink(), "unsafe receipt store")
    try:
        directory.stat()
    except FileNotFoundError:
        return []  # No local release has created the store yet.
    # Enumeration/I/O failure is different from one corrupt neighbor. Never
    # silently turn an unreadable inventory into an empty retention set.
    return sorted(
        p
        for p in directory.iterdir()
        if p.name.startswith("RUN-local-release-") and p.name.endswith(".md")
    )


def orphan_receipts(agent: str, harness: str):
    """Find exact owner hints when its semaphore is missing; no success proof."""
    prefixes = tuple(f"RUN-local-release-{alias}-" for alias in agent_aliases(agent))
    for path in receipt_paths():
        if not path.name.startswith(prefixes):
            continue
        card = untrusted_metadata(path)
        if card.get("owner_session_id") == harness or any(
            fields.get("harness_session_id") == harness
            for fields in embedded_semaphores(card)
        ):
            yield path


def declared_retention_hints(fields: dict):
    for key in ("isolated_worktree", "governance_worktree", "orz_sessions_dir"):
        value = fields.get(key)
        if isinstance(value, str) and Path(value).is_absolute():
            yield {"path": value}


def matching_semaphore_hints(receipt: Path):
    # Preserve the entire agent/guard key, avoiding ambiguous splitting of
    # hyphenated agent aliases. Fields must reconstruct this exact filename.
    key = receipt.name.removeprefix("RUN-local-release-").removesuffix(".md")
    if not TOKEN.fullmatch(key):
        return
    for path in sorted((runtime() / "sessions").glob(f"{key}.open*")):
        if path.name != key + ".open" and not path.name.startswith(key + ".open."):
            continue
        if path.name.endswith((".lease", ".lock")) or ".lease." in path.name:
            continue
        fields = untrusted_metadata(path)
        try:
            if (
                receipt_path(fields.get("agent", ""), fields.get("session_id", ""))
                == receipt
            ):
                yield from declared_retention_hints(fields)
        except RECORD_ERRORS as exc:
            warn_damaged_record(path, exc)


def damaged_retention_hints(receipt: Path):
    card = untrusted_metadata(receipt)
    snapshots = card.get("worktrees")
    if isinstance(snapshots, list):
        yield from (item for item in snapshots if isinstance(item, dict))
    for fields in embedded_semaphores(card):
        yield from declared_retention_hints(fields)
    yield from matching_semaphore_hints(receipt)


def retention_hints():
    """Restrictions only: errors stay scoped; no damaged hint grants access."""
    for path in receipt_paths():
        try:
            card = load_receipt(path)
        except RECORD_ERRORS as exc:
            warn_damaged_record(path, exc)
            yield from damaged_retention_hints(path)
        else:
            yield from card["worktrees"]
    # A missing receipt cannot silently release an explicitly retained copy.
    for path in sorted((runtime() / "sessions").glob("*.open" + SUFFIX)):
        fields = untrusted_metadata(path)
        expected = f"{fields.get('agent')}-{fields.get('session_id')}.open{SUFFIX}"
        if path.name == expected:
            yield from declared_retention_hints(fields)
        else:
            warn_damaged_record(path, "retained filename/identity mismatch")


def retention_matches(item: dict, target: str, identity: list[int]) -> bool:
    value = item.get("path")
    path = None
    managed = False
    if isinstance(value, str) and Path(value).is_absolute():
        store = runtime() / "isolated-worktrees"
        managed = store in Path(value).parents
        try:
            path = Path(value).resolve()
            managed = managed or store in path.parents
        except (OSError, ValueError, RuntimeError) as exc:
            print(f"WARNING: unusable retention path hint: {exc}", file=sys.stderr)
    observed = item.get("directory_identity")
    inode_match = (
        isinstance(observed, list)
        and len(observed) == 2
        and all(type(v) is int and v >= 0 for v in observed)
        and observed == identity
    )
    managed_target = runtime() / "isolated-worktrees" in Path(target).parents
    return (
        item.get("exclusive_worktree") is True
        or managed
        or (inode_match and managed_target)
    ) and (path is not None and str(path) == target or inode_match)


def assert_worktree_available(worktree: Path):
    target = str(worktree.resolve())
    info = worktree.stat()
    identity = [info.st_dev, info.st_ino]
    for item in retention_hints():
        if retention_matches(item, target, identity):
            raise ReleaseError(
                "worktree intentionally retained without publication; separate pilot decision required"
            )


def mutation_fenced(agent: str, harness: str) -> bool:
    """Choose the exact current generation before inspecting old receipts."""
    records = matching_records(agent, harness)
    # Housekeeping shares the harness but is not a new ordinary session.
    # It must not hide an earlier local-release fence.
    active = [
        (p, f)
        for p, f, _ in records
        if p.name.endswith(".open") and not f.get("housekeeping")
    ]
    if active:
        return any(
            (path := receipt_path(f["agent"], f["session_id"])).exists()
            or path.is_symlink()
            for _, f in active
        )
    if any(
        p.name.endswith(SUFFIX)
        or (receipt := receipt_path(f["agent"], f["session_id"])).exists()
        or receipt.is_symlink()
        for p, f, _ in records
    ):
        return True  # Missing/corrupt proof never authorizes rearming.
    return any(True for _ in orphan_receipts(agent, harness))


def harness_fenced(harness: str) -> bool:
    return any(mutation_fenced(agent, harness) for agent in AGENT_FAMILIES)


def harness_release_status(harness: str) -> dict:
    """Own proof only; all fenced-but-unproven outcomes block Stop explicitly."""
    states = []
    has_active = False
    for agent in AGENT_FAMILIES:
        has_active |= any(
            p.name.endswith(".open") for p, _, _ in matching_records(agent, harness)
        )
        if mutation_fenced(agent, harness):
            states.append(release_status(agent, harness))
    if not states:
        return {"released": False, "fenced": False}
    # The agent-less obligation API cannot disambiguate cross-family ID reuse.
    return {
        "released": not has_active and all(s.get("released") for s in states),
        "fenced": True,
    }


def guard_fenced(guard: str) -> bool:
    return any(
        (path := receipt_path(alias, guard)).exists() or path.is_symlink()
        for agent in AGENT_FAMILIES
        for alias in agent_aliases(agent)
    )


def assert_semaphore_available(path: Path):
    fields = metadata(safe_read(path))
    if not fields.get("agent") or not fields.get("session_id"):
        return  # Legacy identity is checked by the ordinary guard itself.
    receipt = receipt_path(fields.get("agent", ""), fields.get("session_id", ""))
    require(
        not receipt.exists() and not receipt.is_symlink(),
        "local release prepared; mutation/cleanup refused",
    )


def publisher_identity_available():
    agent = os.environ.get("IWE_AGENT", "")
    for native_agent, key in (
        ("codex", "CODEX_THREAD_ID"),
        ("claude-code", "CLAUDE_CODE_SESSION_ID"),
    ):
        harness = os.environ.get(key, "")
        if harness:
            require(
                not mutation_fenced(native_agent, harness),
                "session locally released; publication refused",
            )
    guard = os.environ.get("IWE_PUBLICATION_SESSION_ID", "")
    if guard and agent:
        require(
            not any(
                receipt_path(alias, guard).exists() for alias in agent_aliases(agent)
            ),
            "session publication is fenced by local release",
        )


def inherited_worktree_fd(worktree: Path) -> int | None:
    """An env flag is never authority: validate the inherited open lock inode."""
    entries = json.loads(os.environ.get("IWE_RELEASE_LOCK_FDS", "{}"))
    fd = entries.get(str(worktree.resolve())) if isinstance(entries, dict) else None
    return validated_lock_fd(fd, worktree_lock(worktree))


def publication_lock() -> Path:
    return runtime() / "session-transition-locks" / "commit-push.lock"


def inherited_publication_fd() -> int | None:
    return validated_lock_fd(
        json.loads(os.environ.get("IWE_RELEASE_PUBLICATION_FD", "null")),
        publication_lock(),
    )


@contextlib.contextmanager
def publication_scope(guard: str = "", worktree: Path | None = None):
    with publication_budget(), contextlib.ExitStack() as stack:
        fd = inherited_publication_fd()
        if fd is None:
            require(
                not inherited_worktree_handles(),
                "lock order violation: publication must precede worktree",
            )
            fd = stack.enter_context(
                exclusive_lock(publication_lock(), wait=publication_wait())
            )
        publisher_identity_available()
        if worktree is not None:
            assert_worktree_available(worktree)
        if guard:
            require(
                not guard_fenced(guard),
                "guard locally released; publication refused",
            )
        previous = os.environ.get("IWE_RELEASE_PUBLICATION_FD")
        os.environ["IWE_RELEASE_PUBLICATION_FD"] = json.dumps(fd)
        try:
            yield fd
        finally:
            if previous is None:
                os.environ.pop("IWE_RELEASE_PUBLICATION_FD", None)
            else:
                os.environ["IWE_RELEASE_PUBLICATION_FD"] = previous


def run_publication(command: list[str]) -> int:
    """Serialize the multi-repository handler, including its direct Git paths."""
    require(command, "publication command required")
    with publication_scope() as fd:
        return subprocess.call(
            command, pass_fds=tuple(inherited_worktree_handles().values()) + (fd,)
        )


def inherited_worktree_handles() -> dict[str, int]:
    inherited = json.loads(os.environ.get("IWE_RELEASE_LOCK_FDS", "{}"))
    require(isinstance(inherited, dict), "invalid inherited worktree locks")
    return {
        path: handle
        for path, handle in inherited.items()
        if inherited_worktree_fd(Path(path)) == handle
    }


def publisher_check(worktree: Path) -> bool:
    if inherited_worktree_fd(worktree) is None:
        return False
    assert_worktree_available(worktree)
    publisher_identity_available()
    return True


def run_publisher(worktree: Path, command: list[str]) -> int:
    require(command, "publisher command required")
    worktree = worktree.resolve()
    with publication_budget(), contextlib.ExitStack() as stack:
        fd = inherited_worktree_fd(worktree)
        if fd is None:
            # Standalone ds-publish holds its source and then publishes a new
            # disposable worktree. Permit that free lock, but never wait for a
            # second worktree without global serialization (A->B / B->A cycle).
            wait = publication_wait()
            if inherited_worktree_handles() and inherited_publication_fd() is None:
                wait = 0.0
            fd = stack.enter_context(exclusive_lock(worktree_lock(worktree), wait=wait))
        assert_worktree_available(worktree)
        publisher_identity_available()
        valid = inherited_worktree_handles()
        valid[str(worktree)] = fd
        env = dict(os.environ, IWE_RELEASE_LOCK_FDS=json.dumps(valid))
        publication = inherited_publication_fd()
        handles = tuple(valid.values()) + (
            (publication,) if publication is not None else ()
        )
        return subprocess.call(command, env=env, pass_fds=handles)


def run_cleanup(worktree: Path, command: list[str]) -> int:
    require(command, "cleanup command required")
    with publication_budget():
        require(
            not inherited_worktree_handles(), "cleanup cannot nest under a publisher"
        )
        with exclusive_lock(worktree_lock(worktree), wait=publication_wait()) as fd:
            assert_worktree_available(worktree)
            return subprocess.call(command, pass_fds=(fd,))


def marker_paths(agent: str, harness: str) -> list[Path]:
    import close_obligation as obligation

    paths = [
        obligation._obligation_path(harness),
        obligation._marker_path(harness),
        obligation.INTENT_SENTINEL_DIR / f"{harness}.flag",
        obligation.INTENT_SENTINEL_DIR / f"{harness}.pending-reflection",
    ]
    if agent == "codex":
        directory = Path(
            os.environ.get("IWE_CODEX_CLOSE_DIR", "/private/tmp/iwe-codex-close")
        )
        paths += [
            directory / f"{harness}.json",
            directory / f"{harness}.pending-reflection.json",
        ]
    return paths


def capture_markers(agent: str, harness: str) -> list[dict]:
    result = []
    for path in marker_paths(agent, harness):
        if not path.exists() and not path.is_symlink():
            continue
        raw = safe_read(path)
        if path.suffix == ".json":
            obj = json.loads(raw)
            require(
                obj.get("session_id", harness) == harness, "foreign marker identity"
            )
        result.append({"path": str(path), "sha256": digest(raw)})
    return result


def remove_owned_markers(card: dict):
    allowed = set(marker_paths(card["agent"], card["owner_session_id"]))
    for item in card["markers"]:
        path = Path(item["path"])
        require(path in allowed, "receipt names a foreign marker path")
        if not path.exists() and not path.is_symlink():
            continue
        require(
            digest(safe_read(path)) == item["sha256"],
            "marker generation changed; release incomplete",
        )
        path.unlink()
        sync_directory(path.parent)
    require(
        not any(p.exists() or p.is_symlink() for p in allowed),
        "residual/new marker; retry cannot report success",
    )


def assert_no_running_close(agent: str, harness: str, fields: dict):
    import close_obligation as obligation

    state = obligation._load_obligation(harness)
    require(
        state is None or state.get("state") == "armed",
        "obligation is running; release not performed",
    )
    # Pending tickets are not consumed under the obligation lock. Once the RUN
    # receipt fences consume, these exact tickets can no longer start a close.
    directories = {cards_dir()}
    directories.update(p / "inbox/agent/tasks" for p in declared_worktrees(fields))
    for directory in sorted(directories):
        for path in directory.glob("RUN-quick-close-*.md"):
            card = metadata(safe_read(path))
            if card.get("owner_session_id") not in {harness, fields["session_id"]}:
                continue
            require(
                card.get("status") in {"completed", "failed", "cancelled"},
                "quick-close is running/waiting; release not performed",
            )
    require(
        not any(k.startswith(("close_delivery_", "close_publish_")) for k in fields),
        "prepared/published close exists; release not performed",
    )


def ledger_event(card: dict):
    import close_obligation as obligation

    event = {
        "run_id": card["run_id"],
        "agent": card["agent"],
        "session_id": card["semaphore"]["session_id"],
        "harness_session_id": card["owner_session_id"],
        "outcome": "closed_local",
        "publication": "pending",
        "retention": "held",
    }
    day = datetime.fromisoformat(card["ledger_date"])

    def recorded():
        document = obligation._load_ledger_day(day) or {}
        return any(
            obligation._ledger_event_matches(
                e, "session_closed_local", {"run_id": card["run_id"]}
            )
            for e in document.get("events", [])
        )

    if not recorded():
        # This event's route skips publisher kicks and Git setup. The receipt
        # pins its day so a retry after midnight does not create a second event.
        result = subprocess.run(
            [
                "bash",
                str(obligation.LEDGER_APPEND),
                "day",
                card["ledger_date"],
                "session_closed_local",
                json.dumps(event),
                "local-release",
            ],
            env=dict(os.environ, IWE_LEDGER_DIR=str(obligation.LEDGER_DIR)),
            capture_output=True,
            text=True,
            timeout=30,
        )
        require(
            result.returncode == 0, "ledger append failed: " + result.stderr.strip()
        )
    require(recorded(), "ledger append did not persist the local-release event")
    # ledger-append.sh fsyncs the replacement and its directory before success.
    # The event may now live in the host buffer, or already have moved from
    # pending to acknowledged/published on a retry. The merged read above is
    # the durable evidence; syncing the old canonical path can fail after a
    # successful buffered append.


def receipt_semaphore(card: dict) -> bytes:
    require(
        isinstance(card.get("semaphore_text"), str), "receipt has no original semaphore"
    )
    raw = card["semaphore_text"].encode()
    require(
        digest(raw) == card.get("semaphore_sha256"),
        "original semaphore digest mismatch",
    )
    fields = metadata(raw)
    require(fields == card["semaphore"], "receipt/semaphore metadata mismatch")
    return raw


def finish_release(path: Path, card: dict):
    sem = (
        runtime()
        / "sessions"
        / f"{card['agent']}-{card['semaphore']['session_id']}.open"
    )
    terminal = Path(str(sem) + SUFFIX)
    expected = receipt_semaphore(card)
    if sem.exists():
        require(
            digest(safe_read(sem)) == card["semaphore_sha256"],
            "open generation changed",
        )
        require(not terminal.exists(), "active and retained semaphore both exist")
        exclusive_rename(sem, terminal)
        sync_directory(sem.parent)
    else:
        require(
            safe_read(terminal) == expected, "retained semaphore does not match receipt"
        )
    remove_owned_markers(card)
    ledger_event(card)
    # Projection cleanup is exact; another session's pointer/lease is retained.
    lease = Path(str(sem) + ".lease")
    if lease.exists():
        lease_data = metadata(b"---\n" + safe_read(lease).rstrip() + b"\n---\n")
        require(
            lease_data.get("session_id") == card["semaphore"]["session_id"],
            "foreign lease",
        )
        lease.unlink()
        sync_directory(lease.parent)
    ptr = sem.parent / f"current-{card['agent']}.ptr"
    if ptr.exists() and safe_read(ptr).decode().strip() in {str(sem), sem.name}:
        ptr.unlink()
        sync_directory(ptr.parent)
    require(
        not sem.exists() and safe_read(terminal) == expected,
        "ownership release not confirmed",
    )
    card.update(
        status="completed",
        outcome="closed_local",
        ownership="released",
        completed_at=utc_now(),
    )
    write_card(path, card)
    require(
        load_receipt(path).get("status") == "completed", "terminal receipt not durable"
    )


def release(agent: str) -> dict:
    import close_obligation as obligation

    harness = native_identity(agent)
    locks = runtime() / "session-transition-locks"
    with contextlib.ExitStack() as stack:
        stack.enter_context(
            exclusive_lock(locks / "scheduled-quarantine-transition.lock")
        )
        records = matching_records(agent, harness)
        require(
            not any(
                p.name.endswith(".open") and f.get("housekeeping")
                for p, f, _ in records
            ),
            "active housekeeping cannot establish release identity",
        )
        active = [r for r in records if r[0].name.endswith(".open")]
        retained = [r for r in records if r[0].name.endswith(SUFFIX)]
        candidates = active
        if not active and retained:
            pending = []
            for record in retained:
                card = load_receipt(
                    receipt_path(record[1]["agent"], record[1]["session_id"])
                )
                require(
                    receipt_semaphore(card) == record[2], "retained generation mismatch"
                )
                if card["status"] != "completed":
                    pending.append(record)
            candidates = pending or retained
            if not pending and len(retained) > 1:
                # Never infer generation by age/slug. With no outstanding work,
                # exact completed proofs are sufficient; residual markers need
                # a single receipt whose inventory matches their bytes.
                with exclusive_lock(hook_lock_path(agent, harness)):
                    markers = capture_markers(agent, harness)
                    if not markers:
                        require(
                            release_status(agent, harness)["released"],
                            "release postconditions incomplete",
                        )
                        return {
                            "status": "completed",
                            "outcome": "closed_local",
                            "publication": "pending",
                            "retention": "held",
                            "receipts": [
                                str(receipt_path(r[1]["agent"], r[1]["session_id"]))
                                for r in retained
                            ],
                        }
                    candidates = [
                        r
                        for r in retained
                        if all(
                            m
                            in load_receipt(
                                receipt_path(r[1]["agent"], r[1]["session_id"])
                            )["markers"]
                            for m in markers
                        )
                    ]
                require(len(candidates) == 1, "residual marker generation is ambiguous")
        # A foreign suffix for the SAME generation remains ambiguous. Earlier
        # terminal generations do not prevent a new exact open from releasing.
        generation_ids = {r[1]["session_id"] for r in candidates}
        require(
            not any(
                r[1]["session_id"] in generation_ids
                and r not in candidates
                and not completed_artifact(r[0], r[2])
                for r in records
            ),
            "older/ambiguous semaphore artifacts; release not performed",
        )
        require(
            len(candidates) <= 1, "ambiguous session generation; release not performed"
        )
        if not candidates:
            require(
                not records,
                "non-active semaphore artifact exists; exact release requires an open binding or local receipt",
            )
            require(
                not mutation_fenced(agent, harness),
                "release receipt exists but its semaphore is missing; release not confirmed",
            )
            require(
                not capture_markers(agent, harness),
                "own residual marker without open-bound identity; release not performed",
            )
            return {"status": "no_session", "released": False}
        source, fields, raw = candidates[0]
        agent = fields["agent"]  # Preserve the actual namespace in the durable proof.
        sem = (
            source
            if source.name.endswith(".open")
            else Path(str(source)[: -len(SUFFIX)])
        )
        stack.enter_context(exclusive_lock(transition_lock(sem)))
        require(safe_read(source) == raw, "semaphore changed after lock")
        path = receipt_path(agent, fields["session_id"])
        existing = load_receipt(path) if path.exists() else None
        worktrees = (
            [Path(item["path"]) for item in existing["worktrees"]]
            if existing
            else declared_worktrees(fields)
        )
        for worktree in sorted(worktrees):
            stack.enter_context(exclusive_lock(worktree_lock(worktree)))
        stack.enter_context(exclusive_lock(publication_lock()))
        stack.enter_context(
            exclusive_lock(runtime() / "run-card-audit" / ".start.lock", mode=0o644)
        )
        stack.enter_context(exclusive_lock(hook_lock_path(agent, harness)))
        # Same lock files as close_obligation and the Codex marker writer.
        stack.enter_context(
            exclusive_lock(
                obligation.OBLIGATION_DIR / f"{obligation._session_hash(harness)}.lock"
            )
        )
        if agent == "codex":
            directory = Path(
                os.environ.get("IWE_CODEX_CLOSE_DIR", "/private/tmp/iwe-codex-close")
            )
            for name in (harness, harness + ".pending-reflection"):
                stack.enter_context(
                    exclusive_lock(directory / f"{name}.lock", mode=0o644)
                )
        if existing:
            require(
                existing["owner_session_id"] == harness,
                "receipt belongs to another harness",
            )
            card = existing
        else:
            require(
                source == sem,
                "retained semaphore without receipt; release not performed",
            )
            assert_no_running_close(agent, harness, fields)
            card = {
                "process_id": "local-release",
                "release_version": VERSION,
                "run_id": path.stem.removeprefix("RUN-"),
                "status": "releasing",
                "agent": agent,
                "owner_session_id": harness,
                "created_at": utc_now(),
                "ledger_date": datetime.now().strftime("%Y-%m-%d"),
                "publication": "pending",
                "ownership": "releasing",
                "retention": "held",
                "semaphore": fields,
                "semaphore_text": raw.decode(),
                "semaphore_sha256": digest(raw),
                "worktrees": [snapshot(p) for p in worktrees],
                "markers": capture_markers(agent, harness),
            }
            write_card(path, card)
        finish_release(path, card)
        return {
            "status": "completed",
            "outcome": "closed_local",
            "publication": "pending",
            "retention": "held",
            "receipt": str(path),
        }


def completed_artifact(path: Path, raw: bytes | None = None) -> bool:
    """Exact old sibling projection; never treats an active .open as released."""
    if path.name.endswith(".open"):
        return False
    raw = safe_read(path) if raw is None else raw
    fields = metadata(raw)
    receipt = receipt_path(fields.get("agent", ""), fields.get("session_id", ""))
    if not receipt.exists():
        return False
    card = load_receipt(receipt)
    terminal = (
        runtime()
        / "sessions"
        / f"{fields['agent']}-{fields['session_id']}.open{SUFFIX}"
    )
    return card["status"] == "completed" and raw == receipt_semaphore(
        card
    ) == safe_read(terminal)


def release_status(agent: str, harness: str) -> dict:
    require(
        bool(TOKEN.fullmatch(agent)) and bool(TOKEN.fullmatch(harness)),
        "invalid identity",
    )
    records = matching_records(agent, harness)
    if not records or any(p.name.endswith(".open") for p, _, _ in records):
        return {"released": False}
    local_guards = {
        fields["session_id"]
        for path, fields, _ in records
        if path.name.endswith(SUFFIX)
    }
    if not local_guards:
        return {"released": False}
    records = [
        record
        for record in records
        if not (
            record[0].name.endswith(".open.closed")
            and record[1]["session_id"] not in local_guards
        )
    ]
    for source, fields, raw in records:
        if not completed_artifact(source, raw):
            return {"released": False, "status": "releasing"}
    if any(p.exists() or p.is_symlink() for p in marker_paths(agent, harness)):
        return {"released": False, "status": "residual_marker"}
    return {
        "released": True,
        "outcome": "closed_local",
        "publication": "pending",
        "receipts": sorted(
            {str(receipt_path(f["agent"], f["session_id"])) for _, f, _ in records}
        ),
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("release", "status"):
        command = sub.add_parser(name)
        command.add_argument("--agent", required=True)
        if name == "status":
            command.add_argument("--harness-session-id", required=True)
    available = sub.add_parser("worktree-available")
    available.add_argument("path")
    available = sub.add_parser("semaphore-available")
    available.add_argument("path")
    for name in ("publisher-check", "publisher", "cleanup"):
        command = sub.add_parser(name)
        command.add_argument("path")
        if name != "publisher-check":
            command.add_argument("argv", nargs=argparse.REMAINDER)
    for name in ("hook-check", "hook"):
        command = sub.add_parser(name)
        command.add_argument("--agent", required=True)
        command.add_argument("--harness-session-id", required=True)
        if name == "hook":
            command.add_argument(
                "--event", choices=["Stop", "UserPromptSubmit", "PreToolUse"]
            )
            command.add_argument("argv", nargs=argparse.REMAINDER)
    sub.add_parser("publication-check")
    sub.add_parser("publication").add_argument("argv", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    try:
        if args.command == "publication-check":
            publisher_identity_available()
            return 0 if inherited_publication_fd() is not None else 1
        if args.command == "publication":
            return run_publication(
                args.argv[1:] if args.argv[:1] == ["--"] else args.argv
            )
        if args.command == "worktree-available":
            assert_worktree_available(Path(args.path))
            return 0
        if args.command == "semaphore-available":
            assert_semaphore_available(Path(args.path))
            return 0
        if args.command == "publisher-check":
            return 0 if publisher_check(Path(args.path)) else 1
        if args.command == "publisher":
            command = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
            return run_publisher(Path(args.path), command)
        if args.command == "cleanup":
            command = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
            return run_cleanup(Path(args.path), command)
        if args.command == "hook-check":
            return (
                0
                if inherited_hook_fd(args.agent, args.harness_session_id) is not None
                else 1
            )
        if args.command == "hook":
            command = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
            return run_hook(args.agent, args.harness_session_id, command, args.event)
        if args.command == "release":
            result = release(args.agent)
        else:
            result = release_status(args.agent, args.harness_session_id)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except RECORD_ERRORS as exc:
        print(json.dumps({"status": "error", "error": str(exc)}, ensure_ascii=False))
        return 7


if __name__ == "__main__":
    raise SystemExit(main())
