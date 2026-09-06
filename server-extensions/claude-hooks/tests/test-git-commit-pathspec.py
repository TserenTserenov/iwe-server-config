#!/usr/bin/env python3
"""Unit corpus for git-commit-pathspec.py (WP-7 Ф107).

Run: python3 .claude/hooks/tests/test-git-commit-pathspec.py

Every case asserts the decision that protects a specific failure mode. The
two directions are NOT symmetric and both are covered on purpose:
  * a wrong KEEP  -> the false block this phase exists to remove (visible)
  * a wrong NARROW -> a validation silently dropped (invisible, worse)
"""

import importlib.util
import pathlib
import sys

HELPER = pathlib.Path(__file__).resolve().parent.parent / "git-commit-pathspec.py"
spec = importlib.util.spec_from_file_location("git_commit_pathspec", HELPER)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)

DAYPLAN = "current/DayPlan 2026-09-06.md"
WEEKPLAN = "current/WeekPlan W36 2026-08-31.md"
PLANS = [DAYPLAN, WEEKPLAN]

HEREDOC_COMMIT = '''git -C DS-my-strategy commit -m "$(cat <<'EOF'
fix(wp7): narrow validation scope

Mentions -- current/DayPlan 2026-09-06.md inside the message body.
EOF
)" -- inbox/WP-7/WP-7.md'''

# (name, command, expected decision)
CASES = [
    # --- NARROW: provably unrelated commits, the false blocks to remove ---
    (
        "pathspec of an unrelated file only",
        "git commit -m x -- inbox/WP-7/WP-7.md",
        "NARROW",
    ),
    (
        "multi-line heredoc message plus unrelated pathspec",
        HEREDOC_COMMIT,
        "NARROW",
    ),
    (
        "several unrelated files in the pathspec",
        "git commit -m x -- a.md docs/b.md scripts/c.sh",
        "NARROW",
    ),
    (
        "-C form with unrelated pathspec",
        "git -C /Users/x/IWE/DS-my-strategy commit -m x -- inbox/WP-7/WP-7.md",
        "NARROW",
    ),
    (
        "leading env assignment before git",
        "GIT_AUTHOR_NAME=bot git commit -m x -- inbox/WP-7/WP-7.md",
        "NARROW",
    ),
    (
        "two commits, both with unrelated pathspecs",
        "git commit -m a -- a.md && git commit -m b -- b.md",
        "NARROW",
    ),
    (
        "unrelated non-commit git call in the same command",
        "git status --short; git commit -m x -- inbox/WP-7/WP-7.md",
        "NARROW",
    ),
    # --- KEEP: the whole index really is at stake ---
    (
        "bare commit takes the whole index",
        "git commit -m x",
        "KEEP",
    ),
    (
        "commit -a takes every tracked change",
        'git commit -am "x"',
        "KEEP",
    ),
    (
        "plan file is itself in the pathspec",
        f'git commit -m x -- "{DAYPLAN}"',
        "KEEP",
    ),
    (
        "weekplan in the pathspec alongside unrelated files",
        f'git commit -m x -- a.md "{WEEKPLAN}"',
        "KEEP",
    ),
    (
        "directory prefix covering the plan file",
        "git commit -m x -- current/",
        "KEEP",
    ),
    (
        "dot pathspec covering the whole repo",
        "git commit -m x -- .",
        "KEEP",
    ),
    (
        "glob that may expand onto the plan file",
        "git commit -m x -- 'current/*.md'",
        "KEEP",
    ),
    (
        "pathspec magic is not modelled, so never narrowed",
        "git commit -m x -- ':(exclude)current/'",
        "KEEP",
    ),
    (
        "absolute spelling of the plan file",
        f'git commit -m x -- "/Users/x/IWE/DS-my-strategy/{DAYPLAN}"',
        "KEEP",
    ),
    (
        "one of two commits has no pathspec",
        "git commit -m a -- a.md && git commit -m b",
        "KEEP",
    ),
    (
        "unbalanced quotes make the text unparseable",
        'git commit -m "oops -- a.md',
        "KEEP",
    ),
    (
        "no commit invocation at all",
        "git status --short",
        "KEEP",
    ),
    # --- KEEP: the trap that makes naive text parsing lose a real block ---
    (
        "-- inside the quoted message is not a pathspec separator",
        f"git commit -m 'see -- {DAYPLAN} for details'",
        "KEEP",
    ),
]


def main():
    failures = []
    for name, command, expected in CASES:
        actual = helper.decide(command, PLANS)
        if actual != expected:
            failures.append(f"{name}: expected {expected}, got {actual}")

    # Guard the caller's own contract: no plan files staged means nothing to
    # protect, and the hook must not be handed a NARROW it cannot justify.
    assert helper.decide("git commit -m x -- a.md", []) == "NARROW", (
        "decide() with an empty plan list should not claim a match; "
        "the empty-list short circuit lives in main()"
    )

    for failure in failures:
        print(f"FAIL: {failure}")
    print(f"\nPASS={len(CASES) - len(failures)} FAIL={len(failures)}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
