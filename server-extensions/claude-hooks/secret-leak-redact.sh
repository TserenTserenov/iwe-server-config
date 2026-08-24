#!/bin/bash
# Secret Leak Redact Hook (B7.7b, WP-212 / WP-544 D6.8)
# Event: PostToolUse (matcher: Bash|Read)
#
# Replaces string leaves inside Bash, Read and MCP tool_response values and
# preserves the original JSON type through updatedToolOutput. This only changes
# what Claude receives after the tool ran. It does not undo command effects or
# guarantee removal from shell history, telemetry or the original transcript.
# Prevention remains the responsibility of PreToolUse and the OS sandbox.
#
# Temporary output bypass:
#   CC_ALLOW_SECRETS_OUTPUT=1
#   CC_ALLOW_SECRETS_OUTPUT_UNTIL=<unix-time, no more than 900s ahead>

set -uo pipefail
umask 077
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

security_warning() {
  printf '%s\n' 'Secret PostToolUse guard could not validate or redact the structured tool response. The tool already ran; treat its output as potentially exposed.' >&2
  exit 2
}

HOOK_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[ -r "$HOOK_DIR/secret-bypass-lib.sh" ] || security_warning
# shellcheck source=secret-bypass-lib.sh
# shellcheck disable=SC1091
. "$HOOK_DIR/secret-bypass-lib.sh" || security_warning
[ -x "$SECRET_BYPASS_JQ" ] && [ -x "$SECRET_BYPASS_PYTHON" ] || security_warning

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
LOG_FILE="$IWE_ROOT/.claude/logs/secret-leak-redact.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
SESSION_ID=""

append_record() {
  local record="$1"
  secret_bypass_audit_append "$LOG_FILE" "$record"
}

# Called indirectly by secret_bypass_authorize.
# shellcheck disable=SC2329
log_bypass_decision() {
  local action="$1" remaining="$2" ts time_bucket record
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  time_bucket=$(date -u +"%Y-%m-%dT%H:00:00Z")
  # The jq program references jq variables.
  # shellcheck disable=SC2016
  record=$("$SECRET_BYPASS_JQ" -nc \
    --arg ts "$ts" \
    --arg bucket "$time_bucket" \
    --arg sid "$SESSION_ID" \
    --arg action "$action" \
    --arg remaining "$remaining" \
    '{ts:$ts,time_bucket:$bucket,hook:"secret-leak-redact",
      session_id:$sid,action:$action,remaining_seconds:($remaining|tonumber),
      warn:"output was not redacted; treat any secret as exposed"}') || return 1
  append_record "$record"
}

input=$(cat) || security_warning
analysis=$(printf '%s' "$input" | secret_pattern_process redact-envelope 2>/dev/null) || security_warning
printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -e '
  type == "object"
  and (.session_id | type == "string" and length > 0)
  and (.tool_name == "Bash" or .tool_name == "Read" or (.tool_name | startswith("mcp__")))
  and has("updated_tool_output")
  and (.pattern_ids | type == "array")
  and (.redaction_count | type == "number")
  and (.original_len | type == "number")
  and (.redacted_len | type == "number")' >/dev/null 2>&1 || security_warning

SESSION_ID=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.session_id')
tool_name=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.tool_name')
redaction_count=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.redaction_count')

if secret_bypass_check OUTPUT; then
  if secret_bypass_authorize OUTPUT log_bypass_decision "bypass-CC_ALLOW_SECRETS_OUTPUT-temporary" "$SECRET_BYPASS_REMAINING"; then
    exit 0
  fi
  [ "$SECRET_BYPASS_STATE" = "rejected" ] || {
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="authorization helper unavailable"
  }
  BYPASS_NOTICE=$(secret_bypass_rejected_message OUTPUT)
elif [ "$SECRET_BYPASS_STATE" = "rejected" ]; then
  BYPASS_NOTICE=$(secret_bypass_rejected_message OUTPUT)
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  time_bucket=$(date -u +"%Y-%m-%dT%H:00:00Z")
  # The jq program references jq variables.
  # shellcheck disable=SC2016
  record=$("$SECRET_BYPASS_JQ" -nc \
    --arg ts "$ts" --arg bucket "$time_bucket" --arg sid "$SESSION_ID" --arg reason "$SECRET_BYPASS_REASON" \
    '{ts:$ts,time_bucket:$bucket,hook:"secret-leak-redact",
      session_id:$sid,action:"bypass-rejected",reason:$reason}') || record=""
  [ -n "$record" ] && append_record "$record" || true
fi

if [ "$redaction_count" -eq 0 ]; then
  # The jq program references jq variables.
  # shellcheck disable=SC2016
  if [ -n "${BYPASS_NOTICE:-}" ] \
    && ! "$SECRET_BYPASS_JQ" -n --arg message "$BYPASS_NOTICE" '{systemMessage:$message}'; then
    security_warning
  fi
  exit 0
fi

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
time_bucket=$(date -u +"%Y-%m-%dT%H:00:00Z")
# The jq program references jq variables.
# shellcheck disable=SC2016
record=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -c \
  --arg ts "$ts" \
  --arg bucket "$time_bucket" \
  --arg sid "$SESSION_ID" \
  --arg tool "$tool_name" \
  '{ts:$ts,time_bucket:$bucket,hook:"secret-leak-redact",session_id:$sid,
    tool:$tool,original_len:.original_len,redacted_len:.redacted_len,
    action:(if .redaction_count >= 3 then "bulk-redacted" else "redacted" end),
    redaction_count:.redaction_count,pattern_ids:.pattern_ids}') || record=""
[ -n "$record" ] && append_record "$record" || true

# The jq program references jq variables.
# shellcheck disable=SC2016
if ! printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" \
  --arg message "${BYPASS_NOTICE:-}" \
  '. as $r
   | {hookSpecificOutput:
        ({hookEventName:"PostToolUse", updatedToolOutput:$r.updated_tool_output}
         + (if $r.redaction_count >= 3
            then {additionalContext:("Secret output guard redacted " + ($r.redaction_count|tostring) + " values. Treat the originals as exposed and rotate them under DP.RUNBOOK.003.")}
            else {} end))}
     + (if $message == "" then {} else {systemMessage:$message} end)'; then
  security_warning
fi

exit 0
