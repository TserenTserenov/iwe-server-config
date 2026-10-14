#!/bin/bash
# test-ritual-pre-gate-warn-only.sh -- ritual-pre-gate.sh (PreToolUse,
# warn-only rollout, РП-484 Ф182, 13.10.2026). Never blocks; only checked
# by what it writes to stderr and its always-exit-0 contract.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$HOOK_DIR/ritual-pre-gate.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0
check() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $desc (ожидалось '$want', получено '$got')"; fi
}

# make_transcript <path> <ritual|absent>: 30 records with a prior tool_use,
# same nontriviality shape ritual_detect_status requires (>20 records AND
# an earlier assistant tool_use) -- otherwise "applies" stays false and the
# warn-only hook (which reuses that same threshold) never has anything to
# warn about, regardless of ritual_status.
make_transcript() {
  local path="$1" mode="$2"
  python3 - "$path" "$mode" <<'PY'
import json, sys
path, mode = sys.argv[1], sys.argv[2]
rows = [{"type": "user", "message": {"content": "сделай РП-999"}}]
if mode == "ritual":
    rows.append({"type": "assistant", "message": {"content": [{"type": "text", "text":
        "> **Роль пользователя:** x\n> **РП:** y\n> **Целевой переход состояния:** z"}]}})
while len(rows) < 25:
    rows.append({"type": "user", "message": {"content": "продолжай"}})
    rows.append({"type": "assistant", "message": {"content": [
        {"type": "text", "text": "работаю"},
        {"type": "tool_use", "id": "t%d" % len(rows), "name": "Read", "input": {}},
    ]}})
with open(path, "w", encoding="utf-8") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
}

run_hook() {  # run_hook <project> <transcript> <session> <tool> -> stdout; stderr $TMP_DIR/err.txt
  printf '{"session_id":"%s","transcript_path":"%s","tool_name":"%s"}' "$3" "$2" "$4" |
    CLAUDE_PROJECT_DIR="$1" bash "$HOOK" 2>"$TMP_DIR/err.txt"
}

# === absent ritual -> exit 0, no stdout, "WOULD BLOCK" warning in stderr ===
P1="$TMP_DIR/p1"; mkdir -p "$P1/.claude/state"
make_transcript "$P1/t.jsonl" absent
OUT=$(run_hook "$P1" "$P1/t.jsonl" sess-1 Write); RC=$?
check "absent: exit 0" 0 "$RC"
check "absent: no stdout (never blocks)" "" "$OUT"
check "absent: WOULD BLOCK logged to stderr" yes \
  "$(grep -q 'WOULD BLOCK' "$TMP_DIR/err.txt" && echo yes || echo no)"

# === ritual shown -> exit 0, no warning, OWN "confirmed" marker written ===
P2="$TMP_DIR/p2"; mkdir -p "$P2/.claude/state"
make_transcript "$P2/t.jsonl" ritual
: > "$TMP_DIR/err.txt"
OUT2=$(run_hook "$P2" "$P2/t.jsonl" sess-2 Write); RC2=$?
check "ritual shown: exit 0" 0 "$RC2"
check "ritual shown: no WOULD BLOCK warning" no \
  "$(grep -q 'WOULD BLOCK' "$TMP_DIR/err.txt" && echo yes || echo no)"
check "ritual shown: writes its own ritual-confirmed marker" yes \
  "$([ -f "$P2/.claude/state/ritual-confirmed-sess-2" ] && echo yes || echo no)"

# === already-confirmed session (own marker set) -> skipped, no warning ===
P3="$TMP_DIR/p3"; mkdir -p "$P3/.claude/state"
make_transcript "$P3/t.jsonl" absent
touch "$P3/.claude/state/ritual-confirmed-sess-3"
: > "$TMP_DIR/err.txt"
run_hook "$P3" "$P3/t.jsonl" sess-3 Write >/dev/null
check "already-confirmed session: no warning (skipped)" no \
  "$(grep -q 'WOULD BLOCK' "$TMP_DIR/err.txt" && echo yes || echo no)"

# === cold-review Critical #1 regression: ritual-shown-detector.sh's OWN
# marker (ritual-checked-*, written on ANY status incl. "absent") must NOT
# disarm this hook -- only ritual-confirmed-* (written by this hook itself)
# may skip it. ===
P5="$TMP_DIR/p5"; mkdir -p "$P5/.claude/state"
make_transcript "$P5/t.jsonl" absent
touch "$P5/.claude/state/ritual-checked-sess-5"
: > "$TMP_DIR/err.txt"
run_hook "$P5" "$P5/t.jsonl" sess-5 Write >/dev/null
check "ritual-checked marker (Stop hook's, absent status) does not disarm this gate" yes \
  "$(grep -q 'WOULD BLOCK' "$TMP_DIR/err.txt" && echo yes || echo no)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
