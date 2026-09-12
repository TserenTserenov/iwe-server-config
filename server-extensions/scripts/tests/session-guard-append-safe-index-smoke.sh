#!/usr/bin/env bash
# Regression for WP-520 Ф8: sessions/00-index.md carries an append-only
# contract (each session adds one row above the table) -- a concurrent
# session's own uncommitted row in that file must not block THIS session's
# close. Live incident: WP-518 Ф5 (12.08), 7 conflict cycles just to clear
# this file plus one umbrella WP-N.md before a content-ready session could
# close. Reproduces the file locally dirty (a concurrent writer's legitimate,
# not-yet-pushed row) while every OTHER registered scope file is clean.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-append-safe.XXXXXX)
TEST_ROOT2=""
trap 'rm -rf "$TEST_ROOT" "$TEST_ROOT2"' EXIT

# A session may span a third repository in addition to governance + sessions.
# Keep one committed-but-unpushed root-repo change so close must discover it
# through the legacy repo-relative `file:` registry even on a new semaphore.
git -C "$TEST_ROOT" init -q
git -C "$TEST_ROOT" config user.email test@example.com
git -C "$TEST_ROOT" config user.name "Test"
echo "root baseline" > "$TEST_ROOT/root-owned.md"
git -C "$TEST_ROOT" add root-owned.md
git -C "$TEST_ROOT" commit -qm "root baseline"
git -C "$TEST_ROOT" update-ref refs/remotes/origin/main HEAD
echo "root session change" > "$TEST_ROOT/root-owned.md"
git -C "$TEST_ROOT" add root-owned.md
git -C "$TEST_ROOT" commit -qm "root session change"

REPO="$TEST_ROOT/DS-strategy"
ISOLATED="$TEST_ROOT/isolated-worktree"
ORIGIN="$TEST_ROOT/governance-origin.git"
git init -q --bare -b main "$ORIGIN"
mkdir -p "$REPO/sessions" "$REPO/inbox/agent/tasks" "$REPO/scripts"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "$ORIGIN"
cat > "$REPO/scripts/process-runner.py" <<'EOF'
#!/usr/bin/env python3
print("{}")
EOF
chmod +x "$REPO/scripts/process-runner.py"

cat > "$REPO/sessions/00-index.md" <<'EOF'
| Date | Session ID | Задача | Агенты | Ходы | Эскал | Статус | Отчёт |
EOF
git -C "$REPO" add sessions/00-index.md
git -C "$REPO" commit -qm init
git -C "$REPO" push -q origin HEAD:main

export IWE_ROOT="$TEST_ROOT"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
# This fixture's repo dir happens to share a name with the real canonical
# checkout the WP-520 freeze defaults to -- opt out explicitly, this test is
# about append-safe scope gating, not freeze (session-guard-freeze-enforce-smoke.sh
# owns that).
export IWE_FROZEN_CANONICAL_PATH=""

bash "$GUARD" open --wp WP-520 --task fixture --slug append-safe-smoke --agent fixture >/dev/null
SEM=$(find "$TEST_ROOT/.iwe-runtime/sessions" -name 'fixture-*.open' -type f | head -1)
GUARD_SID=$(grep '^session_id: ' "$SEM" | cut -d' ' -f2-)
ORZ_BASENAME=$(grep '^orz_file: ' "$SEM" | cut -d' ' -f2-)
git -C "$REPO" worktree add -qb isolated-session "$ISOLATED"
mkdir -p "$ISOLATED/inbox/agent/tasks"
# This fixture creates its worktree manually after `open`: it may identify the
# governance/code checkout, but must not gain automatic publish/remove rights
# through isolated_worktree (reserved for worktrees created by open --isolate).
perl -0pi -e 's#^governance_worktree: .*$#governance_worktree: '"$ISOLATED"'#m; s#^orz_sessions_dir: .*$#orz_sessions_dir: '"$ISOLATED"'/sessions#m' "$SEM"
rm -f "$REPO/sessions/$ORZ_BASENAME"

# Register scope from the checkout the semaphore now names: the session's own
# file will be committed, while both supported index spellings stay dirty.
echo "own content" > "$ISOLATED/own-file.md"
(cd "$ISOLATED" && bash "$GUARD" note-file own-file.md --agent fixture >/dev/null)
(cd "$ISOLATED" && bash "$GUARD" note-file sessions/00-index.md --agent fixture >/dev/null)
echo "modern root-level index dirt" > "$ISOLATED/00-index.md"
(cd "$ISOLATED" && bash "$GUARD" note-file 00-index.md --agent fixture >/dev/null)
(cd "$TEST_ROOT" && bash "$GUARD" note-file root-owned.md --agent fixture >/dev/null)

# This session's own file: committed, as close requires.
git -C "$ISOLATED" add own-file.md
git -C "$ISOLATED" commit -qm "own file"

# A real isolated-session artifact is clean and committed in its own worktree,
# while the canonical checkout has an unrelated untracked file at the same
# path.  Close must inspect the ORZ worktree, not misattribute canonical dirt.
echo "isolated artifact" > "$ISOLATED/isolate-owned.md"
git -C "$ISOLATED" add isolate-owned.md
git -C "$ISOLATED" commit -qm "isolated artifact"
echo "file: isolate-owned.md" >> "$SEM"
echo "canonical foreign dirt" > "$REPO/isolate-owned.md"

# Simulate a concurrent session's uncommitted row in the shared index --
# not this session's own edit, but still registered in its scope because
# note-file fell back to the single open semaphore (WP-520 case 10).
cat >> "$ISOLATED/sessions/00-index.md" <<'EOF'
| 2026-08-12 | other-session | someone else's row | other-agent | 0 | 0 | started | — |
EOF

# ORZ required by validate_orz.
ORZ="$ISOLATED/sessions/$ORZ_BASENAME"
mkdir -p "$(dirname "$ORZ")"
cat > "$ORZ" <<'EOF'
---
date: 2026-08-12
type: work
wp: WP-520
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
git -C "$ISOLATED" add "sessions/$ORZ_BASENAME"
git -C "$ISOLATED" commit -qm "orz"
git -C "$ISOLATED" push -q origin HEAD:main

# Terminal runner card required by close's Ф4 gate.
cat > "$ISOLATED/inbox/agent/tasks/RUN-quick-close-append-safe-smoke.md" <<EOF
---
process_id: quick-close
run_id: quick-close-append-safe-smoke
requested_slug: append-safe-smoke
status: completed
current_step: done
owner_session_id: $GUARD_SID
results:
  gather-session-facts:
    wp: WP-520
---
EOF
echo "file: inbox/agent/tasks/RUN-quick-close-append-safe-smoke.md" >> "$SEM"

if CLOSE_OUT=$(bash "$GUARD" close --wp WP-520 --slug append-safe-smoke --agent fixture 2>&1); then
    printf '%s\n' "$CLOSE_OUT"
    echo "PASS: close uses isolate scope and accepts its terminal runner card"
else
    echo "FAIL: close blocked on an append-safe index or misattributed canonical dirt: $CLOSE_OUT" >&2
    exit 1
fi
if ! grep -Fq "незапушенных коммита в $(basename "$TEST_ROOT")" <<<"$CLOSE_OUT"; then
    echo "FAIL: close did not inspect the third/root repository registered by this session: $CLOSE_OUT" >&2
    exit 1
fi
echo "PASS: close still warns about an unpushed third repository on a current-schema semaphore"

# Control: a non-append-safe registered file left genuinely dirty must still
# block close -- the exclusion is scoped to 00-index.md, not a blanket bypass.
TEST_ROOT2=$(mktemp -d /private/tmp/session-guard-append-safe-control.XXXXXX)
REPO2="$TEST_ROOT2/DS-strategy"
mkdir -p "$REPO2/sessions" "$REPO2/inbox/agent/tasks"
git -C "$REPO2" init -q
git -C "$REPO2" config user.email test@example.com
git -C "$REPO2" config user.name "Test"
echo "placeholder" > "$REPO2/sessions/00-index.md"
git -C "$REPO2" add sessions/00-index.md
git -C "$REPO2" commit -qm init

IWE_ROOT="$TEST_ROOT2" bash "$GUARD" open --wp WP-520 --task fixture --slug control-smoke --agent fixture >/dev/null
SEM2=$(find "$TEST_ROOT2/.iwe-runtime/sessions" -name 'fixture-*.open' -type f | head -1)
GUARD_SID2=$(grep '^session_id: ' "$SEM2" | cut -d' ' -f2-)
ORZ_BASENAME2=$(grep '^orz_file: ' "$SEM2" | cut -d' ' -f2-)
mkdir -p "$REPO2/nested"
echo "dirty nested basename, not an append-safe alias" > "$REPO2/nested/00-index.md"
(cd "$REPO2" && IWE_ROOT="$TEST_ROOT2" bash "$GUARD" note-file nested/00-index.md --agent fixture >/dev/null)

ORZ2="$REPO2/sessions/$ORZ_BASENAME2"
mkdir -p "$(dirname "$ORZ2")"
cp "$ORZ" "$ORZ2"
git -C "$REPO2" add "sessions/$ORZ_BASENAME2"
git -C "$REPO2" commit -qm "orz"
cat > "$REPO2/inbox/agent/tasks/RUN-quick-close-control-smoke.md" <<EOF
---
process_id: quick-close
run_id: quick-close-control-smoke
requested_slug: control-smoke
status: completed
current_step: done
owner_session_id: $GUARD_SID2
results:
  gather-session-facts:
    wp: WP-520
---
EOF

if CONTROL_OUT=$(IWE_ROOT="$TEST_ROOT2" bash "$GUARD" close --wp WP-520 --slug control-smoke --agent fixture 2>&1); then
    echo "FAIL: close should not exempt an arbitrary nested 00-index.md by basename" >&2
    exit 1
fi
if ! grep -Fq 'nested/00-index.md' <<<"$CONTROL_OUT"; then
    echo "FAIL: control close failed before exercising the exact-path exclusion: $CONTROL_OUT" >&2
    exit 1
fi
echo "PASS: close exempts only the two exact index aliases"
