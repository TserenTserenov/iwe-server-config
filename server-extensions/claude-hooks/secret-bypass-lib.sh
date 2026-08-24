#!/bin/bash
# Shared validation for temporary secret-hook overrides (WP-544 D6.4).
# A bypass is active only when the scope flag is exactly 1 and its absolute
# expiry is in the future, no more than 15 minutes from the current check.

SECRET_BYPASS_MAX_TTL=900
SECRET_BYPASS_STATE="absent"
SECRET_BYPASS_REASON=""
SECRET_BYPASS_REMAINING=0

secret_bypass_check() {
  local scope="$1" flag_name until_name flag until now remaining

  case "$scope" in
    INPUT|OUTPUT) ;;
    *)
      SECRET_BYPASS_STATE="rejected"
      SECRET_BYPASS_REASON="unknown scope"
      return 2
      ;;
  esac

  flag_name="CC_ALLOW_SECRETS_${scope}"
  until_name="${flag_name}_UNTIL"
  flag="${!flag_name:-}"
  until="${!until_name:-}"
  SECRET_BYPASS_STATE="absent"
  SECRET_BYPASS_REASON=""
  SECRET_BYPASS_REMAINING=0

  if [ -z "$flag" ] && [ -z "$until" ]; then
    return 1
  fi
  if [ "$flag" != "1" ]; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="${flag_name} must equal 1"
    return 2
  fi
  case "$until" in
    ''|*[!0-9]*)
      SECRET_BYPASS_STATE="rejected"
      SECRET_BYPASS_REASON="${until_name} must be a Unix timestamp"
      return 2
      ;;
  esac
  if [ "${#until}" -gt 10 ]; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="${until_name} is outside the supported timestamp range"
    return 2
  fi

  now=$(date +%s)
  case "$now" in
    ''|*[!0-9]*)
      SECRET_BYPASS_STATE="rejected"
      SECRET_BYPASS_REASON="current time is unavailable"
      return 2
      ;;
  esac
  until=$((10#$until))
  now=$((10#$now))
  remaining=$((until - now))
  if [ "$remaining" -le 0 ]; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="temporary override expired"
    return 2
  fi
  if [ "$remaining" -gt "$SECRET_BYPASS_MAX_TTL" ]; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="temporary override exceeds ${SECRET_BYPASS_MAX_TTL}s"
    return 2
  fi

  SECRET_BYPASS_STATE="active"
  SECRET_BYPASS_REMAINING="$remaining"
  return 0
}

secret_bypass_active_message() {
  printf 'Temporary secret %s bypass is active for %ss more.' \
    "$1" "$SECRET_BYPASS_REMAINING"
}

secret_bypass_rejected_message() {
  printf 'Requested secret %s bypass was rejected: %s. Protection remains active.' \
    "$1" "$SECRET_BYPASS_REASON"
}

secret_bypass_audit_append() {
  # Reject devices/FIFOs/symlinks and prove that a private regular file grew.
  local log_file="$1" record="$2" before=0 after
  if [ -L "$log_file" ] || { [ -e "$log_file" ] && [ ! -f "$log_file" ]; }; then
    return 1
  fi
  if [ -e "$log_file" ]; then
    chmod 600 "$log_file" 2>/dev/null || return 1
    before=$(wc -c < "$log_file" 2>/dev/null | tr -d ' ') || return 1
  fi
  case "$before" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$record" >> "$log_file" 2>/dev/null || return 1
  chmod 600 "$log_file" 2>/dev/null || return 1
  [ -f "$log_file" ] && [ ! -L "$log_file" ] || return 1
  after=$(wc -c < "$log_file" 2>/dev/null | tr -d ' ') || return 1
  case "$after" in ''|*[!0-9]*) return 1 ;; esac
  [ "$after" -gt "$before" ]
}

secret_bypass_emit_alert() {
  local notice="$1" alert_json
  command -v jq >/dev/null 2>&1 || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  if ! alert_json=$(jq -n --arg message "$notice" '{systemMessage:$message}') \
    || [ -z "$alert_json" ] \
    || ! printf '%s' "$alert_json" | python3 -c '
import json
import sys

expected = sys.argv[1]
value = json.load(sys.stdin)
if not isinstance(value, dict) or value.get("systemMessage") != expected:
    raise SystemExit(1)
' "$notice"; then
    return 1
  fi
  printf '%s\n' "$alert_json"
}

secret_bypass_authorize() {
  # The override becomes effective only after both durable audit and a visible
  # user alert succeed. A logging/alert failure keeps the protection active.
  local scope="$1" notice
  shift

  if [ "$SECRET_BYPASS_STATE" != "active" ]; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="temporary override was not validated"
    return 2
  fi
  if [ "$#" -eq 0 ] || ! "$@"; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="audit record unavailable"
    return 2
  fi
  notice=$(secret_bypass_active_message "$scope")
  if ! secret_bypass_emit_alert "$notice"; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="user alert unavailable"
    return 2
  fi
  return 0
}

secret_bypass_self_test() {
  local now failures=0 authorize_output audit_tmp audit_file audit_link
  now=$(date +%s)

  run_case() {
    local name expected_rc expected_state actual_rc
    name="$1"
    expected_rc="$2"
    expected_state="$3"
    shift 3
    (
      unset CC_ALLOW_SECRETS_INPUT CC_ALLOW_SECRETS_INPUT_UNTIL
      eval "$*"
      secret_bypass_check INPUT
    )
    actual_rc=$?
    if [ "$actual_rc" -ne "$expected_rc" ]; then
      printf 'FAIL %s: rc=%s expected=%s\n' "$name" "$actual_rc" "$expected_rc" >&2
      failures=$((failures + 1))
      return
    fi

    unset CC_ALLOW_SECRETS_INPUT CC_ALLOW_SECRETS_INPUT_UNTIL
    eval "$*"
    secret_bypass_check INPUT >/dev/null 2>&1 || true
    if [ "$SECRET_BYPASS_STATE" != "$expected_state" ]; then
      printf 'FAIL %s: state=%s expected=%s\n' "$name" "$SECRET_BYPASS_STATE" "$expected_state" >&2
      failures=$((failures + 1))
    else
      printf 'PASS %s\n' "$name"
    fi
  }

  run_case absent 1 absent ':'
  run_case zero 2 rejected 'export CC_ALLOW_SECRETS_INPUT=0'
  run_case missing_expiry 2 rejected 'export CC_ALLOW_SECRETS_INPUT=1'
  run_case leading_zero 2 rejected 'export CC_ALLOW_SECRETS_INPUT=1 CC_ALLOW_SECRETS_INPUT_UNTIL=09'
  run_case expired 2 rejected "export CC_ALLOW_SECRETS_INPUT=1 CC_ALLOW_SECRETS_INPUT_UNTIL=$((now - 1))"
  run_case excessive 2 rejected "export CC_ALLOW_SECRETS_INPUT=1 CC_ALLOW_SECRETS_INPUT_UNTIL=$((now + SECRET_BYPASS_MAX_TTL + 1))"
  run_case valid 0 active "export CC_ALLOW_SECRETS_INPUT=1 CC_ALLOW_SECRETS_INPUT_UNTIL=$((now + 60))"

  secret_bypass_test_audit_ok() { return 0; }
  secret_bypass_test_audit_fail() { return 1; }

  SECRET_BYPASS_STATE="active"
  SECRET_BYPASS_REMAINING=60
  if authorize_output=$(secret_bypass_authorize INPUT secret_bypass_test_audit_ok) \
    && printf '%s' "$authorize_output" | jq -e '.systemMessage | length > 0' >/dev/null 2>&1; then
    printf 'PASS audited_authorization\n'
  else
    printf 'FAIL audited_authorization\n' >&2
    failures=$((failures + 1))
  fi

  SECRET_BYPASS_STATE="active"
  SECRET_BYPASS_REMAINING=60
  if secret_bypass_authorize INPUT secret_bypass_test_audit_fail >/dev/null 2>&1; then
    printf 'FAIL audit_failure_rejected\n' >&2
    failures=$((failures + 1))
  elif [ "$SECRET_BYPASS_STATE" = "rejected" ]; then
    printf 'PASS audit_failure_rejected\n'
  else
    printf 'FAIL audit_failure_rejected: state=%s\n' "$SECRET_BYPASS_STATE" >&2
    failures=$((failures + 1))
  fi

  jq() { return 0; }
  SECRET_BYPASS_STATE="active"
  SECRET_BYPASS_REMAINING=60
  if secret_bypass_authorize INPUT secret_bypass_test_audit_ok >/dev/null 2>&1; then
    printf 'FAIL alert_failure_rejected\n' >&2
    failures=$((failures + 1))
  elif [ "$SECRET_BYPASS_STATE" = "rejected" ]; then
    printf 'PASS alert_failure_rejected\n'
  else
    printf 'FAIL alert_failure_rejected: state=%s\n' "$SECRET_BYPASS_STATE" >&2
    failures=$((failures + 1))
  fi
  unset -f jq

  audit_tmp=$(mktemp -d "${TMPDIR:-/tmp}/secret-bypass-audit.XXXXXX") || return 1
  audit_file="$audit_tmp/audit.jsonl"
  audit_link="$audit_tmp/audit-link.jsonl"
  if secret_bypass_audit_append "$audit_file" '{"test":true}' \
    && [ "$(stat -f '%Lp' "$audit_file" 2>/dev/null)" = "600" ] \
    && grep -q '"test":true' "$audit_file"; then
    printf 'PASS durable_private_audit\n'
  else
    printf 'FAIL durable_private_audit\n' >&2
    failures=$((failures + 1))
  fi
  ln -s /dev/null "$audit_link"
  if secret_bypass_audit_append "$audit_link" '{"test":true}'; then
    printf 'FAIL audit_symlink_rejected\n' >&2
    failures=$((failures + 1))
  else
    printf 'PASS audit_symlink_rejected\n'
  fi
  rm -rf "$audit_tmp"

  [ "$failures" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --self-test) secret_bypass_self_test ;;
    *) printf 'usage: %s --self-test\n' "$0" >&2; exit 2 ;;
  esac
fi
