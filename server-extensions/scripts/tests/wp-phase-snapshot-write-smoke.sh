#!/usr/bin/env bash
# wp-phase-snapshot-write-smoke.sh -- WP-561 Ф42 write side (peer-session
# 2026-10-19-24, Claude+Codex; cold review's High finding: a read-only gate
# with no writer never fires, every card stays NO_BASELINE forever). This
# script writes/updates the self-entry (ref == own WP) of handoff_snapshot
# that wp-sync-bundle.sh's phase_gate_check() reads.
set -uo pipefail
PY_FINDER="$(cd "$(dirname "$0")/.." && pwd)/lib/find-python3.sh"
PY="$("$PY_FINDER" --stdlib-only 2>/dev/null)"
[ -n "$PY" ] || { echo "FAIL: no python3 resolved"; exit 1; }
WRITER="$(cd "$(dirname "$0")/.." && pwd)/wp-phase-snapshot-write.py"
[ -f "$WRITER" ] || { echo "FAIL: $WRITER not found"; exit 1; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
GOV="$SANDBOX/DS-my-strategy"
fails=0
assert_contains() { case "$1" in *"$2"*) echo "  ok   $3" ;; *) echo "  FAIL $3 (got '$1', expected to contain '$2')"; fails=$((fails+1)) ;; esac; }
assert_eq() { if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails+1)); fi; }

card() {  # <open-phase-heading-lines> <extra-frontmatter-block-or-empty>
  mkdir -p "$GOV/inbox/WP-9302"
  {
    printf -- '---\nwp: 9302\nstatus: in_progress\n'
    [ -n "${2:-}" ] && printf '%s' "$2"
    printf -- '---\n# WP-9302\n\n%s' "$1"
  } > "$GOV/inbox/WP-9302/WP-9302.md"
}

run_writer() {
  IWE_WORKSPACE="$SANDBOX" IWE_GOVERNANCE_REPO="DS-my-strategy" "$PY" "$WRITER" "$@" > "$SANDBOX/out.txt" 2> "$SANDBOX/err.txt"
  echo $?
}

echo "scenario A: no handoff_snapshot block yet -> creates it with the self-entry, exit 0"
card $'### Ф1 — открыта\n\nтело\n'
rc=$(run_writer 9302)
assert_eq "$rc" "0" "exit 0"
assert_contains "$(cat "$SANDBOX/out.txt")" "Ф1" "wrote the one real open phase"
assert_contains "$(cat "$GOV/inbox/WP-9302/WP-9302.md")" "observed_open_phases: [Ф1]" "frontmatter has the entry"
assert_contains "$(cat "$GOV/inbox/WP-9302/WP-9302.md")" "observed_source: sections" "legacy card (no phases: block) is read by headings"

echo "scenario B: existing depends_on entry for ANOTHER WP must survive untouched"
card $'### Ф1 — открыта\n\nтело\n' $'handoff_snapshot:\n  - ref: WP-123\n    observed_status: in_progress\n    observed_phase_digest: abc123\n'
run_writer 9302 > /dev/null
assert_contains "$(cat "$GOV/inbox/WP-9302/WP-9302.md")" "observed_phase_digest: abc123" "WP-123 depends_on entry preserved"
assert_contains "$(cat "$GOV/inbox/WP-9302/WP-9302.md")" "ref: WP-9302" "self-entry added alongside it"

echo "scenario C: running twice with no card change -> idempotent, says so, does not duplicate the entry"
run_writer 9302 > /dev/null
before=$(cat "$GOV/inbox/WP-9302/WP-9302.md")
rc=$(run_writer 9302)
after=$(cat "$GOV/inbox/WP-9302/WP-9302.md")
assert_eq "$rc" "0" "exit 0 on no-op"
assert_contains "$(cat "$SANDBOX/out.txt")" "already up to date" "stdout says already up to date"
assert_eq "$before" "$after" "card bytes unchanged on the no-op run"
assert_eq "$(grep -c '^  - ref: WP-9302$' "$GOV/inbox/WP-9302/WP-9302.md")" "1" "exactly one self-entry, not duplicated"

echo "scenario D: card phases change (Ф1 closed, Ф2 opens) -> entry updates IN PLACE, not appended"
card $'### Ф1 ✅ — закрыта\n\nтело\n\n### Ф2 — открыта\n\nтело\n' $'handoff_snapshot:\n  - ref: WP-9302\n    observed_status: in_progress\n    observed_open_phases: [Ф1]\n    recorded_at: "2026-01-01"\n'
run_writer 9302 > /dev/null
assert_contains "$(cat "$GOV/inbox/WP-9302/WP-9302.md")" "observed_open_phases: [Ф2]" "entry reflects the new open phase"
assert_eq "$(grep -c '^  - ref: WP-9302$' "$GOV/inbox/WP-9302/WP-9302.md")" "1" "still exactly one self-entry"

echo "scenario E: unknown WP -> exit 1, no file created"
rc=$(run_writer 9999)
assert_eq "$rc" "1" "exit 1 for a missing card"

echo "scenario F (WP-484 Ф299 п.4): a card WITH a phases: block -> open list comes from the records, sections only add diagnostics"
card $'### Ф1 — открыта\n\nтело\n\n### Ф2 — ждёт приёмки\n\nтело\n\n### Ф3 ✅ — закрыта\n\nтело\n\n### Ф5 — раздел без записи\n\nтело\n' $'phases:\n  Ф1: pending\n  Ф2: implemented-partial\n  Ф3: done\n  Ф4: waiting\n  Ф6: pending\n'
rc=$(run_writer 9302)
assert_eq "$rc" "0" "exit 0"
snap=$(cat "$GOV/inbox/WP-9302/WP-9302.md")
assert_contains "$snap" "observed_source: phases" "source is the phases: block"
assert_contains "$snap" "observed_open_phases: [Ф1, Ф2, Ф6]" "open = is_open records (Ф5 has no record, Ф4 is unknown, Ф3 closed)"
assert_contains "$snap" "observed_unaccounted: [Ф5]" "section without a record is named, not counted as open"
assert_contains "$snap" "open_without_section: [Ф6]" "open record without a section is named"
assert_contains "$snap" "observed_unknown_status: [Ф4]" "unknown status is recorded apart"
assert_contains "$(cat "$SANDBOX/err.txt")" "Ф4" "unknown status is warned about, not a refusal"

echo "scenario G: the same card run twice -> still idempotent with the new keys"
before=$(cat "$GOV/inbox/WP-9302/WP-9302.md")
rc=$(run_writer 9302)
assert_eq "$rc" "0" "exit 0 on no-op"
assert_contains "$(cat "$SANDBOX/out.txt")" "already up to date" "says already up to date"
assert_eq "$before" "$(cat "$GOV/inbox/WP-9302/WP-9302.md")" "bytes unchanged"

echo "scenario H: a closed record without a section raises no diagnostic"
card $'### Ф1 — открыта\n\nтело\n' $'phases:\n  Ф1: pending\n  Ф7: completed\n'
run_writer 9302 > /dev/null
snap=$(cat "$GOV/inbox/WP-9302/WP-9302.md")
assert_contains "$snap" "observed_open_phases: [Ф1]" "only the open record"
case "$snap" in *open_without_section*|*observed_unaccounted*) echo "  FAIL archived closed record must not be a diagnostic"; fails=$((fails+1)) ;; *) echo "  ok   no diagnostic for a closed record without a section" ;; esac

echo "scenario I: a phases: block of which nothing is readable -> snapshot by headings, with a warning (never 'no open phases')"
card $'### Ф1 — открыта\n\nтело\n' $'phases:\n  f1: in_progress\n  F2: pending\n'
rc=$(run_writer 9302)
assert_eq "$rc" "0" "exit 0"
snap=$(cat "$GOV/inbox/WP-9302/WP-9302.md")
assert_contains "$snap" "observed_source: sections" "source falls back to the headings"
assert_contains "$snap" "observed_open_phases: [Ф1]" "open phase found by heading"
assert_contains "$(cat "$SANDBOX/err.txt")" "ни одной записи не прочитано" "the unreadable block is warned about"

echo "scenario J: only the diagnostics change (open list is the same) -> the entry IS rewritten"
card $'### Ф1 — открыта\n\nтело\n' $'phases:\n  Ф1: pending\n'
run_writer 9302 > /dev/null
card $'### Ф1 — открыта\n\nтело\n\n### Ф2 — новый раздел без записи\n\nтело\n' $'phases:\n  Ф1: pending\n'
rc=$(run_writer 9302)
assert_eq "$rc" "0" "exit 0"
assert_contains "$(cat "$GOV/inbox/WP-9302/WP-9302.md")" "observed_unaccounted: [Ф2]" "new diagnostic recorded although the open list did not change"

echo "scenario K: deferred and cancelled are table words -> not open, and not reported as unknown"
card $'### Ф1 — открыта\n\nтело\n\n### Ф2 — отложена\n\nтело\n\n### Ф3 — отменена\n\nтело\n' $'phases:\n  Ф1: pending\n  Ф2: deferred\n  Ф3: cancelled\n  Ф4: defer\n'
rc=$(run_writer 9302)
assert_eq "$rc" "0" "exit 0"
snap=$(cat "$GOV/inbox/WP-9302/WP-9302.md")
assert_contains "$snap" "observed_open_phases: [Ф1]" "only the pending phase is open"
case "$snap$(cat "$SANDBOX/err.txt")" in *observed_unknown_status*|*"неизвестный статус"*) echo "  FAIL a table word was reported as unknown"; fails=$((fails+1)) ;; *) echo "  ok   no unknown-status report for table words" ;; esac

if [ "$fails" -eq 0 ]; then
  echo "PASS: all scenarios"
  exit 0
else
  echo "FAIL: $fails scenario(s) failed"
  exit 1
fi
