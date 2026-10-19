"""phase_sections.py -- shared structural scanner for <<ФN>> phase headings
across heading levels (## .. ######).

WP-484 Ф217 / WP-561 Ф42, peer-session 2026-10-19-16-wp484-wp561-phase-parser-
gate (Claude + Codex), continuing the consensus of 2026-10-19-06-close-
pipeline-analysis (Claude + Codex + Grok, cold review Fable): the archiver
(wp-archive-closed-phases.py) only ever matched `## ФN` (H2) -- cards and
create-wp.sh commonly use `### ФN` (H3), so the archiver saw zero phases on
them. A fifth independent parser was rejected in favour of pulling the
*structural* rules out of pending-phases-sweep.sh into one shared module;
callers keep their own status/terminal-marker/pending policy.

Codex's review of sweep's actual AWK (same session) found it unsuitable to
reuse wholesale:
  * sweep's phase_number() drops a letter suffix (Ф7b -> 7) -- the archiver
    already keeps suffixes and decimal sub-phases; reusing sweep's
    normalisation would collide IDs and license one phase's status onto
    another's.
  * sweep only emits PENDING/UNSUPPORTED rows (a report of open work), not a
    full heading inventory -- it cannot be the source of truth for "how many
    phase headings exist".
  * sweep re-initialises its current section on a deeper same-ID heading
    without closing the first one -- silently drops the earlier section's
    accumulated state. Every phase heading occurrence, including a
    duplicate ID, must come out as its own entry here.
  * sweep treats `blocked` (a reporting choice) as a closing signal -- that
    policy decision belongs to a caller, never to this module.

So this module owns ONLY the structure (where a phase block starts and ends,
what its id/level are, how `#### Продолжение ФNN` and duplicate ids are
represented) -- never the pending/closed verdict.

Rules (consensus of the peer-session above):
  * a phase heading `#{2,6} ФN...` (the id at the very start of the heading
    text, right after the leading #'s) closes the previously open phase
    block regardless of level or id match -- a new phase occurrence always
    starts a new block.
  * an ordinary (non-phase) heading at the same level or shallower closes
    the open phase block; a deeper heading stays nested inside it.
  * `#### Продолжение ФNN` extends the currently open block of that exact
    id (it is not a new occurrence); a mismatched id is reported as a
    diagnostic, never silently merged or silently dropped.
  * duplicates are counted by full id, not heading text -- this module only
    reports them (`duplicate: True`, `occurrence: N`); a caller decides
    whether/how to resolve which occurrence (if any) is "the" phase.
"""
from __future__ import annotations

import re

PHASE_ID = r"Ф\d+(?:\.\d+)*[а-яa-z]?"
# H1 included deliberately (cold review, peer-session 2026-10-19-16): a "# ..." line
# is rare inside a card body, but when it occurs it must still close an open phase
# block like any other heading of that level or shallower -- excluding H1 would leave
# everything after it wrongly nested inside the still-open phase.
HEADING_RE = re.compile(rf"^(#{{1,6}})\s+(.*)$")
# the id must be immediately followed by whitespace, a common separator, or end of
# heading text -- NOT a bare "-"/"/" glued on, which this corpus uses for compound
# cross-reference tags ("## Ф3/Ф6 -- ночной...") and descriptive slugs ("### Ф1-live-
# gap-audit -- ..."). Found running the --dry-run sweep across inbox/ (WP-484 Ф217
# п.4, 19.10): a plain `\b` boundary matched these as spurious extra occurrences of
# Ф3/Ф1 and made them look like duplicate ids.
_ID_TERMINATOR = r"[\s—:,.;)\]…]"
PHASE_HEAD_RE = re.compile(rf"^({PHASE_ID})(?={_ID_TERMINATOR}|$)(.*)$")
CONTINUATION_RE = re.compile(rf"^Продолжение\s+({PHASE_ID})(?={_ID_TERMINATOR}|$)")


def _fence_toggle(line: str, fence: tuple[str, int] | None) -> tuple[str, int] | None:
    """CommonMark fence tracking: close only with the same char, run >= open length."""
    m = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
    if not m:
        return fence
    run = m.group(1)
    if fence is None:
        return (run[0], len(run))
    if run[0] == fence[0] and len(run) >= fence[1] and line.strip() == run:
        return None
    return fence


def split_phase_sections(lines: list[str], start: int = 0, end: int | None = None) -> tuple[list[dict], list[dict]]:
    """Returns (sections, diagnostics).

    Each section: id, heading (full line, with its leading #'s), level,
    start, end (line indices into `lines`, end exclusive), occurrence
    (1-based per id, in document order), duplicate (bool, True if this id
    occurs more than once in [start, end)).

    Each diagnostic: line, issue, heading, open_id -- currently only
    "continuation-id-mismatch" (a `#### Продолжение ФNN` whose id does not
    match the currently open block, or no block open at all).
    """
    if end is None:
        end = len(lines)
    sections: list[dict] = []
    diagnostics: list[dict] = []
    fence: tuple[str, int] | None = None
    current: dict | None = None
    for i in range(start, end):
        ln = lines[i]
        new_fence = _fence_toggle(ln, fence)
        if new_fence != fence:
            fence = new_fence
            continue
        if fence is not None:
            continue
        m = HEADING_RE.match(ln)
        if not m:
            continue
        level = len(m.group(1))
        text = m.group(2)
        cm = CONTINUATION_RE.match(text)
        if cm:
            if current is not None and current["id"] == cm.group(1):
                current.setdefault("continuations", []).append(i)
            else:
                diagnostics.append({
                    "line": i, "issue": "continuation-id-mismatch",
                    "heading": ln.rstrip(), "open_id": current["id"] if current else None,
                })
            continue
        pm = PHASE_HEAD_RE.match(text)
        if pm:
            if current is not None:
                current["end"] = i
                sections.append(current)
            current = {"id": pm.group(1), "heading": ln.rstrip(), "level": level, "start": i, "end": end}
            continue
        # ordinary (non-phase) heading: closes the open block unless it is nested deeper
        if current is not None and level <= current["level"]:
            current["end"] = i
            sections.append(current)
            current = None
    if current is not None:
        sections.append(current)
    counts: dict[str, int] = {}
    for s in sections:
        counts[s["id"]] = counts.get(s["id"], 0) + 1
    seen: dict[str, int] = {}
    for s in sections:
        seen[s["id"]] = seen.get(s["id"], 0) + 1
        s["occurrence"] = seen[s["id"]]
        s["duplicate"] = counts[s["id"]] > 1
    return sections, diagnostics


def scan_phase_heading_lines(lines: list[str], start: int = 0, end: int | None = None) -> list[dict]:
    """Independent cross-check enumeration for split_phase_sections(): every
    line that IS a (non-continuation) phase heading, any level, fence-aware
    -- with NO block-boundary logic (no open/close stack) and no pending/
    status filter. Deliberately a different, simpler algorithm from
    split_phase_sections() above: it exists to catch bugs IN that function
    (e.g. a boundary rule that drops or doubles an occurrence), so it must
    not depend on that function's own bookkeeping to agree with it by
    construction.
    """
    if end is None:
        end = len(lines)
    out: list[dict] = []
    fence: tuple[str, int] | None = None
    for i in range(start, end):
        ln = lines[i]
        new_fence = _fence_toggle(ln, fence)
        if new_fence != fence:
            fence = new_fence
            continue
        if fence is not None:
            continue
        m = HEADING_RE.match(ln)
        if not m:
            continue
        text = m.group(2)
        if CONTINUATION_RE.match(text):
            continue
        pm = PHASE_HEAD_RE.match(text)
        if pm:
            out.append({"line": i, "id": pm.group(1), "level": len(m.group(1))})
    return out
