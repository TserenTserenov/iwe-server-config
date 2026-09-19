#!/usr/bin/env python3
"""Check whether a just-applied Edit/Write/MultiEdit is actually on disk.

Used by write-path-post-verify.sh (WP-530 Ф45). Standalone file, not an
inline bash heredoc: old_string/new_string/content can contain arbitrary
bytes (quotes, newlines, shell metacharacters) that are not safe to round
-trip through bash variables, and a heredoc sharing stdin with a piped JSON
payload silently starves `json.load(sys.stdin)` (found live while testing
the first version of this hook: python3 - <<'EOF' consumes the heredoc as
its OWN source, leaving nothing on stdin for the JSON read).

Contract
--------
stdin  : the PostToolUse hook payload (JSON: hook_event_name, tool_name, tool_input)
argv[1]: path to write-path-manifest.yaml
argv[2]: governance repo name ({{GOV_REPO}} substitution)
stdout : one line —
  "SKIP <reason>"                — not our concern, hook should stay silent
  "OK <class_id>"                — edit verified present on disk
  "FAIL <class_id> <reason,...>" — edit missing or reverted, hook should alert
"""
import fnmatch
import json
import os
import sys


def match_manifest_class(manifest_path: str, target: str, gov: str) -> str | None:
    """Same flat two-level parser as write-path-lease-guard.sh (WP-530 Ф10) —
    kept identical on purpose so both hooks agree on what counts as protected."""
    cur_id = cur_mode = None
    with open(manifest_path, encoding="utf-8") as f:
        for raw in f:
            line = raw.split("#", 1)[0].rstrip()
            s = line.strip()
            if s.startswith("- id:"):
                cur_id, cur_mode = s.split(":", 1)[1].strip(), None
            elif s.startswith("mode:"):
                cur_mode = s.split(":", 1)[1].strip()
            elif s.startswith("- ") and not s.startswith("- id:"):
                pat = s[2:].strip().strip("\"'").replace("{{GOV_REPO}}", gov)
                if cur_id and cur_mode and pat and fnmatch.fnmatch(target, pat):
                    return cur_id
    return None


def verify(tool_name: str, tool_input: dict, disk: str) -> list[str]:
    """Return a list of problem codes; empty means the write looks intact.

    Edit/MultiEdit check new_string presence AND old_string absence rather
    than a bare substring match — a bare match false-positives whenever the
    replacement text already occurs elsewhere in the file (found by Kimi,
    peer-session 2026-09-17-11-wp530-peer-finish, turn 2). MultiEdit checks
    each edit independently, in list order, without simulating the full
    sequential application in memory — a deliberate simplification (pilot
    chose "simple check" over full replay at the Decision Gate of that
    session); it can miss the narrow case where one edit's new_string is
    reintroduced by a later edit, but that is a false negative on an
    already-advisory, non-blocking signal, not a false alarm.
    """
    problems: list[str] = []

    if tool_name == "Write":
        if disk != tool_input.get("content", ""):
            problems.append("write_content_mismatch")
        return problems

    edits = tool_input.get("edits") if tool_name == "MultiEdit" else [tool_input]
    for i, edit in enumerate(edits or []):
        old_s = edit.get("old_string", "")
        new_s = edit.get("new_string", "")
        tag = f"edit[{i}]_" if tool_name == "MultiEdit" else ""
        if new_s and new_s not in disk:
            problems.append(f"{tag}new_string_missing")
        # old_s not in new_s: an edit that extends old_string (e.g. "Ф44" ->
        # "Ф44/Ф45") legitimately leaves old_string physically present inside
        # new_string's own text — false positive found live on this exact
        # pattern (cold-context review, WP-530 Ф49 close pass) by reproducing
        # it against this file's own header comment ("Ф44/Ф45").
        if old_s and old_s != new_s and old_s not in new_s and old_s in disk:
            problems.append(f"{tag}old_string_still_present")
    return problems


def main() -> None:
    manifest_path, gov = sys.argv[1], sys.argv[2]

    try:
        payload = json.load(sys.stdin)
    except Exception:
        print("SKIP bad_json")
        return

    tool_name = payload.get("tool_name", "")
    tool_input = payload.get("tool_input") or {}
    file_path = tool_input.get("file_path", "")
    if not file_path or tool_name not in ("Write", "Edit", "MultiEdit"):
        print("SKIP unsupported_tool_or_no_path")
        return

    target = os.path.abspath(os.path.expanduser(file_path))
    class_id = match_manifest_class(manifest_path, target, gov)
    if class_id is None:
        print("SKIP not_in_manifest")
        return

    if not os.path.isfile(target):
        print(f"FAIL {class_id} file_missing_after_write")
        return

    try:
        with open(target, encoding="utf-8", errors="replace") as f:
            disk = f.read()
    except OSError as exc:
        print(f"SKIP read_error:{exc}")
        return

    problems = verify(tool_name, tool_input, disk)
    if problems:
        print(f"FAIL {class_id} " + ",".join(problems))
    else:
        print(f"OK {class_id}")


if __name__ == "__main__":
    main()
