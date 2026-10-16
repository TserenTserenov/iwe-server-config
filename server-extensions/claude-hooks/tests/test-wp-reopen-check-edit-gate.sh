#!/usr/bin/env bash
# test-wp-reopen-check-edit-gate.sh — smoke test for wp-reopen-check-edit-gate.sh
# (WP-530 Ф97: wire wp-reopen-gate.sh check-edit into the real write boundary).
#
# Throwaway sandbox repo only -- never touches a real governance repo or card.
# Reuses the bare-origin + clone fixture from wp-reopen-gate-smoke.sh.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$HOOK_DIR/wp-reopen-check-edit-gate.sh"
GATE="$HOOK_DIR/../../scripts/wp-reopen-gate.sh"
[ -x "$HOOK" ] || { echo "FAIL: хук не найден: $HOOK"; exit 1; }
[ -x "$GATE" ] || { echo "FAIL: wp-reopen-gate.sh не найден: $GATE"; exit 1; }

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

BARE="$SANDBOX/origin.git"
REPO="$SANDBOX/gov-repo"
git init -q --bare "$BARE"
git clone -q "$BARE" "$REPO"
# wp-reopen-gate.sh defaults to branch "main" -- force it regardless of this
# host's git init.defaultBranch (no commit exists yet, so this is safe).
git -C "$REPO" symbolic-ref HEAD refs/heads/main
mkdir -p "$REPO/inbox/WP-999" "$REPO/docs"
echo "revision 1" > "$REPO/inbox/WP-999/WP-999.md"
echo "not a card" > "$REPO/docs/notes.md"
git -C "$REPO" add inbox/WP-999/WP-999.md docs/notes.md
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "r1"
git -C "$REPO" push -q origin main

export IWE_ROOT="$SANDBOX"
export WP_REOPEN_GATE_BIN="$GATE"
export CLAUDE_CODE_SESSION_ID="test-session-1"
# Sandboxed, not the real ~/.claude/state -- the hook must never pollute (or
# read stale state from) the real cache directory while under test.
export WP_REOPEN_CHECK_EDIT_CACHE_DIR="$SANDBOX/cache"
unset WP_REOPEN_CHECK_EDIT_MODE

json_input() {  # tool_name file_path session_id
  python3 -c 'import json,sys; print(json.dumps({"tool_name": sys.argv[1], "tool_input": {"file_path": sys.argv[2]}, "session_id": sys.argv[3]}))' \
    "$1" "$2" "$3"
}

run_hook() {  # tool_name file_path [session_id]
  json_input "$1" "$2" "${3:-$CLAUDE_CODE_SESSION_ID}" | "$HOOK"
}

# 1. Non-matching tool_name (Read) is a no-op regardless of lease state.
out=$(run_hook "Read" "$REPO/inbox/WP-999/WP-999.md" 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "Read должен быть no-op (exit 0), вернул $rc: $out"
[ -z "$out" ] || fail "Read не должен писать никаких сообщений: $out"
[ "$rc" -eq 0 ] && [ -z "$out" ] && pass "tool_name=Read -> no-op"

# 2. Edit on a non-card path is a no-op.
out=$(run_hook "Edit" "$REPO/docs/notes.md" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  && pass "правка не-карточки РП -> no-op" \
  || fail "правка docs/notes.md должна быть no-op, получено rc=$rc out=$out"

# 3. Write on a not-yet-existing card is a no-op (nothing to actualize).
out=$(run_hook "Write" "$REPO/inbox/WP-998/WP-998.md" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  && pass "создание новой (не существующей) карточки -> no-op" \
  || fail "создание новой карточки WP-998 должно быть no-op, получено rc=$rc out=$out"

# 4. Existing card, no lease taken, default mode (telemetry): warn, still allow.
out=$(run_hook "Edit" "$REPO/inbox/WP-999/WP-999.md" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "РП-999" && printf '%s' "$out" | grep -qi "telemetry"; then
  pass "карточка без лицензии, режим telemetry -> allow + предупреждение"
else
  fail "ожидался exit 0 с предупреждением про РП-999 в режиме telemetry, получено rc=$rc out=$out"
fi

# 5. Same, but mode=enforce: must actually block.
out=$(WP_REOPEN_CHECK_EDIT_MODE=enforce run_hook "Edit" "$REPO/inbox/WP-999/WP-999.md" 2>&1)
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "заблокирована"; then
  pass "карточка без лицензии, режим enforce -> block (exit 2)"
else
  fail "ожидался exit 2 с текстом блокировки в режиме enforce, получено rc=$rc out=$out"
fi

# 6. actualize for this exact session, then the SAME check must pass silently
#    (enforce mode -- strongest claim: no warning text at all once actualized).
(cd "$REPO" && "$GATE" actualize --wp 999 --governance-repo "$REPO" --session-id "$CLAUDE_CODE_SESSION_ID" >/dev/null)
out=$(WP_REOPEN_CHECK_EDIT_MODE=enforce run_hook "Edit" "$REPO/inbox/WP-999/WP-999.md" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  pass "после actualize той же сессией -> allow без предупреждений, даже в enforce"
else
  fail "после actualize ожидался чистый exit 0, получено rc=$rc out=$out"
fi

# 7. A DIFFERENT session (no lease of its own) is still blocked in enforce mode,
#    even though some other session's lease for the same card exists.
out=$(WP_REOPEN_CHECK_EDIT_MODE=enforce run_hook "Edit" "$REPO/inbox/WP-999/WP-999.md" "test-session-2" 2>&1)
rc=$?
if [ "$rc" -eq 2 ]; then
  pass "чужая сессия без своей лицензии -> block (exit 2) даже когда карточка уже актуализирована кем-то другим"
else
  fail "ожидался exit 2 для чужой сессии, получено rc=$rc out=$out"
fi

# 8. Gate binary missing: enforce mode must block, not fall through silently
#    (the Critical cold-review finding was exactly this kind of silent-allow
#    path for a DIFFERENT precondition failure -- this covers the sibling
#    branch that was already coded correctly, but untested).
out=$(WP_REOPEN_CHECK_EDIT_MODE=enforce WP_REOPEN_GATE_BIN="$SANDBOX/no-such-gate" \
  run_hook "Edit" "$REPO/inbox/WP-999/WP-999.md" "test-session-missing-gate" 2>&1)
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "не найден"; then
  pass "инструмент wp-reopen-gate.sh недоступен, режим enforce -> block"
else
  fail "ожидался exit 2 с упоминанием 'не найден', получено rc=$rc out=$out"
fi

# 9. Same, but telemetry mode: warn, still allow.
out=$(WP_REOPEN_GATE_BIN="$SANDBOX/no-such-gate" \
  run_hook "Edit" "$REPO/inbox/WP-999/WP-999.md" "test-session-missing-gate-2" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "не найден"; then
  pass "инструмент wp-reopen-gate.sh недоступен, режим telemetry -> allow + предупреждение"
else
  fail "ожидался exit 0 с упоминанием 'не найден', получено rc=$rc out=$out"
fi

# 10. Mode marker file (not the env var) selects enforce. Run a COPY of the
#     hook from an isolated directory so this never writes next to the real,
#     shipped hook.
HOOK_COPY_DIR="$SANDBOX/hook-copy"
mkdir -p "$HOOK_COPY_DIR"
cp "$HOOK" "$HOOK_COPY_DIR/wp-reopen-check-edit-gate.sh"
echo "enforce" > "$HOOK_COPY_DIR/wp-reopen-check-edit-mode"
out=$(json_input "Edit" "$REPO/inbox/WP-999/WP-999.md" "test-session-marker" \
  | env -u WP_REOPEN_CHECK_EDIT_MODE "$HOOK_COPY_DIR/wp-reopen-check-edit-gate.sh" 2>&1)
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "заблокирована"; then
  pass "файл-маркер режима (enforce) рядом с хуком применяется без env-переменной"
else
  fail "ожидался exit 2 по файлу-маркеру enforce, получено rc=$rc out=$out"
fi

# 11. MultiEdit is treated the same as Edit (both are in-place edits of an
#     existing file -- only Write can target a not-yet-existing path).
out=$(run_hook "MultiEdit" "$REPO/inbox/WP-999/WP-999.md" "test-session-multiedit" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "РП-999"; then
  pass "tool_name=MultiEdit обрабатывается так же, как Edit"
else
  fail "ожидался exit 0 с предупреждением про РП-999 для MultiEdit, получено rc=$rc out=$out"
fi

# 12. Debounce: a second check within CACHE_TTL_SECONDS for the SAME
#     (session, WP) must not call wp-reopen-gate.sh again. Proven with a
#     counting shim in front of the real gate, not by timing the real one.
COUNT_FILE="$SANDBOX/gate-call-count"
: > "$COUNT_FILE"
COUNTING_SHIM="$SANDBOX/counting-gate.sh"
cat > "$COUNTING_SHIM" <<SHIM
#!/usr/bin/env bash
echo x >> "$COUNT_FILE"
exec "$GATE" "\$@"
SHIM
chmod +x "$COUNTING_SHIM"
(cd "$REPO" && "$GATE" actualize --wp 999 --governance-repo "$REPO" --session-id "test-session-debounce" >/dev/null)
WP_REOPEN_GATE_BIN="$COUNTING_SHIM" run_hook "Edit" "$REPO/inbox/WP-999/WP-999.md" "test-session-debounce" >/dev/null 2>&1
FIRST_COUNT=$(wc -l < "$COUNT_FILE")
WP_REOPEN_GATE_BIN="$COUNTING_SHIM" run_hook "Edit" "$REPO/inbox/WP-999/WP-999.md" "test-session-debounce" >/dev/null 2>&1
SECOND_COUNT=$(wc -l < "$COUNT_FILE")
if [ "$FIRST_COUNT" -eq 1 ] && [ "$SECOND_COUNT" -eq 1 ]; then
  pass "повторная правка той же карточки той же сессией в пределах окна кэша не вызывает gate повторно"
else
  fail "ожидался ровно 1 вызов gate после первого и второго обращения (кэш), получено first=$FIRST_COUNT second=$SECOND_COUNT"
fi

echo ""
echo "Итог: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
