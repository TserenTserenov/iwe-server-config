#!/usr/bin/env python3
"""Lossless rotation of the full communication style through a size-capped hook.

The full style (S0 base + S1 author, ~26K chars) cannot pass through one hook:
the harness keeps at most PLATFORM_HOOK_CONTEXT_CHAR_LIMIT chars inline. Instead
of compressing (which would drop rules — forbidden by the pilot's no-deletion
decision of 2026-11-05) the text is cut at rule boundaries into parts that each
fit, and one part is delivered per turn on a deterministic schedule:

* warm-up: parts never sent in this session go first, one per turn, in order;
* afterwards: the most overdue part, where overdue = turn - last_sent - period;
  parts holding the "Дальше" rule or ontological purity have period 3, the rest 12;
* every turn a one-line manifest says which part was delivered and what comes next.

Concatenating the parts gives back the source text exactly.

The state file owns the turn counter: the turn number and the delivery marks are
written together, after the part is chosen, so a crash cannot shift the cadence.
PART_MAX_CHARS is the nominal part size; whether a part fits is decided per turn
from the real prefix/suffix length. A part that does not fit even without the
suffix is deferred (stays due, never cut) and the hook sends A0 + manifest only.
The cap is checked on the final text, which already contains the manifest and the
closing mark BLOCK_END, so both are always paid for.

CLI (used by inject-communication-style.sh):
    style_rotation.py --source FILE --state FILE --session ID [--turn N] [--log FILE]
Env STYLE_PREFIX / STYLE_SUFFIX: text placed before/after the style block; the
whole output never exceeds HOOK_CONTEXT_HARD_CAP chars.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from platform_limits import HOOK_CONTEXT_HARD_CAP

# Room left in the capped hook output for the A0 line (~420), the manifest (~400) and
# the A13.1 hint (usually < 800); a larger hint is dropped before a style part is.
PART_MAX_CHARS = HOOK_CONTEXT_HARD_CAP - 2000
PRIORITY_PERIOD = 3
DEFAULT_PERIOD = 12
# A line that starts a new rule or section: heading, "N. **...", "**Label:**", "- **A1 ...".
RULE_START = re.compile(r"^(#{1,4} |\d+\. \*\*|\*\*|- \*\*)")
# Priority is decided by the rule's own title, not by mentions inside examples.
PRIORITY_LABEL = re.compile(r"^(«Дальше:»|Онтологическая чистота)")
LABEL = re.compile(r"^(?:#{1,4} |\d+\. |- )?\**([^*\n]{1,60})")


def split_units(text):
    """Cut text into rule-sized units at RULE_START lines; units concatenate to text."""
    lines = text.splitlines(keepends=True)
    units, current = [], []
    for line in lines:
        if current and RULE_START.match(line):
            units.append("".join(current))
            current = []
        current.append(line)
    if current:
        units.append("".join(current))
    return units


def _split_oversize(unit, limit):
    """Split a unit longer than limit at paragraph, then line, then hard boundaries."""
    pieces, rest = [], unit
    while len(rest) > limit:
        cut = rest.rfind("\n\n", 0, limit)
        if cut <= 0:
            cut = rest.rfind("\n", 0, limit)
        cut = cut + 1 if cut > 0 else limit
        pieces.append(rest[:cut])
        rest = rest[cut:]
    if rest:
        pieces.append(rest)
    return pieces


def unit_label(unit):
    match = LABEL.match(unit.lstrip("\n"))
    return match.group(1).strip().rstrip(".:") if match else ""


def make_parts_with_periods(text, limit=PART_MAX_CHARS):
    """Greedy-pack units into parts of at most limit chars without splitting a rule.

    A rule longer than limit is split at paragraph boundaries; every piece keeps the
    priority of the rule it came from. Returns (parts, periods).
    """
    parts, periods, current, priority = [], [], "", False
    for unit in split_units(text):
        unit_priority = bool(PRIORITY_LABEL.match(unit_label(unit)))
        for piece in _split_oversize(unit, limit) if len(unit) > limit else [unit]:
            if current and len(current) + len(piece) > limit:
                parts.append(current)
                periods.append(PRIORITY_PERIOD if priority else DEFAULT_PERIOD)
                current, priority = "", False
            current += piece
            priority = priority or unit_priority
    if current:
        parts.append(current)
        periods.append(PRIORITY_PERIOD if priority else DEFAULT_PERIOD)
    return parts, periods


def make_parts(text, limit=PART_MAX_CHARS):
    return make_parts_with_periods(text, limit)[0]


def part_labels(part):
    return [label for label in (unit_label(u) for u in split_units(part)) if label]


def choose_part(turn, last_sent, periods):
    """Index of the part to deliver this turn, or None when nothing is due."""
    for index, sent in enumerate(last_sent):
        if sent is None:
            return index
    best, best_overdue = None, -1
    for index, (sent, period) in enumerate(zip(last_sent, periods)):
        overdue = turn - sent - period
        if overdue >= 0 and overdue > best_overdue:
            best, best_overdue = index, overdue
    return best


BLOCK_END = "<!-- /стиль IWE -->"


def load_state(path, source_hash, part_count):
    try:
        with open(path, encoding="utf-8") as handle:
            state = json.load(handle)
    except (OSError, ValueError):
        state = {}
    if state.get("src") != source_hash or len(state.get("last_sent", [])) != part_count:
        state = {
            "src": source_hash,
            "last_sent": [None] * part_count,
            "turn": state.get("turn", 0),
        }
    state.setdefault("turn", 0)
    return state


def render(turn, index, parts, periods, last_sent, source_hash):
    """Manifest line plus the chosen part (if any)."""
    total = len(parts)
    pending = [k for k, sent in enumerate(last_sent) if sent is None]
    if index is None:
        due = [
            (sent + period - turn, k)
            for k, (sent, period) in enumerate(zip(last_sent, periods))
        ]
        wait, nxt = min(due)
        wait = max(wait, 0)
        manifest = (
            f"<!-- стиль IWE: ход {turn}, часть в этом ходе не нужна; "
            f"следующая — {nxt + 1}/{total} через {wait} ход(а); src={source_hash} -->"
        )
        return manifest + "\n" + BLOCK_END
    labels = ", ".join(part_labels(parts[index])) or "—"
    remaining = (
        f"; ещё не показаны в этой сессии: {len(pending) - 1}" if pending else ""
    )
    manifest = (
        f"<!-- стиль IWE: часть {index + 1}/{total}, правила: {labels}; "
        f"src={source_hash}{remaining}. Полный текст — пак DP.SC.050, приходит по частям -->"
    )
    return manifest + "\n" + parts[index].rstrip("\n") + "\n" + BLOCK_END


def assemble(prefix, body, suffix):
    return "\n".join(p for p in (prefix, body, suffix) if p)


def log_line(path, fields):
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as handle:
            handle.write("\t".join(str(f) for f in fields) + "\n")
    except OSError as error:
        print(f"style_rotation: log write failed: {error}", file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument(
        "--turn", type=int, help="override the turn counter kept in --state"
    )
    parser.add_argument("--session", default="unknown")
    parser.add_argument("--log", default="")
    args = parser.parse_args(argv)

    with open(args.source, encoding="utf-8") as handle:
        source = handle.read()
    prefix = os.environ.get("STYLE_PREFIX", "")
    suffix = os.environ.get("STYLE_SUFFIX", "")
    source_hash = hashlib.sha256(source.encode("utf-8")).hexdigest()[:8]
    parts, periods = make_parts_with_periods(source)
    state = load_state(args.state, source_hash, len(parts))
    last_sent = state["last_sent"]
    turn = args.turn if args.turn is not None else state["turn"] + 1

    index = choose_part(turn, last_sent, periods)
    body = render(turn, index, parts, periods, last_sent, source_hash)
    output = assemble(prefix, body, suffix)
    mode = "inline" if index is not None else "manifest-only"
    if len(output) > HOOK_CONTEXT_HARD_CAP:
        # The style part has priority over the per-turn hint; never exceed the cap.
        output = assemble(prefix, body, "")
        mode += "-hint-dropped"
    if len(output) > HOOK_CONTEXT_HARD_CAP:
        # Never cut a rule (no-deletion decision 2026-11-05): defer the part, it stays due,
        # and report loudly so the prefix growth that caused it gets fixed.
        index = None
        mode = "deferred-oversize"
        output = assemble(
            prefix,
            render(
                turn,
                None,
                parts,
                periods,
                [s if s is not None else turn for s in last_sent],
                source_hash,
            ),
            "",
        )
        print(
            f"style_rotation: part deferred, prefix {len(prefix)} chars leaves no room "
            f"under cap {HOOK_CONTEXT_HARD_CAP}",
            file=sys.stderr,
        )
    if index is not None:
        last_sent[index] = turn
    state["last_sent"] = last_sent
    state["turn"] = turn
    tmp = args.state + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(state, handle)
    os.replace(tmp, args.state)

    part_field = f"{index + 1}/{len(parts)}" if index is not None else f"-/{len(parts)}"
    now = datetime.datetime.now(datetime.timezone.utc)  # noqa: UP017 - hooks also run on older macOS python3
    log_line(
        args.log,
        [
            now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            args.session,
            turn,
            part_field,
            len(output),
            mode,
            source_hash,
        ],
    )
    sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
