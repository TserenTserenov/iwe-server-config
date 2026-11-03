#!/usr/bin/env python3
"""Guardrail check before ledger-publish.sh auto-resets a diverged checkout.

WP-503 (2026-08-31, peer-session with Codex): a dedicated automation
checkout can drift onto a pre-rewrite branch tip and never recover on its
own -- every preflight rebase conflicts the same way forever, and the
checkout just accumulates local-only ledger-append commits nobody looks at.
A reset to origin discards that local history, which is only safe if none
of the touched machine/ledger/**/*.yaml files carry events origin doesn't
already have.

This mirrors the manual check done for the initial incident recovery:
for every ledger file the local branch touches that origin/main doesn't
already contain, verify (a) the full event multiset is a subset of
origin's version (ledger-event-diff.py's own check) and (b) the
schema/scale/period header fields match -- ledger-event-diff.py only looks
at `events`, and a structural difference there would be invisible to it.

Usage: ledger-safe-reset-check.py <checkout> <branch>
Exit 0 = every touched file is a clean subset of origin, safe to reset.
Exit 1 = at least one file has content git can't prove is redundant --
         print exactly which files and why, so the caller can put that in
         an actionable alert instead of the current opaque conflict.

WP-503 (2026-09-01, peer-session with Codex, follow-up): a diverged local
*commit* isn't the only way this checkout jams a rebase -- an untracked
machine/ledger/*.yaml file left by a prior crashed drain collides with the
same path in origin's new commit just as hard, and `git reset --hard` does
NOT protect it the way `git rebase`/`git checkout` do: it silently
overwrites an untracked path that exists in the target tree, discarding
whatever the untracked copy held if it differs (confirmed empirically --
see peer-session notes). This checker discovers such files itself (not
from a caller-supplied list, in case the caller's snapshot is stale) and
requires an exact byte match against origin's committed version before
calling them safe; the committed-file path above still uses the looser
event-subset check because a legitimate local-only commit is allowed to
carry append-only growth, but a stray untracked file lacks that provenance
and gets no such benefit of the doubt.
"""
import json
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
EVENT_DIFF_TOOL = SCRIPT_DIR / "ledger-event-diff.py"

TOP_LEVEL_FIELDS = ("schema", "scale", "period")


def git_show(repo, ref, path):
    result = subprocess.run(
        ["git", "-C", str(repo), "show", f"{ref}:{path}"],
        capture_output=True, text=True,
    )
    return result.stdout if result.returncode == 0 else None


def git_show_bytes(repo, ref, path):
    result = subprocess.run(
        ["git", "-C", str(repo), "show", f"{ref}:{path}"],
        capture_output=True,
    )
    return result.stdout if result.returncode == 0 else None


def untracked_ledger_files(repo):
    """machine/ledger/*.yaml paths git sees as untracked, found here (not
    trusted from a caller-supplied list -- see module docstring).

    `-uall`, not the default `-unormal`: a wholly-new leaf directory (the
    common case) collapses to a single `?? machine/ledger/day/2026/09/`
    porcelain line under the default mode, which this function's per-file
    filter below would never match -- silently reporting zero untracked
    ledger files even when one is sitting right there (found live testing
    this exact branch, mirrors the same fix already needed in
    ledger-publish.sh's caller-side gate).

    `-z`, NUL-separated: plain `--porcelain` quotes a path with a space and
    octal-escapes non-ASCII bytes, which would desync a naive `line[3:]`
    slice from the real on-disk filename `(repo / rel_path).read_bytes()`
    later tries to open (cold-context review, 2026-09-01 -- the same defect
    class ledger-publish.sh's own `list_untracked_outside_ledger` already
    exists to avoid)."""
    result = subprocess.run(
        ["git", "-C", str(repo), "status", "--porcelain", "-uall", "-z"],
        capture_output=True, text=True,
    )
    files = []
    for entry in result.stdout.split("\0"):
        if not entry.startswith("?? "):
            continue
        path = entry[3:]
        if path.startswith("machine/ledger/") and path.endswith(".yaml"):
            files.append(path)
    return sorted(files)


def touched_ledger_files(repo, branch):
    result = subprocess.run(
        ["git", "-C", str(repo), "log", "--name-only", "--format=",
         branch, f"^origin/{branch}", "--", "machine/ledger/**/*.yaml"],
        capture_output=True, text=True,
    )
    return sorted({line for line in result.stdout.splitlines() if line})


def event_subset_ok(src_text, dst_path):
    src_path = dst_path.parent / f".{dst_path.name}.src-check"
    src_path.write_text(src_text, encoding="utf-8")
    try:
        result = subprocess.run(
            [sys.executable, str(EVENT_DIFF_TOOL), "--source-subset",
             str(src_path), str(dst_path)],
            capture_output=True, text=True,
        )
        return result.returncode == 0, result.stderr.strip()
    finally:
        src_path.unlink(missing_ok=True)


def structure_matches(src_text, dst_text):
    import yaml
    src = yaml.safe_load(src_text)
    dst = yaml.safe_load(dst_text)
    for field in TOP_LEVEL_FIELDS:
        if src.get(field) != dst.get(field):
            return False, f"{field}: {src.get(field)!r} != {dst.get(field)!r}"
    extra = set(src.keys()) - {*TOP_LEVEL_FIELDS, "events"}
    if extra:
        return False, f"unexpected extra top-level keys: {extra}"
    return True, ""


def main(argv):
    if len(argv) != 3:
        print("usage: ledger-safe-reset-check.py <checkout> <branch>", file=sys.stderr)
        return 1
    repo, branch = Path(argv[1]), argv[2]

    problems = []
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        for rel_path in touched_ledger_files(repo, branch):
            src_text = git_show(repo, branch, rel_path)
            dst_text = git_show(repo, f"origin/{branch}", rel_path)
            if dst_text is None:
                problems.append((rel_path, "missing on origin -- local-only file"))
                continue

            dst_path = tmp_path / Path(rel_path).name
            dst_path.write_text(dst_text, encoding="utf-8")
            ok, reason = event_subset_ok(src_text, dst_path)
            if not ok:
                problems.append((rel_path, f"event-subset check: {reason}"))
                continue

            try:
                ok, reason = structure_matches(src_text, dst_text)
            except Exception as exc:  # noqa: BLE001 -- unparseable YAML is itself a finding
                problems.append((rel_path, f"unparseable, cannot verify: {exc}"))
                continue
            if not ok:
                problems.append((rel_path, f"structure mismatch: {reason}"))

        for rel_path in untracked_ledger_files(repo):
            origin_bytes = git_show_bytes(repo, f"origin/{branch}", rel_path)
            if origin_bytes is None:
                # Not part of origin's tree, so `git reset --hard` won't
                # touch it -- it isn't part of the collision this checker
                # exists to clear, leave it alone.
                continue
            try:
                local_bytes = (repo / rel_path).read_bytes()
            except OSError as exc:
                # Race with a concurrent process between the `git status`
                # snapshot above and this read (this checker's caller reruns
                # every 30 min, so the window is real, if rare). Surface it
                # as a named problem instead of an unhandled traceback that
                # the caller's `2>/dev/null` would silently swallow into an
                # empty, unexplained "not safe" verdict.
                problems.append((rel_path, f"could not read: {exc}"))
                continue
            if local_bytes != origin_bytes:
                problems.append((
                    rel_path,
                    "untracked file differs byte-for-byte from origin's "
                    "committed version -- `git reset --hard` would silently "
                    "overwrite it",
                ))

    if problems:
        print(json.dumps({"safe": False, "problems": [
            {"file": f, "reason": r} for f, r in problems
        ]}, ensure_ascii=False))
        return 1

    print(json.dumps({"safe": True, "problems": []}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
