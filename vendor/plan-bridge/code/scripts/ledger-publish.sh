#!/bin/bash
# ledger-publish.sh — sole owner of commit/fetch/rebase/push for machine/ledger/*.yaml
#
# WP-503, АрхГейт по находке 3 (05.08, вариант Г, пир-сессия с Codex —
# sessions/2026-08/05/2026-08-05-17-wp503-ledger-sync-archgate/report.md §4).
# Root problem this closes: none of the 5 night pipeline scripts on tsekh-1 ever
# commits or pushes machine/ledger/*.yaml — data only reached Mac by accident,
# when a human happened to commit the same file during an unrelated interactive
# session on the same host (WP-503.md, diagnosis 05.08, finding 3).
#
# Design (decided in the peer session; activation-tested 09.08 — see GATE below):
# - ledger-append.sh is untouched: stays a local-only primitive, no network.
# - This script is the ONLY thing that commits/fetches/rebases/pushes the ledger.
# - Runs against a DEDICATED checkout, never the interactive session's working
#   tree — a crash here must not leave a human's uncommitted work in a weird state.
# - A repo-local lock (below) still serializes concurrent runs of THIS script
#   (kicked by any of the 5 night scripts, or by the periodic backstop timer)
#   before draining. Before draining, the checkout is aligned with origin.
#   Publication itself (fetch+cherry-pick+push after the local commit) is no
#   longer this script's own retry loop — it goes through the shared
#   ds-publish.sh gateway (WP-484, 17.08), which coordinates with every other
#   planned writer via one repo-wide lock, not just other runs of this script.
#   See "# --- Публикация через единый шлюз" below for the current mechanism.
# - Existing ledger files are append-only. Drain first accepts byte-prefix growth
#   in either direction (source extends origin, or a fresher origin extends a
#   stale source). If byte order differs, scripts/lib/ledger-event-diff.py parses
#   both files as YAML and accepts the case where source's events are a multiset
#   subset of dest's (e.g. a manual merge reordered same-timestamp events without
#   losing any). Any other divergence fails closed instead of silently
#   overwriting somebody else's events. Runtime dependency: python3 with PyYAML
#   (import yaml), checked at bootstrap — see require_yaml_event_diff below.
# - Path allowlist: only machine/ledger/**/*.yaml is ever staged, and the staged
#   set is verified AFTER `git add`, not assumed — a dedicated checkout existing
#   for one purpose is still one accidental future edit away from picking up
#   something else.
# - force-push is never used anywhere in this script. No bypass flag exists.
# - A crash between local commit and push does not lose data: the commit stays
#   in the automation checkout's local history and is retried on the next run
#   (kicked again, or picked up by the periodic backstop timer).
#
# ACTIVATION GATE (report.md §4, WP-503.md "Честный остаток"): this script must NOT
# run on tsekh-1 production before the smoke matrix passes — two scripts kicking
# concurrently; a foreign push landing between local commit and push; a dirty index;
# a rebase conflict; a crash after commit but before push; an unreachable remote;
# draining an already-accumulated backlog. That matrix now exists and passes:
# scripts/tests/test-ledger-publish.sh, green as of 09.08 (it also
# found and forced the fix of the two drain defects below). Run it after ANY edit to
# this file.
#
# PILOT DECISION 09.08 (matrix green, no force-push anywhere in this file, both
# drain defects fixed): activated on tsekh-1 via the systemd WATCHDOG TIMER ONLY
# (ledger-publish.timer, OnUnitActiveSec=30min, wired in install-systemd.sh). The
# async "kick" (systemctl start --no-block from inside the 5 existing pipeline
# scripts — wp-sync-bundle-batch.sh, wp-secretary-queue.sh, wp-pool-cascade.sh,
# wp-pool-tiebreak.sh, ledger-append.sh) stays deliberately UNWIRED — not an
# oversight. Reason: a foreign file stuck in the automation checkout
# ($HOME/.iwe-automation) would jam every future publish until a human cleans it
# up by hand, and there is no self-heal for that failure mode yet — the pilot
# chose one rare watchdog writer over five potential kick sources ("пусть работает
# один редкий писатель, а не пять"). Wire the kick into the 5 scripts only once
# self-heal for a jammed checkout exists — see WP-503.md "Честный остаток".
#
# Usage: ledger-publish.sh [--probe]
#   --probe: automation checkout AND source ledger dir are both redirected into
#   an isolated temp fixture with a local bare-repo standing in for origin — no
#   real network, no real git history touched. Exercises the actual happy-path
#   code (bootstrap clone, drain, commit, fetch, rebase, push), not the full
#   7-scenario matrix. Same --probe contract as wp-sync-bundle-batch.sh /
#   wp-secretary-queue.sh (isolated I/O, real code path, Telegram suppressed).
set -euo pipefail

IWE_WORKSPACE="${IWE_WORKSPACE:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-my-strategy}"
SOURCE_REPO="$IWE_WORKSPACE/$GOV_REPO"
CHECKOUT="${LEDGER_PUBLISH_CHECKOUT:-$HOME/.iwe-automation/$GOV_REPO}"
TELEGRAM_LIB="$IWE_WORKSPACE/$GOV_REPO/scripts/lib/telegram.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LEDGER_EVENT_DIFF="$SCRIPT_DIR/lib/ledger-event-diff.py"
# notify_translate нужна до первого вызова tg_notify (fail() вызывает её в
# command substitution раньше, чем tg_notify успевает лениво подгрузить
# TELEGRAM_LIB) — сорсим отдельно и заранее, файл без секретов/сети.
# shellcheck source=lib/notification-render.sh
. "$SCRIPT_DIR/lib/notification-render.sh"
HEARTBEAT_FILE="$IWE_WORKSPACE/.claude/state/ledger-publish.heartbeat"
LOCK_FILE="$IWE_WORKSPACE/.claude/state/ledger-publish.lock"
MAX_PUSH_ATTEMPTS="${LEDGER_PUBLISH_MAX_RETRIES:-3}"
BACKLOG_ALARM_HOURS="${LEDGER_PUBLISH_BACKLOG_ALARM_HOURS:-3}"
# host:pid — traces which process instance a fail/conflict alert came from
# (WP-538, 18.08: unexplained burst of "ledger: N файл(ов)" Telegram messages
# with no matching commit in $CHECKOUT — root cause not found, this makes the
# next occurrence attributable instead of another blind investigation). Falls
# back to a literal placeholder rather than dying under set -e if `hostname`
# is entirely absent — this line runs before tg_notify/fail() exist, so a
# raw failure here would be exactly the silent-pipeline death this publisher
# was built to end (cold-context review, 18.08).
INVOCATION_TAG="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown-host):$$"

# Usage: ledger-publish.sh [--probe | --source-ledger-dir /physical/absolute/path]
# Opt-in external ledger/v1 input; no producer is switched by this API.
# rc 0 acknowledges only the pinned snapshot; rc 75 means retry/unknown.
# Without --acknowledged-ledger-dir the source remains unchanged. The explicit
# acknowledgement mode retains verified records outside Git before draining
# those exact IDs from pending; a writer can append after the pinned snapshot.
EXTERNAL_SOURCE=""
ACKNOWLEDGED_DIR=""
EXPECTED_BASE=""
PLAN_CANDIDATE=""
PLAN_SNAPSHOT_ID=""
PLAN_WORKTREE=""
PLAN_CONTROL=""
SOURCE_SNAPSHOT=""
SNAPSHOT_HELPER="$SCRIPT_DIR/lib/ledger-source-snapshot.py"
PROBE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --probe) PROBE=true; shift ;;
    --source-ledger-dir)
      [[ $# -ge 2 && -n "$2" && -z "$EXTERNAL_SOURCE" ]] || { echo 'ERROR: source directory required once' >&2; exit 1; }
      EXTERNAL_SOURCE="$2"; shift 2 ;;
    --acknowledged-ledger-dir)
      [[ $# -ge 2 && -n "$2" && -z "$ACKNOWLEDGED_DIR" ]] || { echo 'ERROR: acknowledged directory required once' >&2; exit 1; }
      ACKNOWLEDGED_DIR="$2"; shift 2 ;;
    --expected-base)
      [[ $# -ge 2 && -z "$EXPECTED_BASE" && "$2" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] \
        || { echo 'ERROR: expected base must be one full commit OID' >&2; exit 1; }
      EXPECTED_BASE="$2"; shift 2 ;;
    *) echo "ERROR: unknown arg $1" >&2; exit 1 ;;
  esac
done
if [[ "$PROBE" == true && -n "$EXTERNAL_SOURCE" ]]; then
  echo 'ERROR: --probe cannot consume an external source' >&2
  exit 1
fi
if [[ -n "$ACKNOWLEDGED_DIR" && -z "$EXTERNAL_SOURCE" ]]; then
  echo 'ERROR: acknowledged directory requires an external source' >&2
  exit 1
fi
if [[ -n "$EXPECTED_BASE" && ( -z "$EXTERNAL_SOURCE" || -n "$ACKNOWLEDGED_DIR" || "$PROBE" == true ) ]]; then
  echo 'ERROR: conditional plan publication requires only an external source' >&2
  exit 1
fi

# Keep a buffer failure through every canonical exit, including an exec retry.
# External/probe modes retain their own EXIT cleanup and receipt contracts.
HOST_BUFFER_FAILED=0
finish_host_buffer_status() {
  local legacy_status="$1"
  if [[ "$legacy_status" == 0 && "$HOST_BUFFER_FAILED" == 1 ]]; then
    exit 75
  fi
  exit "$legacy_status"
}
if [[ -z "$EXTERNAL_SOURCE" && "$PROBE" != true ]]; then
  [[ "${LEDGER_PUBLISH_BUFFER_FAILED:-0}" != 1 ]] || HOST_BUFFER_FAILED=1
  trap 'finish_host_buffer_status "$?"' EXIT
fi

# Capture only a bounded receipt, never raw child output. Drain excess stdout
# without retaining it; stderr is discarded. All reported reasons are constants.
run_host_buffer_pass() {
  python3 - "${LEDGER_PUBLISH_BUFFER_CMD:-$0}" "$BUFFER_HOME" 2>/dev/null <<'PYEOF'
import json
import os
import re
import select
import subprocess
import sys

FAILURE_REASONS = {
    "acknowledgement_unconfirmed",
    "allowlist",
    "bootstrap",
    "busy",
    "checkout",
    "checkout_needs_recovery",
    "drain",
    "fetch",
    "invalid_acknowledgement",
    "invalid_destination",
    "invalid_source",
    "nonledger_backlog",
    "preflight-rebase",
    "prepared_clone_required",
    "private_clone_required",
    "publish",
    "publish_unknown",
    "snapshot_unavailable",
    "snapshot_unconfirmed",
    "unsafe_checkout",
    "verification_unavailable",
    "wrong_branch",
    "wrong_origin",
    "wrong_push_origin",
    "yaml_bounds",
}
BASE_FIELDS = {"state", "reason", "snapshot_id", "origin_oid", "source_changed"}


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate receipt field")
        result[key] = value
    return result


def capture_receipt(command, buffer_home):
    pending = os.path.join(buffer_home, "pending")
    acknowledged = os.path.join(buffer_home, "acknowledged")
    os.makedirs(acknowledged, exist_ok=True)
    # Match the former Bash child: preserve already inherited lock FDs.
    with subprocess.Popen(
        [
            "bash",
            command,
            "--source-ledger-dir",
            pending,
            "--acknowledged-ledger-dir",
            acknowledged,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        close_fds=False,
        env=dict(os.environ, LEDGER_PUBLISH_BUFFER_PASS="0"),
    ) as child:
        raw = bytearray()
        output_fd = child.stdout.fileno()
        os.set_blocking(output_fd, False)
        while child.poll() is None:
            if not select.select([output_fd], [], [], 0.1)[0]:
                continue
            chunk = os.read(output_fd, 4096)
            if not chunk:
                break
            raw.extend(chunk[: max(0, 4097 - len(raw))])
        code = child.wait()
        # A background descendant may retain receipt fd 3. Collect bytes
        # already available, without waiting for that descendant's EOF.
        while len(raw) <= 4096:
            try:
                chunk = os.read(output_fd, 4097 - len(raw))
            except BlockingIOError:
                break
            if not chunk:
                break
            raw.extend(chunk)
    return raw, code


def parse_receipt(raw, code):
    if len(raw) > 4096:
        return "unconfirmed", "receipt_too_large"
    if not raw:
        return "unconfirmed", "receipt_missing"
    try:
        lines = raw.decode("utf-8").splitlines()
        if len(lines) != 1 or not lines[0].startswith("LEDGER_SOURCE_RECEIPT "):
            raise ValueError("invalid receipt envelope")
        record = json.loads(lines[0].split(" ", 1)[1], object_pairs_hook=strict_object)
        if not isinstance(record, dict):
            raise ValueError("invalid receipt object")
        if record.get("state") == "unconfirmed":
            if (
                set(record) != BASE_FIELDS
                or record["reason"] not in FAILURE_REASONS
                or any(
                    record[key] is not None
                    for key in ("snapshot_id", "origin_oid", "source_changed")
                )
            ):
                raise ValueError("invalid failure receipt")
            return "unconfirmed", record["reason"]
        if (
            set(record) != BASE_FIELDS | {"files", "acknowledged_files"}
            or record["state"] != "published"
            or record["reason"] != "snapshot_verified"
            or not isinstance(record["snapshot_id"], str)
            or not re.fullmatch(r"[0-9a-f]{64}", record["snapshot_id"])
            or not isinstance(record["origin_oid"], str)
            or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", record["origin_oid"])
            or record["source_changed"] is not None
            and type(record["source_changed"]) is not bool
            or type(record["files"]) is not int
            or record["files"] < 0
            or type(record["acknowledged_files"]) is not int
            or record["acknowledged_files"] != record["files"]
        ):
            raise ValueError("invalid success receipt")
        if code != 0:
            return "unconfirmed", "receipt_exit_mismatch"
        return "published", "snapshot_verified"
    except (ValueError, TypeError, KeyError, UnicodeError, RecursionError):
        return "unconfirmed", "receipt_invalid"


try:
    captured, child_status = capture_receipt(sys.argv[1], sys.argv[2])
except OSError:
    state, reason = "unconfirmed", "buffer_start_failed"
else:
    state, reason = parse_receipt(captured, child_status)
print(json.dumps({"state": state, "reason": reason}, sort_keys=True))
sys.exit(0 if state == "published" else 75)
PYEOF
}

# Host buffer pass (WP-530 F158): attempt the buffer first, then always run the
# canonical pass. A partial result remains nonzero without advancing recovery.
# LEDGER_PUBLISH_BUFFER_PASS=0 marks the child itself and also switches the pass off.
if [[ -z "$EXTERNAL_SOURCE" && "$PROBE" != true && "${LEDGER_PUBLISH_BUFFER_PASS:-1}" == 1 ]]; then
  BUFFER_HOME="${IWE_LEDGER_BUFFER_HOME:-$HOME/.local/state/iwe/ledger-buffer}"
  if [[ -d "$BUFFER_HOME/pending" ]] && python3 - "$BUFFER_HOME/pending" <<'PYEOF'
import os
import sys

for _root, _dirs, files in os.walk(sys.argv[1]):
    if any(name.endswith(".yaml") for name in files):
        sys.exit(0)
sys.exit(1)
PYEOF
  then
    if BUFFER_RESULT=$(run_host_buffer_pass); then
      :
    else
      HOST_BUFFER_FAILED=1
      export LEDGER_PUBLISH_BUFFER_FAILED=1
      if [[ -z "$BUFFER_RESULT" ]]; then
        BUFFER_RESULT='{"state":"unconfirmed","reason":"buffer_start_failed"}'
      fi
    fi
    printf 'LEDGER_HOST_BUFFER_RECEIPT %s\n' "$BUFFER_RESULT" >&2
  fi
  # Test seam for ledger-buffer-ctl.sh preflight: stop after the buffer pass so the
  # canonical run (clone, drain, push) never starts inside a sandbox.
  [[ "${LEDGER_PUBLISH_BUFFER_PASS_ONLY:-0}" == 1 ]] && exit 0
fi

# The external API exposes only a content-free receipt. Legacy helpers and Git
# hooks can print raw file/remote data; none of it belongs in its stdout/logs.
exec 3>&1
if [[ -n "$EXTERNAL_SOURCE" ]]; then
  exec >/dev/null 2>&1
fi

external_fail() {
  local reason="$1" code="${2:-1}"
  if [[ -n "$EXPECTED_BASE" ]]; then
    local state=unconfirmed candidate=null snapshot=null
    [[ "$code" != 31 ]] || state=base_changed
    [[ -z "$PLAN_CANDIDATE" ]] || candidate="\"$PLAN_CANDIDATE\""
    [[ -z "$PLAN_SNAPSHOT_ID" ]] || snapshot="\"$PLAN_SNAPSHOT_ID\""
    printf 'PLAN_PUBLICATION_RECEIPT {"schema":"plan-publication-receipt/1","state":"%s","reason":"%s","expected_base":"%s","candidate_oid":%s,"origin_oid":null,"snapshot_id":%s}\n' "$state" "$reason" "$EXPECTED_BASE" "$candidate" "$snapshot" >&3
    exit "$code"
  fi
  printf 'LEDGER_SOURCE_RECEIPT {"state":"unconfirmed","reason":"%s","snapshot_id":null,"origin_oid":null,"source_changed":null}\n' "$reason" >&3
  exit "$code"
}

# The snapshot helper exits 3 when a ledger file is over its size/event bound
# (ledger-source-snapshot.py BOUNDS_EXIT); any other failure keeps the caller's
# reason. Usage: helper_cmd || external_fail_helper $? <reason> [code]
external_fail_helper() {
  local rc="$1" reason="$2" code="${3:-1}"
  [[ "$rc" -ne 3 ]] || reason=yaml_bounds
  external_fail "$reason" "$code"
}

verify_external_snapshot() {
  local oid proof_ref command=receipt
  proof_ref="refs/ledger-proof/$(python3 -c 'import uuid; print(uuid.uuid4())')"
  git fetch --no-write-fetch-head --no-tags -q origin \
    "+refs/heads/$BRANCH:$proof_ref" >/dev/null 2>&1 || external_fail verification_unavailable 75
  oid=$(git rev-parse "$proof_ref" 2>/dev/null) || external_fail verification_unavailable 75
  git update-ref -d "$proof_ref" "$oid" || external_fail verification_unavailable 75
  if [[ -n "$EXPECTED_BASE" ]]; then
    [[ -n "$PLAN_CANDIDATE" ]] || external_fail snapshot_already_present 75
    python3 "$SNAPSHOT_HELPER" conditional-receipt "$EXTERNAL_SOURCE" "$SOURCE_SNAPSHOT" \
      "$CHECKOUT" "$EXPECTED_BASE" "$PLAN_CANDIDATE" "$oid" >&3 \
      || external_fail_helper $? snapshot_unconfirmed 75
    exit 0
  fi
  if [[ -n "$ACKNOWLEDGED_DIR" ]]; then
    command=acknowledge
    python3 "$SNAPSHOT_HELPER" "$command" "$EXTERNAL_SOURCE" "$SOURCE_SNAPSHOT" "$CHECKOUT" "$oid" "$ACKNOWLEDGED_DIR" >&3 \
      || external_fail_helper $? acknowledgement_unconfirmed 75
  else
    python3 "$SNAPSHOT_HELPER" "$command" "$EXTERNAL_SOURCE" "$SOURCE_SNAPSHOT" "$CHECKOUT" "$oid" >&3 \
      || external_fail_helper $? snapshot_unconfirmed 75
  fi
  exit 0
}

cleanup_external_snapshot() {
  # Failed candidates remain reachable on their private branch. Never force
  # removal: dirty or interrupted attempts stay intact for recovery.
  if [[ -n "$PLAN_WORKTREE" && -n "$PLAN_CONTROL" ]]; then
    cd "$PLAN_CONTROL" || return
    git worktree remove "$PLAN_WORKTREE" >/dev/null 2>&1 || true
  fi
  [[ -z "$SOURCE_SNAPSHOT" ]] || rm -rf -- "$SOURCE_SNAPSHOT"
}

prepare_plan_candidate() {
  local origin_oid branch
  origin_oid=$(git rev-parse "origin/$BRANCH") || external_fail fetch 75
  [[ "$origin_oid" == "$EXPECTED_BASE" ]] || external_fail base_changed 31
  # A pre-existing private-branch backlog is not this invocation's work.
  git merge-base --is-ancestor HEAD "$origin_oid" || external_fail checkout_needs_recovery
  PLAN_CONTROL="$CHECKOUT"
  PLAN_WORKTREE=$(mktemp -d) || external_fail snapshot_unavailable 75
  branch="plan-bridge-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
  git worktree add -q -b "$branch" "$PLAN_WORKTREE" "$EXPECTED_BASE" \
    || external_fail checkout_needs_recovery
  CHECKOUT="$PLAN_WORKTREE"
  cd "$CHECKOUT" || external_fail checkout
}

# tg_notify/fail need TELEGRAM_LIB and PROBE already resolved, so define them
# before any --probe path override — both branches below call fail() on error.
tg_notify() {
  local msg="$1"
  if [[ "$PROBE" == "true" ]]; then
    echo "[probe: TG suppressed] $msg"
  elif [[ -f "$TELEGRAM_LIB" ]]; then
    # shellcheck source=lib/telegram.sh
    . "$TELEGRAM_LIB"
    telegram_send "$msg" || echo "WARN: telegram_send failed" >&2
  fi
}

# digest_note <status> <detail>: routine outcomes the pilot need not act on go to
# the daily digest, not Telegram (WP-538 Ф4, 02.09: addressee rule — realtime only
# for what changes the pilot's decision or expectation right now). --probe keeps
# the production digest untouched, same as tg_notify keeps Telegram untouched.
digest_note() {
  [[ -z "$EXTERNAL_SOURCE" ]] || return 0
  local status="$1" detail="$2"
  if [[ "$PROBE" == "true" ]]; then
    echo "[probe: digest suppressed] $detail"
    return 0
  fi
  notify_digest_append "$status" "Публикация журнала событий" "$detail"
}

fail() {
  local stage="$1" detail="$2" conflict_file="${3:-}" behind="${4:-}"
  if [[ -n "$EXTERNAL_SOURCE" ]]; then
    case "$stage" in
      fetch|publish) external_fail "$stage" 75 ;;
      *) external_fail "$stage" ;;
    esac
  fi
  echo "ERROR [$stage]: $detail" >&2
  # WP-538: этап/деталь — техническая информация, остаётся в stderr выше;
  # в Telegram уходит только переведённая фраза (кроме conflict_file/behind
  # ниже — они безопасны и адресны, не сырой git/exit-вывод). "drain" —
  # нарушение append-only инварианта, по смыслу конфликт данных, не просто
  # отказ. "publish" — сбой уже прошёл через ds-publish.sh, которая сама шлёт
  # точный (conflict/fail/manual_action_required) перевод в Telegram; повторный
  # tg_notify здесь давал бы ВТОРОЕ, более грубое сообщение на одно и то же
  # событие — тот же класс дубликата, который эта сессия разбирала (cold-context
  # review, 18.08).
  if [[ "$stage" != "publish" ]]; then
    local human_status=fail
    [[ "$stage" == "drain" ]] && human_status=conflict

    # Composite dedup-ключ только для drain с известным конфликтующим файлом
    # (WP-538, 25.08, пир-сессия с Codex) — голый "$stage" склеивает РАЗНЫЕ
    # файлы/репозитории в один ключ, дедуп путает несвязанные инциденты.
    # Остальные стадии (bootstrap/allowlist/checkout/fetch/preflight-rebase)
    # и drain без conflict_file (например "каталог очереди не найден" —
    # нет конкретного файла) держат прежний ключ "$stage".
    local dedup_key="$stage"
    local -a extra_args=()
    if [[ "$stage" == "drain" && -n "$conflict_file" ]]; then
      local repo_id safe_file
      repo_id="$(notify_repo_id "$SOURCE_REPO")"
      safe_file="$(printf '%s' "$conflict_file" | tr -c 'a-zA-Z0-9._-' '-')"
      dedup_key="drain:${repo_id}:${safe_file}"
      extra_args+=(--conflict-file "$conflict_file")
      [[ -n "$behind" && "$behind" != "0" ]] && extra_args+=(--behind "$behind")
    fi

    # WP-538, всплеск 20-21.08 (пир-сессия с Codex): этот путь никогда не
    # проходил через notify_channel/ds-publish.sh — каждый плановый тик
    # заново слал ЭТО сообщение при застрявшем состоянии (например
    # "checkout" — незакоммиченные tracked-правки в служебной копии),
    # без какого-либо подавления повторов. Канал остаётся прежним
    # (всегда realtime для этих стадий — так было исторически, не
    # меняется здесь), добавлен только дедуп повторов ОДНОГО И ТОГО ЖЕ
    # зависшего состояния между отдельными запусками скрипта.
    # --probe пропускает дедуп целиком (cold-context review): PROBE_DIR
    # ниже по файлу перенаправляет CHECKOUT/HEARTBEAT/LOCK_FILE в
    # изолированную песочницу, но НЕ $HOME -- без этой ветки health-check
    # прогон писал бы timestamp в боевой $HOME/IWE/.claude/state/notify-dedup
    # и мог бы на час замаскировать настоящий сбой той же стадии в проде.
    # tg_notify сам гасит фактическую отправку при PROBE=true (см. выше) --
    # здесь та же логика, что и раньше probe, просто без стороннего эффекта
    # на дедуп-состояние.
    # ${extra_args[@]+"${extra_args[@]}"} , не голое "${extra_args[@]}" --
    # bash 3.2 (macOS /bin/bash, тот же интерпретатор, что резолвит шебанг
    # этого файла на дефолтной установке) под set -u падает с "unbound
    # variable" на пустом массиве в обычном "${arr[@]}" (баг фиксили только
    # в bash 4.4+); extra_args пуст в подавляющем большинстве вызовов fail()
    # (все стадии кроме drain-с-известным-файлом) -- без этой идиомы скрипт
    # падал бы почти на каждом вызове fail() на bash 3.2 (WP-538, 25.08,
    # cold-context review).
    if [[ "$PROBE" == "true" ]]; then
      tg_notify "$(notify_translate "$human_status" "Публикация журнала событий" ${extra_args[@]+"${extra_args[@]}"})"
    elif notify_dedup_allow "$human_status" "$dedup_key"; then
      # NOTIFY_DEDUP_WAS_REPEAT (WP-538, 24.08) -- этот же ключ уже
      # алертил и подавлялся раньше: текст должен признать, что проблема
      # длится, а не звучать как первое разовое сообщение.
      local msg
      if [[ "$NOTIFY_DEDUP_WAS_REPEAT" == true ]]; then
        local -a repeat_args=(${extra_args[@]+"${extra_args[@]}"} --repeat)
        if [[ -n "$NOTIFY_DEDUP_FIRST_SEEN" ]]; then
          repeat_args+=(--duration "$(notify_format_duration $(( $(date -u +%s) - NOTIFY_DEDUP_FIRST_SEEN )))")
        fi
        msg="$(notify_translate "$human_status" "Публикация журнала событий" "${repeat_args[@]}")"
      else
        msg="$(notify_translate "$human_status" "Публикация журнала событий" ${extra_args[@]+"${extra_args[@]}"})"
      fi
      # Тот же общий лимит realtime-сообщений на весь бот, что в
      # ds-publish.sh notify_route() (WP-538, 01.09, сессия 18) -- этот путь
      # исторически шлёт realtime в обход ds-publish.sh целиком (найдено
      # сессией 10), подключается к тому же общему state явно здесь.
      # A repeat of the same stuck state is not news for the pilot (WP-538 Ф4,
      # 02.09, peer session with Kimi + Codex): the first alert already named the
      # owner of the next step (this agent). Repeats go to the daily digest only.
      # WP-538 Ф5б (03.09, round-4 design consensus, Kimi+Codex): the FIRST
      # drain-conflict alert went realtime unconditionally, even though its
      # own text already says "действие не нужно прямо сейчас" — the same
      # inconsistency notify_channel() already resolves for ds-publish.sh's
      # fail/conflict path (digest unless retries are exhausted). This call
      # site never retries, so "first drain conflict" is the equivalent of
      # "not yet retries-exhausted" — matches notify_channel(), goes to
      # digest. Other stages (bootstrap/allowlist/checkout/fetch/preflight-
      # rebase, human_status=fail) keep the pre-existing realtime behaviour —
      # that boundary is intentional (see comment above), not touched here.
      local dispatched
      if [[ "$NOTIFY_DEDUP_WAS_REPEAT" == true || "$human_status" == "conflict" ]]; then
        notify_digest_append "$human_status" "Публикация журнала событий" "$msg"
      elif dispatched="$(notify_admission_dispatch "Публикация журнала событий" "$msg" --key "$(notify_incident_key "$human_status" ledger-publish drain)")"; then
        tg_notify "$dispatched"
      else
        notify_digest_append "$human_status" "Публикация журнала событий" \
          "подавлено общим лимитом realtime-сообщений (${NOTIFY_ADMISSION_WINDOW_MIN:-15} мин) — $msg"
      fi
    fi
  fi
  exit 1
}

# report_recovery_if_any: снимает дедуп-подавление по всем нашим собственным
# стадиям fail() разом и говорит пилоту явно, что застрявшее состояние
# починилось (WP-538, всплеск 20-21.08 — симметрично notify_route()'овской
# логике восстановления в ds-publish.sh). Вызывается из ОБОИХ путей успеха
# ниже по файлу — раннего "нечего публиковать" и обычного после push
# (WP-538, 25.08, найдено тестом сценария 16: конфликт мог устраниться без
# появления новых файлов на публикацию — в этом случае скрипт идёт ранним
# путём, и recovery без этого вызова там никогда не сработал бы).
# drain без конкретного файла (например "каталог очереди не найден") держит
# ключ "drain" как раньше — снимается notify_dedup_clear_any. drain С файлом
# (append-only конфликт, WP-538 25.08) использует composite-ключ
# "drain:<repo-id>:<file>" — notify_dedup_clear_any по буквальному "drain" его
# не найдёт, нужна отдельная groupwise-очистка своим repo-id (не глобальным
# "drain:" — иначе снимет ещё активный инцидент чужого репозитория).
report_recovery_if_any() {
  [[ "$PROBE" == "true" ]] && return 0
  local had_dedup_state=1
  notify_dedup_clear_any bootstrap allowlist checkout fetch preflight-rebase drain \
    && had_dedup_state=0
  notify_dedup_clear_prefix "drain:$(notify_repo_id "$SOURCE_REPO"):" \
    && had_dedup_state=0
  if [[ "$had_dedup_state" -eq 0 ]]; then
    tg_notify "$(notify_translate recovered "Публикация журнала событий")"
  fi
}

complete_legacy_pass() {
  if [[ "$HOST_BUFFER_FAILED" == 1 ]]; then
    echo "WARN: canonical ledger pass completed; invocation remains partial after host buffer failure" >&2
    return 0
  fi
  echo "$1"
  touch "$HEARTBEAT_FILE"
  report_recovery_if_any
}

require_yaml_event_diff() {
  [[ -f "$LEDGER_EVENT_DIFF" ]] \
    || fail bootstrap "не найден YAML event-diff helper: $LEDGER_EVENT_DIFF"
  python3 -c 'import yaml' 2>/dev/null \
    || fail bootstrap "нужны python3 и PyYAML (import yaml) для безопасной YAML-проверки ledger"
  # Без этой проверки синтаксическая ошибка в helper'е всплывёт только внутри
  # drain-цикла как non-zero exit — source_events_are_in_dest() не отличает
  # "helper сломан" от "события действительно разошлись", и fail() на
  # drain-этапе доложит обманчивое "append-only инвариант нарушен" вместо
  # истинной причины (peer review, 14.08).
  python3 -c 'import sys; compile(open(sys.argv[1], "rb").read(), sys.argv[1], "exec")' "$LEDGER_EVENT_DIFF" 2>/dev/null \
    || fail bootstrap "YAML event-diff helper не компилируется: $LEDGER_EVENT_DIFF"
  # WP-503 (31.08, cold-review finding): same class of ambiguity this
  # function exists to prevent, for the two dependencies preflight-rebase's
  # self-heal added -- an absent `jq` or a broken ledger-safe-reset-check.py
  # would otherwise make RESET_VERDICT silently empty, self-heal would
  # never fire, and the resulting fail() would read as a real divergence
  # conflict instead of naming the actual missing/broken dependency.
  command -v jq >/dev/null 2>&1 \
    || fail bootstrap "нужен jq для self-heal диверджентного checkout (preflight-rebase)"
  [[ -f "$SCRIPT_DIR/lib/ledger-safe-reset-check.py" ]] \
    || fail bootstrap "не найден self-heal helper: $SCRIPT_DIR/lib/ledger-safe-reset-check.py"
  python3 -c 'import sys; compile(open(sys.argv[1], "rb").read(), sys.argv[1], "exec")' "$SCRIPT_DIR/lib/ledger-safe-reset-check.py" 2>/dev/null \
    || fail bootstrap "self-heal helper не компилируется: $SCRIPT_DIR/lib/ledger-safe-reset-check.py"
}

if [[ "$PROBE" == "true" ]]; then
  PROBE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ledger-publish-probe.XXXXXX")
  trap 'rm -rf "$PROBE_DIR"' EXIT

  BRANCH="main"
  REMOTE_BARE="$PROBE_DIR/origin.git"
  git init --bare -q -b "$BRANCH" "$REMOTE_BARE" 2>/dev/null \
    || fail bootstrap "git init --bare -b не поддерживается этой версией git — probe требует git>=2.28"

  # Seed the fake remote with one commit so a real fetch/rebase/push happens
  # below, not just a first-push-to-empty-repo shortcut.
  SEED_DIR="$PROBE_DIR/seed"
  git init -q -b "$BRANCH" "$SEED_DIR"
  mkdir -p "$SEED_DIR/machine/ledger"
  echo "probe seed, $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SEED_DIR/README-probe.md"
  git -C "$SEED_DIR" add -- README-probe.md
  git -C "$SEED_DIR" -c user.email=probe@localhost -c user.name=probe commit -q -m "probe: seed"
  git -C "$SEED_DIR" push -q "$REMOTE_BARE" "$BRANCH"

  CHECKOUT="$PROBE_DIR/checkout"
  git clone -q "$REMOTE_BARE" "$CHECKOUT"

  SOURCE_REPO="$PROBE_DIR/source"
  mkdir -p "$SOURCE_REPO/machine/ledger/day/2026/08"
  cat > "$SOURCE_REPO/machine/ledger/day/2026/08/day-2026-08-09.yaml" <<'FIXTURE'
schema: ledger/v1
scale: day
period: "2026-08-09"
events:
  - ts: "2026-08-09T00:00:00Z"
    source: probe-fixture
    kind: wp_drift_found
    data: {wp: "9999", label: probe}
FIXTURE

  HEARTBEAT_FILE="$PROBE_DIR/heartbeat"
  LOCK_FILE="$PROBE_DIR/lock"
  echo "[probe] checkout=$CHECKOUT remote=$REMOTE_BARE source=$SOURCE_REPO (изолированы, боевой репозиторий не тронут)"
fi

# The publisher owns a private clone. Refuse an override into the source or
# canonical checkout (including symlink aliases) before any Git mutation there.
if [[ "$PROBE" != "true" ]]; then
  python3 - "$CHECKOUT" "$SOURCE_REPO" "$IWE_WORKSPACE/DS-my-strategy" <<'PY_CHECKOUT' \
    || fail bootstrap "служебная копия пересекается с исходным или каноническим репозиторием: $CHECKOUT"
import os
import sys

checkout, *protected = map(os.path.realpath, sys.argv[1:])
for source in protected:
    if os.path.commonpath((checkout, source)) in (checkout, source):
        raise SystemExit(1)
PY_CHECKOUT
fi

mkdir -p "$(dirname "$LOCK_FILE")" "$(dirname "$HEARTBEAT_FILE")"

# Repo-wide lock (see design note above for its actual scope: serializes THIS
# script's own concurrent invocations, not human commits in another worktree).
# Non-blocking: if another run already holds it, that run will drain whatever
# is in SOURCE_REPO right now anyway, so there is nothing useful to wait for.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  [[ -z "$EXTERNAL_SOURCE" ]] || external_fail busy 75
  echo "OK: другой прогон ledger-publish.sh уже держит лок ($LOCK_FILE) — выход, backlog всё равно будет опубликован им"
  exit 0
fi

if [[ -n "$EXTERNAL_SOURCE" ]]; then
  # Bootstrap itself can execute inherited template/post-checkout hooks. Only
  # an already provisioned clone can have its full hook profile checked first.
  [[ -d "$CHECKOUT/.git" && ! -L "$CHECKOUT/.git" ]] || external_fail prepared_clone_required
  SOURCE_SNAPSHOT=$(mktemp -d) || external_fail snapshot_unavailable 75
  trap cleanup_external_snapshot EXIT
  python3 "$SNAPSHOT_HELPER" capture "$EXTERNAL_SOURCE" "$SOURCE_SNAPSHOT" \
    "$CHECKOUT" "$SOURCE_REPO" "$IWE_WORKSPACE/DS-my-strategy" || external_fail_helper $? invalid_source
  if [[ -n "$EXPECTED_BASE" ]]; then
    python3 "$SNAPSHOT_HELPER" check-snapshot-scope "$SOURCE_SNAPSHOT" plan || external_fail invalid_source
    PLAN_SNAPSHOT_ID=$(python3 -c 'import hashlib,pathlib,sys; print(hashlib.sha256(pathlib.Path(sys.argv[1], "manifest.json").read_bytes()).hexdigest())' "$SOURCE_SNAPSHOT") || external_fail invalid_source
  elif [[ -n "$ACKNOWLEDGED_DIR" ]]; then
    python3 "$SNAPSHOT_HELPER" check-snapshot-scope "$SOURCE_SNAPSHOT" nonplan || external_fail invalid_source
  fi
  if [[ -n "$ACKNOWLEDGED_DIR" ]]; then
    python3 "$SNAPSHOT_HELPER" check-acknowledgement "$EXTERNAL_SOURCE" "$SOURCE_SNAPSHOT" "$ACKNOWLEDGED_DIR" \
      || external_fail_helper $? invalid_acknowledgement
  fi
fi

if [[ "$PROBE" != "true" ]]; then
  ORIGIN_URL=$(git -C "$SOURCE_REPO" remote get-url origin 2>/dev/null) \
    || fail bootstrap "не удалось определить origin в $SOURCE_REPO"
  BRANCH=$(git -C "$SOURCE_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null) \
    || fail bootstrap "не удалось определить текущую ветку в $SOURCE_REPO"

  if [[ ! -d "$CHECKOUT/.git" ]]; then
    mkdir -p "$(dirname "$CHECKOUT")"
    git clone -q "$ORIGIN_URL" "$CHECKOUT" \
      || fail bootstrap "git clone $ORIGIN_URL -> $CHECKOUT не удался"
  fi
fi

cd "$CHECKOUT" || fail bootstrap "cd $CHECKOUT не удался"
if [[ -n "$EXTERNAL_SOURCE" ]]; then
  # The limited API does not repair inherited dirty state or interrupted
  # operations. Those legacy paths can emit maintenance events in canon.
  [[ -d .git && ! -L .git ]] || external_fail private_clone_required
  checkout_origin=$(git remote get-url origin 2>/dev/null) || external_fail checkout
  [[ "$checkout_origin" == "$ORIGIN_URL" ]] || external_fail wrong_origin
  push_origins=$(git remote get-url --push --all origin 2>/dev/null) || external_fail wrong_origin
  [[ "$push_origins" == "$ORIGIN_URL" ]] || external_fail wrong_push_origin
  checkout_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || external_fail checkout
  [[ "$BRANCH" == main && "$checkout_branch" == main ]] || external_fail wrong_branch
  python3 "$SNAPSHOT_HELPER" check-checkout "$CHECKOUT" || external_fail unsafe_checkout
  status=$(git status --porcelain=v1 --untracked-files=all 2>/dev/null) || external_fail checkout
  [[ -z "$status" && ! -d .git/rebase-merge && ! -d .git/rebase-apply ]] || external_fail checkout_needs_recovery
fi
require_yaml_event_diff

# WP-484 Ф157: this private clone is created by `git clone`, so it has no ledger-events merge
# driver config (git config is per clone). Install it on every run (idempotent, self-healing);
# without it a rebase here would fall back to a text conflict instead of merging by events.
install_out=$(bash "$SCRIPT_DIR/install-ledger-merge-driver.sh" "$CHECKOUT" 2>&1) \
  || fail bootstrap "не удалось установить событийный драйвер слияния журнала в $CHECKOUT (install-ledger-merge-driver.sh): $(printf '%s' "$install_out" | tail -n 1)"
# The source repo (the working clone whose queue is published) needs the driver too: agents cherry-pick
# and rebase ledger commits there. Self-healing on every tick; non-fatal, a missing driver there gives a
# visible conflict, never a silent merge.
if [[ "$PROBE" != "true" && -z "$EXTERNAL_SOURCE" ]] && git -C "$SOURCE_REPO" rev-parse --git-dir >/dev/null 2>&1; then
  bash "$SCRIPT_DIR/install-ledger-merge-driver.sh" "$SOURCE_REPO" >/dev/null 2>&1 \
    || digest_note fail "не удалось установить событийный драйвер слияния журнала в $SOURCE_REPO"
fi

# WP-484 пункт Y round 2 (2026-09-01, peer-session Kimi+Codex): a run killed
# mid-rebase (SIGKILL, OOM, host reboot) leaves .git/rebase-merge or
# rebase-apply behind. The repo-wide flock above already rules out a second
# concurrent instance doing this to itself, so finding this here always means
# a PRIOR run died here — abort it before anything else runs, or the dirty-
# tree guard just below would fail every future tick forever on the same
# leftover state (the same cascading-failure shape WP-503 already fixed for
# a diverged commit, applied here to a diverged rebase).
if [[ -d "$CHECKOUT/.git/rebase-merge" || -d "$CHECKOUT/.git/rebase-apply" ]]; then
  git rebase --abort 2>/dev/null || true
  echo "WARN: незавершённый rebase от прошлого прогона обнаружен и отменён (rebase-merge/rebase-apply в $CHECKOUT/.git)" >&2
fi

# Validate anything a previous interrupted run left staged BEFORE rebase. A staged
# foreign path makes `git rebase` fail with a generic message and hides the actual
# allowlist violation; report the stronger invariant instead.
validate_staged_allowlist() {
  STAGED=$(git diff --cached --name-only)
  [[ -z "$STAGED" ]] && return 0

  BAD=$(printf '%s\n' "$STAGED" | grep -vE '^machine/ledger/.*\.yaml$' || true)
  if [[ -n "$BAD" ]]; then
    git reset -q
    fail allowlist "staged paths вне machine/ledger/**/*.yaml: $BAD"
  fi
}

# WP-484 Ф157: the same strict check on what is about to be committed, so an unreadable ledger never
# becomes a local commit that then blocks every following tick. On failure the index is reset (the
# queue file stays untouched in the source) and the run stops with a drain failure naming the file.
validate_staged_ledgers() {
  local rel tmp bad=""
  tmp=$(mktemp)
  while IFS= read -r rel; do
    [[ "$rel" == *.yaml ]] || continue
    git show ":$rel" > "$tmp" 2>/dev/null || continue
    if ! python3 "$LEDGER_EVENT_DIFF" --validate "$tmp" >/dev/null 2>&1; then
      bad="${bad:+$bad }$rel"
    fi
  done < <(git diff --cached --name-only --diff-filter=AM -- machine/ledger 2>/dev/null)
  rm -f "$tmp"
  if [[ -n "$bad" ]]; then
    git reset -q -- machine/ledger 2>/dev/null || true
    fail drain "журнал не проходит строгую проверку YAML, в коммит не взят, публикация остановлена: $bad" "${bad%% *}"
  fi
}

validate_staged_allowlist

# WP-530 Ф67 (25.09, peer-session Claude+Kimi+Codex): a tracked ledger file
# modified inside this service clone jammed 742 consecutive ticks (21-25.09,
# a session-guard event written from a session opened with cwd in the clone).
# The only legitimate writer of this clone is this script, so such dirt is
# always foreign -- but when every event of the dirty working file is already
# on origin (proved by ledger-event-diff.py --source-subset, the same
# event-level check the drain uses), discarding it loses nothing. Staged dirt,
# a non-ledger path, and any file whose events are NOT all on origin keep the
# fail-closed stop: that is real data a human must look at. The source of the
# dirt is closed separately (session-guard.sh open refuses a cwd under
# ~/.iwe-automation).
self_heal_dirty_tracked_ledgers() {
  git diff --cached --quiet || return 1
  git fetch -q origin "$BRANCH" || return 1
  local rel origin_copy healed=""
  while IFS= read -r rel; do
    [[ "$rel" == machine/ledger/*.yaml ]] || return 1
    origin_copy=$(mktemp)
    if ! git show "origin/$BRANCH:$rel" > "$origin_copy" 2>/dev/null \
       || ! python3 "$LEDGER_EVENT_DIFF" --source-subset "$CHECKOUT/$rel" "$origin_copy"; then
      rm -f "$origin_copy"
      return 1
    fi
    rm -f "$origin_copy"
    git checkout -- "$rel" || return 1
    healed="${healed:+$healed }$rel"
  done < <(git diff --name-only)
  [[ -n "$healed" ]] || return 1
  echo "WARN: служебная копия содержала tracked-правки, все события которых уже на origin — сброшено: $healed" >&2
  digest_note fail "самовосстановление служебной копии: сброшены файлы с уже опубликованными событиями ($healed)"
}

# WP-484 Ф203 (17.10, peer-session Claude+Kimi+Codex): sibling case to
# self_heal_dirty_tracked_ledgers above. That function only discards staged
# or unstaged tracked ledger edits proven to be an already-published SUBSET
# of origin. The live incident this function fixes is the opposite: a prior
# run staged (git add) a genuinely NEW, not-yet-published ledger event and
# was then killed or crashed before the commit a few hundred lines below
# this one ever ran. Found 16.10: ~/.iwe-automation/DS-my-strategy sat with
# one staged merge_scope_widened event since 2026-10-15T18:49, blocking
# every tick for 26+ hours with "не трогаю, нужна ручная проверка" -- the
# guard correctly refused to silently discard real data, but nothing ever
# committed it either, so it sat forever instead of draining once.
#
# Committing it here loses nothing new: the fetch/rebase/union-merge-heal
# logic a few hundred lines below this already reconciles any local-only
# commit against a diverged origin/$BRANCH (that is its everyday job for the
# normal drain commit) -- a commit recovered here is handled by that exact
# same path, not a new one. Scope is intentionally narrow: ONLY staged
# modifications to machine/ledger/*.yaml, nothing unstaged, nothing
# untracked, no staged add/delete/rename of a ledger path, and the staged
# content itself must still pass the same strict YAML event validator
# validate_staged_ledgers uses below -- any of those return 1 and the caller
# falls through to the unchanged fail-closed stop.
self_heal_staged_tracked_ledgers() {
  git diff --quiet || return 1          # any UNSTAGED tracked diff: not this case
  git diff --cached --quiet && return 1 # nothing staged: not this case either
  local status
  status=$(git status --porcelain --untracked-files=all) || return 1
  [[ -z "$(grep -vE '^M  machine/ledger/.*\.yaml$' <<<"$status")" ]] || return 1
  local rel tmp
  tmp=$(mktemp)
  while IFS= read -r rel; do
    git show ":$rel" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    python3 "$LEDGER_EVENT_DIFF" --validate "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
  done < <(git diff --cached --name-only --diff-filter=M -- 'machine/ledger/*.yaml')
  rm -f "$tmp"
  git commit -q -m "ledger: восстановление прерванной публикации (staged, не закоммичено), $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -- machine/ledger || return 1
  echo "WARN: служебная копия содержала staged, но не закоммиченные события ledger -- закоммичено для обычного дренажа" >&2
  digest_note fail "самовосстановление служебной копии: закоммичены staged-но-не-закоммиченные события ledger"
}

# WP-7 Ф263: the two functions above miss UNSTAGED new events (a session-guard event
# left in the clone froze the Mac publisher for 27 h). Only unstaged edits of day/week/
# month ledger files (plan/ stays fail-closed) that load strictly and keep every event
# of HEAD are committed; the normal drain then reconciles them against origin.
self_heal_unstaged_new_ledger_events() {
  git diff --cached --quiet || return 1
  git diff --quiet && return 1
  local status
  status=$(git status --porcelain --untracked-files=all) || return 1
  [[ -z "$(grep -vE '^ M machine/ledger/(day|week|month)/.*\.yaml$' <<<"$status")" ]] || return 1
  local rel head_copy
  local -a files=()
  head_copy=$(mktemp)
  while IFS= read -r rel; do
    git show "HEAD:$rel" > "$head_copy" 2>/dev/null \
      && python3 "$LEDGER_EVENT_DIFF" --validate "$CHECKOUT/$rel" >/dev/null 2>&1 \
      && python3 "$LEDGER_EVENT_DIFF" --source-subset "$head_copy" "$CHECKOUT/$rel" >/dev/null 2>&1 \
      || { rm -f "$head_copy"; return 1; }
    files+=("$rel")
  done < <(git diff --name-only --diff-filter=M)
  rm -f "$head_copy"
  [[ "${#files[@]}" -gt 0 ]] || return 1
  git commit -q -m "ledger: восстановление непроиндексированных событий служебной копии, $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -- "${files[@]}" || return 1
  echo "WARN: служебная копия содержала незакоммиченные новые события ledger -- закоммичено для обычного дренажа: ${files[*]}" >&2
  digest_note fail "самовосстановление служебной копии: закоммичены новые события ledger (${files[*]})"
}

if ! git diff --quiet || ! git diff --cached --quiet; then
  self_heal_dirty_tracked_ledgers \
    || self_heal_staged_tracked_ledgers \
    || self_heal_unstaged_new_ledger_events \
    || fail checkout "служебная копия содержит незакоммиченные tracked-правки — не трогаю; нужна ручная проверка $CHECKOUT"
fi

# Self-heal for untracked debris (WP-503, peer-session with Codex,
# sessions/2026-08/18/2026-08-18-04-wp503-ledger-publish-kick/). Unlike tracked
# dirt above (which is always a human/process actively touching this checkout
# and must stop the run), an untracked file here is residue from something that
# landed OUTSIDE the drain path (a crashed rsync, a stray manual touch) — safe
# to move aside and retry rather than fail the whole run on every future pass.
# Quarantine, not `git clean -fdx`: -fdx also sweeps .gitignore'd build debris
# that has nothing to do with corruption and may be owned by another process
# (Codex's objection, turn 3 of the same session) — moving preserves the file
# for inspection instead of deleting it blind.
# list_untracked_outside_ledger — NUL-separated list of untracked paths outside
# machine/ledger/. Plain `git status --porcelain` quotes any path with a space
# and octal-escapes non-ASCII bytes (git's default core.quotepath behavior,
# not disabled anywhere in this script) — a naive `cut -c4-` on that output
# leaves the quoting/escaping IN the string, so a later `mv "$CHECKOUT/$rel"`
# looks for a literal quoted filename that does not exist on disk and fails
# the whole run for a file that was perfectly movable (cold-context review,
# same defect class already found and fixed for path parsing in Ф22 — see
# postflight in the phase-write-access work). `-z` is the only fully safe
# option: NUL-separated, no quoting, no escaping, matches the pattern already
# used elsewhere in this pipeline for the same reason.
list_untracked_outside_ledger() {
  git status --porcelain -z | while IFS= read -r -d '' entry; do
    local status="${entry:0:2}" rel="${entry:3}"
    [[ "$status" == "??" ]] || continue
    [[ "$rel" == machine/ledger/* ]] && continue
    printf '%s\0' "$rel"
  done
}

quarantine_untracked() {
  # Scoped to paths OUTSIDE machine/ledger/ only (peer-session turn 5,
  # consensus with Codex). Debris inside machine/ledger/ is a different,
  # already-handled case: stage_ledger_paths below rejects it before staging
  # and fails the run loudly
  # with the exact offending path — that explicit contract (scenario 6 of
  # the smoke matrix) must stay intact, not get silently self-healed away.
  # This function exists for the gap validate_staged_allowlist cannot see at
  # all: junk sitting anywhere else in $CHECKOUT that drain never touches and
  # that would otherwise accumulate unnoticed run after run.
  local any_untracked=false
  while IFS= read -r -d '' rel; do
    any_untracked=true
    break
  done < <(list_untracked_outside_ledger)
  [[ "$any_untracked" == "false" ]] && return 0

  local epoch qdir rel dest moved_count=0
  epoch=$(date +%s)
  qdir="${CHECKOUT}-quarantine/$epoch"
  while IFS= read -r -d '' rel; do
    dest="$qdir/$rel"
    if ! mkdir -p "$(dirname "$dest")" || ! mv -- "$CHECKOUT/$rel" "$dest"; then
      fail checkout "не удалось перенести посторонний файл '$rel' в $qdir — служебная копия остаётся грязной, нужна ручная проверка $CHECKOUT"
    fi
    moved_count=$((moved_count + 1))
  done < <(list_untracked_outside_ledger)

  # Re-check rather than trust the move: a directory move can leave a nested
  # untracked file behind if `mv` only relocated the top-level entry reported
  # by --porcelain (e.g. an entire untracked dir reported as one line). Same
  # machine/ledger/ exclusion as above — this is a self-check on quarantine's
  # own work, not a general cleanliness assertion.
  local still_dirty=false
  while IFS= read -r -d '' rel; do
    still_dirty=true
    break
  done < <(list_untracked_outside_ledger)
  [[ "$still_dirty" == "false" ]] \
    || fail checkout "после переноса в $qdir служебная копия всё ещё не чиста — нужна ручная проверка $CHECKOUT"

  echo "Перенесены посторонние файлы в $qdir, продолжаю"

  # TO findings journal (WP-545 Ф6, peer-session 2026-09-01-35 with Codex):
  # this self-heal used to fix the checkout silently — now the fact is a
  # journal record. Target repo named explicitly: this script juggles the
  # automation checkout and the source repo at once.
  if [[ -f "$SCRIPT_DIR/lib/maintenance-event-append.sh" ]]; then
    # shellcheck source=lib/maintenance-event-append.sh
    . "$SCRIPT_DIR/lib/maintenance-event-append.sh"
    # Subshell: VAR=x before a shell FUNCTION (unlike a command) can leak the
    # assignment into the caller's environment in some bash modes.
    (
      export MAINTENANCE_EVENT_REPO="$SOURCE_REPO"
      maintenance_event_append ledger_publish_selfheal "ledger-publish-checkout" \
        "untracked debris quarantined: $moved_count file(s) moved aside" \
        auto_fixed ok "untracked files outside machine/ledger in automation checkout"
    )
  fi
}

quarantine_untracked

# Ротация: держать только последние 5 карантинных эпох, чтобы не расти
# бесконечно на диске при повторяющихся находках.
QUARANTINE_ROOT="${CHECKOUT}-quarantine"
if [[ -z "$EXTERNAL_SOURCE" && -d "$QUARANTINE_ROOT" ]]; then
  find "$QUARANTINE_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
    | sort -rn | tail -n +6 | xargs -r rm -rf
fi

# Align BEFORE drain. The live 09.08 incident was caused by the opposite order:
# a stale checkout committed a source file which already contained origin's new
# event, then rebased that duplicate addition and conflicted forever.
preflight_attempt=1
while ! git fetch -q origin "$BRANCH" 2>/dev/null; do
  (( preflight_attempt == MAX_PUSH_ATTEMPTS )) \
    && fail fetch "git fetch origin $BRANCH не удался до дренажа после $MAX_PUSH_ATTEMPTS попыток — очередь остаётся в $SOURCE_REPO, не потеряна"
  sleep $((preflight_attempt * 5))
  preflight_attempt=$((preflight_attempt + 1))
done

# --reapply-cherry-picks (WP-484 пункт Y round 2, live dry-run against the
# real tsekh-1 backlog, Codex round 5): a prior run's marked snapshot commit
# (see attempt_ledger_union_merge_heal below) can already be sitting ahead of
# HEAD by the time THIS rebase runs -- without the flag, git can silently
# SKIP that commit as "already applied" whenever its patch-id happens to
# coincide with an unrelated commit somewhere in origin's long-lived history
# (never reproducible on the smoke matrix's fresh fixtures, confirmed live on
# real data). A skipped commit means a clean exit here with the local events
# quietly gone and attempt_ledger_union_merge_heal never even invoked.
if [[ -n "$EXTERNAL_SOURCE" ]]; then
  python3 "$SNAPSHOT_HELPER" check-backlog "$CHECKOUT" "$BRANCH" "$SOURCE_SNAPSHOT" || external_fail_helper $? nonledger_backlog
fi
[[ -z "$EXPECTED_BASE" ]] || prepare_plan_candidate
if [[ -z "$EXPECTED_BASE" ]] && ! git rebase --reapply-cherry-picks -q "origin/$BRANCH" 2>/dev/null; then
  git rebase --abort 2>/dev/null || true
  [[ -z "$EXTERNAL_SOURCE" ]] || external_fail checkout_needs_recovery

  # WP-503 (31.08, self-heal, peer-session with Codex): live incident found
  # this checkout frozen since March -- every 30-minute tick hit this same
  # `fail` and nothing ever recovered, growing into 38h+ of repeated Telegram
  # alerts before anyone looked. A genuine conflict and "diverged onto a
  # dead branch tip after an upstream history rewrite" look identical here
  # (non-fast-forward rebase failure), but only the second is provably safe
  # to auto-resolve: if every ledger file this checkout's local-only history
  # touches is a proven subset of what origin already has, that history
  # carries nothing origin doesn't and a reset loses no data. Anything the
  # check can't prove (unparseable file, genuinely unique event, structural
  # mismatch) falls straight through to the unchanged fail() below, now with
  # the specific files named instead of a generic "conflict".
  # WP-503 (2026-09-01, peer-session with Codex, follow-up to 31.08): a
  # strictly empty porcelain missed the more common real case -- an
  # untracked machine/ledger/*.yaml file this same pipeline half-drained on
  # a prior crashed run, colliding with a path origin's new commit wants to
  # write. That's not a dirty/foreign working tree; it's this pipeline's own
  # leftover. ledger-safe-reset-check.py verifies each such file byte-for-
  # byte against origin before trusting it, so it's safe to let porcelain
  # consisting ONLY of such lines through the gate below.
  # `-uall`, not the default `-unormal`: a wholly-new leaf directory (the
  # common case -- a fresh machine/ledger/day/YYYY/MM/ this run created)
  # collapses to a single `?? machine/ledger/day/2026/09/` porcelain line
  # under the default mode, which never matches the per-entry check below and
  # silently disables this whole heal path (found live testing this exact
  # branch -- the collapsed-directory case looked identical to a real
  # foreign dirty tree until `-uall` was added). `-z`, NUL-separated: plain
  # `--porcelain` quotes a path with a space and octal-escapes non-ASCII
  # bytes, which would desync this glob check from the byte-exact filename
  # untracked_ledger_files() (ledger-safe-reset-check.py) parses the same way
  # `list_untracked_outside_ledger` above already had to fix for the same
  # reason (cold-context review, 2026-09-01).
  porcelain_is_heal_eligible() {
    local entry status rel
    while IFS= read -r -d '' entry; do
      status="${entry:0:2}" rel="${entry:3}"
      [[ "$status" == "??" ]] || return 1
      [[ "$rel" == machine/ledger/*.yaml ]] || return 1
    done < <(git status --porcelain -uall -z)
    return 0
  }

  # WP-484 пункт Y round 2 (2026-09-01, peer-session Kimi+Codex): the safe-
  # reset check below only ever proves "identical to origin or nothing new"
  # -- for the actual chronic-failure case (two machines each genuinely
  # append fresh events to the same day-file, neither a subset of the
  # other) it correctly says NOT safe, since `git reset --hard` would
  # silently discard real data. Round 1's fix (move the untracked file
  # aside, merge, restore) was rejected on review: a moved-then-restored
  # file needs its own rollback/crash-recovery, which round 1 got wrong in
  # more than one way. This redesign never moves the file at all --
  # `git add`+`commit` the untracked content AS-IS first (an ordinary local
  # snapshot commit), then rebase. Either it applies cleanly (origin turned
  # out not to touch this exact content), or it produces a REAL git merge
  # conflict on this path -- not a checkout-blocked-by-untracked-file error
  # -- which gets resolved via union-merge and `rebase --continue`. Nothing
  # to restore on any failure: the file was never off-disk, and the
  # snapshot commit survives `rebase --abort` exactly like the script's
  # pre-existing invariant already promises ("crash between commit and push
  # doesn't lose data, retried next run").
  attempt_ledger_union_merge_heal() {
    local entry status rel any=false
    local -a rels=()
    while IFS= read -r -d '' entry; do
      status="${entry:0:2}" rel="${entry:3}"
      [[ "$status" == "??" ]] || continue
      [[ "$rel" == machine/ledger/*.yaml ]] || continue
      git cat-file -e "origin/$BRANCH:$rel" 2>/dev/null || continue
      rels+=("$rel")
      any=true
    done < <(git status --porcelain -uall -z)

    local snapshot_marker="[ledger-merge-snapshot]"
    if [[ "$any" == "true" ]]; then
      git add -- "${rels[@]}" || return 1
      git commit -q -m "ledger: снимок локального backlog перед синхронизацией с origin/$BRANCH $snapshot_marker" -- "${rels[@]}" || return 1
    else
      # No fresh untracked snapshot to make -- but a PRIOR run of this same
      # function may have already committed one and then died before
      # reaching push (crashed mid-rebase -- caught by startup-recovery
      # above and left REBASE_RECOVERED=true; or crashed between commit and
      # the outer preflight-rebase even starting -- no stuck rebase state at
      # all, REBASE_RECOVERED stays false). Both are the same situation from
      # here: a marked snapshot commit sitting ahead of origin, unresolved.
      # Gated on the marker, not on REBASE_RECOVERED or "any ahead commit
      # exists" -- an unrelated diverged commit must never auto-resolve
      # through this path (that scope creep broke scenario 17b earlier in
      # this same round, found live and fixed once already; checking
      # provenance by marker closes the whole class instead of re-narrowing
      # by hand for every new crash point -- Codex review, rounds 3 and 5).
      local ahead_shas unmarked_count
      ahead_shas=$(git rev-list "origin/$BRANCH..HEAD" -- 'machine/ledger/*.yaml' 2>/dev/null)
      [[ -n "$ahead_shas" ]] || return 1
      unmarked_count=$(git log --format=%s "origin/$BRANCH..HEAD" -- 'machine/ledger/*.yaml' 2>/dev/null \
        | grep -Fvc "$snapshot_marker" || true)
      [[ "$unmarked_count" -eq 0 ]] || return 1
    fi

    # --reapply-cherry-picks: WITHOUT it, live testing against the real
    # tsekh-1 backlog found `git rebase` silently SKIP the snapshot commit
    # ("skipped previously applied commit") whenever its patch-id happened
    # to match some unrelated commit already reachable from origin's
    # history (a coincidence on a long-lived repo, never reproducible on
    # the smoke matrix's fresh isolated fixtures) -- exit 0, clean rebase,
    # and the local events silently vanish with no error at all. This flag
    # forces every commit to actually be replayed and hit a real
    # content-level merge/conflict instead of a heuristic skip. Found and
    # fixed via a real dry-run on a COPY of the actual tsekh-1 backlog
    # (36+71 events) before deploy, per Codex's round-4 recommendation --
    # exactly the class of bug synthetic fixtures cannot surface.
    if git rebase --reapply-cherry-picks -q "origin/$BRANCH" 2>/dev/null; then
      digest_note ok "untracked ledger-backlog (${#rels[@]} файл(ов)) зафиксирован снимком, rebase прошёл без конфликта ($CHECKOUT)"
      return 0
    fi

    # Only resolve conflicts on machine/ledger/*.yaml paths ourselves. Any
    # OTHER conflicting path (or none at all -- rebase failed for a reason
    # this heal doesn't understand) aborts cleanly; the snapshot commit from
    # above survives the abort, next run tries again.
    local -a conflicted=()
    while IFS= read -r rel; do
      [[ -n "$rel" ]] && conflicted+=("$rel")
    done < <(git diff --name-only --diff-filter=U)

    if [[ ${#conflicted[@]} -eq 0 ]]; then
      git rebase --abort 2>/dev/null || true
      return 1
    fi
    for rel in "${conflicted[@]}"; do
      if [[ "$rel" != machine/ledger/*.yaml ]]; then
        git rebase --abort 2>/dev/null || true
        return 1
      fi
    done

    local origin_tmp stage2_tmp stage3_tmp local_tmp merge_tmp
    for rel in "${conflicted[@]}"; do
      origin_tmp=$(mktemp); stage2_tmp=$(mktemp); stage3_tmp=$(mktemp)
      git show "origin/$BRANCH:$rel" > "$origin_tmp" 2>/dev/null
      git show ":2:$rel" > "$stage2_tmp" 2>/dev/null
      git show ":3:$rel" > "$stage3_tmp" 2>/dev/null

      # `git rebase` conflict stages do NOT follow `git merge`'s :2=ours/
      # :3=theirs convention (upstream temporarily becomes HEAD) -- verify
      # by content against origin's known blob instead of assuming a fixed
      # stage number (peer-session review finding, round 2). Require EXACTLY
      # one stage to match origin (XOR) -- zero matches is the ambiguous
      # case the previous if/elif already caught, but two matches would
      # have silently fallen through to "stage3 is local" with no actual
      # evidence for it (Codex, round 3) -- both are provenance failures,
      # abort either way rather than guess.
      local stage2_is_origin=false stage3_is_origin=false
      diff -q "$stage2_tmp" "$origin_tmp" >/dev/null 2>&1 && stage2_is_origin=true
      diff -q "$stage3_tmp" "$origin_tmp" >/dev/null 2>&1 && stage3_is_origin=true
      if [[ "$stage2_is_origin" == "true" && "$stage3_is_origin" == "false" ]]; then
        local_tmp="$stage3_tmp"
      elif [[ "$stage3_is_origin" == "true" && "$stage2_is_origin" == "false" ]]; then
        local_tmp="$stage2_tmp"
      else
        rm -f "$origin_tmp" "$stage2_tmp" "$stage3_tmp"
        git rebase --abort 2>/dev/null || true
        return 1
      fi

      merge_tmp=$(mktemp)
      if ! python3 "$LEDGER_EVENT_DIFF" --union-merge "$local_tmp" "$origin_tmp" > "$merge_tmp" 2>/dev/null; then
        rm -f "$origin_tmp" "$stage2_tmp" "$stage3_tmp" "$merge_tmp"
        git rebase --abort 2>/dev/null || true
        return 1
      fi
      if ! mv -- "$merge_tmp" "$rel" || ! git add -- "$rel"; then
        rm -f "$origin_tmp" "$stage2_tmp" "$stage3_tmp" "$merge_tmp"
        git rebase --abort 2>/dev/null || true
        return 1
      fi
      rm -f "$origin_tmp" "$stage2_tmp" "$stage3_tmp"
    done

    if ! GIT_EDITOR=true git rebase --continue 2>/dev/null; then
      git rebase --abort 2>/dev/null || true
      return 1
    fi
    digest_note ok "${#conflicted[@]} untracked ledger-файл(ов) слиты с origin/$BRANCH по полному содержимому событий (union-merge, порядок origin сохранён), публикация продолжается ($CHECKOUT)"
    return 0
  }

  RESET_VERDICT=""
  SAFE_RESET_CHECK="$SCRIPT_DIR/lib/ledger-safe-reset-check.py"
  if [[ -f "$SAFE_RESET_CHECK" ]] && porcelain_is_heal_eligible; then
    # The checker's own exit 1 (== "not safe") is an expected, meaningful
    # result, not a script error -- under `set -e` an unguarded assignment
    # here would kill ledger-publish.sh right on this line, before the
    # jq check below ever runs, and silently skip the fail() call this
    # whole block exists to reach (found live testing this exact branch:
    # the "safe" case masked it because that exit is 0).
    RESET_VERDICT=$(python3 "$SAFE_RESET_CHECK" "$CHECKOUT" "$BRANCH" 2>/dev/null) || true
  fi

  if [[ "$(jq -r '.safe // false' <<<"$RESET_VERDICT" 2>/dev/null)" == "true" ]]; then
    STALE_TIP=$(git rev-parse HEAD)
    git reset --hard "origin/$BRANCH"
    if ! git rebase -q "origin/$BRANCH" 2>/dev/null; then
      # A clean reset onto origin/$BRANCH itself failing to rebase is not
      # the divergence case this guard exists for -- something else is
      # wrong, fail loudly instead of retrying blindly.
      git rebase --abort 2>/dev/null || true
      fail preflight-rebase "автосброс на origin/$BRANCH прошёл, но повторный rebase всё равно упал — не расхождение истории, нужна ручная проверка $CHECKOUT"
    fi
    digest_note ok "$CHECKOUT разошёлся с origin/$BRANCH (локальные коммиты и/или неотслеживаемые ledger-файлы) — все затронутые данные оказались уже опубликованы или байт-в-байт совпадают с origin, автоматически сброшен на актуальную линию (устаревший tip $STALE_TIP ещё в reflog)"
  elif attempt_ledger_union_merge_heal; then
    : # succeeded -- rebase clean or resolved via union-merge, drain's
      # explicit path staging below picks up any further delta normally.
  else
    PROBLEM_FILES=$(jq -r '.problems[]? | "  - \(.file): \(.reason)"' <<<"$RESET_VERDICT" 2>/dev/null)
    DETAIL="локальный backlog конфликтует с origin/$BRANCH до дренажа — новые коммиты не создавались, backlog сохранён в $CHECKOUT"
    [[ -n "$PROBLEM_FILES" ]] && DETAIL="$DETAIL"$'\nфайлы с непроверяемым расхождением:\n'"$PROBLEM_FILES"
    fail preflight-rebase "$DETAIL"
  fi
fi

file_is_prefix() {
  local prefix="$1" complete="$2" prefix_size complete_size
  prefix_size=$(wc -c < "$prefix" | tr -d ' ')
  complete_size=$(wc -c < "$complete" | tr -d ' ')
  (( prefix_size <= complete_size )) || return 1
  cmp -s "$prefix" <(head -c "$prefix_size" "$complete")
}

# Byte-prefix growth misses the case where a manual merge reordered a handful
# of same-timestamp events without losing any (ledger-append.sh's batch writers
# can stamp several distinct events with an identical ts, so ts alone cannot
# stand in for identity — this compares full canonical event content instead,
# see scripts/lib/ledger-event-diff.py).
install_ledger_file() {
  if [[ -n "$EXTERNAL_SOURCE" ]]; then
    # Exit 3 = the file is over the shared size/event bound (writer side of the
    # contract); callers turn it into `yaml_bounds` after their own cleanup.
    python3 "$SNAPSHOT_HELPER" install "$1" "$CHECKOUT" "${2#"$CHECKOUT"/}"
  else
    # The periodic pass grew the 30.10 file past what the readers accept: it
    # checks the same bound before copying (exit 3 = over the bound).
    python3 "$SNAPSHOT_HELPER" check-bounds "$1" || return
    cp -f "$1" "$2"
  fi
}

source_events_are_in_dest() {
  python3 "$LEDGER_EVENT_DIFF" --source-subset "$1" "$2"
}

# Content divergence (both the source and origin hold events the other lacks --
# two writers, Mac and Tsekh, on one day file): the journal is append-only, so
# the union of both event sets loses nothing. Until 02.10.2026 this branch only
# fail()ed, and the publisher stayed down for 6.5 hours (01.10 20:29 -> 02.10
# 03:00) while every ledger-append still printed PUBLISH_TRIGGERED (WP-530 F74,
# "automatic ledger publication" open item).
# The merge goes through the git merge driver's own routine with an EMPTY base
# (the same one used by hand on 01.10 for 9 files): origin's order is kept and
# the other side's events are inserted by ts, so readers that take events[-1]
# keep seeing the newest event.
# Safety: the source is only READ (never overwritten), and only from a snapshot,
# so an append landing mid-merge is simply published by the next run. The merge
# is accepted only if the result is valid YAML and contains EVERY event of both
# the snapshot and the current dest (multiplicity included); any doubt returns 1
# and the caller fail()s exactly as before (fail-closed: header mismatch,
# malformed YAML, an event without ts).
merge_diverged_ledger() {
  local src="$1" dest="$2" rel="$3" snap merged empty rc=1
  snap=$(mktemp) && merged=$(mktemp) && empty=$(mktemp) || return 1
  if cp -f "$src" "$snap" \
     && cp -f "$dest" "$merged" \
     && python3 "$LEDGER_EVENT_DIFF" --merge-driver "$empty" "$merged" "$snap" >/dev/null 2>&1 \
     && python3 "$LEDGER_EVENT_DIFF" --validate "$merged" >/dev/null 2>&1 \
     && python3 "$LEDGER_EVENT_DIFF" --source-subset "$snap" "$merged" >/dev/null 2>&1 \
     && python3 "$LEDGER_EVENT_DIFF" --source-subset "$dest" "$merged" >/dev/null 2>&1; then
    # Keep install's own status: 3 (over the bound) must reach the caller.
    install_ledger_file "$merged" "$dest" && rc=0 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "Расхождение $rel: источник и origin содержат разные события — слито по событиям (union-merge), потерь нет"
      digest_note ok "журнал $rel: расхождение источника и origin слито по событиям (union-merge)"
    fi
  fi
  rm -f "$snap" "$merged" "$empty"
  return "$rc"
}

# --- drain: append-safe copy SOURCE_REPO/machine/ledger -> CHECKOUT/machine/ledger.
# Ledger files only ever grow (ledger-append.sh appends, never deletes/renames).
# Therefore equal content and byte-prefix growth are the only automatic cases.
# Anything else is a true content divergence and must stay visible to a human.
#
# Every drain failure routes through fail(): a bare `set -e` death here would exit
# non-zero with no Telegram at all, which is precisely the silent-pipeline failure
# mode this publisher was built to end (05.08 diagnosis: "конвейер молчал четыре
# ночи незамеченно"). A missing queue directory is loud for the same reason — it
# means the source checkout is misconfigured, and skipping it quietly would keep the
# heartbeat green while nothing is ever published.
DRAIN_DIR="$SOURCE_REPO/machine/ledger"
if [[ -n "$EXTERNAL_SOURCE" ]]; then
  DRAIN_DIR="$SOURCE_SNAPSHOT/ledger"
  python3 "$SNAPSHOT_HELPER" check-destination "$SOURCE_SNAPSHOT" "$CHECKOUT" || external_fail_helper $? invalid_destination
fi
[[ -d "$DRAIN_DIR" ]] \
  || fail drain "каталог очереди $SOURCE_REPO/machine/ledger не найден — проверить IWE_WORKSPACE и чекаут источника"

# SOURCE_REPO is the pilot's interactive checkout, not this publisher's own —
# a content-divergence fail() below is frequently just SOURCE_REPO sitting
# behind its own origin (dirty tree blocking pull), not a real data conflict.
# Surface that likelihood in the fail() text instead of forcing a human to
# SSH in and diff branches by hand every time (peer-session with Kimi,
# 2026-08-15, WP-503: 17h silent backlog traced to exactly this).
SOURCE_BEHIND=""
if [[ -z "$EXTERNAL_SOURCE" ]] && git -C "$SOURCE_REPO" fetch -q origin "$BRANCH" 2>/dev/null; then
  SOURCE_BEHIND=$(git -C "$SOURCE_REPO" rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || true)
fi

# Bound pre-pass: refuse before the first copy, so an over-bound file does not
# leave the checkout half-drained. Only files the loop may copy are parsed;
# install_ledger_file re-checks what it writes (the merge result included).
check_drain_bounds() {
  local src rel dest rc over=""
  while IFS= read -r -d '' src; do
    rel="${src#"$DRAIN_DIR"/}"
    [[ -n "$EXTERNAL_SOURCE" || "$rel" != plan/* ]] || continue
    dest="$CHECKOUT/machine/ledger/$rel"
    [[ -f "$dest" ]] && cmp -s "$src" "$dest" && continue
    # The loop keeps origin's longer append-only copy here; nothing is copied.
    [[ -f "$dest" ]] && file_is_prefix "$src" "$dest" && continue
    rc=0
    python3 "$SNAPSHOT_HELPER" check-bounds "$src" 2>/dev/null || rc=$?
    if [[ "$rc" -eq 3 ]]; then
      over="${over:+$over }$rel"
    elif [[ "$rc" -ne 0 ]]; then
      fail drain "не удалось проверить предел журнала $rel (код $rc) — публикация остановлена" "$rel"
    fi
  done < <(find "$DRAIN_DIR" -name '*.yaml' -print0)
  [[ -z "$over" ]] || fail yaml_bounds "журнал больше общего предела размера/событий — не публикую, нужно делить файл или пересмотреть предел: $over" "${over%% *}"
}
check_drain_bounds

mkdir -p "$CHECKOUT/machine/ledger"
# plan/ (plan-events/1, WP-561 F33) is published only through the external-source input;
# the periodic queue must not become a second route for the same files.
SKIPPED_PLAN=0
while IFS= read -r -d '' src; do
  rel="${src#"$DRAIN_DIR"/}"
  if [[ -z "$EXTERNAL_SOURCE" && "$rel" == plan/* ]]; then
    SKIPPED_PLAN=$((SKIPPED_PLAN + 1))
    continue
  fi
  dest="$CHECKOUT/machine/ledger/$rel"
  mkdir -p "$(dirname "$dest")" || fail drain "mkdir для $dest не удался"

  if [[ ! -f "$dest" ]] || file_is_prefix "$dest" "$src"; then
    install_rc=0
    install_ledger_file "$src" "$dest" || install_rc=$?
    [[ "$install_rc" -ne 3 ]] || fail yaml_bounds "журнал $rel больше общего предела размера/событий — не публикую, нужно делить файл или пересмотреть предел" "$rel"
    [[ "$install_rc" -eq 0 ]] || fail drain "cp $src -> $dest не удался"
  elif file_is_prefix "$src" "$dest"; then
    echo "Источник отстаёт от origin для $rel — сохраняю более длинную append-only версию origin"
  elif source_events_are_in_dest "$src" "$dest"; then
    echo "Источник семантически содержится в dest для $rel, порядок событий отличается — сохраняю dest"
  else
    merge_rc=0
    merge_diverged_ledger "$src" "$dest" "$rel" || merge_rc=$?
    [[ "$merge_rc" -ne 3 ]] || fail yaml_bounds "журнал $rel после слияния больше общего предела размера/событий — не публикую" "$rel"
    [[ "$merge_rc" -ne 0 ]] || continue
    STALE_HINT=""
    [[ -n "$SOURCE_BEHIND" && "$SOURCE_BEHIND" != "0" ]] \
      && STALE_HINT=" — вероятная причина: $SOURCE_REPO отстаёт от своего origin/$BRANCH на $SOURCE_BEHIND коммит(ов), проверить git pull в источнике"
    fail drain "append-only инвариант нарушен для $rel: source не содержится в dest по полному мультимножеству YAML-событий, автоматическое перезаписывание запрещено$STALE_HINT" "$rel" "$SOURCE_BEHIND"
  fi
done < <(find "$DRAIN_DIR" -name '*.yaml' -print0)
if (( SKIPPED_PLAN > 0 )); then
  echo "ledger-publish: каталог plan/ публикуется только внешним входом, пропущено файлов: $SKIPPED_PLAN" >&2
fi

# Validate the complete candidate list before touching the index. NUL paths and
# literal pathspecs prevent spaces, newlines or glob characters from widening it.
# Deletions and symlinks are not ledger additions and are never published here.
stage_ledger_paths() {
  local rel
  local -a paths=()
  while IFS= read -r -d '' rel; do
    # Defence in depth for the drain skip above: a plan file already sitting in a
    # checkout is never staged by the periodic path.
    [[ -z "$EXTERNAL_SOURCE" && "$rel" == machine/ledger/plan/* ]] && continue
    if [[ "$rel" != machine/ledger/*.yaml || ! -f "$rel" || -L "$rel" ]]; then
      fail allowlist "небезопасный путь в очереди staging: $rel"
    fi
    paths+=("$rel")
  done < <(git ls-files -z --modified --others --exclude-standard -- machine/ledger)
  if [[ ${#paths[@]} -gt 0 ]]; then
    GIT_LITERAL_PATHSPECS=1 git add -- "${paths[@]}"
  fi
}

# --- stage, verified against the allowlist AFTER `git add`, not assumed.
stage_ledger_paths
validate_staged_allowlist
validate_staged_ledgers

if [[ -z "$STAGED" ]]; then
  # Nothing new to commit — but a PREVIOUS run may have committed locally and
  # then failed to push (crash, unreachable remote). That backlog still needs
  # draining, so fall through to the fetch/rebase/push loop below instead of
  # exiting here; only skip straight past if HEAD already matches origin.
  AHEAD=$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)
  if [[ "$AHEAD" == "0" ]]; then
    [[ -z "$EXTERNAL_SOURCE" ]] || verify_external_snapshot
    complete_legacy_pass "OK: нечего публиковать (backlog пуст, HEAD уже синхронизирован с origin/$BRANCH)"
    exit 0
  fi
  echo "Нет новых файлов в этом прогоне, но $AHEAD локальных коммит(ов) ещё не опубликованы — продолжаю попытку push"
  STAGED_COUNT=0
else
  STAGED_COUNT=$(echo "$STAGED" | wc -l | tr -d ' ')
  # Pathspec is mandatory, never a bare `git commit`: this checkout is private to
  # the publisher, but the repo-wide rule exists because a bare commit sweeps up
  # whatever another agent left staged, and a private checkout today is exactly
  # the kind of assumption that stops holding later.
  # `-- machine/ledger` is an --only commit: it takes the working-tree content of every
  # modified tracked file under the path, staged or not. The periodic path therefore
  # excludes plan/ explicitly instead of relying on what stage_ledger_paths staged.
  COMMIT_PATHSPEC=(machine/ledger)
  [[ -n "$EXTERNAL_SOURCE" ]] || COMMIT_PATHSPEC+=(':(exclude)machine/ledger/plan')
  git commit -q -m "ledger: публикация $STAGED_COUNT файл(ов) очереди, $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -- "${COMMIT_PATHSPEC[@]}"
fi

# --- backlog age: age of the OLDEST commit still ahead of origin, independent
# of whether this run's own push below succeeds — catches the case the 05.08
# diagnosis found ("конвейер молчал четыре ночи незамеченно"), where repeated
# per-run PUBLISH_FAIL alerts alone were not enough because nobody was looking.
OLDEST_AHEAD_TS=$(git log "origin/$BRANCH..HEAD" --format=%ct --reverse 2>/dev/null | head -1 || true)
if [[ -n "$OLDEST_AHEAD_TS" && -z "$EXTERNAL_SOURCE" ]]; then
  AGE_H=$(( ($(date +%s) - OLDEST_AHEAD_TS) / 3600 ))
  if (( AGE_H >= BACKLOG_ALARM_HOURS )); then
    # Once per dedup TTL, through the shared admission gate, in pilot-facing
    # words with the owner of the next step named (WP-538 Ф4). Every scheduled
    # tick past the threshold used to re-send this raw line.
    BACKLOG_MSG="⏰ Публикация журнала событий: события не опубликованы уже ${AGE_H}ч. Разберу в следующей сессии с этим репозиторием; напиши, если нужно срочно."
    if [[ "$PROBE" == "true" ]]; then
      tg_notify "$BACKLOG_MSG"
    elif notify_dedup_allow fail backlog-age; then
      if BACKLOG_DISPATCHED="$(notify_admission_dispatch "Публикация журнала событий" "$BACKLOG_MSG" --key "$(notify_incident_key fail ledger-publish -)")"; then
        tg_notify "$BACKLOG_DISPATCHED"
      else
        notify_digest_append fail "Публикация журнала событий" "$BACKLOG_MSG"
      fi
    fi
  fi
fi

# WP-484 Ф157: refuse to publish a ledger file that does not load strictly (duplicate keys, torn
# events, conflict markers). The event-level merge driver prevents silent interleaving; this
# catches what still reaches the outgoing commit by another path (a hand edit, a stash apply, a
# clone without the driver that resolved a conflict by hand). It does not see swapped values
# inside a file that parses -- that class is the driver's job.
validate_outgoing_ledgers() {
  git rev-parse --verify -q "origin/$BRANCH" >/dev/null \
    || fail drain "нет origin/$BRANCH: исходящие журналы проверить нельзя, публикация остановлена"
  local rel tmp bad="" over="" bounds_rc
  tmp=$(mktemp)
  while IFS= read -r rel; do
    [[ "$rel" == *.yaml ]] || continue
    git show "HEAD:$rel" > "$tmp" 2>/dev/null || continue
    if ! python3 "$LEDGER_EVENT_DIFF" --validate "$tmp" >/dev/null 2>&1; then
      bad="${bad:+$bad }$rel"
    fi
    # Last writer-side gate for this script's paths into an outgoing commit
    # (drain, merge, rebase heal). A ledger merge-driver run during the gateway's
    # cherry-pick happens later and is not covered here (WP-503 Ф108, deferred).
    # Fail closed: a check that could not run is not a pass.
    bounds_rc=0
    python3 "$SNAPSHOT_HELPER" check-bounds "$tmp" 2>/dev/null || bounds_rc=$?
    if [[ "$bounds_rc" -eq 3 ]]; then
      over="${over:+$over }$rel"
    elif [[ "$bounds_rc" -ne 0 ]]; then
      bad="${bad:+$bad }$rel"
    fi
  done < <(git diff --name-only "origin/$BRANCH" HEAD -- machine/ledger 2>/dev/null)
  rm -f "$tmp"
  if [[ -n "$over" ]]; then
    fail yaml_bounds "журнал больше общего предела размера/событий, публикация остановлена: $over (непубликуемый коммит остался в $CHECKOUT: после деления файла или пересмотра предела вернуть клон на origin/$BRANCH)" "${over%% *}"
  fi
  # An unpushed plan/ commit (left by an external run whose push failed) is not this
  # path's to publish: stop loudly instead of pushing it as a second route.
  if [[ -z "$EXTERNAL_SOURCE" ]]; then
    local plan_rel
    plan_rel=$(git diff --name-only "origin/$BRANCH" HEAD -- machine/ledger/plan 2>/dev/null | head -1)
    [[ -z "$plan_rel" ]] || fail drain "в непубликованных коммитах есть файл плана ($plan_rel): его публикует только внешний вход --source-ledger-dir, повторить его" "$plan_rel"
  fi
  if [[ -n "$bad" ]]; then
    fail drain "журнал не проходит строгую проверку YAML, публикация остановлена: $bad (непубликуемый коммит остался в $CHECKOUT: после исправления источника вернуть клон на origin/$BRANCH, очередь цела в источнике)" "${bad%% *}"
  fi
}
validate_outgoing_ledgers

# --- Публикация через единый шлюз (WP-484, 17.08) — раньше здесь был
# собственный fetch+rebase+push с ретраями; тот цикл серилизовал только
# конкурентные прогоны ЭТОГО скрипта (свой $LOCK_FILE), но не видел
# `week-open-orchestrator.sh` и другие плановые писатели на другом чекауте —
# именно это столкновение уронило открытие недели 17.08 (найдено в разборе
# инцидента, sessions/2026-08/17/2026-08-17-01-week-open-race-codex/).
# ds-publish.sh берёт общую на все плановые скрипты блокировку и публикует
# через уже проверенный isolate-push.sh (cherry-pick + bounded retry).
if [[ "$PROBE" != "true" ]]; then
  DS_PUBLISH="$SCRIPT_DIR/ds-publish.sh"
  [[ -x "$DS_PUBLISH" ]] || fail publish "$DS_PUBLISH не найден или не исполняем"
  # --quiet-ok (WP-538, 18.08 по прямому запросу пилота): рутинный успех
  # планового прогона (раз в 30 минут) не несёт действия — в Telegram летит
  # только fail/conflict (через fail() выше, обычным путём, без --quiet-ok).
  # Only this DS caller owns the following sync handoff. Generic gateway
  # refresh would merge first with an undeclared scope and append a new audit
  # event after publication, making the freshly published ledger dirty again.
  LEDGER_CANON_SYNC_MODE=automatic
  [[ "$GOV_REPO" == "DS-my-strategy" || -n "$EXTERNAL_SOURCE" ]] && LEDGER_CANON_SYNC_MODE=caller
  # Raw gateway diagnostics can contain personal ledger data. The external
  # API returns a fixed reason; the existing gateway owns its notification.
  if [[ -n "$EXTERNAL_SOURCE" ]]; then
    if [[ -n "$EXPECTED_BASE" ]]; then
      PLAN_CANDIDATE=$(git rev-parse HEAD) || external_fail checkout
      plan_rc=0
      IWE_PUBLICATION_SESSIONLESS=1 IWE_LEDGER_SOURCE_SNAPSHOT="$SOURCE_SNAPSHOT" DS_PUBLISH_CANON_SYNC=caller \
        bash "$DS_PUBLISH" "$CHECKOUT" normal --quiet-ok --from-commit "$PLAN_CANDIDATE" \
        --exact-commit "$PLAN_CANDIDATE" --expected-base "$EXPECTED_BASE" \
        --reason "conditional plan snapshot #$INVOCATION_TAG" >/dev/null 2>&1 || plan_rc=$?
      [[ "$plan_rc" != 31 ]] || external_fail base_changed 31
      [[ "$plan_rc" == 0 ]] || external_fail publish_unknown 75
      verify_external_snapshot
    fi
    IWE_PUBLICATION_SESSIONLESS=1 IWE_LEDGER_SOURCE_SNAPSHOT="$SOURCE_SNAPSHOT" DS_PUBLISH_CANON_SYNC=caller bash "$DS_PUBLISH" "$CHECKOUT" normal --quiet-ok \
      --reason "ledger external snapshot #$INVOCATION_TAG" >/dev/null 2>&1 \
      || external_fail publish_unknown 75
    verify_external_snapshot
  fi
  # The scheduled ledger publisher has no interactive session to bind a v2 receipt to; it
  # declares itself session-less per call (WP-539 F21 B5), never through a global export.
  IWE_PUBLICATION_SESSIONLESS=1 DS_PUBLISH_CANON_SYNC="$LEDGER_CANON_SYNC_MODE" bash "$DS_PUBLISH" "$CHECKOUT" normal --quiet-ok \
    --reason "ledger: $STAGED_COUNT файл(ов) #$INVOCATION_TAG" \
    || fail publish "ds-publish.sh не смог опубликовать (код $?) — коммит остаётся локально в $CHECKOUT, не потерян"
fi

# The safe sync runner owns source convergence. Kick it only after a real
# publication, never on the empty-queue path; release this publisher's lock first.
# It may refuse an unpublished tail or a live session without undoing publication.
# --publisher-mode (WP-538 Ф20, D1, peer-session 2026-10-17 Claude+Kimi+Codex):
# this call site fires on any host, after every publish, not just on tsekh-1's
# own periodic timer (which stays the one caller WITHOUT this flag and keeps
# owning Signal A's accounting) -- without it, a host with no periodic timer
# (the pilot's Mac) never gets a tick clean enough to reset the streak, since
# the next journal event lands seconds after the very publish that triggered
# this tick. Signal B/C still observe and dispatch independently either way.
if [[ "$PROBE" != "true" && "$GOV_REPO" == "DS-my-strategy" ]]; then
  flock -u 9
  if ! IWE_ROOT="$IWE_WORKSPACE" bash "$SCRIPT_DIR/tsekh1-git-sync.sh" --publisher-mode; then
    echo "WARN: журнал опубликован, синхронизация исходного репозитория отложена" >&2
    # WP-538 Ф13: a fresh local tail (other sessions appended after our publish)
    # is the one refusal the next publication fixes. Drain it, bounded; any other
    # refusal still defers as before.
    DRAIN_LEFT="${LEDGER_PUBLISH_DRAIN_LEFT:-3}"
    [[ "$DRAIN_LEFT" =~ ^[0-9]+$ ]] || DRAIN_LEFT=0
    timeout 30 git -C "$IWE_WORKSPACE/$GOV_REPO" fetch -q origin main \
      || echo "WARN: fetch origin/main перед проверкой хвоста не удался" >&2
    DRAIN_REASON=$(python3 "${LEDGER_RECONCILE_GUARD:-$IWE_WORKSPACE/iwe-local-config/scripts/lib/ledger-reconcile-published.py}" --check \
      "$IWE_WORKSPACE/$GOV_REPO" origin/main main 2>&1 || true)
    echo "ledger-publish: причина отказа сверки: ${DRAIN_REASON:-нет вывода}" >&2
    if (( DRAIN_LEFT > 0 )) && [[ "$DRAIN_REASON" == *'unpublished local event occurrences'* ]]; then
      echo "ledger-publish: свежий хвост журнала, повторная публикация (осталось попыток: $((DRAIN_LEFT - 1)))" >&2
      sleep "${LEDGER_PUBLISH_DRAIN_PAUSE:-3}"
      LEDGER_PUBLISH_DRAIN_LEFT=$((DRAIN_LEFT - 1)) exec bash "$SCRIPT_DIR/ledger-publish.sh" "$@"
    fi
  fi
fi

complete_legacy_pass "OK: публикация журнала событий завершена успешно ($INVOCATION_TAG)"

if [[ "$PROBE" == "true" ]]; then
  echo "=== PROBE SUMMARY ==="
  echo "staged=$STAGED_COUNT (ds-publish.sh пропущен в probe-режиме — своя изолированная фикстура без реального origin)"
  echo "🟢 PROBE: happy-path (bootstrap→preflight-sync→drain→commit) прошёл целиком"
fi
