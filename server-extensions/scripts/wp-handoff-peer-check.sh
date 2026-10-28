#!/usr/bin/env bash
# wp-handoff-peer-check.sh -- check the card field «Следующий шаг» on the
# peer-session close path (WP-484 F257, measure M2).
#
# A peer session closes through session-guard.sh close (or, for the Kimi writer,
# through its own commit block) and never passes the Quick Close runner, so the
# runner's handoff check (M1) does not see it.  This script runs the same
# checker, wp-handoff-check.py, in `peer` mode: there is no agent answer to
# compare with, every other clause runs.
#
# Usage:
#   wp-handoff-peer-check.sh --sem <semaphore-file>
#   wp-handoff-peer-check.sh --agent <agent> --slug <slug>
#   wp-handoff-peer-check.sh --agent <agent> --wp <WP-N>   # the one open peer-session semaphore of the WP
#
# Mode (IWE_HANDOFF_CHECK_MODE): `shadow` (default) prints a warning and appends a
# line to .iwe-runtime/handoff-check-shadow.log, never blocks; `off` does nothing.
# Leaving shadow is a pilot decision after at least 7 days and 5 peer-session
# closes of data, so there is deliberately no blocking branch here yet.
#
# Always exits 0: infrastructure problems (no card, no checker, unreadable
# input) are logged as `infra`, never reported as a rule violation.
# Written for bash 3.2 (stock macOS): no associative arrays, no empty-array expansion.
set -u

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SEM=""
AGENT=""
SLUG=""
FIND_WP=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || break   # a flag without a value ends parsing; `shift 2` would never drain $#
  case "$1" in
    --sem) SEM="${2:-}"; shift 2 ;;
    --agent) AGENT="${2:-}"; shift 2 ;;
    --slug) SLUG="${2:-}"; shift 2 ;;
    --wp) FIND_WP="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

MODE="${IWE_HANDOFF_CHECK_MODE:-shadow}"
[ "$MODE" = "off" ] && exit 0

LOG_DIR="$IWE_ROOT/.iwe-runtime"
LOG_FILE="$LOG_DIR/handoff-check-shadow.log"

log_line() { # <wp> <state> <code> <evidence>
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  # Card text reaches the evidence; `|` there would shift the fields, so it is replaced.
  local evidence="${4//|/¦}"
  printf '%s | %s | %s | %s | %s | %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${LOG_SESSION:-${SLUG:-?}}" "$2" "$3" "$evidence" \
    >>"$LOG_FILE" 2>/dev/null || true
}

if [ -z "$SEM" ] && [ -n "$AGENT" ] && [ -n "$SLUG" ]; then
  for candidate in "$IWE_ROOT/.iwe-runtime/sessions/$AGENT"-*.open; do
    [ -f "$candidate" ] || continue
    if grep -qx "slug: $SLUG" "$candidate" 2>/dev/null; then
      SEM="$candidate"
      break
    fi
  done
fi
if [ -z "$SEM" ] && [ -n "$AGENT" ] && [ -n "$FIND_WP" ]; then
  # Kimi's semaphore is opened outside this repo and its slug is not the peer-session id,
  # so it is found by WP.  More than one candidate is ambiguous, never a guess.
  MATCHES=0
  for candidate in "$IWE_ROOT/.iwe-runtime/sessions/$AGENT"-*.open; do
    [ -f "$candidate" ] || continue
    if grep -qx "wp: $FIND_WP" "$candidate" 2>/dev/null; then
      MATCHES=$((MATCHES + 1))
      SEM="$candidate"
    fi
  done
  if [ "$MATCHES" -gt 1 ]; then
    SEM=""
    log_line "$FIND_WP" "infra" "SEMAPHORE_AMBIGUOUS" "{}"
    exit 0
  fi
fi
if [ -z "$SEM" ] || [ ! -f "$SEM" ]; then
  log_line "${FIND_WP:-?}" "infra" "SEMAPHORE_NOT_FOUND" "{}"
  exit 0
fi

field() { grep "^$1: " "$SEM" 2>/dev/null | head -1 | cut -d' ' -f2-; }

# Only the peer-session path; the runner path has its own check (M1).  `--wp` is the
# caller's own declaration (the Kimi writer opens its semaphore without close_path).
if [ -z "$FIND_WP" ] && [ "$(field close_path)" != "peer-session" ]; then
  exit 0
fi
[ -n "$SLUG" ] || SLUG="$(field slug)"
LOG_SESSION="$(field session_id)"

WP="$(field wp)"
case "$WP" in
  WP-[0-9]*) ;;
  *) exit 0 ;;
esac
case "${WP#WP-}" in
  *[!0-9]*) exit 0 ;;
esac

GOV="$(field governance_worktree)"
if [ -z "$GOV" ] || [ ! -d "$GOV" ]; then
  log_line "$WP" "infra" "GOVERNANCE_WORKTREE_MISSING" "{}"
  exit 0
fi
CARD="$GOV/inbox/$WP/$WP.md"
CHECKER="$GOV/scripts/wp-handoff-check.py"
if [ ! -f "$CARD" ]; then
  log_line "$WP" "infra" "CARD_MISSING" "{}"
  exit 0
fi
if [ ! -f "$CHECKER" ]; then
  log_line "$WP" "infra" "CHECKER_MISSING" "{}"
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wp-handoff-peer.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# Bounded and detached from the caller's stdin: a stale checker without the `peer`
# mode falls back to reading JSON from stdin and would hang a close forever.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
if [ -r "$LIB_DIR/run-limited.sh" ]; then
  # shellcheck source=lib/run-limited.sh
  . "$LIB_DIR/run-limited.sh"
else
  run_limited() { shift; "$@"; }   # stale copy without the library: no limit, never a failed close
fi
limited() { run_limited 20 "$@" </dev/null; }

# Baseline: the card as it was on origin when the session opened, named by the
# blob id that `open` recorded -- time-based reconstruction is not reliable.
BASELINE_OID="$(field baseline_card_oid)"
BASELINE_SOURCE="$(field baseline_source)"   # `local-unfetched`: the open-time fetch failed, the baseline may be older than the server
BASELINE_FILE="$TMP_DIR/baseline.md"
HAVE_BASELINE=0
case "$BASELINE_OID" in
  "") ;;
  *[!0-9a-f]*) log_line "$WP" "infra" "BASELINE_OID_INVALID" "{}" ;;
  *)
    if [ "${#BASELINE_OID}" -eq 40 ] || [ "${#BASELINE_OID}" -eq 64 ]; then
      if limited git -C "$GOV" cat-file -p "$BASELINE_OID" >"$BASELINE_FILE" 2>/dev/null; then
        HAVE_BASELINE=1
      fi
    else
      log_line "$WP" "infra" "BASELINE_OID_INVALID" "{}"
    fi
    ;;
esac

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  log_line "$WP" "infra" "PYTHON_MISSING" "{}"
  exit 0
fi
if [ "$HAVE_BASELINE" = 1 ]; then
  RESULT="$(limited "$PY" "$CHECKER" peer --card "$CARD" --origin-file "$BASELINE_FILE" 2>/dev/null)"
else
  RESULT="$(limited "$PY" "$CHECKER" peer --card "$CARD" 2>/dev/null)"
fi
RC=$?
if [ "$RC" -ne 0 ] || [ -z "$RESULT" ]; then
  log_line "$WP" "infra" "CHECKER_FAILED_RC_$RC" "{}"
  exit 0
fi

# The check reads the working copy; the next session reads origin.  A field edit that
# is not published yet will not be seen by it -- say so, state unchanged.
ORIGIN_BLOB="$(limited git -C "$GOV" rev-parse --verify -q "origin/main:inbox/$WP/$WP.md" 2>/dev/null || true)"
WORK_BLOB="$(limited git -C "$GOV" hash-object "$CARD" 2>/dev/null || true)"
NOT_ON_ORIGIN=0
if [ -n "$ORIGIN_BLOB" ] && [ -n "$WORK_BLOB" ] && [ "$ORIGIN_BLOB" != "$WORK_BLOB" ]; then
  NOT_ON_ORIGIN=1
fi

# The checker prints `state=<s> code=<c> evidence=<json>`; anything else is an
# infrastructure problem, never a parsed-from-garbage rule verdict.
case "$RESULT" in
  state=*" code="*" evidence="*) ;;
  *)
    log_line "$WP" "infra" "CHECKER_OUTPUT_UNPARSEABLE" "{}"
    exit 0
    ;;
esac
STATE="${RESULT#state=}"; STATE="${STATE%% *}"
CODE="${RESULT#*code=}"; CODE="${CODE%% *}"
EVIDENCE="${RESULT#*evidence=}"
if [ "$NOT_ON_ORIGIN" = 1 ]; then
  if [ "$EVIDENCE" = "{}" ]; then
    EVIDENCE='{"not_on_origin": true}'
  else
    EVIDENCE="${EVIDENCE%\}}, \"not_on_origin\": true}"
  fi
fi
if [ "$BASELINE_SOURCE" = "local-unfetched" ]; then
  if [ "$EVIDENCE" = "{}" ]; then
    EVIDENCE='{"baseline_source": "local-unfetched"}'
  else
    EVIDENCE="${EVIDENCE%\}}, \"baseline_source\": \"local-unfetched\"}"
  fi
fi
log_line "$WP" "$STATE" "$CODE" "$EVIDENCE"
if [ "$BASELINE_SOURCE" = "local-unfetched" ]; then
  echo "Session CLOSE: baseline карточки записан без свежего fetch при открытии: правка поля другой сессией могла быть принята за правку этой (вердикт ниже ориентировочный)." >&2
fi
if [ "$NOT_ON_ORIGIN" = 1 ]; then
  echo "Session CLOSE: правка карточки $WP ещё не опубликована на origin — следующая сессия прочтёт прежнее значение поля. Опубликуй карточку до закрытия." >&2
fi

case "$STATE" in
  fail)
    echo "Session CLOSE (режим наблюдения, закрытие не блокируется): поле «Следующий шаг» карточки $WP не прошло проверку — $CODE. Подробности: $EVIDENCE" >&2
    echo "  Поправь поле «Следующий шаг» в «Осталось» карточки: одна строка с названием фазы (ФN) и первым действием. У зонтичной карточки (agent_scope: open-only) поле — ключ next_step в шапке, назвать можно фазу или под-РП." >&2
    ;;
  pass)
    echo "Session CLOSE: поле «Следующий шаг» карточки $WP проверено (отпечаток ревизии в журнале наблюдения)." >&2
    ;;
esac
exit 0
