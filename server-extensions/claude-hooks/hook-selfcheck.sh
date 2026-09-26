#!/bin/bash
# hook-selfcheck.sh — PostToolUse (matcher: Edit|Write|MultiEdit), WP-544 Ф12 measure 1.
#
# Mechanizes a rule that kept failing as a manual step (lessons_secret_bypass_
# lib_apostrophe_total_lockout.md): check shell syntax and self-tests after
# edits to .claude/hooks/*.sh. The extracted secret_patterns.py corpus also
# needs a syntax check and its owning shell library's self-test.
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
  .claude/hooks/*.sh|.claude/hooks/secret_patterns.py) ;;
  *) exit 0 ;;
esac

# Reject nested paths (e.g. .claude/hooks/tests/x.sh) — measure 1 covers the
# hook scripts directly consumed by settings.json, not their test corpus.
TAIL="${REL#.claude/hooks/}"
case "$TAIL" in
  */*) exit 0 ;;
esac

TARGET="$FILE_PATH"
case "$FILE_PATH" in
  /*) ;;
  *) [ -z "$CWD" ] || TARGET="$CWD/$REL" ;;
esac
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

SELF_TEST_TARGET="$TARGET"
SYNTAX_RC=0
if [ "$REL" = ".claude/hooks/secret_patterns.py" ]; then
  # Compile bytes without executing the module or writing __pycache__.
  # Do not echo a failing source line: the checker handles a secret guard.
  SYNTAX_ERR=$(_safe_timeout 15 python3 -I -B - "$TARGET" 2>&1 <<'PY'
import pathlib
import sys
import warnings

try:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        compile(pathlib.Path(sys.argv[1]).read_bytes(), sys.argv[1], "exec")
except (SyntaxError, ValueError, OSError) as exc:
    print(f"{type(exc).__name__} at line {getattr(exc, 'lineno', None) or '?'}")
    sys.exit(1)
PY
  ) || SYNTAX_RC=$?
  SELF_TEST_TARGET="$(dirname "$TARGET")/secret-bypass-lib.sh"
else
  SYNTAX_ERR=$(bash -n -- "$TARGET" 2>&1) || SYNTAX_RC=$?
fi

if [ "$SYNTAX_RC" -eq 124 ] || [ "$SYNTAX_RC" -eq 142 ]; then
  printf '[hook-selfcheck] TIMEOUT: %s — syntax check did not finish in 15s\n' "$REL"
  exit 0
fi

if [ "$SYNTAX_RC" -ne 0 ]; then
  printf '[hook-selfcheck] FAIL (syntax): %s\n%s\n' "$REL" "$SYNTAX_ERR"
  exit 0
fi

# Use the owning library's self-test to exercise its link to the extracted
# corpus as well as the corpus itself before reporting success.
if [ "$REL" = ".claude/hooks/secret_patterns.py" ] && \
   { [ ! -r "$SELF_TEST_TARGET" ] || ! grep -q -- '--self-test' "$SELF_TEST_TARGET"; }; then
  printf '[hook-selfcheck] FAIL (self-test): %s — owning library self-test unavailable\n' "$REL"
  exit 0
fi

# Grep for the literal flag is a heuristic, not proof the file actually
# implements --self-test (it would also match a comment mentioning the
# flag) — named as such in the report, not claimed as detection.
if grep -q -- '--self-test' "$SELF_TEST_TARGET" 2>/dev/null; then
  SELF_TEST_OUT=$(_safe_timeout 15 bash "$SELF_TEST_TARGET" --self-test 2>&1)
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
