#!/bin/bash
# WP-295 Ф1 шаг 5: agent-trace async uploader.
# Читает NDJSON-файлы из ~/.claude/logs/agent-trace/, POST'ит каждую строку
# в event-gateway (с idempotency по external_id). Успешно отправленные строки
# помечаются (rotation), при network fail — оставляются для retry.
#
# Запуск:
#   ~/.claude/hooks/agent-trace-uploader.sh          # один проход
#   ~/.claude/hooks/agent-trace-uploader.sh --watch  # loop каждые 30s
#
# see DP.SC.037 (agent-trace store), DP.ROLE.047 (Trace Recorder).
#
# Эта часть writer'а — fire-and-forget путь от локального NDJSON в Neon через
# event-gateway. Schedule (cron / launchd) — отдельная фаза Ф4.5 / Ф6.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

LOG_DIR="${HOME}/.claude/logs/agent-trace"
UPLOADED_DIR="${LOG_DIR}/uploaded"
ENDPOINT="${AGENT_TRACE_GATEWAY:-https://event-gateway.aisystant.workers.dev/events}"
SOURCE_NAME="agent-trace-recorder"
mkdir -p "$UPLOADED_DIR" 2>/dev/null || exit 0

upload_line() {
    local line="$1"
    local session_uuid="$2"
    local line_idx="$3"

    local event_type
    event_type=$(echo "$line" | jq -r '.event_type // empty')
    [ -z "$event_type" ] && return 1

    local schema_version
    schema_version=$(echo "$line" | jq -r '.schema_version // "v1"')

    local payload
    payload=$(echo "$line" | jq -c '.payload // {}')

    local occurred_at
    occurred_at=$(echo "$line" | jq -r '.emitted_at // empty')

    # external_id для idempotency: session_uuid + line_idx + event_type
    local external_id="${session_uuid}-${line_idx}-${event_type}"

    local body
    body=$(jq -nc \
        --arg src "$SOURCE_NAME" --arg eid "$external_id" \
        --arg et "$event_type" --arg sv "$schema_version" \
        --argjson p "$payload" --arg oa "$occurred_at" \
        '{source: $src, external_id: $eid, event_type: $et, schema_version: $sv, payload: $p, occurred_at: $oa}')

    local response
    response=$(curl -s -X POST "$ENDPOINT" -H "Content-Type: application/json" -d "$body" 2>/dev/null)
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "  network error (curl $exit_code), keeping for retry" >&2
        return 1
    fi

    # 200 (idempotent) или 201 (new) — event-gateway returns {inserted: bool} or {inserted: false, idempotent: true}
    # jq -r '.inserted // empty' bug: jq treats `false` как falsy для //. Используем `has()`:
    local accepted
    accepted=$(echo "$response" | jq -r 'if has("inserted") or has("idempotent") then "yes" else empty end' 2>/dev/null)
    if [ "$accepted" == "yes" ]; then
        return 0
    fi

    # Anything else = error
    echo "  upload FAILED: $response" >&2
    return 1
}

upload_file() {
    local file="$1"
    local session_uuid
    session_uuid=$(basename "$file" .ndjson)
    local total=0
    local sent=0
    local failed=0
    local line_idx=0

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        total=$((total + 1))
        line_idx=$((line_idx + 1))
        if upload_line "$line" "$session_uuid" "$line_idx"; then
            sent=$((sent + 1))
        else
            failed=$((failed + 1))
        fi
    done < "$file"

    if [ $failed -eq 0 ] && [ $sent -gt 0 ]; then
        # Все успешно — переносим в uploaded/ (audit trail).
        mv "$file" "${UPLOADED_DIR}/${session_uuid}.ndjson"
        echo "session $session_uuid: $sent/$total ✓ (moved to uploaded/)"
    else
        echo "session $session_uuid: $sent/$total sent, $failed failed (keeping file for retry)"
    fi
}

run_once() {
    local count=0
    for file in "$LOG_DIR"/*.ndjson; do
        [ -e "$file" ] || continue
        # Skip uploaded/ dir
        [[ "$file" == "$UPLOADED_DIR"* ]] && continue
        upload_file "$file"
        count=$((count + 1))
    done
    [ $count -eq 0 ] && echo "no NDJSON files to upload"
}

if [ "${1:-}" == "--watch" ]; then
    INTERVAL="${2:-30}"
    echo "starting watch loop, interval ${INTERVAL}s"
    while true; do
        run_once
        sleep "$INTERVAL"
    done
else
    run_once
fi
