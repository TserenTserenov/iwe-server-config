#!/usr/bin/env bash
# WP-484, bug-2026-11-17-multiline-note-file-claim-blocks-product-receipt.md
#
# Fix 2: `note-file` with one path argument containing a newline glued several
#        paths into ONE claim that matches no changed file; once the close was
#        PREPARED the claim was frozen and the close could not be repaired.
#        The single-path form must refuse it, like the batch form already does.
# Fix 1: `close --pilot-release` in any state but "none" was read by nobody: no
#        audit line, no answer. It must be recorded (applied=false, the state it
#        was held in) and answered in plain words.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-multiline.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FAILURES=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    FAILURES=$((FAILURES + 1))
  fi
}

GOV="$TEST_ROOT/DS-strategy"
mkdir -p "$GOV/inbox/WP-999" "$GOV/docs"
printf '%s\n' 'hypothesis_relation: "tests"' > "$GOV/inbox/WP-999/WP-999.md"
git -C "$GOV" init -q
git -C "$GOV" config user.email test@test.local
git -C "$GOV" config user.name test
echo doc > "$GOV/docs/a.md"
echo doc > "$GOV/docs/b.md"
git -C "$GOV" add docs/a.md docs/b.md inbox/WP-999/WP-999.md
git -C "$GOV" commit -q -m seed

guard() {  # guard <subcommand> [args...]; runs from inside the governance checkout
  (cd "$GOV" && IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH="" \
    bash "$GUARD" "$@")
}

guard open --housekeeping multiline-test --agent fixture >/dev/null 2>&1
SEM=$(find "$TEST_ROOT/.iwe-runtime/sessions" -name 'fixture-*.open' | head -1)
[ -n "$SEM" ] || { echo "FAIL: fixture session did not open"; exit 1; }

# --- Fix 2: a newline inside one path is refused, nothing is claimed ------------
cp "$SEM" "$TEST_ROOT/sem.before"
OUT=$(guard note-file "$(printf 'docs/a.md\ndocs/b.md')" --agent fixture 2>&1); RC=$?
check "multiline path: refused" "1" "$RC"
check "multiline path: reason is named" "1" "$(printf '%s\n' "$OUT" | grep -c 'перевод строки в пути')"
check "multiline path: semaphore byte-identical" "same" "$(cmp -s "$TEST_ROOT/sem.before" "$SEM" && echo same || echo differ)"
OUT=$(guard note-file "$(printf 'docs/a.md\r')" --agent fixture 2>&1); RC=$?
check "path with carriage return: refused" "1" "$RC"

# A normal single path still works.
OUT=$(guard note-file docs/a.md --agent fixture 2>&1); RC=$?
check "single path: claimed" "0" "$RC"
check "single path: file line written" "1" "$(grep -cxF 'file: docs/a.md' "$SEM")"

# --- Fix 1: the pilot's word in a non-"none" close state is recorded and answered --
# Mark the semaphore as PREPARED the same way the guard does, by extracting its own
# functions (not copies) and driving them on the fixture session.
FIXTURE="$TEST_ROOT/fixture.sh"
: > "$FIXTURE"
extract_fn() {  # <function-name>
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { active = 1 }
    active {
      print
      if (!inpy && $0 ~ /<<.PY./) { inpy = 1; next }
      if (inpy && $0 == "PY") { inpy = 0; next }
      if (!inpy && $0 == "}") { active = 0; exit }
    }
  ' "$GUARD"
}
FNS="_unique_record_field _terminal_proof_snapshot_sha _owned_semaphore_snapshot_sha _append_close_fields_atomic _record_close_prepared _close_delivery_state"
for fn in $FNS; do
  extract_fn "$fn" >> "$FIXTURE"
  printf '\n' >> "$FIXTURE"
  grep -q "^${fn}() {" "$FIXTURE" \
    || { echo "FAIL: fixture setup -- ${fn}() not found in session-guard.sh"; exit 1; }
done
# shellcheck source=/dev/null
source "$FIXTURE"

REPO="$TEST_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
printf 'base' > "$REPO/f.txt"; git -C "$REPO" add f.txt; git -C "$REPO" commit -qm base
BASE=$(git -C "$REPO" rev-parse HEAD)
printf 'session' > "$REPO/f.txt"; git -C "$REPO" commit -qam session
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
TERMINAL_FILE="$TEST_ROOT/terminal.txt"; printf 'terminal-anchor\n' > "$TERMINAL_FILE"
TERMINAL_SHA=$(_terminal_proof_snapshot_sha file "$TERMINAL_FILE")
SESSION_ID_VALUE=$(grep '^session_id: ' "$SEM" | head -1 | cut -d' ' -f2-)
COMMITS_JSON=$(python3 -c 'import json,sys; print(json.dumps([sys.argv[1]]))' "$HEAD_SHA")
EMPTY_BLOB=$(git -C "$REPO" hash-object -t blob /dev/null)
_record_close_prepared "$SEM" "$SESSION_ID_VALUE" "$REPO" "$REPO/.git" "$BASE" "$HEAD_SHA" \
  "$EMPTY_BLOB" "$COMMITS_JSON" '[]' file "$TERMINAL_FILE" "$TERMINAL_SHA" \
  "https://example.invalid/repo.git" "refs/heads/main" >/dev/null \
  || { echo "FAIL: fixture setup -- could not mark the session PREPARED"; exit 1; }
check "setup: the fixture session reads as prepared" "prepared" "$(_close_delivery_state "$SEM" "$SESSION_ID_VALUE")"

AUDIT="$TEST_ROOT/.iwe-runtime/pilot-release-audit.jsonl"
rm -f "$AUDIT"
OUT=$(guard close --agent fixture --pilot-release "закрой, работа опубликована" 2>&1 || true)
check "prepared + pilot word: answer names the held state" "1" \
  "$(printf '%s\n' "$OUT" | grep -c 'слово пилота принято и записано в журнал, но закрытие держит доставка (состояние: prepared)')"
check "prepared + pilot word: one audit line" "1" "$(wc -l < "$AUDIT" 2>/dev/null | tr -d ' ')"
check "audit line: applied=false" "False" \
  "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["applied"])' "$AUDIT" 2>/dev/null)"
check "audit line: held_in_state=prepared" "prepared" \
  "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["held_in_state"])' "$AUDIT" 2>/dev/null)"
check "audit line: the word is kept verbatim" "закрой, работа опубликована" \
  "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["word"])' "$AUDIT" 2>/dev/null)"

# Without the flag nothing is written and no answer appears (no noise for ordinary closes).
rm -f "$AUDIT"
OUT=$(guard close --agent fixture 2>&1 || true)
check "prepared, no flag: no audit file" "absent" "$([ -e "$AUDIT" ] && echo present || echo absent)"
check "prepared, no flag: no pilot-word answer" "0" "$(printf '%s\n' "$OUT" | grep -c 'слово пилота принято')"

if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: multiline claim refused; pilot word in a held close state is audited and answered"
  exit 0
fi
echo "FAILURES: $FAILURES"
exit 1
