#!/bin/bash
# Secret Leak Redact Hook (B7.7b, WP-212)
# Event: PostToolUse (matcher: Bash|Read)
# Заменяет плейнтекст-секреты в tool output на [REDACTED-<class>] перед тем как Claude увидит.
# ОГРАНИЧЕНИЕ: оригинал остаётся в conversation transcript. Hook защищает от
# re-использования Claude'ом в собственных ответах, но не от full forensics.
#
# Bypass: env CC_ALLOW_SECRETS=1
# Лог: ~/IWE/.claude/logs/secret-leak-redact.jsonl

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
LOG_FILE="$IWE_ROOT/.claude/logs/secret-leak-redact.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

input=$(cat)

# Bypass
if [ -n "${CC_ALLOW_SECRETS:-}" ]; then
  exit 0
fi

# Извлечение output — пробуем оба возможных пути (схема Claude Code варьируется)
tool_name=$(echo "$input" | jq -r '.tool_name // .tool // empty' 2>/dev/null)
[ -z "$tool_name" ] && exit 0

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
[ -z "$tool_output" ] && exit 0

# Паттерны (sed-формат, basic regex для совместимости BSD/GNU)
# Используем только regex который не разрушит non-secret content
redacted=$(printf '%s' "$tool_output" | sed -E \
  -e 's/napi_[A-Za-z0-9]{30,}/[REDACTED-NEON-KEY]/g' \
  -e 's/postgresql(ql)?:\/\/[^:[:space:]]+:[^@[:space:]]{6,}@/postgresql:\/\/[REDACTED-USER]:[REDACTED-PASS]@/g' \
  -e 's/sk-ant-api[0-9]{2}-[A-Za-z0-9_-]{30,}/[REDACTED-ANTHROPIC-KEY]/g' \
  -e 's/gh[poshru]_[A-Za-z0-9]{30,}/[REDACTED-GITHUB-TOKEN]/g' \
  -e 's/AKIA[0-9A-Z]{16}/[REDACTED-AWS-KEY]/g' \
  -e 's/ust_[A-Za-z0-9]{20,}/[REDACTED-BETTERSTACK]/g' \
  -e 's/[0-9]{8,10}:[A-Za-z0-9_-]{35}/[REDACTED-TG-BOT]/g' \
  )

# Если ничего не изменилось — выход без модификации (минимизируем оверхед)
if [ "$redacted" = "$tool_output" ]; then
  exit 0
fi

# Лог факта редакции (без значений)
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq -nc \
  --arg ts "$ts" \
  --arg sid "${CLAUDE_SESSION_ID:-}" \
  --arg tool "$tool_name" \
  --arg orig_len "${#tool_output}" \
  --arg new_len "${#redacted}" \
  '{ts:$ts, hook:"secret-leak-redact", session_id:$sid, tool:$tool, original_len:($orig_len|tonumber), redacted_len:($new_len|tonumber), action:"redacted"}' \
  >> "$LOG_FILE" 2>/dev/null || true

# Возврат модифицированного output
jq -n \
  --arg out "$redacted" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: $out}}'

exit 0
