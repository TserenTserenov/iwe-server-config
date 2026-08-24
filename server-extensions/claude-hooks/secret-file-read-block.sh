#!/bin/bash
# Secret File Read Block Hook (B7.7c, WP-212 / WP-544 D6.4)
# Event: PreToolUse (matcher: Read|Edit|MultiEdit|Grep)
#
# Denies sensitive file paths before their content reaches Claude. The one-file
# bypass is active only for a canonical existing regular file and needs three
# fields set by the pilot for no more than 900 seconds:
#   CC_ALLOW_SECRET_PATH=1
#   CC_ALLOW_SECRET_PATH_FILE=<absolute canonical file>
#   CC_ALLOW_SECRET_PATH_UNTIL=<unix-time>
# The legacy one-variable path form is rejected.
# Accepted residual risk: this hook cannot transfer its validated descriptor to
# the later Read/Edit process. A cooperating process can replace the file after
# approval, so the authorization does not pin the inode used by the tool. Only
# descriptor handoff or the Read/Edit sandbox can close that inter-process race.

set -uo pipefail
umask 077
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

security_failure() {
  printf '%s\n' 'Secret file PreToolUse guard failed to validate its input; the file operation is blocked.' >&2
  exit 2
}

HOOK_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[ -r "$HOOK_DIR/secret-bypass-lib.sh" ] || security_failure
# shellcheck source=secret-bypass-lib.sh
# shellcheck disable=SC1091
. "$HOOK_DIR/secret-bypass-lib.sh" || security_failure
[ -x "$SECRET_BYPASS_JQ" ] && [ -x "$SECRET_BYPASS_PYTHON" ] || security_failure

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
LOG_FILE="$IWE_ROOT/.claude/logs/secret-file-read-block.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
SESSION_ID=""

log_decision() {
  local decision="$1" pattern="$2" path_value="${3:-}" ts time_bucket record
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  time_bucket=$(date -u +"%Y-%m-%dT%H:00:00Z")
  # The jq program references jq variables.
  # shellcheck disable=SC2016
  record=$("$SECRET_BYPASS_JQ" -nc \
    --arg ts "$ts" \
    --arg bucket "$time_bucket" \
    --arg sid "$SESSION_ID" \
    --arg dec "$decision" \
    --arg pat "$pattern" \
    --argjson path_length "${#path_value}" \
    '{ts:$ts,time_bucket:$bucket,hook:"secret-file-read-block",
      session_id:$sid,decision:$dec,pattern:$pat,path_length:$path_length}') || return 1
  secret_bypass_audit_append "$LOG_FILE" "$record"
}

input=$(cat) || security_failure
printf '%s' "$input" | "$SECRET_BYPASS_JQ" -e '
  type == "object"
  and .hook_event_name == "PreToolUse"
  and (.session_id | type == "string" and test("\\S"))
  and (.tool_name | type == "string" and test("\\S"))
  and (.tool_input | type == "object")' >/dev/null 2>&1 || security_failure

tool_name=$(printf '%s' "$input" | "$SECRET_BYPASS_JQ" -r '.tool_name')
SESSION_ID=$(printf '%s' "$input" | "$SECRET_BYPASS_JQ" -r '.session_id')
case "$tool_name" in
  Read|Edit|MultiEdit) fp_field='.tool_input.file_path' ;;
  Grep) fp_field='.tool_input.path' ;;
  *) security_failure ;;
esac

fp_type=$(printf '%s' "$input" | "$SECRET_BYPASS_JQ" -r "$fp_field | type" 2>/dev/null) || security_failure
case "$tool_name:$fp_type" in
  Read:string|Edit:string|MultiEdit:string|Grep:string|Grep:null) ;;
  *) security_failure ;;
esac
target=$(printf '%s' "$input" | "$SECRET_BYPASS_JQ" -r "$fp_field // empty" 2>/dev/null) || security_failure
[ -n "$target" ] || {
  [ "$tool_name" = "Grep" ] && exit 0
  security_failure
}
case "$target" in
  *[![:space:]]*) ;;
  *)
    [ "$tool_name" = "Grep" ] && exit 0
    security_failure
    ;;
esac

base=$(basename "$target")
base_n=$(printf '%s' "$base" | sed -E 's/[[:space:].]+$//' | tr '[:upper:]' '[:lower:]')
target_n=$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')

case "$base_n" in
  *.example|*.sample|*.template|*.dist|*.example.*|*.sample.*)
    log_decision "allow-template" "template-exception" "$target" || true
    exit 0
    ;;
esac

matched=""
case "/$target_n/" in
  */.secrets/*) matched=".secrets/ dir" ;;
  */.railway/*) matched=".railway/ dir" ;;
esac
if [ -z "$matched" ]; then
  case "$target_n" in
    */secrets/*.yaml|*/secrets/*.yml|*/secrets/*.json|secrets/*.yaml|secrets/*.yml|secrets/*.json)
      matched="secrets/ dir (sops)"
      ;;
  esac
fi
if [ -z "$matched" ]; then
  case "$base_n" in
    .env|.env.*|*.env) matched="*.env" ;;
    *.pem|*.key|*.p12|*.pfx) matched="private-key" ;;
    *.token) matched="*.token" ;;
    id_rsa|id_rsa.*|id_ed25519|id_ed25519.*) matched="ssh-key" ;;
    *-secret.yaml|*-secret.yml|*-secret.json|*-secret.txt|*-secret.ini|*-secret.conf|secrets.yaml|secrets.yml|secrets.json|credentials.yaml|credentials.yml|credentials.json) matched="secret/creds file" ;;
    .netrc|.proxy-env|.proxy-secret) matched=".netrc/proxy" ;;
    wrangler.toml) matched="wrangler.toml" ;;
  esac
fi

EXTRA="$HOME/.iwe/secret-read-extra.deny"
if [ -z "$matched" ] && [ -f "$EXTRA" ]; then
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    case "$pat" in \#*) continue ;; esac
    # shellcheck disable=SC2254
    case "$base_n" in $pat) matched="extra-file-policy"; break ;; esac
    case "/$target_n/" in *"/$pat/"*) matched="extra-directory-policy"; break ;; esac
  done < "$EXTRA"
fi

[ -n "$matched" ] || exit 0

if secret_bypass_check INPUT; then
  if secret_bypass_authorize INPUT log_decision "emergency-override-temporary" "$matched" "$target"; then
    exit 0
  fi
  [ "$SECRET_BYPASS_STATE" = "rejected" ] || {
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="authorization helper unavailable"
  }
  BYPASS_NOTICE=$(secret_bypass_rejected_message INPUT)
elif [ "$SECRET_BYPASS_STATE" = "rejected" ]; then
  log_decision "emergency-override-rejected" "$SECRET_BYPASS_REASON" "$target" || true
  BYPASS_NOTICE=$(secret_bypass_rejected_message INPUT)
fi

if secret_path_bypass_check "$target"; then
  if secret_bypass_authorize PATH log_decision "path-allow-used" "$matched" "$target"; then
    exit 0
  fi
  [ "$SECRET_BYPASS_STATE" = "rejected" ] || {
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="authorization helper unavailable"
  }
  BYPASS_NOTICE=$(secret_bypass_rejected_message PATH)
elif [ "$SECRET_BYPASS_STATE" = "rejected" ]; then
  log_decision "path-allow-rejected" "$SECRET_BYPASS_REASON" "$target" || true
  BYPASS_NOTICE=$(secret_bypass_rejected_message PATH)
fi

reason="Чтение чувствительного файла заблокировано до попадания значения в контекст (паттерн: $matched). Используй значение через \$VAR/env или wrapper. Разовый однофайловый обход требует одновременно CC_ALLOW_SECRET_PATH=1, CC_ALLOW_SECRET_PATH_FILE=<absolute canonical existing regular file> и CC_ALLOW_SECRET_PATH_UNTIL=<unix-time> не более чем на 15 минут."
log_decision "deny" "$matched" "$target" || true
# The jq program references jq variables.
# shellcheck disable=SC2016
if ! "$SECRET_BYPASS_JQ" -n \
  --arg reason "$reason" \
  --arg message "${BYPASS_NOTICE:-}" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}
   + (if $message == "" then {} else {systemMessage:$message} end)'; then
  security_failure
fi
exit 0
