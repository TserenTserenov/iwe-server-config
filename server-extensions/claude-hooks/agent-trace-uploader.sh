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
MALFORMED_DIR="${LOG_DIR}/quarantine/malformed"
PIDFILE="${LOG_DIR}/.uploader.pid"
ENDPOINT="${AGENT_TRACE_GATEWAY:-https://event-gateway.aisystant.workers.dev/events}"
SOURCE_NAME="agent-trace-recorder"
CONCURRENT_UPLOADS="${AGENT_TRACE_UPLOAD_CONCURRENCY:-24}"
CURL_TIMEOUT="${AGENT_TRACE_CURL_TIMEOUT:-30}"

# VPN guard: warn if a VPN is routing default traffic. NordVPN (utun) breaks DNS for
# *.aisystant.workers.dev / *.neon.tech, causing upload retries. We keep files for retry,
# but the pilot should know why uploads are stalling.
if [ "${SKIP_VPN_CHECK:-}" != "1" ]; then
    _vpn_active=0
    if command -v scutil >/dev/null 2>&1 && scutil --nc list 2>/dev/null | grep -qi "connected"; then
        _vpn_active=1
    elif netstat -rn -f inet 2>/dev/null | grep -E '^default' | grep -qE 'utun|ipsec|ppp'; then
        _vpn_active=1
    fi

    if [ "$_vpn_active" -eq 1 ]; then
        echo "WARNING: active VPN detected. Uploads to event-gateway may fail due to DNS issues; files will be retried. Disable VPN or set SKIP_VPN_CHECK=1 to silence." >&2
    fi
fi

# Create dirs before anything writes into LOG_DIR (the pidfile lives there too).
mkdir -p "$UPLOADED_DIR" "$MALFORMED_DIR" 2>/dev/null || exit 0

# Single-instance guard: exit if another uploader is already running.
if [ -e "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT INT TERM

upload_line() {
    local line="$1"
    local session_uuid="$2"
    local line_idx="$3"

    local event_type
    event_type=$(echo "$line" | jq -r '.event_type // empty')
    # No event_type = terminal reject (bad data, never uploadable). Return 2 so the caller
    # quarantines it instead of retrying forever (terminal fail != transient fail).
    [ -z "$event_type" ] && return 2

    local schema_version
    schema_version=$(echo "$line" | jq -r '.schema_version // "v1"')

    local payload
    # Sanitize payload: PostgreSQL JSON rejects \u0000 (NULL byte).
    payload=$(echo "$line" | jq -c '.payload // {} | walk(if type == "string" then gsub("\u0000"; "") else . end)' 2>/dev/null || echo '{}')

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
    response=$(curl -s --max-time "$CURL_TIMEOUT" -X POST "$ENDPOINT" -H "Content-Type: application/json" -d "$body" 2>/dev/null)
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
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/agent-trace-uploader.XXXXXX")
    local total=0
    local line_idx=0
    local pids=()
    local result_files=()

    # Read file and dispatch each valid line to a background upload job.
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        total=$((total + 1))
        line_idx=$((line_idx + 1))

        # Guard against malformed NDJSON lines (e.g. interleaved concurrent writes split
        # one record across physical lines). Skip the bad line, keep uploading the rest —
        # uploads are idempotent (external_id), so valid events are not lost.
        if ! echo "$line" | jq -e . >/dev/null 2>&1; then
            echo "2" > "$tmpdir/result.$line_idx"
            continue
        fi

        # Job file holds the session_uuid (first line) and the JSON line (rest).
        { echo "$session_uuid"; echo "$line"; } > "$tmpdir/job.$line_idx"

        # Pre-create result with a failure placeholder; the background job overwrites
        # it on success. If the job dies without writing, we retry the line next run.
        echo "1" > "$tmpdir/result.$line_idx"

        (
            upload_line "$line" "$session_uuid" "$line_idx"
            echo $? > "$tmpdir/result.$line_idx"
        ) &
        pids+=($!)
        result_files+=("$tmpdir/result.$line_idx")

        # Concurrency limit: wait for any finished job when we reach the cap.
        while [ ${#pids[@]} -ge "$CONCURRENT_UPLOADS" ]; do
            local i
            for i in "${!pids[@]}"; do
                if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                    wait "${pids[$i]}" 2>/dev/null || true
                    unset pids[$i]
                    unset result_files[$i]
                    break
                fi
            done
            sleep 0.2
        done
    done < "$file"

    # Wait for remaining background jobs.
    local i
    for i in "${!pids[@]}"; do
        wait "${pids[$i]}" 2>/dev/null || true
    done

    # Collect results.
    local sent=0
    local failed=0
    local malformed=0
    local r
    for r in "$tmpdir"/result.*; do
        [ -e "$r" ] || continue
        local rc
        rc=$(cat "$r" 2>/dev/null || echo 1)
        case "$rc" in
            0) sent=$((sent + 1)) ;;
            2) malformed=$((malformed + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
    done

    rm -rf "$tmpdir"

    if [ $failed -gt 0 ]; then
        # Network failures — keep file; retry re-POSTs (idempotent), converges when net recovers.
        echo "session $session_uuid: $sent/$total sent, $failed failed, $malformed malformed (keeping file for retry)"
    elif [ $malformed -gt 0 ]; then
        # All parseable lines uploaded (idempotent); file had corruption → quarantine for forensics.
        mv "$file" "${MALFORMED_DIR}/${session_uuid}.ndjson"
        echo "session $session_uuid: $sent/$total sent, $malformed malformed → quarantine"
    elif [ $sent -gt 0 ]; then
        # Все успешно — переносим в uploaded/ (audit trail).
        mv "$file" "${UPLOADED_DIR}/${session_uuid}.ndjson"
        echo "session $session_uuid: $sent/$total ✓ (moved to uploaded/)"
    else
        echo "session $session_uuid: nothing uploaded ($total lines), keeping file"
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
    return $count
}

if [ "${1:-}" == "--watch" ]; then
    INTERVAL="${2:-30}"
    echo "starting watch loop, interval ${INTERVAL}s"
    while true; do
        processed=0
        for file in "$LOG_DIR"/*.ndjson; do
            [ -e "$file" ] || continue
            [[ "$file" == "$UPLOADED_DIR"* ]] && continue
            upload_file "$file"
            processed=$((processed + 1))
        done
        [ $processed -eq 0 ] && sleep "$INTERVAL"
    done
else
    run_once
fi
