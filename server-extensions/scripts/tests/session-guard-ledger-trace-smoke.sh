#!/usr/bin/env bash
# WP-484 F290: session-guard's ledger writes leave a trace and retry only when
# the retry is deduplicated.
#   1. A write that fails once with a dedup flag is retried and lands once.
#   2. Without a dedup flag a failed write is not retried; the miss is logged.
#   3. A write that fails twice logs RETRY and LEDGER_MISS and still returns 0.
#   4. The real ledger-append with --dedup-by-event-key keeps one session_opened
#      when the same event (with session_id) is appended twice.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$ROOT/scripts/session-guard.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

check() {  # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 -- expected '$2', got '$3'"
    FAILURES=$((FAILURES + 1))
  fi
}

# The function under test, extracted from the real script (no copy in the test).
sed -n -e '/^ledger_append_traced() {/,/^}/p' -e '/^_ledger_trace_line() {/,/^}/p' "$GUARD" > "$TMP/helper.sh"
check "helpers found in session-guard.sh" "2" "$(grep -c '^\(ledger_append_traced\|_ledger_trace_line\)() {' "$TMP/helper.sh")"

# A fake writer: records each call, fails while its failure budget lasts.
mkdir -p "$TMP/iwe/gov/scripts"
cat > "$TMP/iwe/gov/scripts/ledger-append.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CALLS"
left=$(cat "$FAKE_BUDGET")
if [ "$left" -gt 0 ]; then
  echo $((left - 1)) > "$FAKE_BUDGET"
  echo "ERROR: simulated failure after write" >&2
  exit 1
fi
echo "OK: event appended"
FAKE

run_helper() {  # <failures before success> <args...>
  local budget="$1"
  shift
  : > "$TMP/calls"
  echo "$budget" > "$TMP/budget"
  rm -rf "$TMP/iwe/gov/logs"
  # set -e as in session-guard.sh: the helper must return 0 there too.
  IWE_ROOT="$TMP/iwe" GOV_REPO=gov FAKE_CALLS="$TMP/calls" FAKE_BUDGET="$TMP/budget" \
    bash -euo pipefail -c '. "$1"; shift; ledger_append_traced "$@"; echo REACHED' _ "$TMP/helper.sh" "$@" \
    > "$TMP/stdout" 2> "$TMP/stderr"
}

echo "=== 1: one failure, dedup flag -> retried, lands ==="
run_helper 1 s1 session_opened yes day 2026-11-05 session_opened '{"session_id":"x"}' session-guard --dedup-by-event-key
check "returns 0" "0" "$?"
check "caller continues" "REACHED" "$(cat "$TMP/stdout")"
check "two calls" "2" "$(wc -l < "$TMP/calls" | tr -d ' ')"
check "RETRY logged" "1" "$(grep -c ' RETRY kind=session_opened rc=1 ' "$TMP/iwe/gov/logs/session-ledger-append.s1.err.log")"
check "no LEDGER_MISS" "0" "$(grep -c 'LEDGER_MISS' "$TMP/iwe/gov/logs/session-ledger-append.s1.err.log")"
check "no warning" "0" "$(grep -c 'не записан' "$TMP/stderr")"

echo "=== 2: one failure, no dedup flag -> not retried, miss logged ==="
run_helper 1 s2 session_closed_direct no day 2026-11-05 session_closed_direct '{}' session-guard
check "returns 0" "0" "$?"
check "one call" "1" "$(wc -l < "$TMP/calls" | tr -d ' ')"
check "LEDGER_MISS logged with the error" "1" \
  "$(grep -c 'LEDGER_MISS kind=session_closed_direct rc=1 err=ERROR: simulated failure after write' "$TMP/iwe/gov/logs/session-ledger-append.s2.err.log")"
check "warning names the log" "1" "$(grep -c 'session-ledger-append.s2.err.log' "$TMP/stderr")"

echo "=== 3: two failures with dedup flag -> RETRY + LEDGER_MISS, returns 0 ==="
run_helper 2 'odd/slug' session_closed yes day 2026-11-05 session_closed '{}' session-guard --dedup-session-closed
check "returns 0" "0" "$?"
check "two calls" "2" "$(wc -l < "$TMP/calls" | tr -d ' ')"
check "slug sanitized into one file name" "1" "$(ls "$TMP/iwe/gov/logs" | grep -c '^session-ledger-append.odd_slug.err.log$')"
check "RETRY then LEDGER_MISS" "RETRY LEDGER_MISS" \
  "$(awk '{print $2}' "$TMP/iwe/gov/logs/session-ledger-append.odd_slug.err.log" | tr '\n' ' ' | sed 's/ $//')"

echo "=== 3b: unwritable log under set -e -> caller still continues ==="
: > "$TMP/calls"; echo 2 > "$TMP/budget"; rm -rf "$TMP/iwe/gov/logs"; mkdir -p "$TMP/iwe/gov/logs/session-ledger-append.s3b.err.log"
IWE_ROOT="$TMP/iwe" GOV_REPO=gov FAKE_CALLS="$TMP/calls" FAKE_BUDGET="$TMP/budget" \
  bash -euo pipefail -c '. "$1"; shift; ledger_append_traced "$@"; echo REACHED' _ "$TMP/helper.sh" \
  s3b session_closed yes day 2026-11-05 session_closed '{}' session-guard --dedup-session-closed \
  > "$TMP/stdout" 2> "$TMP/stderr"
check "returns 0" "0" "$?"
check "caller continues after the helper" "REACHED" "$(cat "$TMP/stdout")"
check "warning still printed" "1" "$(grep -c 'ledger session_closed не записан' "$TMP/stderr")"
rm -rf "$TMP/iwe/gov/logs"

echo "=== 4: real ledger-append dedups a repeated session_opened ==="
GOV_SCRIPTS="${IWE_GOVERNANCE_SCRIPTS:-$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-my-strategy}/scripts}"
if [ -x "$GOV_SCRIPTS/ledger-append.sh" ]; then
  # shellcheck source=/dev/null
  . "$GOV_SCRIPTS/lib/ledger-path.sh"
  mkdir -p "$TMP/probe"
  ledger_probe_isolate "$TMP/probe"
  event='{"wp":"WP-484","slug":"probe","agent":"claude-code","task":"t","sync_gate_marker_present":false,"session_id":"probe-1"}'
  for _ in 1 2; do
    bash "$GOV_SCRIPTS/ledger-append.sh" day 2026-11-05 session_opened "$event" session-guard --dedup-by-event-key >/dev/null 2>&1
  done
  count=$(ledger_read_yaml day 2026-11-05 "$IWE_LEDGER_DIR" "$IWE_LEDGER_ARCHIVE_DIR" "$IWE_LEDGER_BUFFER_DIR" \
    | python3 -c 'import sys,yaml; d=yaml.safe_load(sys.stdin) or {}; print(sum(1 for e in d.get("events",[]) if e.get("kind")=="session_opened"))')
  check "one session_opened after two appends" "1" "$count"
else
  echo "  SKIP: $GOV_SCRIPTS/ledger-append.sh not found"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: session-guard-ledger-trace-smoke"
  exit 0
fi
echo "FAILURES: $FAILURES"
exit 1
