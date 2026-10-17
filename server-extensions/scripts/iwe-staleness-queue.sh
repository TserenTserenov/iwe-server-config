#!/usr/bin/env bash
# iwe-staleness-queue.sh — persistent cross-session record of repos whose
# checkout is known stale/diverged against origin (WP-561 Ф41, ArchGate
# 17.10.2026: tri-state admit/degrade/abstain response to staleness instead
# of "mark potentially-stale and forget", found live when DS-my-strategy sat
# 361+ commits behind without anyone noticing across many sessions).
#
# One file, one repo per row, upsert-or-clear semantics — survives across
# sessions so the debt is visible, unlike the per-session state pull-on-touch
# already keeps. Consumers (Day Open, a future dynamic day plan) read it as
# plain data; this script owns the only writer logic.
#
# Usage:
#   iwe-staleness-queue.sh upsert <repo> <commits_behind> <tier>   # tier: degrade|abstain
#   iwe-staleness-queue.sh clear  <repo>                           # repo caught up (tier: admit)
#   iwe-staleness-queue.sh list                                   # human-readable, one line per row
set -uo pipefail

QUEUE_FILE="${IWE_STALENESS_QUEUE_FILE:-$HOME/.claude/state/staleness-queue.tsv}"
mkdir -p "$(dirname "$QUEUE_FILE")"
touch "$QUEUE_FILE"

cmd="${1:-}"
case "$cmd" in
  upsert)
    repo="${2:?usage: upsert <repo> <commits_behind> <tier>}"
    behind="${3:?usage: upsert <repo> <commits_behind> <tier>}"
    tier="${4:?usage: upsert <repo> <commits_behind> <tier>}"
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    QUEUE_FILE="$QUEUE_FILE" repo="$repo" behind="$behind" tier="$tier" now="$now" python3 -c '
import os
path = os.environ["QUEUE_FILE"]
repo = os.environ["repo"]
behind = os.environ["behind"]
tier = os.environ["tier"]
now = os.environ["now"]
rows = []
found = False
with open(path) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        cols = line.split("\t")
        if cols[0] == repo:
            first_seen = cols[2] if len(cols) > 2 else now
            rows.append("\t".join([repo, now, first_seen, behind, tier]))
            found = True
        else:
            rows.append(line)
if not found:
    rows.append("\t".join([repo, now, now, behind, tier]))
with open(path, "w") as f:
    f.write("\n".join(rows) + "\n" if rows else "")
'
    ;;
  clear)
    repo="${2:?usage: clear <repo>}"
    QUEUE_FILE="$QUEUE_FILE" repo="$repo" python3 -c '
import os
path = os.environ["QUEUE_FILE"]
repo = os.environ["repo"]
rows = []
with open(path) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        if line.split("\t")[0] != repo:
            rows.append(line)
with open(path, "w") as f:
    f.write("\n".join(rows) + "\n" if rows else "")
'
    ;;
  list)
    [ -s "$QUEUE_FILE" ] || exit 0
    while IFS=$'\t' read -r repo last_seen first_seen behind tier; do
        [ -z "$repo" ] && continue
        printf '%s: отставание %s коммитов, с %s, уровень %s (последняя проверка %s)\n' \
            "$repo" "$behind" "$first_seen" "$tier" "$last_seen"
    done < "$QUEUE_FILE"
    ;;
  *)
    echo "usage: $0 {upsert <repo> <commits_behind> <tier>|clear <repo>|list}" >&2
    exit 2
    ;;
esac
