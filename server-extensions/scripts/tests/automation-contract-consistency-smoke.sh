#!/usr/bin/env bash
# Regression for WP-538 Ф5а: scripts/automation-contract.conf must not drift
# from what sync-strategy-files.sh actually syncs. canon-refresh.sh trusts
# the contract file to decide whether a mirrored tree is safe to advance
# without a commit — a contract that's narrower or wider than reality makes
# that decision wrong in either direction (round-4 design session, Kimi:
# "one source of truth, or the two copies drift apart silently").
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../lib/automation-contract.sh
. "$ROOT_DIR/scripts/lib/automation-contract.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Representative paths sync-strategy-files.sh's own grep patterns match
# (scripts/sync-strategy-files.sh lines ~93-104) — each must be allowed by
# the "sync-strategy-files" entry in automation-contract.conf.
POSITIVE_PATHS=(
  "inbox/WP-538.md"
  "inbox/WP-538/WP-538.md"
  "current/WeekPlan W35.md"
  "current/DayPlan-2026-09-03.md"
  "MEMORY.md"
)

for path in "${POSITIVE_PATHS[@]}"; do
  automation_contract_path_allowed sync-strategy-files "$path" \
    || fail "contract does not allow '$path', but sync-strategy-files.sh's own grep would sync it — contract has drifted narrower than reality"
done

# The '/'-boundary guard (WP-538 Ф5а: a '*' must not silently match across a
# path separator) is a property of the matcher, not of any specific glob —
# verify it directly rather than by asserting a real inbox path is rejected
# (the actual inbox convention, CLAUDE.md "один РП = одна папка", nests
# WP-{N}.md inside inbox/WP-{N}/, which is exactly why the contract carries
# both inbox/WP-*.md and inbox/WP-*/*.md — a deeper path than either glob
# expects must still be refused).
if automation_contract_path_allowed sync-strategy-files "inbox/WP-538/sub/dir/WP-538.md"; then
  fail "contract matcher let a '*' cross more than one path segment — the '/' boundary guard (WP-538 Ф5а) regressed"
fi

# Paths that must stay outside the contract — the point of the allowlist is
# that these can never be silently fast-forwarded through as a "known
# automation mirror".
NEGATIVE_PATHS=(
  "scripts/git-dirty-guard.sh"
  "scripts/canon-refresh.sh"
  "PACK-agent-rules/rules/AR.001.md"
  # sync-strategy-files.sh explicitly skips this one path (its own inline
  # `case "$FILE" in inbox/fleeting-notes.md) continue ;; esac`, separate
  # sync cadence via a different script) — the contract must not claim it.
  "inbox/fleeting-notes.md"
)

for path in "${NEGATIVE_PATHS[@]}"; do
  if automation_contract_path_allowed sync-strategy-files "$path"; then
    fail "contract allows '$path', which is not something sync-strategy-files.sh syncs — contract has drifted wider than reality"
  fi
done

echo "PASS: automation-contract-consistency-smoke.sh (${#POSITIVE_PATHS[@]} positive, 1 nested-path guard, ${#NEGATIVE_PATHS[@]} negative)"
