#!/bin/bash
# style-hint-for-agent.sh — the Claude style hook for other agents (WP-7 F309).
#
# Claude gets the communication style every turn from inject-communication-style.sh
# (UserPromptSubmit). Codex and Kimi got only AGENTS.md, so the style rules past
# A12/A14 never reached them. This wrapper runs the same hook for them:
#   --format json   Codex: same hookSpecificOutput.additionalContext JSON as Claude
#   --format plain  Kimi: plain stdout (Kimi adds non-empty stdout of a
#                   UserPromptSubmit hook to the context)
# The transcript-based next-turn hint reads Claude transcripts only, so it is off.
# Fail-open: any error prints nothing extra and exits 0 (never blocks a prompt).
set -uo pipefail

FORMAT="json"
[ "${1:-}" = "--format" ] && FORMAT="${2:-json}"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$HOOK_DIR/../.." && pwd)}"
export IWE_STYLE_NEXT_TURN_HINT=0

OUT=$(bash "$HOOK_DIR/inject-communication-style.sh" 2>/dev/null) || OUT='{}'
case "$FORMAT" in
  plain) printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true ;;
  *)     [ -n "$OUT" ] || OUT='{}'; printf '%s\n' "$OUT" ;;
esac
exit 0
