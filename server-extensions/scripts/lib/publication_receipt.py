#!/usr/bin/env python3
"""WP-561 F23: verifiable historical publication receipts, stored in a session.

The caller holds session-guard's transition lock when recording. Receipts are
an index into Git evidence, not trusted attestations: verification reconstructs
the proof, including the original claim, from immutable Git objects.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time

PREFIX = "publication_receipt_v2: "
MAX_BYTES = 1024 * 1024
MAX_CANDIDATES = 256


class ProofError(Exception):
    """Missing, ambiguous or inconsistent publication evidence."""


def git_env() -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_NO_REPLACE_OBJECTS="1", GIT_GRAFT_FILE=os.devnull,
               GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0",
               GIT_NO_LAZY_FETCH="1", GIT_LITERAL_PATHSPECS="1")
    return env


def git(repo: Path, *args: str, env=None, input=None, allowed=(0,)) -> bytes:
    result = subprocess.run(["git", "-C", str(repo), *args], input=input,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=env or git_env(), timeout=15, check=False)
    if result.returncode not in allowed:
        raise ProofError("git " + args[0] + " failed: " +
                         result.stderr.decode("utf-8", "replace")[-400:])
    return result.stdout


def oid(repo: Path, ref: str) -> str:
    return git(repo, "rev-parse", "--verify", ref).decode().strip()


def ancestor(repo: Path, before: str, after: str) -> bool:
    return subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor",
                           before, after], env=git_env(), stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, timeout=15).returncode == 0


def snapshot(path: Path) -> bytes:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_nlink != 1 or not 0 < info.st_size <= MAX_BYTES):
            raise ProofError("unsafe session file")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            raw = stream.read(MAX_BYTES + 1)
        current = os.lstat(path)
        if ((current.st_dev, current.st_ino, current.st_size) !=
                (info.st_dev, info.st_ino, len(raw)) or not raw.endswith(b"\n")
                or b"\0" in raw):
            raise ProofError("session changed or malformed")
        return raw
    finally:
        os.close(fd)


def field(raw: bytes, key: str) -> str:
    values = [line[len(key) + 2:] for line in raw.decode().splitlines()
              if line.startswith(key + ": ")]
    if len(values) != 1 or not values[0]:
        raise ProofError("missing/duplicate " + key)
    return values[0]


def claims(raw: bytes, repo_name: str, repo: Path) -> list[str]:
    result = []
    for line in raw.decode().splitlines():
        if not line.startswith("commit: " + repo_name + " "):
            continue
        sha = line[len("commit: " + repo_name + " "):]
        if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", sha):
            raise ProofError("malformed source claim")
        if sha not in result:
            result.append(sha)
    # PREPARED close already freezes its source inventory in this semaphore,
    # including commits which predate note-commit. Bind that inventory to the
    # same repository and session, never to caller-supplied source lists.
    if b'close_delivery_version: ' in raw:
        common = Path(git(repo, 'rev-parse', '--path-format=absolute', '--git-common-dir').decode().strip()).resolve()
        if Path(field(raw, 'close_delivery_common_dir')).resolve() == common:
            if (field(raw, 'close_delivery_version') != 'isolate-push/v2'
                    or field(raw, 'close_delivery_session_id') != field(raw, 'session_id')
                    or field(raw, 'close_delivery_target_ref') != 'refs/heads/main'):
                raise ProofError('invalid prepared source identity')
            sources = json.loads(field(raw, 'close_delivery_source_commits'))
            if (not isinstance(sources, list) or len(sources) > MAX_CANDIDATES
                    or any(not isinstance(sha, str) or not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', sha)
                           for sha in sources)):
                raise ProofError('invalid prepared source inventory')
            for sha in sources:
                if sha not in result:
                    result.append(sha)
    return result


def changed_paths(repo: Path, source: str) -> list[str]:
    raw = git(repo, "diff-tree", "--root", "--no-commit-id", "--name-only",
              "--no-renames", "-r", "-z", source)
    paths = [os.fsdecode(item) for item in raw.split(b"\0") if item]
    if not paths or len(paths) > 4096:
        raise ProofError("empty or excessive source scope")
    return paths


def entries(repo: Path, commit: str, paths: list[str]) -> list[dict]:
    found = {}
    for row in git(repo, "ls-tree", "-rz", "--full-tree", commit, "--", *paths).split(b"\0"):
        if not row:
            continue
        meta, name = row.split(b"\t", 1)
        mode, kind, sha = meta.decode().split()
        found[os.fsdecode(name)] = {"mode": mode, "kind": kind, "oid": sha}
    return [{"path": path, "entry": found.get(path)} for path in paths]


def replay_matches(repo: Path, source: str, anchor: str) -> bool:
    source_line = git(repo, "rev-list", "--parents", "-n", "1", source).decode().split()
    anchor_line = git(repo, "rev-list", "--parents", "-n", "1", anchor).decode().split()
    if len(source_line) != 2 or len(anchor_line) != 2:
        return False
    if oid(repo, anchor + "^{tree}") == oid(repo, anchor_line[1] + "^{tree}"):
        return False
    objects = Path(git(repo, "rev-parse", "--path-format=absolute",
                       "--git-path", "objects").decode().strip())
    fmt = git(repo, "rev-parse", "--show-object-format").decode().strip()
    with tempfile.TemporaryDirectory(prefix="iwe-receipt-proof-") as directory:
        scratch = Path(directory)
        env = git_env()
        git(scratch, "init", "--bare", "--quiet", "--template=", "--object-format=" + fmt, env=env)
        env["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = json.dumps(str(objects))
        env["GIT_ATTR_SOURCE"] = git(scratch, "mktree", env=env, input=b"").decode().strip()
        result = subprocess.run(
            ["git", "-C", str(scratch), "-c", "merge.renames=false", "merge-tree",
             "--write-tree", "--merge-base=" + source_line[1], anchor_line[1], source],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        return (result.returncode == 0 and result.stdout.decode().strip() ==
                oid(repo, anchor + "^{tree}"))


def receipt(repo: Path, raw: bytes, repo_name: str, source: str, anchor: str) -> dict:
    if source not in claims(raw, repo_name, repo):
        raise ProofError("source is not claimed by this session")
    if oid(repo, source + "^{commit}") != source or oid(repo, anchor + "^{commit}") != anchor:
        raise ProofError("non-canonical commit identity")
    # An original commit is itself the best historical anchor. Do not label a
    # later overwritten tree as containing its bytes merely through ancestry.
    if source == anchor:
        proof = "exact-commit"
    elif replay_matches(repo, source, anchor):
        proof = "exact-replay"
    else:
        raise ProofError("anchor does not reproduce the source change")
    paths = changed_paths(repo, source)
    identity = {"agent": field(raw, "agent"), "session_id": field(raw, "session_id"),
                "repo": repo_name, "origin_sha256": hashlib.sha256(
                    git(repo, "remote", "get-url", "origin").strip()).hexdigest(),
                "target_ref": "refs/heads/main", "source_commit": source}
    return {"version": 2, **identity,
            "claim_id": hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest(),
            "source_tree": oid(repo, source + "^{tree}"),
            "source_paths": entries(repo, source, paths),
            "anchor_commit": anchor, "anchor_tree": oid(repo, anchor + "^{tree}"),
            "published_paths": entries(repo, anchor, paths), "proof": proof}


def find_receipt(repo: Path, raw: bytes, name: str, source: str, published: str) -> dict:
    deadline = time.monotonic() + 20
    if ancestor(repo, source, published):
        return receipt(repo, raw, name, source, source)
    candidates = git(repo, "rev-list", "--max-count=" + str(MAX_CANDIDATES),
                     published, "--", *changed_paths(repo, source)).decode().splitlines()
    for candidate in candidates:
        if time.monotonic() > deadline:
            raise ProofError("publication search exceeded time budget")
        if replay_matches(repo, source, candidate):
            return receipt(repo, raw, name, source, candidate)
    raise ProofError("no exact publication anchor within search budget")


def verify(repo: Path, semaphore: Path, name: str, source: str, remote: str) -> bool:
    raw = snapshot(semaphore)
    for line in raw.decode().splitlines():
        if not line.startswith(PREFIX):
            continue
        try:
            saved = json.loads(line[len(PREFIX):])
            if not isinstance(saved, dict):
                continue
            if saved.get("repo") != name or saved.get("source_commit") != source:
                continue
            anchor = saved["anchor_commit"]
            if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", anchor):
                continue
            if (ancestor(repo, anchor, remote) and
                    saved == receipt(repo, raw, name, source, anchor) and
                    oid(repo, 'refs/remotes/origin/main^{commit}') == remote and
                    snapshot(semaphore) == raw):
                return True
        except (KeyError, TypeError, ValueError, ProofError):
            continue
    return False


def verified_anchors(repo: Path, semaphore: Path, name: str, remote: str) -> list[str]:
    """Reconstruct exact receipts before returning published candidate OIDs.

    Each anchor proves delivery of its own source claim. Callers must still
    independently prove preservation of an older claim against that anchor.
    """
    raw = snapshot(semaphore)
    anchors = set()
    for line in raw.decode().splitlines():
        if not line.startswith(PREFIX):
            continue
        try:
            saved = json.loads(line[len(PREFIX):])
            if not isinstance(saved, dict) or saved.get("repo") != name:
                continue
            source, anchor = saved["source_commit"], saved["anchor_commit"]
            if any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value)
                   for value in (source, anchor)):
                continue
            if (ancestor(repo, anchor, remote)
                    and saved == receipt(repo, raw, name, source, anchor)):
                anchors.add(anchor)
        except (KeyError, TypeError, ValueError, ProofError):
            continue
    if (oid(repo, 'refs/remotes/origin/main^{commit}') != remote
            or snapshot(semaphore) != raw):
        raise ProofError("session or remote changed while verifying anchors")
    if len(anchors) > 32:
        raise ProofError("verified anchors exceed supersession proof budget")
    return sorted(anchors)


def record(repo: Path, semaphore: Path, name: str, published: str) -> int:
    raw = snapshot(semaphore)
    remote = oid(repo, "refs/remotes/origin/main^{commit}")
    if not ancestor(repo, published, remote):
        raise ProofError("publication is not on fetched origin/main")
    sources = claims(raw, name, repo)
    if not sources:
        raise ProofError("session has no commit claims for this repository")
    added = []
    proven = 0
    for source in sources:
        if verify(repo, semaphore, name, source, remote):
            proven += 1
            continue
        try:
            evidence = find_receipt(repo, raw, name, source, published)
        except ProofError:
            # A publisher may deliver one of several already declared claims.
            # Leave the others unproven; close still checks every claim.
            continue
        proven += 1
        added.append(PREFIX + json.dumps(evidence, sort_keys=True, separators=(",", ":")))
    if not proven:
        raise ProofError("no claimed change has a publication proof")
    if not added:
        return 0
    updated = raw + ("\n".join(added) + "\n").encode()
    if len(updated) > MAX_BYTES:
        raise ProofError("receipt would exceed session size limit")
    fd, temporary = tempfile.mkstemp(prefix=semaphore.name + ".receipt-", dir=semaphore.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(updated)
            stream.flush()
            os.fsync(stream.fileno())
        if snapshot(semaphore) != raw or oid(repo, "refs/remotes/origin/main^{commit}") != remote:
            raise ProofError("session or remote changed while recording")
        os.replace(temporary, semaphore)
        directory_fd = os.open(semaphore.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return len(added)


def verify_checkout(repo: Path, semaphore: Path, name: str, remote: str) -> bool:
    """Strict alternative for a clean isolated checkout, never foreign history."""
    raw = snapshot(semaphore)
    head = oid(repo, "HEAD^{commit}")
    if git(repo, "status", "--porcelain=v1", "--untracked-files=all"):
        return False
    pending = git(repo, "rev-list", remote + ".." + head).decode().splitlines()
    owned = set(claims(raw, name, repo))
    if not pending or not set(pending).issubset(owned):
        return False
    return (all(verify(repo, semaphore, name, source, remote) for source in pending)
            and snapshot(semaphore) == raw and oid(repo, "HEAD^{commit}") == head
            and oid(repo, 'refs/remotes/origin/main^{commit}') == remote
            and not git(repo, "status", "--porcelain=v1", "--untracked-files=all"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("record", "verify", "verify-checkout"))
    parser.add_argument("semaphore", type=Path)
    parser.add_argument("repo", type=Path)
    parser.add_argument("repo_name")
    parser.add_argument("commit")
    parser.add_argument("remote", nargs="?")
    args = parser.parse_args()
    try:
        if args.action == "record":
            print("publication receipts v2: " + str(record(args.repo, args.semaphore, args.repo_name, args.commit)))
            return 0
        if args.action == "verify-checkout":
            return 0 if verify_checkout(args.repo, args.semaphore, args.repo_name, args.commit) else 1
        if not args.remote:
            raise ProofError("verify requires the fetched remote commit")
        return 0 if verify(args.repo, args.semaphore, args.repo_name, args.commit, args.remote) else 1
    except (ProofError, OSError, UnicodeError, ValueError, subprocess.SubprocessError) as error:
        print("publication receipt refused: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
