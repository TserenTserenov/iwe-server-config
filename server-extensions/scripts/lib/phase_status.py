"""phase_status.py -- the one place that decides whether a phase status means
"open" or "closed" (WP-484 Ф299 п.1).

Before this module three programs kept three different lists:
  * wp-archive-closed-phases.py treated only done/closed/archived/completed as
    closed (so `merged`, `superseded` read as open);
  * wp-handoff-check.py treated only pending/in_progress/blocked as open (so
    `implemented` fell out of the snapshot);
  * wp-sync-bundle.sh carried a third inline copy of the open list.
wp-phase-snapshot-write.py reuses the archiver's classifier, so it follows.

Contract (peer-session 2026-11-11-06-wp484-next-phase, Claude+Kimi+Codex; the "parked" class and
`cancelled` added 2026-11-11, peer-session 2026-11-11-07-wp484-f299-phase-source, pilot's word
«сделаем правило только из таблицы»):
  open    -- pending, in_progress, blocked, implemented, implemented-partial
             (implemented* wait for acceptance, they are not finished)
  parked  -- deferred (`defer` is accepted as the same word): put aside on purpose, not worked now.
             Not open (it does not demand a «Следующий шаг» naming it) and not closed (it is not
             archived, the work still exists).
  closed  -- done, closed, archived, completed, merged, superseded, cancelled, moved-to-<WP>
  unknown -- anything else, including an empty or missing status.  Unknown is
             never "closed": a caller must not archive on it and must report it.
The table is the ONLY vocabulary: a status word that is not in it is a defect of the card, not a new
word (docs/INBOX-CONVENTION.md of the governance repo lists the same words; a test keeps the two equal).

CLI (for shell callers, no second copy of the table):
  python3 phase_status.py classify <status>   -> open | parked | closed | unknown
"""
from __future__ import annotations

import re
import sys

OPEN_STATUSES = frozenset({"pending", "in_progress", "blocked", "implemented", "implemented-partial"})
PARKED_STATUSES = frozenset({"deferred", "defer"})
CLOSED_STATUSES = frozenset({"done", "closed", "archived", "completed", "merged", "superseded", "cancelled"})
MOVED_PREFIX = "moved-to-"


def _normalise(status: object) -> str:
    return status.strip().lower() if isinstance(status, str) else ""


def classify(status: object) -> str:
    """Return "open", "parked", "closed" or "unknown" for a phase status value."""
    value = _normalise(status)
    if value in OPEN_STATUSES:
        return "open"
    if value in PARKED_STATUSES:
        return "parked"
    if value in CLOSED_STATUSES or (value.startswith(MOVED_PREFIX) and len(value) > len(MOVED_PREFIX)):
        return "closed"
    return "unknown"


def is_open(status: object) -> bool:
    return classify(status) == "open"


def is_closed(status: object) -> bool:
    return classify(status) == "closed"


def is_parked(status: object) -> bool:
    return classify(status) == "parked"


# ФN, sub-phases ФN.M(.K), optional letter suffix (Ф5а).  Kept equal to
# phase_sections.PHASE_ID (a test guards the two against drifting apart).
PHASE_ID = r"Ф\d+(?:\.\d+)*[а-яa-z]?"
_PHASE_ID_RE = re.compile(PHASE_ID)
_PHASES_KEY_RE = re.compile(r"^phases:\s*(?:#.*)?$")
_STATUS_VALUE = r"[A-Za-z][A-Za-z0-9_.-]*"
_MAP_ENTRY_RE = re.compile(rf"^\s{{2,}}({PHASE_ID})\s*:\s*[\"']?({_STATUS_VALUE})[\"']?\s*(?:#.*)?$")
_MAP_KEY_ONLY_RE = re.compile(rf"^\s{{2,}}({PHASE_ID})\s*:\s*(?:#.*)?$")
# `key: value` pairs of a flow mapping; a quoted value is consumed whole, so a `status: x`
# inside a quoted title is never read as the status.
_FLOW_PAIR_RE = re.compile(r"""(\w+)\s*:\s*("(?:[^"\\]|\\.)*"|'[^']*'|[^,}]+)""")
_LIST_ID_RE = re.compile(r"^\s*-\s*(?:id|phase)\s*:\s*[\"']?([^\"'#\s]+)[\"']?\s*(?:#.*)?$")
_LIST_STATUS_RE = re.compile(rf"^\s+status\s*:\s*[\"']?({_STATUS_VALUE})[\"']?\s*(?:#.*)?$")


def parse_phases(frontmatter_lines: list[str]) -> dict[str, str] | None:
    """Read the `phases:` block of a card's frontmatter (the lines between the `---` fences).

    The one parser for the four programs that used to keep their own (archiver
    regexes, handoff check and sync bundle through PyYAML, each with its own id
    grammar).  Stdlib only, because the gate runs under `find-python3 --stdlib-only`.

    Returns None when the card has no `phases:` key (legacy cards -- callers fall
    back to the heading scan), otherwise {id: status} in file order.  Both shapes:
      map   `  Ф16: pending`
      list  `- id: Ф16` followed by `  status: pending` (a bare number is read as ФN)
      flow  `- {id: Ф16, title: "x", status: pending}`
      nested `  Ф16:` followed by `    status: pending`
    Ids must follow PHASE_ID (Cyrillic Ф): Latin `F1`/`f1` and free-form keys are not read, so a card that
    uses them yields {} -- callers treat an empty result as "block present but unreadable" and fall back
    to the heading scan instead of reporting "no open phases".
    Statuses may carry hyphens (`implemented-partial`, `moved-to-wp-5`).
    """
    start = next((i for i, ln in enumerate(frontmatter_lines) if _PHASES_KEY_RE.match(ln)), None)
    if start is None:
        return None
    phases: dict[str, str] = {}
    current_id: str | None = None
    for line in frontmatter_lines[start + 1:]:
        if line.strip() == "" or line.lstrip().startswith("#"):
            continue
        if not line.startswith((" ", "-")):
            break  # next top-level key
        entry = _MAP_ENTRY_RE.match(line)
        if entry:
            phases[entry.group(1)] = entry.group(2)
            current_id = None
            continue
        bare_key = _MAP_KEY_ONLY_RE.match(line)
        if bare_key:  # nested form: the status follows on an indented `status:` line
            current_id = bare_key.group(1)
            continue
        if "{" in line:
            pairs = {key: value.strip().strip("\"'") for key, value in _FLOW_PAIR_RE.findall(line.split("{", 1)[1])}
            raw = pairs.get("id") or pairs.get("phase") or ""
            raw = f"Ф{raw}" if raw.isdecimal() else raw
            if _PHASE_ID_RE.fullmatch(raw) and re.fullmatch(_STATUS_VALUE, pairs.get("status", "")):
                phases[raw] = pairs["status"]
                current_id = None
                continue
        list_id = _LIST_ID_RE.match(line)
        if list_id:
            raw = list_id.group(1)
            raw = f"Ф{raw}" if raw.isdecimal() else raw
            current_id = raw if _PHASE_ID_RE.fullmatch(raw) else None
            continue
        list_status = _LIST_STATUS_RE.match(line)
        if list_status and current_id:
            phases[current_id] = list_status.group(1)
    return phases


def frontmatter_lines(card_text: str) -> list[str]:
    """Lines between the first two `---` fences; [] when the card has no frontmatter."""
    lines = card_text.splitlines()
    if not lines or lines[0].strip() != "---":
        return []
    for index in range(1, len(lines)):
        if lines[index].strip() == "---":
            return lines[1:index]
    return []


def phase_sort_key(phase_id: str) -> tuple:
    digits = re.findall(r"\d+", phase_id)
    return (tuple(int(d) for d in digits), phase_id)


def open_ids(phases: dict[str, str]) -> list[str]:
    """Ids whose status is open, in numeric order.  Unknown statuses are NOT open."""
    return sorted((pid for pid, status in phases.items() if is_open(status)), key=phase_sort_key)


def parked_ids(phases: dict[str, str]) -> list[str]:
    """Ids put aside on purpose (deferred): neither open nor closed, listed apart from the unknown ones."""
    return sorted((pid for pid, status in phases.items() if is_parked(status)), key=phase_sort_key)


def unknown_ids(phases: dict[str, str]) -> list[str]:
    """Ids with a status the table does not know -- neither open nor closed; callers report them."""
    return sorted((pid for pid, status in phases.items() if classify(status) == "unknown"), key=phase_sort_key)


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] != "classify":
        print("usage: phase_status.py classify <status>", file=sys.stderr)
        return 2
    print(classify(argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
