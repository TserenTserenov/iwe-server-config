#!/usr/bin/env python3
"""Block-level git merge driver for the monthly capture feeds (inbox/captures/YYYY-MM.md).

WP-5 Ф60. The extractor feeders of two hosts (git-diff-feed, session-close-feed) append blocks to the
end of the same file and inbox-check marks blocks in place. A line-wise text merge conflicts on every
overlapping append (2026-10-01 21:08: 7 blocks stuck on the Mac), and git's `merge=union` interleaves
lines of neighbouring blocks (measured on real blocks: one silently damaged block in 150-400 overlaps),
the same silent corruption that retired `merge=union` for the ledgers (WP-484 Ф157). This driver merges
by whole blocks, so a block can never be mixed with another one.

A block starts at a line `### ` that is not inside a fenced code block or an HTML comment and runs to
the next such line (fences and comments are skipped the way pending_capture_count of the extractor
skips them; real capture files have neither, and the lines `# ` and `## ` of the old monthly files stay
in the block above them). The text before the first block is the preamble.

Merge of base O, ours A, theirs B (git: `--merge-driver %O %A %B`; the result replaces %A):
  * the same block in two versions is told by its heading without marks AND its body without the report
    pointer lines (`extraction-reports/`) and blank lines: marking, which is all that changes a block
    after the feeders wrote it, adds a mark to the heading and a report pointer under it. Blocks are
    matched in order (an alignment, like a diff), so repeated headings and exact copies are handled
    position by position: an exact pair, marked `[analyzed]` and `[duplicate]` by one host while the
    other appends, lands in place (31 of the 52 repeated headings of 2026-09 were such pairs);
  * our blocks keep their place and order;
  * a block that exactly one side re-marked takes the re-marked version; if both sides re-marked it
    differently, both versions are kept (ours in place, theirs right after);
  * a block theirs added (matched to no base block) goes after ours, in theirs' order; a block both
    sides added with the same content is kept once;
  * a block one side removed and the other left as it was is removed; one side removed it and the
    other re-marked it: the re-marked version stays (a change beats a removal);
  * blank lines are layout, not content: they play no part in telling blocks apart or in telling a
    changed block from an unchanged one, so a change that only adds or removes them is not merged
    (ours stay).
Known limits (nothing is lost in any of them): a block whose body, more than a report pointer, one side
rewrote counts as a removal plus an addition, and the rewritten version may land at the end, so a mark
on that block by the other side shows up as a second version; with three or more identical copies of
which both sides re-mark two differently, merging the same theirs a second time may swap a copy for
another version (identical copies cannot be told apart; real files hold pairs, and pairs are stable).
Anything the driver cannot merge safely (an unterminated code fence or comment, a preamble both sides
edited differently) falls back to git's own line merge, the very merge a clone without the driver gets:
it merges cleanly when git itself finds a clean result, otherwise it leaves conflict markers and exits 1.
"""
import difflib
import os
import re
import subprocess
import sys
from collections import Counter

# Bump on EVERY change of the driver (semantics or fix): install-ledger-merge-driver.sh compares
# versions only and never replaces an installed copy with an older one.
MERGE_DRIVER_VERSION = 1

_FENCE = re.compile(r"^\s*(`{3,}|~{3,})")
_MARKS = re.compile(r"\s*\[(?:feed|analyzed|processed|duplicate|defer)[^\]]*\]")
# every report pointer line inbox-check has inserted (244 of them in 127 commits, in five wordings:
# `Отчёт: [..](..)`, `**Отчёт:** ..`, `> Extraction report: ..`, `См. extraction-reports/..`) names this directory
_REPORT = "extraction-reports/"


class CannotMerge(Exception):
    """The driver must not decide this merge by blocks."""


def _lines(text):
    """Split on \\n only (str.splitlines also splits on U+2028 and friends) and keep the ends."""
    parts = text.split("\n")
    out = [p + "\n" for p in parts[:-1]]
    if parts[-1]:
        out.append(parts[-1])
    return out


def parse(text):
    """Return (preamble, [block, ...]); the pieces concatenate back to `text` exactly."""
    preamble, blocks, current = [], [], None
    fence = None  # (character, run length) of the open fence
    comment = False
    for line in _lines(text):
        body = line.rstrip("\r\n")
        starts_block = False
        if comment:
            comment = "-->" not in body
        else:
            match = _FENCE.match(body)
            if match:
                run = match.group(1)
                if fence is None:
                    fence = (run[0], len(run))
                elif run[0] == fence[0] and len(run) >= fence[1] and body.strip() == run:
                    fence = None
            elif fence is None:
                if body.lstrip().startswith("<!--"):
                    comment = "-->" not in body
                elif body.startswith("### "):
                    starts_block = True
        if starts_block:
            if current is not None:
                blocks.append("".join(current))
            current = [line]
        elif current is None:
            preamble.append(line)
        else:
            current.append(line)
    if current is not None:
        blocks.append("".join(current))
    if fence is not None or comment:
        raise CannotMerge("unterminated fenced code block or HTML comment")
    return "".join(preamble), blocks


def _content(block):
    """The lines of a block that carry something: blank lines are layout."""
    return [line for line in block.split("\n") if line.strip()]


def _norm(block):
    return "\n".join(_content(block))


def _heading_key(block):
    return _MARKS.sub("", block.split("\n", 1)[0]).strip()


def _ident(block):
    """Who a block is: its heading without marks and its body without what marking adds to the body, the
    report pointer lines inbox-check inserts under the heading (and the blank lines around them)."""
    body = [line for line in _content(block)[1:] if _REPORT not in line]
    return (_heading_key(block), "\n".join(body))


def _align(base_blocks, other_blocks):
    """Index in base -> index in other for the blocks that are the same one, matched in order."""
    matcher = difflib.SequenceMatcher(None, [_ident(b) for b in base_blocks], [_ident(b) for b in other_blocks],
                                      autojunk=False)
    return {i + k: j + k for i, j, size in matcher.get_matching_blocks() for k in range(size)}


def _gap(block):
    """The block followed by exactly one blank line (the feed layout)."""
    return block.rstrip("\n") + "\n\n"


def _keep_tail(new, old):
    """`new` with the trailing newlines of `old`, so an in-place change keeps our spacing."""
    return new.rstrip("\n") + old[len(old.rstrip("\n")):]


def _combine(base_blocks, ours_blocks, theirs_blocks):
    """Decide block by block: (our blocks with in-place changes, indexes to drop, variants, additions)."""
    to_ours, to_theirs = _align(base_blocks, ours_blocks), _align(base_blocks, theirs_blocks)
    ours_texts = {_norm(b) for b in ours_blocks}
    # blocks of ours that belong to no base block: what ours added or rewrote (also what an earlier run of
    # this merge already put there, so that merging the same theirs again changes nothing)
    ours_matched = set(to_ours.values())
    ours_new = Counter(_norm(b) for j, b in enumerate(ours_blocks) if j not in ours_matched)

    out = list(ours_blocks)
    removed = set()          # indices in `out` that theirs removed and ours left untouched
    variants = {}            # index in `out` -> theirs' variant kept right after it
    revived = set()          # theirs' blocks that ours removed but theirs re-marked: the change beats the removal
    for i, base_block in enumerate(base_blocks):
        o, t = to_ours.get(i), to_theirs.get(i)
        base_text = _norm(base_block)
        if o is None:
            if t is not None and _norm(theirs_blocks[t]) != base_text:
                revived.add(t)
        elif t is None:
            if _norm(ours_blocks[o]) == base_text:
                removed.add(o)
        else:
            ours_block, theirs_block = ours_blocks[o], theirs_blocks[t]
            if _norm(theirs_block) in (base_text, _norm(ours_block)):
                continue
            if _norm(ours_block) == base_text:
                out[o] = _keep_tail(theirs_block, ours_block)
            elif _norm(theirs_block) not in ours_texts:      # else ours already holds this very block
                variants[o] = theirs_block

    theirs_matched = set(to_theirs.values()) - revived
    additions = []
    for t, block in enumerate(theirs_blocks):
        if t in theirs_matched:
            continue
        key = _norm(block)
        if ours_new[key] > 0:            # the same block is already there (added by both sides)
            ours_new[key] -= 1
            continue
        additions.append(block)
    return out, removed, variants, additions


def _layout(out, removed, variants, additions):
    """The blocks in the feed layout: ours in place, a variant right after its block, additions last."""
    final = []
    for i, block in enumerate(out):
        if i in removed:
            continue
        final.append(block)
        if i in variants:
            final[-1] = _gap(final[-1])
            final.append(_gap(variants[i]))     # theirs' last block may lack its final newline
    if additions:
        if final:
            final[-1] = _gap(final[-1])
        final.extend(_gap(b) for b in additions[:-1])
        final.append(_gap(additions[-1]))
    return "".join(final)


def merge(base, ours, theirs):
    """Return the merged text; raise CannotMerge when the driver must not decide by blocks."""
    if ours == theirs or theirs == base:
        return ours
    if ours == base:
        return theirs
    base_pre, base_blocks = parse(base)
    ours_pre, ours_blocks = parse(ours)
    theirs_pre, theirs_blocks = parse(theirs)

    if ours_pre == base_pre:
        preamble = theirs_pre
    elif theirs_pre in (base_pre, ours_pre):
        preamble = ours_pre
    else:
        raise CannotMerge("both sides changed the preamble differently")
    layout = _layout(*_combine(base_blocks, ours_blocks, theirs_blocks))
    if layout and preamble and not preamble.endswith("\n"):
        preamble += "\n"          # a heading has to start a line, or it stops being one
    return preamble + layout


def _read(path):
    if not os.path.exists(path):
        return ""
    with open(path, "rb") as handle:
        return handle.read().decode("utf-8", "surrogateescape")


def _write_result(path, text, ours_text):
    """Write the result into %A, git's own temporary file; if the write breaks half way, put our side back
    (git reads %A even after a non-zero exit, and half a result would pass for a conflict)."""
    try:
        with open(path, "wb") as handle:
            handle.write(text.encode("utf-8", "surrogateescape"))
    except OSError:
        with open(path, "wb") as handle:
            handle.write(ours_text.encode("utf-8", "surrogateescape"))
        raise


def _git_line_merge(base_path, ours_path, theirs_path):
    """What git does without a driver: the line merge into OURS, conflict markers included."""
    try:
        status = subprocess.run(["git", "merge-file", "-L", "ours", "-L", "base", "-L", "theirs",
                                 ours_path, base_path, theirs_path]).returncode
    except OSError as error:
        print(f"captures-blocks: git merge-file could not run: {error}", file=sys.stderr)
        return 1
    return 0 if status == 0 else 1


def main(argv):
    if len(argv) != 5 or argv[1] != "--merge-driver":
        print("usage: captures-block-merge.py --merge-driver BASE OURS THEIRS", file=sys.stderr)
        return 2
    base_path, ours_path, theirs_path = argv[2:5]
    base, ours, theirs = _read(base_path), _read(ours_path), _read(theirs_path)
    try:
        merged = merge(base, ours, theirs)
    except CannotMerge as error:
        print(f"captures-blocks: {error}; falling back to git's line merge", file=sys.stderr)
        return _git_line_merge(base_path, ours_path, theirs_path)
    try:
        _write_result(ours_path, merged, ours)
    except OSError as error:
        print(f"captures-blocks: could not write the merge result: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
