#!/bin/bash
# Protocol Artifact Validation Hook
# Event: PreToolUse (matcher: Bash)
# Intercepts `git commit` in protocol-managed repos to validate artifacts.
# Returns block decision if artifact fails validation.
# Read-only: only returns JSON, does not modify files.
#
# Validated artifacts:
#   - DayPlan: 11 required sections + collapsible + non-empty key sections + carry-over
#   - DayClose: итоги, carry-over (day-close protocol) [future]
#
# Parameterized: sections list is a variable, not hardcoded per format.
# Ф3 WP-229: добавлены проверки структуры (collapsible, непустые секции, мультипликатор, carry-over)

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on Bash tool with git commit command
if [ "$TOOL" != "Bash" ]; then
  echo '{}'
  exit 0
fi

# Trigger only on an actual git commit invocation (git as command word after a
# command separator), not on any occurrence of the substring "git commit" —
# e.g. inside a grep pattern, echo text, or commit message being searched for.
# Same anchoring principle as close-runner-gate.sh:150 (WP-484 Ф74а).
if ! echo "$TOOL_INPUT" | grep -qE '(^|[;&|(]) *(([A-Za-z_][A-Za-z0-9_]*=[^ ]+ *)*)(command |builtin |exec )?git ([^;&|]* )?commit( |$)'; then
  echo '{}'
  exit 0
fi

# Repo-scope fix (bug-2026-08-26/27, hardened in peer-session
# 2026-08-27-11-wp452-external-developer-access turns 3-6 with Codex):
# resolve the repo(s) the intercepted command's `git ... commit` invocation(s)
# actually run in, instead of always checking the hardcoded governance path.
# Without this, a commit staged in any OTHER repo gets blocked whenever some
# unrelated agent happens to have a DayPlan/WeekPlan staged in the governance
# repo at the same time (live incident, twice).
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Same anchoring principle as close-runner-gate.sh (WP-484 Ф74а): normalize
# newlines to `;` first (a multi-line command is command-separator-joined,
# same as `;`), then require any global flag between the `git` token and the
# `commit` it belongs to — not a bare substring search across the whole
# command, which would grab `-C` from an unrelated `git ... rev-parse` call
# earlier in the same command, or from inside a commit message like
# `-m "... -C ..."` (both found live in cold-context review of the first
# draft of this fix).
NORMALIZED_COMMAND=$(printf '%s' "$TOOL_INPUT" | tr '\n' ';' | tr -s '[:space:]' ' ')
# Unquoted flag values exclude shell separators too (`[^[:space:];&|]+`, not
# just `[^ ]+`) — `git -C /foreign&&git commit` has no space around `&&`, so
# a value class that only excludes spaces would swallow `&&git` into the
# path and merge two distinct invocations into one (found in peer review).
GIT_GLOBAL_FLAGS_RE='(-C ("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]+)|-c [^[:space:];&|]+|--(git-dir|work-tree|namespace|exec-path)(=[^[:space:];&|]+| [^[:space:];&|]+)|--(literal-pathspecs|glob-pathspecs|noglob-pathspecs|icase-pathspecs|no-optional-locks|no-lazy-fetch|no-replace-objects|no-pager|paginate|bare)|-P)'

# `--git-dir=`/`--work-tree=` are matched (so they don't break the anchor
# for OTHER flags in the same invocation) but not parsed into a target
# path — no real call site in this codebase uses them for `commit`, and
# resolving a bare `--git-dir` back to a worktree adds complexity for a
# case that doesn't occur.

# Governance-репо: из env $IWE_GOVERNANCE_REPO (по умолчанию DS-my-strategy —
# fallback был "DS-strategy", репо переименовано, см. bug-2026-07-11).
# Workspace: $IWE_WORKSPACE или $IWE_ROOT (синонимы), default ~/IWE. Computed
# once — it's an invariant of this hook run, not per candidate invocation.
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-my-strategy}"
WORKSPACE="${IWE_WORKSPACE:-${IWE_ROOT:-$HOME/IWE}}"
GOV_CANONICAL_PATH="$WORKSPACE/$GOV_REPO"
# Worktree-aware match: compare the shared git dir, not the working-tree
# path — an isolated worktree of the governance repo (freeze fallback) has
# a different toplevel path but the same git-common-dir as the canonical
# checkout.
GOV_COMMON_DIR=$(git -C "$GOV_CANONICAL_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -z "$GOV_COMMON_DIR" ]; then
  # Governance repo itself doesn't resolve — a real misconfiguration
  # (IWE_WORKSPACE/IWE_GOVERNANCE_REPO or the checkout itself), not "this
  # commit is unrelated". Surface it instead of silently skipping forever
  # (the same silent-regression shape as the bug this fix addresses).
  jq -n --arg reason "⚠️ protocol-artifact-validate: governance-репозиторий ($GOV_CANONICAL_PATH) не резолвится — DayPlan/WeekPlan не проверены. Проверь IWE_WORKSPACE/IWE_GOVERNANCE_REPO." \
    '{"additionalContext": $reason}'
  exit 0
fi

RESOLVE_FROM=""
# Walk every `git <flags>* commit` invocation in the (possibly compound)
# command — a single Bash call can chain commits to more than one repo, and
# the one that matters may not be the first (found in peer review).
while IFS= read -r invocation; do
  [ -n "$invocation" ] || continue
  candidate="$CWD"
  c_arg=$(printf '%s' "$invocation" | grep -oE -- '-C ("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]+)' | head -1 | sed -E 's/^-C //; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')
  case "$c_arg" in
    *'$'*)
      # A literal shell expansion we cannot resolve from text alone (e.g.
      # `-C "$REPO_ROOT"`) — fall back to .cwd for THIS invocation rather
      # than giving up entirely. This hook is a formatting/hygiene gate, not
      # a security boundary: treating "can't resolve -C" as "assume it's the
      # governance repo, block" would recreate the exact false-positive bug
      # this fix removes, just one level deeper.
      ;;
    "") ;;
    *)
      resolved=$(cd "${CWD:-.}" 2>/dev/null && cd "$c_arg" 2>/dev/null && pwd)
      [ -n "$resolved" ] && candidate="$resolved"
      ;;
  esac
  [ -n "$candidate" ] || continue
  candidate_repo=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$candidate_repo" ] || continue
  candidate_common_dir=$(git -C "$candidate_repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  [ -n "$candidate_common_dir" ] || continue
  if [ "$candidate_common_dir" = "$GOV_COMMON_DIR" ]; then
    RESOLVE_FROM="$candidate_repo"
    break
  fi
done <<EOF
$(printf '%s\n' "$NORMALIZED_COMMAND" | grep -oE "git( $GIT_GLOBAL_FLAGS_RE)* commit")
EOF

if [ -z "$RESOLVE_FROM" ]; then
  echo '{}'
  exit 0
fi
GOV_PATH="$RESOLVE_FROM"

# R4.5 fix (WP-273): trigger ТОЛЬКО по staged files, НЕ по тексту команды.
# Старая логика грепала TOOL_INPUT на «DayPlan|day-close» — false positive
# на любой коммит файла `day-close/SKILL.md` или сообщения с «day-close».
# Принцип: «hook trigger = artifact (staged file), не TOOL_INPUT текст» (memory/hooks-design.md).
# `core.quotePath=false` keeps non-ASCII paths literal, so the pathspec
# narrowing below compares the same spelling the command uses.
STAGED=$(cd "$GOV_PATH" 2>/dev/null && git -c core.quotePath=false diff --cached --name-only 2>/dev/null || echo "")
STAGED_PLANS=$(echo "$STAGED" | grep -E '^current/DayPlan.*\.md$|^current/WeekPlan.*\.md$' || true)
if [ -z "$STAGED_PLANS" ]; then
  echo '{}'
  exit 0
fi

# Pathspec-scope fix (WP-7 Ф107, bug-2026-08-26/27/09-05 class): the index read
# above belongs to the whole repo, but `git commit -- <paths>` commits only the
# listed paths. On the shared Mac checkout several sessions stage into the same
# index at once, so a DayPlan/WeekPlan staged by ANOTHER agent would otherwise
# block a commit that does not contain it.
# The helper only ever answers NARROW when the command text PROVES every commit
# invocation excludes the staged plan files; a missing helper, a broken python3
# or any doubt falls back to validating the whole index, exactly as before.
PATHSPEC_HELPER="$(dirname "${BASH_SOURCE[0]}")/git-commit-pathspec.py"
if [ -f "$PATHSPEC_HELPER" ]; then
  PLAN_ARGS=()
  while IFS= read -r staged_plan; do
    [ -n "$staged_plan" ] && PLAN_ARGS+=("$staged_plan")
  done <<< "$STAGED_PLANS"
  PATHSPEC_DECISION=$(printf '%s' "$TOOL_INPUT" | python3 "$PATHSPEC_HELPER" "${PLAN_ARGS[@]}" 2>/dev/null || echo "KEEP")
  if [ "$PATHSPEC_DECISION" = "NARROW" ]; then
    echo '{}'
    exit 0
  fi
fi

# --- DayPlan Validation (выполняется только если DayPlan-файл существует) ---
DAYPLAN=$(ls "$GOV_PATH"/current/DayPlan\ *.md 2>/dev/null | head -1)
MISSING=()
ERRORS=()

if [ -n "$DAYPLAN" ]; then

# Required sections (parameterized — update this list when format changes).
# Scout раздел опционален: проверяется отдельно ниже (см. блок "Scout").
SECTIONS=(
  "План на сегодня|Plan for Today|Today.s Plan"
  "Календарь|Calendar"
  "IWE за ночь|IWE Overnight"
  "Разбор заметок|Notes Review"
  "Итоги вчера|Yesterday"
)

for section in "${SECTIONS[@]}"; do
  if ! grep -qE "$section" "$DAYPLAN"; then
    MISSING+=("$section")
  fi
done

# Check mandatory format elements

# --- Ф3 Check 1: collapsible <details> блоки ---
DETAILS_COUNT=$(grep -c '<details' "$DAYPLAN" 2>/dev/null || true); DETAILS_COUNT=${DETAILS_COUNT:-0}
if [ "$DETAILS_COUNT" -lt 3 ]; then
  ERRORS+=("Collapsible секции (<details>) < 3 найдено: $DETAILS_COUNT. DayPlan должен иметь collapsible-структуру")
fi

# --- Ф3 Check 2: непустые обязательные секции ---
# Календарь: должна содержать хотя бы одну строку с | (таблица) или "нет событий"
CALENDAR_CONTENT=$(awk '/Календарь|Calendar/,/^<\/details>/' "$DAYPLAN" 2>/dev/null | wc -l || echo 0)
if [ "$CALENDAR_CONTENT" -lt 3 ]; then
  ERRORS+=("Секция 'Календарь' пустая или слишком короткая (${CALENDAR_CONTENT} строк)")
fi

# Scout: проверяется только если секция вообще присутствует в DayPlan (опциональный компонент,
# зависит от DS-agent-workspace). Если секции нет — Scout не сконфигурирован, валидатор не блокирует.
if grep -q "Наработки Scout" "$DAYPLAN" 2>/dev/null; then
  if ! awk '/Наработки Scout/,/^<\/details>/' "$DAYPLAN" 2>/dev/null | grep -iqE 'наход|capture|статус|нет|find|disabled|not configured'; then
    ERRORS+=("Секция 'Наработки Scout' пустая (допустимы маркеры 'нет находок', 'disabled', 'not configured')")
  fi
fi

# --- Ф3 Check 3: формат мультипликатора ---
# Пилот 27.08: середина дня — множитель объективно ещё не посчитан (считается
# на Day Close), явная формулировка-заглушка "мультипликатор считается на
# закрытии дня" тоже валидна, не только готовое число.
if ! grep -qE "~[0-9]+\.?[0-9]*x|мультипликатор считается на закрытии дня" "$DAYPLAN"; then
  ERRORS+=("Мультипликатор не найден — нужен формат '~N.Nx' в строке бюджета или явная заглушка 'мультипликатор считается на закрытии дня'")
fi

if ! grep -qE "~[0-9]+\.?[0-9]*h РП" "$DAYPLAN"; then
  ERRORS+=("Бюджет дня не в формате '~Xh РП / ~Yh физ'")
fi

# --- Ф3 Check 5: Carry-over цитата (если есть предыдущий DayPlan) ---
PREV_DAYPLAN=$(ls "$GOV_PATH"/current/DayPlan\ *.md 2>/dev/null | sort | tail -2 | head -1)
if [ -n "$PREV_DAYPLAN" ] && [ "$PREV_DAYPLAN" != "$DAYPLAN" ]; then
  # Предыдущий DayPlan существует — текущий должен содержать Carry-over
  if ! grep -qiE 'carry.over|carry_over' "$DAYPLAN"; then
    ERRORS+=("Carry-over цитата из предыдущего Day Close отсутствует (предыдущий DayPlan: $(basename "$PREV_DAYPLAN"))")
  fi
fi

fi  # endif [ -n "$DAYPLAN" ]

# --- WeekPlan Validation (Ф6.1 WP-265) ---
WEEKPLAN=$(ls "$GOV_PATH"/current/WeekPlan\ *.md 2>/dev/null | sort | tail -1)
if [ -n "$WEEKPLAN" ]; then
  WP_LINES=$(wc -l < "$WEEKPLAN" | tr -d ' ')
  WP_ERRORS=()
  WP_MISSING_LIST=()

  # Детектор (а): >80 строк без достаточного числа <details>
  WP_DETAILS_COUNT=$(grep -c '<details' "$WEEKPLAN" 2>/dev/null || true); WP_DETAILS_COUNT=${WP_DETAILS_COUNT:-0}
  if [ "$WP_LINES" -gt 80 ] && [ "$WP_DETAILS_COUNT" -lt 3 ]; then
    WP_ERRORS+=("WeekPlan >80 строк ($WP_LINES) но collapsible секций < 3 ($WP_DETAILS_COUNT). Используй <details>/<summary> (formatting.md)")
  fi

  # Детектор (б): баланс <details> / </details>
  DETAILS_OPEN=$(grep -c '<details' "$WEEKPLAN" 2>/dev/null || true); DETAILS_OPEN=${DETAILS_OPEN:-0}
  DETAILS_CLOSE=$(grep -c '</details>' "$WEEKPLAN" 2>/dev/null || true); DETAILS_CLOSE=${DETAILS_CLOSE:-0}
  if [ "$DETAILS_OPEN" != "$DETAILS_CLOSE" ]; then
    WP_ERRORS+=("WeekPlan: несбалансированные <details> (открытий=$DETAILS_OPEN, закрытий=$DETAILS_CLOSE)")
  fi

  # Детектор (в): обязательные секции WeekPlan (по templates-dayplan.md)
  # ОПТ-5 (WP-297, 8 май): «Итоги» переехали в WeekReport — больше не required в WeekPlan
  WP_REQUIRED=(
    "Повестка|Agenda"
    "Inbox Triage"
    "План на неделю|Week Plan"
    "Контент-план|Content Plan"
  )
  for wp_section in "${WP_REQUIRED[@]}"; do
    if ! grep -qE "$wp_section" "$WEEKPLAN"; then
      WP_MISSING_LIST+=("$wp_section")
    fi
  done

  # Детектор (г): WeekReport валидация (ОПТ-5 WP-297)
  WEEKREPORT=$(ls "$GOV_PATH"/current/WeekReport\ *.md 2>/dev/null | sort | tail -1)
  if [ -n "$WEEKREPORT" ]; then
    if ! grep -q "Итоги" "$WEEKREPORT"; then
      WP_MISSING_LIST+=("Итоги (в WeekReport)")
    fi
  fi

  if [ ${#WP_MISSING_LIST[@]} -gt 0 ] || [ ${#WP_ERRORS[@]} -gt 0 ]; then
    WP_MISSING_STR=$(IFS=', '; echo "${WP_MISSING_LIST[*]:-}")
    WP_ERRORS_STR=$(IFS=', '; echo "${WP_ERRORS[*]:-}")
    WP_MSG="⛔ WEEKPLAN VALIDATION FAILED."
    [ ${#WP_MISSING_LIST[@]} -gt 0 ] && WP_MSG="$WP_MSG Пропущены секции (${#WP_MISSING_LIST[@]}): $WP_MISSING_STR."
    [ ${#WP_ERRORS[@]} -gt 0 ] && WP_MSG="$WP_MSG Ошибки структуры: $WP_ERRORS_STR."
    WP_MSG="$WP_MSG Исправь WeekPlan перед коммитом."
    jq -n --arg reason "$WP_MSG" '{"decision": "block", "reason": $reason}'
    exit 0
  fi
fi

# Report results
if [ ${#MISSING[@]} -gt 0 ] || [ ${#ERRORS[@]} -gt 0 ]; then
  MISSING_STR=$(printf ', %s' "${MISSING[@]}")
  MISSING_STR=${MISSING_STR:2}
  ERRORS_STR=$(printf ', %s' "${ERRORS[@]}")
  ERRORS_STR=${ERRORS_STR:2}

  MSG="⛔ DAYPLAN VALIDATION FAILED."
  [ ${#MISSING[@]} -gt 0 ] && MSG="$MSG Пропущены секции (${#MISSING[@]}): $MISSING_STR."
  [ ${#ERRORS[@]} -gt 0 ] && MSG="$MSG Ошибки формата/структуры: $ERRORS_STR."
  MSG="$MSG Исправь DayPlan перед коммитом."

  jq -n --arg reason "$MSG" '{"decision": "block", "reason": $reason}'
else
  cat <<'EOF'
{"additionalContext": "✅ DayPlan прошёл валидацию: секции, collapsible, непустые блоки, мультипликатор, carry-over."}
EOF
fi

exit 0
