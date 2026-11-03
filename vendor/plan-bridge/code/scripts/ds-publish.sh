#!/bin/bash
# ds-publish.sh — единственная точка публикации в origin/main для плановых
# (автоматических, без человека рядом) скриптов ночного цикла DS-my-strategy.
#
# WP-484, дизайн согласован в пир-сессиях с Codex (sessions/2026-08/17/2026-08-17-01-week-open-race-codex/)
# и Kimi (sessions/2026-08/17/2026-08-17-02-publish-gate-implementation/), АрхГейт пройден.
#
# Проблема, которую закрывает: инцидент 17.08 — открытие недели закоммитило
# результат в общей рабочей копии, но push отклонён (в origin/main уже был
# коммит от другого планового скрипта), а повторная попытка (fetch+rebase)
# упала на незакоммиченных файлах, оставленных в той же общей копии кем-то
# ещё — тот же класс гонки, из-за которого 14.08 заморозили общую копию для
# людей и агентов (WP-520), просто плановые скрипты в эту заморозку не попали.
#
# Не переизобретает git-механику: саму публикацию (fetch + временный worktree
# от свежего origin + cherry-pick + push + bounded retry) делает уже
# существующий и отдельно пир-ревьюженный scripts/isolate-push.sh (WP-484
# Ф102, 16.08) — тот же инструмент, которым уже пользуется закрытие
# интерактивных сессий после заморозки WP-520. Найдено в этой же сессии
# грепом по всему scripts/ ПЕРЕД тем, как объявлять миграцию готовой — если
# бы не заметили, получили бы дублирующую git-логику вместо переиспользования
# уже проверенной (P2). Этот скрипт добавляет только то, чего в
# isolate-push.sh нет и что специфично для автоматических (не интерактивных)
# писателей: честная блокировка с приоритетом и жёстким потолком удержания,
# мгновенное оповещение в Телеграм на каждый исход, локальный аудит-журнал,
# аварийный клапан на самокрайний случай.
#
# Контракт: caller сам готовит изменения в СВОЕЙ изолированной worktree-копии
# (создаёт worktree от свежего origin/main, коммитит туда) и передаёт путь
# сюда. Этот скрипт коммит не создаёт и не меняет.
#
# Приоритет — честная политика (не преимущественный захват): FIFO-очередь на
# одном локальном замке, но у каждого держателя жёсткий потолок удержания
# (timeout+kill), так что худшее ожидание для high ограничено потолком
# normal, а не его фактическим временем работы. Если алерт "high ждал >20с"
# сработает 2+ раз за 30 дней — переходить на двухуровневый lock, не раньше
# (явный критерий, сессия с Kimi 17.08).
#
# Usage: ds-publish.sh <worktree-path> <high|normal> [--reason "<text>"]
#                                                      [--from-commit <sha>]
#                                                      [--exact-commit <sha>]
#                                                      [--quiet-ok]
#                                                      [--mode single-shot|retry-wrapper]
#                                                      [--max-attempts N] [--deadline-sec D]
#
# --mode retry-wrapper (WP-530 Ф7 follow-up, 18.08 peer-session with Codex,
# sessions/2026-08/18/2026-08-18-22-wp530-publish-retry-wrapper/): requires
# --from-commit. Default mode (--mode omitted) is single-shot -- byte-for-byte
# the original behaviour below, unchanged for every existing caller
# (commit-push.sh, night-cycle scripts) that never passes --mode. retry-wrapper
# is a thin outer loop, not a rewrite of the single-shot path: it re-execs this
# same script (`bash "$0" ... --from-commit <recomputed-sha>`, no --mode) on
# exit 20 (conflict), so the hardened lock/watchdog/bypass logic below never
# runs twice or gets bypassed by a half-refactored fast path. On exit 20 it
# re-fetches origin/main, tries to re-apply the ORIGINAL commit's patch onto
# the fresh tip in a disposable scratch worktree: applies cleanly -> genuine
# staleness, commit again and retry the child call; doesn't apply -> genuine
# content conflict (someone else touched the same lines), not retriable, exits
# 22 immediately rather than burning the attempt budget on a conflict retrying
# can't fix. Backoff is full-jitter (random 0..min(cap, base*2^attempt)) so
# concurrent retriers don't resynchronize into the same thundering herd they're
# trying to avoid. Every attempt (success, retry, or give-up) is appended as
# one JSON line to $DS_PUBLISH_RETRY_LOG for AC #2 (attempt/frequency
# observability) -- see scripts/tests/ds-publish-retry-wrapper-smoke.sh.
#
# --from-commit <sha> (WP-484 Ф108/Ф111, 17.08 peer-session with Codex,
# sessions/2026-08/17/2026-08-17-14-ds-publish-migration-tails/): opt-in mode
# for callers that commit into a SHARED, not isolated, checkout (day-open-
# pipeline.sh, week-open-day-section-patch.sh, month-open-orchestrator.sh --
# all three commit into the live DS-my-strategy tree, not their own copy).
# isolate-push.sh requires the passed path to have a fully clean
# `git status --porcelain` (untracked included, no exceptions) -- a shared
# checkout with 9+ concurrent agent sessions routinely fails that, on files
# that have nothing to do with the caller's own commit (confirmed live 17.08:
# a stray untracked file from an unrelated session was present at review
# time). With --from-commit, this script creates its own disposable worktree
# on a NAMED branch (not --detach: isolate-push.sh explicitly refuses a
# detached HEAD) pointed at that single commit, publishes only that isolated
# copy, and always removes both the worktree and the temp branch on exit --
# the caller's shared checkout is never touched. Without --from-commit, the
# positional <worktree-path> is used as-is (original contract: caller already
# prepared an isolated copy).
#
# Exit codes: 0 успех · 10 high timeout на захвате лока · 11 normal timeout
# на захвате лока · 20 конфликт при переносе коммитов (isolate-push.sh exit 3,
# временный worktree сохранён для ручного разбора, путь — в алерте; в
# retry-wrapper — попытки исчерпаны/дедлайн истёк, конфликт так и не
# разрешился) · 21 push не удался после retry (isolate-push.sh exit 1) ·
# 22 (только --mode retry-wrapper) патч не применился на свежий origin/main —
# подтверждённый конфликт содержимого, не устаревание, дальше ретраить
# бессмысленно · 23 требуется ручное действие: непереносимая история
# (isolate-push.sh exit 2) либо безопасная передача/очистка промежуточного
# конфликта не завершилась · 30 watchdog kill (превышен потолок удержания) ·
# 40 сработал bypass-токен (операция успешна, код только для audit)
# Conditional mode: 31 = base_changed before send; 75 = publication unconfirmed.
# --expected-base B requires single-shot --from-commit C --exact-commit C,
# with exactly one parent B. It returns DS_EXPECTED_BASE_RECEIPT, never replay.
set -euo pipefail

# Canonical convergence is optional post-publication work, separate from push
# proofs and receipts. A caller with its own synchronized handoff may own it.
# Export the validated mode through retry wrappers and isolate-push children.
DS_PUBLISH_CANON_SYNC="${DS_PUBLISH_CANON_SYNC:-automatic}"
case "$DS_PUBLISH_CANON_SYNC" in
    automatic|caller) ;;
    *) echo "ERROR: DS_PUBLISH_CANON_SYNC must be automatic or caller" >&2; exit 1 ;;
esac
export DS_PUBLISH_CANON_SYNC

# SCRIPT_DIR/IWE_WORKSPACE resolved here (not further down where they used to
# live) because --status (WP-484 Ф138, 25.08) has to short-circuit before the
# positional WORKTREE/PRIORITY requirement below -- it takes no worktree, no
# priority, just reads the queue.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IWE_WORKSPACE="${IWE_WORKSPACE:-$HOME/IWE}"
# WP-568 Ф10: set by the single-shot path; never inherited from a caller.
PUBLISH_PHASE=
# shellcheck disable=SC2034  # consumed by is_ds_repo_by_origin() in the sourced lib below
IWE_ROOT="$IWE_WORKSPACE"
# shellcheck source=lib/publish-queue.sh
. "$SCRIPT_DIR/lib/publish-queue.sh"
# shellcheck source=lib/publish-gate.sh
# normalize_remote_url/is_ds_repo_by_origin reused below (post-publish
# canon-refresh trigger) -- same predicate publish-gate.sh's own callers
# already use to decide whether a repo routes through this gateway at all.
. "$SCRIPT_DIR/lib/publish-gate.sh"
# shellcheck source=lib/publish-lease.sh
# Cross-host CAS fencing (WP-561 Ф4, wiring the Ф139 primitive) -- flock below
# only serializes writers on THIS host; the lease adds a remote check for the
# other host(s) (Mac + tsekh-1) sharing this repo. Cooperative, not server
# enforcement -- see publish-lease.sh's own header.
. "$SCRIPT_DIR/lib/publish-lease.sh"

if [ "${1:-}" = "--status" ]; then
    QUEUE_DIR="${DS_PUBLISH_QUEUE_DIR:-$IWE_WORKSPACE/.claude/state/ds-publish-queue}"
    publish_queue_status_report "$QUEUE_DIR"
    exit 0
fi

# F228: retain the source fence across all retries and disposable copies.
RELEASE_GATE="$(dirname "${BASH_SOURCE[0]}")/session_local_release.py"
if ! python3 "$RELEASE_GATE" publisher-check "$1" >/dev/null 2>&1; then
  exec python3 "$RELEASE_GATE" publisher "$1" -- bash "$0" "$@"
fi

WORKTREE="${1:?Usage: ds-publish.sh <worktree-path> <high|normal> [--reason \"text\"] [--from-commit <sha>] [--quiet-ok] | ds-publish.sh --status}"
PRIORITY="${2:?Usage: ds-publish.sh <worktree-path> <high|normal> [--reason \"text\"] [--from-commit <sha>] [--quiet-ok] | ds-publish.sh --status}"
shift 2
REASON=""
# WP-538 Ф7 (11.09): run correlation id as its own argument — never parsed
# out of --reason text (that copy is 8 chars, for humans) — travels into the
# admission queue and the digest as a structured field.
RUN_ID=""
FROM_COMMIT=""
EXACT_COMMIT=""
EXPECTED_BASE=""
QUIET_OK=false
FORCE_NOTIFY=false
MODE="single-shot"
MAX_ATTEMPTS=5
DEADLINE_SEC=300
while [ $# -gt 0 ]; do
    case "$1" in
        --reason) REASON="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --from-commit) FROM_COMMIT="$2"; shift 2 ;;
        --exact-commit) EXACT_COMMIT="$2"; shift 2 ;;
        --expected-base)
            [ "$#" -ge 2 ] && [ -n "$2" ] && [ -z "$EXPECTED_BASE" ] || exit 1
            EXPECTED_BASE="$2"; shift 2 ;;
        # WP-538 (18.08, пир-сессия с Codex + прямой запрос пилота): рутинный
        # успех планового писателя без действия для пилота не должен лететь
        # в Telegram real-time — только failure/conflict/manual_action_required
        # интересны сразу. audit_log ниже пишет исход независимо от этого флага.
        --quiet-ok) QUIET_OK=true; shift ;;
        # WP-538 (20.08, пир-сессия с Codex, консенсус): явный обратный
        # opt-in — caller осознанно хочет видеть подтверждение успеха этой
        # конкретной публикации в реалтайме, вместо дефолтного log-only.
        --notify-ok) FORCE_NOTIFY=true; shift ;;
        --mode) MODE="$2"; shift 2 ;;
        --max-attempts) MAX_ATTEMPTS="$2"; shift 2 ;;
        --deadline-sec) DEADLINE_SEC="$2"; shift 2 ;;
        *) echo "ERROR: unknown arg $1" >&2; exit 1 ;;
    esac
done

case "$MODE" in
    single-shot|retry-wrapper) ;;
    *) echo "ERROR: --mode must be single-shot or retry-wrapper, got '$MODE'" >&2; exit 1 ;;
esac

# WP-530 (29.09, cold-review of the peer-session fix below): RUN_ID lands
# verbatim as a trailing TSV field in audit_log() -- a tab or newline inside
# it would silently split one log entry into a garbled extra line, defeating
# the very forensics this field exists for. The one caller today
# (publish-gate.sh's publish_commit()) already sanitizes before export, but
# that's the caller's discipline, not this script's contract -- validating
# here matches --scheduled-run-id's own pattern in session-guard.sh.
if [ -n "$RUN_ID" ] && ! [[ "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    echo "ERROR: --run-id должен соответствовать ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\$, получено '$RUN_ID'" >&2
    exit 1
fi

# WP-539 F21 B5 (30.10): the receipt-gap log named no caller, so a lost receipt could not be
# traced to a script. Pass the stated reason to isolate-push.sh, which normalizes it where it
# writes the log; the caller chain is computed there too, only when an entry is written
# (process lookups here shifted the timing of the queue marker that ds-publish-queue-smoke.sh
# measures). This block runs before every isolate-push.sh call and before the retry-wrapper
# starts its children (bash "$0"), and a child inherits the parent's value.
IWE_PUBLICATION_REASON="${IWE_PUBLICATION_REASON:-$REASON}"
export IWE_PUBLICATION_REASON

# Failed-command text for the unexpected-failure journals (audit_log TSV and
# the retry JSONL): one line, credentials masked, capped at 200 chars. Defined
# before every ERR trap below so the traps can always call it. Explicit
# character classes instead of sed's I flag -- BSD sed (Mac) lacks it.
sanitize_failed_cmd() {
    local s=${1//[$'\t\n\r']/ }
    s=$(printf '%s' "$s" | sed -E \
        -e 's#(://)[^/@ ]+@#\1***@#g' \
        -e 's/(([Tt][Oo][Kk][Ee][Nn]|[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww]([Oo][Rr])?[Dd])[A-Za-z_]*[=: ]+)[^ ]+/\1***/g' \
        -e 's/([Bb][Ee][Aa][Rr][Ee][Rr]|[Bb][Aa][Ss][Ii][Cc]) +[^ ]+/\1 ***/g')
    printf '%s' "${s:0:200}"
}

case "$PRIORITY" in
    high)   ACQUIRE_TIMEOUT=30; MAX_HOLD=90; ALERT_WAIT_THRESHOLD=20 ;;
    normal) ACQUIRE_TIMEOUT=30; MAX_HOLD=30; ALERT_WAIT_THRESHOLD=999999 ;;
    *) echo "ERROR: priority must be high or normal, got '$PRIORITY'" >&2; exit 1 ;;
esac

# `.git` — файл (gitdir-pointer), не директория, для настоящих linked worktree
# (`git worktree add`), а не только для обычных клонов — найдено живым тестом
# 17.08: `[ -d "$WORKTREE/.git" ]` пропускал ровно тот случай, ради которого
# писался шлюз (caller готовит изменения в изолированной worktree-копии).
# Тот же способ проверки, что уже использует isolate-push.sh. В --from-commit
# режиме $WORKTREE — источник коммита (может быть shared checkout, не
# изолированный), а не то, что передаётся в isolate-push.sh -- достаточно
# знать, что это git-репозиторий вообще, содержащий нужный коммит.
git -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "ERROR: $WORKTREE is not a git worktree" >&2; exit 1; }

if [ -n "$FROM_COMMIT" ]; then
    FROM_COMMIT_INPUT="$FROM_COMMIT"
    FROM_COMMIT=$(git -C "$WORKTREE" rev-parse --verify "$FROM_COMMIT^{commit}" 2>/dev/null) \
        || { echo "ERROR: $FROM_COMMIT_INPUT is not a commit reachable in $WORKTREE" >&2; exit 1; }
    # The caller's SOURCE commit, for the gateway's receipt claim. Set once: the retry wrapper
    # re-invokes this script with a recomputed squash commit that must never replace it (a
    # squash can be garbage-collected after the scratch branch is removed).
    export IWE_PUBLICATION_SOURCE_COMMIT="${IWE_PUBLICATION_SOURCE_COMMIT:-$FROM_COMMIT}"
fi

if [ -n "$EXACT_COMMIT" ]; then
    [ -n "$FROM_COMMIT" ] \
        || { echo "ERROR: --exact-commit требует --from-commit" >&2; exit 1; }
    EXACT_COMMIT=$(git -C "$WORKTREE" rev-parse --verify "$EXACT_COMMIT^{commit}" 2>/dev/null) \
        || { echo "ERROR: --exact-commit не является коммитом в $WORKTREE" >&2; exit 1; }
fi

if [ -n "$EXPECTED_BASE" ]; then
    [ "$MODE" = single-shot ] && [ -n "$FROM_COMMIT" ] && [ "$EXACT_COMMIT" = "$FROM_COMMIT" ] \
        || { echo "ERROR: expected base requires single-shot and identical from/exact commits" >&2; exit 1; }
    # Parent/ancestry evidence must describe the objects that Git sends, not a
    # local refs/replace view that could disguise a non-append candidate.
    export GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null
    EXPECTED_BASE=$(git -C "$WORKTREE" rev-parse --verify "$EXPECTED_BASE^{commit}" 2>/dev/null) \
        || { echo "ERROR: invalid expected base" >&2; exit 1; }
    [ "$(git -C "$WORKTREE" rev-list --parents -n 1 "$EXACT_COMMIT")" = "$EXACT_COMMIT $EXPECTED_BASE" ] \
        || { echo "ERROR: conditional candidate must have exactly the expected parent" >&2; exit 1; }
fi

# --- notify-инфраструктура, поднята сюда из блока ниже (WP-530 "Осталось
# после Ф9", 19.08 peer-session с Kimi) -- retry-wrapper ниже теперь тоже
# вызывает tg_notify на итоговый give-up/confirmed-conflict, а не только
# single-shot путь. retry-wrapper требует эти объявления доступными ДО входа
# в свой блок: это намеренный coupling (Kimi, ход 3), не побочный эффект --
# retry-wrapper без notify-инфраструктуры не может сообщить о своём исходе.
# Проверено (ход 3-4): нет subshell-изоляции вокруг retry-wrapper (плоский
# `if`, set -euo pipefail единообразен на весь файл), $REASON уже установлена
# парсингом аргументов выше -- перенос безопасен.
# SCRIPT_DIR/IWE_WORKSPACE уже определены в самом начале файла (нужны там для
# ранней ветки --status).
TELEGRAM_LIB="$SCRIPT_DIR/lib/telegram.sh"
# notify_translate нужна до первого вызова tg_notify (fail() вызывает её в
# command substitution раньше, чем tg_notify успевает лениво подгрузить
# TELEGRAM_LIB) — сорсим отдельно и заранее, файл без секретов/сети, чем и
# отличается от TELEGRAM_LIB.
# shellcheck source=lib/notification-render.sh
. "$SCRIPT_DIR/lib/notification-render.sh"
# WP-568 Ф4 (14.10, peer-session with Kimi+Codex): mirror the canon-desync
# alerts below into the Центр's silent counter, same pattern already used by
# tsekh1-git-sync.sh for the sibling "fail:tsekh1-git-sync:-" signal. Fail-open
# by construction (notification_center_bridge_send always returns 0) -- safe
# to call unconditionally after the existing tg_notify, no change to the
# direct Telegram path.
# shellcheck source=lib/notification-center-bridge.sh
. "$SCRIPT_DIR/lib/notification-center-bridge.sh"
# WP-538 Ф8 (26.10, пир-сессия Kimi+Codex): политика повторов алерта
# «high-priority ждал N секунд» — 1ч → 4ч → 24ч, затяжное ожидание (≥4ч) уходит
# в эскалацию notify_escalation_update вместо обычной отправки.
# shellcheck source=lib/notify-retry-policy.sh
. "$SCRIPT_DIR/lib/notify-retry-policy.sh"
# WP-538: caller уже передаёт --reason (день/неделя/журнал/что публикуется),
# но раньше он оставался в $REASON и никуда не подставлялся — все уведомления
# звучали одинаково ("Публикация изменений"), пилот не мог понять, о какой
# именно публикации речь.
NOTIFY_LABEL="Публикация изменений"
[ -n "$REASON" ] && NOTIFY_LABEL="Публикация изменений ($REASON)"

# The allowlist channel of ds-publish is "decision": a send reaches the live
# chat only when TELEGRAM_NEEDS_DECISION=1 is set for it (the pilot must act
# now — a stash to restore, an active bypass, a stuck high-priority commit);
# everything else goes to the morning digest (WP-568 Ф10).
tg_notify() {
    if [ -f "$TELEGRAM_LIB" ]; then
        # shellcheck source=lib/telegram.sh
        . "$TELEGRAM_LIB"
        telegram_send "$1" || echo "WARN: telegram_send failed" >&2
    fi
}

# notify_route <status> [--retries-exhausted]: единая точка решения "куда идёт
# этот исход" (WP-538, 20.08, консенсус с Codex) — realtime (Telegram сейчас),
# digest (файл, day-close читает и суммирует одним сообщением) или log-only
# (ничего, кроме audit_log выше по вызывающему коду). Заменяет прежние прямые
# `tg_notify "$(notify_translate ...)"`, которые ВСЕГДА шли в реалтайм
# независимо от того, что говорил сам текст (найденное противоречие: fail/
# conflict уже признавали "действие не нужно прямо сейчас", но канал не
# слушал текст). channel="log-only" явно не делает ничего — не путать с
# digest: notify_channel в notification-render.sh различает эти два канала.
notify_route() {
    # A recursive single-shot belongs to retry-wrapper's private recovery
    # attempt. It must not publish an intermediate digest/realtime outcome:
    # the parent may prove the conflict stale and delete that worktree. The
    # wrapper emits exactly one final outcome after classification instead.
    [ "${DS_PUBLISH_RETRY_CHILD:-0}" = "1" ] && return 0

    local status="$1"
    # WP-568 Ф10: the ERR trap fires on any failed command; name the phase so
    # the text states whether the changes reached the server.
    if [ "$status" = "unexpected" ]; then
        case "${PUBLISH_PHASE:-}" in
            published) status=unexpected_after_publish ;;
            push-failed) status=unexpected_after_push_fail ;;
            before) status=unexpected_before_publish ;;
        esac
    fi
    # The pilot's decision is needed now only for manual_action_required; the
    # allowlist channel "decision" lets exactly these sends reach the live chat.
    # WP-568 (30.10): an urgent send must say what to do and where, or the gate
    # demotes it to the digest. The gate appends this line to the message.
    local TELEGRAM_NEEDS_DECISION=0 TELEGRAM_ACTION=""
    if [ "$status" = "manual_action_required" ]; then
        TELEGRAM_NEEDS_DECISION=1
        TELEGRAM_ACTION="открой чат с агентом и скажи, как довести публикацию до конца"
    fi
    local extra=()
    [ "${2:-}" = "--retries-exhausted" ] && extra+=(--retries-exhausted)
    [ "$FORCE_NOTIFY" = true ] && extra+=(--force-notify)
    local channel
    # ${extra[@]+"${extra[@]}"}, not the bare form: on bash 3.2 (macOS default,
    # where a pilot running this directly resolves to) expanding "${extra[@]}"
    # on an empty array aborts under set -u -- same class already fixed in
    # ledger-publish.sh's extra_args (bug-2026-08-25-notification-dedup-
    # crashes-on-bash-3.2.md).
    channel="$(notify_channel "$status" ${extra[@]+"${extra[@]}"})"
    local dedup_key
    dedup_key="$(notify_dedup_key "$REASON")"
    # WP-538 Ф7: class of incident for the bot-wide window — status + this
    # script's allowlist source-id + stage; no repo/date/run_id in it (Codex,
    # round 1: run_id in the key would make three parallel runs three "new"
    # incidents and bypass the limiter). run_id rides along separately.
    local incident_key
    incident_key="$(notify_incident_key "$status" ds-publish publish)"

    # Восстановление (WP-538, всплеск 20-21.08, пир-сессия с Codex):
    # status=ok после подавленных fail/conflict с тем же ключом -- сказать
    # пилоту явно, что починилось, а не оставлять его гадать по тишине.
    # Нет подавленного состояния -- notify_dedup_clear ничего не находит,
    # ok идёт своим обычным маршрутом (log-only) без лишнего сообщения.
    if [ "$status" = "ok" ] && notify_dedup_clear "$dedup_key"; then
        tg_notify "$(notify_translate recovered "$NOTIFY_LABEL")"
    fi

    case "$channel" in
        realtime)
            if { [ "$status" = "fail" ] || [ "$status" = "conflict" ]; } \
                && ! notify_dedup_allow "$status" "$dedup_key"; then
                notify_digest_append "$status" "$NOTIFY_LABEL" \
                    "подавлено дедупом — повтор в пределах ${NOTIFY_DEDUP_TTL_MIN:-60} мин"
            else
                local msg
                if { [ "$status" = "fail" ] || [ "$status" = "conflict" ]; } \
                    && [ "$NOTIFY_DEDUP_WAS_REPEAT" = true ]; then
                    # TTL уже истёк и алерт разрешён (ветка выше не
                    # сработала), но notify_dedup_allow сообщила, что
                    # state-файл для этого ключа уже существовал -- это не
                    # первый алерт, а очередное напоминание о длящейся
                    # проблеме (WP-538, 24.08).
                    msg="$(notify_translate "$status" "$NOTIFY_LABEL" --repeat)"
                else
                    msg="$(notify_translate "$status" "$NOTIFY_LABEL")"
                fi
                # Глобальный лимит realtime-сообщений на весь бот (WP-538,
                # 01.09, сессия 18) -- per-source дедуп выше не спасает от
                # нескольких НЕЗАВИСИМЫХ источников, решивших слать "первый
                # алерт" в одно и то же окно (несколько репозиториев сломались
                # разом). manual_action_required исключён из гейта намеренно
                # (консенсус с Codex) -- это тот случай, когда пилоту реально
                # нужно решение прямо сейчас, откладывать его в очередь нельзя.
                local dispatched
                if [ "$status" = "manual_action_required" ]; then
                    # Исключён из ГЛОБАЛЬНОГО гейта намеренно (см. выше) -- но
                    # это не защищало от буквального повтора ОДНОГО И ТОГО ЖЕ
                    # решения (живой дамп 09.10: "restore stranded publish-
                    # gate.sh fix" дважды за минуту -- ни разу не было TTL-
                    # дедупа ни на одном уровне). Короткое окно (по умолчанию
                    # 5 мин, не общие 60 у fail/conflict) гасит именно этот
                    # повтор, не трогая обход глобального гейта ниже.
                    #
                    # Ключ -- `notify_dedup_key_full` (полный REASON), НЕ общий
                    # $dedup_key (производитель до первого ":"): тот нарочно
                    # грубый ради fail/conflict (там это терпимо, см. комментарий
                    # у notify_dedup_key), но здесь схлопнул бы два РАЗНЫХ
                    # срочных решения одного источника в "одно и то же" -- тот
                    # самый случай, которому manual_action_required обязан не
                    # давать ждать (найдено cold-context review этой сессии).
                    local manual_dedup_key
                    manual_dedup_key="$(notify_dedup_key_full "$REASON")"
                    if NOTIFY_DEDUP_TTL_MIN="${NOTIFY_MANUAL_ACTION_DEDUP_TTL_MIN:-5}" \
                        notify_dedup_allow manual_action_required "$manual_dedup_key"; then
                        tg_notify "$msg"
                        # Обязано пометить окно занятым для ВСЕХ ОСТАЛЬНЫХ
                        # realtime-источников -- иначе следующий realtime-
                        # триггер (например завершающий ту же цепочку fail
                        # --retries-exhausted) проходит через
                        # notify_admission_allow бесплатно, будто окно всё ещё
                        # свободно (WP-538 Ф8, 08.09, пир-сессия с Kimi -- один
                        # из каналов, порождавших 2-3 Telegram-сообщения на
                        # один сбой публикации). Best-effort: сбой мьютекса
                        # здесь не должен блокировать уже отправленное
                        # manual_action_required.
                        notify_admission_mark_sent 2>/dev/null || true
                    else
                        notify_digest_append manual_action_required "$NOTIFY_LABEL" \
                            "подавлено дедупом -- повтор того же решения в пределах ${NOTIFY_MANUAL_ACTION_DEDUP_TTL_MIN:-5} мин" "$RUN_ID"
                    fi
                elif dispatched="$(notify_admission_dispatch "$NOTIFY_LABEL" "$msg" --key "$incident_key" --run-id "$RUN_ID")"; then
                    tg_notify "$dispatched"
                else
                    # Подавлено общим лимитом -- не пропадает: копия уходит в
                    # дневной digest как страховка на случай, если следующий
                    # realtime-триггер (который бы сделал flush очереди) так
                    # и не наступит сегодня (anti-starvation, консенсус с
                    # Codex, сессия 18).
                    notify_digest_append "$status" "$NOTIFY_LABEL" \
                        "подавлено общим лимитом realtime-сообщений (${NOTIFY_ADMISSION_WINDOW_MIN:-15} мин) — $msg" "$RUN_ID"
                fi
            fi
            ;;
        digest)   notify_digest_append "$status" "$NOTIFY_LABEL" "" "$RUN_ID" ;;
        log-only) : ;;
    esac
}

# --- retry-wrapper: полностью самодостаточная ветка, выходит из скрипта до
# лока/watchdog/bypass ниже. Рекурсивные вызовы себя же идут БЕЗ --mode
# (single-shot по умолчанию) -- вся хардненая логика ниже выполняется только
# в дочернем процессе, без дублирования и без риска разъехаться с ней.
if [ "$MODE" = "retry-wrapper" ]; then
    [ -n "$FROM_COMMIT" ] \
        || { echo "ERROR: --mode retry-wrapper требует --from-commit (пересчитывать коммит можно только от известного исходного SHA)" >&2; exit 1; }

    # WP-530 "Осталось после Ф9" follow-up (19.08, peer-session с Codex):
    # MAX_ATTEMPTS/DEADLINE_SEC приходят из CLI без проверки -- невалидное
    # значение (0, отрицательное, не-число) не падает здесь, а проявляется
    # позже в арифметике (RAW_MS=$(( BACKOFF_BASE_MS * (1 << (ATTEMPT - 1)) ))
    # на "$ATTEMPT - 1" даёт отрицательный сдвиг при ATTEMPT=0) -- trap этого
    # не заменяет (Codex, ход 3): нужна валидация входов до цикла, не защита
    # после факта.
    [[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] \
        || { echo "ERROR: --max-attempts должен быть положительным целым, получено '$MAX_ATTEMPTS'" >&2; exit 1; }
    [[ "$DEADLINE_SEC" =~ ^[1-9][0-9]*$ ]] \
        || { echo "ERROR: --deadline-sec должен быть положительным целым, получено '$DEADLINE_SEC'" >&2; exit 1; }

    # Every child conflict created by this wrapper carries an opaque token in
    # its attempt passport. Only this wrapper can later claim that exact
    # conflict for stale-retry cleanup; another wrapper or a manual resume
    # wins the registry CAS instead of racing a destructive `--force` remove.
    RETRY_CLEANUP_TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(16))' 2>/dev/null || true)
    [[ "$RETRY_CLEANUP_TOKEN" =~ ^[0-9a-f]{32}$ ]] \
        || { echo "ERROR: retry-wrapper: не удалось создать cleanup token" >&2; exit 1; }
    export DS_PUBLISH_RETRY_CLEANUP_TOKEN="$RETRY_CLEANUP_TOKEN"

    # WP-530 follow-up (19.08, Codex ход 3-4): fallback, не единственная линия
    # защиты -- явные ||-ветки на git/mktemp/date остаются основным путём
    # (retry_log + tg_notify с точным контекстом отказа). Этот trap ловит то,
    # что ни одна || не поймала: голое присваивание/арифметику, упавшую под
    # set -e без явной обработки. RETRY_WRAPPER_HANDLED (аналог
    # DS_PUBLISH_HANDLED ниже по файлу, но локальный для этого блока --
    # DS_PUBLISH_HANDLED там объявлен позже, использовать его здесь нельзя)
    # не даёт trap сработать повторно после explicit exit из уже
    # обработанной ветки.
    # audit_log() is defined only after this block, so the trap records the
    # cause in the retry journal (RETRY_LOG) via log_unexpected_retry().
    log_unexpected_retry() {  # log_unexpected_retry <exit> <line> <sanitized cmd>
        python3 -c '
import json, sys
ts, worktree, ec, line, cmd = sys.argv[1:]
print(json.dumps({"ts": ts, "worktree": worktree, "reason": "unexpected",
                  "result_code": int(ec), "line": line, "cmd": cmd}))' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WORKTREE" "$1" "$2" "$3" \
            >> "${RETRY_LOG:-${TMPDIR:-/tmp}/ds-publish-retry.jsonl}" 2>/dev/null \
            || echo "WARN: не удалось записать причину сбоя в журнал повторов" >&2
    }
    trap 'ec=$?; fcmd=$BASH_COMMAND; fline=$LINENO; [ "$ec" -ne 0 ] && [ -z "${RETRY_WRAPPER_HANDLED:-}" ] && { fcmd=$(sanitize_failed_cmd "$fcmd"); echo "ERROR: retry-wrapper: неожиданный отказ (exit=$ec, line=$fline, cmd=$fcmd), см. stderr выше" >&2; log_unexpected_retry "$ec" "$fline" "$fcmd"; notify_route unexpected; }' ERR

    RETRY_LOG="${DS_PUBLISH_RETRY_LOG:-$IWE_WORKSPACE/.claude/state/ds-publish-retry.jsonl}"
    mkdir -p "$(dirname "$RETRY_LOG")" 2>/dev/null || RETRY_LOG="${TMPDIR:-/tmp}/ds-publish-retry.jsonl"

    retry_log() {  # retry_log <attempt> <base_sha> <tip_sha> <result_code> <sleep_ms>
        python3 -c '
import json, sys
ts, worktree, reason, attempt, max_attempts, base_sha, tip_sha, result_code, sleep_ms = sys.argv[1:]
print(json.dumps({
    "ts": ts, "worktree": worktree, "reason": reason,
    "attempt": int(attempt), "max_attempts": int(max_attempts),
    "base_sha": base_sha, "tip_sha": tip_sha,
    "result_code": int(result_code), "sleep_ms": int(sleep_ms),
}))' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WORKTREE" "$REASON" \
            "$1" "$MAX_ATTEMPTS" "$2" "$3" "$4" "$5" >> "$RETRY_LOG" 2>/dev/null \
            || echo "WARN: не удалось дописать $RETRY_LOG" >&2
    }

    # Диапазон, а не один коммит (cold-context review 18.08 -- Critical):
    # isolate-push.sh переносит ВЕСЬ merge-base($FROM_COMMIT,origin/main)..
    # $FROM_COMMIT (rev-list --reverse, isolate-push.sh:89), не только сам
    # $FROM_COMMIT. В общем $WORKTREE (9+ параллельных сессий, из-за чего
    # --from-commit вообще существует) впереди $FROM_COMMIT вполне может
    # стоять чужой ещё не опубликованный коммит той же цепочки -- диффать
    # только "$FROM_COMMIT^..$FROM_COMMIT" на каждой попытке тихо роняет его
    # из пересчитанного патча (найдено ревью ДО деплоя, не живьём). Патч
    # фиксируется ОДИН раз от исходного диапазона и переприменяется как есть
    # на каждой попытке -- не передиффовывается от CURRENT_COMMIT (тот после
    # первой же успешной пересборки становится синтетическим squash-коммитом
    # поверх НОВОГО tip; его собственный диапазон уже включает чужие коммиты
    # с origin/main, и передифф от него задвоил бы их).
    ORIGINAL_BASE=$(git -C "$WORKTREE" merge-base "$FROM_COMMIT" origin/main 2>/dev/null) \
        || { echo "ERROR: retry-wrapper: не нашёл merge-base между $FROM_COMMIT и origin/main" >&2; retry_log 1 "$FROM_COMMIT" "?" 21 0; notify_route fail --retries-exhausted; RETRY_WRAPPER_HANDLED=1; exit 21; }
    RANGE_COMMIT_COUNT=$(git -C "$WORKTREE" rev-list --count "${ORIGINAL_BASE}..${FROM_COMMIT}")
    if [ "$RANGE_COMMIT_COUNT" -eq 1 ]; then
        ORIGINAL_COMMIT_MSG=$(git -C "$WORKTREE" log -1 --format=%B "$FROM_COMMIT")
        ORIGINAL_AUTHOR=$(git -C "$WORKTREE" log -1 --format='%an <%ae>' "$FROM_COMMIT")
        ORIGINAL_DATE=$(git -C "$WORKTREE" log -1 --format=%aI "$FROM_COMMIT")
    else
        # Несколько коммитов в диапазоне -- пересборка на retry неизбежно
        # squash'ит их в один (у нас один патч, не серия), явно проговариваем
        # это в сообщении коммита, не маскируем под оригинальную историю.
        # Автора/дату первого коммита диапазона берём как приближение -- точная
        # атрибуция нескольких разных коммитов в одном squash невозможна.
        ORIGINAL_COMMIT_MSG="retry-wrapper: squash of $RANGE_COMMIT_COUNT commits (${ORIGINAL_BASE}..${FROM_COMMIT})

$(git -C "$WORKTREE" log --reverse --format='- %h %s' "${ORIGINAL_BASE}..${FROM_COMMIT}")"
        ORIGINAL_AUTHOR=$(git -C "$WORKTREE" log -1 --format='%an <%ae>' "$(git -C "$WORKTREE" rev-list --reverse "${ORIGINAL_BASE}..${FROM_COMMIT}" | head -1)")
        ORIGINAL_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    fi
    # WP-530 follow-up (19.08, Codex ход 3, ИСПРАВЛЕНО ход 6 после cold-review):
    # изначально полагался на ERR-trap как fallback здесь -- ошибка: trap
    # НЕ срабатывает на explicit `exit` внутри `||`-группы под set -euo
    # pipefail (проверено живым тестом, cold-context review нашёл это как
    # Critical). tg_notify нужен явно, тем же паттерном, что и остальные
    # ||-ветки этого блока -- trap реален только для НЕобёрнутых голых команд.
    ORIGINAL_PATCH_FILE=$(mktemp) \
        || { echo "ERROR: retry-wrapper: mktemp для ORIGINAL_PATCH_FILE не сработал" >&2; notify_route fail --retries-exhausted; RETRY_WRAPPER_HANDLED=1; exit 1; }
    git -C "$WORKTREE" diff "${ORIGINAL_BASE}..${FROM_COMMIT}" > "$ORIGINAL_PATCH_FILE"

    # Trap-покрытие scratch-ресурсов (cold-context review 18.08 -- High):
    # в отличие от --from-commit temp-worktree ниже по файлу (свой trap), эта
    # ветка раньше чистила scratch только инлайн-командами ПОСЛЕ apply/commit
    # -- любой сбой (`git apply`/`add`/`commit` под set -e, SIGTERM) внутри
    # этого окна раньше молча оставлял worktree/branch/patch-файл на диске.
    SCRATCH_DIR=""
    SCRATCH_PARENT=""
    SCRATCH_BRANCH=""
    SCRATCH_CREATED=false
    PRESERVE_SCRATCH_ON_EXIT=false
    ACTIVE_CHILD_CONFLICT=false
    ACTIVE_CHILD_CONFLICT_WT=""
    ACTIVE_CHILD_CONFLICT_COMMITS=""
    RELEASED_CHILD_CONFLICT_WT=""
    cleanup_scratch_worktree() {  # idempotent, safe to call per-iteration AND on EXIT
        local worktree_remove_failed=false

        if [ "$SCRATCH_CREATED" = "true" ]; then
            if git -C "$WORKTREE" worktree remove "$SCRATCH_DIR" --force 2>/dev/null; then
                SCRATCH_CREATED=false
                if ! git -C "$WORKTREE" branch -D "$SCRATCH_BRANCH" >/dev/null 2>&1; then
                    echo "WARN: retry-wrapper: не удалось удалить временную ветку $SCRATCH_BRANCH" >&2
                fi
            else
                worktree_remove_failed=true
                echo "WARN: retry-wrapper: не удалось удалить scratch worktree $SCRATCH_DIR; каталог сохранён" >&2
            fi
        fi

        # SCRATCH_PARENT may exist before `git worktree add` succeeds. Remove
        # it only when no registered worktree cleanup failed; otherwise keep
        # the recoverable checkout instead of deleting its files behind Git.
        if [ -n "$SCRATCH_PARENT" ] && [ "$worktree_remove_failed" != "true" ]; then
            rm -rf "$SCRATCH_PARENT" 2>/dev/null || \
                echo "WARN: retry-wrapper: не удалось удалить временный каталог $SCRATCH_PARENT" >&2
            SCRATCH_PARENT=""
            SCRATCH_DIR=""
            SCRATCH_BRANCH=""
        fi
        [ "$worktree_remove_failed" != "true" ]
    }

    retry_child_conflict_physical_path() {
        local reported_path="$1"
        local expected_commits_csv="$2"
        local lock_dir physical_path last_expected_commit

        [[ "$expected_commits_csv" =~ ^[0-9a-fA-F]{40,64}(,[0-9a-fA-F]{40,64})*$ ]] || {
            echo "ERROR: retry-wrapper: дочерний конфликт не сообщил полный ключ коммитов" >&2
            return 1
        }
        last_expected_commit=${expected_commits_csv##*,}
        [ "$last_expected_commit" = "$CURRENT_COMMIT" ] || {
            echo "ERROR: retry-wrapper: ключ коммитов дочернего конфликта не заканчивается текущим commit" >&2
            return 1
        }

        [ -n "$reported_path" ] && [ -d "$reported_path" ] || {
            echo "ERROR: retry-wrapper: дочерний конфликт не сообщил существующий worktree" >&2
            return 1
        }
        lock_dir=$(dirname "${DS_PUBLISH_LOCK_FILE:-$IWE_WORKSPACE/.claude/state/ds-publish.lock}")
        lock_dir=$(cd "$lock_dir" 2>/dev/null && pwd -P || true)
        physical_path=$(cd "$reported_path" 2>/dev/null && pwd -P || true)
        [ -n "$lock_dir" ] && [ -n "$physical_path" ] || return 1
        case "$physical_path" in
            "$lock_dir"/ds-publish-from-commit-*/.isolate-push-tmp/attempt-*) ;;
            *)
                echo "ERROR: retry-wrapper: дочерний конфликт сообщил путь вне каталога этого вызова" >&2
                return 1
                ;;
        esac
        printf '%s\n' "$physical_path"
    }

    recover_retry_child_conflict_from_registry() {
        local registry recovered

        registry="$HOME/IWE/.iwe-runtime/isolate-push-attempts"
        recovered=$(python3 - "$registry" "$RETRY_CLEANUP_TOKEN" "$CURRENT_COMMIT" <<'PYEOF'
import glob
import json
import os
import sys

registry, token, current_commit = sys.argv[1:4]
candidates = []
for path in glob.glob(os.path.join(registry, "*.json")):
    try:
        with open(path, encoding="utf-8") as source:
            record = json.load(source)
    except (OSError, ValueError):
        continue
    commits = record.get("source_commits")
    if (
        record.get("owner") == "isolate-push"
        and record.get("target_branch") == "main"
        and record.get("retry_cleanup_token") == token
        and record.get("status")
        in {"retry-pending-classification", "retry-cleanup-in-progress"}
        and isinstance(commits, list)
        and commits
        and commits[-1] == current_commit
        and isinstance(record.get("worktree_path"), str)
    ):
        candidates.append(record)
if len(candidates) != 1:
    raise SystemExit(1)
candidate = candidates[0]
print(candidate["worktree_path"])
print(",".join(candidate["source_commits"]))
PYEOF
) || return 1
        ACTIVE_CHILD_CONFLICT_WT=$(printf '%s\n' "$recovered" | sed -n '1p')
        ACTIVE_CHILD_CONFLICT_COMMITS=$(printf '%s\n' "$recovered" | sed -n '2p')
        retry_child_conflict_physical_path "$ACTIVE_CHILD_CONFLICT_WT" "$ACTIVE_CHILD_CONFLICT_COMMITS" >/dev/null || return 1
        return 0
    }

    cleanup_retry_child_conflict_worktree() {
        local reported_path="$1"
        local expected_commits_csv="$2"
        local physical_path conflict_store conflict_parent

        physical_path=$(retry_child_conflict_physical_path "$reported_path" "$expected_commits_csv") || return 1

        # The owner command validates passport identity, operation key,
        # opaque wrapper token, repository and the conflict-state snapshot,
        # then holds the registry lock across claim -> git remove -> finalize.
        # ds-publish must never remove first and validate afterwards: a
        # concurrent manual resume could already own this worktree.
        if ! "$SCRIPT_DIR/isolate-push.sh" --cleanup-retry-conflict \
            "$reported_path" "$WORKTREE" "$expected_commits_csv" main; then
            echo "ERROR: retry-wrapper: безопасная очистка промежуточной конфликтной копии отклонена; retry остановлен" >&2
            [ -d "$physical_path" ] && return 1
            return 2
        fi

        conflict_store=$(dirname "$physical_path")
        conflict_parent=$(dirname "$conflict_store")
        rmdir "$conflict_store" "$conflict_parent" 2>/dev/null || true
        ACTIVE_CHILD_CONFLICT=false
        ACTIVE_CHILD_CONFLICT_WT=""
        ACTIVE_CHILD_CONFLICT_COMMITS=""
        RELEASED_CHILD_CONFLICT_WT=""
        return 0
    }

    release_active_child_conflict() {
        local physical_path

        [ "$ACTIVE_CHILD_CONFLICT" = "true" ] || return 0
        physical_path=$(retry_child_conflict_physical_path "$ACTIVE_CHILD_CONFLICT_WT" "$ACTIVE_CHILD_CONFLICT_COMMITS") || return 1
        if ! "$SCRIPT_DIR/isolate-push.sh" --release-retry-conflict "$physical_path" "$WORKTREE" "$ACTIVE_CHILD_CONFLICT_COMMITS" main; then
            echo "ERROR: retry-wrapper: не удалось передать промежуточную копию ручному resume; внутренний паспорт сохранён" >&2
            return 1
        fi
        RELEASED_CHILD_CONFLICT_WT="$physical_path"
        ACTIVE_CHILD_CONFLICT=false
        ACTIVE_CHILD_CONFLICT_WT=""
        ACTIVE_CHILD_CONFLICT_COMMITS=""
        return 0
    }

    require_manual_handoff() {
        local tip_sha="$1"

        release_active_child_conflict && return 0
        retry_log "$ATTEMPT" "$CURRENT_COMMIT" "$tip_sha" 23 0
        notify_route manual_action_required
        RETRY_WRAPPER_HANDLED=1
        exit 23
    }

    # shellcheck disable=SC2329  # invoked by the EXIT trap below
    retry_wrapper_cleanup_on_exit() {
        local primary_rc="$1"
        trap - ERR EXIT
        set +e
        if [ "$ACTIVE_CHILD_CONFLICT" = "true" ]; then
            if release_active_child_conflict; then
                echo "WARN: retry-wrapper: при аварийном выходе конфликт сохранён для следующего ручного resume" >&2
                echo "isolate-push: manual-resume-conflict=$RELEASED_CHILD_CONFLICT_WT"
                echo "$RELEASED_CHILD_CONFLICT_WT"
            else
                echo "ERROR: retry-wrapper: при аварийном выходе конфликт остался во внутреннем retry-паспорте; требуется восстановление по реестру" >&2
            fi
        fi
        [ "$PRESERVE_SCRATCH_ON_EXIT" = "true" ] || cleanup_scratch_worktree || true
        rm -f "$ORIGINAL_PATCH_FILE" 2>/dev/null
        exit "$primary_rc"
    }
    trap 'retry_wrapper_cleanup_on_exit "$?"' EXIT

    CURRENT_COMMIT="$FROM_COMMIT"
    ATTEMPT=1
    # WP-530 follow-up (19.08, Codex ход 3): $(date +%s) внутри арифметики
    # ($(( $(date ...) - START_EPOCH ))) теряет date's exit-статус -- сбой
    # date даёт пустую подстановку, арифметика падает с невнятной ошибкой
    # "syntax error" вместо диагностики про сам date. Явная проверка здесь и
    # на строке ниже (в цикле) -- две отдельные команды, не одна вложенная.
    START_EPOCH=$(date +%s) || { echo "ERROR: retry-wrapper: date +%s не сработал" >&2; notify_route fail --retries-exhausted; RETRY_WRAPPER_HANDLED=1; exit 1; }
    # Full jitter (не exponential-с-фиксированным-множителем): случайный сон
    # 0..cap, а не детерминированный 2^N — иначе 15-20 писателей, упавших в
    # одном раунде flock-очереди почти синхронно, синхронно же и просыпаются
    # для повторной попытки, воссоздавая ту самую давку, от которой должен
    # спасать backoff (согласовано с Codex, ход 1 этой сессии).
    BACKOFF_BASE_MS=1000
    BACKOFF_CAP_MS=20000

    while true; do
        TIP_BEFORE=$(git -C "$WORKTREE" rev-parse origin/main 2>/dev/null || echo "?")
        CHILD_ARGS=("$WORKTREE" "$PRIORITY" --from-commit "$CURRENT_COMMIT")
        [ -n "$REASON" ] && CHILD_ARGS+=(--reason "$REASON")
        [ -n "$RUN_ID" ] && CHILD_ARGS+=(--run-id "$RUN_ID")
        [ "$QUIET_OK" = true ] && CHILD_ARGS+=(--quiet-ok)
        # WP-538 (20.08): дочерний single-shot исполняет реальный success-путь
        # (case "$RC" in 0) ... ниже по файлу) — без проброса верхний
        # --notify-ok не даёт realtime на успехе (найдено code review 20.08).
        [ "$FORCE_NOTIFY" = true ] && CHILD_ARGS+=(--notify-ok)
        # A command used as an `if` condition is exempt from both `set -e`
        # and ERR-trap handling. That makes an expected child conflict (20)
        # ordinary control flow without opening a window where the fallback
        # trap is globally disabled.
        if SINGLE_OUT=$(DS_PUBLISH_RETRY_CHILD=1 bash "$0" "${CHILD_ARGS[@]}" 2>&1); then
            RC=0
        else
            RC=$?
        fi
        if [ "$RC" -ne 20 ]; then
            echo "$SINGLE_OUT"
            retry_log "$ATTEMPT" "$CURRENT_COMMIT" "$TIP_BEFORE" "$RC" 0
            [ "$RC" -eq 0 ] && [ "$ATTEMPT" -gt 1 ] \
                && echo "retry-wrapper: успех на попытке $ATTEMPT/$MAX_ATTEMPTS" >&2
            # WP-530 follow-up (19.08, ход 6, ИСПРАВЛЕНО ход 7 после cold-review):
            # изначально предполагал "дочерний уже уведомил, если RC != 0" --
            # неверно (Codex, ход 5): дочерний single-shot имеет 2 bootstrap-
            # exit 1 (строки ~143, ~425) ДО того, как его собственный
            # fail()/ERR-trap вообще установлены -- allowlist известных кодов
            # тоже отвергнут (Codex: неявный контракт, тихая регрессия при
            # новом коде в будущем). Явное владение: уведомляем ЗДЕСЬ на любой
            # non-0 код, ценой возможного дублирования с уведомлением
            # дочернего (если оно было) -- "молчание хуже дубля" (Codex, ход 5).
            # WP-538 (20.08): этот путь всегда финальный (exit сразу следом,
            # дальше ретрая нет) -- --retries-exhausted, иначе не-конфликтный
            # финальный сбой (push/bootstrap) тихо уходил бы в digest вместо
            # realtime (найдено cold-context review 20.08, Critical).
            case "$RC" in
                0)  notify_route ok ;;
                23) notify_route manual_action_required ;;
                # Emergency bypass is a successful operation with a distinct
                # audit exit code. The child already sent its explicit BYPASS
                # alert directly; a parent fail here would contradict it.
                40) : ;;
                # Lease-busy (another host publishing this minute) is not
                # final: night cycles repeat the call (lib/ds-publish-busy-retry.sh,
                # WP-568 Ф11), an interactive caller sees the exit code. Digest only.
                12) notify_route fail ;;
                *)  notify_route fail --retries-exhausted ;;
            esac
            exit "$RC"
        fi

        MANUAL_RESUME_CONFLICT=$(printf '%s\n' "$SINGLE_OUT" | sed -n 's/^isolate-push: manual-resume-conflict=//p' | tail -1 || true)
        if [ -n "$MANUAL_RESUME_CONFLICT" ]; then
            # A manual owner already won an earlier handoff. Never classify
            # or clean that copy as an internal stale-retry artifact.
            echo "$SINGLE_OUT"
            echo "retry-wrapper: исчерпаны попытки — конфликт уже передан ручному владельцу" >&2
            retry_log "$ATTEMPT" "$CURRENT_COMMIT" "$TIP_BEFORE" 20 0
            notify_route fail --retries-exhausted
            RETRY_WRAPPER_HANDLED=1
            exit 20
        fi

        ACTIVE_CHILD_CONFLICT_WT=$(printf '%s\n' "$SINGLE_OUT" | tail -1 || true)
        ACTIVE_CHILD_CONFLICT_COMMITS=$(printf '%s\n' "$SINGLE_OUT" | sed -n 's/^isolate-push: retry-cleanup-commits=//p' | tail -1 || true)
        if ! retry_child_conflict_physical_path "$ACTIVE_CHILD_CONFLICT_WT" "$ACTIVE_CHILD_CONFLICT_COMMITS" >/dev/null 2>&1; then
            if ! recover_retry_child_conflict_from_registry; then
                retry_log "$ATTEMPT" "$CURRENT_COMMIT" "$TIP_BEFORE" 23 0
                notify_route manual_action_required
                RETRY_WRAPPER_HANDLED=1
                exit 23
            fi
        fi
        ACTIVE_CHILD_CONFLICT=true

        if ! NOW_EPOCH=$(date +%s); then
            require_manual_handoff "$TIP_BEFORE"
            echo "$SINGLE_OUT"
            echo "ERROR: retry-wrapper: date +%s не сработал" >&2
            notify_route fail --retries-exhausted
            RETRY_WRAPPER_HANDLED=1
            exit 1
        fi
        ELAPSED=$(( NOW_EPOCH - START_EPOCH ))
        if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ] || [ "$ELAPSED" -ge "$DEADLINE_SEC" ]; then
            require_manual_handoff "$TIP_BEFORE"
            echo "$SINGLE_OUT"
            retry_log "$ATTEMPT" "$CURRENT_COMMIT" "$TIP_BEFORE" 20 0
            echo "retry-wrapper: исчерпаны попытки ($ATTEMPT/$MAX_ATTEMPTS) или дедлайн (${ELAPSED}s/${DEADLINE_SEC}s) — конфликт не разрешён, сдаюсь" >&2
            notify_route fail --retries-exhausted
            RETRY_WRAPPER_HANDLED=1
            exit 20
        fi

        # exit 20 от дочернего вызова -- проверяем, устарел ли исходный
        # диапазон (пересчитываемо) или это уже настоящий конфликт содержимого
        # (не пересчитываемо). Единственный способ узнать -- попробовать:
        # переприменить ЗАМОРОЖЕННЫЙ исходный патч на свежий tip.
        if ! git -C "$WORKTREE" fetch origin main --quiet; then
            require_manual_handoff "?"
            echo "$SINGLE_OUT"
            echo "ERROR: retry-wrapper: git fetch origin main не прошёл" >&2
            retry_log "$ATTEMPT" "$CURRENT_COMMIT" "?" 21 0
            notify_route fail --retries-exhausted
            RETRY_WRAPPER_HANDLED=1
            exit 21
        fi
        if ! NEW_TIP=$(git -C "$WORKTREE" rev-parse origin/main); then
            require_manual_handoff "?"
            echo "$SINGLE_OUT"
            echo "ERROR: retry-wrapper: не удалось прочитать origin/main после fetch" >&2
            retry_log "$ATTEMPT" "$CURRENT_COMMIT" "?" 21 0
            notify_route fail --retries-exhausted
            RETRY_WRAPPER_HANDLED=1
            exit 21
        fi

        # WP-530 follow-up (19.08, Codex ход 4, TOCTOU-фикс): `mktemp -u -d`
        # только печатал имя, не создавал каталог -- окно между печатью и
        # `git worktree add`, использующим то же имя, было гонкой (второй
        # процесс с тем же PID/паттерном мог напечатать то же имя первым).
        # Codex: `mktemp -d` создаёт РЕАЛЬНЫЙ родительский каталог атомарно
        # (резервирует пространство имён), а `git worktree add` получает
        # несуществующий дочерний путь внутри него -- контракт git ("целевой
        # путь не существует") сохранён, TOCTOU закрыт.
        if ! SCRATCH_PARENT=$(mktemp -d "${TMPDIR:-/tmp}/ds-publish-retry-XXXXXXXX"); then
            require_manual_handoff "$NEW_TIP"
            echo "$SINGLE_OUT"
            echo "ERROR: retry-wrapper: mktemp для scratch-каталога не сработал" >&2
            retry_log "$ATTEMPT" "$CURRENT_COMMIT" "$NEW_TIP" 21 0
            notify_route fail --retries-exhausted
            RETRY_WRAPPER_HANDLED=1
            exit 21
        fi
        SCRATCH_DIR="$SCRATCH_PARENT/worktree"
        SCRATCH_BRANCH="tmp-ds-publish-retry-$$-${ATTEMPT}"
        if ! git -C "$WORKTREE" worktree add -b "$SCRATCH_BRANCH" "$SCRATCH_DIR" "$NEW_TIP" >/dev/null 2>&1; then
            require_manual_handoff "$NEW_TIP"
            echo "$SINGLE_OUT"
            echo "ERROR: retry-wrapper: не удалось создать scratch worktree" >&2
            retry_log "$ATTEMPT" "$CURRENT_COMMIT" "$NEW_TIP" 21 0
            notify_route fail --retries-exhausted
            RETRY_WRAPPER_HANDLED=1
            exit 21
        fi
        SCRATCH_CREATED=true

        APPLY_OK=true
        if [ -s "$ORIGINAL_PATCH_FILE" ]; then
            git -C "$SCRATCH_DIR" apply --check "$ORIGINAL_PATCH_FILE" 2>/dev/null || APPLY_OK=false
        fi
        if [ "$APPLY_OK" = true ]; then
            [ -s "$ORIGINAL_PATCH_FILE" ] && git -C "$SCRATCH_DIR" apply "$ORIGINAL_PATCH_FILE"
            # -A оправдан только здесь: SCRATCH_DIR — одноразовая scratch-копия
            # этого же вызова, созданная секундами раньше пустой от NEW_TIP,
            # в ней нет и не может быть чужих файлов — не общий checkout,
            # к которому относится запрет "никогда git add -A" (AR.*).
            git -C "$SCRATCH_DIR" add -A
            # --committer via -c user.*, --author/--date preserve the ORIGINAL
            # commit's identity/time ("Name <email>" is --author's own accepted
            # format, no separate GIT_AUTHOR_NAME/EMAIL needed).
            git -C "$SCRATCH_DIR" -c user.email="ds-publish-retry@iwe.local" -c user.name="ds-publish-retry" \
                commit -q -m "$ORIGINAL_COMMIT_MSG" --author="$ORIGINAL_AUTHOR" --date="$ORIGINAL_DATE" --allow-empty
            NEW_COMMIT=$(git -C "$SCRATCH_DIR" rev-parse HEAD)
        fi
        # A failed removal keeps SCRATCH_CREATED and all three handles intact.
        # Retry once for a transient Git failure; if it is still registered,
        # stop this retry cycle before the next iteration can overwrite the
        # only path/branch handles and leak an orphaned scratch worktree.
        if ! cleanup_scratch_worktree && ! cleanup_scratch_worktree; then
            PRESERVE_SCRATCH_ON_EXIT=true
            require_manual_handoff "$NEW_TIP"
            echo "$SINGLE_OUT"
            echo "ERROR: retry-wrapper: scratch worktree $SCRATCH_DIR не удалось удалить; retry остановлен до ручного восстановления" >&2
            retry_log "$ATTEMPT" "$CURRENT_COMMIT" "$NEW_TIP" 23 0
            notify_route manual_action_required
            RETRY_WRAPPER_HANDLED=1
            exit 23
        fi

        if [ "$APPLY_OK" != true ]; then
            require_manual_handoff "$NEW_TIP"
            echo "$SINGLE_OUT"
            retry_log "$ATTEMPT" "$CURRENT_COMMIT" "$NEW_TIP" 22 0
            echo "ERROR: retry-wrapper: патч не применился на свежий origin/main — настоящий конфликт содержимого, не устаревание, дальше ретраить бессмысленно" >&2
            notify_route conflict --retries-exhausted
            RETRY_WRAPPER_HANDLED=1
            exit 22
        fi

        # This conflict was classified as stale and a replacement commit was
        # built successfully. The child's preserved diagnostic worktree is no
        # longer the final manual-recovery artifact, so remove it before the
        # next attempt; a final/exhausted conflict remains preserved above.
        # The cleanup function validates and canonicalizes the candidate
        # against both the invocation-owned lock directory and its unique
        # isolate-push passport.
        if cleanup_retry_child_conflict_worktree "$ACTIVE_CHILD_CONFLICT_WT" "$ACTIVE_CHILD_CONFLICT_COMMITS"; then
            CLEANUP_RC=0
        else
            CLEANUP_RC=$?
        fi
        if [ "$CLEANUP_RC" -ne 0 ]; then
            # A still-existing pending copy becomes manual-resumable before
            # its path is exposed. An absent/transient copy is never promised.
            if [ "$CLEANUP_RC" -eq 1 ] && release_active_child_conflict; then
                echo "$SINGLE_OUT"
            fi
            ACTIVE_CHILD_CONFLICT=false
            ACTIVE_CHILD_CONFLICT_WT=""
            ACTIVE_CHILD_CONFLICT_COMMITS=""
            retry_log "$ATTEMPT" "$CURRENT_COMMIT" "$NEW_TIP" 23 0
            notify_route manual_action_required
            RETRY_WRAPPER_HANDLED=1
            exit 23
        fi

        RAW_MS=$(( BACKOFF_BASE_MS * (1 << (ATTEMPT - 1)) ))
        [ "$RAW_MS" -gt "$BACKOFF_CAP_MS" ] && RAW_MS=$BACKOFF_CAP_MS
        SLEEP_MS=$(( RANDOM % (RAW_MS + 1) ))
        retry_log "$ATTEMPT" "$CURRENT_COMMIT" "$NEW_TIP" 20 "$SLEEP_MS"
        echo "retry-wrapper: попытка $ATTEMPT/$MAX_ATTEMPTS устарела, пересчитан коммит $NEW_COMMIT на свежем tip, сплю ${SLEEP_MS}ms" >&2
        # WP-530 follow-up (19.08, Codex ход 3): awk был внешним процессом --
        # его сбой (бинарник недоступен) диагностировался бы уже на sleep,
        # первопричина терялась. printf -- bash builtin, не внешняя команда,
        # исключает этот класс сбоя целиком вместо проверки его результата.
        sleep "$(printf '%d.%03d' "$((SLEEP_MS / 1000))" "$((SLEEP_MS % 1000))")"

        CURRENT_COMMIT="$NEW_COMMIT"
        ATTEMPT=$((ATTEMPT + 1))
    done
fi
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-my-strategy}"
ISOLATE_PUSH="$SCRIPT_DIR/isolate-push.sh"
LOCK_FILE="${DS_PUBLISH_LOCK_FILE:-$IWE_WORKSPACE/.claude/state/ds-publish.lock}"
AUDIT_LOG="${DS_PUBLISH_AUDIT_LOG:-/var/log/iwe/ds-publish.log}"
BYPASS_TOKEN="${DS_PUBLISH_BYPASS_TOKEN:-/var/lib/iwe/emergency/ds-publish-bypass.token}"
QUEUE_DIR="${DS_PUBLISH_QUEUE_DIR:-$IWE_WORKSPACE/.claude/state/ds-publish-queue}"
BRANCH="main"

[ -x "$ISOLATE_PUSH" ] || { echo "ERROR: $ISOLATE_PUSH не найден или не исполняем" >&2; exit 1; }
mkdir -p "$(dirname "$LOCK_FILE")"
mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || AUDIT_LOG="$IWE_WORKSPACE/.claude/state/ds-publish.log"

audit_log() {
    # priority wait_s hold_s result detail worktree pid run_id — append-only,
    # для расследований (Kimi review 17.08: Telegram-алерт не заменяет
    # локальный журнал). pid/run_id добавлены WP-530 (29.09, peer-session с
    # Codex, sessions/2026-09/29/2026-09-29-03-ds-publish-retry-loop/) --
    # живой разбор алертов занял час ручной археологии по .open-семафорам
    # именно потому, что нельзя было отличить "один процесс долго ретраит"
    # от "несколько разных запусков подряд". $$ всегда доступен (без
    # дополнительного плюмбинга); run_id — уже прокидываемый вызывающим
    # `--run-id` (строка ~132), раньше терявшийся на входе в эту функцию.
    # Поля добавлены В КОНЕЦ -- позиционные читатели полей 1-7 не ломаются.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PRIORITY" "${WAIT_S:-?}" "${HOLD_S:-?}" \
        "$1" "${2:-}" "$WORKTREE" "$$" "${RUN_ID:-}" >> "$AUDIT_LOG" 2>/dev/null \
        || echo "WARN: audit_log write to $AUDIT_LOG failed" >&2
}

# WP-530 Ф76 (loudness): canon-reconcile-published.sh keeps its own refusal streak and prints ONE `ALERT` line
# when the same refusal class has lasted long enough (again no more often than its own repeat interval). Its
# lines reach this script by two routes: isolate-push.sh runs the guard right after its push and prefixes every
# line with "isolate-push: " (they land in ISOLATE_OUT); the post-publish call of this script covers the callers
# that got here another way (CANON_RECONCILE_PUBLISHED_OUT). Forward the last ALERT line through the existing
# notification path instead of leaving it in a log nobody reads. Best effort like everything around it, and it
# always returns 0: grep exits 1 when there is no ALERT, and under set -e / pipefail that would turn a published
# change into a failed exit (the WP-5 Ф48 class further down). The marker must open the line (after the optional
# "isolate-push: " prefix): the same words inside a commit subject or a path are not an alert (Codex, peer-session
# 2026-10-01-20). The message goes out as plain text (telegram_send sends no parse mode by default), so nothing in a
# path or a class name can be read as markup; the guard keeps the line to one line.
# describe_canon_writers <semaphore name>...: the pilot cannot act on a
# semaphore file name, so turn each live canonical writer into "agent, work
# product, task, since when" from the semaphore's own fields (WP-568,
# peer-session 2026-10-24-07). Sets CANON_WRITERS_TEXT (one line per writer)
# and CANON_WRITERS_STALE=1 when a writer shows no sign of life: its pid is
# gone on this host and its last heartbeat is older than 30 min.
describe_canon_writers() {
    local sessions="${IWE_RUNTIME_DIR:-${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime}/sessions" name sem agent wp task opened pid host hb hb_epoch alive
    local now; now=$(date -u +%s)
    CANON_WRITERS_TEXT="" CANON_WRITERS_STALE=0
    for name in "$@"; do
        sem="$sessions/$name.open"
        if [ ! -f "$sem" ]; then
            CANON_WRITERS_TEXT="${CANON_WRITERS_TEXT}- сессия ${name} (уже закрыта)"$'\n'
            continue
        fi
        agent=$(sed -n 's/^agent: //p' "$sem" | head -1)
        wp=$(sed -n 's/^wp: //p' "$sem" | head -1)
        task=$(sed -n 's/^task: //p' "$sem" | head -1)
        opened=$(sed -n 's/^opened_at: //p' "$sem" | head -1)
        pid=$(sed -n 's/^pid: //p' "$sem" | head -1)
        host=$(sed -n 's/^host: //p' "$sem" | head -1)
        hb=$(sed -n 's/^heartbeat_at: //p' "$sem" | tail -1)
        alive=0
        if [ -n "$pid" ] && { [ -z "$host" ] || [ "$host" = "$(uname -n)" ]; } && kill -0 "$pid" 2>/dev/null; then
            alive=1
        elif [ -n "$hb" ]; then
            hb_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$hb" +%s 2>/dev/null || date -u -d "$hb" +%s 2>/dev/null || echo 0)
            [ $((now - hb_epoch)) -lt 1800 ] && alive=1
        fi
        [ "$alive" = 1 ] || CANON_WRITERS_STALE=1
        CANON_WRITERS_TEXT="${CANON_WRITERS_TEXT}- ${agent:-агент} по ${wp:-неизвестному РП}${task:+ «${task}»}${opened:+, открыта ${opened}}$([ "$alive" = 1 ] && echo ", работает" || echo ", признаков жизни нет")"$'\n'
    done
}

forward_canon_alert() {  # <text containing the guard's output>
    local alert body ru label="${DS_PUBLISH_HOST_LABEL:-}"
    if [ -z "$label" ]; then   # the message must name the host that raised it: this script runs on the Mac and on other hosts
        case "$(uname -s 2>/dev/null)" in Darwin) label="Мак" ;; *) label=$(hostname -s 2>/dev/null || echo "хост") ;; esac
    fi
    alert=$(printf '%s\n' "$1" | grep -aE '^(isolate-push: )?canon-reconcile-published: ALERT ' | tail -1 || true)   # -a: GNU grep takes input with an invalid byte sequence for a binary file and prints nothing
    [ -n "$alert" ] || return 0
    body="${alert#*canon-reconcile-published: ALERT }"
    # Russian rendering of the known shape; anything else goes out raw rather than not at all.
    # The optional " -- detail: ..." tail (WP-568) carries what follows the class.
    # Fields are joined with the unit separator (0x1F), not \t: BSD sed on the Mac does not expand \t in a replacement.
    local fields canon age count class dirty detail us=$'\037'
    fields=$(printf '%s\n' "$body" | sed -n -E "s/^canon (.+) not reconciled for ([0-9]+) min: ([0-9]+) refusals '(.*)', ([0-9]+) dirty tracked path\(s\) -- an owner must clear the blocking state; next alert in [0-9]+ min( -- detail: (.*))?\$/\1${us}\2${us}\3${us}\4${us}\5${us}\7/p" || true)
    IFS="$us" read -r canon age count class dirty detail <<EOF_FIELDS
$fields
EOF_FIELDS
    audit_log "canon-reconcile-alert" "$alert"
    local channel=realtime
    if [ -z "$fields" ]; then
        ru="канон не сведён с GitHub. ${body:0:3500}"   # cut: Telegram refuses a message over 4096 characters, and an alert of an unknown shape must still arrive
    elif [ "${class#live canonical writer(s)}" != "$class" ]; then   # also "... appeared during preflight"
        # shellcheck disable=SC2086 # detail is a space-separated list of semaphore names
        describe_canon_writers $detail
        ru="копия ${canon} не обновляется с GitHub уже ${age} мин: прямо в ней сейчас пишет сессия агента, а обновлять копию под живым писателем опасно."$'\n'"${CANON_WRITERS_TEXT}"
        if [ "$age" -ge 720 ]; then
            ru="${ru}Нужен человек: копия стоит больше 12 часов. Если эту сессию вы не ведёте - закройте её (или скажите агенту «закрой зависшую сессию»), копия обновится сама."
        elif [ "$CANON_WRITERS_STALE" = 1 ]; then
            ru="${ru}Похоже, сессия зависла. Что делать: если вы её не ведёте - закройте её, копия обновится сама. Если сессия рабочая - ничего не делать."
        elif [ "$age" -lt 240 ]; then
            channel=digest   # a live writer younger than the commit lease is normal work, not news
        else
            ru="${ru}Сессия жива, но держит копию больше 4 часов. Что делать: ничего, если вы над ней работаете; иначе закройте её."
        fi
        # one writer blocks every canon it touches: tell the pilot once per writer set, the other canons go to the digest
        local wkey wdir="${DS_PUBLISH_DIGEST_DIR:-$HOME/IWE/.claude/state/notify-digest}/../canon-writer-alert" wnow wlast
        wkey=$(printf '%s' "$detail" | tr ' ' '\n' | sort | tr '\n' ' ' | cksum | cut -d' ' -f1)
        wnow=$(date -u +%s)
        if [ "$channel" = realtime ] && mkdir -p "$wdir" 2>/dev/null; then
            wlast=$(cat "$wdir/$wkey" 2>/dev/null || true)
            [[ "$wlast" =~ ^[0-9]+$ ]] || wlast=0   # an empty or torn state file must not abort the publisher
            if [ $((wnow - wlast)) -lt 1800 ]; then
                channel=digest
            else
                { printf '%s\n' "$wnow" > "$wdir/$wkey.tmp.$$" && mv -f "$wdir/$wkey.tmp.$$" "$wdir/$wkey"; } 2>/dev/null || true
                ru="${ru}"$'\n'"Другие копии с той же причиной - в вечерней сводке."
            fi
        fi
    else
        ru="канон ${canon} не сведён с GitHub уже ${age} мин; отказов подряд: ${count}, причина: ${class}${detail:+ (${detail})}; грязных отслеживаемых путей: ${dirty}; нужен владелец канона. Что делать: попроси агента свести канон; пока этого нет, в этой копии нет свежих изменений с GitHub."
    fi
    # A copy stuck under a live writer for 12+ hours needs the pilot (close the
    # session); every other canon refusal is information for the digest.
    local needs_decision=0
    case "$ru" in *"Нужен человек"*) needs_decision=1 ;; esac
    if [ "$channel" = digest ]; then
        notify_digest_append notice "${label}: копия не обновляется под живой сессией" "$ru"
    else
        TELEGRAM_NEEDS_DECISION="$needs_decision" \
        TELEGRAM_ACTION="закрой зависшую сессию агента, которая держит копию, или попроси агента свести канон" \
            tg_notify "⚠️ ${label}: ${ru}" || true
    fi
    # WP-568 Ф4 (14.10): mirror into the Центр's silent counter, AFTER the
    # direct send (same order as vscode-remote-watchdog/session-guard -- the
    # centre must not go blind when Telegram itself is down). correlation_id
    # names the canon this host failed to reconcile, not the message text, so
    # repeated ticks of the same stuck canon stay one incident (notify_incident_key
    # convention already used by tsekh1-git-sync.sh's sibling signal).
    local canon_name host_tag
    canon_name=$(printf '%s\n' "$body" | sed -n -E 's/^canon (.+) not reconciled for [0-9]+ min:.*/\1/p')
    host_tag=$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo host)
    notification_center_bridge_send ds-publish yellow "Канон не сведён с GitHub" "$ru" 0 \
        "canon-not-reconciled:${host_tag}:${canon_name:-unknown}"
    return 0
}


# canon-reconcile.sh refuses (exit 1, nothing touched) when UNTRACKED files would be overwritten by
# the fast-forward: they are real, never-published content (02.10.2026: the day's ledger file, whose
# events were carried off by the old `stash -u` behaviour). Until now that refusal ended as the last line
# of canon-reconcile's output in audit_log, so a canon silently falling behind stayed invisible. Forward
# it through the same notification path as forward_canon_alert, but at most once per interval per
# blocker set: every publish re-runs the reconcile, and one alert per publish would be spam. Only this
# refusal class is forwarded; the others (diverged history, an unrecognized git error) are expected
# refusals with their own handling. Best effort, always returns 0 (WP-5 Ф48 class: never turn a
# published change into a failed exit). Message goes out as plain text.
forward_canon_reconcile_refusal() {  # <canon-reconcile exit code> <its output>
    local rc="$1" out="$2" paths key dir state now last interval sorted_paths label="${DS_PUBLISH_HOST_LABEL:-}" class marker
    [ "$rc" != "0" ] || return 0
    # Two classes are forwarded. "untracked": real unpublished files block the fast-forward and nothing
    # was touched. "stash": the fast-forward happened but some stashed content could not be carried over
    # and stays in `git stash list` (26.10.2026: 152 ledger events sat there unnoticed, WP-484 Ф255).
    if printf '%s\n' "$out" | grep -aq 'untracked file(s) would be overwritten'; then
        class=untracked; marker='untracked file(s) would be overwritten'
    elif printf '%s\n' "$out" | grep -aq 'left in stash for manual review'; then
        class=stash; marker='left in stash for manual review'
    elif printf '%s\n' "$out" | grep -aq 'ledger tail NOT safe to reconcile'; then
        class=ledger; marker='ledger tail NOT safe to reconcile'   # refused before anything moved: the tail sits on disk, the canon stays behind
    else
        return 0
    fi
    if [ -z "$label" ]; then
        case "$(uname -s 2>/dev/null)" in Darwin) label="Мак" ;; *) label=$(hostname -s 2>/dev/null || echo "хост") ;; esac
    fi
    # The blocked paths are the non-empty lines AFTER the explanation line (the line that carries the
    # marker) up to the next canon-reconcile: message; anything before it is ignored, so an extra leading
    # line cannot leak into the list.
    paths=$(printf '%s\n' "$out" | awk -v m="$marker" 'index($0, m) {f=1; next} f && NF && $0 !~ /^canon-reconcile:/ {print}' | head -5 | tr '\n' ' ' | sed 's/ *$//')
    audit_log "canon-reconcile-refusal" "${class} blockers: ${paths:-(пути не распознаны)}"
    interval="${DS_PUBLISH_RECONCILE_ALERT_INTERVAL_SEC:-21600}"
    dir="${IWE_RUNTIME_DIR:-${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime}"
    # The key must not depend on the order git lists the paths in: sort them first (sha256, not the
    # 32-bit cksum: two different blocker sets must not share a state file). macOS has no sha256sum
    # (only shasum -a 256) -- same fallback already used by wp-run-scheduled-tsekh1.sh and
    # lib/notification-render.sh; without it this crashed with "sha256sum: command not found" on
    # every Mac call, which isolate-push then logged as a plain publish failure (06.10, WP-5 Ф60
    # observation -- a real push before this point was unaffected, only this throttle key was).
    sorted_paths=$(printf '%s\n' "$paths" | tr ' ' '\n' | sort)
    [ "$class" = untracked ] || sorted_paths="${class}"$'\n'"${sorted_paths:-$(printf '%s' "$out" | head -c 300)}"   # the same paths in another class are another incident; the ledger refusal names its reason in one line, so the line itself keys the throttle
    if command -v sha256sum >/dev/null 2>&1; then
        key=$(printf '%s\n' "$sorted_paths" | sha256sum | cut -c1-16)
    else
        key=$(printf '%s\n' "$sorted_paths" | shasum -a 256 | cut -c1-16)
    fi
    state="$dir/canon-reconcile-alert.$key"
    now=$(date +%s)
    last=$(cat "$state" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if (( now - last >= interval )); then
        local note=""
        # Record the send BEFORE sending. If the state cannot be written the throttle cannot work: say so
        # in the message and the audit instead of silently repeating on every publish as if nothing were wrong.
        if ! { mkdir -p "$dir" 2>/dev/null && printf '%s\n' "$now" > "$state" 2>/dev/null; }; then
            note=" (не удалось записать состояние ограничения повторов: ${dir}; сообщение может повторяться при каждой публикации)"
            audit_log "canon-reconcile-refusal-state-unwritable" "$dir"
        fi
        if [ "$class" = ledger ]; then
            TELEGRAM_NEEDS_DECISION=1 TELEGRAM_ACTION='попроси агента свести канон и разобрать хвост журнала событий вручную' tg_notify "⚠️ ${label}: канон не сведён с GitHub: хвост журнала событий нельзя безопасно перенести, ничего не тронуто (${out:0:400}). Хвост лежит на диске и ждёт публикации; разберите причину и запустите сведение вручную.${note}" || true
            notification_center_bridge_send ds-publish yellow "Канон не сведён: хвост журнала" \
                "хвост журнала нельзя безопасно перенести" 0 "canon-reconcile-ledger:${key}"
            return 0
        fi
        if [ "$class" = stash ]; then
            TELEGRAM_NEEDS_DECISION=1 TELEGRAM_ACTION='посмотри список тайников (git stash list) в каноне и верни несохранённые правки, тайник не сбрасывай' tg_notify "⚠️ ${label}: канон подтянут, но несохранённые изменения не удалось перенести и они лежат в тайнике git stash (${paths:0:600}). Не сбрасывайте тайник: посмотрите git stash list в каталоге репозитория и верните содержимое вручную.${note}" || true
            notification_center_bridge_send ds-publish yellow "Канон: изменения оставлены в тайнике" \
                "пути в тайнике: ${paths:0:200}" 0 "canon-reconcile-stash:${key}"
            return 0
        fi
        TELEGRAM_NEEDS_DECISION=1 TELEGRAM_ACTION='убери или сохрани мешающие неотслеживаемые файлы в каноне и запусти публикацию снова' tg_notify "⚠️ ${label}: канон не сведён с GitHub: неотслеживаемые файлы мешают обновлению (${paths:0:600}). Ничего не удалено и не унесено в stash, разобрать вручную.${note}" || true
        # WP-568 Ф4 (14.10): mirror into the Центр, same reasoning as
        # forward_canon_alert above. $key already identifies this exact
        # blocker set (sha256 of the sorted untracked paths) -- reuse it as
        # the incident's correlation_id instead of minting a second one.
        notification_center_bridge_send ds-publish yellow "Канон не сведён: неотслеживаемые файлы" \
            "неотслеживаемые пути: ${paths:0:200}" 0 "canon-reconcile-refusal:${key}"
    fi
    return 0
}

fail() {
    local code="$1" stage="$2" detail="$3"
    echo "ERROR [$stage]: $detail" >&2
    audit_log "FAIL:$stage" "$detail"
    # WP-538: приоритет/этап/exit-код — техническая деталь, остаётся в stderr
    # и audit_log выше; в Telegram уходит только переведённая фраза.
    local human_status=fail
    case "$stage" in
        conflict) human_status=conflict ;;
        unsupported-history) human_status=manual_action_required ;;
    esac
    # WP-538 (20.08, ИСПРАВЛЕНО после второго cold-context review — Critical):
    # изначально ставил здесь --retries-exhausted безусловно ("эта функция —
    # единственный выход, exit следует сразу же") -- неверно для дочернего
    # single-shot внутри retry-wrapper: fail() отправляет уведомление РАНЬШЕ,
    # чем родитель успевает решить, продолжать retry или нет (RC=20 conflict
    # у дочернего -- это НЕ финал всей recovery-цепочки, родитель ловит его
    # штатно в `if [ "$RC" -ne 20 ]` и может пойти на новую попытку). Realtime
    # до решения родителя -- преждевременное и потенциально ложное
    # уведомление. Без флага fail/conflict уходит в digest по умолчанию;
    # родитель retry-wrapper явно берёт владение realtime-эскалацией в СВОИХ
    # точках знания о финальности (см. notify_route ... --retries-exhausted
    # в ветках "исчерпаны попытки"/"настоящий конфликт content" retry-wrapper
    # цикла) -- то же решение, что уже принято для non-0 non-20 кодов там же.
    # manual_action_required не читает флаг (notify_channel игнорирует его
    # для этого статуса) -- всегда realtime, как и требует консенсус.
    notify_route "$human_status"
    DS_PUBLISH_HANDLED=1
    exit "$code"
}

# Отлавливает то, что не проходит через fail() — bare `VAR=$(cmd)`/mkdir перед
# захватом лока, которые под `set -e` иначе падают молча, без алерта и без
# аудит-записи (review 17.08: обещание «алерт на каждый отказ» держалось
# только явными fail()-вызовами, не покрывало необработанные сбои).
# WP-568 Ф10: single-shot path; nothing has been pushed yet.
PUBLISH_PHASE=before
trap 'ec=$?; fcmd=$BASH_COMMAND; fline=$LINENO; [ "$ec" -ne 0 ] && [ -z "${DS_PUBLISH_HANDLED:-}" ] && { fcmd=$(sanitize_failed_cmd "$fcmd"); audit_log "FAIL:unexpected" "exit=$ec, line=$fline, cmd=$fcmd"; notify_route unexpected; }' ERR

# --- Bypass-токен: строгий парсинг (Kimi review 17.08 — отсутствие/битый
# токен ОБЯЗАН провалиться в штатный путь, не молча "валиден". Файл создаётся
# ТОЛЬКО вручную пилотом, никаким скриптом — иначе это снова кнопка, не аварийный клапан.
parse_bypass_expiry_epoch() {
    local value="$1" parsed
    if parsed=$(date -u -d "$value" +%s 2>/dev/null); then
        printf '%s\n' "$parsed"
        return 0
    fi
    # macOS/BSD date has no GNU `-d`; the emergency token format is strict
    # UTC RFC3339, so parse that exact shape without mutating the system clock.
    if parsed=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$value" +%s 2>/dev/null); then
        printf '%s\n' "$parsed"
        return 0
    fi
    return 1
}

if [ -f "$BYPASS_TOKEN" ]; then
    # cut -f2- (не awk -F=): значение reason само может содержать "=" —
    # -F= у awk резало бы его на первом символе (review 17.08).
    EXPIRES_AT=$(grep '^expires_at=' "$BYPASS_TOKEN" 2>/dev/null | cut -d= -f2-)
    BYPASS_REASON=$(grep '^reason=' "$BYPASS_TOKEN" 2>/dev/null | cut -d= -f2-)
    EXPIRES_EPOCH=$(parse_bypass_expiry_epoch "$EXPIRES_AT" || echo 0)
    NOW_EPOCH=$(date -u +%s)
    if [ -n "$EXPIRES_AT" ] && [ -n "$BYPASS_REASON" ] && [ "$EXPIRES_EPOCH" -gt "$NOW_EPOCH" ]; then
        if [ -n "${IWE_LEDGER_SOURCE_SNAPSHOT:-}" ] || [ -n "$EXPECTED_BASE" ]; then
            echo "ERROR: external or conditional publication cannot use emergency bypass" >&2
            exit 1
        fi
        TELEGRAM_NEEDS_DECISION=1 TELEGRAM_ACTION='выясни, зачем включён обход защиты, и выключи его, когда причина ушла' tg_notify "🆘 ds-publish.sh: BYPASS АКТИВЕН — причина: $BYPASS_REASON. Прямая публикация в обход шлюза (минуя isolate-push.sh). Токен: $BYPASS_TOKEN"
        audit_log "BYPASS" "$BYPASS_REASON"
        if [ -n "$FROM_COMMIT" ]; then
            # Bypass still must not push the caller's shared checkout as-is
            # (it may carry unrelated foreign changes) -- push exactly
            # $FROM_COMMIT via a plain detached checkout, no isolate-push.sh
            # cherry-pick machinery needed since this path skips the gate
            # entirely already.
            git -C "$WORKTREE" push origin "$FROM_COMMIT:$BRANCH" || fail 21 push "bypass: push не удался"
        else
            cd "$WORKTREE"
            git push origin "HEAD:$BRANCH" || fail 21 push "bypass: push не удался"
        fi
        DS_PUBLISH_HANDLED=1
        exit 40
    fi
    echo "WARN: bypass-токен есть, но не прошёл проверку (истёк/битый) — иду штатным путём" >&2
fi

# --- Захват блокировки с приоритетным таймаутом + watchdog на удержание.
# flock отсутствовал в PATH systemd-юнита живьём 29.07 (ledger-append.sh),
# и та потеря события осталась незамеченной, потому что ошибка выглядела как
# обычный таймаут захвата — здесь эта путаница исключена явной проверкой ДО
# захвата, чтобы неверный диагноз не повторился.
command -v flock >/dev/null 2>&1 \
    || fail 1 bootstrap "flock не найден в PATH — проверить systemd Environment=PATH= для юнита (известный класс проблемы, ledger-append.sh 29.07)"

WAIT_START=$(date +%s)

# Очередь видна СРАЗУ, до того как flock вообще начал ждать (WP-484 Ф138,
# 25.08, пилотское решение на АрхГейте: «в очереди видно сразу», не тихое
# ожидание) -- маркер создаётся до flock -w, не после. Это только
# наблюдаемость: сам порядок и взаимное исключение по-прежнему держит flock
# ниже, потеря/устаревание маркера никогда не блокирует и не разблокирует
# публикацию. QUEUE_MARKER пуст при сбое mktemp -- остальной скрипт работает
# как раньше, публикация не должна зависеть от целостности реестра.
# WP-561 Ф4: defined and wired into the EXIT trap here, before the lease is
# even acquired below -- not next to the acquire call -- so a crash between
# QUEUE_MARKER creation and a later, more complete trap replacing this one
# (see the cleanup_temp_worktree trap further down) still has SOME chance of
# releasing the lease. `[ "$LEASE_HELD" = "true" ]` makes every call before
# acquire actually succeeds a safe no-op (cold-review 02.09, Critical -- an
# earlier version left this exact window with no release attempt at all).
LEASE_HELD=false
release_lease_on_exit() {
    [ "$LEASE_HELD" = "true" ] || return 0
    publish_lease_release "$WORKTREE" "$LEASE_OWNER" "$LEASE_EPOCH" >/dev/null 2>&1 || true
}
QUEUE_MARKER=$(publish_queue_mark_waiting "$QUEUE_DIR" "$PRIORITY" "$REASON" "$WORKTREE" 2>/dev/null || echo "")
# shellcheck disable=SC2329  # invoked by the EXIT trap below
early_cleanup_on_exit() {
    local primary_rc="$1"
    trap - ERR EXIT
    set +e
    rm -f "$QUEUE_MARKER" 2>/dev/null
    release_lease_on_exit
    exit "$primary_rc"
}
trap 'early_cleanup_on_exit "$?"' EXIT
if [ -n "$QUEUE_MARKER" ]; then
    AHEAD=$(publish_queue_ahead_count "$QUEUE_DIR" "$QUEUE_MARKER")
    [ "$AHEAD" -gt 0 ] && echo "ds-publish.sh: блокировка занята, впереди $AHEAD (приоритет $PRIORITY) — статус: ds-publish.sh --status" >&2
fi

exec 9>"$LOCK_FILE"
if ! flock -w "$ACQUIRE_TIMEOUT" 9 2>/dev/null; then
    WAIT_S=$ACQUIRE_TIMEOUT
    CODE=10; [ "$PRIORITY" = normal ] && CODE=11
    fail "$CODE" acquire "не удалось захватить блокировку публикации за ${ACQUIRE_TIMEOUT}с (приоритет $PRIORITY)"
fi
[ -n "$QUEUE_MARKER" ] && publish_queue_mark_holder "$QUEUE_MARKER"

# Cross-host lease (WP-561 Ф4): TTL tied to THIS call's actual hold ceiling,
# not the library default -- a mismatch would let the lease outlive or expire
# before the section it's meant to cover. Recompute if MAX_HOLD's constants
# above change.
LEASE_TTL=$((MAX_HOLD + 30))
LEASE_RECORD=""
if LEASE_RECORD=$(publish_lease_acquire "$WORKTREE" "$REASON" "$LEASE_TTL" "${FROM_COMMIT:-}"); then
    LEASE_HELD=true
    LEASE_OWNER=$(_publish_lease_field "$LEASE_RECORD" "owner")
    LEASE_EPOCH=$(_publish_lease_field "$LEASE_RECORD" "epoch")
else
    LEASE_RC=$?
    if [ "$LEASE_RC" -eq 2 ]; then
        # Busy: a different host holds it right now -- the one case the
        # lease exists to catch. Respect it; do not silently proceed.
        fail 12 lease-busy "публикация уже идёт с другого хоста (см. publish-lease.sh status для деталей)"
    fi
    # exit 1 (network/read failure): fail-OPEN, not fail-closed. Documented
    # design choice, not an oversight -- publish-lease.sh is a canary
    # ("cooperative fencing, not enforcement", its own header); making an
    # unproven network primitive a hard blocking dependency for the single
    # most-called script in this whole system is a worse failure mode than
    # the pre-lease status quo it's degrading to. Residual risk (peer-review
    # 02.09, Kimi round 6): if host B genuinely holds the lease AND the read
    # that would have told us so also fails, this host proceeds regardless --
    # the local flock above and isolate-push.sh's own remote-state check are
    # what still catch an actual content collision in that case.
    audit_log "WARN:lease-degraded" "acquire вернул код $LEASE_RC (не 'занята') -- продолжаю без межхостовой лизы"
fi
WAIT_S=$(( $(date +%s) - WAIT_START ))
if [ "$WAIT_S" -gt "$ALERT_WAIT_THRESHOLD" ]; then
    # Fingerprint — sha ожидающего коммита (без растущих чисел: WAIT_S сюда
    # не входит, иначе каждый тик был бы «новым» событием и подавления не
    # было бы вовсе).
    WAIT_COMMIT="${FROM_COMMIT:-$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || echo unknown)}"
    # Третий аргумент — реальный возраст инцидента: ds-publish узнаёт о
    # долгом ожидании только когда оно уже закончилось; без него одно
    # суточное ожидание получало бы «первую отправку» вместо escalate
    # (холодное ревью Codex, 26.10, итерация 2).
    WAIT_GATE=$(notify_repeat_gate "ds-publish-high-wait" "high-priority-wait:$WAIT_COMMIT" "$WAIT_S")
    case "$(head -1 <<< "$WAIT_GATE")" in
        send)
            # Телеметрия для решения о двухуровневом замке, действия от пилота не требует:
            # в дневную сводку (счётчик по метке), не в чат (WP-568, 29.10: три таких
            # сообщения за сутки). Эскалация ниже остаётся в реальном времени.
            notify_digest_append notice "Публикация ждала очереди дольше порога" "⏰ ds-publish.sh: high-priority ждал ${WAIT_S}с (порог ${ALERT_WAIT_THRESHOLD}с) $(sed -n 2p <<< "$WAIT_GATE") — если это повторится 2+ раз за 30 дней, переходим на двухуровневый lock (см. sessions/2026-08/17/2026-08-17-02-publish-gate-implementation/)"
            ;;
        escalate)
            # Затяжное ожидание: не обычный повтор, а эскалация со своей
            # urgent-каденцией (WP-484) — частые подавленные повторы не должны
            # прятать многочасовой простой. --urgent-after-sec 1: срочность
            # немедленная, gate уже отмерил свои 24ч — не начинать urgent-таймер
            # с нуля (холодное ревью Codex, 26.10; 0 невалиден по контракту
            # notify_escalation_update, минимум 1).
            if notify_escalation_update "ds-publish/high-priority-wait" fail --urgent-after-sec 1 --urgent-repeat-after-min 240; then
                TELEGRAM_NEEDS_DECISION=1 TELEGRAM_ACTION='открой чат с агентом и скажи довести застрявшую публикацию до конца' tg_notify "🆘 ds-publish.sh: уже больше $((NOTIFY_REPEAT_ESCALATE_AFTER_SEC / 3600)) часов не удаётся опубликовать high-priority коммит ${WAIT_COMMIT:0:7} (одно долгое ожидание или повторяющиеся попытки) — нужна ручная проверка, кто удерживает публикацию"
            fi
            ;;
    esac
else
    # Быстрый захват после инцидента ожидания = восстановление (холодное
    # ревью Codex, 26.10): сброс политики повторов и закрытие эскалации,
    # иначе следующее реальное ожидание унаследовало бы накопленный возраст
    # и молчало бы до конца чужого окна. Сброс ТОЛЬКО здесь, не после
    # медленного ожидания выше: медленное ожидание того же коммита —
    # продолжение того же инцидента, его повторы должны подавляться
    # (серия «6 раз за 25 минут» из дампа 24.10), а не начинать окно заново.
    if [ -f "$NOTIFY_REPEAT_STATE_DIR/ds-publish-high-wait" ]; then
        notify_repeat_reset "ds-publish-high-wait"
        notify_escalation_update "ds-publish/high-priority-wait" ok > /dev/null
    fi
fi

HOLD_START=$(date +%s)
ISOLATE_OUT_FILE=$(mktemp)
RECEIPT_DEFER_FILE=$(mktemp)
# TEMP_WORKTREE/TEMP_BRANCH stay empty outside --from-commit mode -- the
# cleanup below is then a no-op (`[ -n ... ]` guards both branches).
# TEMP_WORKTREE_CREATED (Codex's turn 18: unconditional cleanup on a
# collided name could delete ANOTHER run's live worktree/branch) is set
# only after `git worktree add` itself succeeds, so a failed/partial
# `--from-commit` setup never tries to remove a resource this invocation
# didn't actually create.
TEMP_WORKTREE_PARENT=""
TEMP_WORKTREE=""
TEMP_BRANCH=""
TEMP_WORKTREE_CREATED=false
PRESERVE_TEMP_WORKTREE_PARENT=false
cleanup_temp_worktree() {
    local parent="$TEMP_WORKTREE_PARENT"
    local inner_store
    local worktree_remove_failed=false

    if [ "$TEMP_WORKTREE_CREATED" = "true" ]; then
        if git -C "$WORKTREE" worktree remove "$TEMP_WORKTREE" --force 2>/dev/null; then
            TEMP_WORKTREE_CREATED=false
            if ! git -C "$WORKTREE" branch -D "$TEMP_BRANCH" >/dev/null 2>&1; then
                echo "WARN: не удалось удалить временную ветку $TEMP_BRANCH" >&2
                audit_log "WARN:temp-branch-cleanup" "$TEMP_BRANCH"
            fi
        else
            worktree_remove_failed=true
            echo "WARN: не удалось удалить временный worktree $TEMP_WORKTREE; каталог сохранён" >&2
            audit_log "WARN:temp-worktree-cleanup" "$TEMP_WORKTREE"
        fi
    fi

    # isolate-push can keep an inner worktree after either a cherry-pick
    # conflict or a non-conflict Git failure. In --from-commit mode that
    # worktree is a sibling of TEMP_WORKTREE under this parent, so recursive
    # parent cleanup would silently destroy the state its output promises to
    # preserve and leave a ghost passport/worktree registration.
    # The parent also covers a crash between mktemp and `worktree add`, when
    # no worktree was registered. Never recursively remove it after a failed
    # `git worktree remove`: preserving recoverable state is safer than
    # leaving a registered worktree whose files disappeared.
    if [ -n "$parent" ] && [ "$PRESERVE_TEMP_WORKTREE_PARENT" != "true" ] && \
       [ "$worktree_remove_failed" != "true" ]; then
        # Remove only directories proven empty. Never recurse into the parent:
        # an inner isolate-push worktree may have been created immediately
        # before an unexpected failure or watchdog termination.
        inner_store="$parent/.isolate-push-tmp"
        [ ! -d "$inner_store" ] || rmdir "$inner_store" 2>/dev/null || true
        if [ -e "$parent" ] && ! rmdir "$parent" 2>/dev/null; then
            echo "WARN: временный каталог $parent не пуст; сохранён для восстановления" >&2
            audit_log "WARN:temp-parent-preserved" "$parent"
        fi
    fi
    if [ "$worktree_remove_failed" != "true" ]; then
        TEMP_WORKTREE_PARENT=""
        TEMP_WORKTREE=""
        TEMP_BRANCH=""
    fi
    return 0
}
# release_lease_on_exit defined earlier (right before QUEUE_MARKER's own
# trap) so BOTH traps can call it -- this one is the fallback for a
# crash/SIGTERM between acquire and the explicit release near flock -u 9
# below; that explicit release already clears LEASE_HELD on success, so the
# normal path never hits this a second time.
# Заменяет более узкий trap, поставленный сразу после создания QUEUE_MARKER
# (bash EXIT trap не накапливается, только последнее объявление действует) --
# от этой строки и до конца скрипта именно этот trap и снимает маркер.
# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup_on_exit() {
    local primary_rc="$1"
    trap - ERR EXIT
    set +e
    rm -f "$ISOLATE_OUT_FILE" "$RECEIPT_DEFER_FILE" 2>/dev/null
    cleanup_temp_worktree
    release_lease_on_exit
    rm -f "$QUEUE_MARKER" 2>/dev/null
    exit "$primary_rc"
}
trap 'cleanup_on_exit "$?"' EXIT

ISOLATE_TARGET="$WORKTREE"
if [ -n "$FROM_COMMIT" ]; then
    # mktemp -d (no -u), same TOCTOU fix already applied to the retry-wrapper
    # path below (line ~453, Codex 19.08 follow-up): `-u` only prints a name
    # without creating it, leaving a window where a second concurrent
    # --from-commit caller could reserve the identical name first (WP-530
    # Ф9, found live 31.08 -- this single-shot path never got the fix that
    # already shipped for the retry-wrapper path in the same file). `mktemp
    # -d` atomically creates the real parent directory; the worktree itself
    # goes into a non-existent child path inside it, which is what `git
    # worktree add` requires (a pre-existing empty dir makes git refuse with
    # "already exists").
    TEMP_WORKTREE_PARENT=$(mktemp -d "$(dirname "$LOCK_FILE")/ds-publish-from-commit-XXXXXXXX") \
        || fail 1 bootstrap "mktemp для scratch-каталога --from-commit не сработал"
    # A relative DS_PUBLISH_LOCK_FILE makes mktemp return ./ds-publish-....
    # git -C <source> worktree add <relative-path> resolves that path from
    # <source>, while the later isolate process resolves it from the caller's
    # cwd. Canonicalize once so every consumer addresses the same directory.
    TEMP_WORKTREE_PARENT=$(cd "$TEMP_WORKTREE_PARENT" 2>/dev/null && pwd -P) \
        || fail 1 bootstrap "не удалось канонизировать scratch-каталог --from-commit"
    TEMP_WORKTREE="$TEMP_WORKTREE_PARENT/worktree"
    TEMP_BRANCH="tmp-ds-publish-$(basename "$TEMP_WORKTREE_PARENT")"
    # -b, not --detach: isolate-push.sh explicitly refuses a detached HEAD
    # (its own `rev-parse --abbrev-ref HEAD` check) -- confirmed live 17.08
    # against a scratch repo before writing this.
    git -C "$WORKTREE" worktree add -b "$TEMP_BRANCH" "$TEMP_WORKTREE" "$FROM_COMMIT" >/dev/null 2>&1 \
        || fail 1 bootstrap "git worktree add не удался для --from-commit $FROM_COMMIT"
    TEMP_WORKTREE_CREATED=true
    ISOLATE_TARGET="$TEMP_WORKTREE"
fi

# --kill-after: голый SIGTERM не гарантирует возврат timeout к сроку — git/ssh
# может проглотить TERM (сетевой read застрял) и держать лок сколь угодно
# долго, что ломает саму гарантию потолка удержания (review 17.08, находка 1).
# fd 9 закрыт в дочернем процессе явно (exec 9>&-) — держит лок родитель,
# unlock ниже не зависит от того, что делает isolate-push.sh с его собственными fd.
# set +e один не гарантирует, что ERR-trap не сработает на ненулевой код
# timeout (живой прогон 17.08 — WP-538: конфликт стабильно давал ДВА
# Telegram-уведомления, fail-fallback из trap + верное conflict следом).
# Снимаем сам trap на время секции и восстанавливаем сразу после — так
# сбой исключён структурно, не только опционально через set +e/-e.
trap - ERR
set +e
ISOLATE_ARGS=("$ISOLATE_PUSH" "$ISOLATE_TARGET" "$BRANCH")
if [ -n "$EXACT_COMMIT" ]; then
    ISOLATE_ARGS+=(--exact-commit "$EXACT_COMMIT")
fi
if [ -n "$EXPECTED_BASE" ]; then
    ISOLATE_ARGS+=(--expected-base "$EXPECTED_BASE")
fi
if [ -n "$EXPECTED_BASE" ]; then
    # Stderr may contain hook/Git context; the conditional protocol consumes
    # only bounded stdout and never retains or forwards those diagnostics.
    # shellcheck disable=SC2016  # Expansion belongs to the child shell.
    IWE_PUBLICATION_RECEIPT_DEFER_FILE="$RECEIPT_DEFER_FILE" \
    timeout --kill-after=5 "$MAX_HOLD" bash -c 'exec 9>&-; exec "$0" "$@"' \
        "${ISOLATE_ARGS[@]}" > "$ISOLATE_OUT_FILE" 2>/dev/null
else
    IWE_PUBLICATION_RECEIPT_DEFER_FILE="$RECEIPT_DEFER_FILE" \
    timeout --kill-after=5 "$MAX_HOLD" bash -c 'exec 9>&-; exec "$0" "$@"' \
        "${ISOLATE_ARGS[@]}" > "$ISOLATE_OUT_FILE" 2>&1
fi
RC=$?
# WP-568 Ф10: an unexpected failure after this point must say whether the
# changes already reached the server (the push result is known here).
# 124/137: timeout killed the push; it may have reached the server already, so
# the phase is unknown and the generic text applies.
case "$RC" in
    0) PUBLISH_PHASE=published ;;
    31) PUBLISH_PHASE=before ;;
    75|124|137) PUBLISH_PHASE=unknown ;;
    *) PUBLISH_PHASE=push-failed ;;
esac
set -e
trap 'ec=$?; fcmd=$BASH_COMMAND; fline=$LINENO; [ "$ec" -ne 0 ] && [ -z "${DS_PUBLISH_HANDLED:-}" ] && { fcmd=$(sanitize_failed_cmd "$fcmd"); audit_log "FAIL:unexpected" "exit=$ec, line=$fline, cmd=$fcmd"; notify_route unexpected; }' ERR
HOLD_S=$(( $(date +%s) - HOLD_START ))
# Release the cross-host lease BEFORE the local unlock (not after) -- so a
# same-host waiter that was queued behind our flock never sees a lease that
# is still (needlessly) held once it gets its turn. Guarded, not part of the
# ERR-trap block above: a release failure is a known, non-critical limitation
# (peer-review 02.09) -- the lease just outlives us until its TTL, it does
# not corrupt anything -- so it's logged, not escalated to fail().
if [ "$LEASE_HELD" = "true" ]; then
    if publish_lease_release "$WORKTREE" "$LEASE_OWNER" "$LEASE_EPOCH" >/dev/null 2>&1; then
        LEASE_HELD=false
    else
        audit_log "WARN:lease-release-failed" "лиза (owner=$LEASE_OWNER epoch=$LEASE_EPOCH) не снята явно -- истечёт по TTL (${LEASE_TTL}с)"
    fi
fi
flock -u 9

# WP-530 F154: receipts queued by isolate-push are recorded outside the timed
# section and the lock, so their fetch can no longer push a publish past
# MAX_HOLD. A SHA is queued only after its push succeeded, so this also runs
# when the watchdog killed the later cleanup stages (124/137).
if [ -s "$RECEIPT_DEFER_FILE" ]; then
    RECEIPT_ARGS=("$ISOLATE_TARGET" "$BRANCH" --record-deferred-receipts "$RECEIPT_DEFER_FILE")
    [ -z "$EXACT_COMMIT" ] || RECEIPT_ARGS+=(--exact-commit "$EXACT_COMMIT")
    RECEIPT_RC=0
    # 60 s covers one guard call (its own 45 s bound) for the usual one-SHA queue.
    RECEIPT_OUT=$(timeout --kill-after=5 60 bash "$ISOLATE_PUSH" "${RECEIPT_ARGS[@]}" 2>&1) || RECEIPT_RC=$?
    # The inline path folded these lines into ISOLATE_OUT; keep them in the audit log.
    if [ "$RECEIPT_RC" -ne 0 ] || [ -n "$RECEIPT_OUT" ]; then
        audit_log "receipt-deferred" "rc=$RECEIPT_RC: $(printf '%s' "$RECEIPT_OUT" | tr '\n\t' '  ' | cut -c1-600)"
    fi
fi

# Parse a bounded, single-record response; malformed stdout is neither forwarded
# nor copied to the audit log. Stderr was discarded at the child boundary.
if [ -n "$EXPECTED_BASE" ]; then
    case "$RC" in
        0|31|75|124|137)
            if EXPECTED_RECEIPT=$(python3 - "$ISOLATE_OUT_FILE" "$RC" "$EXPECTED_BASE" "$EXACT_COMMIT" <<'PY_EXPECTED_RECEIPT'
import json
import re
import sys

path, code, base, candidate = sys.argv[1:]
fields = {"schema", "state", "reason", "expected_base", "candidate_oid", "origin_oid"}
outcomes = {
    "0": ("published", "exact_commit_verified"),
    "31": ("base_changed", "base_changed"),
    "75": ("unconfirmed", "push_unknown"),
}


def strict_object(pairs):
    record = {}
    for key, value in pairs:
        if key in record:
            raise ValueError("duplicate field")
        record[key] = value
    return record


try:
    with open(path, "rb") as stream:
        raw = stream.read(4097)
    if len(raw) > 4096:
        raise ValueError("oversized receipt")
    lines = raw.decode("utf-8").splitlines()
    if len(lines) != 1 or not lines[0].startswith("DS_EXPECTED_BASE_RECEIPT "):
        raise ValueError("missing or duplicate receipt")
    record = json.loads(lines[0].split(" ", 1)[1], object_pairs_hook=strict_object)
    if not isinstance(record, dict) or set(record) != fields:
        raise ValueError("unexpected fields")
    if (
        record["schema"] != "ds-expected-base/v1"
        or record["expected_base"] != base
        or record["candidate_oid"] != candidate
        or (record["state"], record["reason"]) != outcomes.get(code)
    ):
        raise ValueError("receipt does not match invocation")
    origin = record["origin_oid"]
    if origin is not None and (
        not isinstance(origin, str)
        or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", origin)
    ):
        raise ValueError("invalid origin")
    if code in ("0", "31") and origin is None:
        raise ValueError("missing origin proof")
    if code == "31" and origin in (base, candidate):
        raise ValueError("base did not change")
    print("DS_EXPECTED_BASE_RECEIPT " + json.dumps(record, sort_keys=True))
except (OSError, ValueError, TypeError, UnicodeError, RecursionError):
    sys.exit(1)
PY_EXPECTED_RECEIPT
            ); then
                : # The original 0/31/75 is bound to the validated receipt.
            else
                RC=75
                EXPECTED_RECEIPT="DS_EXPECTED_BASE_RECEIPT {\"schema\":\"ds-expected-base/v1\",\"state\":\"unconfirmed\",\"reason\":\"push_unknown\",\"expected_base\":\"$EXPECTED_BASE\",\"candidate_oid\":\"$EXACT_COMMIT\",\"origin_oid\":null}"
            fi
            audit_log "conditional:$RC" "expected-base publication result"
            DS_PUBLISH_HANDLED=1
            printf '%s\n' "$EXPECTED_RECEIPT"
            exit "$RC"
            ;;
        3) fail 20 conflict "conditional publication guard refused the candidate" ;;
        2) fail 23 unsupported-history "conditional candidate history refused" ;;
        *) fail 21 push "conditional publication stopped before a verified result" ;;
    esac
fi

ISOLATE_OUT=$(cat "$ISOLATE_OUT_FILE" 2>/dev/null || echo "")

case "$RC" in
    0)
        audit_log "OK" "$(echo "$ISOLATE_OUT" | tail -1)"
        notify_route ok
        echo "OK: published (wait=${WAIT_S}s hold=${HOLD_S}s)"
        echo "$ISOLATE_OUT"
        forward_canon_alert "$ISOLATE_OUT"   # the guard isolate-push ran itself (WP-530 Ф76)
        if [ "$DS_PUBLISH_CANON_SYNC" = caller ]; then
            audit_log "canon-handoff" "canonical convergence belongs to the caller after publication unlock"
            echo "ds-publish: canonical convergence handed to caller"
            exit 0
        fi
        # WP-484 AF post-publish trigger (design agreed this morning's ArchGate,
        # MC-sessions/2026-09/01/2026-09-01-04-wp484-af-canon-staleness/report.md
        # §4 point 1): origin/main just advanced by this commit -- the canonical
        # checkout may now be one commit further behind, regardless of which
        # worktree/session submitted it. is_ds_repo_by_origin below is NOT a
        # redundant belt-and-suspenders check: this script is also invoked
        # directly (not only via publish-gate.sh's own push_or_publish()
        # routing) by callers that can point IWE_GOVERNANCE_REPO at a
        # different repo (e.g. week-open-day-section-patch.sh), so $WORKTREE's
        # origin genuinely can differ from DS-my-strategy's -- this is the one
        # thing standing between that case and refreshing the wrong canonical
        # path. Do not remove it as "obviously always true" (cold-review
        # finding, 01.09). Best-effort, never turns a successful publish into
        # a failed one: canon-refresh.sh is itself fail-safe (no-ops on
        # anything but a clean, purely-behind tree) and is called under
        # `|| true`.
        CANON_DIR="$IWE_WORKSPACE/DS-my-strategy"
        CANON_REFRESH="$IWE_WORKSPACE/scripts/canon-refresh.sh"
        if [ -x "$CANON_REFRESH" ] && [ -d "$CANON_DIR/.git" ] && is_ds_repo_by_origin "$WORKTREE"; then
            CANON_REFRESH_OUT=$(bash "$CANON_REFRESH" "$CANON_DIR" "$BRANCH" 2>&1) || true
            audit_log "canon-refresh" "$(echo "$CANON_REFRESH_OUT" | tail -1)"
        fi
        # WP-530 Ф33: canon-refresh.sh above only fast-forwards a clean tree
        # -- it deliberately no-ops on a dirty one, so a canon that's fallen
        # behind AND carries local edits (isolate-push publishing without
        # anyone syncing the canonical worktree back, the exact live incident
        # that flagged this) stays stale until an agent notices by hand.
        # canon-reconcile.sh covers that case too: it stashes only the paths
        # actually blocking the fast-forward, and drops the stash only when
        # the stashed content turns out byte-identical to what origin already
        # has -- any real difference is left in the stash and named in its
        # output, never silently discarded. Same best-effort contract as
        # canon-refresh.sh above: `|| true`, logged, must never affect this
        # branch's own exit code (WP-5 Ф48's fall-through bug applies here
        # too -- see the comment on that fix below).
        CANON_RECONCILE="$IWE_WORKSPACE/scripts/canon-reconcile.sh"
        if [ -x "$CANON_RECONCILE" ] && [ -d "$CANON_DIR/.git" ] && is_ds_repo_by_origin "$WORKTREE"; then
            CANON_RECONCILE_RC=0
            CANON_RECONCILE_OUT=$(bash "$CANON_RECONCILE" "$CANON_DIR" "$BRANCH" 2>&1) || CANON_RECONCILE_RC=$?
            # WP-538/545 (15.10): the day's ledger file is appended straight into
            # this same checkout, and only reaches origin via ledger-publish.sh's
            # own rate-limited async kick (up to 15 min later on Mac -- see
            # lib/ledger-publish-kick.sh). A reconcile landing inside that window
            # sees the file as untracked-and-blocking and refuses, even though
            # it is about to be committed anyway. If every blocked path is a
            # ledger day file, flush the publisher synchronously once (its own
            # `flock -n` makes this safe even if a kicked run is already in
            # flight -- it just no-ops) and retry the reconcile once before
            # giving up. Any other blocked path (a real, unrelated untracked
            # file) skips this and falls through to the existing refusal
            # unchanged.
            if [ "$CANON_RECONCILE_RC" != 0 ] && printf '%s\n' "$CANON_RECONCILE_OUT" | grep -aq 'untracked file(s) would be overwritten'; then
                CANON_RECONCILE_BLOCKED_PATHS=$(printf '%s\n' "$CANON_RECONCILE_OUT" | awk 'f && NF {print} /untracked file\(s\) would be overwritten/ {f=1}')
                if [ -n "$CANON_RECONCILE_BLOCKED_PATHS" ] \
                   && ! printf '%s\n' "$CANON_RECONCILE_BLOCKED_PATHS" | grep -qv '^machine/ledger/day/'; then
                    LEDGER_PUBLISH="$CANON_DIR/scripts/ledger-publish.sh"
                    if [ -x "$LEDGER_PUBLISH" ]; then
                        audit_log "canon-reconcile-ledger-retry" "blocked on ${CANON_RECONCILE_BLOCKED_PATHS//$'\n'/, } -- flushing ledger before retry"
                        bash "$LEDGER_PUBLISH" >/dev/null 2>&1 || true
                        CANON_RECONCILE_RC=0
                        CANON_RECONCILE_OUT=$(bash "$CANON_RECONCILE" "$CANON_DIR" "$BRANCH" 2>&1) || CANON_RECONCILE_RC=$?
                    fi
                fi
            fi
            audit_log "canon-reconcile" "$(echo "$CANON_RECONCILE_OUT" | tail -1)"
            forward_canon_reconcile_refusal "$CANON_RECONCILE_RC" "$CANON_RECONCILE_OUT"
        fi
        # WP-530 Ф38: third shape -- history diverged because this very publish
        # path republishes the canon's own commits under new SHAs. isolate-push.sh
        # already calls canon-reconcile-published.sh right after its push (that
        # covers session-guard close too); this call is the belt for callers that
        # reach here through a different route, and is a no-op when the ref has
        # already been reconciled. Same best-effort contract as the two above.
        # Skipped when isolate-push already ran it for this very publish (its
        # output is prefixed and lands in ISOLATE_OUT) -- a second run against
        # the same state would only produce a second refusal (cold review 11.09).
        CANON_RECONCILE_PUBLISHED="$IWE_WORKSPACE/scripts/canon-reconcile-published.sh"
        if [ -x "$CANON_RECONCILE_PUBLISHED" ] && [ -d "$CANON_DIR/.git" ] && is_ds_repo_by_origin "$WORKTREE" \
           && ! printf '%s' "$ISOLATE_OUT" | grep -q 'canon-reconcile-published:'; then
            CANON_RECONCILE_PUBLISHED_OUT=$(bash "$CANON_RECONCILE_PUBLISHED" "$CANON_DIR" "$BRANCH" 2>&1) || true
            audit_log "canon-reconcile-published" "$(echo "$CANON_RECONCILE_PUBLISHED_OUT" | tail -1)"
            forward_canon_alert "$CANON_RECONCILE_PUBLISHED_OUT"   # WP-530 Ф76
        fi
        # WP-5 Ф48 (found live 02.09): without an explicit exit, the script's
        # own exit status falls through to whatever the canon-refresh `if`
        # above last evaluated to -- when CANON_REFRESH doesn't exist/isn't
        # executable (e.g. IWE_WORKSPACE pointed at a caller's isolated
        # sandbox that has no scripts/ dir), that `if`'s condition is false
        # and its own exit status is 1, silently turning a genuinely
        # successful publish (push already confirmed above) into a reported
        # failure for the caller. canon-refresh is documented fail-safe and
        # optional; it must never affect this branch's own exit code.
        exit 0
        ;;
    124)
        fail 30 watchdog "критическая секция превысила потолок удержания ${MAX_HOLD}с и была прервана. isolate-push вывод: $ISOLATE_OUT"
        ;;
    2)
        fail 23 unsupported-history "isolate-push.sh: непереносимая история (merge-коммит в диапазоне) — нужен ручной разбор. Вывод: $ISOLATE_OUT"
        ;;
    3)
        TEMP_WT=$(echo "$ISOLATE_OUT" | tail -1)
        if [ -n "$TEMP_WORKTREE_PARENT" ] && [ -d "$TEMP_WT" ]; then
            case "$TEMP_WT" in
                "$TEMP_WORKTREE_PARENT"/.isolate-push-tmp/*)
                    PRESERVE_TEMP_WORKTREE_PARENT=true
                    ;;
            esac
        fi
        fail 20 conflict "конфликт при переносе коммитов — worktree $WORKTREE не тронут, временная копия для ручного разбора: $TEMP_WT. Вывод: $ISOLATE_OUT"
        ;;
    *)
        fail 21 push "isolate-push.sh упал (код $RC) после собственных повторных попыток — коммит остаётся в $WORKTREE, не потерян. Вывод: $ISOLATE_OUT"
        ;;
esac
