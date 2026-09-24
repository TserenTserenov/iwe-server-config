#!/bin/bash
# log_formatter.sh
# Shared JSONL formatter для capture_log.jsonl / gate_log.jsonl.
# Пишет одну строку JSON в указанный файл, atomic append.
#
# Usage:
#   log_jsonl <file> <key=val>...
# Пример:
#   log_jsonl .claude/logs/capture_log.jsonl detector=incident status=fired latency_ms=42

set -euo pipefail

log_jsonl() {
  local file="$1"; shift
  local ts
  ts=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")

  local args=(--arg ts "$ts")
  local jq_obj='{ts: $ts'

  for kv in "$@"; do
    local key="${kv%%=*}"
    local val="${kv#*=}"
    args+=(--arg "$key" "$val")
    jq_obj+=", $key: \$$key"
  done
  jq_obj+="}"

  mkdir -p "$(dirname "$file")"
  jq -nc "${args[@]}" "$jq_obj" >> "$file"
}

# Если скрипт вызван напрямую — работает как CLI
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  log_jsonl "$@"
fi
