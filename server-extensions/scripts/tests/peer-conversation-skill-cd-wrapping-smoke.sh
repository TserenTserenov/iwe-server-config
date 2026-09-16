#!/usr/bin/env bash
# peer-conversation-skill-cd-wrapping-smoke.sh -- WP-484 п.16-continuation
# (16.09, peer session 2026-09-16-13-wp484-close-drift-fix, Claude+Kimi).
#
# `session-guard.sh open`/`open --isolate` resolves the freeze check and the
# `--isolate` clone target from the CALLING PROCESS's cwd, not from a
# `$GOV_REPO_ROOT` variable value (by design, WP-484 Ф104). The peer-conversation
# skill must therefore wrap both `open` invocations in `cd "$GOV_REPO_ROOT" && ...`
# -- without it, a session started from the IWE root silently freeze-checks and
# isolates the wrong repository (found live 14.09, fixed same day, commit
# 3251ebc97f). The fix regressed silently once already: this session found the
# wrapping stripped from the working copy on disk while the fix stayed intact in
# the last commit -- no test caught it because SKILL.md is prose an LLM executes,
# not code a CI runs. This is a static grep, not a behavioral test: it cannot
# prove the LLM will follow the instruction, only that the instruction is present
# to follow.
set -euo pipefail

SKILL_FILE="${IWE_ROOT:-$HOME/IWE}/.claude/skills/peer-conversation/SKILL.md"
[ -f "$SKILL_FILE" ] || { echo "SKIP: не найден $SKILL_FILE"; exit 0; }

FAIL=0

# Step 1.0: the plain `open` call.
if ! grep -qF 'OPEN_OUTPUT=$(cd "$GOV_REPO_ROOT" && IWE_AGENT=claude-code bash' "$SKILL_FILE"; then
  echo "FAIL: 'open' в Шаге 1.0 не обёрнут в cd \"\$GOV_REPO_ROOT\" &&"
  FAIL=1
fi

# Freeze-fallback: the `open --isolate` retry.
if ! grep -qF 'ISOLATE_OUTPUT=$(cd "$GOV_REPO_ROOT" && IWE_AGENT=claude-code bash' "$SKILL_FILE"; then
  echo "FAIL: 'open --isolate' во freeze-fallback не обёрнут в cd \"\$GOV_REPO_ROOT\" &&"
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: оба вызова session-guard.sh open обёрнуты в cd \"\$GOV_REPO_ROOT\" &&"
fi
exit "$FAIL"
