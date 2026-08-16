#!/bin/bash
# Witness Write Guard (PreToolUse, WP-484 Ф56, 2026-08-05)
#
# Problem (cold review, live PoC reproduced): without this hook the closing
# agent could write a forged line directly into the witness file
# (.iwe-runtime/pilot-witness/*.jsonl) or into the session mapping
# (.iwe-runtime/quick-close-harness-session/*.session_id) via plain Bash/Write —
# defeating the whole point of this phase (the agent must not be able to plant
# words that later get shown to the pilot as their "recorded answer"). Same
# class of gate as close-runner-gate.sh already applies to a direct git commit
# bypassing the runner.
#
# Deny-closed on path mention, not on a read/write classification: the closing
# agent has zero legitimate reason to reference these paths directly in its own
# Bash/Write calls at all (render/append/release read/write them themselves, as
# subprocesses of process-runner.py — PreToolUse never sees that, it's a
# separate process tree). So there's no need to enumerate write verbs
# (tee/cp/sed -i/python open() etc.) — the mere mention of the path from the
# agent's top-level Bash call is already an anomaly.
#
# NOT cryptographic protection (design point 5, WP-484.md §Ф56): same boundary
# close-runner-gate.sh already accepts for a direct git commit — a reflex
# against casual/rationalizing bypass, not a guarantee against a deliberately
# malicious agent. There is no privilege boundary between this hook and the
# agent's Bash tool (same unix user) — full imperviousness is technically
# impossible on this architecture, not worth debating here.
#
# Known uncovered paths (2nd cold review 2026-08-05, live-confirmed, NOT closed
# by this version on purpose — same principle close-runner-gate.sh already
# states: "patching the regex for every variant is an arms race, not a fix"):
#   - variable indirection (`D=.iwe-runtime/pilot-witness; echo x >> "$D/y"`)
#   - a symlink alias to the protected directory under an unprotected path
#   - writing via an interpreter rather than a literal path in the command line
#     (`python3 -c "open('.iwe' + '-runtime/...', 'a')..."`)
# Round 1 found a direct path mention (closed below); round 2 found `cd DIR &&
# <relative command>` without repeating the path (also closed below, via a
# dedicated `cd` branch, since that's the obvious/likely case, not an exotic one).
#
# Protected paths: .iwe-runtime/pilot-witness/**, .iwe-runtime/quick-close-
# harness-session/**, .iwe-runtime/autonomous-run.marker — written ONLY by
# .claude/hooks/pilot-witness-recorder.sh, .claude/hooks/close-runner-gate.sh,
# or a trusted launchd/systemd unit file, never by the closing agent.
#
# PreToolUse contract: stdin JSON {"tool_name","tool_input","session_id",...}.
# Exit 0 = allow; exit 2 = block (stderr shown to the LLM).
set -uo pipefail

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# No mandatory trailing "/" (round 2: `rm -rf .../pilot-witness` without a
# trailing slash on the whole directory used to slip through). A separate
# branch on `cd ... <protected-subdir>` catches the relative-cd bypass:
# `cd .iwe-runtime/pilot-witness && touch x`, where the second half of the
# command has nothing to match unless `cd` itself is inspected separately.
#
# The `cd` branch names the same three protected subpaths as the rest of
# PROTECTED_RE, not the whole `.iwe-runtime` tree (bug-2026-08-16-witness-
# guard-blocks-legitimate-isolated-worktree-cd.md, DS-my-strategy/inbox/bugs):
# a bare `cd[[:space:]]+[^;&|]*\.iwe-runtime` matched ANY `cd` under
# `.iwe-runtime`, including legitimate session-guard --isolate worktrees under
# `.iwe-runtime/isolated-worktrees/` that have nothing to do with witness/
# harness-session/marker. `autonomous-run.marker` is a file, not a directory
# — `cd` into it is not a thing bash does, so it's excluded from the cd branch.
PROTECTED_RE='\.iwe-runtime/pilot-witness|\.iwe-runtime/quick-close-harness-session|\.iwe-runtime/autonomous-run\.marker|cd[[:space:]]+[^;&|]*\.iwe-runtime/(pilot-witness|quick-close-harness-session)'

TARGET=""
case "$TOOL_NAME" in
  Write|Edit|MultiEdit)
    TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    ;;
  Bash)
    TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    ;;
  *)
    exit 0
    ;;
esac
[ -n "$TARGET" ] || exit 0

echo "$TARGET" | grep -qE "$PROTECTED_RE" || exit 0

echo "[witness-write-guard] заблокировано прямое обращение агента к $PROTECTED_RE -- эти файлы пишутся/читаются только .claude/hooks/pilot-witness-recorder.sh, close-runner-gate.sh или доверенным планировщиком, никогда закрывающим агентом напрямую (WP-484 Ф56, session-reflection-append.sh сам читает witness как подпроцесс раннера). Продолжай через process-runner.py next -- witness обрабатывается внутри хендлера." >&2
exit 2
