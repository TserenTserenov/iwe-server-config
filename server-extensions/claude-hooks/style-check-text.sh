#!/usr/bin/env bash
# claude-hook: false — standalone wrapper called directly by peer adapter
# scripts (not a settings.json hook event); see check-orphan-hooks.sh.
# style-check-text.sh <agent> <text-file> — thin wrapper feeding one agent's
# reply text through the shared response-clarity-hook.sh core (РП-388 Ф17).
#
# One core, two wrappers: Kimi and Codex route through this instead of a
# separate per-agent reimplementation (the dead style-check-post-run.sh had
# its own log file and its own rule numbering — agregator couldn't see it).
#
# Builds a synthetic two-row JSONL transcript (same shape run_case() in
# tests/test-response-clarity-hook.sh already builds) and feeds it to the
# hook on stdin with STYLE_AGENT set, so the shared log carries the right
# agent column.
#
# Optional third argument <context>: "peer" for a peer's turn in a peer
# session (addressed to the writer, not the pilot), "direct" (default) for a
# reply to the pilot. Exported as STYLE_CONTEXT; a12-next-block.py skips the
# pilot-chat "Дальше:" profile for "peer" (РП-605 Ф2).
#
# Always exits 0 — this is a style nudge, never a gate.

set -uo pipefail

AGENT_NAME="${1:-}"
TEXT_FILE="${2:-}"
CONTEXT="${3:-${IWE_STYLE_CONTEXT:-direct}}"

if [ -z "$AGENT_NAME" ] || [ -z "$TEXT_FILE" ] || [ ! -f "$TEXT_FILE" ]; then
  exit 0
fi

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOKS_DIR/response-clarity-hook.sh"

TMP_TRANSCRIPT=$(mktemp)
trap 'rm -f "$TMP_TRANSCRIPT"' EXIT

TEXT_FILE="$TEXT_FILE" python3 - "$TMP_TRANSCRIPT" <<'PY' 2>/dev/null || true
import json, os, sys
path = sys.argv[1]
with open(os.environ["TEXT_FILE"], encoding="utf-8") as f:
    reply = f.read()
rows = [
    {"type": "user", "message": {"content": [{"type": "text", "text": "ход напарника"}]}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": reply}]}},
]
with open(path, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PY

if [ "${STYLE_WRAPPER_EMIT:-0}" = "1" ] && [ "$CONTEXT" = "peer" ]; then
  # Peer-session run (WP-388 Ф24): the reply is read by an adapter, not the pilot,
  # so the agent's own end-of-reply hook neither blocks nor logs; the adapter runs
  # the log-only check once after the run (a second log row here would double-count).
  echo '{}'
  exit 0
fi

if [ "${STYLE_WRAPPER_EMIT:-0}" = "1" ]; then
  # Return mode (РП-388 Ф21): the caller is an agent's own end-of-reply hook and
  # forwards the block decision back to the agent so it rewrites the reply. The
  # blocking switch is turned on here, once, for every non-Claude agent; peer
  # adapters (no EMIT) stay log-only. The core prints {} when nothing blocks.
  printf '{"transcript_path":"%s","session_id":"style-check-%s"}' "$TMP_TRANSCRIPT" "$AGENT_NAME" \
    | STYLE_AGENT="$AGENT_NAME" STYLE_CONTEXT="$CONTEXT" STYLE_ENFORCE_BLOCK=1 STYLE_BLOCK_A14=1 \
      bash "$HOOK" 2>/dev/null || true
  exit 0
fi

printf '{"transcript_path":"%s","session_id":"style-check-%s"}' "$TMP_TRANSCRIPT" "$AGENT_NAME" \
  | STYLE_AGENT="$AGENT_NAME" STYLE_CONTEXT="$CONTEXT" bash "$HOOK" >/dev/null 2>&1 || true

exit 0
