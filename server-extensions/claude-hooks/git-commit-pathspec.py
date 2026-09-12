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

import posixpath
import re
import shlex
import sys
import unicodedata

# Pathspec magic (`:(exclude)`, `:!`, `:/`) changes matching rules in ways this
# text-only check does not model. Treat any such entry as "could match".
PATHSPEC_MAGIC_PREFIX = ":"
GLOB_CHARS = "*?["
# A pathspec entry carrying a shell expansion can expand to anything, including
# a plan file. The `-C` handling in protocol-artifact-validate.sh refuses to
# resolve these for the same reason.
EXPANSION_CHARS = "$`"

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

# `commit -i`/`--include` commits the index IN ADDITION to the listed paths,
# so the pathspec no longer bounds what goes in. `-a`/`--all` has no such
# case to cover: git itself rejects `-a`/`--all` combined with an explicit
# pathspec ("paths ... with -a does not make sense"), so by the time a
# pathspec is present here `-a` could never have been accepted.
INDEX_INCLUDING_LONG_FLAGS = {"--include"}
INDEX_INCLUDING_SHORT_LETTERS = set("i")

# Commands that run further commands from text this parser cannot see. Their
# presence anywhere makes the whole call unmodellable.
SHELL_INDIRECTION = {"sh", "bash", "zsh", "dash", "ksh", "eval", "xargs"}

# `git <subcmd> --continue` (after a conflict) or a fast-forward-less `pull`
# can create a commit that is not spelled `commit` and is not bounded by any
# pathspec this parser could check — treat their mere presence as index-wide,
# the same as `commit -a`/`-i`.
GIT_SUBCOMMANDS_MAY_COMMIT = {"rebase", "merge", "cherry-pick", "revert", "am", "pull"}

COMMAND_SEPARATORS = {";", "&&", "||", "|", "|&", "&", "(", ")", "\n"}

ENV_ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
COMMAND_WRAPPERS = ("command", "builtin", "exec")


def tokenize(command):
    """Split the command into shell tokens, or return None if unparseable.

    posix=True keeps a quoted commit message — including the multi-line
    `-m "$(cat <<'EOF' ... EOF)"` form used throughout this repo — as ONE
    token, so a `--` inside the message text can never be read as the
    pathspec separator.

    A newline is a command separator, not whitespace: agents routinely send
    two commits as two lines of one Bash call, and treating the newline as
    plain whitespace merged them into a single invocation whose pathspec then
    covered a bare `git commit` on the next line. Comment handling is off for
    the same reason — an unquoted `#` inside `-m fix#123` is a literal, and
    dropping the rest of the line there loses the pathspec.
    """
    lexer = shlex.shlex(command, posix=True, punctuation_chars="();<>|&\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    lexer.commenters = ""
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


def classify_invocation(invocation):
    """Classify one invocation. Returns a `(kind, payload)` pair:

      ("commit", args)   — a `git ... commit` call; args = tokens after commit
      ("other-git", sub) — `git <sub>`, sub not `commit` (`sub` is `None` for
                            a bare `git`/`git -C x` with nothing after)
      ("unmodellable", None) — the leading token, after skipping bare `VAR=`
          assignments and the POSIX `command`/`builtin`/`exec` wrappers, is
          not literally `git`. This is NOT the same as "proven unrelated":
          `env git commit`, `/usr/bin/git commit`, `nohup git commit`, a
          backtick-substitution, or a shell keyword (`for`, `if`, `{`) can
          all still run a commit that this text-only parser cannot see —
          conflating "unrecognized" with "safe to ignore" is exactly how the
          first draft of this parser missed several real commits (cold
          review, 2026-09-06). Only a bucket the caller must treat as KEEP.
    """
    index = 0
    while index < len(invocation) and (
        ENV_ASSIGNMENT_RE.match(invocation[index])
        or invocation[index] in COMMAND_WRAPPERS
    ):
        index += 1

    if index >= len(invocation) or invocation[index] != "git":
        return ("unmodellable", None)
    index += 1

    while index < len(invocation):
        token = invocation[index]
        if token == "commit":
            return ("commit", invocation[index + 1 :])
        if not token.startswith("-"):
            return ("other-git", token)
        if token in GIT_GLOBAL_FLAGS_WITH_VALUE:
            index += 2
            continue
        index += 1
    return ("other-git", None)


def includes_whole_index(args):
    """True when `commit` flags pull in more than the listed pathspec."""
    for token in args:
        if token == "--":
            return False
        if token in INDEX_INCLUDING_LONG_FLAGS:
            return True
        if (
            token.startswith("-")
            and not token.startswith("--")
            and set(token[1:]) & INDEX_INCLUDING_SHORT_LETTERS
        ):
            # Short flags combine: `-am`, `-im` behave like `-a`/`-i`.
            return True
    return False


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
    if any(char in entry for char in EXPANSION_CHARS):
        # `-- $FILE` can expand to the plan file itself.
        return True

    # normpath collapses `./`, `//` and `..`, so `current//DayPlan X.md` and
    # `inbox/../current/DayPlan X.md` compare like the plain spelling. NFC
    # normalization matters on macOS, where the filesystem accepts either
    # composed or decomposed accented/Cyrillic spellings of the same name.
    normalized = unicodedata.normalize(
        "NFC", posixpath.normpath(entry.rstrip("/"))
    )
    plan_path = unicodedata.normalize("NFC", plan_path)

    if normalized in ("", ".", "/"):
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
    plan_dir = posixpath.dirname(plan_path)
    if plan_dir and (
        normalized == plan_dir
        or normalized.endswith("/" + plan_dir)
        or posixpath.basename(normalized) == plan_dir
    ):
        # A directory prefix of the plan file, spelled from the repo root, an
        # absolute path, or (like the file-name fallback below) relative to
        # an invocation directory this text-only check cannot resolve.
        return True
    if posixpath.basename(normalized) == posixpath.basename(plan_path):
        # A pathspec is relative to the invocation's own directory, which this
        # text-only check cannot resolve — `git commit -- "DayPlan X.md"` run
        # from `current/` commits the plan file. Matching on the file name
        # alone keeps that case on the safe side.
        return True
    return False


def decide(command, plan_paths):
    tokens = tokenize(command)
    if tokens is None:
        return "KEEP"
    if any(token in SHELL_INDIRECTION for token in tokens):
        # `sh -c '...'` and `xargs ... git commit` run commands this parser
        # never sees, so no pathspec here bounds what actually gets committed.
        return "KEEP"

    saw_commit = False
    for invocation in split_invocations(tokens):
        kind, payload = classify_invocation(invocation)

        if kind == "unmodellable":
            # Not proven unrelated — see classify_invocation's docstring.
            return "KEEP"

        if kind == "other-git":
            if payload in GIT_SUBCOMMANDS_MAY_COMMIT:
                # `rebase/merge/... --continue` can create a commit that
                # carries the whole index and is not spelled `commit`.
                return "KEEP"
            continue

        # kind == "commit"
        saw_commit = True
        args = payload
        if includes_whole_index(args):
            return "KEEP"
        pathspec = explicit_pathspec(args)
        if pathspec is None:
            # `git commit -m x` / `git commit -a` commit the whole index —
            # validating the whole index is then correct, not a false positive.
            return "KEEP"
        for entry in pathspec:
            if any(could_match(entry, plan) for plan in plan_paths):
                return "KEEP"

    if not saw_commit:
        # No `git commit` anywhere in the command — nothing for this hook to
        # validate regardless (the caller only ever asks about `git commit`
        # invocations, see protocol-artifact-validate.sh's own anchor check),
        # but stay on the safe side rather than assume that invariant here.
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
