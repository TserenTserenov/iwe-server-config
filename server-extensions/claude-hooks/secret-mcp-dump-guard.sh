#!/bin/bash
# Secret MCP Dump Guard (B7.7d, WP-212; WP-544 D6.4/D6.8).
# Event: PreToolUse (matcher: mcp__.*)
#
# Scans every string leaf in MCP input and denies literal secrets, sensitive
# paths and known bulk-secret tools before execution. Audit records contain
# only safe pattern classes, lengths and the session identifier. Unknown or
# renamed bulk tools remain a documented boundary: MCP servers must also apply
# least-privilege response scopes.

set -uo pipefail
umask 077
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

fail_closed() {
  printf 'Secret MCP guard blocked the call because its safety envelope could not be validated.\n' >&2
  exit 2
}

HOOK_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SECRET_LIB="$HOOK_DIR/secret-bypass-lib.sh"
[ -r "$SECRET_LIB" ] || fail_closed
# shellcheck source=secret-bypass-lib.sh
# shellcheck disable=SC1091
. "$SECRET_LIB"
if ! command -v secret_bypass_check >/dev/null 2>&1 \
  || ! command -v secret_bypass_authorize >/dev/null 2>&1 \
  || ! command -v secret_bypass_audit_append >/dev/null 2>&1 \
  || [ ! -x "$SECRET_BYPASS_JQ" ] \
  || [ ! -x "$SECRET_BYPASS_PYTHON" ]; then
  fail_closed
fi

if ! input=$(cat); then
  fail_closed
fi
if ! analysis=$(printf '%s' "$input" | secret_pattern_process analyze-mcp 2>/dev/null); then
  fail_closed
fi
printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -e '
  type == "object"
  and (.applicable | type == "boolean")
  and (.session_id | type == "string" and length > 0)
  and (.tool_name | type == "string" and length > 0)
  and ((.applicable == false) or (
    (.input_length | type == "number")
    and (.pattern_ids | type == "array")
    and (.match_count | type == "number")
    and (.sensitive_path | type == "boolean")
  ))' >/dev/null 2>&1 || fail_closed

applicable=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.applicable') || fail_closed
[ "$applicable" = "true" ] || exit 0
SESSION_ID=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.session_id') || fail_closed
tool_name=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.tool_name') || fail_closed
INPUT_LENGTH=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.input_length') || fail_closed
pattern_ids=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.pattern_ids | join(",")') || fail_closed
sensitive_path=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.sensitive_path') || fail_closed

bulk_tool=false
tool_name_lower=$(printf '%s' "$tool_name" | tr '[:upper:]' '[:lower:]')
case "$tool_name_lower" in
  *list_variables*|*list_secrets*|*get_variables*|*get_secrets*|*list_env*|*dump_env*|*list_vars*|*get_env*)
    bulk_tool=true
    ;;
  *service_config*|*environment_status*|*service_metrics*|*get_config*)
    ;;
esac

violation_pattern="$pattern_ids"
if [ "$sensitive_path" = "true" ]; then
  violation_pattern="${violation_pattern:+${violation_pattern},}sensitive-path"
fi
if [ "$bulk_tool" = "true" ]; then
  violation_pattern="${violation_pattern:+${violation_pattern},}bulk-secret-tool"
fi
[ -n "$violation_pattern" ] || exit 0

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
LOG_FILE="$IWE_ROOT/.claude/logs/secret-mcp-dump-guard.jsonl"
mkdir -p "$(dirname -- "$LOG_FILE")" 2>/dev/null || true

log_decision() {
  # Never persist MCP arguments or exact tool names.
  local decision="$1" pattern="$2" ts time_bucket record
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  time_bucket=$(date -u +"%Y-%m-%dT%H:00:00Z")
  # The jq program references jq variables.
  # shellcheck disable=SC2016
  record=$("$SECRET_BYPASS_JQ" -nc \
    --arg ts "$ts" \
    --arg bucket "$time_bucket" \
    --arg sid "$SESSION_ID" \
    --arg decision "$decision" \
    --arg pattern "$pattern" \
    --argjson input_length "$INPUT_LENGTH" \
    '{ts:$ts,time_bucket:$bucket,hook:"secret-mcp-dump-guard",
      session_id:$sid,decision:$decision,pattern:$pattern,
      input_length:$input_length}') || return 1
  secret_bypass_audit_append "$LOG_FILE" "$record"
}

BYPASS_NOTICE=""
if secret_bypass_check INPUT; then
  if authorization_output=$(secret_bypass_authorize INPUT \
      log_decision "bypass-env-temporary:${SECRET_BYPASS_REMAINING}s" "$violation_pattern"); then
    printf '%s\n' "$authorization_output"
    exit 0
  fi
  SECRET_BYPASS_STATE="rejected"
  SECRET_BYPASS_REASON="audited authorization unavailable"
  BYPASS_NOTICE=$(secret_bypass_rejected_message INPUT)
elif [ "$SECRET_BYPASS_STATE" = "rejected" ]; then
  log_decision "bypass-env-rejected:$SECRET_BYPASS_REASON" "$violation_pattern" || true
  BYPASS_NOTICE=$(secret_bypass_rejected_message INPUT)
fi

reason="MCP-вызов заблокирован до выполнения: вход содержит возможный секрет, чувствительный путь либо инструмент запрашивает набор секретов (классы: ${violation_pattern}). Передавай ссылку на конкретное безопасное значение или используй его внутри сервиса. Временное исключение требует CC_ALLOW_SECRETS_INPUT=1 и CC_ALLOW_SECRETS_INPUT_UNTIL=<unix-time> не более чем на 15 минут."
log_decision "deny" "$violation_pattern" || true
# The jq program references jq variables.
# shellcheck disable=SC2016
if ! "$SECRET_BYPASS_JQ" -n \
    --arg reason "$reason" \
    --arg message "$BYPASS_NOTICE" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",
      permissionDecision:"deny",permissionDecisionReason:$reason}}
      + (if $message == "" then {} else {systemMessage:$message} end)'; then
  fail_closed
fi
exit 0
