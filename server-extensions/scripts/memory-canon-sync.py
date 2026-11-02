#!/usr/bin/env python3
"""Refresh memory/<file> copies from the published root canon (WP-529 F248).

Design: DRR-f248-sposob-kopirovaniya-kanona-v-memory (variant B). Source is
the canon at refs/remotes/origin/main, never the working tree. A control
record (canon blob SHA + sha256 of the written file) is kept per file; a copy
whose hash no longer matches its record was edited past the canon, and that
file is left alone. Any git failure or empty blob leaves memory/ untouched.

Exit code is always 0 for best-effort callers; the outcome is printed.
"""
import argparse
import hashlib
import os
import subprocess
import sys
import tempfile
from pathlib import Path

CANON_DIR = ".claude/memory-canon"
REF = "refs/remotes/origin/main"


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True).stdout


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    try:
        return sha256(path.read_bytes())
    except FileNotFoundError:
        return None


def read_state(path):
    state = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            name, blob, digest = line.split("\t")
            state[name] = (blob, digest)
    return state


def past_canon_blobs(root, rev, path):
    """Blob ids this canon path ever had; a copy equal to one of them is an old canon, not a hand edit."""
    commits = git(root, "rev-list", rev, "--", path).decode().split()
    blobs = set()
    for commit in commits:
        try:
            blobs.add(git(root, "rev-parse", f"{commit}:{path}").decode().strip())
        except subprocess.CalledProcessError:
            continue  # commit that deleted the path
    return blobs


def blob_id(path):
    return subprocess.run(["git", "hash-object", str(path)], check=True, capture_output=True).stdout.decode().strip()


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    with os.fdopen(fd, "wb") as out:
        out.write(data)
        out.flush()
        os.fsync(out.fileno())
    os.replace(tmp, path)


def sync(root, memory, state_path):
    rev = git(root, "rev-parse", "--verify", f"{REF}^{{commit}}").decode().strip()
    names = git(root, "ls-tree", "--name-only", f"{rev}:{CANON_DIR}").decode().split()
    state = read_state(state_path)
    updated, stopped = [], []
    for name in names:
        blob = git(root, "rev-parse", f"{rev}:{CANON_DIR}/{name}").decode().strip()
        content = git(root, "cat-file", "blob", blob)
        if not content:
            stopped.append(f"{name}: пустой блоб канона")
            continue
        target = memory / name
        new_digest = sha256(content)
        current = file_sha(target)
        record = state.get(name)
        if current == new_digest:
            state[name] = (blob, new_digest)
            continue
        if record is None and current is not None:
            past = past_canon_blobs(root, rev, f"{CANON_DIR}/{name}")
            if blob_id(target) in past:
                record = (None, current)
        if current is not None and (record is None or current != record[1]):
            stopped.append(f"{name}: правка мимо канона — внести её в {CANON_DIR}/{name} через изолированную копию корня")
            continue
        write_atomic(target, content)
        state[name] = (blob, new_digest)
        updated.append(name)
    write_atomic(state_path, "".join(f"{n}\t{b}\t{d}\n" for n, (b, d) in sorted(state.items())).encode())
    if updated and (memory / ".git").exists():
        git(memory, "add", "--", *updated)
        git(memory, "commit", "-q", "-m", f"memory-canon-sync: {len(updated)} файл(ов) из канона {rev[:9]}")
    return rev, updated, stopped


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=os.environ.get("IWE_ROOT_DIR", str(Path.home() / "IWE")))
    parser.add_argument("--memory", help="memory directory (default: <root>/memory)")
    parser.add_argument("--state", help="control record (default: <root>/.iwe-runtime/memory-canon/state.tsv)")
    args = parser.parse_args()
    root = Path(args.root)
    memory = Path(args.memory) if args.memory else root / "memory"
    state_path = Path(args.state) if args.state else root / ".iwe-runtime/memory-canon/state.tsv"
    try:
        rev, updated, stopped = sync(root, memory, state_path)
    except (subprocess.CalledProcessError, OSError, ValueError) as exc:
        print(f"[memory-canon-sync] память не тронута: {exc}", file=sys.stderr)
        return 0
    print(f"[memory-canon-sync] канон {rev[:9]}: обновлено {len(updated)}, остановлено {len(stopped)}")
    for line in stopped:
        print(f"  ⚠️ {line}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
