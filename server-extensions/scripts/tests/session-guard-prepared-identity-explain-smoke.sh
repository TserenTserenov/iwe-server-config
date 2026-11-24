#!/usr/bin/env bash
# _prepared_source_identity_explain names the first diverging PREPARED
# component (WP-561, 22.11, peer-session 2026-11-22-06). The real function is
# extracted from session-guard.sh; its collaborators are stubbed so that each
# branch is driven by one variable and checked by its observable stderr line.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-prepared-explain.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FAILURES=0
check() {  # check <name> <expected substring> <actual>
  case "$3" in
    *"$2"*) echo "  ok: $1" ;;
    *) echo "  FAIL: $1 (expected '$2' in '$3')"; FAILURES=$((FAILURES + 1)) ;;
  esac
}

FN_FILE="$TEST_ROOT/explain.sh"
awk '/^_prepared_source_identity_explain\(\) \{/ { on = 1 } on { print } on && /^}$/ { exit }' \
  "$GUARD" > "$FN_FILE"
grep -q '^_prepared_source_identity_explain() {' "$FN_FILE" \
  || { echo "FAIL: function not found in session-guard.sh"; exit 1; }
# shellcheck source=/dev/null
source "$FN_FILE"

WORK="$TEST_ROOT/work"
git init -q "$WORK"
git -C "$WORK" remote add origin https://example.invalid/work.git
COMMON=$(cd "$WORK/.git" && pwd -P)

# Recorded snapshot fields; MISSING_FIELD makes one of them unreadable.
MISSING_FIELD=""
REC_COMMON="$COMMON"; REC_ORIGIN="example.invalid/work"
REC_COMMITS='["a"]'; REC_CLAIMS='["w a - -"]'; REC_TARGET=refs/heads/main
_unique_record_field() {  # <semaphore> <field>
  [ "$2" != "$MISSING_FIELD" ] || return 1
  case "$2" in
    close_delivery_common_dir) printf '%s\n' "$REC_COMMON" ;;
    close_delivery_origin) printf '%s\n' "$REC_ORIGIN" ;;
    close_delivery_source_commits) printf '%s\n' "$REC_COMMITS" ;;
    close_delivery_claimed_commits) printf '%s\n' "$REC_CLAIMS" ;;
    close_delivery_target_ref) printf '%s\n' "$REC_TARGET" ;;
    *) printf 'x\n' ;;
  esac
}
normalize_remote_url() { printf 'example.invalid/work\n'; }
ACT_COMMITS='["a"]'; ACT_CLAIMS='["w a - -"]'
_isolated_source_commits_json() { printf '%s\n' "$ACT_COMMITS"; }
_session_commit_claims_json() { printf '%s\n' "$ACT_CLAIMS"; }

explain() { _prepared_source_identity_explain "$TEST_ROOT/sem" "$1" 2>&1 >/dev/null; }

check "missing worktree" "рабочей копии снимка нет" "$(explain "$TEST_ROOT/absent")"
MISSING_FIELD=close_delivery_target_ref
check "corrupt snapshot" "поле close_delivery_target_ref" "$(explain "$WORK")"
MISSING_FIELD=""
REC_COMMON=/elsewhere
check "common dir" "common-dir" "$(explain "$WORK")"
REC_COMMON="$COMMON"; REC_ORIGIN=other
check "origin" "origin" "$(explain "$WORK")"
REC_ORIGIN="example.invalid/work"; REC_TARGET=refs/heads/other
check "target ref" "целевая ветка" "$(explain "$WORK")"
REC_TARGET=refs/heads/main; ACT_COMMITS='["b"]'
check "source commits" "набор исходных коммитов" "$(explain "$WORK")"
ACT_COMMITS='["a"]'; ACT_CLAIMS='["w a - -","w b - -"]'
check "claims name the way out" "close --abandon-prepared" "$(explain "$WORK")"
ACT_CLAIMS='["w a - -"]'
check "everything else equal -> terminal" "terminal" "$(explain "$WORK")"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: PREPARED identity explanation"
  exit 0
fi
echo "FAIL: $FAILURES check(s) failed"
exit 1
