#!/bin/bash
# check-secret skill backend (B7.7c, WP-212; WP-544 D6.8).
# Accepts a file path or inline text and reports only secret classes, counts
# and line numbers. Matched source text, secret values and content-derived
# hashes must never reach stdout, stderr or the audit log.

set -uo pipefail
umask 077
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SKILL_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(CDPATH='' cd -- "$SKILL_DIR/../.." && pwd)"
# shellcheck source=../../lib/iwe-env-bootstrap.sh
# shellcheck disable=SC1091
source "$CLAUDE_DIR/lib/iwe-env-bootstrap.sh" || exit 2

SECRET_LIB="$CLAUDE_DIR/hooks/secret-bypass-lib.sh"
if [ ! -r "$SECRET_LIB" ]; then
  printf 'check-secret unavailable: security pattern library is missing.\n' >&2
  exit 2
fi
# shellcheck source=../../hooks/secret-bypass-lib.sh
# shellcheck disable=SC1091
. "$SECRET_LIB"
if ! command -v secret_pattern_process >/dev/null 2>&1 \
  || ! command -v secret_bypass_audit_append >/dev/null 2>&1 \
  || [ ! -x "$SECRET_BYPASS_JQ" ] \
  || [ ! -x "$SECRET_BYPASS_PYTHON" ]; then
  printf 'check-secret unavailable: validated security helpers are missing.\n' >&2
  exit 2
fi

input="${*:-}"
if [ -z "$input" ]; then
  printf 'Usage: check.sh <file-path-or-text>\n' >&2
  printf '       check.sh - < file.txt\n' >&2
  exit 2
fi

if [ "$input" = "-" ]; then
  text=$(cat) || {
    printf 'check-secret unavailable: input could not be read.\n' >&2
    exit 2
  }
elif [ -f "$input" ]; then
  text=$(cat -- "$input") || {
    printf 'check-secret unavailable: input file could not be read.\n' >&2
    exit 2
  }
else
  text="$input"
fi

if ! analysis=$(printf '%s' "$text" | secret_pattern_process detect-text 2>/dev/null) \
  || ! printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -e '
      type == "object"
      and (.pattern_ids | type == "array" and all(.[]; type == "string"))
      and (.patterns | type == "array" and all(.[];
        type == "object"
        and (.pattern_id | type == "string")
        and (.count | type == "number" and . >= 1 and floor == .)
        and (.lines | type == "array" and all(.[]; type == "number" and . >= 1 and floor == .))))
      and (.match_count | type == "number" and . >= 0 and floor == .)
    ' >/dev/null 2>&1; then
  printf 'check-secret unavailable: input analysis failed closed.\n' >&2
  exit 2
fi

match_count=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.match_count')
pattern_count=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.pattern_ids | length')
input_len=${#text}
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
time_bucket=$(date -u +"%Y-%m-%dT%H:00:00Z")
decision="clean"
[ "$match_count" -gt 0 ] && decision="detected"

LOG_FILE="$IWE_ROOT/.claude/logs/check-secret.jsonl"
mkdir -p "$(dirname -- "$LOG_FILE")" 2>/dev/null || {
  printf 'check-secret unavailable: private audit directory could not be prepared.\n' >&2
  exit 2
}
# The jq program references jq variables.
# shellcheck disable=SC2016
if ! record=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -c \
    --arg ts "$ts" \
    --arg bucket "$time_bucket" \
    --arg sid "${CLAUDE_SESSION_ID:-}" \
    --arg decision "$decision" \
    --argjson input_len "$input_len" \
    '{ts:$ts,time_bucket:$bucket,hook:"check-secret",session_id:$sid,
      decision:$decision,input_len:$input_len,pattern_ids:.pattern_ids,
      match_count:.match_count}') \
  || ! secret_bypass_audit_append "$LOG_FILE" "$record"; then
  printf 'check-secret unavailable: private audit write failed closed.\n' >&2
  exit 2
fi

if [ "$match_count" -eq 0 ]; then
  printf 'OK: no secrets detected (input: %s chars)\n' "$input_len"
  exit 0
fi

printf 'SECRETS DETECTED: %s match(es), %s class(es).\n' "$match_count" "$pattern_count" >&2
printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '
  .patterns[]
  | "- \(.pattern_id): \(.count) match(es); line(s) \(.lines | map(tostring) | join(","))"
' >&2
printf 'Matched values are intentionally hidden. Do not publish the input.\n' >&2
printf 'For a real secret, follow DP.RUNBOOK.003 cascade rotation.\n' >&2
exit 1
