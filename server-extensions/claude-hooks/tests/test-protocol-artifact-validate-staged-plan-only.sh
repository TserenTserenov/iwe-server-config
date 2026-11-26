#!/bin/bash
# test-protocol-artifact-validate-staged-plan-only.sh -- WP-484 F342
# (bug-2026-09-14-artifact-validate-hook-blocks-unrelated-commits-on-stale-dayplan,
# inbox I-43 item 1): the hook validated a DayPlan from disk whenever ANY plan
# (DayPlan or WeekPlan) was staged, and vice versa, so a commit of only the week
# transition was blocked by a stale DayPlan. Now each plan is validated only when
# it is in the commit, and the staged file itself is validated.
#
# Run: bash .claude/hooks/tests/test-protocol-artifact-validate-staged-plan-only.sh
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/protocol-artifact-validate.sh"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
PASS=0
FAIL=0

GOV="$WORKDIR/gov-repo"
mkdir -p "$GOV/current"
git -C "$GOV" init -q
git -C "$GOV" config user.email test@test
git -C "$GOV" config user.name test

valid_dayplan() {
  cat <<'EOF'
## План на сегодня
- item
## Календарь
| time | event |
|------|-------|
| 10:00 | standup |
## IWE за ночь
nothing
## Разбор заметок
nothing
## Итоги вчера
nothing
<details>1</details>
<details>2</details>
<details>3</details>
**Портфель в работе:** ~9h РП / физ 9h / мультипликатор считается на закрытии дня
carry-over from yesterday
EOF
}
broken_dayplan() { printf '## План на сегодня\n- item\n'; }  # most sections missing
valid_weekplan() { printf '## Повестка\nitem\n## Inbox Triage\nitem\n## План на неделю\nitem\n## Контент-план\nitem\n'; }
broken_weekplan() { printf '## Повестка\nitem\n<details>\n'; }  # sections missing, unbalanced <details>

run_hook() { # prints the hook's stdout for `git commit -m x` run in $GOV
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"cwd":sys.argv[1]}))' "$GOV" \
    | IWE_GOVERNANCE_REPO="gov-repo" IWE_WORKSPACE="$WORKDIR" bash "$HOOK" 2>/dev/null
}
verdict() { # block | ok-dayplan | silent | other
  local out="$1"
  if grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' <<<"$out"; then echo block
  elif grep -q 'DayPlan прошёл валидацию' <<<"$out"; then echo ok-dayplan
  elif [ "$out" = "{}" ]; then echo silent
  else echo "other:$out"; fi
}
expect() { # <name> <expected verdict>
  local got
  got=$(verdict "$(run_hook)")
  if [ "$got" = "$2" ]; then PASS=$((PASS + 1)); echo "PASS: $1"
  else FAIL=$((FAIL + 1)); echo "FAIL: $1 (expected $2, got $got)"; fi
}
reset_index() { git -C "$GOV" reset -q; }

broken_dayplan > "$GOV/current/DayPlan 2026-09-12.md"
broken_weekplan > "$GOV/current/WeekPlan W37.md"
git -C "$GOV" add -A && git -C "$GOV" commit -qm "stale plans on disk"

# 1. Only a (valid) WeekPlan in the commit, a broken DayPlan on disk -> passes.
valid_weekplan > "$GOV/current/WeekPlan W38.md"
git -C "$GOV" add "current/WeekPlan W38.md"
expect "1: only WeekPlan staged, stale broken DayPlan on disk is not validated" silent
reset_index

# 2. Only a (valid) DayPlan in the commit, a broken WeekPlan on disk -> passes.
#    Also proves the staged DayPlan is validated, not the alphabetically first
#    one on disk: the broken 2026-09-12 stays on disk outside the commit.
valid_dayplan > "$GOV/current/DayPlan 2026-09-15.md"
git -C "$GOV" add "current/DayPlan 2026-09-15.md"
expect "2: only DayPlan staged, broken plans on disk are not validated" ok-dayplan
reset_index

# 3. Both staged: both validated as before (coverage kept).
git -C "$GOV" add "current/DayPlan 2026-09-15.md" "current/WeekPlan W38.md"
expect "3a: both staged and valid -> DayPlan reported valid" ok-dayplan
broken_dayplan > "$GOV/current/DayPlan 2026-09-15.md"
git -C "$GOV" add "current/DayPlan 2026-09-15.md"
expect "3b: both staged, staged DayPlan broken -> block" block
valid_dayplan > "$GOV/current/DayPlan 2026-09-15.md"
broken_weekplan > "$GOV/current/WeekPlan W38.md"
git -C "$GOV" add "current/DayPlan 2026-09-15.md" "current/WeekPlan W38.md"
expect "3c: both staged, staged WeekPlan broken -> block" block
reset_index

# 4. No plan staged -> early exit, silent.
echo note > "$GOV/notes.md"
git -C "$GOV" add notes.md
expect "4: no plan staged -> silent" silent
reset_index

# 5. A staged deletion (archiving a plan) has nothing to validate.
git -C "$GOV" rm -q --cached "current/DayPlan 2026-09-12.md"
mv "$GOV/current/DayPlan 2026-09-12.md" "$WORKDIR/archived-dayplan.md"
expect "5: archived (deleted) DayPlan in the commit -> silent" silent

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
