#!/bin/bash
# test-wp-card-license-gate.sh -- wp-card-license-gate.sh (PreToolUse,
# WP-484 Ф210, 17.10.2026, пир-сессия Kimi+Codex+Grok).
# Денит Edit/Write/MultiEdit inbox/WP-NNN/WP-NNN.md из isolated-сессии, когда
# wp-reopen-gate check-edit не дал editing_allowed. Fail-open: не-карточка,
# не-isolated семафор, неоднозначный/отсутствующий семафор, битый вход.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$HOOK_DIR/wp-card-license-gate.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0
check() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $desc (ожидалось '$want', получено '$got')"; fi
}

# --- sandbox IWE_ROOT ---
ROOT="$TMP_DIR/iwe"
mkdir -p "$ROOT/.iwe-runtime/sessions" "$ROOT/scripts" "$ROOT/DS-my-strategy/inbox/WP-484"
cat > "$ROOT/scripts/wp-reopen-gate.sh" <<GATE
#!/bin/bash
# фейк: editing_allowed только если файл-флаг license_ok существует
[ -f "$TMP_DIR/license_ok" ] || exit 2
GATE
chmod +x "$ROOT/scripts/wp-reopen-gate.sh"

SEM="$ROOT/.iwe-runtime/sessions/claude-code-testf210.open"
cat > "$SEM" <<SEMEOF
---
agent: claude-code
wp: WP-484
session_id: guard-sess-1
harness_session_id: harness-uuid-1
isolated_worktree: $ROOT/DS-my-strategy
governance_worktree: $ROOT/DS-my-strategy
isolated_branch: session-isolate/test
---
SEMEOF

run_hook() {  # run_hook <tool> <file_path> [harness_id]
  local tool="$1" fp="$2" hid="${3:-harness-uuid-1}"
  jq -n --arg t "$tool" --arg f "$fp" --arg s "$hid" \
    '{tool_name:$t, session_id:$s, tool_input:{file_path:$f}}' \
    | IWE_ROOT="$ROOT" HARNESS_SESSION_ID="$hid" bash "$HOOK" 2>/dev/null
}

CARD="$ROOT/DS-my-strategy/inbox/WP-484/WP-484.md"
NOTCARD="$ROOT/DS-my-strategy/scripts/foo.sh"

# 1. лицензия есть -> пустой вывод (разрешено)
touch "$TMP_DIR/license_ok"
OUT=$(run_hook Edit "$CARD")
check "license ok: разрешено" "" "$OUT"

# 2. лицензии нет (check-edit exit 2) -> deny
rm -f "$TMP_DIR/license_ok"
OUT=$(run_hook Edit "$CARD")
DECISION=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)
check "license missing: deny" "deny" "$DECISION"
REASON=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
case "$REASON" in
  *"actualize"*) check "deny reason указывает actualize" "yes" "yes" ;;
  *) check "deny reason указывает actualize" "yes" "no: $REASON" ;;
esac

# 3. Write и MultiEdit тоже денятся
OUT=$(run_hook Write "$CARD")
check "Write: deny" "deny" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)"
OUT=$(run_hook MultiEdit "$CARD")
check "MultiEdit: deny" "deny" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)"

# 4. не карточка inbox -> fail-open
OUT=$(run_hook Edit "$NOTCARD")
check "не карточка: разрешено" "" "$OUT"

# 5. другой инструмент -> fail-open
OUT=$(run_hook Bash "$CARD")
check "Bash: разрешено" "" "$OUT"

# 6. чужой harness id (нет семафора) -> fail-open
OUT=$(run_hook Edit "$CARD" "harness-uuid-OTHER")
check "чужая сессия: разрешено" "" "$OUT"

# 7. семафор без isolated_worktree -> fail-open
sed '/^isolated_worktree:/d' "$SEM" > "$SEM.noiso" && mv "$SEM.noiso" "$SEM"
OUT=$(run_hook Edit "$CARD")
check "не-isolated семафор: разрешено" "" "$OUT"

# 8. битый вход -> exit 0, пустой вывод
OUT=$(printf 'not-json' | IWE_ROOT="$ROOT" bash "$HOOK" 2>/dev/null; echo "rc=$?")
check "битый вход: fail-open rc=0" "rc=0" "$(printf '%s' "$OUT" | tail -1)"

# 9. карточка в пути с префиксом (другой worktree) тоже матчится
# (семафор возвращаем в isolated-состояние — кейс 7 его лишил флага)
cat > "$SEM" <<SEMEOF
---
agent: claude-code
wp: WP-484
session_id: guard-sess-1
harness_session_id: harness-uuid-1
isolated_worktree: $ROOT/DS-my-strategy
governance_worktree: $ROOT/DS-my-strategy
isolated_branch: session-isolate/test
---
SEMEOF
OUT=$(run_hook Edit "/some/prefix/inbox/WP-99/WP-99.md")
# WP-99 семафору не назначен, лицензии нет -> deny (семафор тот же, WP любой)
check "карточка WP-99 без лицензии: deny" "deny" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)"

echo ""
echo "wp-card-license-gate: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
