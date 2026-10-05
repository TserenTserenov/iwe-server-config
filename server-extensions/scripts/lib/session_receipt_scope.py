#!/usr/bin/env python3
"""Prove a shared MC-sessions checkout from exact session-owned receipts.

The shared checkout can contain other agents' unpublished commits.  This
fallback proves only this session's repository-qualified files and commits;
it never publishes or changes a ref.  The caller must fetch origin/main first.
"""
from __future__ import annotations

import json
import hashlib
import os
from pathlib import Path
import re
import stat
import sys

import publication_receipt as proof


def require(condition: bool, message: str) -> None:
    if not condition:
        raise proof.ProofError(message)


def exact_path(value: object) -> bool:
    return (isinstance(value, str) and bool(value) and not value.startswith(("/", ":"))
            and all(part not in ("", ".", "..") for part in value.split("/"))
            and not any(char in value for char in "\x00\r\n*?["))


def parse_scope(raw: bytes, common: Path, orz: str) -> set[str]:
    lines = raw.decode("utf-8").splitlines()
    own: set[str] = set()
    unpaired: list[str] = []
    pending: str | None = None
    for line in lines + [""]:
        if pending is not None and not line.startswith("file_v2: "):
            unpaired.append(pending)
            pending = None
        if line.startswith("file: "):
            pending = line[6:]
            require(exact_path(pending), "invalid legacy file claim")
        elif line.startswith("file_v2: "):
            require(pending is not None, "orphan repository-qualified claim")
            item = json.loads(line[9:])
            require(isinstance(item, dict) and set(item) == {"path", "repo"},
                    "invalid repository-qualified claim")
            require(item["path"] == pending and exact_path(item["path"]),
                    "repository-qualified claim differs from adjacent file")
            require(isinstance(item["repo"], str) and Path(item["repo"]).is_absolute()
                    and Path(item["repo"]).name == ".git"
                    and Path(item["repo"]).resolve(strict=True) == Path(item["repo"])
                    and Path(item["repo"]).is_dir(),
                    "invalid repository identity")
            if Path(item["repo"]) == common:
                own.add(pending)
            pending = None
    require(set(unpaired) == {orz, "inbox/open-sessions.log"}
            and len(unpaired) == 2, "unqualified session file claim")
    own.add(orz)
    return own


def receipt_for(raw: bytes, name: str, source: str) -> dict:
    rows = []
    for line in raw.decode("utf-8").splitlines():
        if not line.startswith(proof.PREFIX):
            continue
        value = json.loads(line[len(proof.PREFIX):])
        if isinstance(value, dict) and value.get("repo") == name and value.get("source_commit") == source:
            rows.append(value)
    require(len(rows) == 1, "missing or duplicate publication receipt")
    return rows[0]


def latest_entry(repo: Path, candidates: list[tuple[str, dict]]) -> dict:
    maxima = [(anchor, entry) for anchor, entry in candidates
              if all(anchor == other or proof.ancestor(repo, other, anchor)
                     for other, _ in candidates)]
    require(len(maxima) == 1, "publication anchors are unordered or ambiguous")
    return maxima[0][1]


def local_entry(repo: Path, path: str, algorithm: str) -> dict | None:
    """Read an existing local file through no-follow dirfds, or report absence."""
    directory = os.open(repo, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    descriptor = None
    try:
        parts = path.split("/")
        try:
            for part in parts[:-1]:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                dir_fd=directory)
                os.close(directory)
                directory = child
            descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                 dir_fd=directory)
        except FileNotFoundError:
            return None
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_size <= 64 * 1024 * 1024,
                "local owned path is not a bounded regular file: " + path)
        digest = hashlib.new(algorithm)
        digest.update(b"blob " + str(before.st_size).encode() + b"\0")
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            require(bool(chunk), "local owned file shortened during proof: " + path)
            digest.update(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
        current = os.stat(parts[-1], dir_fd=directory, follow_symlinks=False)
        fields = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns", "st_ctime_ns")
        require(all(getattr(before, field) == getattr(after, field) == getattr(current, field)
                    for field in fields), "local owned file changed during proof: " + path)
        return {"kind": "blob", "mode": "100755" if before.st_mode & stat.S_IXUSR else "100644",
                "oid": digest.hexdigest()}
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(directory)


def verify_scope(semaphore: Path, repo: Path, remote: str) -> None:
    raw = proof.snapshot(semaphore)
    require(proof.field(raw, "orz_sessions_dir") == str(repo), "sessions checkout differs from semaphore")
    require(proof.field(raw, "close_path") != "machine-publish-only", "unsupported session type")
    orz = proof.field(raw, "orz_file")
    require(exact_path(orz), "invalid session document path")
    require(repo.resolve(strict=True) == repo and repo.name == "MC-sessions", "not canonical MC-sessions")
    common = Path(proof.git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
                  .decode().strip()).resolve(strict=True)
    require(common == repo / ".git", "not the canonical sessions checkout")
    require(re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", remote) is not None,
            "invalid remote commit")
    require(proof.oid(repo, "refs/remotes/origin/main^{commit}") == remote, "remote changed")
    head = proof.oid(repo, "HEAD^{commit}")
    own = parse_scope(raw, common, orz)
    algorithm = proof.git(repo, "rev-parse", "--show-object-format").decode().strip()
    require(algorithm in {"sha1", "sha256"}, "unsupported Git object format")
    name = repo.name
    sources = proof.claims(raw, name, repo)
    require(0 < len(sources) <= 128, "missing or excessive owned commits")
    published: dict[str, list[tuple[str, dict]]] = {}
    for source in sources:
        require(proof.verify(repo, semaphore, name, source, remote),
                "claimed commit lacks exact publication receipt")
        receipt = receipt_for(raw, name, source)
        anchor = receipt["anchor_commit"]
        changed = set(proof.changed_paths(repo, source))
        require(changed <= own, "commit changes an unclaimed sessions path")
        rows = receipt.get("published_paths")
        require(isinstance(rows, list) and {row.get("path") for row in rows if isinstance(row, dict)} == changed
                and len(rows) == len(changed), "receipt paths differ from source")
        for row in rows:
            entry = row.get("entry")
            require(isinstance(entry, dict) and set(entry) == {"kind", "mode", "oid"}
                    and entry["kind"] == "blob" and entry["mode"] in {"100644", "100755"},
                    "unsupported published file")
            published.setdefault(row["path"], []).append((anchor, entry))
    require(set(published) == own, "file claims and published commits differ")
    local_snapshots: dict[str, dict | None] = {}
    for path, candidates in published.items():
        expected = latest_entry(repo, candidates)
        actual = proof.entries(repo, remote, [path])[0]["entry"]
        require(actual == expected, "current remote differs from last owned publication: " + path)
        require(not proof.git(repo, "status", "--porcelain=v1", "--untracked-files=all", "--", path),
                "local owned path is dirty: " + path)
        local_snapshots[path] = local_entry(repo, path, algorithm)
        require(local_snapshots[path] is None or local_snapshots[path] == expected,
                "local owned file differs from remote: " + path)
    for path in published:
        require(not proof.git(repo, "status", "--porcelain=v1", "--untracked-files=all", "--", path),
                "local owned path changed during proof: " + path)
        require(local_entry(repo, path, algorithm) == local_snapshots[path],
                "local owned content changed during proof: " + path)
    require(proof.snapshot(semaphore) == raw and proof.oid(repo, "HEAD^{commit}") == head
            and proof.oid(repo, "refs/remotes/origin/main^{commit}") == remote,
            "session or refs changed during proof")


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate repository claim key")
        result[key] = value
    return result


def verify_empty_governance_scope(semaphore: Path, repo: Path) -> None:
    """Prove attribution elsewhere, never infer absence from missing files.

    This proves scope only. The caller must still verify every external file
    and commit's delivery, while holding the exact session transition lock.
    """
    raw = proof.snapshot(semaphore)
    require(repo.is_absolute() and repo.resolve(strict=True) == repo,
            "noncanonical governance checkout")
    require(proof.field(raw, "governance_worktree") == str(repo),
            "governance checkout differs from semaphore")
    for name in ("agent", "session_id", "wp", "slug", "harness_session_id", "host"):
        proof.field(raw, name)
    require(proof.field(raw, "close_path") in {"unknown", "peer-session", "quick-close"},
            "unsupported empty-scope close path")
    require(not any(line.startswith("isolated_worktree:") for line in raw.decode().splitlines()),
            "isolated governance requires full delivery proof")
    own_common, own_origin = proof.repository_identity(repo)
    sessions = Path(proof.field(raw, "orz_sessions_dir"))
    require(sessions.is_absolute() and sessions.resolve(strict=True) == sessions,
            "noncanonical sessions checkout")
    sessions_common, sessions_origin = proof.repository_identity(sessions)
    require(sessions_common != own_common and sessions_origin != own_origin,
            "session document belongs to governance")
    orz = proof.field(raw, "orz_file")
    require(exact_path(orz), "invalid session document")
    unpaired = []
    pending = None
    commits = []
    for line in raw.decode().splitlines() + [""]:
        if pending is not None and not line.startswith("file_v2: "):
            unpaired.append(pending)
            pending = None
        if line.startswith("file: "):
            pending = line[6:]
            require(exact_path(pending), "invalid file claim")
        elif line.startswith("file_v2: "):
            require(pending is not None, "orphan repository-qualified claim")
            item = json.loads(line[9:], object_pairs_hook=unique_object)
            require(isinstance(item, dict) and set(item) == {"path", "repo"}
                    and item["path"] == pending and isinstance(item["repo"], str),
                    "invalid repository-qualified claim")
            common = Path(item["repo"])
            require(common.is_absolute() and common.name == ".git"
                    and common.resolve(strict=True) == common and common.is_dir(),
                    "invalid repository identity")
            # The close pipeline checks current dirty scope in governance and
            # sessions only. Attribution to a third repository alone cannot
            # prove its uncommitted/unclaimed output was delivered.
            require(common == sessions_common,
                    "file claim belongs outside the verified sessions checkout")
            pending = None
        elif line.startswith("commit: "):
            parts = line[8:].split()
            require(len(parts) == 2 and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", parts[1]) is not None,
                    "invalid commit claim")
            commits.append(parts)
        elif line.startswith(("file:", "file_v2:", "commit:")):
            raise proof.ProofError("malformed scope record")
    require(len(unpaired) == 2 and set(unpaired) == {orz, "inbox/open-sessions.log"},
            "unqualified or incomplete scope")
    require(bool(commits) and all(name == sessions.name and name != repo.name for name, _ in commits),
            "missing external commit or governance/unknown commit claim")
    require(proof.snapshot(semaphore) == raw, "session changed during scope proof")
    require(proof.repository_identity(repo) == (own_common, own_origin)
            and proof.repository_identity(sessions) == (sessions_common, sessions_origin),
            "repository identity changed during scope proof")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 4:
            raise proof.ProofError("usage: session_receipt_scope.py <semaphore> <MC-sessions> <remote>")
        if sys.argv[1] == "--empty-governance":
            verify_empty_governance_scope(Path(sys.argv[2]), Path(sys.argv[3]))
        else:
            verify_scope(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
    except (proof.ProofError, OSError, UnicodeError, ValueError, KeyError, TypeError) as error:
        print("session receipt scope refused: " + str(error), file=sys.stderr)
        raise SystemExit(1)
