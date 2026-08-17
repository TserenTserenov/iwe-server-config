#!/bin/bash
# Pipeline Runner Gate (PreToolUse, WP-503 «Reflex-принуждение к конвейерному
# исполнителю»), зеркало close-runner-gate.sh (WP-482/484).
#
# Проблема, которую решает: agent объявляет намерение прогнать умный конвейер
# на явный список карточек РП, но затем правит их файлы сам через Edit/Write —
# заявленный механизм подменяется агентом, работа реальна, но не тем путём,
# который был анонсирован пилоту. Живой случай 17.08.2026 — обнаружено
# постфактум пилотом по пустому ledger, не агентом.
#
# Два разных легитимных пути «конвейер реально вызван» (найдено ПОСЛЕ первой
# версии этого гейта, 17.08.2026, параллельная сессия с пилотом): batch-режим
# на явный произвольный список карточек в коде НЕ существует ни для одного
# боевого скрипта (wp-pool-cascade.sh/wp-pool-tiebreak.sh/wp-run-scheduled-
# tsekh1.sh — все принимают либо один WP-N за вызов, либо весь портфель через
# pool:true-фильтр). Единственный честный способ «прогнать конвейер по списку»
# — вызвать нужный скрипт по одному разу на каждую карточку:
#   - wp-sync-bundle.sh <WP-N> — актуализация контекста (детерминированный
#     sync-bundle, тот же путь, что WP Gate Шаг 3a; см. protocol-open.md)
#   - wp-run-scheduled-tsekh1.sh <WP-N> — реальное headless-исполнение фазы
# Оба засчитываются как «invoked» для этого WP-N — гейт не навязывает, какой
# из двух нужен для конкретной карточки, только требует, чтобы ХОТЯ БЫ один
# реально прозвучал перед прямой правкой файла.
#
# Что НЕ делает: не блокирует Read/Grep/Agent-субагентов (разведка — законная
# часть работы конвейера, находки из неё передаются пилоту как очередь
# вопросов, это не подмена исполнения). Блокирует только Edit/Write карточки
# inbox/WP-N/*.md для N, заявленного в pipeline-obligation и ещё не отмеченного
# как invoked (один из двух скриптов выше реально вызван для этого N).
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

# --- Bash-путь: наблюдаем вызов ЛЮБОГО из двух легитимных скриптов на <WP-N>
# -- отмечаем invoked, чтобы последующий Edit/Write того же WP-N был разрешён.
# Оба принимают WP-N (или голое число) первым позиционным аргументом сразу
# после имени скрипта -- один и тот же паттерн извлечения номера подходит
# обоим, различается только имя скрипта в regex. ---
if [ "$TOOL_NAME" = "Bash" ]; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [ -n "$COMMAND" ] || exit 0
  INVOKED_SCRIPT_RE='wp-run-scheduled-tsekh1\.sh|wp-sync-bundle\.sh'
  if echo "$COMMAND" | grep -qE "$INVOKED_SCRIPT_RE"; then
    WP_ARG=$(echo "$COMMAND" | grep -oE "($INVOKED_SCRIPT_RE)[[:space:]]+[^[:space:]]+" \
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
🚫 Reflex-принуждение к конвейерному исполнителю (WP-503): прямая правка карточки РП-$WP_NUM в обход конвейера заблокирована.

В этой сессии объявлено намерение прогнать умный конвейер на список карточек,
включающий РП-$WP_NUM, но ни один из двух легитимных скриптов для НЕГО не
наблюдался. Явного batch-режима на произвольный список номеров в коде нет —
честный путь — вызвать один из них по одному разу на эту карточку:

  bash \$IWE_ROOT/.claude/scripts/wp-sync-bundle.sh $WP_NUM
    (актуализация контекста — детерминированный sync, без LLM-вызова)

  bash \$IWE_ROOT/DS-my-strategy/scripts/wp-run-scheduled-tsekh1.sh $WP_NUM <agent> <timeout-min> [--phase "..." --phase-add-dir <path>]
    (реальное headless-исполнение фазы)

Если хочешь работать напрямую (не через конвейер) для ЭТОЙ карточки — скажи
пилоту явно, дождись фразы «не через конвейер»/«работай сама», гейт снимется.
EOF
exit 2
