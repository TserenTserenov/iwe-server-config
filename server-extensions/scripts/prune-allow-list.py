#!/usr/bin/env python3
"""Prune one-off entries from the permission allow list of a Claude Code settings file.

Every "always allow" click adds an exact copy of one command to `permissions.allow`. Such a
copy never matches again, and some of them hold a password or a session folder. This script
removes them and keeps general rules (those with a wildcard) and every non-Bash rule.

Removed:
  * a Bash rule without a wildcard (an exact one-off command);
  * a Bash rule that looks like it holds a secret;
  * a Bash rule tied to one session: a scratchpad or session folder, a dated session slug,
    a commit message, a database host, a quick-close run.

Usage:
  prune-allow-list.py FILE            show what would go (default, changes nothing)
  prune-allow-list.py FILE --apply    write FILE, keeping FILE.bak-before-prune-<date>
  prune-allow-list.py FILE --apply --add 'Read(~/IWE/memory/**)'   also add a rule (repeatable)

Entries are never printed in full when they look like a secret.
"""
import argparse
import datetime
import json
import re
import shutil
import sys

SECRET = re.compile(r"PGPASSWORD|passw|token|secret|api[_-]?key|bearer|sk-[A-Za-z0-9]", re.I)
SESSION = re.compile(
    r"/tmp/claude-\d+/"
    r"|scratchpad"
    r"|isolated-worktrees/claude-code-[0-9a-f]{6,}"
    r"|MC-sessions/\d{4}-\d{2}"
    r"|\b20\d\d-\d\d-\d\d-\d\d-"            # dated session slug
    r"|git commit -m"
    r"|psql -h"
    r"|process-runner\.py (?:next|start|status) quick-close"
)


def bash_body(entry):
    match = re.fullmatch(r"Bash\((.*)\)", entry, re.S)
    return match.group(1) if match else None


def reason(entry):
    """Why an allow entry should go, or None to keep it."""
    body = bash_body(entry)
    if body is None:
        return None
    if SECRET.search(entry):
        return "secret"
    if SESSION.search(entry):
        return "one session"
    if "*" not in body:
        return "one-off"
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--add", action="append", default=[], help="rule to add to allow (repeatable)")
    args = parser.parse_args()

    with open(args.file, encoding="utf-8") as fh:
        data = json.load(fh)
    allow = data.get("permissions", {}).get("allow", [])
    kept, dropped = [], {}
    for entry in allow:
        why = reason(entry)
        if why:
            dropped.setdefault(why, []).append(entry)
        else:
            kept.append(entry)
    for rule in args.add:
        if rule not in kept:
            kept.append(rule)

    print(f"{args.file}: {len(allow)} -> {len(kept)} rules")
    for why, items in dropped.items():
        print(f"  removed ({why}): {len(items)}")
    if not args.apply:
        print("dry run: nothing written (add --apply)")
        return 0
    stamp = datetime.date.today().isoformat()
    backup = f"{args.file}.bak-before-prune-{stamp}"
    shutil.copy2(args.file, backup)
    data.setdefault("permissions", {})["allow"] = kept
    with open(args.file, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print(f"written; backup: {backup}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
