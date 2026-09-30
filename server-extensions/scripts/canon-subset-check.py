#!/usr/bin/env python3
"""canon-subset-check.py <canon-repo> [<origin-ref>]

For every commit the canon carries that origin/<ref> does not (git cherry '+'),
and for every dirty tracked path of the canon working tree, say whether origin
already covers the canon content. Verdicts, strongest first:
  EQUAL          identical to the version on origin
  ANCESTRAL_PATH the canon blob occurred earlier in origin's history of the SAME
                 path, and the path still exists on origin: the canon holds an
                 older state of origin, nothing of it is unique. Renames and
                 deletions never qualify (path missing on origin gives UNIQUE).
  SUBSET         every non-empty line of the canon version occurs on origin
                 (multiset, feed tags stripped): weaker, for appended feeds
  UNIQUE         canon content origin lacks; must be published or explicitly
                 accepted by the pilot before the canon ref may move
ANCESTRAL_PATH is history-based evidence, not a proof of compatibility with the
current origin tip; use it to decide "nothing is lost", not "safe to overwrite".
Exit 0 when nothing is UNIQUE, 1 otherwise. Read-only (git show/rev-list/hash-object).
"""
import re
import subprocess
import sys
from collections import Counter

TAG_RE = re.compile(r"\s*\[(feed|analyzed)[^\]]*\]")
HISTORY_LIMIT = 400


def git(repo, *args, check=True):
    return subprocess.run(["git", "-C", repo, *args], check=check, capture_output=True, text=True).stdout


def blob_text(repo, rev, path):
    try:
        return git(repo, "show", f"{rev}:{path}")
    except subprocess.CalledProcessError:
        return None


def blob_id(repo, rev, path):
    out = git(repo, "rev-parse", "--verify", "-q", f"{rev}:{path}", check=False).strip()
    return out or None


def lines(text):
    return Counter(TAG_RE.sub("", ln).rstrip() for ln in text.splitlines() if ln.strip())


def in_path_history(repo, ref, path, wanted_blob):
    """True when `wanted_blob` was the content of `path` in some commit of `ref`."""
    if wanted_blob is None or blob_id(repo, ref, path) is None:
        return False
    for sha in git(repo, "rev-list", f"--max-count={HISTORY_LIMIT}", ref, "--", path).split():
        if blob_id(repo, sha, path) == wanted_blob:
            return True
    return False


def classify(repo, ref, path, canon_text, canon_blob):
    origin_text = blob_text(repo, ref, path)
    if canon_text is None and origin_text is None:
        return "EQUAL", "deleted on both sides"
    if canon_text is None:
        return "UNIQUE", "deleted in canon but still present on origin"
    if origin_text is None:
        return "UNIQUE", "path absent on origin (deleted or renamed there)"
    if canon_text == origin_text:
        return "EQUAL", ""
    if in_path_history(repo, ref, path, canon_blob):
        return "ANCESTRAL_PATH", "canon = earlier state of origin"
    missing = lines(canon_text) - lines(origin_text)
    if not missing:
        return "SUBSET", f"origin has {len(lines(origin_text) - lines(canon_text))} extra line(s)"
    sample = next(iter(missing))[:90]
    return "UNIQUE", f"{sum(missing.values())} canon line(s) not on origin, e.g. {sample!r}"


def main():
    repo = sys.argv[1]
    ref = sys.argv[2] if len(sys.argv) > 2 else "origin/main"
    unique = 0
    print(f"== local-only commits vs {ref} ==")
    for row in git(repo, "cherry", "-v", ref, "HEAD").splitlines():
        mark, sha, *subject = row.split(" ", 2)
        title = subject[0][:70] if subject else ""
        if mark != "+":
            print(f"- {sha[:9]} patch-equivalent on {ref}: {title}")
            continue
        print(f"+ {sha[:9]} {title}")
        for path in git(repo, "diff-tree", "--no-commit-id", "-r", "--name-only", sha).splitlines():
            verdict, note = classify(repo, ref, path, blob_text(repo, sha, path), blob_id(repo, sha, path))
            unique += verdict == "UNIQUE"
            print(f"    {verdict:14} {path} {note}")
    print("== dirty tracked paths (working tree vs origin) ==")
    for row in git(repo, "status", "--porcelain").splitlines():
        status, path = row[:2], row[3:].strip('"')
        if status.startswith("??"):
            continue
        with open(f"{repo}/{path}", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        wt_blob = git(repo, "hash-object", "--", path).strip()
        verdict, note = classify(repo, ref, path, text, wt_blob)
        unique += verdict == "UNIQUE"
        print(f"    {verdict:14} [{status}] {path} {note}")
    print(f"UNIQUE paths: {unique}")
    sys.exit(1 if unique else 0)


if __name__ == "__main__":
    main()
