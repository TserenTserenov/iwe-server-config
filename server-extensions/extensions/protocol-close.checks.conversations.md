#!/bin/bash
# protocol-close.checks.conversations.md — WARN gate for unfinished conversational sessions (DP.SC.154)
#
# Purpose: Detect sessions/conversations/*/meta.yaml with status: started and no report.md.
# Implements DP.SC.154 Q8: WARN not BLOCK. User can --finalize or --interrupt.
#
# Spec: DP.SC.154 §Инварианты, Q8 Close-гейт.

set -eu

IWE_WORKSPACE="${IWE_WORKSPACE:-${WORKSPACE_DIR:-$HOME/IWE}}"
CONV_DIR="$IWE_WORKSPACE/DS-my-strategy/sessions/conversations"
SCRIPTS_DIR="$IWE_WORKSPACE/DS-my-strategy/scripts"

[ -d "$CONV_DIR" ] || exit 0

STALE=()
for meta in "$CONV_DIR"/*/meta.yaml; do
    [ -f "$meta" ] || continue
    status=$(grep "^status:" "$meta" 2>/dev/null | sed 's/^status: *//; s/"//g' | tr -d "'")
    [ "$status" = "started" ] || continue
    session_dir="$(dirname "$meta")"
    [ -f "${session_dir}/report.md" ] && continue
    STALE+=("$(basename "$session_dir")")
done

if [ ${#STALE[@]} -gt 0 ]; then
    echo ""
    echo "⚠️  Незавершённые диалоговые сессии (нет report.md):"
    echo ""
    for s in "${STALE[@]}"; do
        echo "   $s"
        echo "   → bash $SCRIPTS_DIR/peer-session-finalize.sh --finalize $s"
        echo "   → bash $SCRIPTS_DIR/peer-session-finalize.sh --interrupt $s"
    done
    echo ""
    echo "Действие: завершить сессию (--finalize) или прервать (--interrupt) до Close."
    echo "Это WARN, не BLOCK. Close можно продолжить — сессии останутся в статусе started."
    echo ""
fi

exit 0
