#!/usr/bin/env bash
# mac-hygiene — Mac resource watch + safe sweep of old Claude session temp dirs
# (WP-545 F39, requested by the pilot 22.11.2026 after "out of application memory"
# dialog: load average 175, swap 6.5 GB, disk 97% full).
#
# Usage:
#   mac-hygiene.sh run [--dry-run]     check thresholds (always) + sweep (once per 24 h)
#   mac-hygiene.sh check [--dry-run]   thresholds only; notify through scripts/iwe-notify
#   mac-hygiene.sh sweep [--dry-run]   delete old session temp dirs now
#
# Sweep rule (a dir is removed only when ALL hold):
#   - it is a direct child of SESSION_TMP_ROOT and older than SWEEP_MIN_AGE_DAYS
#     (no file inside was modified within that window);
#   - no running process mentions its id in the command line;
#   - no git checkout (.git file or dir) lives inside it (unpushed work is possible).
# Deletion goes through .claude/bin/guarded-rm (the registry of allowed roots).
#
# Env overrides (used by the smoke test): IWE_HYGIENE_TMP_ROOT, IWE_HYGIENE_STATE_DIR,
# IWE_HYGIENE_NOTIFY (command printing instead of sending), IWE_HYGIENE_SWAP_MB,
# IWE_HYGIENE_DISK_FREE_GB, IWE_HYGIENE_SESSIONS, IWE_HYGIENE_FORCE_HOUR.
set -u

IWE_WORKSPACE="${IWE_WORKSPACE:-${HOME}/IWE}"
SESSION_TMP_ROOT="${IWE_HYGIENE_TMP_ROOT:-/private/tmp/claude-501/-Users-tserentserenov-IWE}"
STATE_DIR="${IWE_HYGIENE_STATE_DIR:-${IWE_WORKSPACE}/.iwe-runtime/state/mac-hygiene}"
NOTIFY="${IWE_HYGIENE_NOTIFY:-${IWE_WORKSPACE}/scripts/iwe-notify}"
GUARDED_RM="${IWE_WORKSPACE}/.claude/bin/guarded-rm"

# Two channels (pilot decision 25.11.2026, WP-568 F14: swap and process alerts were 4-6 chat messages a
# day with nothing new in them). Source "mac-hygiene" goes to the morning digest (telegram-transport-
# allowlist.conf), "mac-hygiene-critical" to the chat: only a disk close to full, which stops the Mac.
SWAP_LIMIT_MB=4096          # digest line when swap in use is above this
DISK_FREE_LIMIT_GB=20       # digest line when free disk is below this
DISK_CRITICAL_FREE_GB=10    # chat message when free disk is below this
SESSIONS_LIMIT=12           # digest line when this many claude processes run at once
SWEEP_MIN_AGE_DAYS=2
SWEEP_PERIOD_SEC=86400
DIGEST_COOLDOWN_SEC=86400   # same kind of digest line at most once per 24 h
CRITICAL_COOLDOWN_SEC=21600 # same kind of chat message at most once per 6 h
QUIET_FROM=23               # no chat pings from 23:00 to 07:59 local time
QUIET_TO=8

DRY_RUN=0

log() { printf '%s mac-hygiene: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

now_epoch() { date +%s; }

swap_used_mb() {
  if [ -n "${IWE_HYGIENE_SWAP_MB:-}" ]; then echo "${IWE_HYGIENE_SWAP_MB}"; return; fi
  sysctl -n vm.swapusage | sed -n 's/.*used = \([0-9]*\)\..*/\1/p'
}

disk_free_gb() {
  if [ -n "${IWE_HYGIENE_DISK_FREE_GB:-}" ]; then echo "${IWE_HYGIENE_DISK_FREE_GB}"; return; fi
  df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2 {printf "%d", $4/1048576}'
}

sessions_count() {
  if [ -n "${IWE_HYGIENE_SESSIONS:-}" ]; then echo "${IWE_HYGIENE_SESSIONS}"; return; fi
  pgrep -f 'native-binary/claude' 2>/dev/null | wc -l | tr -d ' '
}

in_quiet_hours() {
  local h="${IWE_HYGIENE_FORCE_HOUR:-$(date +%H)}"
  h=$((10#${h}))
  [ "${h}" -ge "${QUIET_FROM}" ] || [ "${h}" -lt "${QUIET_TO}" ]
}

# send_alert <digest|critical> <kind> <text>: per-kind cooldown; quiet hours hold only chat messages
send_alert() {
  local channel="$1" kind="$2" text="$3" stamp last source cooldown
  if [ "${channel}" = critical ]; then
    source=mac-hygiene-critical; cooldown="${CRITICAL_COOLDOWN_SEC}"
  else
    source=mac-hygiene; cooldown="${DIGEST_COOLDOWN_SEC}"
  fi
  stamp="${STATE_DIR}/last-notify-${kind}"
  last=0
  [ -f "${stamp}" ] && last="$(cat "${stamp}" 2>/dev/null || echo 0)"
  if [ $(( $(now_epoch) - last )) -lt "${cooldown}" ]; then
    log "alert ${kind} suppressed (cooldown)"; return 0
  fi
  if [ "${channel}" = critical ] && in_quiet_hours; then
    log "alert ${kind} suppressed (quiet hours)"; return 0
  fi
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "DRY-RUN alert ${kind} (${source}): ${text}"; return 0
  fi
  if "${NOTIFY}" --source "${source}" "${text}"; then
    now_epoch > "${stamp}"
    log "alert ${kind} sent"
  else
    log "alert ${kind}: notify failed (exit $?), will retry next run"
  fi
}

do_check() {
  local swap free sessions
  swap="$(swap_used_mb)"; free="$(disk_free_gb)"; sessions="$(sessions_count)"
  log "swap=${swap}MB disk_free=${free}GB claude_sessions=${sessions}"
  if [ -n "${swap}" ] && [ "${swap}" -gt "${SWAP_LIMIT_MB}" ]; then
    send_alert digest swap "Мак: подкачка заполнена на ${swap} МБ (порог ${SWAP_LIMIT_MB}) — памяти не хватает. Закройте лишние окна VS Code с сессиями (сейчас их ${sessions}) и вкладки Chrome."
  fi
  if [ -n "${free}" ] && [ "${free}" -lt "${DISK_CRITICAL_FREE_GB}" ]; then
    send_alert critical disk-critical "Мак: на диске свободно всего ${free} ГБ (порог ${DISK_CRITICAL_FREE_GB}) — скоро перестанут работать сессии и публикации. Что делать: очистить корзину, Загрузки, Docker."
  elif [ -n "${free}" ] && [ "${free}" -lt "${DISK_FREE_LIMIT_GB}" ]; then
    send_alert digest disk "Мак: на диске свободно ${free} ГБ (порог ${DISK_FREE_LIMIT_GB}). Нужна чистка: корзина, Загрузки, Docker."
  fi
  if [ "${sessions}" -gt "${SESSIONS_LIMIT}" ]; then
    send_alert digest sessions "Мак: одновременно работает ${sessions} процессов claude (порог ${SESSIONS_LIMIT}). Закройте завершённые сессии."
  fi
}

# dir_is_removable <dir> — prints the reason to keep it, or nothing when removable
keep_reason() {
  local dir="$1" id
  id="$(basename "${dir}")"
  if [ -n "$(find "${dir}" -newermt "${SWEEP_MIN_AGE_DAYS} days ago" -print -quit 2>/dev/null)" ]; then
    echo "recent-files"; return
  fi
  if pgrep -qf -- "${id}"; then
    echo "running-process"; return
  fi
  if [ -n "$(find "${dir}" -maxdepth 5 -name .git -print -quit 2>/dev/null)" ]; then
    echo "git-checkout-inside"; return
  fi
}

do_sweep() {
  local dir reason removed=0 kept=0 id
  if [ ! -d "${SESSION_TMP_ROOT}" ]; then log "sweep: no ${SESSION_TMP_ROOT}"; return 0; fi
  if [ ! -x "${GUARDED_RM}" ]; then log "sweep: guarded-rm missing, nothing deleted"; return 1; fi
  while IFS= read -r dir; do
    id="$(basename "${dir}")"
    reason="$(keep_reason "${dir}")"
    if [ -n "${reason}" ]; then
      kept=$((kept + 1)); continue
    fi
    if [ "${DRY_RUN}" -eq 1 ]; then
      log "DRY-RUN would remove ${id}"; removed=$((removed + 1)); continue
    fi
    if "${GUARDED_RM}" -rf "${dir}"; then
      removed=$((removed + 1))
    else
      log "sweep: guarded-rm refused ${id}"
    fi
  done < <(find "${SESSION_TMP_ROOT}" -mindepth 1 -maxdepth 1 -type d)
  log "sweep: removed=${removed} kept=${kept} (dry_run=${DRY_RUN})"
}

do_run() {
  local stamp="${STATE_DIR}/last-sweep" last=0
  do_check
  [ -f "${stamp}" ] && last="$(cat "${stamp}" 2>/dev/null || echo 0)"
  if [ $(( $(now_epoch) - last )) -ge "${SWEEP_PERIOD_SEC}" ]; then
    do_sweep && [ "${DRY_RUN}" -eq 0 ] && now_epoch > "${stamp}"
  fi
  return 0
}

main() {
  local cmd="${1:-}"; shift || true
  [ "${1:-}" = "--dry-run" ] && DRY_RUN=1
  mkdir -p "${STATE_DIR}"
  case "${cmd}" in
    run) do_run ;;
    check) do_check ;;
    sweep) do_sweep ;;
    *) echo "usage: mac-hygiene.sh {run|check|sweep} [--dry-run]" >&2; exit 2 ;;
  esac
}

main "$@"
