#!/usr/bin/env bash
#
# kimi-final-text-smoke.sh
# Fixture smoke test for scripts/kimi-final-text.py (WP-524 F6, DP.SC.202).
#
# The tool's whole contract is "never hand back a partial or foreign answer in
# silence". Every case below is a way that contract was actually broken during
# cold review on 2026-09-05 -- a cancelled turn read as complete, a neighbouring
# turn's end marker certifying an aborted one, an unlabelled fragment glued to
# the wrong turn. Each asserts an exit code AND the observable output, because
# "it ran without crashing" is what let those three through in the first place.

set -uo pipefail

TOOL="${IWE_WORKSPACE:-$HOME/IWE}/scripts/kimi-final-text.py"
WORK=$(mktemp -d -t kimi-final-text-smoke-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0

# check <name> <fixture> <expected exit> <expected stdout substring, or "" for empty stdout>
check() {
  local name="$1" fixture="$2" want_code="$3" want_out="$4"
  local out code
  out=$(python3 "$TOOL" --file "$WORK/$fixture" 2>/dev/null)
  code=$?

  if [ "$code" != "$want_code" ]; then
    echo "FAIL $name: код возврата $code, ожидался $want_code"
    FAILED=$((FAILED + 1))
    return
  fi
  if [ -z "$want_out" ] && [ -n "$out" ]; then
    echo "FAIL $name: ожидался пустой вывод, получено: $out"
    FAILED=$((FAILED + 1))
    return
  fi
  if [ -n "$want_out" ] && [[ "$out" != *"$want_out"* ]]; then
    echo "FAIL $name: в выводе нет «$want_out», получено: $out"
    FAILED=$((FAILED + 1))
    return
  fi
  echo "ok   $name"
  PASSED=$((PASSED + 1))
}

python3 - "$WORK" <<'PY'
import json, os, sys

work = sys.argv[1]


def part(turn, step, text):
    return {"type": "context.append_loop_event",
            "event": {"type": "content.part", "turnId": turn, "step": step,
                      "part": {"type": "text", "text": text}}}


def think(turn, step, text):
    return {"type": "context.append_loop_event",
            "event": {"type": "content.part", "turnId": turn, "step": step,
                      "part": {"type": "think", "think": text}}}


def ended(turn, reason="completed"):
    return {"type": "turn.ended", "turnId": turn, "reason": reason, "durationMs": 1}


def write(name, rows, extra_lines=()):
    with open(os.path.join(work, name), "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
        for line in extra_lines:
            handle.write(line + "\n")


write("empty.jsonl", [])
write("think_only.jsonl", [think(0, 1, "размышление"), ended(0)])
write("no_end.jsonl", [part(0, 1, "частичный ответ")])
write("cancelled.jsonl", [part(0, 1, "обрывок"), ended(0, "cancelled")])
write("failed.jsonl", [part(0, 1, "обрывок"), ended(0, "failed")])
write("turn_cancel.jsonl", [part(0, 1, "обрывок"),
                            {"type": "turn.cancel", "turnId": 0, "reason": "user"}])
# The neighbouring finished turn must not certify the unfinished one.
write("cross_turn.jsonl", [part(0, 1, "обрывок хода 0"),
                           {"type": "turn.prompt", "turnId": 1},
                           ended(1),
                           {"type": "prompt.completed", "promptId": "p1"}])
# prompt.completed carries no turnId at all, so it alone certifies nothing.
write("only_prompt_completed.jsonl", [part(0, 1, "обрывок"),
                                      {"type": "prompt.completed", "promptId": "p1"}])
write("multistep.jsonl", [part(0, 1, "нарратив шага 1"),
                          part(0, 2, "ФИНАЛЬНЫЙ ОТВЕТ"), ended(0)])
# Turn 10 must win over turn 9: numeric order, not string order.
write("turn_order.jsonl", [part(9, 1, "старый ход"), ended(9),
                           part(10, 1, "НОВЫЙ ХОД"), ended(10)])
write("turnid_missing.jsonl", [{"type": "context.append_loop_event",
                                "event": {"type": "content.part", "step": 1,
                                          "part": {"type": "text", "text": "без хода"}}},
                               ended(0)])
write("corrupt.jsonl", [part(0, 1, "уцелевший текст"), ended(0)], ["{битая строка"])
write("good.jsonl", [part(0, 1, "достоверный текст отчёта"), ended(0)])
# Text appended after the turn already ended is not covered by that marker.
write("text_after_end.jsonl", [part(0, 1, "первый кусок"), ended(0),
                               part(0, 2, "дописано после конца")])
PY

echo "--- отказы (частичный текст выдавать нельзя) ---"
check "пустой журнал"                      empty.jsonl                1 ""
check "только размышления, без ответа"     think_only.jsonl           1 ""
check "ход не завершён"                    no_end.jsonl               4 ""
check "ход прерван (cancelled)"            cancelled.jsonl            4 ""
check "ход упал (failed)"                  failed.jsonl               4 ""
check "ход отменён (turn.cancel)"          turn_cancel.jsonl          4 ""
check "конец соседнего хода не считается"  cross_turn.jsonl           4 ""
check "prompt.completed без номера хода"   only_prompt_completed.jsonl 4 ""
check "фрагмент без номера хода"           turnid_missing.jsonl       1 ""
check "текст дописан после конца хода"      text_after_end.jsonl       4 ""

echo "--- выдача ---"
check "многошаговый ход: берём финальный"  multistep.jsonl            0 "ФИНАЛЬНЫЙ ОТВЕТ"
check "ход 10 новее хода 9"                turn_order.jsonl           0 "НОВЫЙ ХОД"
check "битая строка не глушит выдачу"      corrupt.jsonl              0 "уцелевший текст"

echo "--- предупреждение о битой строке видно ---"
if python3 "$TOOL" --file "$WORK/corrupt.jsonl" 2>&1 >/dev/null | grep -q "не разобрались как JSON"; then
  echo "ok   битая строка порождает предупреждение"
  PASSED=$((PASSED + 1))
else
  echo "FAIL битая строка прошла молча"
  FAILED=$((FAILED + 1))
fi

echo "--- сверка ---"
printf '%s\n' "достоверный текст отчёта" > "$WORK/same.txt"
printf '%s\n' "достоверный отчёта" > "$WORK/lossy.txt"

python3 "$TOOL" --file "$WORK/good.jsonl" --diff "$WORK/same.txt" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "ok   идентичная копия — расхождений нет"
  PASSED=$((PASSED + 1))
else
  echo "FAIL идентичная копия объявлена расходящейся"
  FAILED=$((FAILED + 1))
fi

DIFF_OUT=$(python3 "$TOOL" --file "$WORK/good.jsonl" --diff "$WORK/lossy.txt" 2>/dev/null)
DIFF_CODE=$?
if [ "$DIFF_CODE" -eq 3 ] && [[ "$DIFF_OUT" == *"текст"* ]]; then
  echo "ok   потерянный кусок найден и назван"
  PASSED=$((PASSED + 1))
else
  echo "FAIL сверка не нашла потерю (код $DIFF_CODE): $DIFF_OUT"
  FAILED=$((FAILED + 1))
fi

echo
echo "прошло: $PASSED, упало: $FAILED"
[ "$FAILED" -eq 0 ]
