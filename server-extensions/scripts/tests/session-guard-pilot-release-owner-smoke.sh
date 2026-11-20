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
write_witness() {  # <conversation> <epoch offset seconds> <text>
  mkdir -p "$WITNESS_DIR"
  python3 - "$WITNESS_DIR/$1.jsonl" "$2" "$3" <<'PY'
import datetime as dt
import json
import sys

path, offset, text = sys.argv[1:]
stamp = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=int(offset))).strftime("%Y-%m-%dT%H:%M:%SZ")
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

echo "4. строка пилота не той формы, не той отметки, не в той беседе или старая не снимает"
write_witness convo-other -5 "пожалуйста снять live-mark $LIVE_CODE"
write_witness convo-other -5 "снять unproven-mark $LIVE_CODE"
write_witness convo-live -5 "снять live-mark $LIVE_CODE"
write_witness convo-other -10800 "снять live-mark $LIVE_CODE"
check "лишние слова, чужой код, чужая беседа, просроченная строка: отказ" "$(close_sem convo-other live-mark --pilot-release "$WORD")" "3"
check "отметка осталась" "$(state_of live-mark)" "open"
check "повторный отказ даёт тот же код (строка пилота остаётся годной)" "$(code_in_refusal)" "$LIVE_CODE"

echo "4а. беседа без своей живой отметки не снимает даже по верной строке"
write_witness convo-nomark -60 "обычная реплика"
write_witness convo-nomark -5 "снять live-mark $LIVE_CODE"
check "отказ с кодом 3" "$(close_sem convo-nomark live-mark --pilot-release "$WORD")" "3"
check "отказ называет причину" "$(seen 'нет своей живой отметки')" "yes"
check "отметка осталась" "$(state_of live-mark)" "open"

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
write_witness convo-other -1 "снять expired-mark $EXPIRED_CODE"
check "строка с просроченным кодом не снимает" "$(close_sem convo-other expired-mark --pilot-release "$WORD")" "3"
NEW_CODE=$(code_in_refusal)
check "выдан новый код" "$([ -n "$NEW_CODE" ] && [ "$NEW_CODE" != "$EXPIRED_CODE" ] && echo yes || echo no)" "yes"
check "отметка осталась" "$(state_of expired-mark)" "open"

echo "8. вызывающий без своей идентичности беседы не может снять чужую живую отметку"
write_witness convo-other -1 "снять expired-mark $NEW_CODE"
RC_NOID=0
env -u CLAUDE_CODE_SESSION_ID bash "$GUARD" close --wp WP-484 --slug expired-mark --agent fixture \
  --pilot-release "$WORD" >/dev/null 2>"$CLOSE_ERR" || RC_NOID=$?
check "без CLAUDE_CODE_SESSION_ID: отказ с кодом 3" "$RC_NOID" "3"
check "отказ объясняет, где снимать" "$(seen 'открыть обычное окно Claude')" "yes"
check "с идентичностью беседы та же строка снимает" "$(close_sem convo-other expired-mark --pilot-release "$WORD")" "0"

echo
echo "session-guard-pilot-release-owner-smoke: прошло $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ]
