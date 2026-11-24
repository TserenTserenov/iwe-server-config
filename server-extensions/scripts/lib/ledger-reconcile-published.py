#!/usr/bin/env python3
"""Reconcile published ledger dirt under the sync and append locks.

HEAD may already equal the pinned target after a publication hook. That case
normalizes only proved dirty content, without merge or any ORIG_HEAD change.

--check is advisory and read-only. --apply requires the caller's ds-commit.lock
on fd 8, repeats every proof, takes dirty-guard.lock and both append lock forms,
and stages only origin bytes proven to contain all local event occurrences.
Already staged automation mirrors may accompany the ledger only when every
path is allowed by canon-refresh's existing automation contract and both index
and worktree equal the pinned origin blob/mode. A clean staged deletion (status
"D ") may accompany it too, under the same contract, only when the pinned
target also lacks that exact path and the index fully drops it. Other staging
is always refused; rollback restores only our ledger index entries, preserving
the original mirror or deletion.
Lock order: caller's commit lock, dirty-guard directory, then sorted ledger paths
(each mkdir fallback lock followed by flock; all acquisitions are nonblocking).
No history rewrite, stash, broad reset, or renewal of the expired bypass.
"""
import contextlib
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
# WP-539 Ф18: this guard lives outside DS-my-strategy on purpose (see module
# docstring's delivery note below main()), but ledger-event-diff.py is a
# stable, generic multiset-diff helper shared by DS-my-strategy's own publish
# pipeline (ledger-publish.sh, install-ledger-merge-driver.sh, and others) --
# moving it too would mean updating every one of those callers for no gain,
# since it was never the file that needed an emergency hotfix. Read it from
# its one true home instead of duplicating it here.
_EVENT_DIFF = Path(os.environ.get("IWE_ROOT", str(Path.home() / "IWE"))) / "DS-my-strategy/scripts/lib/ledger-event-diff.py"
SPEC = importlib.util.spec_from_file_location("ledger_events", _EVENT_DIFF)
EVENTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVENTS)
LEDGER_PATH = re.compile(r"machine/ledger/(?:day|week|month)/[0-9/]+/(?:day|week|month)-[0-9W-]+\.yaml\Z")


class Refused(Exception):
    """The complete proof required for mutation is absent."""


def git(*args, check=True):
    result = subprocess.run(["git", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        raise Refused(f"git {args[0]} failed: {result.stderr.decode(errors='replace').strip()}")
    return result


def oid(ref):
    return git("rev-parse", "--verify", ref).stdout.strip().decode()


def regular_path(path):
    if Path(path).resolve() != Path.cwd() / path:
        raise Refused(f"symlink in ledger path: {path}")
    mode = os.lstat(path).st_mode
    if not stat.S_ISREG(mode) or mode & 0o111:
        raise Refused(f"ledger is not a non-executable regular file: {path}")
    return stat.S_IMODE(mode)


def automation_allowlisted(path):
    """Reuse canon-refresh's own automation allowlist (sync-strategy-files)."""
    workspace = Path(os.environ.get("IWE_ROOT", str(Path.home() / "IWE")))
    library = workspace / "scripts/lib/automation-contract.sh"
    allowed = subprocess.run(
        ["bash", "-c", '. "$1" && automation_contract_path_allowed sync-strategy-files "$2"',
         "automation-contract", str(library), path], capture_output=True,
    )
    return allowed.returncode == 0


def published_mirror(path, target):
    """Prove a staged add/modify exactly matches pinned origin, allowlist included."""
    if not automation_allowlisted(path):
        raise Refused(f"staged intent outside the declared automation mirror: {path}")
    mode = regular_path(path)
    target_blob = oid(f"{target}:{path}")
    target_entry = git("ls-tree", "-z", target, "--", path).stdout
    staged_entry = git("ls-files", "--stage", "-z", "--", path).stdout
    if target_entry != f"100644 blob {target_blob}\t{path}".encode() + b"\0":
        raise Refused(f"mirror target is not a regular non-executable blob: {path}")
    if staged_entry != f"100644 {target_blob} 0\t{path}".encode() + b"\0":
        raise Refused(f"staged mirror differs from pinned origin: {path}")
    published = git("show", f"{target}:{path}").stdout
    if Path(path).read_bytes() != published:
        raise Refused(f"mirror has an unpublished worktree layer: {path}")
    return published, mode


def staged_deletion_allowed(path, target):
    """A clean staged deletion ("D ") has no blob to compare — prove absence instead:
    the same automation allowlist as published_mirror, the pinned target also lacking
    this exact path, and the index fully dropping it (not left behind by a dirty merge)."""
    if not automation_allowlisted(path):
        raise Refused(f"staged deletion outside the declared automation mirror: {path}")
    if git("ls-tree", "-z", target, "--", path).stdout:
        raise Refused(f"staged deletion differs from pinned origin: {path}")
    if git("ls-files", "--stage", "-z", "--", path).stdout:
        raise Refused(f"staged deletion is not fully dropped from the index: {path}")


def dirty_paths(target):
    paths, mirrors, deletions = [], {}, []
    for record in git("status", "--porcelain=v1", "-z", "--untracked-files=all").stdout.split(b"\0"):
        if not record:
            continue
        status, path = record[:2], os.fsdecode(record[3:])
        # The append locks are durable sidecars, never event payload or staging.
        if path.endswith(".lock") and LEDGER_PATH.fullmatch(path[:-5]):
            continue
        if path.endswith(".lockdir/owner") and LEDGER_PATH.fullmatch(path[:-14]):
            continue
        if LEDGER_PATH.fullmatch(path):
            if status not in (b" M", b"??"):
                raise Refused(f"preexisting staged ledger intent: {path}")
            paths.append(path)
        elif status in (b"M ", b"A "):
            mirrors[path] = published_mirror(path, target)
        elif status == b"D ":
            staged_deletion_allowed(path, target)
            deletions.append(path)
        else:
            raise Refused(f"non-ledger dirt or staged intent: {path}")
    return sorted(paths), mirrors, sorted(deletions)


def prove(target, branch):
    head = oid("HEAD")
    if git("symbolic-ref", "--short", "HEAD").stdout.strip().decode() != branch:
        raise Refused("branch changed")
    if git("merge-base", "--is-ancestor", head, target, check=False).returncode:
        raise Refused("published reconciliation requires current HEAD or its fast-forward successor")
    for name in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "rebase-merge", "rebase-apply"):
        if Path(git("rev-parse", "--git-path", name).stdout.strip().decode()).exists():
            raise Refused("repository has an unfinished Git operation")
    paths, mirrors, deletions = dirty_paths(target)
    if not paths and not mirrors and not deletions:
        raise Refused("no published ledgers or declared mirrors to reconcile")
    snapshots = {}
    for path in paths:
        mode = regular_path(path)
        original = Path(path).read_bytes()
        entry = git("ls-tree", "-z", target, "--", path).stdout.split(b"\t", 1)[0]
        if not entry.startswith(b"100644 blob "):
            raise Refused(f"origin lacks a regular ledger: {path}")
        published = git("show", f"{target}:{path}").stdout
        local_doc = EVENTS.yaml.load(original, Loader=EVENTS.DuplicateKeyLoader)
        remote_doc = EVENTS.yaml.load(published, Loader=EVENTS.DuplicateKeyLoader)
        if not isinstance(local_doc, dict) or not isinstance(remote_doc, dict):
            raise Refused(f"ledger is not a mapping: {path}")
        EVENTS._check_header(local_doc, remote_doc)
        if local_doc.get("schema") != "ledger/v1" or local_doc.get("scale") not in ("day", "week", "month"):
            raise Refused(f"unsupported ledger schema or scale: {path}")
        if not isinstance(local_doc.get("period"), str):
            raise Refused(f"missing ledger period: {path}")
        if Path(path).name != f"{local_doc['scale']}-{local_doc['period']}.yaml":
            raise Refused(f"ledger header does not match its path: {path}")
        for doc in (local_doc, remote_doc):
            if not isinstance(doc.get("events"), list) or any(not isinstance(e, dict) for e in doc["events"]):
                raise Refused(f"ledger events are not a list of mappings: {path}")
        if EVENTS.missing_events(local_doc["events"], remote_doc["events"]):
            raise Refused(f"unpublished local event occurrences: {path}")
        snapshots[path] = (original, published, mode)
    return head, snapshots, mirrors, deletions


@contextlib.contextmanager
def directory_lock(path):
    # Never steal a lock here. The next periodic tick retries after its owner exits.
    path = Path(path)
    try:
        path.mkdir()
    except FileExistsError as exc:
        raise Refused(f"lock busy: {path}") from exc
    owner = path / "owner"
    metadata = f"host={socket.gethostname()}\npid={os.getpid()}\n"
    owner.write_text(metadata)
    try:
        yield
    finally:
        if owner.exists() and owner.read_text() == metadata:
            owner.unlink()
            path.rmdir()


@contextlib.contextmanager
def append_lock(path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    # Cooperate with ledger-append's PATH-dependent mkdir fallback as well as flock.
    with directory_lock(path + ".lockdir"):
        fd = os.open(path + ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        except BlockingIOError as exc:
            raise Refused(f"append lock busy: {path}") from exc
        finally:
            os.close(fd)


def replace_bytes(path, content, mode):
    fd, tmp = tempfile.mkstemp(prefix=".ledger-reconcile-", dir=str(Path(path).parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def file_matches(path, content, mode):
    try:
        return regular_path(path) == mode and Path(path).read_bytes() == content
    except (OSError, Refused):
        return False


def verify_files(files, stage):
    for path, (content, mode) in files.items():
        if not file_matches(path, content, mode):
            raise Refused(f"file changed {stage}: {path}")


def verify_absent(paths, stage):
    for path in paths:
        if Path(path).exists():
            raise Refused(f"deleted path reappeared {stage}: {path}")


def save_recovery(git_dir, head, target, original_index, snapshots):
    backup = Path(tempfile.mkdtemp(prefix="ledger-reconcile-", dir=git_dir))
    files = []
    for number, (path, (original, _, mode)) in enumerate(snapshots.items()):
        (backup / str(number)).write_bytes(original)
        files.append({"path": path, "snapshot": str(number), "mode": mode})
    manifest = {"head": head, "target": target,
                "index_tree": original_index.decode().strip(), "files": files}
    (backup / "manifest.json").write_text(json.dumps(manifest))
    print(f"ledger-reconcile: recovery snapshot {backup}", flush=True)
    return backup


def stage_published(target, original_index, snapshots, mirrors, deletions):
    if git("write-tree").stdout != original_index:
        raise Refused("index changed before staging")
    if snapshots:
        git("add", "--", *snapshots)
    paths = set(snapshots) | set(mirrors) | set(deletions)
    staged = git("diff", "--cached", "--name-only", "-z").stdout.split(b"\0")
    if any(os.fsdecode(path) not in paths for path in staged if path):
        raise Refused("foreign path staged during reconciliation")
    for path in set(snapshots) | set(mirrors):
        expected_blob = oid(f"{target}:{path}")
        entry = git("ls-files", "--stage", "-z", "--", path).stdout
        if entry != f"100644 {expected_blob} 0\t{path}".encode() + b"\0":
            raise Refused(f"foreign staged content: {path}")
    for path in deletions:
        if git("ls-files", "--stage", "-z", "--", path).stdout:
            raise Refused(f"foreign staged content: {path}")
    return git("write-tree").stdout


def rollback_owned(head, original_index, expected_index, snapshots, written, backup):
    # Never remove a foreign HEAD, index layer, file edit, or recovery snapshot.
    safe = oid("HEAD") == head and git("write-tree").stdout == expected_index
    safe = safe and all(file_matches(p, snapshots[p][1], snapshots[p][2]) for p in written)
    if not safe:
        print(f"ledger-reconcile: foreign change; no rollback; recovery snapshot retained at {backup}",
              file=sys.stderr)
        return
    if expected_index != original_index:
        git("restore", "--staged", f"--source={head}", "--", *snapshots)
    for path in written:
        original, _, mode = snapshots[path]
        replace_bytes(path, original, mode)
    shutil.rmtree(backup)


def identical_untracked(head, target):
    """Paths the fast-forward adds that already sit on disk, untracked or ignored, as an exact
    copy of the target blob. `git merge` refuses to overwrite them although the result would be
    the same bytes; an earlier runner card hidden by .git/info/exclude stopped the Mac copy this
    way three times (WP-484 F327, 19.11 and 22.11). A copy that differs in any byte or mode is
    not returned, so it keeps refusing the merge as before."""
    found = {}
    raw = git("diff-tree", "-r", "-z", "--no-renames", "--diff-filter=A", head, target).stdout
    items = [os.fsdecode(item) for item in raw.split(b"\0") if item]
    for meta, path in zip(items[0::2], items[1::2]):
        mode, blob = meta.lstrip(":").split(" ")[1], meta.split(" ")[3]
        if mode not in ("100644", "100755") or Path(path).is_symlink() or not Path(path).is_file():
            continue
        if git("ls-files", "-z", "--", path).stdout:
            continue  # tracked or staged: not this case
        content = git("cat-file", "blob", blob).stdout
        if file_matches(path, content, int(mode[-3:], 8)):
            found[path] = (content, int(mode[-3:], 8))
    return found


def set_aside(git_dir, files):
    """Move the exact copies out of the merge's way; returns the aside directory or None."""
    if not files:
        return None
    aside = Path(tempfile.mkdtemp(prefix="identical-before-ff-", dir=git_dir))
    for index, path in enumerate(sorted(files)):
        os.replace(path, aside / str(index))
    return aside


def _drop_if_unchanged(copy, content, mode):
    """Unlink `copy` only while it holds exactly `content` with `mode`. The file stays open across the
    check and the unlink, so a write that lands in between is seen through the same descriptor and the
    bytes are put back. Returns True when the copy is gone."""
    try:
        fd = os.open(copy, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return False
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or (before.st_mode & 0o777) != mode or stream.read() != content:
            return False
        os.unlink(copy)
        after = os.fstat(stream.fileno())
        if (after.st_size, after.st_mtime_ns) == (before.st_size, before.st_mtime_ns):
            return True
        stream.seek(0)
        changed = stream.read()
    with open(copy, "xb") as restored:
        restored.write(changed)
    os.chmod(copy, after.st_mode & 0o777)
    return False


def drop_verified_aside(aside, files):
    """Delete only the set-aside copies that still equal the recorded bytes and mode.
    Returns (dropped paths, kept paths); the directory is removed only when it ends up empty, so a
    file that appeared there meanwhile is never deleted with it."""
    dropped, kept = [], []
    for index, path in enumerate(sorted(files)):
        content, mode = files[path]
        (dropped if _drop_if_unchanged(aside / str(index), content, mode) else kept).append(path)
    if not kept:
        try:
            aside.rmdir()
        except OSError as exc:
            print(f"ledger-reconcile: WARN set-aside directory {aside} not removed: {exc}", file=sys.stderr)
    return dropped, kept


def put_back(aside, files):
    """Return set-aside copies after a failed merge, never over a file that appeared meanwhile."""
    if aside is None:
        return
    for index, path in enumerate(sorted(files)):
        if not Path(path).exists():
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            os.replace(aside / str(index), path)
    if not any(aside.iterdir()):
        aside.rmdir()


def reconcile_locked(target, branch, head, snapshots, mirrors, deletions, original_index, git_dir):
    backup = save_recovery(git_dir, head, target, original_index, snapshots)
    published_files = {p: (published, mode) for p, (_, published, mode) in snapshots.items()}
    published_files.update(mirrors)
    expected_index, written = original_index, []
    try:
        for path, (original, published, mode) in snapshots.items():
            if not file_matches(path, original, mode):
                raise Refused(f"ledger changed before replacement: {path}")
            written.append(path)
            replace_bytes(path, published, mode)
        expected_index = stage_published(target, original_index, snapshots, mirrors, deletions)
        verify_files(published_files, "before fast-forward")
        verify_absent(deletions, "before fast-forward")
        # A prior publication hook may already have advanced HEAD/index while
        # leaving an older equivalent ledger on disk. Normalize that proven dirt
        # under the same locks, but do not touch history or ORIG_HEAD again.
        if head != target:
            # No autostash, no silent overwrite of an ignored file on a
            # fast-forward path (WP-530 Ф150, Fable review 14.11). Only exact
            # copies of what the merge writes are moved aside first (F327).
            identical = identical_untracked(head, target)
            aside = set_aside(git_dir, identical)
            try:
                git("merge", "--ff-only", "--no-autostash", "--no-overwrite-ignore", target)
            except BaseException:
                put_back(aside, identical)
                raise
            try:
                verify_files(identical, "after fast-forward over an identical untracked copy")
            except Refused as exc:
                # Never lose a set-aside copy silently: name where it is kept.
                raise Refused(f"{exc}; set-aside copies kept in {aside}") from exc
            if aside is not None:
                dropped, kept = drop_verified_aside(aside, identical)
                if dropped:
                    print(f"ledger-reconcile: {len(dropped)} untracked copy(ies) equal to the target replaced by the merge: "
                          + ", ".join(dropped))
                if kept:
                    # A writer changed the copy after it was checked: its bytes are not ours to delete.
                    print(f"ledger-reconcile: WARN changed set-aside copy(ies) kept in {aside}: " + ", ".join(kept),
                          file=sys.stderr)
        reached_branch = git("symbolic-ref", "--short", "HEAD").stdout.strip().decode()
        if oid("HEAD") != target or reached_branch != branch:
            raise Refused("fast-forward did not reach the pinned branch tip")
        verify_files(published_files, "during fast-forward")
        verify_absent(deletions, "during fast-forward")
        shutil.rmtree(backup)
        print(f"ledger-reconcile: published events reconciled in {len(snapshots)} file(s), "
              f"{len(mirrors)} declared mirror(s), {len(deletions)} declared deletion(s)")
    except BaseException:
        rollback_owned(head, original_index, expected_index, snapshots, written, backup)
        raise


def require_clean_server_only(path):
    """A changed path outside the journal grammar may only pass the transaction when this
    checkout holds nothing of its own there: no tracked, untracked or ignored entry."""
    if git("status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored", "--", path).stdout:
        raise Refused(f"unsupported changed ledger path: {path}")
    parent = Path(path).parent
    while str(parent) not in ("", "."):
        if parent.is_symlink():
            raise Refused(f"symlink parent: {path}")
        parent = parent.parent


def apply(target, branch, commit_lock):
    # fd 8 is inherited from tsekh1-git-sync; inode identity binds it to the
    # expected mutation lock. Re-locking the same open description is nonblocking.
    descriptor, lock_file = os.fstat(8), os.stat(commit_lock)
    if (descriptor.st_dev, descriptor.st_ino) != (lock_file.st_dev, lock_file.st_ino):
        raise Refused("caller does not hold the shared commit-lock descriptor")
    fcntl.flock(8, fcntl.LOCK_EX | fcntl.LOCK_NB)
    git_dir = Path(git("rev-parse", "--absolute-git-dir").stdout.strip().decode())
    with directory_lock(git_dir / "dirty-guard.lock"), contextlib.ExitStack() as locks:
        original_index = git("write-tree").stdout
        head, snapshots, mirrors, deletions = prove(target, branch)
        changed = git("diff", "--name-only", "-z", "--no-renames", head, target,
                      "--", "machine/ledger").stdout
        # Include currently clean ledgers FF changes, so an emitter cannot start
        # after the dirty scan and race Git's checkout of an unprotected file.
        lock_paths = set(snapshots) | {os.fsdecode(p) for p in changed.split(b"\0") if p}
        for path in sorted(lock_paths):
            if not LEDGER_PATH.fullmatch(path):
                # Server-only files next to the journals (plan/, plan/boundary/known-ids-*.txt,
                # written by the nightly Day Open) have no append lock and no local writer.
                # A clean one is the fast-forward's job; refusing it stalled the Mac copy after
                # every night (WP-484 F327, 22.11). Local dirt on such a path is still refused.
                require_clean_server_only(path)
                continue
            if Path(path).exists():
                regular_path(path)
            elif Path(path).parent.resolve() != (Path.cwd() / path).parent:
                raise Refused(f"symlink parent: {path}")
            locks.enter_context(append_lock(path))
        locked_head, current, locked_mirrors, locked_deletions = prove(target, branch)
        if (head != locked_head or snapshots != current or mirrors != locked_mirrors
                or deletions != locked_deletions):
            raise Refused("ledger or HEAD changed while taking locks; retry next tick")
        if git("write-tree").stdout != original_index:
            raise Refused("index changed while proving published content")
        reconcile_locked(target, branch, head, snapshots, mirrors, deletions, original_index, git_dir)


def main():
    if len(sys.argv) not in (5, 6) or sys.argv[1] not in ("--check", "--apply"):
        raise Refused("usage: ledger-reconcile-published.py --check|--apply <repo> <pinned> <branch> [commit-lock]")
    os.chdir(sys.argv[2])
    os.environ.update(GIT_LITERAL_PATHSPECS="1", GIT_NO_REPLACE_OBJECTS="1", GIT_GRAFT_FILE="/dev/null/iwe-no-grafts", GIT_OPTIONAL_LOCKS="0")
    target = oid(sys.argv[3] + "^{commit}")
    if sys.argv[1] == "--check":
        prove(target, sys.argv[4])
    else:
        if len(sys.argv) != 6:
            raise Refused("missing shared lock path")
        apply(target, sys.argv[4], sys.argv[5])


def interrupted(signum, _frame):
    raise Refused(f"interrupted by signal {signum}")


if __name__ == "__main__":
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        main()
    except (Refused, OSError, ValueError, EVENTS.yaml.YAMLError) as exc:
        print(f"ledger-reconcile: refused: {exc}", file=sys.stderr)
        sys.exit(1)
