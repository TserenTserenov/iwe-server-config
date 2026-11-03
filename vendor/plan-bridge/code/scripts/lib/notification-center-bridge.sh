#!/bin/bash
# notification-center-bridge.sh — WP-568 Ф4 (12.09, пир-сессия Kimi+Codex
# 2026-09-12-04-wp568-notification-sources-triage, консенсус за 2 раунда).
#
# Opt-in mirror from an already-gated Telegram source (WP-538 admission gate)
# into the Grafana-backed Центр уведомлений (WP-568 Ф1/Ф2). This is a MIRROR,
# not a replacement: Telegram stays the primary, tested delivery path until
# Ф3's live counter exists and Ф5 wires the dashboard. A Grafana-side failure
# must never affect Telegram delivery, the calling script's exit code, or its
# own alert hysteresis — this function always returns 0 and never throws.
#
# Whitelist, not "every enforced source" (Kimi + Codex round 1: sending every
# telegram-transport-allowlist.conf enforced/reviewed source unconditionally
# risks alert-fatigue in Grafana — elar-morning-window.sh, wp-pool-cascade.sh
# and similar low-priority sources stay Telegram/digest-only until a separate,
# deliberate decision widens this list). See notification-center-sources.conf.
#
# Secrets/tokens for the actual Grafana write are not live yet on this host
# (DRR Ф1 — pilot creates them); until then every call here fails at
# notification-center-send.sh's own secrets check and is logged as "fail",
# which is the correct, harmless outcome for a mirror.

set -uo pipefail

NC_BRIDGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NC_BRIDGE_SOURCES_FILE="${NC_BRIDGE_SOURCES_FILE:-$NC_BRIDGE_LIB_DIR/../notification-center-sources.conf}"
NC_BRIDGE_SEND_SCRIPT="${NC_BRIDGE_SEND_SCRIPT:-$NC_BRIDGE_LIB_DIR/../notification-center-send.sh}"
NC_BRIDGE_LOG="${NC_BRIDGE_LOG:-$HOME/.claude/state/notification-center-bridge.log}"
NC_BRIDGE_TIMEOUT_SEC="${NC_BRIDGE_TIMEOUT_SEC:-5}"

# _nc_bridge_timeout <seconds> <command...>: `timeout` (coreutils) or `gtimeout`
# (macOS with coreutils); with neither (stock macOS, where the Mac-side sources run)
# the command runs without a cap: the send/heartbeat scripts bound their own curl
# calls (-m 20), so the worst case is slower, never a silent "command not found".
# NC_BRIDGE_TIMEOUT_BIN overrides the lookup ("none" = no cap); used by the tests.
_nc_bridge_timeout() {
    local bin="${NC_BRIDGE_TIMEOUT_BIN:-}"
    if [ -z "$bin" ]; then bin=$(command -v timeout || command -v gtimeout || true); fi
    if [ -n "$bin" ] && [ "$bin" != none ] && [ -x "$bin" ]; then
        "$bin" "$@"
    else
        shift
        "$@"
    fi
}

# Sources conf format (WP-568 Ф7 slice 1, DRR-f7): one source per line,
#   <source-id> [<class> [<interval>]]   (trailing "# comment" allowed, CRLF ok)
# class = event (default) | state | info; a state source must also declare the
# expected run interval (<N>[smhd], N >= 1). The FIRST line may declare
# "# schema: N"; no declaration = schema 1 (bare ids, every source is "event").
# A conf newer than NC_BRIDGE_SCHEMA_SUPPORTED, or with a malformed schema
# line, is not interpreted: every source it lists is skipped (fail-closed), so
# a half-deployed newer conf cannot make an older bridge guess.
NC_BRIDGE_SCHEMA_SUPPORTED=2
NC_BRIDGE_ENTRY_CLASS=""
NC_BRIDGE_ENTRY_REASON=""

# _nc_bridge_conf_schema: prints the schema number of NC_BRIDGE_SOURCES_FILE
# (1 if undeclared), or "bad" for a malformed or absurdly large declaration.
_nc_bridge_conf_schema() {
    local first
    first=$(head -n 1 "$NC_BRIDGE_SOURCES_FILE" 2>/dev/null | tr -d '\r')
    case "$first" in
        "# schema:"*)
            if [[ "$first" =~ ^\#\ schema:\ ([0-9]{1,6})$ ]]; then
                printf '%s' "${BASH_REMATCH[1]}"
            else
                printf 'bad'
            fi ;;
        *) printf '1' ;;
    esac
}

# _nc_bridge_entries: conf lines that carry an entry (comments, CR, blank lines stripped).
_nc_bridge_entries() {
    grep -v '^[[:space:]]*#' "$NC_BRIDGE_SOURCES_FILE" 2>/dev/null \
        | tr -d '\r' | sed 's/[[:space:]]*#.*$//' | grep -v '^[[:space:]]*$'
}

# _nc_bridge_resolve <source-id>: looks the source up in the conf.
#   return 0 = listed and valid: NC_BRIDGE_ENTRY_CLASS is set
#   return 1 = not listed (or conf missing/unreadable): callers stay silent
#   return 2 = listed but unusable: NC_BRIDGE_ENTRY_REASON says why (callers log it)
# Non-zero returns are part of the protocol: call it as
# `_nc_bridge_resolve "$id" && rc=0 || rc=$?` so a caller running under
# `set -e` is never aborted by it.
# Missing/unreadable file = nothing whitelisted (fail-closed for the whitelist
# itself — the opposite direction from the fail-open send below is intentional:
# an accidentally deleted config must not silently widen the mirror).
_nc_bridge_resolve() {
    local source_id="${1:-}" id class interval rest schema
    local found=0 first_class="" first_interval=""
    NC_BRIDGE_ENTRY_CLASS=""; NC_BRIDGE_ENTRY_REASON=""
    [ -n "$source_id" ] || return 1
    [ -r "$NC_BRIDGE_SOURCES_FILE" ] || return 1
    while read -r id class interval rest; do
        [ "$id" = "$source_id" ] || continue
        found=$((found + 1))
        if [ "$found" -eq 1 ]; then
            first_class="${class:-event}"; first_interval="${interval:-}"
        elif [ "${class:-event}" != "$first_class" ] || [ "${interval:-}" != "$first_interval" ]; then
            NC_BRIDGE_ENTRY_REASON="conflicting duplicate entries"
            return 2
        fi
    done < <(_nc_bridge_entries)
    [ "$found" -gt 0 ] || return 1
    schema=$(_nc_bridge_conf_schema)
    if [ "$schema" = "bad" ]; then
        NC_BRIDGE_ENTRY_REASON="malformed schema line"
        return 2
    fi
    if [ "$schema" -gt "$NC_BRIDGE_SCHEMA_SUPPORTED" ]; then
        NC_BRIDGE_ENTRY_REASON="conf schema $schema is newer than supported $NC_BRIDGE_SCHEMA_SUPPORTED"
        return 2
    fi
    case "$first_class" in
        event|info) ;;
        state)
            [[ "$first_interval" =~ ^[1-9][0-9]*[smhd]$ ]] \
                || { NC_BRIDGE_ENTRY_REASON="class state needs an interval like 6h"; return 2; } ;;
        *) NC_BRIDGE_ENTRY_REASON="unknown class '$first_class'"; return 2 ;;
    esac
    NC_BRIDGE_ENTRY_CLASS="$first_class"
    return 0
}

# notification_center_bridge_allowed <source-id>: true (exit 0) only if the
# source is listed with a usable entry (see _nc_bridge_resolve).
notification_center_bridge_allowed() {
    _nc_bridge_resolve "${1:-}"
}

# _nc_bridge_key_valid <key>: an explicit incident key is usable if it is
# non-blank, has no double quote or backslash (the LogQL run_id lookup cannot
# take them), no control characters and is at most 200 BYTES (measured in the C
# locale on purpose: systemd/launchd run these scripts without a UTF-8 locale,
# and the count must not depend on it). Deliberately lenient about letters,
# spaces and punctuation: keys already in use (e.g.
# deploy-watchdog:<service name>:<id>) must keep working; stability of the key
# over time is the source's duty, pinned by that source's own smoke test.
_nc_bridge_key_valid() {
    local key="${1:-}" bytes
    [ -n "${key//[[:space:]]/}" ] || return 1
    bytes=$(printf '%s' "$key" | LC_ALL=C wc -c)
    [ "${bytes//[[:space:]]/}" -le 200 ] || return 1
    case "$key" in
        *'"'*|*\\*) return 1 ;;
    esac
    [[ "$key" != *[[:cntrl:]]* ]]
}

# notification_center_bridge_alive <source-id>
# "I ran" ping for class-state sources (WP-568 Ф7, DRR-f7): call it on EVERY run,
# whether or not there is something to report. It is the only thing that lets
# the counter tell a healthy source that has nothing to say from a dead one
# (silence longer than 2 x the declared interval + slack raises a yellow
# "source is silent" incident). A no-op for any other class. Fail-open like
# the send below: always returns 0, outcome goes to NC_BRIDGE_LOG only.
NC_BRIDGE_HEARTBEAT_SCRIPT="${NC_BRIDGE_HEARTBEAT_SCRIPT:-$NC_BRIDGE_LIB_DIR/../notification-center-heartbeat-send.sh}"
notification_center_bridge_alive() {
    local source_id="${1:-}" ts resolved out rc
    [ -n "$source_id" ] || return 0
    _nc_bridge_resolve "$source_id" && resolved=0 || resolved=$?
    [ "$resolved" -eq 0 ] && [ "$NC_BRIDGE_ENTRY_CLASS" = "state" ] || return 0
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$NC_BRIDGE_LOG")" 2>/dev/null || true
    if [ ! -x "$NC_BRIDGE_HEARTBEAT_SCRIPT" ]; then
        printf '%s\talive-skip\t%s\theartbeat script missing or not executable: %s\n' \
            "$ts" "$source_id" "$NC_BRIDGE_HEARTBEAT_SCRIPT" >> "$NC_BRIDGE_LOG" 2>/dev/null || true
        return 0
    fi
    # `&& rc=0 || rc=$?`, not a bare assignment: under a caller's `set -e` a
    # failing command substitution in `out=$(...)` would abort the caller.
    out=$(_nc_bridge_timeout "$NC_BRIDGE_TIMEOUT_SEC" bash "$NC_BRIDGE_HEARTBEAT_SCRIPT" --source "$source_id" --event source_alive 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s\talive-ok\t%s\t-\n' "$ts" "$source_id" >> "$NC_BRIDGE_LOG" 2>/dev/null || true
    else
        printf '%s\talive-fail\t%s\t%s\n' "$ts" "$source_id" \
            "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)" >> "$NC_BRIDGE_LOG" 2>/dev/null || true
    fi
    return 0
}

# notification_center_bridge_resolved <source-id> <correlation_id> [severity red|yellow]
# The source's own "this problem is over" (resolved_by_source, WP-568 Ф7). Unlike
# the send/alive calls this one RETURNS AN ERROR when the marker could not be
# delivered: the caller keeps its "still open" flag and retries on the next run,
# otherwise a lost marker would leave the incident open until it expires. Nothing
# to close (source not listed, unusable key) is not a failure: 0. A listed source whose
# entry cannot be used (schema newer than this bridge, broken entry) or a conf that
# exists but cannot be read IS a failure: the caller keeps its flag and retries.
# A caller under `set -e` must call it as `notification_center_bridge_resolved ... || ...`.
notification_center_bridge_resolved() {
    local source_id="${1:-}" key="${2:-}" severity="${3:-yellow}" ts resolved out rc
    [ -n "$source_id" ] && [ -n "$key" ] || return 0
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$NC_BRIDGE_LOG")" 2>/dev/null || true
    _nc_bridge_resolve "$source_id" && resolved=0 || resolved=$?
    if [ "$resolved" -eq 1 ]; then
        # Not listed (or no conf at all): nothing to close, not a failure. A conf that
        # exists but cannot be read is different: we cannot know, so the caller retries.
        if [ -e "$NC_BRIDGE_SOURCES_FILE" ] && [ ! -r "$NC_BRIDGE_SOURCES_FILE" ]; then
            printf '%s\tresolved-skip\t%s\tsources conf not readable\n' "$ts" "$source_id" >> "$NC_BRIDGE_LOG" 2>/dev/null || true
            return 1
        fi
        return 0
    elif [ "$resolved" -ne 0 ]; then
        # Listed but unusable (schema newer than this bridge, broken entry): the marker
        # cannot be interpreted now; keep the caller's flag and try again later.
        printf '%s\tresolved-skip\t%s\t%s\n' "$ts" "$source_id" "$NC_BRIDGE_ENTRY_REASON" >> "$NC_BRIDGE_LOG" 2>/dev/null || true
        return 1
    fi
    _nc_bridge_key_valid "$key" || return 0
    if [ ! -x "$NC_BRIDGE_HEARTBEAT_SCRIPT" ]; then
        printf '%s\tresolved-skip\t%s\theartbeat script missing or not executable: %s\n' \
            "$ts" "$source_id" "$NC_BRIDGE_HEARTBEAT_SCRIPT" >> "$NC_BRIDGE_LOG" 2>/dev/null || true
        return 1
    fi
    out=$(_nc_bridge_timeout "$NC_BRIDGE_TIMEOUT_SEC" bash "$NC_BRIDGE_HEARTBEAT_SCRIPT" --source "$source_id" \
        --correlation-id "$key" --severity "$severity" --event resolved_by_source 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s\tresolved-ok\t%s\t%s\n' "$ts" "$source_id" "$key" >> "$NC_BRIDGE_LOG" 2>/dev/null || true
        return 0
    fi
    printf '%s\tresolved-fail\t%s\t%s\n' "$ts" "$source_id" \
        "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)" >> "$NC_BRIDGE_LOG" 2>/dev/null || true
    return 1
}

# notification_center_bridge_send <source-id> <severity red|yellow> <title> [detail] [needs_decision 0|1] [correlation_id]
# correlation_id: stable incident key = identity of the PROBLEM as the source
# understands it (e.g. deploy-watchdog:<service>:<deployment id>), never the
# message text. REQUIRED for class event/state (WP-568 Ф7, DRR-f7): without a
# usable key the call is skipped and logged. Class info may omit it; the send
# script then derives sha1(source:title). A key containing a double quote or
# backslash, blank, over 200 chars or with control characters is unusable.
# Fail-open by construction: the exit code is always 0 regardless of what
# happened inside (skipped/sent/failed) — this must be safe to call from any
# existing alert path without touching its own control flow, INCLUDING a
# caller that forgets a required argument under `set -u` (cold-context
# review, 12.09: an unquoted `$1`/`$2`/`$3` here would abort the whole
# caller script, not just this function — the exact failure mode the header
# above promises never happens). Every outcome past the whitelist check is
# appended to NC_BRIDGE_LOG (tab-separated: ts, outcome, source, detail),
# never to the caller's own stdout/stderr, so the mirror stays invisible
# unless someone chooses to inspect the log; a non-whitelisted or
# missing-argument call returns before that point and logs nothing (by
# design — see notification_center_bridge_allowed above).
notification_center_bridge_send() {
    local source_id="${1:-}" severity="${2:-}" title="${3:-}" detail="${4:-}" needs_decision="${5:-0}" correlation_id="${6:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$NC_BRIDGE_LOG")" 2>/dev/null || true

    [ -n "$source_id" ] && [ -n "$severity" ] && [ -n "$title" ] || return 0

    local resolved
    _nc_bridge_resolve "$source_id" && resolved=0 || resolved=$?
    [ "$resolved" -eq 1 ] && return 0
    if [ "$resolved" -eq 2 ]; then
        printf '%s\tskip\t%s\t%s\n' "$ts" "$source_id" "$NC_BRIDGE_ENTRY_REASON" >> "$NC_BRIDGE_LOG" 2>/dev/null || true
        return 0
    fi

    # event/state need an explicit stable incident key (the identity of the
    # PROBLEM, not the message text). Only class info may fall back to the
    # send script's sha1(source:title). Fail-closed for the identity, fail-open
    # for the caller: it is skipped and logged, never an error.
    if ! _nc_bridge_key_valid "$correlation_id"; then
        if [ "$NC_BRIDGE_ENTRY_CLASS" != "info" ]; then
            printf '%s\tskip\t%s\tmissing or invalid correlation_id for class %s\n' \
                "$ts" "$source_id" "$NC_BRIDGE_ENTRY_CLASS" >> "$NC_BRIDGE_LOG" 2>/dev/null || true
            return 0
        fi
        correlation_id=""
    fi

    if [ ! -x "$NC_BRIDGE_SEND_SCRIPT" ]; then
        printf '%s\tskip\t%s\tbridge script missing or not executable: %s\n' \
            "$ts" "$source_id" "$NC_BRIDGE_SEND_SCRIPT" >> "$NC_BRIDGE_LOG" 2>/dev/null || true
        return 0
    fi

    local args=(--source "$source_id" --severity "$severity" --title "$title")
    [ -n "$detail" ] && args+=(--detail "$detail")
    [ "$needs_decision" = "1" ] && args+=(--needs-decision)
    [ -n "$correlation_id" ] && args+=(--correlation-id "$correlation_id")

    local out rc
    # Same reason as in notification_center_bridge_alive: a failing send script
    # must not abort a caller running under `set -e` (found by the Ф7 slice 2
    # errexit test; the previous bare assignment made the "always returns 0"
    # promise false exactly when Grafana was down).
    out=$(_nc_bridge_timeout "$NC_BRIDGE_TIMEOUT_SEC" bash "$NC_BRIDGE_SEND_SCRIPT" "${args[@]}" 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s\tok\t%s\t-\n' "$ts" "$source_id" >> "$NC_BRIDGE_LOG" 2>/dev/null || true
    else
        printf '%s\tfail\t%s\t%s\n' "$ts" "$source_id" \
            "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)" >> "$NC_BRIDGE_LOG" 2>/dev/null || true
    fi
    return 0
}
