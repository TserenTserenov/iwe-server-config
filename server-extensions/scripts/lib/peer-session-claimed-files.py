#!/usr/bin/env python3
"""Check whether one semaphore claims a complete peer-session journal."""

from __future__ import annotations

import pathlib
import re
import sys


PEER_FILE = re.compile(
    r"(\d{4}-\d{2})/(\d{2})/(\d{4}-\d{2}-\d{2}-[A-Za-z0-9][A-Za-z0-9._-]*)/"
    r"(meta\.yaml|00-writer\.md)"
)
REQUIRED_FILES = {"meta.yaml", "00-writer.md"}


def claimed_directory(semaphore: pathlib.Path) -> str | None:
    """Return the sole claimed peer directory, rejecting ambiguous claims."""
    if not semaphore.is_file():
        return None

    directories: dict[str, set[str]] = {}
    for line in semaphore.read_text().splitlines():
        if not line.startswith("file: "):
            continue
        claim = line[6:].strip()
        if not claim.endswith(("/meta.yaml", "/00-writer.md")):
            continue
        match = PEER_FILE.fullmatch(claim)
        if match is None:
            return None
        month, day, session_id, name = match.groups()
        if not session_id.startswith(f"{month}-{day}-"):
            return None
        relative_dir = f"{month}/{day}/{session_id}"
        directories.setdefault(relative_dir, set()).add(name)

    if len(directories) != 1:
        return None
    relative_dir, names = next(iter(directories.items()))
    return relative_dir if names == REQUIRED_FILES else None


def journal_is_complete(orz_dir: pathlib.Path, relative_dir: str) -> bool:
    root = orz_dir.resolve(strict=True)
    directory = root / relative_dir
    if directory.resolve(strict=True) != directory or not directory.is_dir():
        return False

    meta = directory / "meta.yaml"
    writer = directory / "00-writer.md"
    if (
        meta.is_symlink()
        or writer.is_symlink()
        or not meta.is_file()
        or not writer.is_file()
        or writer.stat().st_size == 0
    ):
        return False

    session_ids = []
    for line in meta.read_text().splitlines():
        if line.startswith("session_id:"):
            value = line.split(":", 1)[1].strip()
            if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
                value = value[1:-1]
            session_ids.append(value)
    return session_ids == [directory.name]


def main() -> int:
    semaphore, orz_dir = map(pathlib.Path, sys.argv[1:])
    try:
        relative_dir = claimed_directory(semaphore)
        valid = relative_dir is not None and journal_is_complete(orz_dir, relative_dir)
    except (OSError, ValueError) as exc:
        print(f"peer evidence file check failed: {exc}", file=sys.stderr)
        valid = False
    print("yes" if valid else "no")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
