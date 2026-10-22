#!/usr/bin/env bash
# ritual-hard-gate.sh -- TACT-01 hard pre-action ritual gate, NARROW scope
# (pilot decision 13.10.2026, peer-session
# MC-sessions:2026-10/13/2026-10-13-19-retroactive-ritual-gate, confirmed in
# follow-up chat the same day -- РП-484 Ф182).
#
# Scope: this hook ONLY denies when the pilot has THEMSELVES explicitly
# named a WP (РП-NNN / WP-NNN) somewhere in this session's user messages.
# That is a zero-ambiguity signal -- which WP it is is no longer a judgment
# call -- so a synchronous deny is safe here without first building the
# allowlist a broader hard block would need for the legitimate pre-ritual
# bookkeeping steps protocol-open.md §Сессия itself prescribes (reading
# WP-REGISTRY, session-guard.sh open, declare-intent.sh, Sync Gate). When
# the pilot does NOT name a WP, this hook stays silent -- ritual-pre-gate.sh
# (same PreToolUse point, warn-only) is the only thing watching that case
# until a broader hard gate is designed with that allowlist.
#
# Why PreToolUse and not UserPromptSubmit: verified same day
# (claude-code-guide agent, two rounds) that a UserPromptSubmit block
# rejects the prompt before the model ever runs -- the assistant gets no
# chance to compose the Ritual text itself, so the pilot would just be
# stuck resubmitting the same blocked message forever. PreToolUse fires
# AFTER the model has already started this turn (so it has had the chance
# to write the Ritual as plain text) and a deny here feeds back into the
# SAME turn (standard tool-denial semantics, same as destructive-guard.sh
# etc.) -- no new human message needed.
#
# Contract (Claude Code PreToolUse hook): stdin JSON {"tool_name",
# "session_id", "transcript_path", ...}. Returns
# {"hookSpecificOutput": {"hookEventName": "PreToolUse",
#  "permissionDecision": "deny", "permissionDecisionReason": "..."}}
# to block, or nothing (exit 0) to allow.

set -uo pipefail
export PATH="/run/current-system/sw/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ -n "$SESSION_ID" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] || exit 0
# session_id feeds a filesystem path below (CONFIRMED_MARKER) -- reject
# anything outside the safe charset before that, not after (path traversal,
# found by peer-session shell-safety-critic 22.10.2026, WP-484).
case "$SESSION_ID" in
  *[!A-Za-z0-9._-]*) exit 0 ;;
esac

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
STATE_DIR="$PROJECT_DIR/.claude/state"
# ritual-confirmed-<session_id>: same OWN marker as ritual-pre-gate.sh (see
# that file's comment -- NOT ritual-shown-detector.sh's ritual-checked-*,
# which gets written on ANY ritual_status including "absent" and would
# permanently disarm this gate on the first Stop otherwise, cold-review
# 13.10.2026 Critical #1).
CONFIRMED_MARKER="$STATE_DIR/ritual-confirmed-$SESSION_ID"
[ -f "$CONFIRMED_MARKER" ] && exit 0

# shellcheck source=lib/ritual-detect.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ritual-detect.sh"

NAMES_WP=$(ritual_prompt_names_wp "$TRANSCRIPT_PATH")
[ "$NAMES_WP" = "yes" ] || exit 0

ALREADY_SHOWN=$(ritual_block_present_now "$TRANSCRIPT_PATH")
if [ "$ALREADY_SHOWN" = "yes" ]; then
  mkdir -p "$STATE_DIR"
  : > "$CONFIRMED_MARKER"
  exit 0
fi
# Fail OPEN on "error" (transcript unreadable / unexpected exception) --
# only an explicit "no" denies. Folding "error" into "no" here would make
# a transient parse failure synchronously deny a legitimate tool call
# (cold-review 13.10.2026 Critical #2).
[ "$ALREADY_SHOWN" = "no" ] || exit 0

cat <<EOF
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "WP Gate: ты назвал номер РП в этой сессии, но Ритуал согласования (роль/РП/класс/ставка — memory/protocol-open.md §Сессия) ещё не объявлен. Покажи Ритуал СЕЙЧАС, текстом, до вызова инструмента $TOOL_NAME, затем дождись согласования пилота."}}
EOF
exit 0
