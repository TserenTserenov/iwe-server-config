#!/bin/bash
# test-ritual-shown-detector-gate.sh — однократный блокирующий гейт Ритуала
# согласования в Stop-хуке ritual-shown-detector.sh (РП-544 Д31, 13.10.2026).
#
# Что проверяется по наблюдаемому результату (stdout хука, файлы-маркеры,
# вызовы подменённого ledger-append.sh):
#   1. нетривиальная сессия без блока Ритуала → первый Stop возвращает
#      {"decision":"block"}, ставит маркер, пишет ritual_shown(absent) и
#      ritual_gate_enforced; второй Stop той же сессии не блокирует повторно
#      и не дублирует события;
#   2. сессия с показанным блоком Ритуала и паузой → никакого блока, маркер
#      гейта не ставится, в ledger ritual_shown(text_and_pause);
#   3. тривиальная сессия (≤20 записей) → ничего не пишется, не блокирует;
#   4. ledger-append.sh отсутствует → гейт всё равно срабатывает (поведение
#      не зависит от наблюдаемости), а пропуск события виден в stderr;
#   5. просроченный маркер гейта (>24ч) убирается той же уборкой, что и
#      маркер проверки.
#
# Хук запускается с CLAUDE_PROJECT_DIR во временной папке: реальные
# .claude/state и DS-my-strategy не затрагиваются.
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

# === 1. Ритуала нет: блок один раз, события по одному разу ===
P1="$TMP_DIR/absent"; make_project "$P1"
make_transcript "$P1/transcript.jsonl" absent 30
OUT1=$(run_hook "$P1" "$P1/transcript.jsonl" sess-absent)
check "absent: первый Stop блокирует" block "$(decision_of "$OUT1")"
check "absent: ответ хука — валидный JSON с reason" true \
  "$(printf '%s' "$OUT1" | jq -r '(.reason | length) > 0' 2>/dev/null)"
check "absent: маркер гейта поставлен" yes \
  "$([ -f "$P1/.claude/state/ritual-gate-enforced-sess-absent" ] && echo yes || echo no)"
check "absent: маркер проверки поставлен (ledger записан)" yes \
  "$([ -f "$P1/.claude/state/ritual-checked-sess-absent" ] && echo yes || echo no)"
OUT2=$(run_hook "$P1" "$P1/transcript.jsonl" sess-absent)
check "absent: второй Stop той же сессии не блокирует" pass "$(decision_of "$OUT2")"
check "absent: ledger — ritual_shown ровно один раз" 1 \
  "$(grep -c '^ritual_shown|ritual-shown-detector$' "$P1/ledger.calls")"
check "absent: ledger — ritual_gate_enforced ровно один раз" 1 \
  "$(grep -c '^ritual_gate_enforced|ritual-shown-detector$' "$P1/ledger.calls")"

# === 1б. тот же session_id, но маркер проверки потерян: гейт не повторяется ===
rm -f "$P1/.claude/state/ritual-checked-sess-absent"
OUT3=$(run_hook "$P1" "$P1/transcript.jsonl" sess-absent)
check "absent: без маркера проверки, но с маркером гейта — не блокирует" pass "$(decision_of "$OUT3")"
check "absent: событие гейта не задублировано" 1 \
  "$(grep -c '^ritual_gate_enforced|ritual-shown-detector$' "$P1/ledger.calls")"

# === 2. Ритуал показан с паузой: без блока ===
P2="$TMP_DIR/ritual"; make_project "$P2"
make_transcript "$P2/transcript.jsonl" ritual 30
OUT4=$(run_hook "$P2" "$P2/transcript.jsonl" sess-ritual)
check "ritual: не блокирует" pass "$(decision_of "$OUT4")"
check "ritual: маркер гейта не ставится" no \
  "$([ -f "$P2/.claude/state/ritual-gate-enforced-sess-ritual" ] && echo yes || echo no)"
check "ritual: ledger — только ritual_shown" "ritual_shown|ritual-shown-detector" \
  "$(cat "$P2/ledger.calls")"

# === 3. тривиальная сессия: ничего не пишется ===
P3="$TMP_DIR/trivial"; make_project "$P3"
make_transcript "$P3/transcript.jsonl" absent 10
OUT5=$(run_hook "$P3" "$P3/transcript.jsonl" sess-trivial)
check "trivial: не блокирует" pass "$(decision_of "$OUT5")"
check "trivial: ledger не трогается" no "$([ -e "$P3/ledger.calls" ] && echo yes || echo no)"
check "trivial: маркеров нет" 0 "$(find "$P3/.claude/state" -type f | wc -l | tr -d ' ')"

# === 4. ledger недоступен: гейт срабатывает, пропуск события виден ===
P4="$TMP_DIR/noledger"; make_project "$P4" no-ledger
make_transcript "$P4/transcript.jsonl" absent 30
OUT6=$(run_hook "$P4" "$P4/transcript.jsonl" sess-noledger)
check "no-ledger: первый Stop блокирует" block "$(decision_of "$OUT6")"
check "no-ledger: пропуск ritual_gate_enforced назван в stderr" yes \
  "$(grep -q 'ritual_gate_enforced not logged' "$TMP_DIR/err.txt" && echo yes || echo no)"
OUT7=$(run_hook "$P4" "$P4/transcript.jsonl" sess-noledger)
check "no-ledger: второй Stop не блокирует" pass "$(decision_of "$OUT7")"

# === 5. просроченный маркер гейта убирается вместе с маркером проверки ===
P5="$TMP_DIR/cleanup"; make_project "$P5"
make_transcript "$P5/transcript.jsonl" ritual 30
touch -t "$(date -v-2d +%Y%m%d%H%M 2>/dev/null || date -d '2 days ago' +%Y%m%d%H%M)" \
  "$P5/.claude/state/ritual-gate-enforced-stale" "$P5/.claude/state/ritual-checked-stale"
run_hook "$P5" "$P5/transcript.jsonl" sess-cleanup >/dev/null
check "cleanup: старый маркер гейта удалён" no \
  "$([ -f "$P5/.claude/state/ritual-gate-enforced-stale" ] && echo yes || echo no)"
check "cleanup: старый маркер проверки удалён" no \
  "$([ -f "$P5/.claude/state/ritual-checked-stale" ] && echo yes || echo no)"
check "cleanup: свежий маркер проверки остался" yes \
  "$([ -f "$P5/.claude/state/ritual-checked-sess-cleanup" ] && echo yes || echo no)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
