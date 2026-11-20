#!/usr/bin/env bash
# WP-484 F323 (inbox I-27): on 19.11 one general pilot phrase released 15 marks of several
# agents through `close --pilot-release`, four of them live sessions. A pilot word now
# releases by itself only what the guard proves on its own: a mark of this very conversation
# or one whose owner is proven dead. A live or unprovable foreign mark is refused with code 3
# and a one-time code bound to that mark; it is released only by repeating the close with
# --pilot-release-code and that code. Every outcome is written to pilot-release-audit.jsonl.

set -euo pipefail
# The pilot close word of peer sessions is covered by test_pilot_close_word.py.
export IWE_PEER_CLOSE_WORD_ENFORCE=0

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="${SESSION_GUARD_UNDER_TEST:-$ROOT_DIR/scripts/session-guard.sh}"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-pilot-release-owner.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
LIVE_PID=""
trap '[ -z "$LIVE_PID" ] || kill "$LIVE_PID" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/DS-strategy"
ORIGIN="$TEST_ROOT/origin.git"
mkdir -p "$REPO/sessions" "$REPO/inbox/agent/tasks" "$REPO/scripts"
git init --bare -q "$ORIGIN"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "$ORIGIN"
printf '#!/usr/bin/env python3\nprint("{}")\n' > "$REPO/scripts/process-runner.py"
chmod +x "$REPO/scripts/process-runner.py"
git -C "$REPO" add scripts/process-runner.py
git -C "$REPO" commit -qm init
git -C "$REPO" push -q origin HEAD:main

export IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy" IWE_AGENT="fixture" IWE_FROZEN_CANONICAL_PATH=""
unset CLAUDE_PID OWNER_PID CODEX_THREAD_ID
SESSIONS="$TEST_ROOT/.iwe-runtime/sessions"
AUDIT="$TEST_ROOT/.iwe-runtime/pilot-release-audit.jsonl"
CHALLENGES="$TEST_ROOT/.iwe-runtime/pilot-release-challenges"
WORD="разберись со всеми семафорами"

PASS=0
FAIL=0
check() {  # <name> <got> <expected>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); echo "  ok: $1"
  else
    FAIL=$((FAIL + 1)); echo "  ПРОВАЛ: $1 (ожидал '$3', получил '$2')"
  fi
}

write_orz() {
  mkdir -p "$(dirname "$1")"
  printf -- '---\ndate: 2026-11-20\ntype: work\nwp: WP-484\nduration_h: 0.1\nartifacts: []\nagent: fixture\n---\n\n# Fixture\n\n## Главный инсайт\nf\n\n## Контекст\nf\n\n## Достигнуто\nf\n\n## Ключевые решения\nf\n' > "$1"
}

sem_of() { grep -l "^slug: $1\$" "$SESSIONS"/fixture-*.open 2>/dev/null || true; }

# open_sem <conversation> <slug> [extra open args...]: opens and publishes the ORZ file, so that
# delivery never decides these closes, only the owner check does.
open_sem() {
  local conversation="$1" slug="$2" semaphore orz
  shift 2
  CLAUDE_CODE_SESSION_ID="$conversation" bash "$GUARD" open --wp WP-484 --task "fixture $slug" \
    --slug "$slug" --agent fixture "$@" >/dev/null 2>&1
  semaphore=$(sem_of "$slug")
  orz=$(grep '^orz_file: ' "$semaphore" | cut -d' ' -f2-)
  write_orz "$REPO/sessions/$orz"
  git -C "$REPO" add "sessions/$orz"
  git -C "$REPO" commit -qm "orz $slug"
  git -C "$REPO" push -q origin HEAD:main
}

CLOSE_ERR="$TEST_ROOT/close.err"
close_sem() {  # <conversation> <slug> [extra close args...]; prints the exit code
  local conversation="$1" slug="$2" rc=0
  shift 2
  CLAUDE_CODE_SESSION_ID="$conversation" bash "$GUARD" close --wp WP-484 --slug "$slug" \
    --agent fixture "$@" >/dev/null 2>"$CLOSE_ERR" || rc=$?
  echo "$rc"
}

state_of() { [ -n "$(sem_of "$1")" ] && echo open || echo closed; }
last_owner() { tail -1 "$AUDIT" | python3 -c 'import json,sys; r=json.loads(sys.stdin.read()); print(r.get("owner",""), r.get("applied", True))'; }
code_in_refusal() { grep -o 'код [0-9]\{6\}' "$CLOSE_ERR" | head -1 | cut -d' ' -f2; }
seen() { grep -q -- "$1" "$CLOSE_ERR" && echo yes || echo no; }
sid_of() { sed -n 's/^session_id: //p' "$(sem_of "$1")" | head -1; }
challenge_of() { echo "$CHALLENGES/fixture-$(sid_of "$1").json"; }

sleep 600 &
LIVE_PID=$!

echo "1. отметку своего разговора общее слово снимает, как раньше, даже при живом владельце"
open_sem convo-own own-mark --owner-pid "$LIVE_PID"
check "своя отметка снята" "$(close_sem convo-own own-mark --pilot-release "$WORD")" "0"
check "журнал: owner=own" "$(last_owner)" "own True"
check "журнал называет точную отметку" "$(tail -1 "$AUDIT" | grep -c '"session_id":"[^"]')" "1"

echo "1а. напарник с унаследованным id беседы своим не считается"
open_sem convo-parent parent-mark --owner-pid "$LIVE_PID"
check "IWE_AGENT другого агента: отказ" "$(IWE_AGENT=kimi close_sem convo-parent parent-mark --pilot-release "$WORD")" "3"
check "CODEX_THREAD_ID при чужой отметке Claude: отказ" "$(CODEX_THREAD_ID=codex-thread-1 close_sem convo-parent parent-mark --pilot-release "$WORD")" "3"
check "отметка родителя осталась" "$(state_of parent-mark)" "open"

echo "2. живую отметку чужого разговора общее слово не снимает"
open_sem convo-live live-mark --owner-pid "$LIVE_PID"
check "отказ с кодом 3" "$(close_sem convo-other live-mark --pilot-release "$WORD")" "3"
check "отметка осталась" "$(state_of live-mark)" "open"
check "отказ называет живого владельца" "$(seen 'владелец жив')" "yes"
check "отказ описывает отметку (слаг, задача)" "$(seen 'слаг live-mark, задача «fixture live-mark»')" "yes"
check "журнал: refused_alive, не применено" "$(last_owner)" "refused_alive False"
LIVE_CODE=$(code_in_refusal)
check "в отказе выдан шестизначный код" "$([ -n "$LIVE_CODE" ] && echo yes || echo no)" "yes"
check "код записан под именем именно этой отметки" "$([ -f "$(challenge_of live-mark)" ] && echo yes || echo no)" "yes"

echo "3. отметку без номера процесса (адаптеры Кими и Кодекса) общее слово не снимает"
open_sem convo-kimi unproven-mark
check "в записи нет pid" "$(grep -c '^pid: ' "$(sem_of unproven-mark)" || true)" "0"
check "отказ с кодом 3" "$(close_sem convo-other unproven-mark --pilot-release "$WORD")" "3"
check "отказ говорит, что завершение не доказано" "$(seen 'завершение владельца не доказано')" "yes"
check "журнал: refused_unproven" "$(last_owner)" "refused_unproven False"
UNPROVEN_CODE=$(code_in_refusal)

echo "4. код одной отметки не подходит к другой, неверный код считается попыткой"
OTHER_CODE=$([ "$LIVE_CODE" = 111111 ] && echo 222222 || echo 111111)
check "чужой код не снимает" "$(close_sem convo-other unproven-mark --pilot-release "$WORD" --pilot-release-code "$LIVE_CODE")" "3"
check "отметка осталась" "$(state_of unproven-mark)" "open"
check "неверный код живой отметки не снимает" "$(close_sem convo-other live-mark --pilot-release "$WORD" --pilot-release-code "$OTHER_CODE")" "3"
check "отказ называет попытку" "$(seen 'попытка 1/3')" "yes"

echo "4а. повторная выдача заменяет код, три неверных попытки сжигают его"
close_sem convo-other parent-mark --pilot-release "$WORD" >/dev/null
FIRST_PARENT_CODE=$(code_in_refusal)
close_sem convo-other parent-mark --pilot-release "$WORD" >/dev/null
SECOND_PARENT_CODE=$(code_in_refusal)
if [ "$FIRST_PARENT_CODE" != "$SECOND_PARENT_CODE" ]; then
  check "прежний код после повторной выдачи не действует" "$(close_sem convo-other parent-mark --pilot-release "$WORD" --pilot-release-code "$FIRST_PARENT_CODE")" "3"
fi
WRONG=$([ "$SECOND_PARENT_CODE" = 000000 ] && echo 999999 || echo 000000)
close_sem convo-other parent-mark --pilot-release "$WORD" >/dev/null
THIRD_PARENT_CODE=$(code_in_refusal)
for _ in 1 2 3; do close_sem convo-other parent-mark --pilot-release "$WORD" --pilot-release-code "$WRONG" >/dev/null; done
check "после трёх неверных попыток код сожжён" "$([ -f "$(challenge_of parent-mark)" ] && echo kept || echo burnt)" "burnt"
check "сожжённый код не снимает" "$(close_sem convo-other parent-mark --pilot-release "$WORD" --pilot-release-code "$THIRD_PARENT_CODE")" "3"
check "отметка родителя по-прежнему открыта" "$(state_of parent-mark)" "open"

echo "5. верный код снимает именно эту отметку, использованный код удаляется вместе с ней"
check "живая отметка снята по коду пилота" "$(close_sem convo-other live-mark --pilot-release "$WORD" --pilot-release-code "$LIVE_CODE")" "0"
check "журнал: confirmed_alive" "$(last_owner)" "confirmed_alive True"
check "непроверяемая отметка снята своим кодом" "$(close_sem convo-other unproven-mark --pilot-release "$WORD" --pilot-release-code "$UNPROVEN_CODE")" "0"
check "журнал: confirmed_unproven" "$(last_owner)" "confirmed_unproven True"
check "использованные коды удалены" "$(find "$CHALLENGES" -type f | wc -l | tr -d ' ')" "0"

echo "6. процесс владельца завершён, но аренда действует (беседу могли возобновить): нужен код"
sleep 600 & DEAD_PID=$!
open_sem convo-dead dead-mark --owner-pid "$DEAD_PID"
kill "$DEAD_PID"; wait "$DEAD_PID" 2>/dev/null || true
check "отказ с кодом 3" "$(close_sem convo-other dead-mark --pilot-release "$WORD")" "3"
check "отказ называет действующую аренду" "$(seen 'аренда отметки ещё действует')" "yes"
check "журнал: refused_unproven" "$(last_owner)" "refused_unproven False"

echo "6а. процесс завершён и аренда истекла: общее слово снимает без кода"
DEAD_CHALLENGE=$(challenge_of dead-mark)
check "код отказа шага 6 выдан" "$([ -f "$DEAD_CHALLENGE" ] && echo yes || echo no)" "yes"
check "отметка завершённого владельца снята" "$(IWE_SESSION_LEASE_SEC=0 close_sem convo-other dead-mark --pilot-release "$WORD")" "0"
check "журнал: owner=dead" "$(last_owner)" "dead True"
check "выданный ранее код удалён вместе с отметкой" "$([ -e "$DEAD_CHALLENGE" ] && echo kept || echo gone)" "gone"

echo "7. просроченный код не принимается"
open_sem convo-live2 expired-mark --owner-pid "$LIVE_PID"
close_sem convo-other expired-mark --pilot-release "$WORD" >/dev/null
EXPIRED_CODE=$(code_in_refusal)
CHALLENGE=$(find "$CHALLENGES" -type f -name 'fixture-*.json' | head -1)
python3 - "$CHALLENGE" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    record = json.load(handle)
record["issued_at"] -= 3600
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle)
PY
check "просроченный код не снимает" "$(close_sem convo-other expired-mark --pilot-release "$WORD" --pilot-release-code "$EXPIRED_CODE")" "3"
check "отказ говорит, что код истёк" "$(seen 'код истёк')" "yes"
check "отметка осталась" "$(state_of expired-mark)" "open"

echo "8. код без слова пилота и код не того вида отклоняются, а не игнорируются"
check "--pilot-release-code без --pilot-release: код 1" "$(close_sem convo-other expired-mark --pilot-release-code 123456)" "1"
check "отказ называет причину" "$(seen 'применяется только вместе с close --pilot-release')" "yes"
check "пятизначный код: код 1" "$(close_sem convo-other expired-mark --pilot-release "$WORD" --pilot-release-code 12345)" "1"
check "отказ требует шестизначный код" "$(seen 'шестизначный код')" "yes"

echo
echo "session-guard-pilot-release-owner-smoke: прошло $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ]
