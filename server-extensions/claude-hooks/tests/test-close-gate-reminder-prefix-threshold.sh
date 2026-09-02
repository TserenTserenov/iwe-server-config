#!/bin/bash
# test-close-gate-reminder-prefix-threshold.sh — close-intent sentinel must
# NOT arm when the close-trigger word is buried deep inside a long pasted
# text (WP-484, bug-2026-08-15-close-intent-sentinel-armed-by-quoted-text.md,
# пир-сессия 2026-09-02-36 с Kimi+Codex).
#
# Live repro 02.09 (twice, same day): a pilot forwards another session's
# report/log containing the word "закрывай" not as a command to THIS
# session -- the sentinel used to arm on the bare regex match anywhere in
# the prompt, regardless of position or context. Fix: measure the Unicode
# character length of the prompt BEFORE the first trigger match; a prefix
# longer than CLOSE_TRIGGER_PREFIX_THRESHOLD (600) is treated as pasted
# text, not a direct command, and the obligation is not armed.
#
# Boundary is strict ">": prefix_len == 600 still arms (a real command can
# legitimately have up to 600 chars of preamble); prefix_len == 601 does not.
#
# Multiline case (the actual bug Codex found in round 1 of the fix session):
# an awk `match($0, re)` without RS control only measures the prefix WITHIN
# the line containing the match, silently discarding all prior lines of a
# multi-line paste -- undercounting exactly the main repro scenario. The
# fix uses python3 (sys.stdin.buffer.read() over the whole payload) instead;
# this file's multiline test is the regression guard for that specific bug.
#
# Run: bash .claude/hooks/tests/test-close-gate-reminder-prefix-threshold.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/close-gate-reminder.sh"
SENTINEL_DIR="/tmp/iwe-close-intent"
FAKE_ROOT=$(mktemp -d)
PASS=0
FAIL=0

# FAKE_ROOT has no DS-my-strategy/scripts/close_obligation.py -> _obligation_available
# is false, isolating exactly the prefix-length gating decision (arm/no-arm),
# independent of the CLI.
cleanup() {
  rm -f "$SENTINEL_DIR"/prefix-test-*.flag
  rm -rf "$FAKE_ROOT"
}
trap cleanup EXIT

run_hook() { # $1 = prompt, $2 = session_id
  local prompt="$1" sid="$2"
  local json
  json=$(python3 -c 'import json,sys; print(json.dumps({"prompt": sys.argv[1], "session_id": sys.argv[2]}))' \
    "$prompt" "$sid")
  printf '%s' "$json" | CLAUDE_PROJECT_DIR="$FAKE_ROOT" env -u CLAUDE_CODE_SESSION_ID bash "$HOOK"
}

# $1 = char count, $2 = fill char (default 'а', Cyrillic)
prefix_of_len() {
  python3 -c 'import sys; print(sys.argv[2] * int(sys.argv[1]), end="")' "$1" "${2:-а}"
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

# === Baseline: short prompt, trigger at start -> armed ===
SID="prefix-test-short"
rm -f "$SENTINEL_DIR/$SID.flag"
run_hook "закрывай" "$SID" >/dev/null
expect_file_present "short prompt: sentinel armed" "$SENTINEL_DIR/$SID.flag"

# === Trigger at very start of a long tail (WP-520 "закрывай, рефлексия: ..." case) -> armed ===
SID="prefix-test-trigger-first"
rm -f "$SENTINEL_DIR/$SID.flag"
TAIL=$(prefix_of_len 2000 "x")
run_hook "закрывай, рефлексия: $TAIL" "$SID" >/dev/null
expect_file_present "trigger-first with long tail: sentinel armed (prefix is short, tail length irrelevant)" "$SENTINEL_DIR/$SID.flag"

# === Boundary: exactly 599 chars before trigger -> armed (599 not > 600) ===
SID="prefix-test-599"
rm -f "$SENTINEL_DIR/$SID.flag"
PREFIX=$(prefix_of_len 599)
run_hook "${PREFIX}закрывай" "$SID" >/dev/null
expect_file_present "prefix_len=599 exactly: sentinel armed" "$SENTINEL_DIR/$SID.flag"

# === Boundary: exactly 600 chars before trigger -> armed (600 not > 600) ===
SID="prefix-test-600"
rm -f "$SENTINEL_DIR/$SID.flag"
PREFIX=$(prefix_of_len 600)
run_hook "${PREFIX}закрывай" "$SID" >/dev/null
expect_file_present "prefix_len=600 exactly: sentinel armed (boundary is strict >)" "$SENTINEL_DIR/$SID.flag"

# === Boundary: exactly 601 chars before trigger -> NOT armed (601 > 600) ===
SID="prefix-test-601"
rm -f "$SENTINEL_DIR/$SID.flag"
PREFIX=$(prefix_of_len 601)
run_hook "${PREFIX}закрывай" "$SID" >/dev/null
expect_file_absent "prefix_len=601 exactly: sentinel NOT armed" "$SENTINEL_DIR/$SID.flag"

# === Long ASCII prefix (2000 chars) -> NOT armed ===
SID="prefix-test-ascii-long"
rm -f "$SENTINEL_DIR/$SID.flag"
PREFIX=$(prefix_of_len 2000 "x")
run_hook "${PREFIX} закрывай" "$SID" >/dev/null
expect_file_absent "long ASCII prefix (2000): sentinel NOT armed" "$SENTINEL_DIR/$SID.flag"

# === Multiline: prefix spread across many short lines totaling >600 chars,
# trigger on a later line -> NOT armed. Regression guard for the awk-only-
# counts-current-line bug found by Codex (round 1). ===
SID="prefix-test-multiline"
rm -f "$SENTINEL_DIR/$SID.flag"
MULTILINE_PREFIX=$(python3 -c 'print("лог чужой сессии строка номер\n" * 30, end="")')  # ~30*31 = ~930 chars, well over 600
run_hook "${MULTILINE_PREFIX}закрывай" "$SID" >/dev/null
expect_file_absent "multiline prefix >600 chars total, trigger on later line: sentinel NOT armed" "$SENTINEL_DIR/$SID.flag"

# === Multiline but short: total prefix under 600 despite multiple lines -> armed ===
SID="prefix-test-multiline-short"
rm -f "$SENTINEL_DIR/$SID.flag"
run_hook $'строка раз\nстрока два\nзакрывай' "$SID" >/dev/null
expect_file_present "multiline prefix under 600 chars: sentinel armed" "$SENTINEL_DIR/$SID.flag"

# === python3 unavailable -> falls back to old behavior (armed), not a hard failure ===
SID="prefix-test-no-python3"
rm -f "$SENTINEL_DIR/$SID.flag"
NO_PY_DIR=$(mktemp -d)
for tool in bash grep sed jq tr cut cat mktemp date rm mkdir printf env; do
  p=$(command -v "$tool" 2>/dev/null) && ln -sf "$p" "$NO_PY_DIR/$tool"
done
PREFIX=$(prefix_of_len 2000 "x")
JSON=$(python3 -c 'import json,sys; print(json.dumps({"prompt": sys.argv[1], "session_id": sys.argv[2]}))' \
  "${PREFIX} закрывай" "$SID")
printf '%s' "$JSON" | PATH="$NO_PY_DIR" CLAUDE_PROJECT_DIR="$FAKE_ROOT" env -u CLAUDE_CODE_SESSION_ID bash "$HOOK" >/dev/null
rm -rf "$NO_PY_DIR"
expect_file_present "python3 unavailable: falls back to old behavior (armed)" "$SENTINEL_DIR/$SID.flag"

echo ""
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
