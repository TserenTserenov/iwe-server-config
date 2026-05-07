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
# WP-264 Ф3: PENDING-маркеры — блок коммита при незаполненных <!-- PENDING:... --> секциях

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

IWE_ROOT="${IWE_ROOT:-${IWE_WORKSPACE:-$HOME/IWE}}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-my-strategy}"
GOV_PATH="$IWE_ROOT/$GOV_REPO"
GATE_LOG="$IWE_ROOT/.claude/logs/gate_log.jsonl"
mkdir -p "$(dirname "$GATE_LOG")" 2>/dev/null || true

log_decision() {
  # log_decision <decision> <reason> <missing_csv> <errors_csv>
  local decision="$1" reason="$2" missing="$3" errors="$4"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local entry
  entry=$(jq -nc \
    --arg ts "$ts" \
    --arg sid "${SESSION_ID:-}" \
    --arg tool "${TOOL:-}" \
    --arg cmd "$(printf '%s' "${TOOL_INPUT:-}" | head -c 200)" \
    --arg dp "${DAYPLAN:-}" \
    --arg dec "$decision" \
    --arg reason "$reason" \
    --arg missing "$missing" \
    --arg errors "$errors" \
    '{ts:$ts, gate:"protocol-artifact-validate", session_id:$sid, tool:$tool,
      cmd_head:$cmd, dayplan:$dp, decision:$dec, reason:$reason,
      missing_sections:($missing|split("|")|map(select(length>0))),
      errors:($errors|split("|")|map(select(length>0)))}' 2>/dev/null || true)
  [ -n "$entry" ] && echo "$entry" >> "$GATE_LOG" 2>/dev/null || true
}

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

# Only trigger on Bash tool with git commit command
if [ "$TOOL" != "Bash" ]; then
  echo '{}'
  exit 0
fi

# Skip if command is just echoing JSON containing "git commit" (false-positive guard).
# Real git commit starts with optional `cd ... &&`, then `git add`/`git commit`.
# Echo'ed test inputs typically have `echo '{...git commit...}' | ...` — `echo '{` near start.
if echo "$TOOL_INPUT" | grep -qE "^\s*echo\s+['\"]?\{"; then
  log_decision "allow" "echo of JSON, not real commit" "" ""
  echo '{}'
  exit 0
fi

# Check if command contains git commit (but not git commit --amend or other non-standard)
if ! echo "$TOOL_INPUT" | grep -qE 'git (add.*&&.*git )?commit'; then
  echo '{}'
  exit 0
fi

# Check if we're in DS-my-strategy (protocol governance repo)
if ! echo "$TOOL_INPUT" | grep -q 'DayPlan\|day-open\|day-close\|WeekPlan'; then
  # Also check pwd context — look for staged DayPlan files
  STAGED=$(cd "$GOV_PATH" 2>/dev/null && git diff --cached --name-only 2>/dev/null || echo "")
  if ! echo "$STAGED" | grep -qE 'DayPlan|WeekPlan'; then
    log_decision "allow" "no DayPlan/WeekPlan in staged or command" "" ""
    echo '{}'
    exit 0
  fi
fi

# --- DayPlan Validation (выполняется только если DayPlan-файл существует) ---
DAYPLAN=$(ls "$GOV_PATH"/current/DayPlan\ *.md 2>/dev/null | head -1)
MISSING=()
ERRORS=()

if [ -n "$DAYPLAN" ]; then

# Required sections (parameterized — update this list when format changes)
SECTIONS=(
  "План на сегодня"
  "Календарь"
  "Здоровье"
  "IWE за ночь"
  "Наработки Scout"
  "Контент-план"
  "Разбор заметок"
  "Итоги вчера"
  "Мир"
  "Контекст недели"
  "Требует внимания"
)

for section in "${SECTIONS[@]}"; do
  if ! grep -q "$section" "$DAYPLAN"; then
    MISSING+=("$section")
  fi
done

# Check mandatory format elements

# --- Ф3 Check 1: collapsible <details> блоки ---
DETAILS_COUNT=$(grep -c '<details' "$DAYPLAN" 2>/dev/null || echo 0)
if [ "$DETAILS_COUNT" -lt 3 ]; then
  ERRORS+=("Collapsible секции (<details>) < 3 найдено: $DETAILS_COUNT. DayPlan должен иметь collapsible-структуру")
fi

# --- Ф3 Check 2: непустые обязательные секции ---
# Календарь: должна содержать хотя бы одну строку с | (таблица) или "нет событий"
CALENDAR_CONTENT=$(awk '/Календарь/,/^<\/details>/' "$DAYPLAN" 2>/dev/null | wc -l || echo 0)
if [ "$CALENDAR_CONTENT" -lt 3 ]; then
  ERRORS+=("Секция 'Календарь' пустая или слишком короткая (${CALENDAR_CONTENT} строк)")
fi

# Здоровье (бота/платформы, QA): должна содержать числа или "нет данных"
if ! awk '/Здоровье (бота|платформы)/,/^<\/details>/' "$DAYPLAN" 2>/dev/null | grep -qE '\|[[:space:]]*[0-9]|нет данных'; then
  ERRORS+=("Секция 'Здоровье' не содержит данных (таблица с числами или 'нет данных')")
fi

# Scout: должна содержать хотя бы упоминание находок или "нет находок"
if ! awk '/Наработки Scout/,/^<\/details>/' "$DAYPLAN" 2>/dev/null | grep -iqE 'наход|capture|статус|нет|find'; then
  ERRORS+=("Секция 'Наработки Scout' пустая")
fi

# --- Ф3 Check 3: формат мультипликатора ---
if ! grep -qE "~[0-9]+\.?[0-9]*x" "$DAYPLAN"; then
  ERRORS+=("Мультипликатор не найден — нужен формат '~N.Nx' в строке бюджета")
fi

# --- Ф3 Check 4 (legacy): mandatory check и бюджет ---
if ! grep -qi "mandatory" "$DAYPLAN"; then
  ERRORS+=("Mandatory check (WP-7 + контентный РП) не найден")
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

# --- WP-264 Ф3: PENDING-маркеры — блокировать коммит если есть незаполненные секции ---
PENDING_COUNT=$(grep -c '<!-- PENDING:' "$DAYPLAN" 2>/dev/null || echo 0)
if [ "$PENDING_COUNT" -gt 0 ]; then
  PENDING_LIST=$(grep -o '<!-- PENDING:[^>]*>' "$DAYPLAN" 2>/dev/null | head -5 | tr '\n' ' ' || true)
  ERRORS+=("Незаполненные PENDING-маркеры ($PENDING_COUNT шт): $PENDING_LIST — заполни перед коммитом")
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

  # Детектор (в): обязательные секции WeekPlan (5 минимальных по templates-dayplan.md Ф7)
  WP_REQUIRED=(
    "Итоги"
    "Повестка"
    "Inbox Triage"
    "План на неделю"
    "Контент-план"
  )
  for wp_section in "${WP_REQUIRED[@]}"; do
    if ! grep -q "$wp_section" "$WEEKPLAN"; then
      WP_MISSING_LIST+=("$wp_section")
    fi
  done

  if [ ${#WP_MISSING_LIST[@]} -gt 0 ] || [ ${#WP_ERRORS[@]} -gt 0 ]; then
    WP_MISSING_STR=$(IFS=', '; echo "${WP_MISSING_LIST[*]:-}")
    WP_ERRORS_STR=$(IFS=', '; echo "${WP_ERRORS[*]:-}")
    WP_MISSING_PIPE=$(IFS='|'; echo "${WP_MISSING_LIST[*]:-}")
    WP_ERRORS_PIPE=$(IFS='|'; echo "${WP_ERRORS[*]:-}")

    WP_MSG="⛔ WEEKPLAN VALIDATION FAILED."
    [ ${#WP_MISSING_LIST[@]} -gt 0 ] && WP_MSG="$WP_MSG Пропущены секции (${#WP_MISSING_LIST[@]}): $WP_MISSING_STR."
    [ ${#WP_ERRORS[@]} -gt 0 ] && WP_MSG="$WP_MSG Ошибки структуры: $WP_ERRORS_STR."
    WP_MSG="$WP_MSG Исправь WeekPlan перед коммитом."

    log_decision "block" "$WP_MSG" "$WP_MISSING_PIPE" "$WP_ERRORS_PIPE"
    jq -n --arg reason "$WP_MSG" '{"decision": "block", "reason": $reason}'
    exit 0
  fi

  log_decision "allow" "WeekPlan validation passed" "" ""
fi

# Report results
if [ ${#MISSING[@]} -gt 0 ] || [ ${#ERRORS[@]} -gt 0 ]; then
  MISSING_STR=$(printf ', %s' "${MISSING[@]}")
  MISSING_STR=${MISSING_STR:2}
  ERRORS_STR=$(printf ', %s' "${ERRORS[@]}")
  ERRORS_STR=${ERRORS_STR:2}

  MISSING_PIPE=$(IFS='|'; echo "${MISSING[*]:-}")
  ERRORS_PIPE=$(IFS='|'; echo "${ERRORS[*]:-}")

  MSG="⛔ DAYPLAN VALIDATION FAILED."
  [ ${#MISSING[@]} -gt 0 ] && MSG="$MSG Пропущены секции (${#MISSING[@]}): $MISSING_STR."
  [ ${#ERRORS[@]} -gt 0 ] && MSG="$MSG Ошибки формата/структуры: $ERRORS_STR."
  MSG="$MSG Исправь DayPlan перед коммитом."

  log_decision "block" "$MSG" "$MISSING_PIPE" "$ERRORS_PIPE"

  jq -n --arg reason "$MSG" '{"decision": "block", "reason": $reason}'
else
  log_decision "allow" "validation passed" "" ""
  cat <<'EOF'
{"additionalContext": "✅ DayPlan прошёл валидацию: секции, collapsible, непустые блоки, мультипликатор, carry-over."}
EOF
fi

exit 0
