#!/bin/bash
# publish-queue.sh -- observability-only queue markers around ds-publish.sh's
# flock. WP-484 Ф138 (25.08, peer-session with Codex, consensus turn 3):
# pilot's ArchGate decision on Класс 1 said the publish lock queue must be
# visible ("в очереди видно сразу"), not a silent wait. This registry does
# NOT participate in mutual exclusion -- flock in ds-publish.sh still owns
# ordering and correctness; a marker going stale or missing never blocks or
# unblocks a publish. Only the caller's own marker is ever removed by that
# caller (via trap) -- a foreign marker with a dead pid is reported `stale`,
# never deleted, matching sweep_orphaned_semaphores()'s existing convention
# in session-guard.sh (kill -0 on a recorded pid, not a wall-clock TTL).
#
# Liveness also checks process identity, not just PID (WP-484 Ф138-tail,
# peer-session with Kimi+Codex, 02.09): a marker whose owner has long since
# exited can have its pid reassigned by the OS to an unrelated process,
# making bare `kill -0` report a dead marker as live. `pid_start` (the
# owning process's start time, via `ps -o lstart=`) is recorded at marker
# creation and compared against the PID's *current* start time at read time
# -- a mismatch means the PID was reused. This is an identity check, not a
# wall-clock TTL: a marker's age is never itself grounds for `stale`.
#
# Functions:
#   publish_queue_mark_waiting <queue_dir> <priority> <reason> <worktree>
#       -- creates the marker, echoes its path to stdout.
#   publish_queue_mark_holder <marker_path>
#   publish_queue_status_report <queue_dir>
#       -- prints holder + waiting queue for `ds-publish.sh --status`.

# publish_queue_mark_waiting <queue_dir> <priority> <reason> <worktree>
# reason/worktree come from caller-supplied free text (--reason, a worktree
# path) -- newlines are stripped before writing (cold-context review 25.08):
# an embedded newline starting with "state: holder" would let a waiting
# marker misreport itself as the lock holder, since every reader takes the
# FIRST "^field: " match in the file.
publish_queue_mark_waiting() {
    local queue_dir="$1" priority="$2" reason="$3" worktree="$4"
    mkdir -p "$queue_dir" || {
        echo "WARN: ds-publish.sh: не удалось создать $queue_dir для маркера очереди (не блокирует публикацию)" >&2
        return 1
    }
    reason="${reason//$'\n'/ }"
    worktree="${worktree//$'\n'/ }"
    local tmp marker
    tmp=$(mktemp "$queue_dir/.rewrite-XXXXXXXX") || {
        echo "WARN: ds-publish.sh: не удалось создать маркер очереди в $queue_dir (не блокирует публикацию)" >&2
        return 1
    }
    {
        echo "pid: $$"
        echo "pid_start: $(LC_ALL=C TZ=UTC ps -o lstart= -p "$$" 2>/dev/null | xargs)"
        echo "priority: $priority"
        echo "reason: ${reason:--}"
        echo "worktree: $worktree"
        echo "started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "state: waiting"
    } > "$tmp"
    # Reuse mktemp's own atomically-allocated suffix for the final name
    # (swap the ".rewrite-" prefix for "marker-") instead of inventing a
    # pid+timestamp name -- mktemp already guaranteed no other file on disk
    # has this exact suffix, so the rename can't collide with a concurrent
    # caller the way a hand-rolled name might.
    marker="$queue_dir/marker-${tmp#"$queue_dir"/.rewrite-}"
    mv "$tmp" "$marker" 2>/dev/null || { rm -f "$tmp"; echo "WARN: ds-publish.sh: не удалось разместить маркер очереди (не блокирует публикацию)" >&2; return 1; }
    echo "$marker"
}

# publish_queue_mark_holder <marker_path> -- flips state after flock is
# acquired. Best-effort: a failed write here never blocks publishing (the
# registry is observability, not the lock itself).
publish_queue_mark_holder() {
    local marker="$1"
    [ -f "$marker" ] || return 0
    local tmp
    tmp=$(mktemp "$(dirname "$marker")/.rewrite-XXXXXXXX") || return 0
    if sed 's/^state: waiting$/state: holder/' "$marker" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$marker" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
    return 0
}

# _publish_queue_pid_alive <pid> <recorded_pid_start> -- true if pid is a
# live process AND (recorded_pid_start is empty, a legacy marker predating
# this field, or it matches the process's current start time). Guards
# against PID reuse: a bare `kill -0` can't tell "the same process that
# wrote this marker" from "the OS handed this pid to someone else since"
# (WP-484 Ф138-tail, found live 02.09 -- a same-day test's marker still
# read as held because its pid was later reassigned to an unrelated macOS
# service). `ps -o lstart=` returns empty for a dead/nonexistent pid.
_publish_queue_pid_alive() {
    local pid="$1" recorded_start="$2" current_start
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # No recorded_start (marker predates this field) -- can't verify identity,
    # fall back to the pre-existing kill -0-only behavior rather than
    # penalizing every legacy marker (cold-context review 02.09: an earlier
    # draft required `ps` to succeed unconditionally, which would have
    # misclassified all pre-existing markers as stale on any `ps` hiccup).
    [ -z "$recorded_start" ] && return 0
    current_start=$(LC_ALL=C TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null | xargs)
    [ -n "$current_start" ] && [ "$recorded_start" = "$current_start" ]
}

# publish_queue_ahead_count <queue_dir> <own_marker> -- how many OTHER live
# markers (any state) exist right now, for the immediate "you are Nth"
# notice printed the moment a wait actually starts (not just at the end).
# Dead/stale markers don't count -- a crashed process holding third place
# shouldn't make a live waiter believe it is 4th.
publish_queue_ahead_count() {
    local queue_dir="$1" own_marker="$2" count=0 marker pid pid_start
    for marker in "$queue_dir"/marker-*; do
        [ -f "$marker" ] || continue
        [ "$marker" = "$own_marker" ] && continue
        pid=$(sed -n 's/^pid: //p' "$marker" | head -1)
        pid_start=$(sed -n 's/^pid_start: //p' "$marker" | head -1)
        _publish_queue_pid_alive "$pid" "$pid_start" && count=$((count + 1))
    done
    echo "$count"
}

# publish_queue_status_report <queue_dir> -- read-only. Never deletes,
# never writes -- a diagnostic command must not be able to perturb the
# thing it's inspecting.
publish_queue_status_report() {
    local queue_dir="$1"
    if [ ! -d "$queue_dir" ] || [ -z "$(ls -A "$queue_dir" 2>/dev/null)" ]; then
        echo "ds-publish: очередь пуста"
        return 0
    fi

    local marker pid pid_start priority reason worktree started_at state alive_tag
    local -a holder_lines=() waiting_lines=()
    for marker in "$queue_dir"/marker-*; do
        [ -f "$marker" ] || continue
        pid=$(sed -n 's/^pid: //p' "$marker" | head -1)
        pid_start=$(sed -n 's/^pid_start: //p' "$marker" | head -1)
        priority=$(sed -n 's/^priority: //p' "$marker" | head -1)
        reason=$(sed -n 's/^reason: //p' "$marker" | head -1)
        worktree=$(sed -n 's/^worktree: //p' "$marker" | head -1)
        started_at=$(sed -n 's/^started_at: //p' "$marker" | head -1)
        state=$(sed -n 's/^state: //p' "$marker" | head -1)
        alive_tag=""
        if ! _publish_queue_pid_alive "$pid" "$pid_start"; then
            alive_tag=" [stale]"
        fi
        local line="  $started_at  pid=$pid  priority=$priority  reason=$reason  worktree=$worktree$alive_tag"
        if [ "$state" = "holder" ]; then
            holder_lines+=("$line")
        else
            waiting_lines+=("$started_at|$line")
        fi
    done

    if [ "${#holder_lines[@]}" -gt 0 ]; then
        echo "Держит блокировку:"
        printf '%s\n' "${holder_lines[@]}"
    else
        echo "Блокировка сейчас свободна (или держатель не оставил маркер)"
    fi

    if [ "${#waiting_lines[@]}" -gt 0 ]; then
        echo "Ожидают (${#waiting_lines[@]}), по возрасту заявки — не строгий FIFO, порядок реально решает flock:"
        printf '%s\n' "${waiting_lines[@]}" | sort | cut -d'|' -f2-
    else
        echo "Ожидающих нет"
    fi
}
