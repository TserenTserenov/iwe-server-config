#!/bin/bash
# Secret MCP Dump Guard (B7.7d, WP-212)
# Event: PreToolUse (matcher: mcp__.*)
# Блокирует MCP-инструменты, вываливающие ВЕСЬ набор переменных/секретов разом.
#
# Зачем: повторяющаяся утечка — агент вызывает «покажи все переменные» (Railway
# list_variables), чтобы взять 2 строки, и в контекст падает весь живой набор
# ключей (YooKassa live, Anthropic, GitHub, пароли БД…). Затирание (B7.7b) маскирует
# известные форматы, но (а) срабатывает PostToolUse — оригинал уже в transcript,
# (б) не ловит неизвестные форматы. Правильный фикс — НЕ тянуть весь список.
#
# Поведение: DENY известных bulk-secret инструментов. Bypass — CC_ALLOW_SECRETS=1
# (осознанное решение, когда список действительно нужен). Лог.
#
# Лог: ~/IWE/.claude/logs/secret-mcp-dump-guard.jsonl
# see: WP-212 B7.7d, AR.111, peer-session 2026-06-05-17

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
LOG_FILE="$IWE_ROOT/.claude/logs/secret-mcp-dump-guard.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log_decision() {
  local decision="$1" tool="$2"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -nc --arg ts "$ts" --arg sid "${CLAUDE_SESSION_ID:-}" --arg dec "$decision" --arg tool "$tool" \
    '{ts:$ts, hook:"secret-mcp-dump-guard", session_id:$sid, decision:$dec, tool:$tool}' \
    >> "$LOG_FILE" 2>/dev/null || true
}

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)

# Только MCP-инструменты
case "$tool_name" in mcp__*) ;; *) exit 0 ;; esac

# Денилист bulk-secret инструментов (регистронезависимо).
# Ловим: list_variables / list_secrets / get_variables / get_secrets / list_env / dump_env.
tn=$(printf '%s' "$tool_name" | tr 'A-Z' 'a-z')
case "$tn" in
  *list_variables*|*list_secrets*|*get_variables*|*get_secrets*|*list_env*|*dump_env*|*list_vars*|*get_env*)
    ;;
  *service_config*|*environment_status*|*service_metrics*|*get_config*)  # конфиг-дамперы возвращают секреты (cold-review H5)
    ;;
  *) exit 0 ;;  # не bulk-secret инструмент — пропускаем
esac

# Bypass: осознанный override пилота/агента
if [ "${CC_ALLOW_SECRETS:-}" = "1" ]; then
  log_decision "bypass-env" "$tool_name"
  exit 0
fi

reason="Инструмент ${tool_name} возвращает ВЕСЬ набор переменных/секретов разом — живые ключи (платёжный, Anthropic, токены, пароли БД) попадут в контекст и в transcript Anthropic. Затирание это не гарантирует (срабатывает поздно + не ловит неизвестные форматы). Возьми нужное значение точечно (по имени конкретной переменной) или используй его через окружение сервиса, не вытягивая список. Если список действительно нужен целиком — запусти с CC_ALLOW_SECRETS=1 (осознанно)."
log_decision "deny" "$tool_name"
jq -n --arg reason "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
exit 0
