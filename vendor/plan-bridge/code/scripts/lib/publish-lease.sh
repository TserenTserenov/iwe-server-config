#!/bin/bash
# publish-lease.sh -- CAS-based global lease/fencing for the publish path
# (WP-484 пункт A, третья дыра линии Класс 1: единый писатель / lease+fencing).
#
# Design consensus: peer-session with Codex,
# sessions/2026-08/25/2026-08-25-21-wp484-class1-unified-writer/, ход 3.
# Local flock (scripts/ds-publish.sh) only serializes writers on ONE host --
# DS-my-strategy syncs across at least two (Mac + tsekh-1), so fencing has to
# live somewhere both hosts actually share: origin on GitHub, not a local
# file. The lease record is a plain commit object (empty tree, key:value
# text in the commit message -- same marker format as publish-queue.sh, no
# JSON/python3 dependency) at a dedicated ref. Every acquire is an atomic
# remote CAS via `git push --force-with-lease=<ref>:<old-oid>` -- GitHub
# either accepts the push (nobody moved the ref since we read it) or rejects
# it outright. A STALE read is safe (the push is simply rejected by the real
# remote state). A FAILED read of an existing lease's content is not safe on
# its own -- the oid from ls-remote can still be correct while the content
# fetch that would reveal it's still someone else's active lease fails, so
# _publish_lease_read_remote treats that specific case as a hard error
# (return 1) instead of "looks free" (cold-context review, 25.08).
#
# Ref choice: refs/notes/iwe-publish-lease, not a bespoke refs/iwe/* -- git
# notes are a namespace GitHub.com is known to accept push/fetch for (widely
# used by CI to attach build metadata); an arbitrary custom namespace was
# flagged by the peer as unverified, and a canary should not add unverified
# infra risk on top of a new algorithm.
#
# Canary scope (consensus): this is COOPERATIVE fencing, not a git-server
# enforcement gate. GitHub.com has no pre-receive hooks (only GitHub
# Enterprise Server does), so a caller that bypasses this library and pushes
# to main directly still isn't blocked at the server. Documented residual
# risk, not an oversight -- full branch-protection/PR-only enforcement is a
# separate decision (forces every IWE session onto a PR workflow instead of
# today's direct push) with its own ArchGate, out of scope for this canary.
#
# Functions:
#   publish_lease_acquire <repo> <reason> [ttl_sec] [base_sha]
#       stdout: key:value lease record on success. Exit 0 acquired,
#       2 busy (valid lease held by someone else), 1 other error
#       (network/race lost -- caller may retry).
#   publish_lease_release <repo> <owner> <epoch>
#       Exit 0 released or already absent, 1 mismatch (a newer/different
#       lease is there -- NOT cleared, that would drop someone else's lease).
#   publish_lease_status <repo>
#       stdout: human-readable current lease state (held/free/expired).

PUBLISH_LEASE_REF="${PUBLISH_LEASE_REF:-refs/notes/iwe-publish-lease}"
PUBLISH_LEASE_TTL_SEC_DEFAULT=120
# Clock skew between hosts (Mac, tsekh-1) is not otherwise bounded here --
# this is a crude compensation, not NTP verification (cold-context review,
# 25.08, Medium). Applied so a checker whose clock reads slightly ahead
# never treats a still-valid lease as expired; it never shortens a real
# expiry, only avoids stealing one a few seconds early.
PUBLISH_LEASE_CLOCK_SKEW_MARGIN_SEC=5

# hostname:pid, not a security token -- exclusivity is enforced by the
# remote CAS push, not by comparing this string. Known limitation (cold-
# context review, 25.08, Low, accepted for canary): OS pid reuse within a
# lease's TTL window could make an unrelated later process on the same host
# look like a "renewal" of an earlier one instead of a genuinely different
# writer. Low probability for the expected call pattern (occasional
# publish invocations, not a tight-loop daemon) -- not worth a boot-id/
# start-time addition until it actually bites.
# WP-530 Ф24 п.1 (06.09): PUBLISH_LEASE_OWNER lets a caller pin the owner
# string to something stable ACROSS processes. The default hostname:pid is
# right for the publish path (one script run holds the lease start to finish),
# but wrong for a lease a whole agent session holds while short-lived hooks
# check it: every hook invocation is a new pid, so a pid-based owner could
# never recognise its own session's lease. See scripts/neon-prod-lease.sh.
publish_lease_owner_id() {
    if [ -n "${PUBLISH_LEASE_OWNER:-}" ]; then
        printf '%s' "$PUBLISH_LEASE_OWNER"
        return 0
    fi
    printf '%s:%s' "$(hostname -s 2>/dev/null || hostname)" "$$"
}

# publish_lease_current_owner <repo> -- stdout: owner of the ACTIVE lease
# (empty when the ref is absent or the lease has expired). Exit 0 read
# successfully, 1 could not read (network/fetch failure) -- callers must treat
# 1 as "unknown", never as "free" (same reasoning as
# _publish_lease_read_remote's hard error).
publish_lease_current_owner() {
    local repo="$1" remote read_rc=0 current_oid current_record
    remote=$(_publish_lease_read_remote "$repo") || read_rc=$?
    [ "$read_rc" -eq 0 ] || return 1
    current_oid=$(printf '%s\n' "$remote" | head -1)
    [ -n "$current_oid" ] || return 0
    current_record=$(printf '%s\n' "$remote" | tail -n +2)
    local cur_owner cur_expires_at now expires_epoch
    cur_owner=$(_publish_lease_field "$current_record" "owner")
    cur_expires_at=$(_publish_lease_field "$current_record" "expires_at")
    now=$(_publish_lease_now_epoch)
    expires_epoch=$(_publish_lease_to_epoch_secs "$cur_expires_at")
    [ $((expires_epoch + PUBLISH_LEASE_CLOCK_SKEW_MARGIN_SEC)) -le "$now" ] && return 0
    printf '%s' "$cur_owner"
}

# publish_lease_current_epoch <repo> -- stdout: epoch of the lease currently on
# the ref (empty if none). Needed by callers that release a lease they took in
# an EARLIER process and therefore never saw the acquire record.
publish_lease_current_epoch() {
    local repo="$1" remote read_rc=0 current_oid
    remote=$(_publish_lease_read_remote "$repo") || read_rc=$?
    [ "$read_rc" -eq 0 ] || return 1
    current_oid=$(printf '%s\n' "$remote" | head -1)
    [ -n "$current_oid" ] || return 0
    _publish_lease_field "$(printf '%s\n' "$remote" | tail -n +2)" "epoch"
}

_publish_lease_now_epoch() { date -u +%s; }

# _publish_lease_to_epoch_secs <ISO8601> -- portable across BSD/GNU date
# (same two-attempt pattern already used by gather-session-facts.sh, WP-484
# Ф26 -- a single-form parse broke duration math on macOS once).
_publish_lease_to_epoch_secs() {
    local iso="$1"
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null \
        || date -u -d "$iso" +%s 2>/dev/null \
        || echo 0
}

_publish_lease_expires_at() {  # _publish_lease_expires_at <ttl_sec>
    local ttl="$1"
    date -u -v+"${ttl}"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "+${ttl} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# _publish_lease_read_remote <repo> -- line 1: current remote OID (empty if
# the ref doesn't exist), remaining lines: the lease record text (empty if
# absent). ls-remote alone can't give the commit message, hence the extra
# scoped fetch. Scratch local ref is suffixed with $$ -- concurrent callers
# on the same host/repo path only share the REMOTE ref, this local one is
# purely a read scratch space and never part of the CAS itself.
# Return code matters here, not just stdout (cold-context review, 25.08 --
# Critical): the earlier version treated a failed content-fetch the same as
# "ref doesn't exist" (both fell through to `return 0` with an empty record).
# But ls-remote had already succeeded and printed a REAL oid -- a caller
# reading empty owner/epoch/expires_at from that then saw an active lease as
# free, computed push_expect from the (correct!) oid it already had, and the
# CAS push legitimately succeeded because that oid genuinely was still
# current -- silently overwriting someone else's still-valid lease. CAS only
# protects against a stale *oid*, not against misreading the *content* behind
# a correctly-read oid. A transient fetch failure must now fail loudly
# (return 1) so the caller refuses to guess.
_publish_lease_read_remote() {
    local repo="$1" oid="" scratch_ref="refs/iwe-lease-scratch/current-$$"
    oid=$(git -C "$repo" ls-remote origin "$PUBLISH_LEASE_REF" 2>/dev/null | awk '{print $1; exit}')
    echo "$oid"
    [ -n "$oid" ] || return 0
    if ! git -C "$repo" fetch origin "${PUBLISH_LEASE_REF}:${scratch_ref}" --quiet --force 2>/dev/null; then
        echo "WARN: publish-lease: ref существует (oid=$oid), но fetch содержимого не удался -- не могу проверить, свободна ли лиза" >&2
        return 1
    fi
    git -C "$repo" log -1 --format=%B "$scratch_ref" 2>/dev/null
    git -C "$repo" update-ref -d "$scratch_ref" 2>/dev/null || true
}

# _publish_lease_field <record> <field> -- same convention as
# publish-queue.sh markers: first "^field: " match wins.
_publish_lease_field() {
    printf '%s\n' "$1" | sed -n "s/^$2: //p" | head -1
}

publish_lease_acquire() {
    local repo="$1" reason="$2" ttl="${3:-$PUBLISH_LEASE_TTL_SEC_DEFAULT}" base_sha="${4:-}"
    # Cold-context review, 25.08 -- Critical: an unvalidated ttl that both
    # BSD and GNU `date` fail to parse (negative, non-numeric) previously
    # produced an empty expires_at, which every reader (including this same
    # function on its next call) parses as epoch 0 -- "always already
    # expired". That silently defeats exclusivity for the entire lifetime of
    # the lease, not just this one call, with no warning at write time.
    [[ "$ttl" =~ ^[1-9][0-9]*$ ]] || {
        echo "WARN: publish-lease: ttl должен быть положительным целым числом секунд, получено '$ttl'" >&2
        return 1
    }
    reason="${reason//$'\n'/ }"
    base_sha="${base_sha//$'\n'/ }"
    local owner
    owner=$(publish_lease_owner_id)

    local remote read_rc=0 current_oid current_record
    remote=$(_publish_lease_read_remote "$repo") || read_rc=$?
    if [ "$read_rc" -ne 0 ]; then
        echo "WARN: publish-lease: не удалось надёжно прочитать текущее состояние лизы -- отказываю в acquire (можно повторить)" >&2
        return 1
    fi
    current_oid=$(printf '%s\n' "$remote" | head -1)
    current_record=$(printf '%s\n' "$remote" | tail -n +2)

    local next_epoch=1 push_expect=""
    if [ -n "$current_oid" ]; then
        local cur_owner cur_epoch cur_expires_at now expires_epoch
        cur_owner=$(_publish_lease_field "$current_record" "owner")
        cur_epoch=$(_publish_lease_field "$current_record" "epoch")
        cur_expires_at=$(_publish_lease_field "$current_record" "expires_at")
        now=$(_publish_lease_now_epoch)
        expires_epoch=$(_publish_lease_to_epoch_secs "$cur_expires_at")
        if [ $((expires_epoch + PUBLISH_LEASE_CLOCK_SKEW_MARGIN_SEC)) -gt "$now" ] && [ "$cur_owner" != "$owner" ]; then
            echo "WARN: publish-lease: занята -- владелец $cur_owner, epoch $cur_epoch, истекает $cur_expires_at" >&2
            return 2
        fi
        [[ "$cur_epoch" =~ ^[0-9]+$ ]] && next_epoch=$((cur_epoch + 1))
        push_expect="$current_oid"
    fi

    local issued_at expires_at record empty_tree new_commit
    issued_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    expires_at=$(_publish_lease_expires_at "$ttl")
    # Belt-and-braces alongside the ttl validation above: if `date` itself
    # still failed for some other reason, refuse rather than write a record
    # no reader can honor.
    [ -n "$expires_at" ] || {
        echo "WARN: publish-lease: не удалось вычислить expires_at -- acquire отменён" >&2
        return 1
    }
    record=$(printf 'owner: %s\nepoch: %s\nissued_at: %s\nexpires_at: %s\nbase_sha: %s\nreason: %s\n' \
        "$owner" "$next_epoch" "$issued_at" "$expires_at" "${base_sha:--}" "${reason:--}")
    empty_tree=$(git -C "$repo" hash-object -t tree /dev/null)
    new_commit=$(git -C "$repo" commit-tree "$empty_tree" -m "$record")

    # WP-530 Ф24 п.1 (06.09): the push's stderr used to go straight to
    # /dev/null, so EVERY failure -- a genuine CAS rejection (someone else's
    # push landed first) and a LOCAL push mechanism refusing to run at
    # all (client-side pre-push hook, no network, auth) -- printed the same
    # "кто-то захватил лизу" message. That is actively misleading for the
    # second class: a caller told "someone else has it, retry" will spin
    # forever retrying a push that a LOCAL hook rejects every single time,
    # when the real fix is unrelated to contention (live example: the
    # canonical-checkout freeze hook, .githooks/pre-push-file, rejects
    # EVERY push from that toplevel regardless of who holds anything --
    # see inbox/bugs/bug-2026-09-05-day-close-lock-vs-canonical-freeze.md, the
    # same collision hit day-close-lock.sh first). A real CAS rejection's
    # stderr names the ref as stale/rejected; anything else is a mechanism
    # failure and gets its own return code so the caller can say so plainly
    # instead of recommending a retry that cannot succeed.
    local push_err push_rc=0
    push_err=$(git -C "$repo" push --force-with-lease="${PUBLISH_LEASE_REF}:${push_expect}" \
        origin "${new_commit}:${PUBLISH_LEASE_REF}" --quiet 2>&1) || push_rc=$?
    if [ "$push_rc" -ne 0 ]; then
        if printf '%s' "$push_err" | grep -qiE 'stale info|already exists|rejected.*lease'; then
            echo "WARN: publish-lease: CAS-push отклонён -- кто-то захватил лизу между чтением и записью" >&2
            return 1
        fi
        echo "WARN: publish-lease: push не выполнен по причине, НЕ связанной с занятостью лизы -- повтор бесполезен, пока не устранена сама причина:" >&2
        printf '%s\n' "$push_err" >&2
        return 3
    fi

    printf '%s' "$record"
}

publish_lease_release() {
    local repo="$1" owner="$2" epoch="$3"
    local remote read_rc=0 current_oid current_record
    remote=$(_publish_lease_read_remote "$repo") || read_rc=$?
    if [ "$read_rc" -ne 0 ]; then
        echo "WARN: publish-lease: не удалось надёжно прочитать текущее состояние лизы -- release отменён (можно повторить)" >&2
        return 1
    fi
    current_oid=$(printf '%s\n' "$remote" | head -1)
    [ -n "$current_oid" ] || return 0
    current_record=$(printf '%s\n' "$remote" | tail -n +2)
    local cur_owner cur_epoch
    cur_owner=$(_publish_lease_field "$current_record" "owner")
    cur_epoch=$(_publish_lease_field "$current_record" "epoch")
    if [ "$cur_owner" != "$owner" ] || [ "$cur_epoch" != "$epoch" ]; then
        echo "WARN: publish-lease: release пропущен -- текущая лиза (owner=$cur_owner epoch=$cur_epoch) уже не наша (owner=$owner epoch=$epoch)" >&2
        return 1
    fi
    git -C "$repo" push --force-with-lease="${PUBLISH_LEASE_REF}:${current_oid}" \
        origin ":${PUBLISH_LEASE_REF}" --quiet 2>/dev/null || {
        echo "WARN: publish-lease: release CAS-push отклонён -- лиза уже изменилась" >&2
        return 1
    }
    return 0
}

publish_lease_status() {
    local repo="$1"
    local remote read_rc=0 current_oid current_record
    remote=$(_publish_lease_read_remote "$repo") || read_rc=$?
    if [ "$read_rc" -ne 0 ]; then
        echo "publish-lease: не удалось прочитать состояние (см. stderr)"
        return 1
    fi
    current_oid=$(printf '%s\n' "$remote" | head -1)
    if [ -z "$current_oid" ]; then
        echo "publish-lease: свободна (ref не существует)"
        return 0
    fi
    current_record=$(printf '%s\n' "$remote" | tail -n +2)
    local cur_owner cur_epoch cur_expires_at now expires_epoch tag
    cur_owner=$(_publish_lease_field "$current_record" "owner")
    cur_epoch=$(_publish_lease_field "$current_record" "epoch")
    cur_expires_at=$(_publish_lease_field "$current_record" "expires_at")
    now=$(_publish_lease_now_epoch)
    expires_epoch=$(_publish_lease_to_epoch_secs "$cur_expires_at")
    tag="держит"
    [ $((expires_epoch + PUBLISH_LEASE_CLOCK_SKEW_MARGIN_SEC)) -le "$now" ] && tag="истекла (можно перехватывать)"
    echo "publish-lease: $tag -- owner=$cur_owner epoch=$cur_epoch expires_at=$cur_expires_at"
}
