#!/usr/bin/env bash
# WP-530 Ф66: mandatory actualization gate for WP reopen (DP.SC.154 peer-session
# 2026-09-25-16-wp530-instant-sync-mandatory-reopen, ArchGate-approved design).
#
# Replaces protocol-open.md's old SS3.5 soft ritual ("summary + pilot says yes,
# nothing enforced") with a machine-checked state machine:
#   reopened -> actualization_required -> actualized -> editing_allowed
#
# A lease is valid only for the exact origin revision of the WP card it was
# taken against (digest-bound, not a bare boolean) -- an unrelated WP's commit
# on origin cannot invalidate this WP's lease, because the digest is scoped to
# this WP's own card file only.
#
# Break-glass (closure-pending-sync) is a two-call challenge/response, not a
# bare role check -- ArchGate condition #1 (ArchGate WP-530 Ф66, pilot ack
# 2026-09-25, see MC-sessions/.../04-pilot-archgate-acknowledgement.md).
# Honest limit (cold review, 2026-09-26): it does NOT prove a human read the
# code -- the calling agent's own process can read its own stdout and confirm
# immediately, with zero human involvement. What it DOES guarantee: a second,
# explicit, deliberate call with the exact code (not a single flag), a
# rate-limited window, and an immutable audit trail of when/why/who-claimed.
# Actual human involvement is a PROCEDURAL discipline on the calling agent
# (relay the code through a channel the pilot reads, e.g. chat or Telegram,
# not just echo it back to itself) -- the same trust model every other
# pilot-decision point in this codebase already relies on (AskUserQuestion
# included: nothing here is cryptographically stronger, and nothing else in
# the platform is either).
set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-my-strategy}"
# NOT $IWE_RUNTIME -- that env var is already claimed platform-wide (see
# .claude/settings.json) as an agent-runtime IDENTIFIER ("claude-code"), not
# a path. Every Claude Code session has it set, so the original ${IWE_RUNTIME:-...}
# fallback silently resolved to a bogus relative path ("claude-code/...")
# instead of the real .iwe-runtime directory -- found live on 2026-09-26 when
# a real (non-sandboxed) run produced a heartbeat file nobody could find at
# the documented path. Sandboxed tests never caught it because they export
# their own override for the same name. Follow session-guard.sh's own
# convention instead: no env override, always $IWE_ROOT/.iwe-runtime.
LEASE_DIR="$IWE_ROOT/.iwe-runtime/wp-reopen-leases"
LEASE_TTL_SECONDS="${WP_REOPEN_LEASE_TTL:-28800}"   # 8h, matches the old wp-sync-N.done window but is a separate mechanism
CHALLENGE_TTL_SECONDS=300                            # 5 min to type back the challenge
MAX_CHALLENGE_ATTEMPTS=5                             # caps brute-force of the 6-digit code within the TTL window

usage() {
  cat >&2 <<'EOF'
Usage:
  wp-reopen-gate.sh actualize --wp N [--governance-repo PATH] [--session-id ID] [--branch main]
  wp-reopen-gate.sh check-edit --wp N [--governance-repo PATH] [--session-id ID]
  wp-reopen-gate.sh status --wp N [--governance-repo PATH]
  wp-reopen-gate.sh closure-pending-sync request --wp N --reason TEXT [--actor NAME]
  wp-reopen-gate.sh closure-pending-sync confirm --wp N --challenge-response CODE
EOF
  exit 1
}

log_err() { echo "WP-REOPEN-GATE: $*" >&2; }

resolve_gov_repo() {
  local override="$1"
  if [ -n "$override" ]; then echo "$override"; return; fi
  local candidate
  candidate=$(git rev-parse --show-toplevel 2>/dev/null) || true
  if [ -n "$candidate" ] && [ "$(basename "$candidate")" = "$GOV_REPO" ]; then
    echo "$candidate"
    return
  fi
  echo "$IWE_ROOT/$GOV_REPO"
}

require_numeric_wp() {
  case "$1" in
    ''|*[!0-9]*) log_err "СТОП: --wp должен быть числом, получено: '$1'"; exit 1 ;;
  esac
}

card_path_for() { echo "inbox/WP-$1/WP-$1.md"; }

lease_file_for() { mkdir -p "$LEASE_DIR"; echo "$LEASE_DIR/WP-$1.json"; }

challenge_file_for() { mkdir -p "$LEASE_DIR"; echo "$LEASE_DIR/WP-$1.challenge"; }

now_epoch() { date -u +%s; }

# Same entropy source as session-guard.sh's session_id generator
# (Ф2/Ф3 fix, 2026-08-15): /dev/urandom first, $RANDOM fallback for sandboxes
# where /dev/urandom is unreadable.
gen_token() {
  if [ -r /dev/urandom ]; then
    head -c 16 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null | tr -d '\n'
  else
    echo "${RANDOM}${RANDOM}${RANDOM}$$"
  fi
}

gen_challenge_code() {
  if [ -r /dev/urandom ]; then
    head -c 4 /dev/urandom 2>/dev/null | od -An -tu2 2>/dev/null | tr -d ' \n' | tail -c 6
  else
    echo "$((RANDOM % 1000000))"
  fi
}

atomic_write() {
  local target="$1" content="$2"
  local tmp
  tmp=$(mktemp "${target}.tmp.XXXXXX")
  printf '%s' "$content" > "$tmp"
  mv -f "$tmp" "$target"
}

json_get() {
  # json_get <file> <key>  -- single-level string/number field, good enough for
  # this script's own flat lease schema (not a general JSON parser).
  python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    v = data.get(sys.argv[2], '')
    print(v if isinstance(v, str) else json.dumps(v))
except Exception:
    print('')
" "$1" "$2"
}

# One JSON parse for the whole lease, one field per output line in a fixed
# order -- avoids the torn-read window of calling json_get() once per field
# while a concurrent actualize() could be mid atomic_write (cold review,
# 2026-09-26). Line-separated, not space-separated: every field here is
# either script-generated (digest, token, timestamp) or a git ref/path that
# cannot contain a newline, so `mapfile` on stdout is exact and doesn't
# require escaping. A field's own value is never empty-vs-missing ambiguous
# here since json_get-style '' default already means "missing" throughout
# this script.
read_lease_fields() {
  local lease_f="$1"
  python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    data = {}
for k in ('session_id', 'card_path', 'card_digest', 'actualized_at', 'ttl_seconds', 'closure_pending_sync', 'branch'):
    print(data.get(k, ''))
" "$lease_f"
}

# Propagates git's own exit status through the pipe explicitly (cold review,
# 2026-09-26): under `set -o pipefail`, a failing `git show` piped into
# shasum/awk (both of which succeed on empty input) was masked because
# pipefail reports the LAST non-zero exit in the pipeline, and here git show
# actually is that one -- but callers doing a bare `digest=$(origin_card_digest
# ...)` still hit set -e's command-substitution-in-assignment trap and abort
# with git's own suppressed exit code (128) instead of the documented
# fallback message. Callers must use `if ! digest=$(origin_card_digest ...)`.
origin_card_digest() {
  local repo="$1" branch="$2" path="$3"
  local out
  if ! out=$(git -C "$repo" show "origin/$branch:$path" 2>/dev/null); then
    return 1
  fi
  printf '%s' "$out" | shasum -a 256 | awk '{print $1}'
}

cmd_actualize() {
  local wp="" gov_override="" session_id="" branch="main"
  while [ $# -gt 0 ]; do
    case "$1" in
      --wp) wp="$2"; shift 2 ;;
      --governance-repo) gov_override="$2"; shift 2 ;;
      --session-id) session_id="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$wp" ] || usage
  require_numeric_wp "$wp"
  session_id="${session_id:-${CLAUDE_CODE_SESSION_ID:-}}"
  [ -n "$session_id" ] || { log_err "СТОП: не удалось определить session_id (нет --session-id, нет CLAUDE_CODE_SESSION_ID в окружении — например, вызов от Kimi/Codex). Передай --session-id явно."; exit 1; }

  local repo card path digest origin_commit token lease
  repo=$(resolve_gov_repo "$gov_override")
  path=$(card_path_for "$wp")
  card="$repo/$path"
  [ -f "$card" ] || { log_err "карточка $path не найдена в $repo — актуализация невозможна"; exit 1; }

  git -C "$repo" fetch -q origin "$branch" || { log_err "git fetch origin $branch не удался — актуализация невозможна без сети"; exit 1; }
  origin_commit=$(git -C "$repo" rev-parse "origin/$branch")
  if ! digest=$(origin_card_digest "$repo" "$branch" "$path"); then
    log_err "не удалось прочитать $path на origin/$branch — карточка там не найдена?"
    exit 1
  fi
  token=$(gen_token)

  lease=$(python3 -c "
import json, sys
print(json.dumps({
    'wp': sys.argv[1], 'session_id': sys.argv[2], 'origin_commit': sys.argv[3],
    'card_path': sys.argv[4], 'card_digest': sys.argv[5], 'fencing_token': sys.argv[6],
    'actualized_at': int(sys.argv[7]), 'ttl_seconds': int(sys.argv[8]),
    'branch': sys.argv[9], 'closure_pending_sync': False,
}))
" "$wp" "$session_id" "$origin_commit" "$path" "$digest" "$token" "$(now_epoch)" "$LEASE_TTL_SECONDS" "$branch")
  atomic_write "$(lease_file_for "$wp")" "$lease"
  echo "$lease"
  log_err "actualized: WP-$wp @ origin_commit=${origin_commit:0:9} digest=${digest:0:12} session=$session_id"
}

cmd_check_edit() {
  local wp="" gov_override="" session_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --wp) wp="$2"; shift 2 ;;
      --governance-repo) gov_override="$2"; shift 2 ;;
      --session-id) session_id="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$wp" ] || usage
  require_numeric_wp "$wp"
  session_id="${session_id:-${CLAUDE_CODE_SESSION_ID:-}}"
  [ -n "$session_id" ] || { log_err "СТОП: не удалось определить session_id (нет --session-id, нет CLAUDE_CODE_SESSION_ID в окружении — например, вызов от Kimi/Codex). Без него владение лицензией не проверяется — передай --session-id явно, отказано fail-closed."; exit 2; }

  local lease_f
  lease_f=$(lease_file_for "$wp")
  if [ ! -f "$lease_f" ]; then
    log_err "СТОП: РП-$wp не актуализирован в этой сессии. Выполни: wp-reopen-gate.sh actualize --wp $wp, затем повтори правку."
    exit 2
  fi

  # Single atomic read of every field this check needs -- json_get() called
  # once per field left a window where a concurrent actualize()'s
  # atomic_write (rename) could land between reads and mix old/new field
  # values (cold review, 2026-09-26).
  local lease_fields lease_session lease_path lease_digest lease_ts lease_ttl lease_closure lease_branch
  mapfile -t lease_fields < <(read_lease_fields "$lease_f")
  lease_session="${lease_fields[0]}"; lease_path="${lease_fields[1]}"; lease_digest="${lease_fields[2]}"
  lease_ts="${lease_fields[3]}"; lease_ttl="${lease_fields[4]}"; lease_closure="${lease_fields[5]}"
  lease_branch="${lease_fields[6]}"

  if [ "$lease_closure" = "True" ] || [ "$lease_closure" = "true" ]; then
    log_err "СТОП: РП-$wp находится в состоянии closure_pending_sync (отложенное закрытие при недоступном origin) — обычные правки заблокированы до разрешения конфликта пилотом."
    exit 2
  fi

  if [ -n "$lease_ts" ] && [ -n "$lease_ttl" ]; then
    local age
    age=$(( $(now_epoch) - lease_ts ))
    if [ "$age" -gt "$lease_ttl" ]; then
      log_err "СТОП: лицензия актуализации РП-$wp истекла ($((age/3600))ч назад истёк TTL ${lease_ttl}с). Выполни: wp-reopen-gate.sh actualize --wp $wp, затем повтори правку."
      exit 2
    fi
  fi

  if [ "$lease_session" != "$session_id" ]; then
    log_err "СТОП: лицензия актуализации РП-$wp принадлежит другой сессии ($lease_session), не текущей ($session_id). Выполни: wp-reopen-gate.sh actualize --wp $wp из своей сессии."
    exit 2
  fi

  local repo path branch current_digest
  repo=$(resolve_gov_repo "$gov_override")
  path="${lease_path:-$(card_path_for "$wp")}"
  branch="${lease_branch:-main}"
  if ! git -C "$repo" fetch -q origin "$branch"; then
    log_err "СТОП: git fetch origin $branch не удался — без сети нельзя доказать, что карточка РП-$wp не изменилась с момента актуализации. Повтори при восстановлении сети, либо wp-reopen-gate.sh closure-pending-sync при длительном отказе."
    exit 2
  fi
  if ! current_digest=$(origin_card_digest "$repo" "$branch" "$path"); then
    log_err "СТОП: не удалось прочитать $path на origin/$branch сейчас — карточка удалена или переименована с момента актуализации? Выполни actualize заново."
    exit 2
  fi
  if [ "$current_digest" != "$lease_digest" ]; then
    log_err "СТОП: карточка РП-$wp изменилась на сервере с момента актуализации (было ${lease_digest:0:12}, стало ${current_digest:0:12}). Выполни: wp-reopen-gate.sh actualize --wp $wp, затем повтори правку."
    exit 2
  fi

  echo "editing_allowed"
  log_err "editing_allowed: WP-$wp session=$session_id"
}

cmd_status() {
  local wp="" gov_override=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --wp) wp="$2"; shift 2 ;;
      --governance-repo) gov_override="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$wp" ] || usage
  local lease_f
  lease_f=$(lease_file_for "$wp")
  if [ ! -f "$lease_f" ]; then
    echo "state=actualization_required reason=no_lease"
    return
  fi
  cat "$lease_f"
}

cmd_closure_request() {
  local wp="" reason="" actor="${USER:-unknown}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --wp) wp="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      --actor) actor="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$wp" ] || usage
  [ -n "$reason" ] || { log_err "--reason обязателен для closure-pending-sync request"; exit 1; }

  local code cf
  code=$(gen_challenge_code)
  cf=$(challenge_file_for "$wp")
  atomic_write "$cf" "$(python3 -c "import json,sys; print(json.dumps({'code': sys.argv[1], 'reason': sys.argv[2], 'actor': sys.argv[3], 'issued_at': int(sys.argv[4]), 'attempts': 0}))" "$code" "$reason" "$actor" "$(now_epoch)")"
  echo "Код подтверждения: $code"
  log_err "Передай этот код пилоту через отдельный канал (чат/голос) и попроси назвать его обратно -- это не криптографическая проверка личности, только вынужденный второй явный шаг, не одиночный флаг; затем вызови: wp-reopen-gate.sh closure-pending-sync confirm --wp $wp --challenge-response <код от пилота> (действует ${CHALLENGE_TTL_SECONDS}с, максимум $MAX_CHALLENGE_ATTEMPTS попыток)"
}

cmd_closure_confirm() {
  local wp="" response=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --wp) wp="$2"; shift 2 ;;
      --challenge-response) response="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$wp" ] || usage
  [ -n "$response" ] || { log_err "--challenge-response обязателен для closure-pending-sync confirm"; exit 1; }

  # Atomic claim (mv is a single rename syscall) before reading/validating --
  # two concurrent confirm calls can no longer both read the same attempts
  # counter and both increment from the same base, nor both consume the same
  # correct code and double-write the audit trail (cold review, 2026-09-26,
  # Low finding #9). Whichever process loses the race sees the file gone and
  # fails cleanly; the winner restores it (with an incremented attempt
  # count) on a wrong-but-not-yet-exhausted guess, or deletes it for good on
  # success/expiry/exhaustion.
  local cf claimed
  cf=$(challenge_file_for "$wp")
  claimed="${cf}.claim.$$"
  if ! mv "$cf" "$claimed" 2>/dev/null; then
    log_err "нет активного запроса closure-pending-sync для WP-$wp (уже использован, истёк, или обрабатывается другим вызовом сейчас) — вызови request заново"
    exit 1
  fi

  local issued code_expected attempts age reason actor
  code_expected=$(json_get "$claimed" code)
  issued=$(json_get "$claimed" issued_at)
  attempts=$(json_get "$claimed" attempts)
  [ -n "$attempts" ] || attempts=0
  age=$(( $(now_epoch) - issued ))

  if [ "$age" -gt "$CHALLENGE_TTL_SECONDS" ]; then
    rm -f "$claimed"
    log_err "код подтверждения истёк (${age}с > ${CHALLENGE_TTL_SECONDS}с) — вызови request заново"
    exit 1
  fi

  if [ "$response" != "$code_expected" ]; then
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$MAX_CHALLENGE_ATTEMPTS" ]; then
      rm -f "$claimed"
      log_err "код подтверждения не совпадает, попытки исчерпаны ($attempts/$MAX_CHALLENGE_ATTEMPTS) — вызови request заново"
      exit 1
    fi
    reason=$(json_get "$claimed" reason)
    actor=$(json_get "$claimed" actor)
    atomic_write "$cf" "$(python3 -c "import json,sys; print(json.dumps({'code': sys.argv[1], 'reason': sys.argv[2], 'actor': sys.argv[3], 'issued_at': int(sys.argv[4]), 'attempts': int(sys.argv[5])}))" "$code_expected" "$reason" "$actor" "$issued" "$attempts")"
    rm -f "$claimed"
    log_err "код подтверждения не совпадает — closure-pending-sync отклонён (попытка $attempts/$MAX_CHALLENGE_ATTEMPTS)"
    exit 1
  fi

  reason=$(json_get "$claimed" reason)
  actor=$(json_get "$claimed" actor)
  cf="$claimed"

  local audit_line lease_f
  audit_line=$(python3 -c "
import json, sys
print(json.dumps({
    'wp': sys.argv[1], 'ts': int(sys.argv[2]), 'reason': sys.argv[3], 'actor': sys.argv[4],
    'origin_error': 'unavailable_or_pilot_declared', 'confirmed_via_challenge': True,
}))
" "$wp" "$(now_epoch)" "$reason" "$actor")
  mkdir -p "$LEASE_DIR"
  printf '%s\n' "$audit_line" >> "$LEASE_DIR/closure-pending-sync-audit.jsonl"

  lease_f=$(lease_file_for "$wp")
  atomic_write "$lease_f" "$(python3 -c "
import json, sys
print(json.dumps({
    'wp': sys.argv[1], 'session_id': 'closure-pending-sync', 'origin_commit': 'unknown',
    'card_path': sys.argv[2], 'card_digest': 'unknown', 'fencing_token': 'closure-pending-sync',
    'actualized_at': int(sys.argv[3]), 'ttl_seconds': 0, 'closure_pending_sync': True,
}))
" "$wp" "$(card_path_for "$wp")" "$(now_epoch)")"
  rm -f "$cf"
  echo "closure_pending_sync recorded"
  log_err "WP-$wp помечен closure_pending_sync (аудит: $LEASE_DIR/closure-pending-sync-audit.jsonl). Обычные правки заблокированы до разрешения пилотом при восстановлении связи."
}

cmd_closure_pending_sync() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    request) cmd_closure_request "$@" ;;
    confirm) cmd_closure_confirm "$@" ;;
    *) usage ;;
  esac
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    actualize) cmd_actualize "$@" ;;
    check-edit) cmd_check_edit "$@" ;;
    status) cmd_status "$@" ;;
    closure-pending-sync) cmd_closure_pending_sync "$@" ;;
    *) usage ;;
  esac
}

main "$@"
