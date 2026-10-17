#!/bin/bash
# stale-sessions-report.sh — informational table of open session semaphores
# for day-close/week-close (WP-484 Ф207, 17.10).
#
# Found live: 43 semaphores open simultaneously on one host, 6 of them for
# the same WP, some 4 days old -- with no automatic cleanup and no step in
# day/week-close that ever surfaces the list to the pilot. sweep_orphaned_
# semaphores() in session-guard.sh deliberately never auto-closes on age
# alone (WP-484 Ф49: a live session's semaphore was once quarantined this
# way) -- this script does not change that. It only reports; the pilot
# decides close/renew per session.
#
# Three reasons, not one boolean, because a long-running session with a
# valid lease is not the same finding as one with an actually expired lease
# (cold-review, Codex, peer-session 2026-10-17-02-wp484-release-stuck-diag):
#   expired            -- lease deadline has passed
#   invalid-timestamp  -- lease deadline cannot be computed (legacy/corrupt)
#   long-running-valid -- age > 1800s but lease still valid (same threshold
#                         session-guard.sh's own `open` NOTE already uses)
#
# Deadline math is copied, not sourced, from session-guard.sh's
# semaphore_epoch()/lease_deadline_epoch() (lines ~683, ~2316): sourcing that
# file would also run its own CLI dispatch at the bottom, which this
# read-only report must never trigger.

set -uo pipefail

SESSIONS_RUNTIME="${IWE_ROOT:-$HOME/IWE}/.iwe-runtime/sessions"
LEASE_SEC="${IWE_SESSION_LEASE_SEC:-14400}"  # 4h, same default as session-guard.sh

compgen -G "$SESSIONS_RUNTIME/*.open" >/dev/null 2>&1 || { echo "stale-sessions-report: нет открытых семафоров"; exit 0; }

semaphore_epoch() {
    local semaphore="$1" timestamp
    timestamp=$(grep -E '^(opened_at|created_at): ' "$semaphore" | head -1 | cut -d' ' -f2- || true)
    [ -n "$timestamp" ] || return 1
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null \
        || date -u -d "$timestamp" +%s 2>/dev/null
}

lease_deadline_epoch() {
    local semaphore="$1" base_epoch renewed_at renewed_epoch=""
    base_epoch=$(semaphore_epoch "$semaphore") || return 1
    if [ -f "${semaphore}.lease" ]; then
        renewed_at=$(grep '^renewed_at: ' "${semaphore}.lease" | tail -1 | cut -d' ' -f2- || true)
        if [ -n "$renewed_at" ]; then
            renewed_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$renewed_at" +%s 2>/dev/null \
                || date -u -d "$renewed_at" +%s 2>/dev/null || true)
        fi
    fi
    if [ -n "$renewed_epoch" ] && [ "$renewed_epoch" -gt "$base_epoch" ]; then
        base_epoch="$renewed_epoch"
    fi
    echo $(( base_epoch + LEASE_SEC ))
}

printf '%-45s %-10s %-20s %s\n' "SESSION" "WP" "REASON" "AGE"

now_epoch=$(date +%s)
for sem in "$SESSIONS_RUNTIME"/*.open; do
    [ -f "$sem" ] || continue
    wp=$(grep '^wp: ' "$sem" | head -1 | cut -d' ' -f2-)
    wp="${wp:-unknown}"

    epoch=$(semaphore_epoch "$sem") || {
        printf '%-45s %-10s %-20s %s\n' "$(basename "$sem")" "$wp" "invalid-timestamp" "-"
        continue
    }
    age=$(( now_epoch - epoch ))
    [ "$age" -lt 0 ] && age=0
    [ "$age" -gt 1800 ] || continue  # same floor as session-guard.sh's own NOTE/WARNING

    deadline=$(lease_deadline_epoch "$sem") || deadline=0
    if [ "$now_epoch" -lt "$deadline" ]; then
        printf '%-45s %-10s %-20s %ss\n' "$(basename "$sem")" "$wp" "long-running-valid" "$age"
    else
        printf '%-45s %-10s %-20s %ss\n' "$(basename "$sem")" "$wp" "expired" "$age"
    fi
done
