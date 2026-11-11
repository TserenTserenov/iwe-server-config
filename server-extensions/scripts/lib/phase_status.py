"""phase_status.py -- the one place that decides whether a phase status means
"open" or "closed" (WP-484 Ф299 п.1).

Before this module three programs kept three different lists:
  * wp-archive-closed-phases.py treated only done/closed/archived/completed as
    closed (so `merged`, `superseded` read as open);
  * wp-handoff-check.py treated only pending/in_progress/blocked as open (so
    `implemented` fell out of the snapshot);
  * wp-sync-bundle.sh carried a third inline copy of the open list.
wp-phase-snapshot-write.py reuses the archiver's classifier, so it follows.

Contract (peer-session 2026-11-11-06-wp484-next-phase, Claude+Kimi+Codex):
  open    -- pending, in_progress, blocked, implemented, implemented-partial
             (implemented* wait for acceptance, they are not finished)
  closed  -- done, closed, archived, completed, merged, superseded, moved-to-*
  unknown -- anything else, including an empty or missing status.  Unknown is
             never "closed": a caller must not archive on it and must report it.

CLI (for shell callers, no second copy of the table):
  python3 phase_status.py classify <status>   -> open | closed | unknown
"""
from __future__ import annotations

import sys

OPEN_STATUSES = frozenset({"pending", "in_progress", "blocked", "implemented", "implemented-partial"})
CLOSED_STATUSES = frozenset({"done", "closed", "archived", "completed", "merged", "superseded"})
MOVED_PREFIX = "moved-to-"


def _normalise(status: object) -> str:
    return status.strip().lower() if isinstance(status, str) else ""


def classify(status: object) -> str:
    """Return "open", "closed" or "unknown" for a phase status value."""
    value = _normalise(status)
    if value in OPEN_STATUSES:
        return "open"
    if value in CLOSED_STATUSES or (value.startswith(MOVED_PREFIX) and len(value) > len(MOVED_PREFIX)):
        return "closed"
    return "unknown"


def is_open(status: object) -> bool:
    return classify(status) == "open"


def is_closed(status: object) -> bool:
    return classify(status) == "closed"


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] != "classify":
        print("usage: phase_status.py classify <status>", file=sys.stderr)
        return 2
    print(classify(argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
