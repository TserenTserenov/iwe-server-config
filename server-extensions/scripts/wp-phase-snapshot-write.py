#!/usr/bin/env python3
"""wp-phase-snapshot-write.py -- writes/updates the self-observation entry
(ref == own WP) of `handoff_snapshot` in a card's frontmatter: observed_status,
observed_open_phases (the same classifier wp-archive-closed-phases.py uses --
"## ФN" / "### ФN" phases WITHOUT a positive terminal marker), recorded_at.

WP-561 Ф42 write side (peer-session 2026-10-19-24, Claude+Codex, cold review):
the read-only gate in wp-sync-bundle.sh compares the card's real open-phase
list against this snapshot. Without a writer, every card reports NO_BASELINE
forever and the gate never fires -- this script is that writer, called at
close (memory/protocol-close.md §5), the same way `wp-phase-digest.sh` is
already called there for depends_on entries. It never touches other
entries (depends_on refs to OTHER WPs) in the same handoff_snapshot block.

Usage: wp-phase-snapshot-write.py WP_NUM [--governance-repo DIR]
Exit: 0 = written (or already up to date)
      1 = usage / card not found / no valid frontmatter
      3 = archiver self-check mismatch -- refuses to write an unverified list
          (a parser disagreement is worse to persist than to leave absent)
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import subprocess
import sys
import tempfile

REF_RE = re.compile(r"^\s*-\s*ref:\s*(.+)$")
TOPLEVEL_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*:")


def find_wp_file(inbox: str, archive: str, num: str) -> str | None:
    # Same lookup order as find_wp_file() in wp-phase-digest.sh (WP-434:
    # folder convention is primary) -- kept as its own copy rather than a
    # shared import, same tradeoff wp-phase-digest.sh itself documents
    # (avoids sourcing a script that declares and runs its own main()).
    candidates = [
        os.path.join(inbox, f"WP-{num}", f"WP-{num}.md"),
        os.path.join(inbox, f"WP-{num}.md"),
        os.path.join(archive, f"WP-{num}", f"WP-{num}.md"),
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
    for base in (inbox, archive):
        if not os.path.isdir(base):
            continue
        for root, _dirs, files in os.walk(base):
            for fn in files:
                if fn.endswith(".md"):
                    path = os.path.join(root, fn)
                    try:
                        with open(path, encoding="utf-8", errors="replace") as f:
                            head = f.read(2000)
                    except OSError:
                        continue
                    if re.search(rf"^wp:\s*{re.escape(num)}\s*$", head, re.M):
                        return path
    return None


def frontmatter_bounds(lines: list[str]) -> tuple[int, int] | None:
    fence_idx = [i for i, ln in enumerate(lines) if ln.rstrip("\n") == "---"]
    if len(fence_idx) < 2:
        return None
    return fence_idx[0], fence_idx[1]


def extract_status(lines: list[str], fm_start: int, fm_end: int) -> str:
    for ln in lines[fm_start + 1 : fm_end]:
        m = re.match(r"^status:\s*(.+)$", ln)
        if m:
            return m.group(1).strip().strip('"')
    return "unknown"


def handoff_snapshot_block_bounds(lines: list[str], fm_start: int, fm_end: int) -> tuple[int, int, int] | None:
    """Returns (key_line, body_start, body_end) or None if the block is absent."""
    for i in range(fm_start + 1, fm_end):
        if lines[i].rstrip("\n") == "handoff_snapshot:":
            body_start = i + 1
            body_end = body_start
            while body_end < fm_end and not TOPLEVEL_KEY_RE.match(lines[body_end]):
                body_end += 1
            return i, body_start, body_end
    return None


def find_self_entry(lines: list[str], body_start: int, body_end: int, want: str) -> tuple[int, int] | None:
    i = body_start
    while i < body_end:
        m = REF_RE.match(lines[i])
        if m and m.group(1).strip().strip('"') == want:
            j = i + 1
            while j < body_end and not REF_RE.match(lines[j]):
                j += 1
            return i, j
        i += 1
    return None


def atomic_write(path: str, lines: list[str]) -> None:
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".wp-phase-snapshot-", dir=d)
    try:
        if os.path.exists(path):
            os.chmod(tmp, os.stat(path).st_mode & 0o777)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.writelines(lines)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("wp", help="WP number (N or WP-N)")
    ap.add_argument("--governance-repo", default=None, help="governance repo root (default: $IWE_WORKSPACE/$IWE_GOVERNANCE_REPO)")
    a = ap.parse_args(argv)

    wp = re.sub(r"^(?i:wp-)", "", a.wp.strip())
    if not wp.isdigit():
        print(f"usage: WP number expected, got {a.wp!r}", file=sys.stderr)
        return 1

    ws = os.environ.get("IWE_WORKSPACE", os.path.expanduser("~/IWE"))
    gov_arg = a.governance_repo or os.environ.get("IWE_GOVERNANCE_REPO", "DS-my-strategy")
    gov = gov_arg if os.path.isabs(gov_arg) else os.path.join(ws, gov_arg)
    inbox = os.path.join(gov, "inbox")
    archive = os.path.join(gov, "archive", "wp-contexts")
    card_path = find_wp_file(inbox, archive, wp)
    if not card_path:
        print(f"card not found: WP-{wp}", file=sys.stderr)
        return 1

    archiver = os.path.join(os.path.dirname(os.path.abspath(__file__)), "wp-archive-closed-phases.py")
    proc = subprocess.run(
        [sys.executable, archiver, wp, "--json", "--governance-repo", gov],
        capture_output=True, text=True,
    )
    if proc.returncode == 1:
        print(f"archiver: card not found or usage error for WP-{wp}: {proc.stderr.strip()}", file=sys.stderr)
        return 1
    try:
        report = json.loads(proc.stdout)
    except (json.JSONDecodeError, ValueError):
        print(f"archiver JSON did not parse (exit {proc.returncode}): {proc.stderr.strip()}", file=sys.stderr)
        return 1
    if not report.get("self_check", {}).get("match", False):
        print(f"self-check mismatch for WP-{wp} -- refusing to persist an unverified phase list", file=sys.stderr)
        return 3

    open_ids = sorted(set(n["phase"] for n in report["no_terminal_marker"]))

    with open(card_path, encoding="utf-8") as f:
        lines = f.read().splitlines(keepends=True)
    bounds = frontmatter_bounds(lines)
    if bounds is None:
        print(f"no valid frontmatter in {card_path}", file=sys.stderr)
        return 1
    fm_start, fm_end = bounds

    status = extract_status(lines, fm_start, fm_end)
    today = _dt.date.today().isoformat()
    want = f"WP-{wp}"
    new_entry = [
        f"  - ref: {want}\n",
        f"    observed_status: {status}\n",
        f"    observed_open_phases: [{', '.join(open_ids)}]\n",
        f'    recorded_at: "{today}"\n',
    ]

    hs = handoff_snapshot_block_bounds(lines, fm_start, fm_end)
    if hs is None:
        lines[fm_start + 1 : fm_start + 1] = ["handoff_snapshot:\n"] + new_entry
    else:
        _key_line, body_start, body_end = hs
        existing = find_self_entry(lines, body_start, body_end, want)
        if existing is not None:
            entry_start, entry_end = existing
            if lines[entry_start:entry_end] == new_entry:
                print(f"WP-{wp}: snapshot already up to date ({len(open_ids)} open phase(s))")
                return 0
            lines[entry_start:entry_end] = new_entry
        else:
            lines[body_end:body_end] = new_entry

    atomic_write(card_path, lines)
    print(f"WP-{wp}: snapshot written ({len(open_ids)} open phase(s)): {', '.join(open_ids) or '(none)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
