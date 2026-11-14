#!/usr/bin/env python3
"""Keep .claude/styles/s0-core.md a generated copy of the S0 style pack (WP-7 F309).

The style hook falls back to this snapshot when the PACK-rhetoric dispatcher is
missing. It used to be edited by hand and fell five months behind the pack
(no "Дальше:" rule, no ontology rule). The snapshot body is now the pack file
body byte for byte, pinned to the pack commit recorded in its own header, so a
check is reproducible and does not turn red when the pack moves on.

Modes:
  --write   regenerate the snapshot from the pack at its current HEAD commit;
            refuses if the pack file has uncommitted changes.
  --check   rebuild the snapshot from the pack at the commit named in the
            snapshot header and compare byte for byte (CI and local).
  --drift   report whether the pack file at HEAD differs from the pinned
            commit (local warning only: "regenerate the snapshot").

Exit codes: 0 ok, 1 mismatch or drift, 2 usage or missing input.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

PACK_REPO = "MimEcoSys/PACK-digital-platform"
PACK_FILE = "pack/digital-platform/02-domain-entities/communication-style-base.md"
SNAPSHOT = Path(".claude/styles/s0-core.md")
FRONTMATTER_RE = re.compile(r"\A---\n.*?^---\n", re.S | re.M)
SHA_RE = re.compile(r"^source_sha: \"([0-9a-f]{40})\"$", re.M)


def fail(message, code=2):
    print(f"style-snapshot-sync: {message}", file=sys.stderr)
    sys.exit(code)


def git(pack_dir, *args):
    # Bytes, decoded without newline translation: the snapshot is byte for byte.
    result = subprocess.run(["git", "-C", str(pack_dir), *args], capture_output=True, check=False)
    if result.returncode != 0:
        fail(f"git {' '.join(args)} failed in {pack_dir}: {result.stderr.decode('utf-8', 'replace').strip()}")
    return result.stdout.decode("utf-8")


def pack_body(pack_dir, sha):
    text = git(pack_dir, "show", f"{sha}:{PACK_FILE}")
    match = FRONTMATTER_RE.match(text)
    if not match:
        fail(f"{PACK_FILE} at {sha} has no YAML frontmatter")
    return text[match.end():]


def render(pack_dir, sha):
    header = (
        "---\n"
        "name: s0-core\n"
        'description: "Снимок базового разговорного стиля S0 для установок без PACK-rhetoric"\n'
        "type: reference\n"
        "owner: platform\n"
        "generated: true\n"
        f'source_repo: "{PACK_REPO}"\n'
        f'source_path: "{PACK_FILE}"\n'
        f'source_sha: "{sha}"\n'
        'update_via: "python3 scripts/style-snapshot-sync.py --write"\n'
        "---\n"
    )
    return header + pack_body(pack_dir, sha)


def pinned_sha(snapshot):
    if not snapshot.is_file():
        fail(f"snapshot {snapshot} not found")
    match = SHA_RE.search(snapshot.read_bytes().decode("utf-8", "replace"))
    if not match:
        fail(f"snapshot {snapshot} has no source_sha line; regenerate with --write")
    return match.group(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--drift", action="store_true")
    parser.add_argument("--pack-dir", type=Path, required=True, help="checkout of PACK-digital-platform")
    parser.add_argument("--snapshot", type=Path, default=SNAPSHOT)
    args = parser.parse_args()

    if not (args.pack_dir / ".git").exists():
        fail(f"pack checkout not found at {args.pack_dir}")

    if args.write:
        dirty = subprocess.run(
            ["git", "-C", str(args.pack_dir), "diff", "--quiet", "HEAD", "--", PACK_FILE], check=False
        )
        if dirty.returncode != 0:
            fail(f"{PACK_FILE} has uncommitted changes in {args.pack_dir}; commit them first")
        sha = git(args.pack_dir, "rev-parse", "HEAD").strip()
        published = subprocess.run(
            ["git", "-C", str(args.pack_dir), "branch", "-r", "--contains", sha], capture_output=True, text=True, check=False
        )
        if not published.stdout.strip():
            print(f"style-snapshot-sync: warning: {sha[:12]} is on no remote branch; CI cannot fetch it until it is pushed")
        with open(args.snapshot, "w", encoding="utf-8", newline="") as handle:
            handle.write(render(args.pack_dir, sha))
        print(f"style-snapshot-sync: wrote {args.snapshot} from {PACK_REPO}@{sha[:12]}")
        return 0

    sha = pinned_sha(args.snapshot)
    if args.check:
        if args.snapshot.read_bytes() != render(args.pack_dir, sha).encode("utf-8"):
            print(f"style-snapshot-sync: {args.snapshot} differs from {PACK_FILE}@{sha[:12]}; regenerate with --write")
            return 1
        print(f"style-snapshot-sync: {args.snapshot} matches {PACK_FILE}@{sha[:12]}")
        return 0

    head = git(args.pack_dir, "rev-parse", "HEAD").strip()
    if pack_body(args.pack_dir, head) != pack_body(args.pack_dir, sha):
        print(f"style-snapshot-sync: pack moved ({sha[:12]} -> {head[:12]}); regenerate the snapshot with --write")
        return 1
    print(f"style-snapshot-sync: pack text unchanged since {sha[:12]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
