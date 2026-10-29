#!/bin/bash
# test-a12-cross-turn-repeat.sh -- fixtures for a12-cross-turn-repeat.py
# (РП-605 Ф6, peer-session 2026-10-29-23-wp605-cross-turn-detector).
#
# Each case builds a small JSONL transcript and checks whether the detector
# prints its one-line signal. Boundary cases come from the Codex review of the
# spec: unfinished tool_use, mixed human+service record, unknown service
# wrapper, episode without tools, a human reply of any length breaking the pair.
#
# Run: bash .claude/hooks/tests/test-a12-cross-turn-repeat.sh

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECTOR="$HOOKS/a12-cross-turn-repeat.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# make_transcript <out-file> <python-expression building `rows` from helpers>
make_transcript() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]

def U(text, **kw):
    return {"type": "user", **kw, "message": {"content": [{"type": "text", "text": text}]}}
def UM(*texts):
    return {"type": "user", "message": {"content": [{"type": "text", "text": t} for t in texts]}}
def QC(text):
    return {"type": "attachment", "attachment": {"type": "queued_command", "prompt": text}}
def FB(text="Stop hook feedback:\nСтиль нарушен (правила: A13.1 ). Перепиши финальную часть."):
    return {"type": "user", "isMeta": True, "message": {"content": text}}
def TR():
    return {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]}}
def A(text):
    return {"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}}
def AH(text):
    return {"type": "assistant", "isApiErrorMessage": True, "message": {"model": "<synthetic>", "content": [{"type": "text", "text": text}]}}
def AT(text=""):
    blocks = ([{"type": "text", "text": text}] if text else []) + [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}]
    return {"type": "assistant", "message": {"content": blocks}}

NOTIF = "<task-notification>фоновая задача завершена</task-notification>"
BLOCK = ("Запрос на слияние номер 1386 готов к проверке пилотом. Проверки зелёные, замечаний нет, "
         "ждёт только решения о слиянии в основную ветку.\n\nДальше: вы решаете, сливать ли запрос сегодня.")
OTHER = "Совсем другая тема: сейчас разбираю журнал приёмки и сверяю расхождения по таблице платежей за неделю."
rows = eval(expr)
with open(path, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
}

# check <name> <expect: fire|quiet> <python rows expression> [env assignment]
check() {
  local name="$1" expect="$2" expr="$3" envs="${4:-}"
  local f="$TMP/$name.jsonl"
  make_transcript "$f" "$expr"
  local out err rc got=quiet
  # A crash must never pass as a detection: stdout and stderr are kept apart,
  # the exit code and an empty stderr are part of every verdict, and a firing
  # case must print the signal line itself (starts with "score=").
  # shellcheck disable=SC2086  # $envs is an intentional VAR=value word list
  out=$(env STYLE_CONTEXT=direct $envs IWE_A12_REPEAT_DEBUG=1 python3 "$DETECTOR" "$f" 2>"$TMP/err")
  rc=$?
  err=$(cat "$TMP/err")
  case "$out" in score=*) got=fire ;; "") got=quiet ;; *) got="garbled" ;; esac
  if [ "$got" = "$expect" ] && [ "$rc" -eq 0 ] && [ -z "$err" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL $name: expected $expect, got $got rc=$rc out=[$out] err=[$err]"
  fi
}

# explain <name> <python rows expression> <jq-free python check on the record `r`>
explain_check() {
  local name="$1" expr="$2" cond="$3"
  local f="$TMP/$name.jsonl"
  make_transcript "$f" "$expr"
  if STYLE_CONTEXT=direct python3 "$DETECTOR" --explain "$f" | python3 -c "
import json, sys
r = json.load(sys.stdin)
sys.exit(0 if ($cond) else 1)"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL $name: condition not met: $cond"
    STYLE_CONTEXT=direct python3 "$DETECTOR" --explain "$f"
  fi
}

# 1. Live shape: same block, second reply written after a service record.
check live-repeat-after-notification fire \
  '[U("Что с запросом?"), A(BLOCK), U(NOTIF), A(BLOCK)]'
# 2. Same text after ANY pilot message, even "да", is not a repeat.
check human-yes-breaks-pair quiet \
  '[U("Что с запросом?"), A(BLOCK), U("да"), A(BLOCK)]'
# 3. Service record but a different reply.
check different-text quiet \
  '[U("Что с запросом?"), A(BLOCK), U(NOTIF), A(OTHER)]'
# 4. Too short on both sides: no data, no signal.
check too-short quiet \
  '[U("Как?"), A("Готово, жду."), U(NOTIF), A("Готово, жду.")]'
# 5. Current episode ends on an unfinished tool call: skipped.
check unfinished-tool-use quiet \
  '[U("Что с запросом?"), A(BLOCK), U(NOTIF), AT(BLOCK)]'
# 6a. Intermediate text before a tool call is not the final reply.
check intermediate-text-ignored quiet \
  '[U("Что?"), AT(BLOCK), TR(), A(OTHER), U(NOTIF), A(BLOCK)]'
# 6b. The final reply after tool results is compared.
check final-after-tools-compared fire \
  '[U("Что?"), AT("проверяю"), TR(), A(BLOCK), U(NOTIF), AT("проверяю снова"), TR(), A(BLOCK)]'
# 7. Mixed record: pilot text next to a service wrapper is a human opener.
check mixed-record-is-human quiet \
  '[U("Что?"), A(BLOCK), UM(NOTIF, "и ещё вопрос"), A(BLOCK)]'
# 8. Unknown opener (isMeta without pilot text): skipped, never guessed.
check ismeta-opener-unknown quiet \
  '[U("Что?"), A(BLOCK), U("служебная вставка загрузки навыка", isMeta=True), A(BLOCK)]'
# 9. Episode without any tool: the previous final reply is compared.
check no-tools-episode fire \
  '[U("Что?"), A(BLOCK), U(NOTIF), A(BLOCK)]'
# 10. Peer context is skipped (addressed to the writer, not the pilot).
check peer-context-skipped quiet \
  '[U("Что?"), A(BLOCK), U(NOTIF), A(BLOCK)]' "STYLE_CONTEXT=peer"
# 11. Single episode: nothing to compare.
check single-episode quiet '[U("Что?"), A(BLOCK)]'
# 12. Only numbers/hashes differ: raw score stays low, masked score is high.
explain_check masked-score-diagnostic \
  '[U("Что?"), A("коммит 1234567 слит запрос 111 закрыт проверка 222 пройдена итог 333 принят"), U(NOTIF), A("коммит 7654321 слит запрос 999 закрыт проверка 888 пройдена итог 777 принят")]' \
  'r["masked_score"] == 1.0 and r["score"] < r["threshold"] and not r["fires"]'
# 13. Threshold is configurable and lowers the bar.
check threshold-env-raises-bar quiet \
  '[U("Что?"), A(BLOCK), U(NOTIF), A(BLOCK)]' "IWE_A12_REPEAT_THRESHOLD=1.01 IWE_A12_REPEAT_NEXT_THRESHOLD=1.01"
# 14. Journal fields for calibration are present.
explain_check journal-fields \
  '[U("Что?"), A(BLOCK), U(NOTIF), A(BLOCK)]' \
  'r["fires"] and r["score"] == 1.0 and len(r["hashes"]) == 2 and r["words"][0] == r["words"][1] and r["opener"] == "service" and r["next_score"] == 1.0'
# 15. Real storage shape of a background notification: a queued_command attachment.
check live-repeat-after-queued-notification fire \
  '[U("Что с запросом?"), A(BLOCK), QC(NOTIF), A(BLOCK)]'
# 16. A pilot message typed while the agent was busy (queued_command, plain text) breaks the pair.
check queued-human-message-breaks-pair quiet \
  '[U("Что с запросом?"), A(BLOCK), QC("да, сливай"), A(BLOCK)]'
# 17. Different body, identical "Дальше:" line: the next-line arm fires.
check next-line-repeat-with-new-body fire \
  '[U("Что?"), A(OTHER + "\n\nДальше: вы решаете, сливать ли запрос сегодня."), U(NOTIF), A(BLOCK.split("\n\n")[0].replace("1386","1400") + " Совсем иной текст про оплату и квитанции за месяц.\n\nДальше: вы решаете, сливать ли запрос сегодня.")]'
explain_check next-line-part-label \
  '[U("Что?"), A(OTHER + "\n\nДальше: вы решаете, сливать ли запрос сегодня."), U(NOTIF), A("Другой абзац про платежи и квитанции, который не похож на прежний ни одним оборотом речи.\n\nДальше: вы решаете, сливать ли запрос сегодня.")]' \
  'r["part"] == "next" and r["score"] < r["threshold"] and r["next_score"] == 1.0'
# 18. Next-line arm threshold is configurable.
check next-threshold-env-raises-bar quiet \
  '[U("Что?"), A(OTHER + "\n\nДальше: вы решаете, сливать ли запрос сегодня."), U(NOTIF), A("Другой абзац про платежи и квитанции, который не похож на прежний ни одним оборотом речи.\n\nДальше: вы решаете, сливать ли запрос сегодня.")]' "IWE_A12_REPEAT_NEXT_THRESHOLD=1.01"
# 19. A harness rate-limit notice is not a model reply: never compared.
check harness-limit-notice-ignored quiet \
  '[U("Что?"), AH("You have hit your session limit and it resets at seven in the evening"), U(NOTIF), AH("You have hit your session limit and it resets at seven in the evening")]'
# 20. Notification and a pilot question inside ONE queued_command / text block: human.
check mixed-queued-command-is-human quiet \
  '[U("Что?"), A(BLOCK), QC(NOTIF + "\nИ ещё вопрос от пилота"), A(BLOCK)]'
check mixed-text-block-is-human quiet \
  '[U("Что?"), A(BLOCK), U(NOTIF + "\nИ ещё вопрос от пилота"), A(BLOCK)]'
# 21. A tool call without a result before the final text: the episode is unfinished.
check unmatched-tool-use-before-text quiet \
  '[U("Что?"), A(BLOCK), U(NOTIF), AT(), A(BLOCK)]'
# 22. A long appendix after the "Дальше:" paragraph neither hides nor fakes a repeat of the line.
explain_check next-paragraph-only \
  '[U("Что?"), A(OTHER + "\n\nДальше: вы решаете, сливать ли запрос сегодня.\n\n" + "Приложение номер один про платежи. " * 12), U(NOTIF), A("Иной текст про журнал приёмки и таблицу расхождений за прошедшую неделю.\n\nДальше: вы решаете, сливать ли запрос сегодня.\n\n" + "Совсем другое приложение про квитанции. " * 12)]' \
  'r["next_score"] == 1.0 and r["part"] == "next"'
# 23. Leading BOM / indentation do not change the classification or the line split.
check bom-before-notification-is-service fire \
  '[U("Что?"), A(BLOCK), QC("\ufeff" + NOTIF), A(BLOCK)]'
explain_check indented-next-line \
  '[U("Что?"), A(OTHER + "\n\n  Дальше: вы решаете, сливать ли запрос сегодня."), U(NOTIF), A("Иной текст про журнал приёмки и таблицу расхождений за прошедшую неделю.\n\n  Дальше: вы решаете, сливать ли запрос сегодня.")]' \
  'r["next_score"] == 1.0'
# 24. Decision uses the raw score, not the rounded one: Jaccard 4/6 = 0.6667 vs threshold 0.6668.
check raw-score-decides quiet \
  '[U("Что?"), A("а б в г д е ж"), U(NOTIF), A("а б в г д е з")]' "IWE_A12_REPEAT_THRESHOLD=0.6668"
# 25. Valid JSON of the wrong shape is dropped; a later real repeat is still found.
check malformed-record-skipped-pair-found fire \
  '[U("Что?"), A(BLOCK), {"type": "user", "message": None}, {"type": "assistant", "message": {"content": [{"type": "text", "text": None}]}}, U(NOTIF), A(BLOCK)]'
# 26. The reply rewritten after a Stop-hook block (isMeta string record) is compared too:
#     this is the pilot's 29.10 case, a repeat shown right after a blocked reply.
check repeat-after-stop-hook-feedback fire \
  '[U("Что?"), A(BLOCK), FB(), A(BLOCK)]'
check stop-hook-feedback-different-reply quiet \
  '[U("Что?"), A(BLOCK), FB(), A(OTHER)]'
# 27. Other isMeta records (loop prompts, skill expansions) stay unknown: never compared.
check ismeta-string-without-known-prefix-unknown quiet \
  '[U("Что?"), A(BLOCK), FB("# Autonomous loop check\nпроверь очередь"), A(BLOCK)]'
# 28. Garbage in the transcript never raises (a Stop hook must not break the turn).
printf 'not json\n{"type":"user"}\n[]\n' > "$TMP/garbage.jsonl"
if [ -z "$(STYLE_CONTEXT=direct python3 "$DETECTOR" "$TMP/garbage.jsonl" 2>&1)" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL garbage-input: detector printed something"
fi

# 29. Hook level: the signal is logged even on the re-run after a block
#     (stop_hook_active=true), where the hook skips every other detector.
make_transcript "$TMP/hook.jsonl" '[U("Что?"), A(BLOCK), FB(), A(BLOCK)]'
mkdir -p "$TMP/home" "$TMP/proj"
printf '{"transcript_path":"%s","session_id":"hooktest","stop_hook_active":true}' "$TMP/hook.jsonl" \
  | HOME="$TMP/home" CLAUDE_PROJECT_DIR="$TMP/proj" bash "$HOOKS/response-clarity-hook.sh" >/dev/null 2>&1
if grep -q "| A12_CROSS_TURN_REPEAT |" "$TMP/home/.claude/logs/style-violations.log" 2>/dev/null; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL hook-logs-signal-on-stop-hook-active: no log line"
fi

echo "a12-cross-turn-repeat: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
