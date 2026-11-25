#!/usr/bin/env bash
# Stand-in for session-guard.sh in wp-session-launch-smoke.sh: implements only
# open --isolate, batch note-file and machine-close, on a throwaway repository.
# It keeps the real guard's refusals that the launcher must respect: open needs
# --isolate + machine-publish-only + owner pid + IWE_SESSION_ID; note-file needs
# --paths-from0 + --repo-root and every path to exist on disk or in HEAD;
# machine-close refuses a dirty copy (tracked or untracked changes).
# FAKE_GUARD_STATE (dir) is required; FAKE_CLOSE_MODE: ok | fail | publish-then-fail | hang | publish-then-hang.
set -euo pipefail
state="${FAKE_GUARD_STATE:?}"
cmd="$1"; shift
case "$cmd" in
  open)
    isolate=0 close_path="" owner=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --isolate) isolate=1; shift ;;
        --close-path) close_path="$2"; shift 2 ;;
        --owner-pid) owner="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ "$isolate" = 1 ] && [ "$close_path" = machine-publish-only ] && [ -n "$owner" ] \
      || { echo "fake: open без --isolate/machine-publish-only/--owner-pid" >&2; exit 1; }
    sid="${IWE_SESSION_ID:?}"
    git fetch -q origin main
    wt="$state/wt-$sid"
    git worktree add -q -b "launch/$sid" "$wt" origin/main
    printf '%s\n' "$wt" > "$state/$sid.open"
    echo "fake guard: ORZ scaffold"
    printf '{"worktree_path": "%s", "branch": "launch/%s", "session_id": "%s"}\n' "$wt" "$sid" "$sid"
    ;;
  note-file)
    list="" root=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --paths-from0) list="$2"; shift 2 ;;
        --repo-root) root="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$list" ] && [ -n "$root" ] || { echo "fake: note-file только пакетом" >&2; exit 1; }
    while IFS= read -r -d '' path; do
      [ -e "$root/$path" ] || git -C "$root" cat-file -e "HEAD:$path" 2>/dev/null \
        || { echo "fake: путь $path не найден" >&2; exit 1; }
      printf '%s\n' "$path" >> "$state/${IWE_SESSION_ID:?}.notes"
    done < "$list"
    ;;
  machine-close)
    sid=""
    while [ "$#" -gt 0 ]; do
      case "$1" in --session-id) sid="$2"; shift 2 ;; *) shift ;; esac
    done
    echo close >> "$state/$sid.close-calls"
    wt=$(cat "$state/$sid.open")
    [ -z "$(git -C "$wt" status --porcelain --untracked-files=all)" ] || { echo "fake: грязная копия" >&2; exit 7; }
    case "${FAKE_CLOSE_MODE:-ok}" in
      fail) exit 7 ;;
      publish-then-fail) git -C "$wt" push -q origin HEAD:main; exit 7 ;;
      hang) sleep 300 ;;
      publish-then-hang) git -C "$wt" push -q origin HEAD:main; sleep 300 ;;
    esac
    if [ "$(git -C "$wt" rev-list --count origin/main..HEAD)" != 0 ]; then
      git -C "$wt" push -q origin HEAD:main
    fi
    mv "$state/$sid.open" "$state/$sid.closed"
    ;;
  *) echo "fake: неизвестная команда $cmd" >&2; exit 1 ;;
esac
