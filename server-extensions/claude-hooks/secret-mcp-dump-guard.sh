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
# Поведение: DENY известных bulk-secret инструментов. Bypass — CC_ALLOW_SECRETS_INPUT=1
# вместе с CC_ALLOW_SECRETS_INPUT_UNTIL=<unix-time> максимум на 15 минут
# (осознанное решение, когда список действительно нужен; переименовано из
# CC_ALLOW_SECRETS I10/WP-500 2026-07-29 — единая семантика с secret-leak-block.sh:
# этот флаг разрешает ВЫЗОВ инструмента, вывод отдельно маскирует secret-leak-redact.sh
# под CC_ALLOW_SECRETS_OUTPUT). Лог.
#
# Лог: ~/IWE/.claude/logs/secret-mcp-dump-guard.jsonl
# see: WP-212 B7.7d, AR.111, peer-session 2026-06-05-17

set -uo pipefail
umask 077
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

HOOK_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [ -r "$HOOK_DIR/secret-bypass-lib.sh" ]; then
  # shellcheck source=secret-bypass-lib.sh
  # Resolved next to this hook at runtime.
  # shellcheck disable=SC1091
  . "$HOOK_DIR/secret-bypass-lib.sh"
fi

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
LOG_FILE="$IWE_ROOT/.claude/logs/secret-mcp-dump-guard.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log_decision() {
  local decision="$1" tool="$2"
  local ts record json_cmd; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  json_cmd="${SECRET_BYPASS_JQ:-jq}"
  # The jq program references jq variables.
  # shellcheck disable=SC2016
  record=$("$json_cmd" -nc --arg ts "$ts" --arg sid "${CLAUDE_SESSION_ID:-}" --arg dec "$decision" --arg tool "$tool" \
    '{ts:$ts, hook:"secret-mcp-dump-guard", session_id:$sid, decision:$dec, tool:$tool}') || return 1
  if command -v secret_bypass_audit_append >/dev/null 2>&1; then
    secret_bypass_audit_append "$LOG_FILE" "$record"
  else
    printf '%s\n' "$record" >> "$LOG_FILE" 2>/dev/null
  fi
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

# Bypass: осознанный короткий override пилота.
if command -v secret_bypass_check >/dev/null 2>&1; then
  if secret_bypass_check INPUT; then
    if command -v secret_bypass_authorize >/dev/null 2>&1 \
      && secret_bypass_authorize INPUT log_decision "bypass-env-temporary:${SECRET_BYPASS_REMAINING}s" "$tool_name"; then
      exit 0
    fi
    if [ "$SECRET_BYPASS_STATE" != "rejected" ]; then
      SECRET_BYPASS_STATE="rejected"
      SECRET_BYPASS_REASON="authorization helper unavailable"
    fi
    BYPASS_NOTICE=$(secret_bypass_rejected_message INPUT)
  elif [ "$SECRET_BYPASS_STATE" = "rejected" ]; then
    log_decision "bypass-env-rejected:$SECRET_BYPASS_REASON" "$tool_name"
    BYPASS_NOTICE=$(secret_bypass_rejected_message INPUT)
  fi
elif [ -n "${CC_ALLOW_SECRETS_INPUT:-}${CC_ALLOW_SECRETS_INPUT_UNTIL:-}" ]; then
  log_decision "bypass-env-rejected:validator-unavailable" "$tool_name"
  BYPASS_NOTICE="Requested secret INPUT bypass was rejected: validator unavailable. Protection remains active."
fi

reason="Инструмент ${tool_name} возвращает ВЕСЬ набор переменных/секретов разом — живые ключи (платёжный, Anthropic, токены, пароли БД) попадут в контекст и в transcript Anthropic. Затирание это не гарантирует (срабатывает поздно + не ловит неизвестные форматы). Возьми нужное значение точечно (по имени конкретной переменной) или используй его через окружение сервиса, не вытягивая список. Если список действительно нужен целиком — запусти с CC_ALLOW_SECRETS_INPUT=1 вместе с CC_ALLOW_SECRETS_INPUT_UNTIL=<unix-time> максимум на 15 минут (осознанно)."
log_decision "deny" "$tool_name"
jq -n --arg reason "$reason" --arg message "${BYPASS_NOTICE:-}" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}
   + (if $message == "" then {} else {systemMessage:$message} end)'
exit 0
