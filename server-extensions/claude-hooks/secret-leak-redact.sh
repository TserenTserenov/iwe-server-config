#!/bin/bash
# Secret Leak Redact Hook (B7.7b, WP-212)
# Event: PostToolUse (matcher: Bash|Read)
# Заменяет плейнтекст-секреты в tool output на [REDACTED-<class>] перед тем как Claude увидит.
# ОГРАНИЧЕНИЕ: оригинал остаётся в conversation transcript. Hook защищает от
# re-использования Claude'ом в собственных ответах, но не от full forensics.
#
# Bypass: env CC_ALLOW_SECRETS_OUTPUT=1 + CC_ALLOW_SECRETS_OUTPUT_UNTIL=<unix-time>
# (не более 15 минут; отдельно от CC_ALLOW_SECRETS_INPUT в
# secret-leak-block.sh — I10, WP-500, 2026-07-29). Живой инцидент: до разделения
# один общий флаг разрешал выполнение команды И одновременно снимал маскирование
# её вывода — 3 живые утечки пароля прошли через незащищённый вывод, пока флаг
# стоял ради одной легитимной ротации. Маскирование вывода остаётся включено по
# умолчанию, даже когда пилот разрешил ввод команды — это отдельное решение.
# Лог: ~/IWE/.claude/logs/secret-leak-redact.jsonl

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
LOG_FILE="$IWE_ROOT/.claude/logs/secret-leak-redact.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

input=$(cat)

# Called indirectly by secret_bypass_authorize.
# shellcheck disable=SC2329
log_bypass_decision() {
  local action="$1" remaining="$2" ts record json_cmd
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  json_cmd="${SECRET_BYPASS_JQ:-jq}"
  # The jq program references jq variables.
  # shellcheck disable=SC2016
  record=$("$json_cmd" -nc --arg ts "$ts" --arg sid "${CLAUDE_SESSION_ID:-}" --arg action "$action" --arg remaining "$remaining" \
    '{ts:$ts, hook:"secret-leak-redact", session_id:$sid, action:$action, remaining_seconds:($remaining|tonumber), warn:"вывод НЕ маскирован — все секреты в нём считать скомпрометированными, ротация по DP.RUNBOOK.003"}') || return 1
  if command -v secret_bypass_audit_append >/dev/null 2>&1; then
    secret_bypass_audit_append "$LOG_FILE" "$record"
  else
    printf '%s\n' "$record" >> "$LOG_FILE" 2>/dev/null
  fi
}

# Bypass — только короткий и валидный; каждое использование видно и записано.
if command -v secret_bypass_check >/dev/null 2>&1 && secret_bypass_check OUTPUT; then
  if command -v secret_bypass_authorize >/dev/null 2>&1 \
    && secret_bypass_authorize OUTPUT log_bypass_decision "bypass-CC_ALLOW_SECRETS_OUTPUT-temporary" "$SECRET_BYPASS_REMAINING"; then
    exit 0
  fi
  if [ "$SECRET_BYPASS_STATE" != "rejected" ]; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="authorization helper unavailable"
  fi
  BYPASS_NOTICE=$(secret_bypass_rejected_message OUTPUT)
fi
if [ "${SECRET_BYPASS_STATE:-absent}" = "rejected" ]; then
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -nc --arg ts "$ts" --arg sid "${CLAUDE_SESSION_ID:-}" --arg reason "$SECRET_BYPASS_REASON" \
    '{ts:$ts, hook:"secret-leak-redact", session_id:$sid, action:"bypass-rejected", reason:$reason}' \
    >> "$LOG_FILE" 2>/dev/null || true
  BYPASS_NOTICE=$(secret_bypass_rejected_message OUTPUT)
elif ! command -v secret_bypass_check >/dev/null 2>&1 && [ -n "${CC_ALLOW_SECRETS_OUTPUT:-}${CC_ALLOW_SECRETS_OUTPUT_UNTIL:-}" ]; then
  BYPASS_NOTICE="Requested secret OUTPUT bypass was rejected: validator unavailable. Protection remains active."
fi

# Извлечение output — пробуем оба возможных пути (схема Claude Code варьируется)
tool_name=$(echo "$input" | jq -r '.tool_name // .tool // empty' 2>/dev/null)
if [ -z "$tool_name" ]; then
  [ -n "${BYPASS_NOTICE:-}" ] && jq -n --arg message "$BYPASS_NOTICE" '{systemMessage:$message}'
  exit 0
fi

# Кандидаты-пути для tool output (разные форматы в разных версиях):
# Bash: .tool_response.stdout / .tool_response.output / .toolResult.content
# Read: .tool_response.content / .toolResult.content[0].text
tool_output=""
for path in '.tool_response.stdout' '.tool_response.output' '.tool_response.content' '.toolResult.content[0].text' '.toolResult.content' '.tool_response'; do
  candidate=$(echo "$input" | jq -r "$path // empty" 2>/dev/null)
  if [ -n "$candidate" ] && [ "$candidate" != "null" ]; then
    tool_output="$candidate"
    break
  fi
done

# Если output пустой — нечего редактировать
if [ -z "$tool_output" ]; then
  [ -n "${BYPASS_NOTICE:-}" ] && jq -n --arg message "$BYPASS_NOTICE" '{systemMessage:$message}'
  exit 0
fi

# Паттерны (sed-формат, basic regex для совместимости BSD/GNU)
# Используем только regex который не разрушит non-secret content
redacted=$(printf '%s' "$tool_output" | sed -E \
  -e 's/napi_[A-Za-z0-9]{30,}/[REDACTED-NEON-KEY]/g' \
  -e 's/postgresql(ql)?:\/\/[^:[:space:]]+:[^@[:space:]]{6,}@/postgresql:\/\/[REDACTED-USER]:[REDACTED-PASS]@/g' \
  -e 's/sk-ant-api[0-9]{2}-[A-Za-z0-9_-]{30,}/[REDACTED-ANTHROPIC-KEY]/g' \
  -e 's/sk-[A-Za-z0-9]{20,}/[REDACTED-OPENAI-KEY]/g' \
  -e 's/(live|test)_[A-Za-z0-9_-]{30,}/[REDACTED-YOOKASSA-KEY]/g' \
  -e 's/gh[poshru]_[A-Za-z0-9]{30,}/[REDACTED-GITHUB-TOKEN]/g' \
  -e 's/AKIA[0-9A-Z]{16}/[REDACTED-AWS-KEY]/g' \
  -e 's/AIza[0-9A-Za-z_-]{35}/[REDACTED-GOOGLE-KEY]/g' \
  -e 's/ust_[A-Za-z0-9]{20,}/[REDACTED-BETTERSTACK]/g' \
  -e 's/eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/[REDACTED-JWT]/g' \
  -e 's/[0-9]{8,10}:[A-Za-z0-9_-]{35}/[REDACTED-TG-BOT]/g' \
  )

# Если ничего не изменилось — выход без модификации (минимизируем оверхед)
if [ "$redacted" = "$tool_output" ]; then
  [ -n "${BYPASS_NOTICE:-}" ] && jq -n --arg message "$BYPASS_NOTICE" '{systemMessage:$message}'
  exit 0
fi

# === Детектор массового вывода (Гермес 2026-06-05): ловим по СОДЕРЖИМОМУ, а не по фразе/команде. ===
# Любой вывод (shell `railway variables`, MCP-дамп, чтение файла) с ≥3 секретами = bulk-утечка.
# дельта: новые маркеры минус пред-существующие в исходнике (cold-review M4 — не считать литералы из текста)
new_markers=$(printf '%s' "$redacted" | grep -o '\[REDACTED-' | wc -l | tr -d ' ')
pre_markers=$(printf '%s' "$tool_output" | grep -o '\[REDACTED-' | wc -l | tr -d ' ')
bulk_count=$(( new_markers - pre_markers ))
warn_prefix=""
action="redacted"
if [ "${bulk_count:-0}" -ge 3 ]; then
  action="bulk-redacted"
  warn_prefix="⚠️ МАССОВЫЙ ВЫВОД СЕКРЕТОВ: замаскировано $bulk_count ключ(ей) в одном ответе. Эти секреты считать СКОМПРОМЕТИРОВАННЫМИ → ротация по DP.RUNBOOK.003. Не запрашивай весь список переменных — бери значения точечно (по одному имени).

"
fi

# Лог факта редакции (без значений; для bulk — со счётчиком)
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq -nc \
  --arg ts "$ts" \
  --arg sid "${CLAUDE_SESSION_ID:-}" \
  --arg tool "$tool_name" \
  --arg orig_len "${#tool_output}" \
  --arg new_len "${#redacted}" \
  --arg act "$action" \
  --arg bulk "$bulk_count" \
  '{ts:$ts, hook:"secret-leak-redact", session_id:$sid, tool:$tool, original_len:($orig_len|tonumber), redacted_len:($new_len|tonumber), action:$act, redaction_count:($bulk|tonumber)}' \
  >> "$LOG_FILE" 2>/dev/null || true

# Возврат модифицированного output (+ предупреждение при bulk)
jq -n \
  --arg out "${warn_prefix}${redacted}" \
  --arg message "${BYPASS_NOTICE:-}" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: $out}}
   + (if $message == "" then {} else {systemMessage:$message} end)'

exit 0
