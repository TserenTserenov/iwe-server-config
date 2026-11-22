#!/usr/bin/env bash
# WP-484 F323 (inbox I-27): on 19.11 one general pilot phrase released 15 marks of several
# agents through `close --pilot-release`, four of them live sessions. A pilot word now
# releases by itself only what the guard proves on its own: a mark of this very conversation
# or one whose owner is proven dead. A live or unprovable foreign mark is refused with code 3
# and a one-time code bound to that mark; it is released only when the pilot typed
# "снять <slug> <code>" in the calling conversation, read from that conversation's
# pilot-witness log (as for `heal`), never from a CLI argument. Every outcome is written to
# pilot-release-audit.jsonl.

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
WITNESS_DIR="$TEST_ROOT/.iwe-runtime/pilot-witness"
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

# A line of the pilot-witness log of one conversation, as the Claude hook writes it.
write_witness() {  # <conversation> <epoch offset seconds> <text>; WITNESS_TS=<ts> pins the stamp
  mkdir -p "$WITNESS_DIR"
  python3 - "$WITNESS_DIR/$1.jsonl" "$2" "$3" "${WITNESS_TS:-}" <<'PY'
import datetime as dt
import json
import sys

path, offset, text, pinned = sys.argv[1:]
stamp = pinned or (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=int(offset))).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "a", encoding="utf-8") as stream:
    stream.write(json.dumps({"ts": stamp, "session_id": "x", "text": text}, ensure_ascii=False) + "\n")
PY
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
code_in_refusal() { sed -n 's/^снять [^ ]* \([0-9]\{6\}\)$/\1/p' "$CLOSE_ERR" | head -1; }
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

# The caller conversation is a registered session of its own with a live owner, and the
# pilot already wrote something ordinary in it (a lone release line looks like a headless child).
open_sem convo-other caller-mark --owner-pid "$LIVE_PID"
write_witness convo-other -60 "разберись со всеми отметками"

echo "2. живую отметку чужого разговора общее слово не снимает"
open_sem convo-live live-mark --owner-pid "$LIVE_PID"
check "отказ с кодом 3" "$(close_sem convo-other live-mark --pilot-release "$WORD")" "3"
check "отметка осталась" "$(state_of live-mark)" "open"
check "отказ называет живого владельца" "$(seen 'владелец жив')" "yes"
check "отказ описывает отметку (слаг, задача)" "$(seen 'слаг live-mark, задача «fixture live-mark»')" "yes"
check "журнал: refused_alive, не применено" "$(last_owner)" "refused_alive False"
LIVE_CODE=$(code_in_refusal)
check "в отказе отдельная строка «снять live-mark <код>»" "$([ -n "$LIVE_CODE" ] && echo yes || echo no)" "yes"
check "код записан под именем именно этой отметки" "$([ -f "$(challenge_of live-mark)" ] && echo yes || echo no)" "yes"
check "код аргументом команды больше не принимается" "$(close_sem convo-other live-mark --pilot-release "$WORD" --pilot-release-code "$LIVE_CODE")" "1"
check "отметка осталась" "$(state_of live-mark)" "open"

echo "3. отметку без номера процесса (адаптеры Кими и Кодекса) общее слово не снимает"
open_sem convo-kimi unproven-mark
check "в записи нет pid" "$(grep -c '^pid: ' "$(sem_of unproven-mark)" || true)" "0"
check "отказ с кодом 3" "$(close_sem convo-other unproven-mark --pilot-release "$WORD")" "3"
check "отказ говорит, что завершение не доказано" "$(seen 'завершение владельца не доказано')" "yes"
check "журнал: refused_unproven" "$(last_owner)" "refused_unproven False"
UNPROVEN_CODE=$(code_in_refusal)

echo "4. реплика-вопрос, чужой код, чужая беседа или старая строка не снимают"
write_witness convo-other -5 "снять live-mark $LIVE_CODE?"
write_witness convo-other -5 "снять unproven-mark $LIVE_CODE"
write_witness convo-live -5 "снять live-mark $LIVE_CODE"
write_witness convo-other -10800 "снять live-mark $LIVE_CODE"
check "вопрос, чужой код, чужая беседа, просроченная строка: отказ" "$(close_sem convo-other live-mark --pilot-release "$WORD")" "3"
check "отказ называет непринятую реплику" "$(seen 'не принята: это вопрос')" "yes"
check "отметка осталась" "$(state_of live-mark)" "open"
check "повторный отказ даёт тот же код (строка пилота остаётся годной)" "$(code_in_refusal)" "$LIVE_CODE"

# WP-561 Ф82: the helper conversation needs no mark of its own and opens none; the agent
# never retypes the word (its --pilot-release text is ignored), the guard finds the word in
# the pilot's own replies, inside a sentence, several pairs per message.
nomark_sems() { grep -l '^harness_session_id: convo-nomark$' "$SESSIONS"/*.open 2>/dev/null | wc -l | tr -d ' '; }
write_witness convo-nomark -60 "обычная реплика"

echo "4а. беседа без своей отметки снимает по слову пилота внутри фразы; текст агента не учитывается"
open_sem convo-live3 nomark-target --owner-pid "$LIVE_PID"
check "первый вызов без текста: отказ с кодом" "$(close_sem convo-nomark nomark-target --pilot-release)" "3"
check "отказ не требует своей отметки" "$(seen 'своя отметка у этой беседы не нужна')" "yes"
NOMARK_CODE=$(code_in_refusal)
write_witness convo-nomark -5 "закрой, пожалуйста, отметку nomark-target, код $NOMARK_CODE"
check "снята по реплике пилота при неверном тексте агента" "$(close_sem convo-nomark nomark-target --pilot-release "снять nomark-target 000000")" "0"
check "журнал: слово — реплика пилота" "$(tail -1 "$AUDIT" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["word"])')" "закрой, пожалуйста, отметку nomark-target, код $NOMARK_CODE"
check "журнал: текст агента отдельно, не доказательство" "$(tail -1 "$AUDIT" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("agent_text_not_proof",""))')" "снять nomark-target 000000"
check "у помогающей беседы отметка не открыта" "$(nomark_sems)" "0"

echo "4б. две пары в одном сообщении снимают обе отметки"
open_sem convo-live4 pair-a --owner-pid "$LIVE_PID"
open_sem convo-live5 pair-b --owner-pid "$LIVE_PID"
close_sem convo-nomark pair-a --pilot-release >/dev/null; CODE_A=$(code_in_refusal)
close_sem convo-nomark pair-b --pilot-release >/dev/null; CODE_B=$(code_in_refusal)
write_witness convo-nomark -4 "закрой отметки pair-a и pair-b; коды $CODE_A и $CODE_B"
check "первая из двух снята" "$(close_sem convo-nomark pair-a --pilot-release)" "0"
check "вторая из двух снята" "$(close_sem convo-nomark pair-b --pilot-release)" "0"

echo "4в. неоднозначное сопоставление слагов и кодов — отказ с понятной причиной"
open_sem convo-live6 amb-a --owner-pid "$LIVE_PID"
open_sem convo-live7 amb-b --owner-pid "$LIVE_PID"
close_sem convo-nomark amb-a --pilot-release >/dev/null; CODE_AMB=$(code_in_refusal)
write_witness convo-nomark -3 "закрой amb-a и amb-b, код $CODE_AMB"
check "два слага и один код: отказ" "$(close_sem convo-nomark amb-a --pilot-release)" "3"
check "отказ называет неоднозначность" "$(seen 'не сопоставляются однозначно')" "yes"
check "отметка осталась" "$(state_of amb-a)" "open"

echo "4в1. пара слаг+код без явного глагола снятия или с просьбой подождать не снимает (WP-561 Ф82 ревью)"
open_sem convo-live8 verb-mark --owner-pid "$LIVE_PID"
close_sem convo-nomark verb-mark --pilot-release >/dev/null; VERB_CODE=$(code_in_refusal)
write_witness convo-nomark -1 "подожди с verb-mark $VERB_CODE"
check "«подожди с …»: отказ" "$(close_sem convo-nomark verb-mark --pilot-release)" "3"
check "отказ называет просьбу подождать" "$(seen 'не принята: в ней есть отрицание или просьба подождать')" "yes"
write_witness convo-nomark -1 "оставь verb-mark $VERB_CODE, позже"
check "«оставь …, позже»: отказ" "$(close_sem convo-nomark verb-mark --pilot-release)" "3"
write_witness convo-nomark -1 "verb-mark $VERB_CODE"
check "голая пара без глагола: отказ" "$(close_sem convo-nomark verb-mark --pilot-release)" "3"
check "отказ называет отсутствие глагола" "$(seen 'нет глагола снятия')" "yes"
write_witness convo-nomark -1 "Закрой. Про verb-mark $VERB_CODE потом поговорим"
check "глагол в другом предложении: отказ" "$(close_sem convo-nomark verb-mark --pilot-release)" "3"
write_witness convo-nomark -1 "сними потом verb-mark $VERB_CODE"
check "«сними потом …»: отказ" "$(close_sem convo-nomark verb-mark --pilot-release)" "3"
check "отметка осталась" "$(state_of verb-mark)" "open"
write_witness convo-nomark -1 "отпусти verb-mark $VERB_CODE"
check "«отпусти <слаг> <код>» снимает" "$(close_sem convo-nomark verb-mark --pilot-release)" "0"
open_sem convo-live8b verb-mark2 --owner-pid "$LIVE_PID"
close_sem convo-nomark verb-mark2 --pilot-release >/dev/null; VERB_CODE2=$(code_in_refusal)
write_witness convo-nomark -1 "закрывай verb-mark2 $VERB_CODE2"
check "«закрывай <слаг> <код>» снимает (привычное слово пилота)" "$(close_sem convo-nomark verb-mark2 --pilot-release)" "0"

echo "4г. без слова пилота беседа без отметки не снимает"
write_witness convo-fresh -60 "обычная реплика"
check "нет слова: отказ" "$(close_sem convo-fresh amb-b --pilot-release "снять amb-b 123456")" "3"
check "отметка осталась" "$(state_of amb-b)" "open"

echo "4д. дочерний разговор (слово — его единственная реплика) не снимает"
close_sem convo-fresh amb-b --pilot-release >/dev/null; CODE_AMB_B=$(code_in_refusal)
write_witness convo-child -2 "снять amb-b $CODE_AMB_B"
check "дочерний разговор: отказ" "$(close_sem convo-child amb-b --pilot-release)" "3"
check "отказ называет дочерний разговор" "$(seen 'так выглядит дочерний разговор')" "yes"
check "отметка осталась" "$(state_of amb-b)" "open"

echo "5. строка пилота в этой беседе снимает именно эту отметку, код удаляется вместе с ней"
write_witness convo-other -3 "снять live-mark $LIVE_CODE"
USED_CHALLENGES=("$(challenge_of live-mark)" "$(challenge_of unproven-mark)")
cat "$CLOSE_ERR" >&2; check "живая отметка снята по строке пилота" "$(close_sem convo-other live-mark --pilot-release "$WORD")" "0"
check "журнал: confirmed_alive" "$(last_owner)" "confirmed_alive True"
check "непроверяемая отметка не снимается строкой другой отметки" "$(close_sem convo-other unproven-mark --pilot-release "$WORD")" "3"
write_witness convo-other -2 "снять unproven-mark $UNPROVEN_CODE"
check "непроверяемая отметка снята своей строкой" "$(close_sem convo-other unproven-mark --pilot-release "$WORD")" "0"
check "журнал: confirmed_unproven" "$(last_owner)" "confirmed_unproven True"
check "использованные коды удалены вместе с отметками" "$(for f in "${USED_CHALLENGES[@]}"; do [ -e "$f" ] && echo kept; done | wc -l | tr -d ' ')" "0"

echo "6. процесс владельца завершён, но аренда действует (беседу могли возобновить): нужна строка пилота"
sleep 600 & DEAD_PID=$!
open_sem convo-dead dead-mark --owner-pid "$DEAD_PID"
kill "$DEAD_PID"; wait "$DEAD_PID" 2>/dev/null || true
check "отказ с кодом 3" "$(close_sem convo-other dead-mark --pilot-release "$WORD")" "3"
check "отказ называет действующую аренду" "$(seen 'аренда отметки ещё действует')" "yes"
check "журнал: refused_unproven" "$(last_owner)" "refused_unproven False"

echo "6а. процесс завершён и аренда истекла: общее слово снимает без строки пилота"
DEAD_CHALLENGE=$(challenge_of dead-mark)
check "код отказа шага 6 выдан" "$([ -f "$DEAD_CHALLENGE" ] && echo yes || echo no)" "yes"
check "отметка завершённого владельца снята" "$(IWE_SESSION_LEASE_SEC=0 close_sem convo-other dead-mark --pilot-release "$WORD")" "0"
check "журнал: owner=dead" "$(last_owner)" "dead True"
check "выданный ранее код удалён вместе с отметкой" "$([ -e "$DEAD_CHALLENGE" ] && echo kept || echo gone)" "gone"

echo "7. просроченный код заменяется новым, строка пилота со старым кодом не снимает"
open_sem convo-live2 expired-mark --owner-pid "$LIVE_PID"
close_sem convo-other expired-mark --pilot-release "$WORD" >/dev/null
EXPIRED_CODE=$(code_in_refusal)
python3 - "$(challenge_of expired-mark)" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    record = json.load(handle)
record["issued_at"] -= 3 * 3600
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle)
PY
# Both lines of steps 7 and 8 carry the same second: the later line of the log is the
# newer one (CI 22.11 failed when the older line with the expired code won the tie).
SAME_SECOND=$(date -u -v-1S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-1 second' +%Y-%m-%dT%H:%M:%SZ)
WITNESS_TS="$SAME_SECOND" write_witness convo-other -1 "снять expired-mark $EXPIRED_CODE"
check "строка с просроченным кодом не снимает" "$(close_sem convo-other expired-mark --pilot-release "$WORD")" "3"
NEW_CODE=$(code_in_refusal)
check "выдан новый код" "$([ -n "$NEW_CODE" ] && [ "$NEW_CODE" != "$EXPIRED_CODE" ] && echo yes || echo no)" "yes"
check "отметка осталась" "$(state_of expired-mark)" "open"

echo "8. вызывающий без своей идентичности беседы не может снять чужую живую отметку"
WITNESS_TS="$SAME_SECOND" write_witness convo-other -1 "снять expired-mark $NEW_CODE"
RC_NOID=0
env -u CLAUDE_CODE_SESSION_ID bash "$GUARD" close --wp WP-484 --slug expired-mark --agent fixture \
  --pilot-release "$WORD" >/dev/null 2>"$CLOSE_ERR" || RC_NOID=$?
check "без CLAUDE_CODE_SESSION_ID: отказ с кодом 3" "$RC_NOID" "3"
check "отказ объясняет, где снимать" "$(seen 'открыть обычное окно Claude')" "yes"
check "с идентичностью беседы та же строка снимает" "$(close_sem convo-other expired-mark --pilot-release "$WORD")" "0"

echo "9. беседа, чью сессию сняли извне, получает при повторном открытии того же slug подсказку нового (РП-561 Ф75)"
REOPEN_RC=0
CLAUDE_CODE_SESSION_ID=convo-live bash "$GUARD" open --wp WP-484 --task "fixture again" \
  --slug live-mark --agent fixture >/dev/null 2>"$CLOSE_ERR" || REOPEN_RC=$?
check "повторное открытие того же slug отклонено" "$([ "$REOPEN_RC" -ne 0 ] && echo refused || echo opened)" "refused"
check "отказ называет внешнее снятие и реплику пилота" "$(seen "снята извне по слову пилота «снять live-mark ${LIVE_CODE}»")" "yes"
check "отказ называет вызвавшую беседу" "$(seen 'вызвала беседа convo-other')" "yes"
check "отказ подсказывает новый slug" "$(seen '--slug live-mark-r2')" "yes"
CLAUDE_CODE_SESSION_ID=convo-live bash "$GUARD" open --wp WP-484 --task "fixture again" \
  --slug live-mark-r2 --agent fixture >/dev/null 2>&1 || true
check "сессия с подсказанным slug открылась" "$(state_of live-mark-r2)" "open"

echo
echo "session-guard-pilot-release-owner-smoke: прошло $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ]
