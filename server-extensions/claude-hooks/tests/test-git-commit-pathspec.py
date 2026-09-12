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
import subprocess
import sys
import unicodedata

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
    # --- KEEP: holes found by cold review of the first draft (2026-09-06) ---
    # Every one of these answered NARROW while the plan file really would have
    # gone into the commit. They are the silent-loss direction, so each gets a
    # named case rather than a shared one.
    (
        "newline separates two commands, the second one unscoped",
        "git commit -m a -- notes.md\ngit commit -m b",
        "KEEP",
    ),
    (
        "newline separates two commands, the second one -a",
        "git commit -m a -- notes.md\ngit commit -am b",
        "KEEP",
    ),
    (
        "unexpanded variable can expand to the plan file",
        "git commit -m x -- $FILE",
        "KEEP",
    ),
    (
        "quoted unexpanded variable is no safer",
        'git commit -m "$MSG" -- "$WP_FILE"',
        "KEEP",
    ),
    (
        "command substitution in the pathspec",
        "git commit -m x -- $(ls current)",
        "KEEP",
    ),
    (
        "pathspec spelled relative to a subdirectory",
        "git commit -m x -- 'DayPlan 2026-09-06.md'",
        "KEEP",
    ),
    (
        "double slash inside the pathspec",
        f"git commit -m x -- 'current//{DAYPLAN.split('/', 1)[1]}'",
        "KEEP",
    ),
    (
        "dot-dot detour back into current/",
        "git commit -m x -- 'inbox/../current/DayPlan 2026-09-06.md'",
        "KEEP",
    ),
    (
        "commit -i adds the whole index on top of the pathspec",
        "git commit -i -m x -- notes.md",
        "KEEP",
    ),
    (
        "combined short flags hide the include mode",
        "git commit -im x -- notes.md",
        "KEEP",
    ),
    (
        "--include spelled long",
        "git commit --include -m x -- notes.md",
        "KEEP",
    ),
    (
        "nested sh -c runs a commit this parser cannot see",
        "git commit -m a -- notes.md && sh -c 'git commit -m b'",
        "KEEP",
    ),
    (
        "xargs runs a commit this parser cannot see",
        "git commit -m a -- notes.md && echo z | xargs -I{} git commit -m {}",
        "KEEP",
    ),
    (
        "git commit only mentioned as bash text is still unmodellable",
        "git commit -m a -- notes.md && bash -c 'true'",
        "KEEP",
    ),
    # --- NARROW: false blocks the cold review found on the other side ---
    (
        "unquoted # is a literal, not a comment that eats the pathspec",
        "git commit -m fix#123 -- notes.md",
        "NARROW",
    ),
    # --- git semantics the first draft left unpinned ---
    (
        "the FIRST -- opens the pathspec, later ones are entries",
        f'git commit -m x -- "{DAYPLAN}" -- notes.md',
        "KEEP",
    ),
    # --- KEEP: holes found by a SECOND cold review (2026-09-06) ---
    # "unmodellable" is now its own outcome from classify_invocation, distinct
    # from "proven unrelated" — these are all commits reached through a
    # leading token the first draft silently treated as "not git at all".
    (
        "env wrapper before the real git invocation",
        "git commit -m a -- notes.md && env git commit -m b",
        "KEEP",
    ),
    (
        "nohup wrapper before the real git invocation",
        "git commit -m a -- notes.md && nohup git commit -m b",
        "KEEP",
    ),
    (
        "absolute path to the git binary",
        "git commit -m a -- notes.md && /usr/bin/git commit -m b",
        "KEEP",
    ),
    (
        "backtick command substitution runs an unmodelled commit",
        "git commit -m a -- notes.md && X=`git commit -m b`",
        "KEEP",
    ),
    (
        "|& is a separator too, not part of a pathspec entry",
        "git commit -m a -- notes.md |& git commit -m b",
        "KEEP",
    ),
    (
        "rebase --continue can create a commit outside any pathspec",
        "git commit -m a -- notes.md && git rebase --continue",
        "KEEP",
    ),
    (
        "merge --continue can create a commit outside any pathspec",
        "git commit -m a -- notes.md && git merge --continue",
        "KEEP",
    ),
    (
        "directory pathspec spelled as an absolute path, not from repo root",
        "git commit -m x -- /Users/x/IWE/DS-my-strategy/current",
        "KEEP",
    ),
    (
        "directory pathspec spelled relative to a parent directory",
        "git commit -m x -- ../current",
        "KEEP",
    ),
    # --- unchanged by the second pass: a genuinely unrelated git subcommand
    # earlier in the compound command must not force a KEEP by itself ---
    (
        "git status earlier in the command is not commit-adjacent",
        "git status --short && git commit -m x -- notes.md",
        "NARROW",
    ),
]

# macOS accepts either the composed (NFC) or decomposed (NFD) spelling of an
# accented/Cyrillic file name as the same path. A plan file name is ASCII
# today, but the DayPlan regex in protocol-artifact-validate.sh does not
# require that, so a pathspec entry spelled in the other normal form must
# still be recognized as the same file (cold review, second pass, 2026-09-06).
# This needs its own plan path with an actually-decomposable character —
# neither DAYPLAN nor WEEKPLAN has one, so it cannot reuse CASES/PLANS above.
NFC_PLAN = "current/DayPlan Отчёт.md"
NFD_PLAN = unicodedata.normalize("NFD", NFC_PLAN)
assert NFD_PLAN != NFC_PLAN, "fixture must actually be decomposed, or this test proves nothing"
UNICODE_CASES = [
    (
        "NFD-decomposed pathspec entry matches an NFC-composed plan path",
        f'git commit -m x -- "{NFD_PLAN}"',
        [NFC_PLAN],
        "KEEP",
    ),
]


def run_main(argv, stdin_text):
    """Run the helper end to end, the way the hook invokes it."""
    completed = subprocess.run(
        [sys.executable, str(HELPER), *argv],
        input=stdin_text,
        capture_output=True,
        text=True,
        check=False,
    )
    assert completed.returncode == 0, (
        f"helper must always exit 0 so the hook can read its answer; "
        f"got {completed.returncode}, stderr={completed.stderr!r}"
    )
    return completed.stdout.strip()


def main():
    total = 0
    failures = []
    for name, command, expected in CASES:
        total += 1
        actual = helper.decide(command, PLANS)
        if actual != expected:
            failures.append(f"{name}: expected {expected}, got {actual}")

    for name, command, plans, expected in UNICODE_CASES:
        total += 1
        actual = helper.decide(command, plans)
        if actual != expected:
            failures.append(f"{name}: expected {expected}, got {actual}")

    # The entry point is where the safety net actually lives, so test IT, not
    # decide(): with no plan paths there is nothing to prove excluded, and the
    # hook must never receive a NARROW it cannot justify.
    for argv, stdin, expected in (
        ([], "git commit -m x -- a.md", "KEEP"),
        ([""], "git commit -m x -- a.md", "KEEP"),
        ([DAYPLAN], "git commit -m x -- a.md", "NARROW"),
        ([DAYPLAN], "git commit -m x", "KEEP"),
    ):
        total += 1
        result = run_main(argv, stdin)
        if result != expected:
            failures.append(f"main({argv!r}) printed {result!r}, expected {expected!r}")

    for failure in failures:
        print(f"FAIL: {failure}")
    print(f"\nPASS={total - len(failures)} FAIL={len(failures)}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
