#!/bin/bash
# publish-gate.sh -- shared predicate + routing primitives for publishing a
# commit into a repo that may or may not need the ds-publish.sh coordination
# gate (flock queue + isolate-push.sh fetch/cherry-pick/push/retry).
#
# Extracted from commit-push.sh's push_or_publish()/is_ds_my_strategy() (WP-530
# Ф9, peer-session with Codex, sessions/2026-08/19/2026-08-19-02-wp530-ds-
# publish-wiring/) so peer-conversation and kimi-peer-writer can route their own
# session-close/implementation-deploy commits through the same gate instead of
# re-deriving the origin-identity check a third and fourth time (P2 -- third
# repetition becomes a function, not a copy-paste).
#
# Functions:
#   normalize_remote_url <url>                           -- pure string transform
#   is_ds_repo_by_origin <repo-dir>                       -- pure predicate
#   publish_commit <repo-dir> <sha> <priority> <reason>   -- routes via ds-publish.sh
#   push_branch <repo-dir>                                -- plain `git push`
#
# Each caller decides which repos need `publish_commit` (identity check) vs.
# `push_branch` (no check) -- this library does not decide priority or reason
# text, only mechanics. IWE_ROOT must be set by the caller before sourcing
# (defaults to $HOME/IWE if unset).

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"

# normalize_remote_url <url> -- strips protocol/creds/.git so
# "git@github.com:org/repo.git" and "https://x:tok@github.com/org/repo.git"
# compare equal. Scheme and optional user@ stripped in separate substitutions
# (a combined pattern silently ate the hostname on creds-less https URLs --
# found in code review 2026-08-12).
normalize_remote_url() {
    sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^@/]*@##; s#:#/#; s#\.git$##' <<<"$1"
}

# is_ds_repo_by_origin <repo-dir> -- true iff <repo-dir>'s origin matches
# DS-my-strategy's origin, compared by normalized URL, not by path (an
# isolated worktree of DS-my-strategy has a different path but the same
# origin, and must route through the gate the same as the canonical
# checkout).
DS_MY_STRATEGY_ORIGIN_NORMALIZED=""
is_ds_repo_by_origin() {  # <repo-dir>
    local repo="$1" repo_remote
    if [[ -z "$DS_MY_STRATEGY_ORIGIN_NORMALIZED" ]]; then
        local canonical_remote
        canonical_remote=$(git -C "$IWE_ROOT/DS-my-strategy" remote get-url origin 2>/dev/null) || return 1
        DS_MY_STRATEGY_ORIGIN_NORMALIZED=$(normalize_remote_url "$canonical_remote")
    fi
    repo_remote=$(git -C "$repo" remote get-url origin 2>/dev/null) || return 1
    [[ "$(normalize_remote_url "$repo_remote")" == "$DS_MY_STRATEGY_ORIGIN_NORMALIZED" ]]
}

# publish_commit <repo-dir> <sha> <priority> <reason> -- publishes <sha> from
# <repo-dir> through the shared ds-publish.sh gate. Always runs the CANONICAL
# ds-publish.sh ($IWE_ROOT/DS-my-strategy/scripts/ds-publish.sh), regardless of
# which checkout the caller itself lives in (WP-537, 18.08 finding) -- warns,
# doesn't block, if the caller's own copy has drifted from canonical (a false
# block would be worse than a stale-copy warning on this critical path).
publish_commit() {  # <repo-dir> <sha> <priority> <reason>
    local repo="$1" sha="$2" priority="$3" reason="$4"
    local canonical_publish="$IWE_ROOT/DS-my-strategy/scripts/ds-publish.sh"
    local self_publish="$(dirname "${BASH_SOURCE[0]}")/../ds-publish.sh"
    if [[ -f "$self_publish" && -f "$canonical_publish" ]] && \
       ! cmp -s "$self_publish" "$canonical_publish"; then
        echo "WARNING: canonical ds-publish.sh ($canonical_publish) differs from this checkout's own copy ($self_publish) -- canonical may be behind a recent fix; proceeding with canonical anyway" >&2
    fi
    # WP-484 Ф178 (06.10, found live by this exact call): isolate-push.sh's
    # record_publication_receipts() only passes --session-id to note-publication
    # when IWE_PUBLICATION_SESSION_ID is set; without it, note-publication falls
    # back to select_semaphore with no selector, which correctly refuses to guess
    # among two or more open semaphores for the same agent -- the system's normal
    # state, not an edge case. commit-push.sh already exports this var from its
    # bound session evidence; interactive callers of publish_commit (peer-
    # conversation, kimi-peer-writer) never did, so every receipt silently fell
    # back to legacy proof whenever another session was open. Caller sets it;
    # this function only surfaces the gap, it never guesses a session_id itself.
    [[ -n "${IWE_PUBLICATION_SESSION_ID:-}" ]] \
        || echo "WARNING: IWE_PUBLICATION_SESSION_ID not set -- publication receipt v2 will fall back to legacy proof if another session is open for this agent; export your own session_id before calling publish_commit" >&2
    # WP-538 Ф7: DS_PUBLISH_RUN_ID (exported by commit-push.sh from the
    # handler payload) rides into ds-publish.sh as a structured --run-id, so
    # the notification queue/digest can correlate messages of one run without
    # parsing the 8-char "#rid:" tail out of the human reason text.
    local run_id_args=()
    [[ -n "${DS_PUBLISH_RUN_ID:-}" ]] && run_id_args=(--run-id "$DS_PUBLISH_RUN_ID")
    bash "$canonical_publish" "$repo" "$priority" --reason "$reason" \
        ${run_id_args[@]+"${run_id_args[@]}"} \
        --from-commit "$sha" \
        --exact-commit "$sha"
}

# push_branch <repo-dir> -- plain `git push` of the current branch, setting
# upstream if missing. For repos that don't share DS-my-strategy's write
# contention and don't need the coordination gate.
push_branch() {  # <repo-dir>
    local repo="$1" remote branch
    remote=$(git -C "$repo" remote | head -1)
    branch=$(git -C "$repo" branch --show-current)
    [[ -n "$remote" && -n "$branch" ]] || {
        echo "cannot publish: remote or current branch is missing" >&2
        return 1
    }
    python3 "$(dirname "${BASH_SOURCE[0]}")/../session_local_release.py" publisher "$repo" -- \
        git -C "$repo" push --set-upstream "$remote" "$branch"
}
