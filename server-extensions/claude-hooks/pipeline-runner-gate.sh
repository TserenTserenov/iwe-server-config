#!/bin/bash
# Pipeline Runner Gate (PreToolUse, WP-503 «Reflex-принуждение к конвейерному
# исполнителю»), зеркало close-runner-gate.sh (WP-482/484).
#
# Проблема, которую решает: agent объявляет намерение прогнать умный конвейер
# (wp-run-scheduled-tsekh1.sh) на явный список карточек РП, но затем правит их
# файлы сам через Edit/Write — заявленный механизм подменяется агентом, работа
# реальна, но не тем путём, который был анонсирован пилоту. Живой случай
# 17.08.2026 — обнаружено постфактум пилотом по пустому ledger, не агентом.
#
# Что НЕ делает: не блокирует Read/Grep/Agent-субагентов (разведка — законная
# часть работы конвейера, находки из неё передаются пилоту как очередь
# вопросов, это не подмена исполнения). Блокирует только Edit/Write карточки
# inbox/WP-N/*.md для N, заявленного в pipeline-obligation и ещё не отмеченного
# как invoked (wp-run-scheduled-tsekh1.sh реально вызван для этого N).
#
# Контракт PreToolUse hook (Claude Code):
# - Stdin: JSON {"tool_name", "tool_input", "session_id", ...}
# - Exit 0 = allow; exit 2 = block (stderr = причина, показывается LLM).

set -uo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
OBLIGATION_CLI="$IWE_ROOT/${IWE_GOVERNANCE_REPO:-DS-my-strategy}/scripts/pipeline_obligation.py"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$SESSION_ID" ] || exit 0

# --- Bash-путь: наблюдаем вызов wp-run-scheduled-tsekh1.sh <WP-N> -- отмечаем
# invoked, чтобы последующий Edit/Write того же WP-N был разрешён. ---
if [ "$TOOL_NAME" = "Bash" ]; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [ -n "$COMMAND" ] || exit 0
  if echo "$COMMAND" | grep -qE 'wp-run-scheduled-tsekh1\.sh'; then
    # Первый позиционный аргумент после имени скрипта -- WP-N (usage: <WP-N>
    # <agent> <timeout-min> ...). Формат гибкий (WP-515 или просто 515) --
    # нормализуем к голому числу для совпадения с ключом obligation.
    WP_ARG=$(echo "$COMMAND" | grep -oE 'wp-run-scheduled-tsekh1\.sh[[:space:]]+[^[:space:]]+' \
      | grep -oE '[0-9]{2,4}' | head -1)
    if [ -n "$WP_ARG" ] && [ -x "$(command -v python3)" ] && [ -f "$OBLIGATION_CLI" ]; then
      python3 "$OBLIGATION_CLI" mark-invoked --session-id "$SESSION_ID" --wp "$WP_ARG" >/dev/null 2>&1
    fi
  fi
  exit 0
fi

# --- Edit/Write-путь: блокируем правку карточки заявленного, не вызванного WP. ---
[ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "MultiEdit" ] || exit 0

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$FILE_PATH" ] || exit 0

# Ловим только карточки РП (inbox/WP-N/... или inbox/WP-N-slug.md), не любой
# файл в репозитории -- гейт не должен мешать правкам вне конвейерного скоупа.
WP_NUM=$(printf '%s' "$FILE_PATH" | grep -oE '/inbox/WP-([0-9]+)' | grep -oE '[0-9]+' | head -1)
[ -n "$WP_NUM" ] || exit 0

[ -x "$(command -v python3)" ] && [ -f "$OBLIGATION_CLI" ] || exit 0

CHECK_OUT=$(python3 "$OBLIGATION_CLI" check --session-id "$SESSION_ID" --wp "$WP_NUM" 2>/dev/null)
ACTION=$(printf '%s' "$CHECK_OUT" | jq -r '.action // "allow"' 2>/dev/null)

[ "$ACTION" = "allow" ] && exit 0

if [ "$ACTION" = "warn" ]; then
  echo "[pipeline-runner-gate] session=$SESSION_ID wp=$WP_NUM mode=warn — правка пропущена без блокировки" >&2
  exit 0
fi

cat >&2 <<EOF
🚫 Reflex-принуждение к конвейерному исполнителю (WP-503): прямая правка карточки РП-$WP_NUM в обход wp-run-scheduled-tsekh1.sh заблокирована.

В этой сессии объявлено намерение прогнать умный конвейер на список карточек,
включающий РП-$WP_NUM, но вызова wp-run-scheduled-tsekh1.sh для НЕГО не
наблюдалось.

Сначала:
  bash \$IWE_ROOT/DS-my-strategy/scripts/wp-run-scheduled-tsekh1.sh $WP_NUM <agent> <timeout-min> [--phase "..." --phase-add-dir <path>]

Если хочешь работать напрямую (не через конвейер) для ЭТОЙ карточки — скажи
пилоту явно, дождись фразы «не через конвейер»/«работай сама», гейт снимется.
EOF
exit 2
