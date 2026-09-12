#!/bin/bash
# hook-selfcheck.sh — PostToolUse (matcher: Edit|Write|MultiEdit), WP-544 Ф12 measure 1.
#
# Mechanizes a rule that kept failing as a manual step (lessons_secret_bypass_
# lib_apostrophe_total_lockout.md): right after an edit to .claude/hooks/*.sh,
# check `bash -n` and run --self-test, instead of waiting for pre-commit.
#
# Scope: Edit|Write|MultiEdit only, not Bash-based mutation (`sed -i` etc.) —
# see WP-544 card §Ф12 for why. Never fails closed: PostToolUse can't undo an
# already-applied write, and this checker must not become its own outage
# vector, so every risky call is guarded and it always exits 0.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[ -n "$FILE_PATH" ] || exit 0
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""

# Normalize to a path relative to the project root so that a false prefix
# match (e.g. backup/.claude/hooks/x.sh) cannot pass as a real hook file
# (WP-544 peer-session 2026-09-12-16, Codex round-2 finding): a suffix/
# substring check on ".claude/hooks/" cannot tell "/project/.claude/hooks/
# x.sh" apart from "/project/backup/.claude/hooks/x.sh" — both end the same
# way. `case` matching from the start of the normalized relative path can.
REL="$FILE_PATH"
if [ -n "$CWD" ] && [ "${REL#"$CWD"/}" != "$REL" ]; then
  REL="${REL#"$CWD"/}"
fi

case "$REL" in
  .claude/hooks/*.sh) ;;
  *) exit 0 ;;
esac

# Reject nested paths (e.g. .claude/hooks/tests/x.sh) — measure 1 covers the
# hook scripts directly consumed by settings.json, not their test corpus.
TAIL="${REL#.claude/hooks/}"
case "$TAIL" in
  */*) exit 0 ;;
esac

TARGET="$FILE_PATH"
[ -e "$TARGET" ] || TARGET="$CWD/$REL"
[ -f "$TARGET" ] || exit 0

# Portable timeout: gtimeout (homebrew coreutils) > timeout (GNU) > perl
# alarm fallback — same three-tier strategy as rule-engine.sh _safe_timeout()
# in this repo (already covers this exact "no `timeout` on stock macOS" gap —
# issue #754), reimplemented locally (not sourced) so this checker stays a
# single self-contained file. Note: unlike gtimeout/timeout, the perl branch
# has no equivalent of their exit code 124 on timeout — a killed child exits
# via its default SIGALRM disposition (128+14=142); both are checked below.
_safe_timeout() {
  local t="$1"; shift
  if command -v gtimeout &>/dev/null; then
    gtimeout "$t" "$@"
  elif command -v timeout &>/dev/null; then
    timeout "$t" "$@"
  else
    perl -e 'alarm shift; exec @ARGV' -- "$t" "$@"
  fi
}

SYNTAX_ERR=$(bash -n -- "$TARGET" 2>&1) && SYNTAX_OK=1 || SYNTAX_OK=0

if [ "$SYNTAX_OK" != "1" ]; then
  printf '[hook-selfcheck] FAIL (syntax): %s\n%s\n' "$REL" "$SYNTAX_ERR"
  exit 0
fi

# Grep for the literal flag is a heuristic, not proof the file actually
# implements --self-test (it would also match a comment mentioning the
# flag) — named as such in the report, not claimed as detection.
if grep -q -- '--self-test' "$TARGET" 2>/dev/null; then
  SELF_TEST_OUT=$(_safe_timeout 15 bash "$TARGET" --self-test 2>&1)
  SELF_TEST_RC=$?
  if [ "$SELF_TEST_RC" -eq 0 ]; then
    printf '[hook-selfcheck] OK: %s — syntax valid, self-test PASS\n' "$REL"
  elif [ "$SELF_TEST_RC" -eq 124 ] || [ "$SELF_TEST_RC" -eq 142 ]; then
    printf '[hook-selfcheck] TIMEOUT: %s — syntax valid, self-test did not finish in 15s\n' "$REL"
  else
    printf '[hook-selfcheck] FAIL (self-test): %s\n%s\n' "$REL" "$SELF_TEST_OUT"
  fi
else
  printf '[hook-selfcheck] OK: %s — syntax valid, no --self-test found (heuristic: no literal match)\n' "$REL"
fi

exit 0
