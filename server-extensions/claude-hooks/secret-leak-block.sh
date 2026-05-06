#!/bin/bash
# Secret Leak Block Hook (B7.7a, WP-212)
# Event: PreToolUse (matcher: Bash)
# Блокирует Bash-команды содержащие плейнтекст-секреты.
# Покрывает ~85% command-driven утечек (см. WP-212 B7.7 feasibility analysis).
# НЕ покрывает: Claude-generated text без tool-use, Read файла с секретами.
#
# Bypass:
#   - env CC_ALLOW_SECRETS=1
#   - маркер `# secret-ok` в команде (для тестов паттернов)
#
# Лог решений: ~/IWE/.claude/logs/secret-leak-block.jsonl

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
LOG_FILE="$IWE_ROOT/.claude/logs/secret-leak-block.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log_decision() {
  local decision="$1" pattern="$2" cmd_head="$3"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -nc \
    --arg ts "$ts" \
    --arg sid "${CLAUDE_SESSION_ID:-}" \
    --arg dec "$decision" \
    --arg pat "$pattern" \
    --arg cmd "$cmd_head" \
    '{ts:$ts, hook:"secret-leak-block", session_id:$sid, decision:$dec, pattern:$pat, cmd_head:$cmd}' \
    >> "$LOG_FILE" 2>/dev/null || true
}

# Read JSON input
input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)
command=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Only check Bash
[ "$tool_name" != "Bash" ] && exit 0
[ -z "$command" ] && exit 0

# Bypass: env var
if [ -n "${CC_ALLOW_SECRETS:-}" ]; then
  log_decision "bypass-env" "" "$(printf '%s' "$command" | head -c 80)"
  exit 0
fi

# Bypass: explicit marker
if echo "$command" | grep -q '# secret-ok'; then
  log_decision "bypass-marker" "" "$(printf '%s' "$command" | head -c 80)"
  exit 0
fi

# Patterns (в синтаксисе grep -E)
declare -a patterns=(
  "napi_[A-Za-z0-9]{30,}|Neon API key"
  "postgresql(ql)?://[^:[:space:]]+:[^@[:space:]]{6,}@|DATABASE_URL с user:pass"
  "sk-ant-api[0-9]{2}-[A-Za-z0-9_-]{30,}|Anthropic API key"
  "gh[poshru]_[A-Za-z0-9]{30,}|GitHub token"
  "AKIA[0-9A-Z]{16}|AWS access key"
  "ust_[A-Za-z0-9]{20,}|Better Stack token"
  "[0-9]{8,10}:[A-Za-z0-9_-]{35}|Telegram bot token"
)

cmd_head=$(printf '%s' "$command" | head -c 200)

for entry in "${patterns[@]}"; do
  p="${entry%%|*}"
  label="${entry##*|}"
  if echo "$command" | grep -qE "$p"; then
    reason="Возможный секрет в Bash-команде (паттерн: $label). Если намеренно (тест/grep) — добавь '# secret-ok' в команду или запусти с CC_ALLOW_SECRETS=1. Если реальный секрет — НЕ передавай через arg, используй \$VAR из env / wrapper из ~/IWE/.secrets/."
    log_decision "deny" "$label" "$cmd_head"
    jq -n \
      --arg reason "$reason" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
    exit 0
  fi
done

log_decision "allow" "" "$cmd_head"
exit 0
