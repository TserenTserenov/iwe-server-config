#!/usr/bin/env bash
# WP-7 F105 (03.10, peer-session 2026-10-03-10-wp7-open-phases-actualize):
# the validation protocol needs 10 pilot-confirmed episodes before the
# signal-(c) downgrade decision, but nothing ever wrote pilot_confirmed —
# the pilot edited progress-detector-validation.jsonl by hand. `confirm`
# must write exactly one boolean into the right line and leave every other
# line untouched.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WATCHDOG="$ROOT_DIR/scripts/kimi-session-watchdog.sh"
TEST_ROOT=$(mktemp -d)
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

export IWE_ROOT="$TEST_ROOT"
export LOG_DIR="$TEST_ROOT/logs"
export STATE_DIR="$TEST_ROOT/watchdog-progress"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/progress-detector-validation.jsonl"
cat > "$LOG" <<'JSONL'
{"recorded_at":"2026-09-04T10:00:00Z","target":"claude-abc","pilot_confirmed":null,"signals":{"a":true}}
{"recorded_at":"2026-09-04T11:00:00Z","target":"kimi-xyz","pilot_confirmed":null,"signals":{"a":false}}
{"recorded_at":"2026-09-04T12:00:00Z","target":"claude-abc","pilot_confirmed":null,"signals":{"a":true}}
JSONL

echo "Case 1: confirm the oldest unconfirmed episode for claude-abc"
bash "$WATCHDOG" confirm claude-abc true
line1=$(sed -n '1p' "$LOG")
line3=$(sed -n '3p' "$LOG")
check "oldest claude-abc line gets pilot_confirmed:true" \
  "$(echo "$line1" | grep -c '"pilot_confirmed": *true')" "1"
check "second claude-abc line untouched (still null)" \
  "$(echo "$line3" | grep -c '"pilot_confirmed": *null')" "1"
check "kimi-xyz line untouched" \
  "$(sed -n '2p' "$LOG" | grep -c '"pilot_confirmed": *null')" "1"

echo "Case 2: confirm the remaining claude-abc episode as false"
bash "$WATCHDOG" confirm claude-abc false
check "second claude-abc line now false" \
  "$(sed -n '3p' "$LOG" | grep -c '"pilot_confirmed": *false')" "1"

echo "Case 3: no unconfirmed episode left for claude-abc → exit 1, log untouched"
before=$(cat "$LOG")
bash "$WATCHDOG" confirm claude-abc true
rc=$?
check "exit code is 1" "1" "$rc"
check "log content unchanged" "$before" "$(cat "$LOG")"

echo "Case 4: unknown target → exit 1, log untouched"
bash "$WATCHDOG" confirm never-seen true
check "unknown target exit code is 1" "1" "$?"

echo "Case 5: invalid value rejected before touching the file"
before=$(cat "$LOG")
bash "$WATCHDOG" confirm kimi-xyz maybe
rc=$?
check "invalid value exit code is 1" "1" "$rc"
check "log content unchanged after invalid value" "$before" "$(cat "$LOG")"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS"
  exit 0
else
  echo "FAIL ($FAILURES)"
  exit 1
fi
