#!/usr/bin/env python3
"""Decide whether a `git commit` Bash call provably excludes given files.

Used by protocol-artifact-validate.sh (WP-7 Ф107). That hook reads the WHOLE
staged index of the governance repo, so a DayPlan/WeekPlan staged by some
OTHER agent on the shared checkout blocks a commit that does not include it.

This helper answers one narrow question: can we PROVE, from the command text
alone, that none of the given plan files is part of what is being committed?

Contract
--------
stdin  : the raw Bash command text intercepted by the hook
argv[1:]: staged plan-file paths, repo-root-relative (e.g. "current/DayPlan X.md")
stdout : "NARROW" — proven excluded, the caller may skip validation
         "KEEP"   — not proven, the caller must keep its current behaviour
exit   : always 0; every failure path prints KEEP

"NARROW" requires ALL of:
  * the command contains at least one `git ... commit` invocation, and
  * EVERY such invocation carries an explicit `-- <pathspec>`, and
  * no pathspec entry could match any of the given plan files.

Anything else — a bare `git commit`, `git commit -a`, a glob, an unparseable
command — yields KEEP. The asymmetry is deliberate: a wrong KEEP reproduces a
false block, which is visible and annoying; a wrong NARROW silently drops a
real validation, which nobody would ever notice.
"""

import re
import shlex
import sys

# Pathspec magic (`:(exclude)`, `:!`, `:/`) changes matching rules in ways this
# text-only check does not model. Treat any such entry as "could match".
PATHSPEC_MAGIC_PREFIX = ":"
GLOB_CHARS = "*?["

# `git` accepts these before the subcommand; each consumes a following value,
# so the value must not be mistaken for the `commit` token.
GIT_GLOBAL_FLAGS_WITH_VALUE = {
    "-C",
    "-c",
    "--git-dir",
    "--work-tree",
    "--namespace",
    "--exec-path",
}

COMMAND_SEPARATORS = {";", "&&", "||", "|", "&", "(", ")", "\n"}

ENV_ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
COMMAND_WRAPPERS = ("command", "builtin", "exec")


def tokenize(command):
    """Split the command into shell tokens, or return None if unparseable.

    posix=True keeps a quoted commit message — including the multi-line
    `-m "$(cat <<'EOF' ... EOF)"` form used throughout this repo — as ONE
    token, so a `--` inside the message text can never be read as the
    pathspec separator.
    """
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        return list(lexer)
    except ValueError:
        # Unbalanced quotes: the text is not a shell command we can reason
        # about. Caller falls back to whole-index validation.
        return None


def split_invocations(tokens):
    """Split a token list into separate command invocations."""
    invocations = []
    current = []
    for token in tokens:
        if token in COMMAND_SEPARATORS:
            if current:
                invocations.append(current)
            current = []
        else:
            current.append(token)
    if current:
        invocations.append(current)
    return invocations


def commit_args(invocation):
    """Return the args after `commit` for a `git ... commit` call, else None.

    Leading `VAR=value` assignments and `command`/`exec`/`builtin` wrappers are
    skipped, matching the invocation anchoring in protocol-artifact-validate.sh.
    """
    index = 0
    while index < len(invocation) and (
        ENV_ASSIGNMENT_RE.match(invocation[index])
        or invocation[index] in COMMAND_WRAPPERS
    ):
        index += 1

    if index >= len(invocation) or invocation[index] != "git":
        return None
    index += 1

    while index < len(invocation):
        token = invocation[index]
        if token == "commit":
            return invocation[index + 1 :]
        if not token.startswith("-"):
            # A non-flag token before `commit` means this is some other
            # subcommand (`git rev-parse`, `git merge`, ...).
            return None
        if token in GIT_GLOBAL_FLAGS_WITH_VALUE:
            index += 2
            continue
        index += 1
    return None


def explicit_pathspec(args):
    """Return the pathspec after `--`, or None when the call has no explicit one.

    An empty list (`git commit -- `) is a valid "commits nothing extra" answer
    and is returned as an empty list, not None.
    """
    for position, token in enumerate(args):
        if token == "--":
            return args[position + 1 :]
    return None


def could_match(entry, plan_path):
    """Conservative test: could this pathspec entry cover this plan file?"""
    if entry.startswith(PATHSPEC_MAGIC_PREFIX):
        return True
    if any(char in entry for char in GLOB_CHARS):
        return True

    normalized = entry
    while normalized.startswith("./"):
        normalized = normalized[2:]
    normalized = normalized.rstrip("/")

    if normalized in ("", "."):
        # The whole repository.
        return True
    if normalized == plan_path:
        return True
    if plan_path.startswith(normalized + "/"):
        # A directory prefix of the plan file.
        return True
    if normalized.endswith("/" + plan_path):
        # An absolute or otherwise-prefixed spelling of the same file.
        return True
    return False


def decide(command, plan_paths):
    tokens = tokenize(command)
    if tokens is None:
        return "KEEP"

    commit_calls = [
        args
        for args in (commit_args(inv) for inv in split_invocations(tokens))
        if args is not None
    ]
    if not commit_calls:
        return "KEEP"

    for args in commit_calls:
        pathspec = explicit_pathspec(args)
        if pathspec is None:
            # `git commit -m x` / `git commit -a` commit the whole index —
            # validating the whole index is then correct, not a false positive.
            return "KEEP"
        for entry in pathspec:
            if any(could_match(entry, plan) for plan in plan_paths):
                return "KEEP"
    return "NARROW"


def main():
    plan_paths = [path for path in sys.argv[1:] if path]
    if not plan_paths:
        print("KEEP")
        return
    print(decide(sys.stdin.read(), plan_paths))


if __name__ == "__main__":
    main()
