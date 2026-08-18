#!/bin/bash
# Pilot Witness Recorder (UserPromptSubmit, WP-484 Ф56, 2026-08-05)
#
# Problem this solves: the Quick Close session-reflection step used to accept
# `answer` from the closing agent's --input with no check on who actually wrote
# it -- judge and offender were the same party (3 recurrences in one day, MAJOR
# fault). This hook records every genuine pilot chat message to a dedicated
# witness file; the session-reflection-append.sh handler sources the answer
# ONLY from here -- the agent's own input never reaches `answer` at all
# (WP-484.md §Ф56, consensus with Codex+Kimi 2026-08-05).
#
# Passive recorder: NEVER blocks pilot input (always exits 0) -- the integrity
# guarantee lives in the append handler's fail-closed behavior (empty witness
# with no trusted autonomous marker => Close blocks), not in this hook.
#
# UserPromptSubmit contract (Claude Code): stdin JSON {"session_id", "prompt", ...}.
set -uo pipefail

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$SESSION_ID" ] || exit 0
SESSION_ID_SAFE=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')
[ -n "$SESSION_ID_SAFE" ] || exit 0

PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
[ -n "$PROMPT" ] || exit 0

# WP-537 (18.08, пир-сессия с Codex): было ${CLAUDE_PROJECT_DIR:-$HOME/IWE} --
# единственное оставшееся место в этой связке hook/handler-скриптов с этим
# паттерном (close_obligation.py, session-guard.sh, close-runner-gate.sh уже
# используют IWE_ROOT env var + $HOME/IWE фолбэк с 16.08, Ф42 -- CLAUDE_PROJECT_DIR
# ненадёжна для worktree-изолированных сессий). Пропущено при рассылке Ф42,
# закрываю тем же паттерном.
IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
WITNESS_DIR="$IWE_ROOT/.iwe-runtime/pilot-witness"
mkdir -p "$WITNESS_DIR" 2>/dev/null || exit 0
chmod 700 "$WITNESS_DIR" 2>/dev/null || true

WITNESS_FILE="$WITNESS_DIR/$SESSION_ID_SAFE.jsonl"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq -cn --arg ts "$TS" --arg session_id "$SESSION_ID" --arg text "$PROMPT" \
  '{ts: $ts, session_id: $session_id, text: $text}' >> "$WITNESS_FILE" 2>/dev/null
chmod 600 "$WITNESS_FILE" 2>/dev/null || true

# WP-537 (18.08): временная диагностика (не сам witness -- отдельный,
# не защищённый witness-write-guard.sh лог) на период проверки фикса выше.
# Убрать после нескольких подтверждённых живых closes без witness_unavailable.
DIAG_LOG="$IWE_ROOT/.iwe-runtime/pilot-witness-recorder.diag.log"
printf '%s session_id=%s iwe_root=%s witness_file=%s\n' "$TS" "$SESSION_ID_SAFE" "$IWE_ROOT" "$WITNESS_FILE" >> "$DIAG_LOG" 2>/dev/null || true

exit 0
