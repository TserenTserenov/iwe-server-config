#!/usr/bin/env bash
# Regression for WP-484 Ф267 п.2: `open --isolate --close-path no-code-changes` lets a healing /
# reading / diagnosis session close without a quick-close RUN card, but ONLY while the promise is
# proven: nothing claimed except the session's own ORZ and inbox/open-sessions.log, the isolated
# worktree clean (tracked, staged and untracked), nothing ahead of origin/main. A failed proof
# does not fail the close outright: it falls back to the ordinary terminal-card requirement.
# All artifacts live in mktemp; nothing real is touched.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-no-code-changes.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/DS-strategy"
ORIGIN="$TEST_ROOT/origin.git"
mkdir -p "$REPO/sessions" "$REPO/inbox/agent/tasks" "$REPO/inbox/WP-484" "$REPO/scripts"
printf '%s\n' 'hypothesis_relation: "tests"' > "$REPO/inbox/WP-484/WP-484.md"
git init --bare -q "$ORIGIN"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "$ORIGIN"
printf '%s\n' 'open-sessions.log' > "$REPO/.gitignore"
cat > "$REPO/scripts/process-runner.py" <<'EOF'
#!/usr/bin/env python3
print("{}")
EOF
cat > "$REPO/scripts/isolate-push.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
git -C "$1" push -q origin HEAD:"$2"
EOF
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$REPO/scripts/ledger-append.sh"
OBLIGATION_LOG="$TEST_ROOT/obligation-calls.log"
cat > "$REPO/scripts/close_obligation.py" <<'EOF'
#!/usr/bin/env python3
import os
import sys

with open(os.environ["OBLIGATION_LOG"], "a", encoding="utf-8") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
EOF
export OBLIGATION_LOG
chmod +x "$REPO/scripts/process-runner.py" "$REPO/scripts/isolate-push.sh" "$REPO/scripts/ledger-append.sh"
git -C "$REPO" add .gitignore scripts/process-runner.py scripts/isolate-push.sh scripts/ledger-append.sh scripts/close_obligation.py inbox/WP-484/WP-484.md
git -C "$REPO" commit -qm init
git -C "$REPO" push -q origin HEAD:main

# Sessions repository of the fixture: ORZ files must never reach the real MC-sessions.
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
export CLAUDE_CODE_SESSION_ID="cccccccc-1111-2222-3333-444444444444"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
export IWE_FROZEN_CANONICAL_PATH=""

fail() { echo "FAIL: $*" >&2; exit 1; }

write_orz() {  # <orz path>
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'EOF'
---
date: 2026-10-29
type: work
wp: WP-484
duration_h: 0.1
artifacts: []
agent: fixture
---

# Fixture session

## Главный инсайт
fixture

## Контекст
fixture

## Достигнуто
fixture

## Ключевые решения
fixture
EOF
}

# Opens an isolated no-code-changes session; sets SEM, WT and writes its ORZ file.
open_session() {  # <slug>
  (cd "$REPO" && bash "$GUARD" open --wp WP-484 --task fixture --slug "$1" --agent fixture --isolate --close-path no-code-changes) >"$TEST_ROOT/open-$1.out" 2>&1 \
    || { cat "$TEST_ROOT/open-$1.out" >&2; fail "open --isolate --close-path no-code-changes must succeed"; }
  SEM=$(grep -l "^slug: $1\$" "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
  grep -q '^close_path: no-code-changes$' "$SEM" || fail "close_path must be recorded in the semaphore"
  WT=$(sed -n 's/^isolated_worktree: //p' "$SEM")
  [ -d "$WT" ] || fail "isolated worktree must exist: $WT"
  ORZ_DIR=$(sed -n 's/^orz_sessions_dir: //p' "$SEM")
  [ "$ORZ_DIR" = "$MC" ] || fail "the fixture must write its ORZ into the fixture sessions repo, got: $ORZ_DIR"
  ORZ_REL=$(sed -n 's/^orz_file: //p' "$SEM")
  write_orz "$ORZ_DIR/$ORZ_REL"
  git -C "$MC" add "$ORZ_REL"
  git -C "$MC" commit -qm "orz $1"
  git -C "$MC" push -q origin HEAD:main
}

close_session() {  # <slug> <stderr file>
  (cd "$REPO" && bash "$GUARD" close --wp WP-484 --slug "$1" --agent fixture) 2>"$2"
}

# --- A. the promise holds: close needs no runner card -------------------------
open_session no-code-a
if close_session no-code-a "$TEST_ROOT/close-a.err" && grep -q 'close_path=no-code-changes объявлен и доказан' "$TEST_ROOT/close-a.err"; then
  grep -q -- "cancel --session-id $CLAUDE_CODE_SESSION_ID --action peer-session-close" "$OBLIGATION_LOG" 2>/dev/null \
    || { cat "$OBLIGATION_LOG" 2>/dev/null >&2; fail "the light close must clear the conversation's close obligation"; }
  [ -f "$SEM.closed" ] || fail "a closed session must leave the .open.closed receipt"
  [ ! -e "$SEM" ] || fail "a closed session must no longer be live"
  [ ! -d "$WT" ] || fail "close must remove the isolated worktree"
  echo "OK: a proven no-code-changes session closes without a quick-close card"
else
  cat "$TEST_ROOT/close-a.err" >&2; fail "proven no-code-changes close must bypass the runner"
fi

[ "$(grep -c -- "--action peer-session-close" "$OBLIGATION_LOG")" = 1 ] || fail "exactly one obligation clear expected after the first close"

# --- B. an untracked file in the isolated worktree breaks the proof -----------
open_session no-code-b
printf 'leftover\n' > "$WT/untracked-note.txt"
if close_session no-code-b "$TEST_ROOT/close-b.err"; then fail "an untracked file must stop the light close"; fi
grep -q 'не доказан' "$TEST_ROOT/close-b.err" || { cat "$TEST_ROOT/close-b.err" >&2; fail "refusal must say the promise is not proven"; }
grep -q 'untracked-note.txt' "$TEST_ROOT/close-b.err" || fail "refusal must name the dirty file"
grep -q 'quick-close' "$TEST_ROOT/close-b.err" || fail "refusal must name the ready exit"
echo "OK: an untracked file stops the light close and names the exit"

# --- C. a modified tracked file ----------------------------------------------
rm -f "$WT/untracked-note.txt"
printf '# changed\n' >> "$WT/scripts/process-runner.py"
if close_session no-code-b "$TEST_ROOT/close-c.err"; then fail "a modified tracked file must stop the light close"; fi
grep -q 'process-runner.py' "$TEST_ROOT/close-c.err" || fail "refusal must name the modified file"
git -C "$WT" checkout -q -- scripts/process-runner.py
echo "OK: a modified tracked file stops the light close"

# --- D. a commit that origin/main lacks --------------------------------------
git -C "$WT" config user.email test@example.com
git -C "$WT" config user.name Test
printf 'x\n' > "$WT/new-file.txt"
git -C "$WT" add new-file.txt
git -C "$WT" commit -qm "local only"
if close_session no-code-b "$TEST_ROOT/close-d.err"; then fail "a commit ahead of origin/main must stop the light close"; fi
grep -q 'HEAD изолированной копии сдвинут' "$TEST_ROOT/close-d.err" || { cat "$TEST_ROOT/close-d.err" >&2; fail "refusal must say HEAD moved"; }
# the same commit pushed to origin/main: nothing is "ahead" any more, but HEAD still moved
git -C "$WT" push -q origin HEAD:main
if close_session no-code-b "$TEST_ROOT/close-d2.err"; then fail "a pushed-and-forgotten commit must stop the light close"; fi
grep -q 'HEAD изолированной копии сдвинут' "$TEST_ROOT/close-d2.err" || fail "pushed commit refusal must say HEAD moved"
git -C "$WT" reset -q --hard HEAD~1
echo "OK: a commit, even one already pushed, stops the light close"

# --- E. an extra claim in the semaphore --------------------------------------
printf 'extra\n' > "$WT/extra.md"
(cd "$REPO" && bash "$GUARD" note-file "extra.md" --wp WP-484 --slug no-code-b --agent fixture) >"$TEST_ROOT/note-e.out" 2>&1 \
  || { cat "$TEST_ROOT/note-e.out" >&2; fail "note-file of the extra claim must succeed so the refusal is really tested"; }
grep -q 'extra.md' "$SEM" || fail "the extra claim must be recorded in the semaphore"
if close_session no-code-b "$TEST_ROOT/close-e.err"; then fail "an extra claim must stop the light close"; fi
grep -q 'extra.md' "$TEST_ROOT/close-e.err" || { cat "$TEST_ROOT/close-e.err" >&2; fail "refusal must show the extra claim"; }
rm -f "$WT/extra.md"
[ "$(grep -c -- "--action peer-session-close" "$OBLIGATION_LOG")" = 1 ] || { cat "$OBLIGATION_LOG" >&2; fail "a refused light close must not clear the obligation"; }
echo "OK: a claim beyond the own ORZ and open-sessions.log stops the light close"

# --- G. the proof itself: bookkeeping lines are not claims, a foreign repository is ----
eval "$(sed -n '/^_no_code_changes_proof()/,/^}/p' "$GUARD")"
open_session no-code-g
_no_code_changes_proof "$SEM" 2>"$TEST_ROOT/proof-g1.err" || { cat "$TEST_ROOT/proof-g1.err" >&2; fail "a fresh declared session must pass the proof"; }
cp "$SEM" "$TEST_ROOT/sem-g.bak"
printf 'close_attempt_id: 1\nclose_delivery_version: isolate-push/v2\nclose_delivery_terminal_reference: declared-no-code-changes:no-code-g\n' >> "$SEM"
_no_code_changes_proof "$SEM" 2>"$TEST_ROOT/proof-g2.err" || { cat "$TEST_ROOT/proof-g2.err" >&2; fail "close bookkeeping lines written at PREPARE must not count as claims"; }
cp "$TEST_ROOT/sem-g.bak" "$SEM"
FOREIGN="$TEST_ROOT/foreign-repo"
git init -q -b main "$FOREIGN"
printf 'file_v2: {"path": "inbox/open-sessions.log", "repo": "%s/.git"}\n' "$FOREIGN" >> "$SEM"
if _no_code_changes_proof "$SEM" 2>"$TEST_ROOT/proof-g3.err"; then fail "the log path in a foreign repository must not count as the own log"; fi
grep -q 'кроме своего ORZ' "$TEST_ROOT/proof-g3.err" || fail "foreign-repository refusal must name the extra claim"
cp "$TEST_ROOT/sem-g.bak" "$SEM"
echo "OK: the proof ignores close bookkeeping lines and binds claims to their repository"

# --- F. without --isolate the path is refused at open ------------------------
if (cd "$REPO" && bash "$GUARD" open --wp WP-484 --task fixture --slug no-code-f --agent fixture --close-path no-code-changes) >"$TEST_ROOT/open-f.out" 2>&1; then
  fail "open --close-path no-code-changes without --isolate must be refused"
fi
grep -q 'требует --isolate' "$TEST_ROOT/open-f.out" || fail "refusal must say --isolate is required"
echo "OK: without --isolate the path is refused at open"

echo "PASS: session-guard close_path=no-code-changes (WP-484 Ф267 п.2)"
