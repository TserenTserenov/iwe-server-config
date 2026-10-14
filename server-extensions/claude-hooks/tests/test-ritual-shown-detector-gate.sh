#!/bin/bash
# test-ritual-shown-detector-gate.sh -- pure-observer behavior of the Stop
# hook ritual-shown-detector.sh (РП-484 Ф182, 13.10.2026).
#
# РП-544 Д31 (13.10.2026) added a one-shot blocking gate to this hook for
# one day; the retroactive-ritual-gate peer-session the same date (Claude+
# Kimi+Codex, MC-sessions:2026-10/13/2026-10-13-19-retroactive-ritual-gate)
# diagnosed why that could not work -- Stop fires only after a turn's work
# is already streamed to the pilot, so a block there always arrives after
# the fact ("задним числом") by construction, not by bug. The blocking
# branch was removed the same day; this file used to assert that branch's
# behavior and now asserts its absence instead. The replacement mechanisms
# (warn-only pre-gate, narrow hard gate) have their own test files.
#
# What is checked, by observable result (hook stdout, marker files, calls
# to a substituted ledger-append.sh):
#   1. nontrivial session, no Ritual shown -> never blocks; ritual_shown
#      (absent) logged exactly once even across repeated Stop calls;
#   2. session with the Ritual block shown and a pause before the next
#      tool_use -> never blocks; ritual_shown(text_and_pause) logged;
#   3. trivial session (<=20 records) -> nothing written, never blocks;
#   4. ledger-append.sh missing -> hook still never blocks; the skipped
#      write is visible in stderr;
#   5. a stale "checked" marker (>24h) is swept the same way it always was.
#
# Hook runs with CLAUDE_PROJECT_DIR pointed at a temp dir: real
# .claude/state and DS-my-strategy are never touched.
#
# Запуск: bash .claude/hooks/tests/test-ritual-shown-detector-gate.sh

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$HOOK_DIR/ritual-shown-detector.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0

check() {  # check <desc> <expected> <actual>
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидалось '$want', получено '$got')"
  fi
}

# make_project <dir> [with-ledger]: workspace with optional fake ledger-append.sh
# that records "<kind>|<source>" per call into $FAKE_LEDGER_LOG.
make_project() {
  local root="$1" with_ledger="${2:-with-ledger}"
  mkdir -p "$root/.claude/state"
  if [ "$with_ledger" = "with-ledger" ]; then
    mkdir -p "$root/DS-my-strategy/scripts"
    cat > "$root/DS-my-strategy/scripts/ledger-append.sh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$3" "$5" >> "$FAKE_LEDGER_LOG"
SH
  fi
}

# make_transcript <path> <ritual|absent> <records>: JSONL with tool_use present.
# With "ritual", the first assistant turn carries the real Ritual blockquote
# signature and a user turn follows before the first tool_use (text_and_pause).
make_transcript() {
  local path="$1" mode="$2" records="$3"
  python3 - "$path" "$mode" "$records" <<'PY'
import json, sys
path, mode, records = sys.argv[1], sys.argv[2], int(sys.argv[3])
ritual = (
    "Ритуал согласования:\n"
    "> **Роль пользователя:** Разработчик\n"
    "> **РП:** РП-544 Д31\n"
    "> **Ставка:** H-001\n"
    "> **Целевой переход состояния:** {pipeline, blocked→running}\n"
    "Подтверди, пожалуйста."
)
rows = []
if mode == "ritual":
    rows.append({"type": "user", "message": {"content": "Сделай задачу"}})
    rows.append({"type": "assistant", "message": {"content": [{"type": "text", "text": ritual}]}})
    rows.append({"type": "user", "message": {"content": "Да, поехали"}})
while len(rows) < records:
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

# run_hook <project> <transcript> <session_id> -> stdout; stderr to $TMP_DIR/err.txt
run_hook() {
  local project="$1" transcript="$2" session="$3"
  printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$session" "$transcript" |
    CLAUDE_PROJECT_DIR="$project" FAKE_LEDGER_LOG="$project/ledger.calls" \
    env -u CLAUDE_CODE_SESSION_ID bash "$HOOK" 2>"$TMP_DIR/err.txt"
}

decision_of() {  # decision_of <hook stdout> -> block | pass
  if printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    echo block
  else
    echo pass
  fi
}

# === 1. Ритуала нет: никогда не блокирует, событие пишется один раз ===
P1="$TMP_DIR/absent"; make_project "$P1"
make_transcript "$P1/transcript.jsonl" absent 30
OUT1=$(run_hook "$P1" "$P1/transcript.jsonl" sess-absent)
check "absent: Stop не блокирует" pass "$(decision_of "$OUT1")"
check "absent: маркер проверки поставлен (ledger записан)" yes \
  "$([ -f "$P1/.claude/state/ritual-checked-sess-absent" ] && echo yes || echo no)"
OUT2=$(run_hook "$P1" "$P1/transcript.jsonl" sess-absent)
check "absent: второй Stop той же сессии тоже не блокирует" pass "$(decision_of "$OUT2")"
check "absent: ledger — ritual_shown ровно один раз (маркер проверки не даёт повторной записи)" 1 \
  "$(grep -c '^ritual_shown|ritual-shown-detector$' "$P1/ledger.calls")"

# === 2. Ритуал показан с паузой: не блокирует, ledger — только ritual_shown ===
P2="$TMP_DIR/ritual"; make_project "$P2"
make_transcript "$P2/transcript.jsonl" ritual 30
OUT4=$(run_hook "$P2" "$P2/transcript.jsonl" sess-ritual)
check "ritual: не блокирует" pass "$(decision_of "$OUT4")"
check "ritual: ledger — только ritual_shown" "ritual_shown|ritual-shown-detector" \
  "$(cat "$P2/ledger.calls")"

# === 3. тривиальная сессия: ничего не пишется, не блокирует ===
P3="$TMP_DIR/trivial"; make_project "$P3"
make_transcript "$P3/transcript.jsonl" absent 10
OUT5=$(run_hook "$P3" "$P3/transcript.jsonl" sess-trivial)
check "trivial: не блокирует" pass "$(decision_of "$OUT5")"
check "trivial: ledger не трогается" no "$([ -e "$P3/ledger.calls" ] && echo yes || echo no)"
check "trivial: маркеров нет" 0 "$(find "$P3/.claude/state" -type f | wc -l | tr -d ' ')"

# === 4. ledger недоступен: не блокирует, пропуск события виден в stderr ===
P4="$TMP_DIR/noledger"; make_project "$P4" no-ledger
make_transcript "$P4/transcript.jsonl" absent 30
OUT6=$(run_hook "$P4" "$P4/transcript.jsonl" sess-noledger)
check "no-ledger: не блокирует" pass "$(decision_of "$OUT6")"
check "no-ledger: пропуск записи назван в stderr" yes \
  "$(grep -q 'ledger-append.sh not found' "$TMP_DIR/err.txt" && echo yes || echo no)"

# === 5. просроченный маркер проверки убирается уборкой ===
P5="$TMP_DIR/cleanup"; make_project "$P5"
make_transcript "$P5/transcript.jsonl" ritual 30
touch -t "$(date -v-2d +%Y%m%d%H%M 2>/dev/null || date -d '2 days ago' +%Y%m%d%H%M)" \
  "$P5/.claude/state/ritual-checked-stale"
run_hook "$P5" "$P5/transcript.jsonl" sess-cleanup >/dev/null
check "cleanup: старый маркер проверки удалён" no \
  "$([ -f "$P5/.claude/state/ritual-checked-stale" ] && echo yes || echo no)"
check "cleanup: свежий маркер проверки остался" yes \
  "$([ -f "$P5/.claude/state/ritual-checked-sess-cleanup" ] && echo yes || echo no)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
