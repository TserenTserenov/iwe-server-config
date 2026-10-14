#!/usr/bin/env bash
# ritual-pre-gate.sh -- TACT-01 pre-action ritual gate, WARN-ONLY rollout
# (pilot decision 13.10.2026, peer-session
# MC-sessions:2026-10/13/2026-10-13-19-retroactive-ritual-gate, role
# DP.ROLE.102). Same rollout discipline as intent-gate-check.sh (DP.SC.204):
# this hook NEVER blocks -- it always exits 0, only logging what WOULD have
# blocked. Flip to blocking is a separate, explicit pilot decision.
#
# Why this exists: ritual-shown-detector.sh (Stop hook) used to also block
# -- РП-544 Д31, 13.10.2026 -- but Stop fires only after a turn's work is
# already streamed to the pilot, so its block message always arrived "задним
# числом" (after the fact). That blocking branch was reverted the same day
# (see ritual-shown-detector.sh header) once the diagnosis confirmed Stop
# cannot structurally gate "before work starts".
#
# This hook fires on PreToolUse instead -- before a tool call actually
# touches files/state -- which is the earliest point where "работа" in the
# protocol-open.md sense (ЗАПРЕЩЕНО до проверки: читать код, исследовать,
# планировать) has not yet happened. It reuses the exact same detection
# logic as the Stop-hook observer (lib/ritual-detect.sh) so the two never
# drift apart on what counts as "Ritual shown".
#
# Contract (Claude Code PreToolUse hook):
# - Stdin: JSON {"tool_name", "tool_input", "session_id", "transcript_path", ...}
# - Always exits 0 in warn-only mode.

set -uo pipefail
export PATH="/run/current-system/sw/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ -n "$SESSION_ID" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
STATE_DIR="$PROJECT_DIR/.claude/state"
# ritual-confirmed-<session_id>: OWN marker, written only once THIS hook
# (or ritual-hard-gate.sh, same marker) has itself confirmed the Ritual
# block is present -- deliberately NOT ritual-shown-detector.sh's
# ritual-checked-<session_id> marker. Cold-review (13.10.2026, Critical #1)
# found that marker gets written by the Stop hook as soon as it logs ANY
# ritual_status (including "absent") -- reusing it here would permanently
# disarm this gate on the very first qualifying Stop, even when the Ritual
# was never shown. Cleanup of this marker family lives in
# ritual-shown-detector.sh (same 24h sweep, extended there).
CONFIRMED_MARKER="$STATE_DIR/ritual-confirmed-$SESSION_ID"
[ -f "$CONFIRMED_MARKER" ] && exit 0

# shellcheck source=lib/ritual-detect.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ritual-detect.sh"
RESULT=$(ritual_detect_status "$TRANSCRIPT_PATH")
[ -n "$RESULT" ] || exit 0

APPLIES=$(printf '%s' "$RESULT" | jq -r '.applies // false' 2>/dev/null || echo false)
[ "$APPLIES" = "true" ] || exit 0

RITUAL_STATUS=$(printf '%s' "$RESULT" | jq -r '.ritual_status // empty' 2>/dev/null || echo "")
if [ "$RITUAL_STATUS" != "absent" ] && [ -n "$RITUAL_STATUS" ]; then
  mkdir -p "$STATE_DIR"
  : > "$CONFIRMED_MARKER"
  exit 0
fi
[ "$RITUAL_STATUS" = "absent" ] || exit 0

# Warn-only: log what WOULD have blocked. No ledger write here -- the Stop
# hook already owns ritual_shown/ritual_status in the ledger; duplicating
# the same fact from a second source would create two writers for one
# event (the exact race the peer-session flagged for the real gate).
echo "ritual-pre-gate: WOULD BLOCK tool=$TOOL_NAME session=$SESSION_ID -- Ритуал согласования не найден в стенограмме (warn-only, DP.SC.204 rollout)" >&2
exit 0
