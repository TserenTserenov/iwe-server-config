#!/usr/bin/env bash
# Regression for WP-561 Ф61 stage 1: the close route is chosen from facts, not from the
# close_path declared at open. `close --explain` prints the route and changes nothing;
# a real close records the route in the ledger (close_route_observed) and still closes
# exactly as before (observation only). The classifier itself is unit-tested in
# scripts/tests/test_close_route.py; this smoke checks the facts session-guard.sh gathers.
# All artifacts live in mktemp; nothing real is touched.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-close-route.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/DS-strategy"
ORIGIN="$TEST_ROOT/origin.git"
mkdir -p "$REPO/inbox/WP-561" "$REPO/scripts"
printf '%s\n' 'hypothesis_relation: "tests"' > "$REPO/inbox/WP-561/WP-561.md"
git init --bare -q "$ORIGIN"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "$ORIGIN"
printf '%s\n' 'open-sessions.log' > "$REPO/.gitignore"
printf '%s\n' '#!/usr/bin/env python3' 'print("{}")' > "$REPO/scripts/process-runner.py"
# The ledger stub records every call, so the test sees what close tried to write.
LEDGER_LOG="$TEST_ROOT/ledger-calls.log"
cat > "$REPO/scripts/ledger-append.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LEDGER_LOG"
EOF
printf '%s\n' '#!/usr/bin/env python3' 'pass' > "$REPO/scripts/close_obligation.py"
chmod +x "$REPO/scripts/process-runner.py" "$REPO/scripts/ledger-append.sh"
git -C "$REPO" add .gitignore scripts inbox
git -C "$REPO" commit -qm init
git -C "$REPO" push -q origin HEAD:main

MC="$TEST_ROOT/MC-sessions"
MC_ORIGIN="$TEST_ROOT/mc-origin.git"
git init --bare -q "$MC_ORIGIN"
git init -q -b main "$MC"
git -C "$MC" config user.email test@example.com
git -C "$MC" config user.name "Test"
git -C "$MC" remote add origin "$MC_ORIGIN"
printf 'sessions\n' > "$MC/README.md"
git -C "$MC" add README.md
git -C "$MC" commit -qm init
git -C "$MC" push -q origin HEAD:main

export IWE_ROOT="$TEST_ROOT"
export IWE_SESSIONS_ROOT="$MC"
export CLAUDE_CODE_SESSION_ID="dddddddd-1111-2222-3333-444444444444"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
export IWE_FROZEN_CANONICAL_PATH=""
export LEDGER_LOG

fail() { echo "FAIL: $*" >&2; exit 1; }

# Opens an isolated session WITHOUT --close-path; sets SEM and WT.
open_session() {  # <slug>
  (cd "$REPO" && bash "$GUARD" open --wp WP-561 --task fixture --slug "$1" --agent fixture --isolate) \
    >"$TEST_ROOT/open-$1.out" 2>&1 || { cat "$TEST_ROOT/open-$1.out" >&2; fail "open --isolate must succeed"; }
  SEM=$(grep -l "^slug: $1\$" "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
  grep -q '^close_path: unknown$' "$SEM" || fail "a session opened without --close-path must record unknown"
  WT=$(sed -n 's/^isolated_worktree: //p' "$SEM")
  [ -d "$WT" ] || fail "isolated worktree must exist: $WT"
  # A valid ORZ lets a real close get past ORZ validation to the closing-card requirement.
  ORZ_REL=$(sed -n 's/^orz_file: //p' "$SEM")
  mkdir -p "$(dirname "$MC/$ORZ_REL")"
  printf -- '---\ndate: 2026-11-12\ntype: work\nwp: WP-561\nduration_h: 0.1\nartifacts: []\nagent: fixture\n---\n\n# Fixture\n\n## Главный инсайт\nf\n\n## Контекст\nf\n\n## Достигнуто\nf\n\n## Ключевые решения\nf\n' > "$MC/$ORZ_REL"
  git -C "$MC" add "$ORZ_REL"
  git -C "$MC" commit -qm "orz $1"
  git -C "$MC" push -q origin HEAD:main
}

explain() {  # <slug> <out file>
  (cd "$REPO" && bash "$GUARD" close --explain --wp WP-561 --slug "$1" --agent fixture) >"$2" 2>&1
}

# --- A. clean isolated copy, nothing declared: proven empty, close untouched ----------
open_session route-a
SEM_BEFORE=$(shasum "$SEM")
LEDGER_BEFORE=$(cat "$LEDGER_LOG" 2>/dev/null || true)  # open itself writes session_opened
explain route-a "$TEST_ROOT/explain-a.out" || { cat "$TEST_ROOT/explain-a.out" >&2; fail "explain must succeed"; }
grep -q 'Путь закрытия: release-empty' "$TEST_ROOT/explain-a.out" \
  || { cat "$TEST_ROOT/explain-a.out" >&2; fail "a clean isolated session must be release-empty without any declaration"; }
grep -q 'расходится с фактами' "$TEST_ROOT/explain-a.out" || fail "declared unknown vs release-empty must be flagged"
[ "$SEM_BEFORE" = "$(shasum "$SEM")" ] || fail "explain must not change the semaphore"
[ "$LEDGER_BEFORE" = "$(cat "$LEDGER_LOG" 2>/dev/null || true)" ] || fail "explain must not write the ledger"
# Without the generalization the declared-only proof still refuses: the old path is intact.
eval "$(sed -n '/^_no_code_changes_proof()/,/^}/p' "$GUARD")"
if _no_code_changes_proof "$SEM" 2>/dev/null; then fail "the declared proof must still require close_path no-code-changes"; fi
_no_code_changes_proof "$SEM" any 2>"$TEST_ROOT/proof-a.err" || { cat "$TEST_ROOT/proof-a.err" >&2; fail "the any-mode proof must pass on a clean copy"; }
echo "OK: clean isolated session -> release-empty, explain changes nothing"

# Real close: behaviour unchanged (no card -> refused as before), the route is recorded.
if (cd "$REPO" && bash "$GUARD" close --wp WP-561 --slug route-a --agent fixture) 2>"$TEST_ROOT/close-a.err"; then
  fail "stage 1 must not change close: an unknown-path session without a card is still refused"
fi
[ -e "$SEM" ] || fail "a refused close must keep the session open"
grep -q 'нет terminal RUN-quick-close-route-a' "$TEST_ROOT/close-a.err" \
  || { cat "$TEST_ROOT/close-a.err" >&2; fail "close must still demand the quick-close card, as before stage 1"; }
grep -q 'close_route_observed .*"route": "release-empty"' "$LEDGER_LOG" \
  || { cat "$LEDGER_LOG" "$TEST_ROOT/close-a.err" >&2; fail "close must record the observed route"; }
grep -q '"declared": "unknown"' "$LEDGER_LOG" || fail "the record must carry the declared path"
grep -q '"slug": "route-a"' "$LEDGER_LOG" || fail "the record must carry the session slug"
grep -q '"session_id": "' "$LEDGER_LOG" || fail "the record must carry the session id"
echo "OK: real close records the route and keeps its old behaviour"

# --- B. a change in the copy: ordinary close ----------------------------------------
printf 'work\n' > "$WT/note.md"
explain route-a "$TEST_ROOT/explain-b.out"
grep -q 'Путь закрытия: close-changes$' "$TEST_ROOT/explain-b.out" \
  || { cat "$TEST_ROOT/explain-b.out" >&2; fail "a dirty copy must give close-changes without the peer step"; }
grep -q 'note.md' "$TEST_ROOT/explain-b.out" || fail "explain must name what broke the proof"
rm -f "$WT/note.md"
echo "OK: a change in the copy -> close-changes with the reason"

# --- C. peer traces without a declaration add the peer step --------------------------
PEER_DIR="$MC/2026-11/12/route-a"
mkdir -p "$PEER_DIR"
printf -- '---\nturn: 0\n---\n' > "$PEER_DIR/00-writer.md"
printf 'work\n' > "$WT/note.md"
explain route-a "$TEST_ROOT/explain-c.out"
grep -q 'close-changes + публикация журнала и отчёта пир-сессии' "$TEST_ROOT/explain-c.out" \
  || { cat "$TEST_ROOT/explain-c.out" >&2; fail "peer traces must add the peer step whatever was declared"; }
rm -f "$WT/note.md"
echo "OK: peer traces without a declaration -> peer step"

# --- D. no session: nothing to close -------------------------------------------------
(cd "$REPO" && bash "$GUARD" close --explain --agent fixture-without-sessions) >"$TEST_ROOT/explain-d.out" 2>&1 \
  || fail "explain without a session must still answer"
grep -q 'Путь закрытия: nothing' "$TEST_ROOT/explain-d.out" || { cat "$TEST_ROOT/explain-d.out" >&2; fail "no mark must give nothing"; }
echo "OK: no session -> nothing"

# --- F. selectors: a miss with an open session is not "nothing"; two sessions are ambiguous --
explain route-a-typo "$TEST_ROOT/explain-f1.out" || true
grep -q 'Путь закрытия: nothing' "$TEST_ROOT/explain-f1.out" \
  && { cat "$TEST_ROOT/explain-f1.out" >&2; fail "a slug that misses an open session must not say nothing to close"; }
grep -q 'отказ (unresolved)' "$TEST_ROOT/explain-f1.out" || { cat "$TEST_ROOT/explain-f1.out" >&2; fail "a missed selector must be refused as unresolved"; }
open_session route-f
(cd "$REPO" && bash "$GUARD" close --explain --agent fixture) >"$TEST_ROOT/explain-f2.out" 2>&1 || true
grep -q 'отказ (ambiguous)' "$TEST_ROOT/explain-f2.out" || { cat "$TEST_ROOT/explain-f2.out" >&2; fail "two open sessions without a selector must be ambiguous"; }
echo "OK: missed selector -> unresolved, two sessions -> ambiguous"

# --- G. a broken classifier never changes the real close ----------------------------
ROUTE_LIB="$ROOT_DIR/scripts/lib/close_route.py"
cp "$ROUTE_LIB" "$TEST_ROOT/close_route.py.bak"
trap 'cp "$TEST_ROOT/close_route.py.bak" "$ROUTE_LIB"; rm -rf "$TEST_ROOT"' EXIT
printf 'raise SystemExit(5)\n' > "$ROUTE_LIB"
if (cd "$REPO" && bash "$GUARD" close --wp WP-561 --slug route-f --agent fixture) 2>"$TEST_ROOT/close-g.err"; then
  cp "$TEST_ROOT/close_route.py.bak" "$ROUTE_LIB"; fail "a broken classifier must not let a cardless close through"
fi
cp "$TEST_ROOT/close_route.py.bak" "$ROUTE_LIB"
grep -q 'путь закрытия по фактам не посчитан' "$TEST_ROOT/close-g.err" || { cat "$TEST_ROOT/close-g.err" >&2; fail "a broken classifier must be reported"; }
grep -q 'нет terminal RUN-quick-close-route-f' "$TEST_ROOT/close-g.err" || fail "close must still demand the card with a broken classifier"
echo "OK: a broken classifier only loses the record"

# --- E. --explain is a close-only flag ------------------------------------------------
if (cd "$REPO" && bash "$GUARD" open --explain --wp WP-561 --agent fixture) >"$TEST_ROOT/open-e.out" 2>&1; then
  fail "--explain outside close must be refused"
fi
grep -q 'применим только к close' "$TEST_ROOT/open-e.out" || fail "refusal must name the command"
echo "OK: --explain outside close is refused"

echo "PASS: session-guard close route from facts (WP-561 Ф61 stage 1)"
