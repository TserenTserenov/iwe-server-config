#!/bin/bash
# intent-binding-shadow-check.sh -- WP-561 dynamic day, IntegrationGate
# consensus 14.10.2026 (peer-session Claude+Kimi+Codex,
# MC-sessions:2026-10/14/2026-10-14-11-wp561-dynamic-day-integrationgate),
# pilot decision: shadow-only rollout (not blocking) until the binding
# producer side exists and the real volume of unbound actions is known.
#
# This is a SEPARATE hook from intent-gate-check.sh (DP.SC.204, warn-only
# WP-declaration freshness) -- that one is not touched. This hook checks a
# DIFFERENT, finer-grained thing: whether the specific action has a binding
# record (scripts/lib/intent_binding.py) linking it to a claimed set of
# paths. It ALWAYS exits 0 -- it only logs what the decision WOULD be, so
# the real question ("if this blocked today, what breaks, and how often")
# gets answered before anyone turns blocking on. No binding producer exists
# yet (that is explicitly an open remainder, not done by this hook) -- every
# mutating call is expected to log NO_BINDING until one is written.

set -uo pipefail
export PATH="/run/current-system/sw/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ -n "$SESSION_ID" ] && [ -n "$TOOL_NAME" ] || exit 0

# Same dead-end avoidance as intent-gate-check.sh: declare-intent.sh itself
# must not get gated by a check that exists to observe OTHER actions.
if [ "$TOOL_NAME" = "Bash" ]; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  case "$COMMAND" in
    *declare-intent.sh*) exit 0 ;;
  esac
fi

IWE_RUNTIME_DIR="${IWE_RUNTIME_DIR:-${HOME:-/nonexistent}/IWE/.iwe-runtime}"
STORE_DIR="$IWE_RUNTIME_DIR/intent-bindings"
LIB_PATH="${HOME:-/nonexistent}/IWE/DS-my-strategy/scripts/lib"
WARN_LOG="$IWE_RUNTIME_DIR/intent-binding-shadow.log"
mkdir -p "$(dirname "$WARN_LOG")" 2>/dev/null || true

# Path/effect classification per the consensus: Write/Edit/MultiEdit/
# NotebookEdit have one known target path and are mutating by definition.
# Bash's effect can't be proven read-only from the command text alone
# (Codex's point in the peer session) -- conservative default: unknown,
# treated as mutate by check_intent() itself, not re-decided here. Read/
# Grep/Glob are not in this hook's matcher at all (see settings.json) --
# they are never gated, not even in shadow mode, so there is nothing to
# log for them.
case "$TOOL_NAME" in
  Write|Edit|MultiEdit|NotebookEdit)
    TOUCHED_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    EFFECT="mutate"
    ;;
  Bash)
    TOUCHED_PATH=""
    EFFECT="unknown"
    ;;
  *)
    exit 0
    ;;
esac

DECISION_JSON=$(IWE_INTENT_STORE_DIR="$STORE_DIR" IWE_INTENT_SESSION_ID="$SESSION_ID" \
  IWE_INTENT_TOUCHED_PATH="$TOUCHED_PATH" IWE_INTENT_EFFECT="$EFFECT" \
  python3 -c "
import json, os, sys
sys.path.insert(0, os.environ.get('LIB_PATH_ENV', ''))
try:
    import intent_binding as ib
except ImportError as exc:
    print(json.dumps({'allow': None, 'reason': f'library not available: {exc}'}))
    sys.exit(0)
from pathlib import Path
store = Path(os.environ['IWE_INTENT_STORE_DIR'])
touched = [os.environ['IWE_INTENT_TOUCHED_PATH']] if os.environ.get('IWE_INTENT_TOUCHED_PATH') else []
decision = ib.check_intent(store, os.environ['IWE_INTENT_SESSION_ID'], 'main', 'shadow-check', touched, os.environ['IWE_INTENT_EFFECT'])
print(json.dumps({'allow': decision.allow, 'reason': decision.reason}))
" LIB_PATH_ENV="$LIB_PATH" 2>/dev/null)

[ -n "$DECISION_JSON" ] || exit 0

ALLOW=$(echo "$DECISION_JSON" | jq -r '.allow' 2>/dev/null)
[ "$ALLOW" = "true" ] && exit 0  # would be allowed -- silent, no log noise

REASON=$(echo "$DECISION_JSON" | jq -r '.reason // "unknown"' 2>/dev/null)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOG_ENTRY=$(jq -nc --arg ts "$TIMESTAMP" --arg sid "$SESSION_ID" --arg tool "$TOOL_NAME" \
  --arg effect "$EFFECT" --arg reason "$REASON" \
  '{ts: $ts, gate: "intent-binding-shadow-check", session_id: $sid, tool_name: $tool, effect: $effect, reason: $reason, mode: "shadow-only", would_block: true}' 2>/dev/null)
[ -n "$LOG_ENTRY" ] && echo "$LOG_ENTRY" >> "$WARN_LOG" 2>/dev/null

exit 0
