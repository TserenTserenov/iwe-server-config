#!/usr/bin/env bash
# wp-phase-gate-smoke.sh -- WP-561 Ф42 (peer-session 2026-10-19-24,
# Claude+Codex): the phase-consistency gate compares the card's real list of
# open phases (## ФN / ### ФN without a positive terminal marker, via
# wp-archive-closed-phases.py --json -- the same classifier the archiver
# uses, read-only) against the self-observation entry (ref == own WP)
# recorded in handoff_snapshot by the previous close. Four outcomes:
# MATCH, MISMATCH (symmetric diff), NO_BASELINE (no self-entry yet --
# expected on every card the day this ships, must not be a false alarm),
# PARSE_FAILED (self-entry exists but observed_open_phases key is missing).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="$ROOT/.claude/scripts/wp-sync-bundle.sh"
[ -f "$BUNDLE" ] || { echo "FAIL: $BUNDLE not found"; exit 1; }
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
GOV=DS-my-strategy
fails=0
assert_contains() { case "$1" in *"$2"*) echo "  ok   $3" ;; *) echo "  FAIL $3 (got '$1', expected to contain '$2')"; fails=$((fails+1)) ;; esac; }

WS="$SANDBOX/ws"
mkdir -p "$WS/$GOV/docs" "$WS/$GOV/archive/wp-contexts" "$WS/$GOV/inbox"
printf '| WP | P | Название | Статус |\n|---|---|---|---|\n| 9201 | P1 | **Fixture 9201** | 🔄 |\n' > "$WS/$GOV/docs/WP-REGISTRY.md"
touch "$WS/$GOV/archive/wp-contexts/.keep"

# card <snapshot-block-or-empty>
card() {
  mkdir -p "$WS/$GOV/inbox/WP-9201"
  {
    printf -- '---\nwp: 9201\ntitle: "Fixture WP-9201"\nstatus: in_progress\ncreated: 2026-10-01\n'
    [ -n "$1" ] && printf '%s' "$1"
    printf -- '---\n# WP-9201\n\n### Ф1 — открытая фаза, без маркера\n\nтело без чекбоксов и без якорей\n\n### Ф2 ✅ — закрытая фаза\n\nтело\n\n## Осталось\n\n**Что дальше:**\n- [ ] пункт\n'
  } > "$WS/$GOV/inbox/WP-9201/WP-9201.md"
}

run_bundle() {
  IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO="$GOV" WP_SYNC_GIT_TIMEOUT=5 bash "$BUNDLE" "$1" > "$SANDBOX/out.md" 2> "$SANDBOX/err.txt"
  echo $?
}
gate_line() { grep -A1 '^## Проверка согласованности фаз' "$SANDBOX/out.md" | tail -1; }

echo "scenario A: no self-entry at all -> NO_BASELINE, not a block, not a crash"
card ""
run_bundle WP-9201 > /dev/null
assert_contains "$(gate_line)" "NO_BASELINE" "no self-entry -> NO_BASELINE"
assert_contains "$(gate_line)" "WP-9201" "message names the WP"

echo "scenario B: self-entry present, exact current open set -> MATCH"
card $'handoff_snapshot:\n  - ref: WP-9201\n    observed_status: in_progress\n    observed_open_phases: [Ф1]\n'
run_bundle WP-9201 > /dev/null
assert_contains "$(gate_line)" "MATCH" "exact match of the single open phase (Ф1; Ф2 has a terminal marker)"

echo "scenario C: self-entry stale on BOTH sides (missing a real one, has a phantom one) -> MISMATCH names both"
card $'handoff_snapshot:\n  - ref: WP-9201\n    observed_status: in_progress\n    observed_open_phases: [Ф2, Ф9]\n'
run_bundle WP-9201 > /dev/null
assert_contains "$(gate_line)" "MISMATCH" "mismatch detected"
assert_contains "$(gate_line)" "Ф1" "newly-open Ф1 (missing from stale snapshot) is named"
assert_contains "$(gate_line)" "Ф9" "phantom Ф9 (in snapshot, not currently open) is named"

echo "scenario D: self-entry present but missing observed_open_phases key -> PARSE_FAILED (not silently empty, not a crash)"
card $'handoff_snapshot:\n  - ref: WP-9201\n    observed_status: in_progress\n'
run_bundle WP-9201 > /dev/null
assert_contains "$(gate_line)" "PARSE_FAILED" "malformed self-entry is a hard parse failure, not an empty-list MATCH"

echo "scenario E: self-entry with an explicit empty list -> MATCH only if nothing is currently open"
mkdir -p "$WS/$GOV/inbox/WP-9201"
printf -- '---\nwp: 9201\ntitle: "Fixture WP-9201"\nstatus: in_progress\ncreated: 2026-10-01\nhandoff_snapshot:\n  - ref: WP-9201\n    observed_status: closed\n    observed_open_phases: []\n---\n# WP-9201\n\n### Ф2 ✅ — закрытая фаза\n\nтело\n' \
  > "$WS/$GOV/inbox/WP-9201/WP-9201.md"
run_bundle WP-9201 > /dev/null
assert_contains "$(gate_line)" "MATCH" "empty snapshot matches a card with zero open phases"

if [ "$fails" -eq 0 ]; then
  echo "PASS: all scenarios"
  exit 0
else
  echo "FAIL: $fails scenario(s) failed"
  exit 1
fi
