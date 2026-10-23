#!/bin/bash
# WP Card Read Gate (WP-484 Ф227, АрхГейт пройден 23.10, пир-сессия
# MC-sessions:2026-10/23/2026-10-23-12-wp530-canon-direct-writers)
# Event: PreToolUse (matcher: Read|Grep|Bash)
#
# Проблема (Ф227): карточка РП (inbox/WP-*/WP-*.md, archive/wp-contexts/**)
# читается из канонического чекаута, который может отставать от origin/main
# и не отражать фазы, опубликованные другой сессией/хостом. Текстовые
# инструкции агенту (protocol-open.md Шаг 3a) это ловят, но только если
# агент их выполнил — этот хук защищает путь мимо них: прямое чтение файла
# инструментом Read/Grep/явным Bash-чтением.
#
# Контракт (АрхГейт 23.10, пересмотрен относительно первого черновика Ф227):
#   - Критерий: БАЙТОВОЕ сравнение файла в каноне с тем же путём на OID
#     origin/<branch>, не git diff HEAD origin/main (тот не видит локально
#     изменённую карточку при равных HEAD/origin).
#   - Deny -- ТОЛЬКО когда байты доказанно разошлись (сама карточка, не
#     "история репо разошлась"). Неизвестная свежесть (офлайн, нет объекта
#     remote-коммита локально) -- allow, не deny: отказ при недоказанном
#     расхождении нарушил бы принцип пилота "блокировать только при
#     доказанном расхождении" (найдено консенсусом Kimi+Codex в этой же
#     пир-сессии -- первый черновик контракта это нарушал).
#   - Нераспознанный/не относящийся к карточке вызов -- allow без вывода.
#   - Изоляты (.iwe-runtime/isolated-worktrees/) и прочие репозитории --
#     allow без проверки (не канонический чекаут governance-репо).
#
# Честный предел гарантии: Bash-ветка матчит только явные cat/sed/head/tail/
# grep с литеральным путём карточки в тексте команды -- динамические команды
# (переменные, конкатенация пути) не распознаются и проходят как allow.
#
# Кэш свежести: ls-remote -- сетевой вызов, не на каждое чтение (Codex,
# та же пир-сессия). Ключ -- toplevel репозитория + HEAD; TTL ниже.
#
# Лог: ~/IWE/.claude/logs/wp-card-read-gate.jsonl

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
LOG_FILE="$IWE_ROOT/.claude/logs/wp-card-read-gate.jsonl"
CACHE_DIR="$IWE_ROOT/.claude/state/wp-card-read-gate"
CACHE_TTL_SEC="${WP_CARD_READ_GATE_CACHE_TTL:-300}"
GIT_SYNC_LIB="$IWE_ROOT/scripts/lib/git-sync-status.sh"

log_decision() {
  local decision="$1" target="${2:-}" detail="${3:-}"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || return 0
  jq -nc --arg ts "$ts" --arg sid "${CLAUDE_SESSION_ID:-}" --arg dec "$decision" \
    --arg target "$target" --arg detail "$detail" \
    '{ts:$ts, hook:"wp-card-read-gate", session_id:$sid, decision:$dec, target:$target, detail:$detail}' \
    >> "$LOG_FILE" 2>/dev/null || true
}

deny_json() {
  # <reason> -- the one locked output form (АрхГейт: "одна форма, закреплённая тестом").
  jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
}

# malformed input -- a literal JSON string, not jq-built, so a broken/missing
# jq still denies the one case the contract requires ("битый JSON входа для
# Read -- deny"), same reasoning as destructive-mcp-guard.sh.
deny_malformed() {
  log_decision "deny-malformed-input" "" "$1"
  printf '%s\n' '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "Не удалось разобрать вход хука -- блокирую чтение карточки РП как неопределённо устаревшее."}}'
  exit 0
}

# card_path_in <text>: prints the matched card-relative path (inbox/WP-N/WP-N.md
# or archive/wp-contexts/...) if <text> contains one, else prints nothing.
card_path_in() {
  printf '%s\n' "$1" | grep -oE '(^|[^[:alnum:]_-])(inbox/WP-[0-9]+/WP-[0-9]+\.md|archive/wp-contexts/[A-Za-z0-9_./-]+\.md)' \
    | sed -E 's/^.//' | head -1
}

# target_path_for <tool_name> <tool_input_json>: prints the path this call
# would read, or nothing if the tool/call is out of this gate's scope.
target_path_for() {
  local tool_name="$1" tool_input="$2"
  case "$tool_name" in
    Read)
      printf '%s' "$tool_input" | jq -r '.file_path // empty' 2>/dev/null
      ;;
    Grep)
      printf '%s' "$tool_input" | jq -r '.path // empty' 2>/dev/null
      ;;
    Bash)
      local cmd
      cmd=$(printf '%s' "$tool_input" | jq -r '.command // empty' 2>/dev/null) || return 0
      [ -n "$cmd" ] || return 0
      # Only explicit single-file read verbs; anything else (pipes into other
      # commands, variables, globs) is the honest limit of this scope.
      printf '%s' "$cmd" | grep -qE '(^|[;&|[:space:]])(cat|sed|head|tail|grep)([[:space:]]|$)' || return 0
      card_path_in "$cmd"
      ;;
    *) return 0 ;;
  esac
}

# is_isolate_path <abs-path>: true when the path lives under a session's
# isolated worktree, not the canonical checkout -- Ф227 scope excludes it.
is_isolate_path() {
  case "$1" in
    */.iwe-runtime/isolated-worktrees/*) return 0 ;;
    *) return 1 ;;
  esac
}

# sync_state_for <repo_toplevel>: sets GATE_REMOTE_OID / GATE_HEAD_OID /
# GATE_SYNC_STATUS by reading a fresh-enough cache or recomputing via
# git-sync-status.sh (ls-remote, not fetch). Cache key = toplevel path,
# invalidated by HEAD moving (a stale cache keyed only by toplevel would
# keep answering for an old HEAD after a local commit).
sync_state_for() {
  local toplevel="$1" head_oid cache_key cache_file now cached_head cached_at
  head_oid=$(git -C "$toplevel" rev-parse HEAD 2>/dev/null) || { GATE_SYNC_STATUS="checker_unavailable"; return 0; }
  cache_key=$(printf '%s' "$toplevel" | cksum | awk '{print $1}')
  cache_file="$CACHE_DIR/$cache_key.cache"
  now=$(date +%s)
  if [ -f "$cache_file" ]; then
    # format: <cached_at> <head_oid> <status> <remote_oid>
    read -r cached_at cached_head GATE_SYNC_STATUS GATE_REMOTE_OID < "$cache_file" 2>/dev/null || cached_at=0
    if [ "${cached_at:-0}" -gt 0 ] 2>/dev/null && [ "$cached_head" = "$head_oid" ] \
       && [ $((now - cached_at)) -lt "$CACHE_TTL_SEC" ]; then
      GATE_HEAD_OID="$head_oid"
      return 0
    fi
  fi
  if [ -r "$GIT_SYNC_LIB" ]; then
    # shellcheck source=../../scripts/lib/git-sync-status.sh
    . "$GIT_SYNC_LIB"
    check_git_sync_status "$toplevel" "" 8
    GATE_SYNC_STATUS="$GIT_SYNC_STATUS"
    GATE_REMOTE_OID="$GIT_SYNC_REMOTE_OID"
  else
    GATE_SYNC_STATUS="checker_unavailable"
    GATE_REMOTE_OID=""
  fi
  GATE_HEAD_OID="$head_oid"
  mkdir -p "$CACHE_DIR" 2>/dev/null \
    && printf '%s %s %s %s\n' "$now" "$head_oid" "$GATE_SYNC_STATUS" "$GATE_REMOTE_OID" > "$cache_file" 2>/dev/null || true
}

# decide <toplevel> <relpath>: prints "allow" or "deny:<reason>".
decide() {
  local toplevel="$1" relpath="$2"
  GATE_REMOTE_OID="" GATE_HEAD_OID="" GATE_SYNC_STATUS=""
  sync_state_for "$toplevel"

  case "$GATE_SYNC_STATUS" in
    checker_unavailable|fetch_failed|NO_UPSTREAM|NOT_A_REPO)
      # Freshness unknown -- not a proven divergence of THIS card. The old
      # draft denied here; the АрхГейт (Kimi+Codex, 23.10) found that a false
      # deny on mere unknown-ness contradicts "блокировать только при
      # доказанном расхождении" -- allow, with a diagnostic note only.
      printf 'allow'; return 0 ;;
  esac
  # A known remote OID is required to byte-compare at all -- "OK" (HEAD ==
  # remote) does NOT short-circuit to allow here: a committed HEAD equal to
  # origin says nothing about an UNCOMMITTED local edit to the working tree,
  # and that exact case is one of the contract's required test scenarios
  # (Ф227: "локально изменённая карточка при равных HEAD/origin").
  [ -n "$GATE_REMOTE_OID" ] || { printf 'allow'; return 0; }
  if ! git -C "$toplevel" cat-file -e "${GATE_REMOTE_OID}^{commit}" 2>/dev/null; then
    # Remote object not present locally -- cannot byte-compare without a
    # fetch, and fetching here is exactly what this read-only gate must not
    # do. Unknown, not proven -- allow.
    printf 'allow'; return 0
  fi
  local origin_content local_content origin_rc
  origin_content=$(git -C "$toplevel" show "${GATE_REMOTE_OID}:${relpath}" 2>/dev/null)
  origin_rc=$?
  if [ -f "$toplevel/$relpath" ]; then
    local_content=$(cat "$toplevel/$relpath" 2>/dev/null)
  else
    local_content=""
  fi
  if [ "$origin_rc" -ne 0 ]; then
    # Path does not exist at the pinned origin OID -- divergence proven
    # (local-only file, not yet published, or already removed on origin).
    printf 'deny:файл отсутствует на origin/main@%s, хотя читается из канона' "${GATE_REMOTE_OID:0:12}"
    return 0
  fi
  if [ "$origin_content" = "$local_content" ]; then
    printf 'allow'; return 0
  fi
  printf 'deny:отличается от снимка origin/main@%s' "${GATE_REMOTE_OID:0:12}"
}

# ---------------------------------------------------------------- self-test
self_test() {
  local failures=0
  run_case() {
    local name="$1" expect="$2" tool_name="$3" field="$4" value="$5"
    local payload out decision
    payload=$(jq -nc --arg tn "$tool_name" --arg f "$field" --arg v "$value" \
      '{hook_event_name:"PreToolUse", session_id:"self-test", tool_name:$tn, tool_input:{($f):$v}}')
    out=$(printf '%s' "$payload" | "$0" 2>/dev/null)
    if [ -z "$out" ]; then decision="allow"; else
      decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)
    fi
    if [ "$decision" = "$expect" ]; then
      printf 'PASS %s\n' "$name"
    else
      printf 'FAIL %s: expected=%s got=%s\n' "$name" "$expect" "$decision" >&2
      failures=$((failures + 1))
    fi
  }
  run_case non_card_read_allowed allow Read file_path "README.md"
  run_case card_path_read_matches_scope_recognized allow Read file_path "inbox/WP-999999/WP-999999.md"
  run_case grep_missing_path_allowed allow Grep path ""
  run_case bash_unrelated_command_allowed allow Bash command "echo hello"
  run_case bash_variable_path_not_matched allow Bash command "cat \$CARD_PATH"
  # The two cases above exercise routing only (target_path_for / scope
  # match) -- they resolve a card path to a toplevel that is not a real git
  # repo in this test environment, so decide() falls through checker_unavailable
  # -> allow regardless of the (nonexistent) sync state. A live divergence
  # (deny) path needs a real git fixture with a byte-level difference staged
  # against a pinned origin OID -- not covered here; flagged as a known gap,
  # not silently claimed as tested.
  [ "$failures" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

INPUT=$(cat 2>/dev/null) || deny_malformed "cat-failed"
printf '%s' "$INPUT" | jq -e \
  'type == "object" and (.tool_name | type) == "string" and (.tool_input | type) == "object"' \
  >/dev/null 2>&1 || deny_malformed "schema-invalid"

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name') || deny_malformed "tool_name-extract-failed"
TOOL_INPUT=$(printf '%s' "$INPUT" | jq -c '.tool_input') || deny_malformed "tool_input-extract-failed"
CLAUDE_SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)

case "$TOOL_NAME" in Read|Grep|Bash) ;; *) exit 0 ;; esac

TARGET=$(target_path_for "$TOOL_NAME" "$TOOL_INPUT") || exit 0
[ -n "$TARGET" ] || exit 0

CARD_REL=$(card_path_in "$TARGET")
[ -n "$CARD_REL" ] || exit 0

ABS_TARGET="$TARGET"
case "$ABS_TARGET" in /*) ;; *) ABS_TARGET="$PWD/$TARGET" ;; esac
if is_isolate_path "$ABS_TARGET"; then
  exit 0
fi

TARGET_DIR=$(dirname -- "$ABS_TARGET")
TOPLEVEL=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
TOPLEVEL_REAL=$(cd "$TOPLEVEL" 2>/dev/null && pwd -P) || exit 0
if is_isolate_path "$TOPLEVEL_REAL"; then
  exit 0
fi

RELPATH=$(git -C "$TOPLEVEL" ls-files --full-name -- "$ABS_TARGET" 2>/dev/null | head -1)
if [ -z "$RELPATH" ]; then
  # Not a tracked path in this repo (new/untracked card, or a path outside
  # the repo despite matching the card pattern lexically) -- nothing to
  # compare against origin, allow.
  exit 0
fi

RESULT=$(decide "$TOPLEVEL" "$RELPATH")
case "$RESULT" in
  allow)
    log_decision "allow" "$RELPATH" "${GATE_SYNC_STATUS:-}"
    exit 0
    ;;
  deny:*)
    REASON_DETAIL="${RESULT#deny:}"
    REASON="Карточка ${RELPATH} в каноне ${REASON_DETAIL}; читай через wp-sync-bundle.sh WP-N (CARD_SOURCE: origin-pinned) или git show origin/main:${RELPATH}. Канон не использовать для выводов по этой карточке."
    log_decision "deny" "$RELPATH" "$REASON_DETAIL"
    deny_json "$REASON"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
