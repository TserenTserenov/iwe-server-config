"""Claim lines of a session semaphore (WP-484 Ф275).

A claim line is `commit: <repo> <sha>` or, since precondition 3,
`commit: <repo> <sha> <checkout> <branch>`. The identity of a claim is the pair
(repo, sha); checkout and branch are context that moves (a branch advances, a
checkout differs between hosts) and must never take part in an equality check.

Fields are separated by exactly one space and the line has no trailing space:
the writers (note-commit, promote-intent) refuse whitespace inside a field, so
a line that deviates is not theirs and is refused here as well.

The bash twin of this module is lib/claim-line.sh; both run the cases of
tests/fixtures/claim-line-cases.json.
"""
from __future__ import annotations

import re
from typing import NamedTuple, Optional

PREFIX = "commit: "

# The sha group is the superset of every spelling a reader accepts today:
# narrowing it would turn a line that is accepted now into a parse error. The
# canonical spelling that a writer produces is stricter (see is_canonical_sha).
_CLAIM = re.compile(r"commit: (\S+) ([0-9a-fA-F]{40,64})(?: (\S+) (\S+))?")
_CANONICAL_SHA = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")


class ClaimError(ValueError):
    """A line starts with the claim prefix but is not a 2- or 4-field claim."""


class Claim(NamedTuple):
    repo: str
    sha: str
    checkout: Optional[str]
    branch: Optional[str]


def parse(line: str) -> Optional[Claim]:
    """Return the claim, None for a line that is not a claim, raise ClaimError for a broken one."""
    if not line.startswith(PREFIX):
        return None
    match = _CLAIM.fullmatch(line)
    if match is None:
        raise ClaimError("not a 2- or 4-field claim: %r" % line)
    return Claim(*match.groups())


def is_canonical_sha(sha: str) -> bool:
    return _CANONICAL_SHA.fullmatch(sha) is not None


def matches(line: str, repo: str, sha: str) -> bool:
    """True when the line is a well-formed claim on exactly this (repo, sha)."""
    try:
        claim = parse(line)
    except ClaimError:
        return False
    return claim is not None and (claim.repo, claim.sha) == (repo, sha)
