#!/bin/bash
# Session Open Gate (PreToolUse, WP-561, 16.10.2026)
#
# Проблема, которую решает: session-guard.sh's own header claims "mechanical
# enforcement: git pre-commit hook checks for an active semaphore" — but the
# live .git/hooks/pre-commit only runs syntax checks, never session-guard.sh.
# A short/trivial session (explicitly exempt from the full WP Gate Ritual per
# CLAUDE.md §2.1 — "тривиальный вопрос, исправление ≤15 мин") can escalate
# into an actual file edit and `git commit` with zero open semaphore at all:
# found live 16.10.2026, a question-only session committed+pushed a CLAUDE.md
# edit directly to the frozen canonical checkout with no session-guard.sh open
# anywhere in its lifetime — Quick Close then had nothing to close.
#
# What this gate does: the same proven git-commit detection this repo already
# uses (close-runner-gate.sh) — but checks for ANY open semaphore carrying this
# session's harness_session_id, not a runner-start marker. Missing → block,
# point at session-guard.sh open (--housekeeping for an unrelated fix, --wp for
# real RP work); session-guard.sh's own freeze guard then tells the agent to
# use an isolated worktree, this gate does not re-implement that logic.
#
# What this gate does NOT do: it does not require the semaphore to live in the
# repo being committed to — the semaphore directory is session-scoped, not
# repo-scoped, matching the rest of this hook family. It does not block
# `git commit` run as a subprocess of another tool (process-runner.py etc.) —
# PreToolUse only observes the top-level Bash tool call, same limitation
# close-runner-gate.sh documents for the same reason.
#
# Контракт PreToolUse hook (Claude Code):
# - Stdin: JSON {"tool_name", "tool_input", "session_id", ...}
# - Exit 0 = allow; exit 2 = block (stderr = причина, показывается LLM).

set -uo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$COMMAND" ] || exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# Same fallback as close-runner-gate.sh (bug-2026-08-31): payload .session_id
# has come back empty while CLAUDE_CODE_SESSION_ID was present and correct.
if [ -z "$SESSION_ID" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  SESSION_ID="$CLAUDE_CODE_SESSION_ID"
fi
[ -n "$SESSION_ID" ] || exit 0
case "$SESSION_ID" in
  *[!A-Za-z0-9._-]*) exit 0 ;;
esac
SESSION_ID_SAFE="$SESSION_ID"

# Same hardened git-commit/push detection as close-runner-gate.sh (Ф74а) —
# reused verbatim, not reinvented, to inherit its evasion coverage.
NORMALIZED_COMMAND=$(printf '%s' "$COMMAND" | tr '\n' ';' | tr -s '[:space:]' ' ')
GIT_GLOBAL_FLAGS_RE='(-C [^ ]+|-c [^ ]+|--(git-dir|work-tree|namespace|exec-path)(=[^ ]+| [^ ]+)|--(literal-pathspecs|glob-pathspecs|noglob-pathspecs|icase-pathspecs|no-optional-locks|no-lazy-fetch|no-replace-objects|no-pager|paginate|bare)|-P)'
echo "$NORMALIZED_COMMAND" | grep -qE "(^|[;&|(]) *(([A-Za-z_][A-Za-z0-9_]*=[^ ]+ *)*)(command |builtin |exec )?git( $GIT_GLOBAL_FLAGS_RE)* (commit|push)( |$)" || exit 0

SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
AGENT="${IWE_AGENT:-claude-code}"
# -x (whole-line match), not a bare -F substring search (close-runner-gate.sh
# ПП-74б/31.08 already hit this exact defect: a shorter session_id that is a
# prefix of a longer one would otherwise match it as a substring).
SEM_MATCHES=$(grep -lxF "harness_session_id: $SESSION_ID" "$SESSION_DIR/${AGENT}"-*.open 2>/dev/null)
[ -n "$SEM_MATCHES" ] && exit 0

echo "[session-open-gate] session=$SESSION_ID_SAFE no open semaphore (${SESSION_DIR}/${AGENT}-*.open carrying harness_session_id: $SESSION_ID) — blocking direct git commit/push" >&2

cat >&2 <<EOF
🚫 Session Open Gate (WP-561): прямой git commit/push без открытой сессии заблокирован.

Эта сессия ни разу не вызывала session-guard.sh open — session-guard.sh сам
заявляет, что коммит без него не должен проходить, но реальный pre-commit хук
это не проверял (найдено 16.10.2026). Теперь проверяет этот хук.

Если правка не про конкретный РП:
  bash scripts/session-guard.sh open --housekeeping "<короткая причина>" --agent claude-code

Если правка про конкретный РП (или вырастает в него):
  bash scripts/session-guard.sh open --wp WP-N --task "..." --agent claude-code

Канонический чекаут может быть заморожен (WP-520/WP-484) — session-guard.sh в
этом случае сам укажет, как перейти в изолированную копию (EnterWorktree /
git worktree add); следовать этой инструкции, не обходить её другим путём.
EOF
exit 2
