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
# WP-484 F285 M1: the closing writer saves its own next step (exactly the field text it
# also gives the pilot and the report) to .iwe-runtime/peer-prompts/<slug>-next-step.txt
# or names the file with --next-file; it is compared with the card field.  Without it
# the checker reports HANDOFF_AGENT_NEXT_MISSING (a field rewritten early in a long
# session passed every other clause, WP-611 04.11).
#
# Usage:
#   wp-handoff-peer-check.sh --sem <semaphore-file>
#   wp-handoff-peer-check.sh --agent <agent> --slug <slug>
#   wp-handoff-peer-check.sh --agent <agent> --wp <WP-N>   # the one open peer-session semaphore of the WP
#   any form above + --next-file <file>                    # the writer's next step, default by slug
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
NEXT_FILE=""
FROM_CLOSE=0
while [ $# -gt 0 ]; do
  if [ "$1" = "--from-close" ]; then FROM_CLOSE=1; shift; continue; fi   # called by session-guard.sh close
  [ $# -ge 2 ] || break   # a flag without a value ends parsing; `shift 2` would never drain $#
  case "$1" in
    --sem) SEM="${2:-}"; shift 2 ;;
    --agent) AGENT="${2:-}"; shift 2 ;;
    --slug) SLUG="${2:-}"; shift 2 ;;
    --wp) FIND_WP="${2:-}"; shift 2 ;;
    --next-file) NEXT_FILE="${2:-}"; shift 2 ;;
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

# A slug equal to the WP (a session opened without --slug) is shared by every session of
# the WP: a stale file of another session must not be taken, so no default then.
if [ -z "$NEXT_FILE" ] && [ -n "$SLUG" ] && [ "$SLUG" != "$WP" ]; then
  NEXT_FILE="$IWE_ROOT/.iwe-runtime/peer-prompts/$SLUG-next-step.txt"
fi
NEXT_ARGS=""
[ -n "$NEXT_FILE" ] && [ -s "$NEXT_FILE" ] && NEXT_ARGS="yes"

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  log_line "$WP" "infra" "PYTHON_MISSING" "{}"
  exit 0
fi
set -- peer --card "$CARD"
[ "$HAVE_BASELINE" = 1 ] && set -- "$@" --origin-file "$BASELINE_FILE"
[ -n "$NEXT_ARGS" ] && set -- "$@" --what-next-file "$NEXT_FILE"
RESULT="$(limited "$PY" "$CHECKER" "$@" 2>/dev/null)"
RC=$?
STALE_CHECKER=0
if [ "$RC" -eq 2 ] && [ -n "$NEXT_ARGS" ]; then
  # A governance worktree older than F285: its checker rejects --what-next-file.  Check
  # the rest the old way and say the comparison did not run, instead of dropping the check.
  set -- peer --card "$CARD"
  [ "$HAVE_BASELINE" = 1 ] && set -- "$@" --origin-file "$BASELINE_FILE"
  RESULT="$(limited "$PY" "$CHECKER" "$@" 2>/dev/null)"
  RC=$?
  STALE_CHECKER=1
fi
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
if [ "$STALE_CHECKER" = 1 ]; then
  EVIDENCE="${EVIDENCE%\}}, \"stale_checker\": true}"
  [ "${EVIDENCE#\{, }" = "$EVIDENCE" ] || EVIDENCE="{${EVIDENCE#\{, }"
  echo "Session CLOSE: проверщик в рабочей копии $GOV устарел (до Ф285) — сравнение поля с твоим следующим шагом не выполнено; обнови копию от origin/main." >&2
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
    echo "  Поправь поле «Следующий шаг» в «Осталось» карточки: одна строка с названием фазы (ФN) и первым действием, метка без даты. У зонтичной карточки (agent_scope: open-only) поле — ключ next_step в шапке, назвать можно фазу или под-РП." >&2
    if [ "$CODE" = "HANDOFF_AGENT_NEXT_MISSING" ] || [ "$CODE" = "HANDOFF_MISMATCH_WHAT_NEXT" ]; then
      echo "  Свой следующий шаг для следующей сессии (ровно текст поля, как в отчёте; не строку «Дальше» пилоту) запиши в ${NEXT_FILE:-файл и передай его через --next-file (slug сессии совпадает с номером РП, файл по умолчанию не берётся)} и повтори проверку." >&2
    fi
    if [ "$FROM_CLOSE" = 1 ]; then
      echo "  Это отказ, а сессия уже закрывается: исправь поле отдельной правкой карточки и скажи пилоту, что проверка не прошла." >&2
    else
      echo "  Это отказ: исправь поле до освобождения сессии и скажи пилоту, что проверка не прошла." >&2
    fi
    ;;
  pass)
    echo "Session CLOSE: поле «Следующий шаг» карточки $WP проверено (отпечаток ревизии в журнале наблюдения)." >&2
    ;;
esac
# F285 warnings: the verdict holds, but the card needs a touch.
case "$EVIDENCE" in *'"label_date_warning"'*)
  echo "  Предупреждение: в метке поля стоит дата — пиши ровно **Следующий шаг:** без даты." >&2 ;;
esac
case "$EVIDENCE" in *'"duplicate_labels_warning"'*)
  echo "  Предупреждение: в «Осталось» несколько меток «Следующий шаг» — считается первая без даты, старые блоки убери." >&2 ;;
esac
case "$EVIDENCE" in *'"valid_until_past_warning"'*)
  echo "  Предупреждение: дата «Актуально до» уже прошла — обнови её." >&2 ;;
esac
exit 0
