#!/usr/bin/env bash
# wp-session-journal-gaps.py used to print only os.path.basename(folder) for
# each row, dropping the <MONTH>/<DAY> prefix the caller needs to build the
# path to report.md. folder is always the full relative path in both data
# sources (scan_semaphores via resolve_peer_folders, scan_ledger via its own
# f"{month}/{day}/{slug}"); the bug was only in main()'s print. This test
# pins a case where the ledger event's timestamp (day 16) differs from the
# session folder's own date (day 15) -- exactly the case that made the old
# "reconstruct the path from opened_at" instruction in protocol-open.md
# wrong (WP-484 Ф194 доп.2, 2026-10-16).
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/scripts/wp-session-journal-gaps.py"
PY="$("$ROOT_DIR/scripts/lib/find-python3.sh" --stdlib-only)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wp-journal-gaps-smoke.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local label="$1" text="$2" needle="$3"
  case "$text" in
    *"$needle"*) ;;
    *) fail "$label — missing '$needle' in: $text" ;;
  esac
}

SESSIONS_DIR="$TEST_ROOT/MC-sessions"
LEDGER_DIR="$TEST_ROOT/ledger/day"
SESSION_FOLDER="2026-10/15/example-session"
mkdir -p "$SESSIONS_DIR/$SESSION_FOLDER"
touch "$SESSIONS_DIR/$SESSION_FOLDER/report.md"

LEDGER_DAY_DIR="$LEDGER_DIR/2026/10"
mkdir -p "$LEDGER_DAY_DIR"
cat > "$LEDGER_DAY_DIR/day-2026-10-16.yaml" <<'EOF'
events:
- ts: '2026-10-16T09:00:00Z'
  kind: session_closed_direct
  data:
    wp: WP-999
    slug: example-session
EOF

OUT="$("$PY" "$SCRIPT" --wp "WP-999" --sessions-dir "$SESSIONS_DIR" \
  --sem-dir "$TEST_ROOT/no-such-sem-dir" --ledger-dir "$LEDGER_DIR")"

assert_contains "full relative path in output" "$OUT" "$SESSION_FOLDER"
assert_contains "report status in output" "$OUT" "report.md есть"
case "$OUT" in
  *" example-session "*) fail "output still prints the bare basename, not the full path" ;;
esac

echo "PASS: wp-session-journal-gaps.py prints the full relative path, not a bare basename"
