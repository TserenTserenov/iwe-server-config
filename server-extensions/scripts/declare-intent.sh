#!/bin/bash
# declare-intent.sh -- DP.SC.204 (pre-action intent gate). Writes a lightweight
# record of what the calling agent is about to work on, BEFORE it calls any
# tool: a WP number or an explicit "outside-wp" marker. Read by
# .claude/hooks/intent-gate-check.sh. Separate from DP.SC.201/DR-03's
# plan-hour admission machinery (plan_allocation.py) -- this is an
# announcement, not an admission to a contested resource (pilot decision,
# WP-561 F33, MC-sessions:2026-10/13/2026-10-13-07-wp561-f33-archgate-receiver).
set -euo pipefail

USAGE="usage: declare-intent.sh <WP-N|outside-wp> [--ritual \"<agreed Ritual, one line>\"] [--inbox-deferred \"<the pilot's own words deferring the inbox triage>\"]"
INTENT="${1:-}"
if [[ ! "$INTENT" =~ ^(WP-[0-9]+|outside-wp)$ ]]; then
  echo "$USAGE" >&2
  exit 1
fi
shift
# WP-484 Ф267 п.4: the pilot-agreed Ritual is kept in this per-conversation
# record, so ritual-hard-gate.sh need not find it in the transcript again after
# the conversation is compacted (the summary names the WP, the Ritual text is gone).
# WP-561 Ф94 part 2: --inbox-deferred keeps, next to the Ritual, the pilot's own
# words that defer the triage of the WP inbox, bound to the server fingerprint of
# its «новое» entries. .claude/hooks/inbox-admission-gate.sh admits work on it only
# while that fingerprint is unchanged and the words are in a message of the pilot.
RITUAL=""
RITUAL_REQUESTED=0
DEFER_QUOTE=""
DEFER_REQUESTED=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ritual)
      if [ "$RITUAL_REQUESTED" = 1 ]; then echo "$USAGE" >&2; exit 1; fi
      RITUAL_REQUESTED=1
      RITUAL="${2:-}"
      if [ -z "$RITUAL" ] || [ "$INTENT" = "outside-wp" ]; then
        echo "declare-intent.sh: --ritual требует непустой текст и номер РП (не outside-wp)" >&2
        exit 1
      fi
      shift 2
      ;;
    --inbox-deferred)
      if [ "$DEFER_REQUESTED" = 1 ]; then echo "$USAGE" >&2; exit 1; fi
      DEFER_REQUESTED=1
      DEFER_QUOTE="${2:-}"
      if [ -z "$DEFER_QUOTE" ] || [ "$INTENT" = "outside-wp" ]; then
        echo "declare-intent.sh: --inbox-deferred требует дословную цитату пилота и номер РП (не outside-wp)" >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      echo "$USAGE" >&2
      exit 1
      ;;
  esac
done
# One line; bounded to 2000 characters in jq below (the record is read by hooks on every tool call).
# Two parallel calls for one conversation could overwrite each other's record:
# one conversation is driven by one agent, so the race is accepted, not locked.
RITUAL=$(printf '%s' "$RITUAL" | tr '\n\r' '  ')
if [ "${RITUAL_REQUESTED:-0}" = 1 ] && [[ ! "$RITUAL" =~ [^[:space:]] ]]; then
  echo "declare-intent.sh: --ritual не должен быть пустым после нормализации" >&2
  exit 1
fi
DEFER_QUOTE=$(printf '%s' "$DEFER_QUOTE" | tr '\n\r' '  ')
if [ "$DEFER_REQUESTED" = 1 ] && [[ ! "$DEFER_QUOTE" =~ [^[:space:]] ]]; then
  echo "declare-intent.sh: --inbox-deferred не должен быть пустым после нормализации" >&2
  exit 1
fi

SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "$SESSION_ID" ]; then
  echo "declare-intent.sh: CLAUDE_CODE_SESSION_ID не задан -- не знаю, для какой сессии писать" >&2
  exit 1
fi
# M4 (Fable cold review, 13.10): CLAUDE_CODE_SESSION_ID becomes a filename
# below -- reject anything that could escape intent-declarations/ (e.g. "../x")
# before it's used in a path, not after.
if [[ ! "$SESSION_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "declare-intent.sh: CLAUDE_CODE_SESSION_ID имеет недопустимый формат: $SESSION_ID" >&2
  exit 1
fi

# WP-503 Ф109: admission to execute, checked BEFORE the intent is recorded, so
# a refused WP leaves no declaration for intent-gate-check.sh to accept.
# A new WP and new phases in progress must link to existing changes owned by
# this WP (WP-611 lists) or to a pilot decision allowing an exception; a pending
# request does not admit work. IWE_GOVERNANCE_REPO_PATH points to the copy the
# session edits (isolated copy); unset = the shared checkout.
if [[ "$INTENT" == WP-* ]]; then
  GOV_DIR="${IWE_GOVERNANCE_REPO_PATH:-${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}}"
  if [ ! -d "$GOV_DIR" ]; then
    echo "declare-intent.sh: репозиторий планов $GOV_DIR не найден — допуск по связям со списками не проверен" >&2
  elif [ -f "$GOV_DIR/machine/wp-links-policy.yaml" ]; then
    # Shared checkout (no explicit copy path): read the published card, because the
    # checkout may lag origin and refuse a WP whose published card has the links
    # (WP-503 Ф109, Fable review 16.11). A wp-links.py that predates the option
    # would read "PUBLISHED" as a revision and refuse everything, so ask for it
    # only when the script knows it.
    LINKS_TREE=WORKTREE
    if [ -z "${IWE_GOVERNANCE_REPO_PATH:-}" ] && grep -q PUBLISHED "$GOV_DIR/scripts/wp-links.py" 2>/dev/null; then
      LINKS_TREE=PUBLISHED
    fi
    if ! python3 "$GOV_DIR/scripts/wp-links.py" check --repo "$GOV_DIR" --wp "${INTENT#WP-}" \
         --purpose execute --tree "$LINKS_TREE" </dev/null; then
      echo "declare-intent.sh: ${INTENT} не допущен к исполнению (связи со списками, выше); намерение не записано, работу не начинать" >&2
      echo "  Карточка в отдельной копии — передайте её путь: IWE_GOVERNANCE_REPO_PATH=<копия> bash declare-intent.sh ${INTENT}" >&2
      exit 3
    fi
  fi
fi

# WP-561 Ф94 part 2: the server fingerprint of the WP's «новое» entries for
# --inbox-deferred, read the same way as show_wp_mailbox below (fetch, then
# wp-inbox.sh at origin/main). Sets DEFER_FP (empty = nothing to defer) and
# DEFER_SHA; on any read failure explains and returns 1.
inbox_deferral_fingerprint() {
  local num="${1#WP-}" repo inbox_script lib
  inbox_script="${IWE_SCRIPTS:-$HOME/IWE/scripts}/wp-inbox.sh"
  if [ -n "${IWE_GOVERNANCE_REPO_PATH:-}" ]; then
    repo="$IWE_GOVERNANCE_REPO_PATH"
  elif [ -n "${IWE_GOVERNANCE_REPO:-}" ]; then
    repo="${IWE_WORKSPACE:-$HOME/IWE}/$IWE_GOVERNANCE_REPO"
  else
    echo "declare-intent.sh: отсрочка не записана: репозиторий планов не задан (IWE_GOVERNANCE_REPO_PATH или IWE_GOVERNANCE_REPO); намерение не записано" >&2
    return 1
  fi
  if [ ! -r "$inbox_script" ] || [ ! -d "$repo" ]; then
    echo "declare-intent.sh: отсрочка не записана: нет скрипта ящика ${inbox_script} или репозитория планов ${repo}; намерение не записано" >&2
    return 1
  fi
  lib="$(dirname "$inbox_script")/lib/run-limited.sh"
  # shellcheck source=lib/run-limited.sh
  [ -r "$lib" ] && . "$lib"
  if ! declare -F run_limited >/dev/null 2>&1; then
    run_limited() { shift; "$@"; }
  fi
  if ! run_limited 12 git -C "$repo" fetch -q origin </dev/null >/dev/null 2>&1; then
    echo "declare-intent.sh: отсрочка не записана: сервер не опрошен (git fetch не удался), отпечаток ящика по серверу не получен; намерение не записано" >&2
    return 1
  fi
  if ! DEFER_SHA=$(git -C "$repo" rev-parse --verify --quiet "origin/main^{commit}"); then
    echo "declare-intent.sh: отсрочка не записана: в ${repo} нет origin/main; намерение не записано" >&2
    return 1
  fi
  if ! DEFER_FP=$(run_limited 15 bash "$inbox_script" digest --wp "$num" --repo "$repo" --rev "$DEFER_SHA" </dev/null 2>/dev/null); then
    echo "declare-intent.sh: отсрочка не записана: отпечаток ящика ${1} не получен (wp-inbox.sh digest); намерение не записано" >&2
    return 1
  fi
}

# A deferral that cannot be bound to the server inbox is refused together with
# the declaration (exit 4): the pilot's words must not silently go unrecorded.
DEFER_FP=""
DEFER_SHA=""
if [ "$DEFER_REQUESTED" = 1 ]; then
  inbox_deferral_fingerprint "$INTENT" || exit 4
  if [ -z "$DEFER_FP" ]; then
    echo "Ящик входящих ${INTENT}: новых записей по серверу нет, откладывать нечего; отсрочка не записана."
    DEFER_QUOTE=""
  fi
fi

INTENT_DIR="${IWE_RUNTIME_DIR:-$HOME/IWE/.iwe-runtime}/intent-declarations"
mkdir -p "$INTENT_DIR"

DECLARED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
AGENT="${IWE_AGENT:-unknown}"

# M1 (Fable cold review): write to a temp file and rename, not a direct `>`
# truncate -- a reader hitting the file mid-write would otherwise see a
# partial/empty JSON and the gate would misread it as badly stale.
TMP_FILE=$(mktemp "$INTENT_DIR/.$SESSION_ID.XXXXXX")
# A repeated declaration for the SAME WP keeps the Ritual already agreed; a
# different WP or outside-wp starts without one (it needs its own agreement).
KEEP_RITUAL="null"
if [ -z "$RITUAL" ] && [ -f "$INTENT_DIR/$SESSION_ID.json" ]; then
  KEEP_RITUAL=$(jq -c --arg intent "$INTENT" 'select(.intent == $intent) | .ritual // null' \
    "$INTENT_DIR/$SESSION_ID.json" 2>/dev/null || true)
  [ -n "$KEEP_RITUAL" ] || KEEP_RITUAL="null"
fi
# The inbox deferral is kept the same way: same WP and no new deferral given.
KEEP_DEFERRAL="null"
if [ "$DEFER_REQUESTED" = 0 ] && [ -f "$INTENT_DIR/$SESSION_ID.json" ]; then
  KEEP_DEFERRAL=$(jq -cs --arg intent "$INTENT" \
    'if length == 1 then (.[0] | select(.intent == $intent) | .inbox_deferral // null) else null end' \
    "$INTENT_DIR/$SESSION_ID.json" 2>/dev/null || true)
  [ -n "$KEEP_DEFERRAL" ] || KEEP_DEFERRAL="null"
fi
jq -nc --arg session "$SESSION_ID" --arg agent "$AGENT" --arg intent "$INTENT" --arg at "$DECLARED_AT" \
  --arg ritual "$RITUAL" --argjson keep "$KEEP_RITUAL" \
  --arg dquote "$DEFER_QUOTE" --arg dfp "$DEFER_FP" --arg dsha "$DEFER_SHA" --argjson keepdef "$KEEP_DEFERRAL" \
  '{session_id: $session, agent: $agent, intent: $intent, declared_at: $at}
   + (if $ritual != "" then {ritual: {text: $ritual[:2000], agreed_at: $at}}
      elif $keep != null then {ritual: $keep} else {} end)
   + (if $dquote != "" then {inbox_deferral: {wp: $intent, session_id: $session, fingerprint: $dfp,
        server_commit: $dsha, quote: $dquote[:2000], recorded_at: $at}}
      elif $keepdef != null then {inbox_deferral: $keepdef} else {} end)' \
  > "$TMP_FILE"
mv -f "$TMP_FILE" "$INTENT_DIR/$SESSION_ID.json"

echo "Намерение записано: $INTENT (сессия $SESSION_ID, агент $AGENT)"
[ -z "$RITUAL" ] || echo "Согласованный Ритуал записан в запись беседы: проверка Ритуала не потребует его заново после сжатия."

# WP-561 Ф88: the pilot's word "почта" is the WP's inbound mailbox (inbox/WP-N/INBOX.md).
# Print its state at declaration time, so an agent sees pending entries instead of
# having to remember the mailbox rule (three agents answered "no such step" on 26.11).
# Never blocks and never prints a bare "0" for a read failure: a failed read says
# "не проверен". Behaviour change vs the handoff reader, which never fetches: this
# fetches origin (fetch leaves the working tree alone) so the count is by the server.
# The governance repo must be named explicitly (IWE_GOVERNANCE_REPO_PATH or
# IWE_GOVERNANCE_REPO): a default would silently read another repository.
show_wp_mailbox() {
  local wp="$1" num="${1#WP-}"
  local inbox_script="${IWE_SCRIPTS:-$HOME/IWE/scripts}/wp-inbox.sh"
  local repo basis="по серверу" rev_flag="--rev origin/main" out heads count lib
  if [ -n "${IWE_GOVERNANCE_REPO_PATH:-}" ]; then
    repo="$IWE_GOVERNANCE_REPO_PATH"
  elif [ -n "${IWE_GOVERNANCE_REPO:-}" ]; then
    repo="${IWE_WORKSPACE:-$HOME/IWE}/$IWE_GOVERNANCE_REPO"
  else
    echo "Ящик входящих $wp: не проверен (репозиторий планов не задан); проверить: wp-inbox.sh list --wp $num --rev origin/main"
    return 0
  fi
  if [ ! -r "$inbox_script" ] || [ ! -d "$repo" ]; then
    echo "Ящик входящих $wp: не проверен (нет скрипта ящика или репозитория планов $repo)"
    return 0
  fi
  lib="$(dirname "$inbox_script")/lib/run-limited.sh"
  # shellcheck source=lib/run-limited.sh
  [ -r "$lib" ] && . "$lib"
  if ! declare -F run_limited >/dev/null 2>&1; then
    run_limited() { shift; "$@"; }
  fi
  if ! run_limited 12 git -C "$repo" fetch -q origin </dev/null >/dev/null 2>&1; then
    rev_flag=""
    basis="по локальной копии, сервер не опрошен"
  fi
  # shellcheck disable=SC2086  # rev_flag is intentionally two words or empty
  if ! out=$(run_limited 15 bash "$inbox_script" list --wp "$num" --repo "$repo" $rev_flag </dev/null 2>&1); then
    echo "Ящик входящих $wp: не проверен ($(printf '%s' "$out" | head -n 1))"
    return 0
  fi
  heads=$(printf '%s\n' "$out" | LC_ALL=C grep -E '^## И-[0-9]+ · ' || true)
  if [ -z "$heads" ]; then
    echo "Ящик входящих $wp: новых записей нет ($basis)"
    return 0
  fi
  count=$(printf '%s\n' "$heads" | grep -c . || true)
  echo "Ящик входящих $wp: новых записей $count ($basis). Разобрать до работы, шаг 3 протокола открытия сессии:"
  printf '%s\n' "$heads" | sed 's/^## /  /'
}

# WP-484 F257 M3: show where the previous session stopped, straight after the
# intent is recorded.  Optional: a slow or failing reader never blocks the
# declaration (`|| true`), and `outside-wp` has no card to read.
case "$INTENT" in
  WP-*)
    SHOW_SCRIPT="${IWE_SCRIPTS:-$HOME/IWE/scripts}/wp-handoff-show.sh"
    if [ -x "$SHOW_SCRIPT" ]; then
      # The reader's own network check is limited to 10 s; this outer limit is longer
      # so a hanging network still lets it print the card fields before it is cut.
      LIMIT_LIB="$(dirname "$SHOW_SCRIPT")/lib/run-limited.sh"
      if [ -r "$LIMIT_LIB" ]; then
        # shellcheck source=lib/run-limited.sh
        . "$LIMIT_LIB"
        run_limited 20 bash "$SHOW_SCRIPT" "$INTENT" </dev/null || true
      else
        bash "$SHOW_SCRIPT" "$INTENT" </dev/null || true
      fi
    fi
    show_wp_mailbox "$INTENT" || true
    ;;
esac
if [ -n "$DEFER_QUOTE" ]; then
  echo "Отсрочка разбора ящика ${INTENT} записана в запись беседы, слова пилота: «${DEFER_QUOTE}» (отпечаток записей по серверу ${DEFER_FP:0:12}). Проверка допуска сверит цитату с сообщениями пилота в этой беседе; новая запись на сервере отменит отсрочку."
fi
