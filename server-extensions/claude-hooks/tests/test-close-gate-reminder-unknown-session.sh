#!/bin/bash
# test-close-gate-reminder-unknown-session.sh — fail-loud on the SESSION_ID
# "unknown" bucket (WP-484, peer-session 2026-08-31-43-close-obligation-
# orphan-recovery, consensus with Codex, closing a High left open by session
# 2026-08-31-40's cold-context review).
#
# Bug: close-gate-reminder.sh (UserPromptSubmit) falls back SESSION_ID to
# the literal string "unknown" when BOTH the payload's .session_id and
# $CLAUDE_CODE_SESSION_ID are empty (or the resolved value fails the charset
# check). _arm_and_sentinel() used to arm an obligation under that fake id
# and tell the agent "Обязательство закрытия зафиксировано" -- a false claim,
# because protocol-stop-gate.sh resolves its OWN SESSION_ID independently and,
# with both sources empty there too, skips its entire obligation check
# silently (fail-open) -- the "unknown" obligation can never be found on Stop.
#
# Fix: _arm_and_sentinel() refuses to arm/sentinel when SESSION_ID=="unknown"
# and returns a loud additionalContext instead. Fail-VISIBLE, not fail-closed
# (no exit 2 -- this repo's UserPromptSubmit hooks never block the prompt
# itself, only PreToolUse hooks do).
#
# Run: bash .claude/hooks/tests/test-close-gate-reminder-unknown-session.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/close-gate-reminder.sh"
SENTINEL_DIR="/tmp/iwe-close-intent"
FAKE_ROOT=$(mktemp -d)
PASS=0
FAIL=0

# FAKE_ROOT has no DS-my-strategy/scripts/close_obligation.py -> _obligation_available
# is false for every case here, so the sentinel-file check below isolates
# exactly the bash-level fix (arm/sentinel gating), independent of the CLI.
cleanup() {
  rm -f "$SENTINEL_DIR/unknown.flag" "$SENTINEL_DIR/test-known-sid.flag" \
        "$SENTINEL_DIR/test-env-sid.flag"
  rm -rf "$FAKE_ROOT"
}
trap cleanup EXIT

run_hook() { # $1 = prompt, $2 = payload session_id ("" for absent), $3 = env CLAUDE_CODE_SESSION_ID ("" for unset)
  local prompt="$1" payload_sid="$2" env_sid="$3"
  local json
  json=$(python3 -c 'import json,sys; print(json.dumps({"prompt": sys.argv[1], "session_id": sys.argv[2]}))' \
    "$prompt" "$payload_sid")
  if [ -n "$env_sid" ]; then
    printf '%s' "$json" | CLAUDE_PROJECT_DIR="$FAKE_ROOT" CLAUDE_CODE_SESSION_ID="$env_sid" bash "$HOOK"
  else
    printf '%s' "$json" | CLAUDE_PROJECT_DIR="$FAKE_ROOT" env -u CLAUDE_CODE_SESSION_ID bash "$HOOK"
  fi
}

expect_contains() { # $1 = описание, $2 = needle, $3 = haystack
  if printf '%s' "$3" | grep -qF "$2"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $1 (не найдено: $2)"
    echo "  got: $3"
  fi
}

expect_not_contains() { # $1 = описание, $2 = needle, $3 = haystack
  if printf '%s' "$3" | grep -qF "$2"; then
    FAIL=$((FAIL+1))
    echo "FAIL: $1 (найдено запрещённое: $2)"
    echo "  got: $3"
  else
    PASS=$((PASS+1))
  fi
}

expect_file_absent() { # $1 = описание, $2 = path
  if [ -f "$2" ]; then
    FAIL=$((FAIL+1))
    echo "FAIL: $1 (файл существует: $2)"
  else
    PASS=$((PASS+1))
  fi
}

expect_file_present() { # $1 = описание, $2 = path
  if [ -f "$2" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $1 (файл отсутствует: $2)"
  fi
}

# === Baseline: payload session_id present -> normal arm behavior ===
rm -f "$SENTINEL_DIR/test-known-sid.flag"
OUT=$(run_hook "закрывай" "test-known-sid" "")
expect_not_contains "known payload sid: no unknown-bucket warning" "session_id не определён" "$OUT"
expect_file_present  "known payload sid: sentinel written" "$SENTINEL_DIR/test-known-sid.flag"

# === Baseline: payload empty, env fallback present -> normal arm behavior ===
rm -f "$SENTINEL_DIR/test-env-sid.flag"
OUT=$(run_hook "закрывай" "" "test-env-sid")
expect_not_contains "env fallback sid: no unknown-bucket warning" "session_id не определён" "$OUT"
expect_file_present  "env fallback sid: sentinel written" "$SENTINEL_DIR/test-env-sid.flag"

# === Bug scenario 1: both sources empty -> fail-loud, no arm, no sentinel ===
rm -f "$SENTINEL_DIR/unknown.flag"
OUT=$(run_hook "закрывай" "" "")
expect_contains     "both empty: fail-loud warning present" "session_id не определён" "$OUT"
expect_not_contains "both empty: no false зафиксировано claim" "Обязательство закрытия (Ф74б) зафиксировано" "$OUT"
expect_file_absent  "both empty: no unknown.flag sentinel" "$SENTINEL_DIR/unknown.flag"

# === Bug scenario 2: payload has invalid charset -> same unknown bucket, same fix ===
rm -f "$SENTINEL_DIR/unknown.flag"
OUT=$(run_hook "закрывай" "bad session id!" "")
expect_contains     "invalid charset: fail-loud warning present" "session_id не определён" "$OUT"
expect_not_contains "invalid charset: no false зафиксировано claim" "Обязательство закрытия (Ф74б) зафиксировано" "$OUT"
expect_file_absent  "invalid charset: no unknown.flag sentinel" "$SENTINEL_DIR/unknown.flag"

# === Broad trigger ("заливай") hits the same guard ===
rm -f "$SENTINEL_DIR/unknown.flag"
OUT=$(run_hook "заливай" "" "")
expect_contains     "broad trigger, both empty: fail-loud warning present" "session_id не определён" "$OUT"
expect_file_absent  "broad trigger, both empty: no unknown.flag sentinel" "$SENTINEL_DIR/unknown.flag"

echo ""
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
