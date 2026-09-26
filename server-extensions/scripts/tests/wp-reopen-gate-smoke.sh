#!/usr/bin/env bash
# Smoke test for wp-reopen-gate.sh (WP-530 F66). Throwaway sandbox repos only --
# never touches a real governance repo or its card.
set -euo pipefail

GATE="$HOME/IWE/scripts/wp-reopen-gate.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

# --- fixture: a bare "origin" and a clone acting as the governance repo ---
BARE="$SANDBOX/origin.git"
REPO="$SANDBOX/gov-repo"
git init -q --bare "$BARE"
git clone -q "$BARE" "$REPO"
mkdir -p "$REPO/inbox/WP-999"
echo "revision 1" > "$REPO/inbox/WP-999/WP-999.md"
git -C "$REPO" add inbox/WP-999/WP-999.md
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "r1"
git -C "$REPO" push -q origin main

# IWE_ROOT, not IWE_RUNTIME -- the latter is a platform-wide agent-runtime
# identifier (see .claude/settings.json), not a path; the gate derives its
# state dir from $IWE_ROOT/.iwe-runtime with no env override, matching
# session-guard.sh's own convention (real-world bug found 2026-09-26: the
# script used to accept an $IWE_RUNTIME path override that collided with
# that identifier in every real Claude Code session).
export IWE_ROOT="$SANDBOX"
IWE_RUNTIME="$SANDBOX/.iwe-runtime"

# 1. check-edit without a lease must refuse (exit 2, self-explaining message).
set +e
out=$(cd "$REPO" && "$GATE" check-edit --wp 999 --governance-repo "$REPO" --session-id s1 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "check-edit без лицензии должен вернуть exit 2, вернул $rc"
echo "$out" | grep -q "актуализирован" || fail "сообщение об отказе не самообъясняющееся: $out"
pass "check-edit без лицензии -> exit 2, самообъясняющееся сообщение"

# 2. actualize, then check-edit for the SAME session must succeed.
(cd "$REPO" && "$GATE" actualize --wp 999 --governance-repo "$REPO" --session-id s1 >/dev/null)
out=$(cd "$REPO" && "$GATE" check-edit --wp 999 --governance-repo "$REPO" --session-id s1)
[ "$out" = "editing_allowed" ] || fail "check-edit после actualize должен вернуть editing_allowed, вернул: $out"
pass "actualize -> check-edit для той же сессии -> editing_allowed"

# 3. check-edit for a DIFFERENT session-id with the same lease must refuse.
set +e
out=$(cd "$REPO" && "$GATE" check-edit --wp 999 --governance-repo "$REPO" --session-id s2 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "check-edit чужой сессией должен вернуть exit 2, вернул $rc"
pass "check-edit чужой сессией с валидной лицензией другой сессии -> exit 2"

# 4. new revision on origin invalidates the old lease (digest-bound, not a bare boolean).
echo "revision 2" > "$REPO/inbox/WP-999/WP-999.md"
git -C "$REPO" add inbox/WP-999/WP-999.md
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "r2"
git -C "$REPO" push -q origin main
set +e
out=$(cd "$REPO" && "$GATE" check-edit --wp 999 --governance-repo "$REPO" --session-id s1 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "check-edit после новой ревизии на origin должен вернуть exit 2, вернул $rc"
echo "$out" | grep -q "изменилась на сервере" || fail "сообщение не называет причину (смена ревизии): $out"
pass "новая ревизия карточки на origin инвалидирует старую лицензию (digest mismatch)"

# 5. re-actualize against the NEW revision restores editing_allowed.
(cd "$REPO" && "$GATE" actualize --wp 999 --governance-repo "$REPO" --session-id s1 >/dev/null)
out=$(cd "$REPO" && "$GATE" check-edit --wp 999 --governance-repo "$REPO" --session-id s1)
[ "$out" = "editing_allowed" ] || fail "повторная actualize должна восстановить editing_allowed, вернула: $out"
pass "повторная actualize после смены ревизии -> editing_allowed"

# 6. an UNRELATED WP's origin change must NOT invalidate this WP's lease
#    (invalidation scope is per-card digest, not repo-wide).
mkdir -p "$REPO/inbox/WP-111"
echo "unrelated" > "$REPO/inbox/WP-111/WP-111.md"
git -C "$REPO" add inbox/WP-111/WP-111.md
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "unrelated WP-111 change"
git -C "$REPO" push -q origin main
out=$(cd "$REPO" && "$GATE" check-edit --wp 999 --governance-repo "$REPO" --session-id s1)
[ "$out" = "editing_allowed" ] || fail "коммит НЕ связанного WP не должен инвалидировать актуализацию этого WP, но check-edit вернул: $out"
pass "коммит несвязанного WP-111 не инвалидирует лицензию WP-999"

# 7. closure-pending-sync: wrong challenge code is rejected.
req_out=$(cd "$REPO" && "$GATE" closure-pending-sync request --wp 999 --reason "test outage" --actor tester 2>&1)
set +e
(cd "$REPO" && "$GATE" closure-pending-sync confirm --wp 999 --challenge-response 000000 >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "closure-pending-sync confirm с неверным кодом должен провалиться"
pass "closure-pending-sync confirm с неверным кодом -> отказ"

# 8. closure-pending-sync: correct challenge code is accepted, then check-edit
#    for a NORMAL edit is blocked (break-glass state, not a bypass of the gate).
code=$(echo "$req_out" | grep -oE '[0-9]{1,6}' | head -1)
[ -n "$code" ] || fail "не удалось извлечь код подтверждения из вывода request: $req_out"
(cd "$REPO" && "$GATE" closure-pending-sync confirm --wp 999 --challenge-response "$code" >/dev/null)
set +e
out=$(cd "$REPO" && "$GATE" check-edit --wp 999 --governance-repo "$REPO" --session-id s1 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "check-edit после closure-pending-sync должен оставаться заблокированным, вернул $rc"
echo "$out" | grep -q "closure_pending_sync" || fail "сообщение не называет состояние closure_pending_sync: $out"
pass "closure-pending-sync с верным кодом -> зафиксирован, обычные правки остаются заблокированы"

[ -f "$IWE_RUNTIME/wp-reopen-leases/closure-pending-sync-audit.jsonl" ] || fail "аудит-файл closure-pending-sync не создан"
grep -q '"wp": "999"' "$IWE_RUNTIME/wp-reopen-leases/closure-pending-sync-audit.jsonl" || fail "аудит-запись не содержит wp=999"
pass "аудит-запись closure-pending-sync создана и содержит wp"

# --- gaps named by cold review (2026-09-26), covered here ---

# 10. check-edit WITHOUT --session-id and without CLAUDE_CODE_SESSION_ID must
#     fail closed (Critical finding #1: it used to silently skip ownership
#     checking whenever identity was unresolved -- Kimi/Codex callers don't
#     set CLAUDE_CODE_SESSION_ID).
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
set +e
out=$(cd "$REPO" && "$GATE" check-edit --wp 999 --governance-repo "$REPO" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "check-edit без session-id (и без CLAUDE_CODE_SESSION_ID) должен провалиться fail-closed, вернул $rc"
pass "check-edit без определённого session_id -> fail-closed, не тихий обход владения"

# 11. status command on a fresh WP with no lease.
out=$(cd "$REPO" && "$GATE" status --wp 222 --governance-repo "$REPO")
echo "$out" | grep -q "actualization_required" || fail "status для WP без лицензии должен назвать actualization_required: $out"
pass "status без лицензии -> actualization_required"

# 12. lease TTL expiry (not just digest mismatch) must block.
mkdir -p "$REPO/inbox/WP-333"
echo "v1" > "$REPO/inbox/WP-333/WP-333.md"
git -C "$REPO" add inbox/WP-333/WP-333.md
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "wp333"
git -C "$REPO" push -q origin main
WP_REOPEN_LEASE_TTL=1 bash -c "cd '$REPO' && '$GATE' actualize --wp 333 --governance-repo '$REPO' --session-id s3 >/dev/null"
sleep 2
set +e
out=$(cd "$REPO" && "$GATE" check-edit --wp 333 --governance-repo "$REPO" --session-id s3 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "check-edit после истечения TTL должен провалиться, вернул $rc"
echo "$out" | grep -q "истекла" || fail "сообщение не называет истечение TTL: $out"
pass "лицензия с истёкшим TTL блокирует check-edit"

# 13. actualize against a NON-default branch, then check-edit must validate
#     against THAT branch (High finding #4: check-edit used to hardcode
#     "main" regardless of what actualize was given).
git -C "$REPO" checkout -q -b feature-branch
echo "feature content" > "$REPO/inbox/WP-333/WP-333.md"
git -C "$REPO" add inbox/WP-333/WP-333.md
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "wp333 on feature branch"
git -C "$REPO" push -q origin feature-branch
git -C "$REPO" checkout -q main
(cd "$REPO" && "$GATE" actualize --wp 333 --governance-repo "$REPO" --session-id s4 --branch feature-branch >/dev/null)
out=$(cd "$REPO" && "$GATE" check-edit --wp 333 --governance-repo "$REPO" --session-id s4)
[ "$out" = "editing_allowed" ] || fail "check-edit должен проверять по ветке, записанной в лицензии (feature-branch), а не по захардкоженному main: $out"
pass "check-edit проверяет по ветке из лицензии (actualize --branch), не по захардкоженному main"

# 14. missing card at origin must fail cleanly (High finding #3: git show's
#     exit status used to be swallowed by pipefail + set -e, aborting with
#     git's raw 128 instead of the documented fallback message).
set +e
out=$(cd "$REPO" && "$GATE" actualize --wp 404 --governance-repo "$REPO" --session-id s5 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "actualize для несуществующей карточки должен вернуть exit 1 (документированный путь), вернул $rc"
echo "$out" | grep -q "актуализация невозможна" || fail "сообщение не объясняет отсутствие карточки: $out"
pass "actualize для несуществующего WP -> чистый exit 1, не сырой git-код 128"

# 15. confirm with no prior request must fail cleanly, not crash.
set +e
out=$(cd "$REPO" && "$GATE" closure-pending-sync confirm --wp 555 --challenge-response 123456 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "confirm без предварительного request должен провалиться"
echo "$out" | grep -q "нет активного запроса" || fail "сообщение не объясняет отсутствие запроса: $out"
pass "confirm без request -> чистый отказ"

# 16. challenge attempt-limit: MAX_CHALLENGE_ATTEMPTS wrong guesses exhaust it
#     even within the TTL window (Critical finding #2 partial fix).
(cd "$REPO" && "$GATE" closure-pending-sync request --wp 333 --reason "rate limit test" --actor tester >/dev/null 2>&1)
for _ in 1 2 3 4; do
  (cd "$REPO" && "$GATE" closure-pending-sync confirm --wp 333 --challenge-response 000000 >/dev/null 2>&1) || true
done
set +e
out=$(cd "$REPO" && "$GATE" closure-pending-sync confirm --wp 333 --challenge-response 000000 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "5-я неверная попытка должна провалиться как и предыдущие"
echo "$out" | grep -q "попытки исчерпаны" || fail "сообщение не называет исчерпание попыток: $out"
pass "closure-pending-sync confirm: попытки исчерпываются после нескольких неверных кодов подряд"

echo "ALL PASS"
