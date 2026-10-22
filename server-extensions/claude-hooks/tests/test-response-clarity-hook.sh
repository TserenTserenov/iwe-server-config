#!/bin/bash
# test-response-clarity-hook.sh — regression + precision/recall harness for
# response-clarity-hook.sh (РП-388 Ф15, round-loop Claude+Kimi+Codex, 2026-10-20).
#
# Before this file, A1/A2/A7.1/A8/A10/A13/BASE5 had zero automated coverage —
# every "проверено" claim in prior calibration sessions was a one-off manual
# run quoted in a peer-session transcript, not a repeatable check. Fixtures
# live in fixtures/response-clarity-fixtures.jsonl: one JSON object per line
# (id, rule, expected, input, note, optional known_gap, optional
# context — "peer" or "direct" (default), passed to the hook as STYLE_CONTEXT). `expected` is the
# rule name for a case that must fire, or NOT_<rule> for a case that must not.
# `known_gap: true` marks a mismatch the team already knows about (open tail,
# not yet fixed) — it is still counted in precision/recall, but does not fail
# the run, so a real NEW regression stays visible instead of hiding in a sea
# of already-accepted gaps.
#
# Transcript/envelope follow the same pattern as test-a12-unsolicited-close.sh
# row 14 (isolated HOME/CLAUDE_PROJECT_DIR per case, stdin JSON with
# transcript_path) — same hook family, same contract, no reason to diverge.
#
# Run: bash .claude/hooks/tests/test-response-clarity-hook.sh

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$HOOKS/response-clarity-hook.sh"
FIXTURES="$HOOKS/tests/fixtures/response-clarity-fixtures.jsonl"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

declare -A TP FP FN TN
RUN_PASS=0
RUN_FAIL=0
GAP_NOTES=()

run_case() {
  local id="$1" rule="$2" expected="$3" input="$4" known_gap="$5" context="$6"
  local case_dir="$TMP/$id"
  mkdir -p "$case_dir/home" "$case_dir/proj"

  local transcript="$case_dir/t.jsonl"
  INPUT_TEXT="$input" python3 - "$transcript" <<'PY'
import json, os, sys
path = sys.argv[1]
reply = os.environ["INPUT_TEXT"]
rows = [
    {"type": "user", "message": {"content": [{"type": "text", "text": "Как дела с задачей?"}]}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": reply}]}},
]
with open(path, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PY

  printf '{"transcript_path":"%s","session_id":"%s"}' "$transcript" "$id" \
    | HOME="$case_dir/home" CLAUDE_PROJECT_DIR="$case_dir/proj" STYLE_CONTEXT="$context" bash "$HOOK" >/dev/null 2>&1
  local hook_exit=$?

  # A crashing hook and a legitimate "rule did not fire" both leave the log
  # line absent — without checking $? the two look identical (code review,
  # РП-388 Ф15, 20.10, High): a NOT_<rule> fixture would quietly "pass" on a
  # crash, hiding exactly the class of bug this harness was built to catch
  # (set -e aborting the hook before it writes its warning). The hook's own
  # contract is "always exit 0", so any non-zero here is always a real bug,
  # never a known_gap.
  if [ "$hook_exit" -ne 0 ]; then
    RUN_FAIL=$((RUN_FAIL + 1))
    echo "FAIL $id ($rule): hook exited $hook_exit (crash, not a rule mismatch)"
    return
  fi

  local log="$case_dir/home/.claude/logs/style-violations.log"
  local fired=false
  [ -f "$log" ] && grep -qE "\| $rule \|" "$log" && fired=true

  local positive=true
  [[ "$expected" == NOT_* ]] && positive=false

  local outcome
  if $positive && $fired; then outcome=TP
  elif $positive && ! $fired; then outcome=FN
  elif ! $positive && $fired; then outcome=FP
  else outcome=TN
  fi

  # case, not eval: $rule comes from the fixtures file, not from code we
  # control line-by-line — eval on an unsanitized key is a standing injection
  # shape even though every current fixture is safe (code review, Medium).
  case "$outcome" in
    TP) TP[$rule]=$(( ${TP[$rule]:-0} + 1 )) ;;
    FP) FP[$rule]=$(( ${FP[$rule]:-0} + 1 )) ;;
    FN) FN[$rule]=$(( ${FN[$rule]:-0} + 1 )) ;;
    TN) TN[$rule]=$(( ${TN[$rule]:-0} + 1 )) ;;
  esac

  if [ "$outcome" = TP ] || [ "$outcome" = TN ]; then
    RUN_PASS=$((RUN_PASS + 1))
    echo "ok   $id ($rule, $outcome)"
  else
    if [ "$known_gap" = "true" ]; then
      RUN_PASS=$((RUN_PASS + 1))
      GAP_NOTES+=("$id ($rule, $outcome) — known gap, see fixture note")
      echo "gap  $id ($rule, $outcome) — known, not a new regression"
    else
      RUN_FAIL=$((RUN_FAIL + 1))
      echo "FAIL $id ($rule, expected $expected, got $outcome)"
    fi
  fi
}

while IFS= read -r line; do
  [ -z "$line" ] && continue
  id=$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["id"])')
  rule=$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["rule"])')
  expected=$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["expected"])')
  input=$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["input"])')
  known_gap=$(printf '%s' "$line" | python3 -c 'import json,sys; print(str(json.loads(sys.stdin.read()).get("known_gap", False)).lower())')
  context=$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("context", "direct"))')
  run_case "$id" "$rule" "$expected" "$input" "$known_gap" "$context"
done < "$FIXTURES"

echo "---"
echo "precision/recall по правилу:"
for rule in $(printf '%s\n' "${!TP[@]}" "${!FP[@]}" "${!FN[@]}" "${!TN[@]}" | sort -u); do
  tp=${TP[$rule]:-0}; fp=${FP[$rule]:-0}; fn=${FN[$rule]:-0}; tn=${TN[$rule]:-0}
  precision="n/a"; recall="n/a"
  [ $((tp + fp)) -gt 0 ] && precision=$(python3 -c "print(f'{$tp/($tp+$fp):.2f}')")
  [ $((tp + fn)) -gt 0 ] && recall=$(python3 -c "print(f'{$tp/($tp+$fn):.2f}')")
  echo "  $rule: TP=$tp FP=$fp FN=$fn TN=$tn precision=$precision recall=$recall"
done

if [ "${#GAP_NOTES[@]}" -gt 0 ]; then
  echo "---"
  echo "известные (не чинённые в этой фазе) пробелы:"
  for note in "${GAP_NOTES[@]}"; do echo "  - $note"; done
fi

echo "---"
echo "passed=$RUN_PASS failed=$RUN_FAIL"
[ "$RUN_FAIL" -eq 0 ]
