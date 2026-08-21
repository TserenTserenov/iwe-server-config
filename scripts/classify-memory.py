#!/usr/bin/env python3
"""classify-memory.py — builds the managed-memory delivery manifest.

Reads YAML frontmatter of every .md file under the Mac's memory dir, selects
files explicitly marked `delivery: managed` + `delivery_authority:
root-repository`, and writes a deterministic manifest + its sha256 into
server-extensions/memory/ (this repo's staging dir).

Root cause this replaces: iwe-extensions-sync.nix used to rsync the ENTIRE
memory dir (905+ personal feedback/project files) with no allowlist at all
except a hardcoded 9-name list living inside sync-extensions.sh — the same
class of gap as the 17-scripts-outside-manifest finding from 2026-08-03
(WP-484 §"Сторож доставки скриптов"), just in a different channel
(root<->server instead of root<->FMT-template). Classifying by an inferred
`owner:` field was considered and rejected in peer-session
2026-08-21-01-delivery-version-handshake: `owner: agent` files turned out to
be host-specific harness bugs (e.g. "Bash tool cwd resets between calls"),
not canonical documents — semantic ownership and delivery authority are
orthogonal axes. This script trusts only the explicit `delivery`/
`delivery_authority` fields; everything else fails closed (excluded).
"""

import getpass
import hashlib
import sys
from pathlib import Path

import yaml

# Assumes the pilot's Claude Code project-key follows "-Users-{username}-IWE"
# (true only when invoked with cwd == ~/IWE, the pilot's actual pattern for
# this workflow) — the real key algorithm hyphen-encodes the full invocation
# cwd, not just the username, so this breaks silently loud (dir not found,
# exit 1 below) if ever run from a worktree or subdirectory instead. Found in
# cold-context review, peer-session 2026-08-21-01-delivery-version-handshake.
MAC_MEMORY = Path.home() / ".claude" / "projects" / f"-Users-{getpass.getuser()}-IWE" / "memory"
REPO_ROOT = Path(__file__).resolve().parent.parent
STAGING_MEMORY = REPO_ROOT / "server-extensions" / "memory"
MANIFEST_PATH = STAGING_MEMORY / "managed-memory-manifest.txt"
MANIFEST_HASH_PATH = STAGING_MEMORY / "manifest.sha256"

REQUIRED_DELIVERY = "managed"
REQUIRED_AUTHORITY = "root-repository"


def read_frontmatter(path: Path) -> dict | None:
    """Parses the leading `---\\n...\\n---` YAML block. None if absent/invalid."""
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    if not text.startswith("---"):
        return None
    parts = text.split("---", 2)
    if len(parts) < 3:
        return None
    try:
        data = yaml.safe_load(parts[1])
    except yaml.YAMLError:
        return None
    return data if isinstance(data, dict) else None


def is_managed(frontmatter: dict) -> bool:
    return (
        frontmatter.get("delivery") == REQUIRED_DELIVERY
        and frontmatter.get("delivery_authority") == REQUIRED_AUTHORITY
    )


def main() -> int:
    if not MAC_MEMORY.is_dir():
        print(f"ERROR: {MAC_MEMORY} not found — run this on the Mac, not the server", file=sys.stderr)
        return 1

    managed_files = []
    for md_file in sorted(MAC_MEMORY.glob("*.md")):
        frontmatter = read_frontmatter(md_file)
        if frontmatter is None:
            continue
        if is_managed(frontmatter):
            managed_files.append(md_file.name)

    if not managed_files:
        print("ERROR: zero managed files found — refusing to write an empty manifest "
              "(bootstrap not run yet? see docs/memory-bootstrap.md)", file=sys.stderr)
        return 1

    STAGING_MEMORY.mkdir(parents=True, exist_ok=True)

    # copy the managed set into staging, dropping anything no longer managed
    existing_staged = {p.name for p in STAGING_MEMORY.glob("*.md")}
    for stale in existing_staged - set(managed_files):
        (STAGING_MEMORY / stale).unlink()
        print(f"removed from staging (no longer managed): {stale}")

    for name in managed_files:
        (STAGING_MEMORY / name).write_bytes((MAC_MEMORY / name).read_bytes())

    manifest_text = "\n".join(managed_files) + "\n"
    MANIFEST_PATH.write_text(manifest_text, encoding="utf-8")

    manifest_sha = hashlib.sha256(manifest_text.encode("utf-8")).hexdigest()
    MANIFEST_HASH_PATH.write_text(f"{manifest_sha}  {MANIFEST_PATH.name}\n", encoding="utf-8")

    print(f"manifest written: {len(managed_files)} files, sha256={manifest_sha[:12]}")
    for name in managed_files:
        print(f"  managed: {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
