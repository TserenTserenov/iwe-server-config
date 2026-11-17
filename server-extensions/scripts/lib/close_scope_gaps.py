#!/usr/bin/env python3
"""Changed files of claimed commits that the session has not claimed (WP-484 F310, defect 2).

bug-2026-11-17-multiline-note-file-claim-blocks-product-receipt.md: a product receipt for a
root-level repository needs every changed file of every claimed commit to be claimed through
`note-file` (publication_receipt.legacy_product_scope). That was found only after the close
reached PREPARED, when the file scope is frozen and cannot be completed any more.

This tool runs the same coverage test earlier -- after `note-commit` and before PREPARED -- and
only reports: the receipt requires full coverage for product deliveries alone, so a refusal here
would stop ordinary closes that never need it. Exit 0 always (also when nothing can be checked);
gaps go to stdout, one line per commit, for session-guard to print as a warning.

Usage: close_scope_gaps.py <semaphore> <workspace-root>
"""

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import publication_receipt as receipt  # noqa: E402  (one definition of claims and coverage)

CHECK_ERRORS = (receipt.ProofError, OSError, UnicodeError, ValueError, subprocess.SubprocessError)


def protected_commons(raw: bytes) -> set:
    """Governance and session repositories are delivered by close itself, never by product receipt."""
    commons = set()
    for key in ("governance_worktree", "orz_sessions_dir"):
        try:
            value = Path(receipt.field(raw, key))
            if value.is_absolute():
                commons.add(receipt.repository_identity(value.resolve(strict=True))[0])
        except CHECK_ERRORS:
            continue
    return commons


def claimed_scope(raw: bytes, common: Path) -> list:
    scope = []
    for line in raw.decode().splitlines():
        if not line.startswith("file_v2: "):
            continue
        try:
            item = json.loads(line[len("file_v2: "):])
        except ValueError:
            continue
        if isinstance(item, dict) and item.get("repo") == str(common) and isinstance(item.get("path"), str):
            scope.append(item["path"])
    return scope


def covered(path: str, scope: list) -> bool:
    """Same rule as publication_receipt.legacy_product_scope: exact path or a claimed directory."""
    return any(path == declared or (declared.endswith("/") and path.startswith(declared))
               for declared in scope)


def gaps(raw: bytes, root: Path) -> list:
    """[(repo name, commit, [unclaimed paths])] for root-level repositories, the receipt's scope."""
    names = sorted({line.split()[1] for line in raw.decode().splitlines()
                    if line.startswith("commit: ") and len(line.split()) >= 3})
    skip = protected_commons(raw)
    result = []
    for name in names:
        repo = root / name
        if not (repo / ".git").exists():
            continue
        try:
            common, _ = receipt.repository_identity(repo)
            commits = receipt.claims(raw, name, repo)
        except CHECK_ERRORS:
            continue
        # legacy_product_scope applies only when common.parent.parent == root.
        if common in skip or common.parent.parent != root.resolve():
            continue
        scope = claimed_scope(raw, common)
        for commit in commits:
            try:
                paths = receipt.changed_paths(repo, commit)
            except CHECK_ERRORS:
                continue
            missing = [path for path in paths if not covered(path, scope)]
            if missing:
                result.append((name, commit, missing))
    return result


def main(argv: list) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 0
    try:
        raw = Path(argv[0]).read_bytes()
    except OSError:
        return 0
    for name, commit, missing in gaps(raw, Path(argv[1])):
        shown = ", ".join(missing[:10]) + (f" и ещё {len(missing) - 10}" if len(missing) > 10 else "")
        print(f"{name} {commit[:12]}: не заявлены через note-file ({len(missing)}): {shown}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
