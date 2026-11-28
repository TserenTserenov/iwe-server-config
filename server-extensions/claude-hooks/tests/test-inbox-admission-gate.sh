#!/bin/bash
# test-inbox-admission-gate.sh -- inbox-admission-gate.sh (PreToolUse, WP-561 Ф94
# part 2) and declare-intent.sh --inbox-deferred, on a fixture governance repo
# with a bare origin, a session working copy (worktree) and synthetic transcripts.
#
# Checked by observable result (deny JSON on stdout, the ids in its text, log
# lines, the stored record):
#   1. the pilot named the WP, 2 «новое» entries on the server -> another write
#      is denied and the text lists both ids; still denied after a tool result
#      became the latest "user" record of the transcript;
#   2. reads, the triage commands and edits of the card/INBOX.md are allowed;
#      calls outside the allowlist (writes, chains with a forbidden part) denied;
#   3. both entries marked in the session working copy -> allowed (one is not enough);
#   4. deferral with the pilot's own words + current fingerprint -> allowed;
#      words absent from the pilot's messages (only in assistant text, a tool
#      result or a task notification) -> denied; another conversation's record
#      -> denied; a third entry arriving on origin voids the deferral;
#   5. no inbox file on the server -> allowed; origin unreachable -> denied with
#      the read-error reason;
#   6. kill switch (file, env) and an internal failure (broken python) -> allowed
#      and logged; WP not named by the pilot, headless run -> gate silent;
#   7. declare-intent.sh --inbox-deferred: refusals, exit 4 without a record when
#      the server is unreachable, nothing to defer, kept for the same WP only.
#
# Everything lives in a temp dir: IWE_ROOT, IWE_RUNTIME_DIR, IWE_WORKSPACE point
# there; the real workspace, its sessions and the network are never touched.
#
# Run: bash .claude/hooks/tests/test-inbox-admission-gate.sh
# Stock macOS bash: TEST_BASH=/bin/bash /bin/bash .claude/hooks/tests/test-inbox-admission-gate.sh

set -uo pipefail
TEST_BASH="${TEST_BASH:-bash}"

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$HOOK_DIR/inbox-admission-gate.sh"
ROOT="$(cd "$HOOK_DIR/../.." && pwd)"
DECLARE="$ROOT/scripts/declare-intent.sh"
DECISION_MODULE="${TEST_INBOX_DECISION_MODULE:-${IWE_WORKSPACE:-$HOME/IWE}/DS-my-strategy/scripts/wp-inbox-decision.py}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0
check() {  # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $1 (ожидалось '$2', получено '$3')"
  fi
}

unset IWE_GOVERNANCE_REPO_PATH IWE_INBOX_ADMISSION_GATE IWE_INBOX_ADMISSION_PYTHON CLAUDE_PROJECT_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export IWE_ROOT="$TMP_DIR/iwe" IWE_RUNTIME_DIR="$TMP_DIR/iwe/.iwe-runtime"
export IWE_WORKSPACE="$TMP_DIR/iwe" IWE_GOVERNANCE_REPO="DS-gov"
export IWE_INBOX_ADMISSION_SERVER_TTL=0 CLAUDE_CODE_ENTRYPOINT=cli IWE_AGENT=claude-code
LOG="$IWE_RUNTIME_DIR/inbox-admission-gate.log"
SID="sess-1"

# --- fixture: origin, canonical checkout, session working copy, writer ---------
ORIGIN="$TMP_DIR/origin.git"
GOV="$IWE_WORKSPACE/DS-gov"
WT="$TMP_DIR/session-copy"
WRITER="$TMP_DIR/writer"
# declare-intent.sh gets a scripts dir with only the mailbox tool and the time
# limiter, so its handoff reader never runs against a real repository.
mkdir -p "$TMP_DIR/scripts/lib" "$IWE_ROOT/.iwe-runtime/sessions"
cp "$ROOT/scripts/wp-inbox.sh" "$TMP_DIR/scripts/wp-inbox.sh"
cp "$ROOT/scripts/lib/run-limited.sh" "$TMP_DIR/scripts/lib/run-limited.sh"

gitq() { git -c user.email=t@example.invalid -c user.name=fixture -c commit.gpgsign=false \
  -c core.hooksPath=/dev/null "$@"; }
inbox() { bash "$ROOT/scripts/wp-inbox.sh" "$@"; }

git init -q --bare -b main "$ORIGIN"
git init -q -b main "$GOV"
gitq -C "$GOV" remote add origin "$ORIGIN"
mkdir -p "$GOV/inbox/WP-77" "$GOV/inbox/WP-78" "$GOV/inbox/WP-79"
mkdir -p "$GOV/scripts"
cp "$DECISION_MODULE" "$GOV/scripts/wp-inbox-decision.py" || exit 1
for n in 77 78 79; do printf -- '---\nwp: %s\n---\n' "$n" > "$GOV/inbox/WP-$n/WP-$n.md"; done
inbox add --to WP-77 --from "РП-500" --pointer "MC-sessions/a.md" --summary "первая выжимка" --repo "$GOV" >/dev/null
inbox add --to WP-77 --from "РП-501" --pointer "MC-sessions/b.md" --summary "вторая выжимка" --repo "$GOV" >/dev/null
gitq -C "$GOV" add -A
gitq -C "$GOV" commit -q -m fixture
gitq -C "$GOV" push -q origin main 2>/dev/null || { echo "fixture: push failed"; exit 1; }
gitq -C "$GOV" fetch -q origin
gitq -C "$GOV" worktree add -q -b session "$WT" origin/main 2>/dev/null || { echo "fixture: worktree failed"; exit 1; }
git clone -q "$ORIGIN" "$WRITER" 2>/dev/null || { echo "fixture: writer clone failed"; exit 1; }
cat > "$IWE_ROOT/.iwe-runtime/sessions/claude-code-guard1.open" <<EOF
agent: claude-code
session_id: guard1
wp: WP-77
harness_session_id: $SID
governance_worktree: $WT
EOF

# --- transcripts ------------------------------------------------------------------
# write_transcript <path> <pilot text> [mode]: the pilot's message (origin human),
# then an assistant tool call and its tool result as the LAST "user" record.
# mode "spoof": the deferral words appear only outside the pilot's messages.
# mode "old-wp": the pilot named the WP earlier, his latest message names none.
# mode "meta-only": the WP is named only by a skill injection and a task notification.
write_transcript() {
  python3 - "$1" "$2" "${3:-plain}" <<'PY'
import json, sys
path, pilot, mode = sys.argv[1], sys.argv[2], sys.argv[3]
def human(text):
    return {"type": "user", "origin": {"kind": "human"}, "isSidechain": False,
            "message": {"role": "user", "content": [{"type": "text", "text": text}]}}
rows = []
if mode == "old-wp":
    rows.append(human("Работаем по РП-77"))
    rows.append({"type": "assistant", "message": {"content": [{"type": "text", "text": "ок"}]}})
rows.append(human(pilot))
if mode == "spoof":
    rows.append({"type": "assistant", "message": {"content": [
        {"type": "text", "text": "Предлагаю разбор ящика отложить."}]}})
    rows.append({"type": "user", "origin": {"kind": "task-notification"},
                 "message": {"role": "user", "content": "разбор ящика отложить"}})
if mode == "meta-only":
    rows.append({"type": "user", "isMeta": True,
                 "message": {"role": "user", "content": [{"type": "text", "text": "skill text WP-77"}]}})
    rows.append({"type": "user", "origin": {"kind": "task-notification"},
                 "message": {"role": "user", "content": "task done for РП-77"}})
rows.append({"type": "assistant", "message": {"content": [
    {"type": "tool_use", "id": "t1", "name": "Read", "input": {"file_path": "/x"}}]}})
rows.append({"type": "user", "message": {"role": "user", "content": [
    {"type": "tool_result", "tool_use_id": "t1", "content": "РП-77: разбор ящика отложить"}]}})
with open(path, "w", encoding="utf-8") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
}

T_NAMED="$TMP_DIR/t-named.jsonl";    write_transcript "$T_NAMED" "Работаем по РП-77, начинай"
T_DEFER="$TMP_DIR/t-defer.jsonl";    write_transcript "$T_DEFER" $'Работаем по РП-77.\nРазбор ящика отложить'
T_SPOOF="$TMP_DIR/t-spoof.jsonl";    write_transcript "$T_SPOOF" "Работаем по РП-77, начинай" spoof
T_OLD="$TMP_DIR/t-old.jsonl";        write_transcript "$T_OLD" "а теперь другое, без номера" old-wp
T_META="$TMP_DIR/t-meta.jsonl";      write_transcript "$T_META" "продолжай" meta-only
T_79="$TMP_DIR/t-79.jsonl";          write_transcript "$T_79" "Работаем по РП-79"
T_80="$TMP_DIR/t-80.jsonl";          write_transcript "$T_80" "Работаем по WP-80"

# --- hook driver ------------------------------------------------------------------
# hook <transcript> <tool> <tool_input JSON> [session] -> hook stdout
hook() {
  jq -nc --arg s "${4:-$SID}" --arg t "$1" --arg tool "$2" --argjson input "$3" --arg cwd "$ROOT" \
    '{session_id: $s, transcript_path: $t, tool_name: $tool, tool_input: $input, cwd: $cwd}' |
    "$TEST_BASH" "$HOOK" 2>>"$TMP_DIR/hook-stderr.log"
}
decision_of() {  # <hook stdout> -> deny | allow | broken
  if [ -z "$1" ]; then echo allow
  elif printf '%s' "$1" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then echo deny
  else echo broken
  fi
}
reason_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }
has() { printf '%s' "$1" | grep -qF -- "$2" && echo yes || echo no; }
write_input() { jq -nc --arg p "$1" '{file_path: $p, content: "x"}'; }
bash_input() { jq -nc --arg c "$1" '{command: $c}'; }
OTHER_FILE="$(write_input "$TMP_DIR/elsewhere/notes.md")"

# === 1. pilot named the WP, two «новое» entries on the server =====================
OUT=$(hook "$T_NAMED" Write "$OTHER_FILE")
check "2 новых записи: запись в другой файл отклонена" deny "$(decision_of "$OUT")"
R=$(reason_of "$OUT")
check "текст отказа называет И-1" yes "$(has "$R" "И-1: первая выжимка")"
check "текст отказа называет И-2" yes "$(has "$R" "И-2: вторая выжимка")"
check "текст отказа называет РП" yes "$(has "$R" "РП-77")"
check "текст отказа даёт выход 1 с копией сессии" yes "$(has "$R" "mark --wp 77 --id K --repo $WT")"
check "текст отказа даёт выход 2" yes "$(has "$R" "WP-77 --inbox-deferred")"
check "отказ записан в журнал" yes "$(grep -q 'event=deny session=sess-1 tool=Write wp=WP-77 basis=new_entries' "$LOG" && echo yes || echo no)"
check "Bash вне списка тоже отклонён" deny "$(decision_of "$(hook "$T_NAMED" Bash "$(bash_input 'git commit -m x')")")"
check "NotebookEdit отклонён" deny "$(decision_of "$(hook "$T_NAMED" NotebookEdit '{"notebook_path":"/tmp/n.ipynb"}')")"

# === 2. reads, the triage itself, card edits: allowed before admission ============
check "Read разрешён" allow "$(decision_of "$(hook "$T_NAMED" Read '{"file_path":"/x"}')")"
check "Grep разрешён" allow "$(decision_of "$(hook "$T_NAMED" Grep '{"pattern":"x"}')")"
for cmd in \
  "bash $ROOT/scripts/wp-inbox.sh mark --wp 77 --id 1 --repo $WT --by \"session=$SID; в Осталось\"" \
  "bash scripts/wp-inbox.sh list --wp 77 --rev origin/main" \
  "git -C $GOV fetch -q origin && bash $ROOT/scripts/wp-inbox.sh digest --wp 77 --repo $GOV --rev origin/main" \
  "IWE_GOVERNANCE_REPO_PATH=$WT bash scripts/declare-intent.sh WP-77 --inbox-deferred \"разбор отложить\"" \
  "bash $ROOT/scripts/session-guard.sh open --wp WP-77 --task x" \
  "bash scripts/session-guard.sh note-file inbox/WP-77/WP-77.md" \
  "bash .claude/scripts/wp-sync-bundle.sh 77 && bash scripts/wp-reopen-gate.sh actualize --wp 77" \
  "git -C $GOV --no-pager log --no-ext-diff --no-textconv --no-show-signature --oneline -5 | head -n 3; git -C $GOV --no-pager show --no-ext-diff --no-textconv --no-show-signature origin/main:inbox/WP-77/INBOX.md" \
  "git status --short && git --no-pager diff --no-ext-diff --no-textconv --stat && git rev-parse HEAD && git ls-tree HEAD && git cat-file -t HEAD" \
  "sed -n '1,40p' $GOV/inbox/WP-77/INBOX.md 2>/dev/null" \
  "grep -n \"a|b\" $GOV/inbox/WP-77/INBOX.md || true" \
  "cat $GOV/inbox/WP-77/WP-77.md; echo ---; ls -la $GOV/inbox; wc -l $GOV/inbox/WP-77/INBOX.md >/dev/null 2>&1" \
  "tail -n 5 $LOG | head -n 2"; do
  check "разрешено до допуска: $cmd" allow "$(decision_of "$(hook "$T_NAMED" Bash "$(bash_input "$cmd")")")"
done
for cmd in \
  "cat $GOV/inbox/WP-77/WP-77.md > /tmp/copy.md" \
  "echo x >> $GOV/inbox/WP-77/WP-77.md" \
  "git log --output=/tmp/log.txt" \
  "git log --outp=/tmp/log.txt" \
  "git show --textconv HEAD:notes.txt" \
  "git show --textc HEAD:notes.txt" \
  "git diff --ext-diff" \
  "git diff --ext-d" \
  "git cat-file --filters HEAD:notes.txt" \
  "git cat-file --filt HEAD:notes.txt" \
  "git log --show-signature" \
  "git diff" \
  "git --no-pager diff -- --no-ext-diff --no-textconv" \
  "git --no-pager diff --src-prefix --no-ext-diff --dst-prefix --no-textconv" \
  "git --no-pager diff --no-ext-diff --no-textconv --no-no-textconv" \
  "git -C --no-pager log --no-ext-diff --no-textconv --no-show-signature" \
  "git show HEAD" \
  "git log" \
  "bash $TMP_DIR/declare-intent.sh" \
  "$TMP_DIR/session-guard.sh open --wp WP-77" \
  "git -c core.pager=sh log" \
  "git fetch --upload-pack=/tmp/x origin" \
  "sed -i '' 's/a/b/' $GOV/inbox/WP-77/WP-77.md" \
  "sed -n '1p;w /tmp/x' $GOV/inbox/WP-77/WP-77.md" \
  "ls && rm -f /tmp/x" \
  "grep x f | xargs rm" \
  "echo \$(touch /tmp/x)" \
  "echo \`touch /tmp/x\`" \
  "bash scripts/wp-inbox.sh add --to WP-77 --from x --pointer p --summary s" \
  "bash scripts/session-guard.sh close --wp WP-77" \
  "bash -c 'touch /tmp/x'" \
  "X=--output=/tmp/x; git log \$X" \
  "PATH=/tmp/evil bash scripts/declare-intent.sh WP-77" \
  "./cat /etc/hosts" \
  "git log
touch /tmp/x" \
  "git log # comment
touch /tmp/x" \
  "(cd /tmp && ls)" \
  "cat <<EOF
x
EOF" \
  "python3 -c 'print(1)'"; do
  check "отклонено до допуска: $cmd" deny "$(decision_of "$(hook "$T_NAMED" Bash "$(bash_input "$cmd")")")"
done
COMMENT_COMMAND=$(python3 -c 'print("cat /dev/null # comment " + chr(92) + chr(10) + "touch /tmp/fixture-only")')
check "комментарий с переносом строки не считается разрешённым чтением" deny \
  "$(decision_of "$(hook "$T_NAMED" Bash "$(bash_input "$COMMENT_COMMAND")")")"
check "правка карточки РП разрешена" allow \
  "$(decision_of "$(hook "$T_NAMED" Edit "$(jq -nc --arg p "$WT/inbox/WP-77/WP-77.md" '{file_path: $p, old_string: "a", new_string: "b"}')")")"
check "запись в INBOX.md разрешена" allow "$(decision_of "$(hook "$T_NAMED" Write "$(write_input "$GOV/inbox/WP-77/INBOX.md")")")"
check "MultiEdit карточки разрешён" allow "$(decision_of "$(hook "$T_NAMED" MultiEdit "$(write_input "$WT/inbox/WP-77/WP-77.md")")")"
check "карточка другого РП отклонена" deny "$(decision_of "$(hook "$T_NAMED" Edit "$(write_input "$WT/inbox/WP-78/WP-78.md")")")"
check "файл рядом с карточкой отклонён" deny "$(decision_of "$(hook "$T_NAMED" Write "$(write_input "$WT/inbox/WP-77/notes.md")")")"

# === 3. entries marked in the session working copy ==================================
inbox mark --wp 77 --id 1 --by "session=$SID; в Осталось" --repo "$WT" >/dev/null
check "помечена одна из двух: всё ещё отклонено" deny "$(decision_of "$(hook "$T_NAMED" Write "$OTHER_FILE")")"
inbox mark --wp 77 --id 2 --by "session=$SID; учтено с согласия пилота" --repo "$WT" >/dev/null
check "обе помечены в копии сессии: разрешено" allow "$(decision_of "$(hook "$T_NAMED" Write "$OTHER_FILE")")"
python3 - "$WRITER/inbox/WP-77/INBOX.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().replace("первая выжимка", "изменённая выжимка"))
PY
gitq -C "$WRITER" add inbox/WP-77/INBOX.md
gitq -C "$WRITER" commit -q -m changed-entry
gitq -C "$WRITER" push -q origin main
export IWE_INBOX_ADMISSION_SERVER_TTL=300
check "тот же номер с новым текстом на сервере: старая пометка не допускает" deny \
  "$(decision_of "$(hook "$T_NAMED" Write "$OTHER_FILE")")"
export IWE_INBOX_ADMISSION_SERVER_TTL=0
gitq -C "$WRITER" checkout HEAD~1 -- inbox/WP-77/INBOX.md
gitq -C "$WRITER" commit -q -m restored-entry
gitq -C "$WRITER" push -q origin main
check "серверный текст снова совпадает с пометкой: разрешено" allow \
  "$(decision_of "$(hook "$T_NAMED" Write "$OTHER_FILE")")"
check "пометки другой беседы не засчитываются" deny "$(decision_of "$(hook "$T_NAMED" Write "$OTHER_FILE" sess-other)")"
gitq -C "$WT" checkout -q -- inbox/WP-77/INBOX.md
check "пометки сняты: снова отклонено" deny "$(decision_of "$(hook "$T_NAMED" Write "$OTHER_FILE")")"

# === 4. deferral by the pilot's own words ===========================================
declare_intent() {  # declare_intent <session> <args...>
  local session="$1"; shift
  CLAUDE_CODE_SESSION_ID="$session" IWE_SCRIPTS="$TMP_DIR/scripts" IWE_GOVERNANCE_REPO_PATH="$WT" \
    "$TEST_BASH" "$DECLARE" "$@"
}
REC="$IWE_RUNTIME_DIR/intent-declarations/$SID.json"
DOUT=$(declare_intent "$SID" WP-77 --inbox-deferred "«Разбор ящика отложить»" 2>&1)
check "отсрочка записана: код 0" 0 "$?"
check "отсрочка: отпечаток = digest сервера" "$(inbox digest --wp 77 --repo "$GOV" --rev origin/main)" \
  "$(jq -r '.inbox_deferral.fingerprint' "$REC")"
check "отсрочка: РП и беседа в записи" "WP-77 $SID" "$(jq -r '.inbox_deferral | "\(.wp) \(.session_id)"' "$REC")"
check "отсрочка: цитата в записи" "«Разбор ящика отложить»" "$(jq -r '.inbox_deferral.quote' "$REC")"
check "отсрочка: вывод подтверждает запись" yes "$(has "$DOUT" "Отсрочка разбора ящика WP-77 записана")"
check "слова пилота есть в его сообщении: разрешено" allow "$(decision_of "$(hook "$T_DEFER" Write "$OTHER_FILE")")"
OUT=$(hook "$T_SPOOF" Write "$OTHER_FILE")
check "слова только у агента, в результате инструмента и в уведомлении: отклонено" deny "$(decision_of "$OUT")"
check "отказ объясняет, что цитата не найдена" yes "$(has "$(reason_of "$OUT")" "не найдена в сообщениях пилота")"
check "слов нет в сообщениях пилота: отклонено" deny "$(decision_of "$(hook "$T_NAMED" Write "$OTHER_FILE")")"
jq '.inbox_deferral.quote = "РП-77"' "$REC" > "$TMP_DIR/rec.json" && mv "$TMP_DIR/rec.json" "$REC"
check "обычное упоминание РП не является решением отложить" deny "$(decision_of "$(hook "$T_NAMED" Write "$OTHER_FILE")")"
jq '.inbox_deferral.quote = "отлож"' "$REC" > "$TMP_DIR/rec.json" && mv "$TMP_DIR/rec.json" "$REC"
check "часть слова не считается цитатой" deny "$(decision_of "$(hook "$T_DEFER" Write "$OTHER_FILE")")"
declare_intent sess-2 WP-77 --inbox-deferred "разбор ящика отложить" >/dev/null 2>&1
cp "$IWE_RUNTIME_DIR/intent-declarations/sess-2.json" "$REC"
check "отсрочка другой беседы (её id внутри записи) не действует" deny "$(decision_of "$(hook "$T_DEFER" Write "$OTHER_FILE")")"
declare_intent "$SID" WP-77 --inbox-deferred "разбор ящика отложить" >/dev/null 2>&1
check "отсрочка заново: разрешено" allow "$(decision_of "$(hook "$T_DEFER" Write "$OTHER_FILE")")"
declare_intent "$SID" WP-77 >/dev/null 2>&1
check "повторное намерение по тому же РП сохраняет отсрочку" allow "$(decision_of "$(hook "$T_DEFER" Write "$OTHER_FILE")")"

# a third entry arrives on the server: the recorded fingerprint no longer matches
inbox add --to WP-77 --from "РП-502" --pointer "MC-sessions/c.md" --summary "третья выжимка" --repo "$WRITER" >/dev/null
gitq -C "$WRITER" add -A
gitq -C "$WRITER" commit -q -m third
gitq -C "$WRITER" push -q origin HEAD:main 2>/dev/null || echo "fixture: writer push failed"
OUT=$(hook "$T_DEFER" Write "$OTHER_FILE")
check "третья запись на сервере: отсрочка больше не действует" deny "$(decision_of "$OUT")"
R=$(reason_of "$OUT")
check "отказ называет новую И-3" yes "$(has "$R" "И-3: третья выжимка")"
check "отказ объясняет, почему отсрочка не действует" yes "$(has "$R" "прежнего состава ящика")"
declare_intent "$SID" WP-77 --inbox-deferred "разбор ящика отложить" >/dev/null 2>&1
check "прежние слова нельзя выдать за новое решение для нового ящика" deny \
  "$(decision_of "$(hook "$T_DEFER" Write "$OTHER_FILE")")"
python3 - "$T_DEFER" <<'PY'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as stream:
    stream.write(json.dumps({"type": "user", "origin": {"kind": "human"},
        "message": {"role": "user", "content": "РП-77\nРазбор ящика отложить"}}, ensure_ascii=False) + "\n")
PY
check "новое явное решение пилота допускает новый состав ящика" allow \
  "$(decision_of "$(hook "$T_DEFER" Write "$OTHER_FILE")")"

# === 5. no inbox file; server unreachable ===========================================
check "у РП нет ящика на сервере: разрешено" allow "$(decision_of "$(hook "$T_79" Write "$OTHER_FILE")")"
check "у РП нет даже папки: разрешено" allow "$(decision_of "$(hook "$T_80" Write "$OTHER_FILE")")"
gitq -C "$GOV" remote set-url origin "$TMP_DIR/no-such-origin.git"
OUT=$(hook "$T_DEFER" Write "$OTHER_FILE")
check "сервер недоступен: отклонено" deny "$(decision_of "$OUT")"
R=$(reason_of "$OUT")
check "отказ называет ошибку чтения" yes "$(has "$R" "ящик входящих на сервере не прочитан")"
check "отказ при ошибке чтения даёт оба выхода" yes "$( [ "$(has "$R" "Выход 1")$(has "$R" "Выход 2")" = yesyes ] && echo yes || echo no)"
check "сервер недоступен: даже при ящике без записей не допускает" deny "$(decision_of "$(hook "$T_79" Write "$OTHER_FILE")")"
check "ошибка чтения в журнале" yes "$(grep -q 'basis=read_error' "$LOG" && echo yes || echo no)"
gitq -C "$GOV" remote set-url origin "$ORIGIN"

# Parsed inbox is cached only for an immutable commit; every admission needs a fresh server head.
gitq -C "$WT" merge -q --ff-only origin/main
for id in 1 2 3; do inbox mark --wp 77 --id "$id" --by "session=$SID; x" --repo "$WT" >/dev/null; done
check "кэш: все три помечены, свежее чтение: разрешено" allow \
  "$(decision_of "$(IWE_INBOX_ADMISSION_SERVER_TTL=300 hook "$T_NAMED" Write "$OTHER_FILE")")"
gitq -C "$GOV" remote set-url origin "$TMP_DIR/no-such-origin.git"
check "кэш: сервер пропал, старый допуск не заменяет свежую проверку" deny \
  "$(decision_of "$(IWE_INBOX_ADMISSION_SERVER_TTL=300 hook "$T_NAMED" Write "$OTHER_FILE")")"
gitq -C "$WT" checkout -q -- inbox/WP-77/INBOX.md
OUT=$(IWE_INBOX_ADMISSION_SERVER_TTL=300 hook "$T_NAMED" Write "$OTHER_FILE")
check "кэш: отказ решается свежим чтением, а оно не удалось" yes \
  "$(has "$(reason_of "$OUT")" "ящик входящих на сервере не прочитан")"
gitq -C "$GOV" remote set-url origin "$ORIGIN"

# === 6. kill switch, internal failure, out of scope ==================================
touch "$IWE_RUNTIME_DIR/inbox-admission-gate-off"
check "выключатель-файл: разрешено" allow "$(decision_of "$(hook "$T_NAMED" Write "$OTHER_FILE")")"
check "выключатель-файл: запись в журнале" yes "$(grep -q 'event=kill_switch .*inbox-admission-gate-off' "$LOG" && echo yes || echo no)"
rm -f "$IWE_RUNTIME_DIR/inbox-admission-gate-off"
OUT=$(IWE_INBOX_ADMISSION_GATE=off hook "$T_NAMED" Write "$OTHER_FILE")
check "выключатель-переменная: разрешено" allow "$(decision_of "$OUT")"
check "выключатель-переменная: запись в журнале" yes "$(grep -q 'event=kill_switch .*allowed: IWE_INBOX_ADMISSION_GATE=off' "$LOG" && echo yes || echo no)"
OUT=$(IWE_INBOX_ADMISSION_PYTHON=/nonexistent/python3 hook "$T_NAMED" Write "$OTHER_FILE")
check "сбой самой проверки (нет python): разрешено" allow "$(decision_of "$OUT")"
check "сбой самой проверки: громкая строка в журнале" yes "$(grep -q 'event=internal_error session=sess-1 tool=Write allowed: prepare' "$LOG" && echo yes || echo no)"
check "сбой самой проверки: предупреждение в stderr" yes "$(grep -q 'ВНИМАНИЕ: сбой самой проверки' "$TMP_DIR/hook-stderr.log" && echo yes || echo no)"
check "пилот назвал РП раньше, последнее сообщение без номера: молчит" "" "$(hook "$T_OLD" Write "$OTHER_FILE")"
check "номер только в тексте навыка и уведомлении: молчит" "" "$(hook "$T_META" Write "$OTHER_FILE")"
check "безголовый запуск (sdk-cli): молчит" "" "$(CLAUDE_CODE_ENTRYPOINT=sdk-cli hook "$T_NAMED" Write "$OTHER_FILE")"

# === 7. declare-intent.sh --inbox-deferred refusals and edge cases ==================
declare_intent "$SID" outside-wp --inbox-deferred "x" >/dev/null 2>&1
check "--inbox-deferred с outside-wp отклонён" 1 "$?"
declare_intent "$SID" WP-77 --inbox-deferred "   " >/dev/null 2>&1
check "пустая цитата отклонена" 1 "$?"
declare_intent "$SID" WP-77 --inbox-deferred >/dev/null 2>&1
check "--inbox-deferred без значения отклонён" 1 "$?"
declare_intent "$SID" WP-77 --inbox-deferred "a" --inbox-deferred "b" >/dev/null 2>&1
check "повтор --inbox-deferred отклонён" 1 "$?"
declare_intent "$SID" WP-77 --ritual "согласовано" --inbox-deferred "разбор ящика отложить" >/dev/null 2>&1
check "--ritual вместе с --inbox-deferred принят" "0 согласовано" "$? $(jq -r '.ritual.text' "$REC")"
BEFORE=$(cat "$REC")
gitq -C "$WT" remote set-url origin "$TMP_DIR/no-such-origin.git"
declare_intent "$SID" WP-77 --inbox-deferred "разбор ящика отложить" >/dev/null 2>&1
check "сервер недоступен: отсрочка не записана, код 4" 4 "$?"
check "сервер недоступен: запись беседы не изменена" yes "$([ "$(cat "$REC")" = "$BEFORE" ] && echo yes || echo no)"
gitq -C "$WT" remote set-url origin "$ORIGIN"
DOUT=$(declare_intent "$SID" WP-79 --inbox-deferred "разбор ящика отложить" 2>&1)
check "нечего откладывать: намерение записано без отсрочки" "0 WP-79 null" "$? $(jq -r '"\(.intent) \(.inbox_deferral)"' "$REC")"
check "нечего откладывать: сказано словами" yes "$(has "$DOUT" "откладывать нечего")"
declare_intent "$SID" WP-77 --inbox-deferred "разбор ящика отложить" >/dev/null 2>&1
declare_intent "$SID" WP-78 >/dev/null 2>&1
check "другой РП не наследует отсрочку" null "$(jq -r '.inbox_deferral' "$REC")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
