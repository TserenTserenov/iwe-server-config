#!/usr/bin/env bash
# Source from Claude Code ledger hooks after INPUT has been read. Sets the
# writer/date for this exact native session; never trusts a global queue env.

ledger_route_configure() {  # $1=hook JSON, $2=workspace, $3=governance repo name
  local input="$1" root="$2" gov="$3" payload_id env_id helper route rc
  LEDGER_ROUTE_OWN=false
  LEDGER_ROUTE_ROOT="$root"
  LEDGER_ROUTE_SESSION_ID=""
  LEDGER_ROUTE_DIR=""
  LEDGER_ROUTE_DATE="$(date +%F)"
  LEDGER_ROUTE_SCRIPT="$root/$gov/scripts/ledger-append.sh"

  payload_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || return 5
  env_id="${CLAUDE_CODE_SESSION_ID:-}"
  if [ -n "$payload_id" ] && [ -n "$env_id" ] && [ "$payload_id" != "$env_id" ]; then
    return 5
  fi
  LEDGER_ROUTE_SESSION_ID="${payload_id:-$env_id}"
  if [ -n "$LEDGER_ROUTE_SESSION_ID" ] &&
     ! [[ "$LEDGER_ROUTE_SESSION_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$ ]]; then
    return 5
  fi
  helper="$root/.iwe-runtime/day-close-ledger-route.py"
  if [ ! -f "$helper" ] || [ -L "$helper" ]; then
    [ ! -e "$root/.iwe-runtime/day-close-interactive.vars" ] &&
      [ ! -d "$root/.iwe-runtime/day-close-ledger/receipts" ] && return 10
    return 5
  fi
  if [ -z "$LEDGER_ROUTE_SESSION_ID" ]; then
    [ ! -e "$root/.iwe-runtime/day-close-interactive.vars" ] &&
      [ ! -d "$root/.iwe-runtime/day-close-ledger/receipts" ] && return 10
    return 5
  fi
  route=$(IWE_ROOT="$root" python3 "$helper" resolve --runtime claude-code \
    --session-id "$LEDGER_ROUTE_SESSION_ID")
  rc=$?
  if [ "$rc" -eq 10 ] && [ -f "$root/.iwe-runtime/day-close-interactive.vars" ] &&
     grep -Fxq "export DAY_CLOSE_NATIVE_RUNTIME=claude-code DAY_CLOSE_NATIVE_SESSION_ID=$LEDGER_ROUTE_SESSION_ID" \
       "$root/.iwe-runtime/day-close-interactive.vars"; then
    return 5
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  LEDGER_ROUTE_DIR=$(printf '%s' "$route" | jq -er '.queue') || return 5
  LEDGER_ROUTE_DATE=$(printf '%s' "$route" | jq -er '.date') || return 5
  printf '%s' "$route" | jq -e '.state == "active" or .state == "completed" or .state == "aborted"' >/dev/null || return 5
  local worktree
  worktree=$(printf '%s' "$route" | jq -er '.worktree') || return 5
  LEDGER_ROUTE_SCRIPT="$worktree/scripts/ledger-append.sh"
  [ -f "$LEDGER_ROUTE_SCRIPT" ] || return 5
  LEDGER_ROUTE_OWN=true
  return 0
}

ledger_route_append() {  # $1=kind, $2=json data, $3=source
  if [ "$LEDGER_ROUTE_OWN" = true ]; then
    IWE_ROOT="$LEDGER_ROUTE_ROOT" IWE_LEDGER_WRITE_DIR="$LEDGER_ROUTE_DIR" IWE_LEDGER_EXTERNAL_SOURCE=1 \
      DAY_CLOSE_NATIVE_RUNTIME=claude-code DAY_CLOSE_NATIVE_SESSION_ID="$LEDGER_ROUTE_SESSION_ID" \
      bash "$LEDGER_ROUTE_SCRIPT" day "$LEDGER_ROUTE_DATE" "$1" "$2" "$3" >/dev/null 2>&1 || return 1
  else
    env -u IWE_LEDGER_WRITE_DIR -u IWE_LEDGER_EXTERNAL_SOURCE \
      bash "$LEDGER_ROUTE_SCRIPT" day "$LEDGER_ROUTE_DATE" "$1" "$2" "$3" >/dev/null 2>&1 || return 1
  fi
}
