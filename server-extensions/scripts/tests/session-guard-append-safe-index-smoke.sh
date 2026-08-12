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

REPO="$TEST_ROOT/DS-strategy"
mkdir -p "$REPO/sessions" "$REPO/inbox/agent/tasks"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"

cat > "$REPO/sessions/00-index.md" <<'EOF'
| Date | Session ID | Задача | Агенты | Ходы | Эскал | Статус | Отчёт |
EOF
git -C "$REPO" add sessions/00-index.md
git -C "$REPO" commit -qm init

export IWE_ROOT="$TEST_ROOT"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"

bash "$GUARD" open --wp WP-520 --task fixture --slug append-safe-smoke --agent fixture >/dev/null

# Register scope: session's own file (will be committed) + the shared index
# (will stay dirty, standing in for a concurrent writer's own row).
echo "own content" > "$REPO/own-file.md"
bash "$GUARD" note-file own-file.md --agent fixture >/dev/null
bash "$GUARD" note-file sessions/00-index.md --agent fixture >/dev/null

# This session's own file: committed, as close requires.
git -C "$REPO" add own-file.md
git -C "$REPO" commit -qm "own file"

# Simulate a concurrent session's uncommitted row in the shared index --
# not this session's own edit, but still registered in its scope because
# note-file fell back to the single open semaphore (WP-520 case 10).
cat >> "$REPO/sessions/00-index.md" <<'EOF'
| 2026-08-12 | other-session | someone else's row | other-agent | 0 | 0 | started | — |
EOF

# ORZ required by validate_orz.
ORZ="$REPO/sessions/2026-08/2026-08-12-append-safe-smoke.md"
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
git -C "$REPO" add "sessions/2026-08/2026-08-12-append-safe-smoke.md"
git -C "$REPO" commit -qm "orz"

# Terminal runner card required by close's Ф4 gate.
cat > "$REPO/inbox/agent/tasks/RUN-quick-close-append-safe-smoke.md" <<'EOF'
---
process_id: quick-close
status: completed
---
EOF

if bash "$GUARD" close --wp WP-520 --slug append-safe-smoke --agent fixture; then
    echo "PASS: close succeeds with a concurrent, uncommitted row in the append-safe index"
else
    echo "FAIL: close blocked on sessions/00-index.md despite the append-safe exclusion (WP-520 Ф8)" >&2
    exit 1
fi

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
echo "dirty, unrelated to the append-safe exclusion" > "$REPO2/exclusive-file.md"
IWE_ROOT="$TEST_ROOT2" bash "$GUARD" note-file exclusive-file.md --agent fixture >/dev/null

ORZ2="$REPO2/sessions/2026-08/2026-08-12-control-smoke.md"
mkdir -p "$(dirname "$ORZ2")"
cp "$ORZ" "$ORZ2"
git -C "$REPO2" add "sessions/2026-08/2026-08-12-control-smoke.md"
git -C "$REPO2" commit -qm "orz"
cat > "$REPO2/inbox/agent/tasks/RUN-quick-close-control-smoke.md" <<'EOF'
---
process_id: quick-close
status: completed
---
EOF

if IWE_ROOT="$TEST_ROOT2" bash "$GUARD" close --wp WP-520 --slug control-smoke --agent fixture 2>/dev/null; then
    echo "FAIL: close should still block on a genuinely dirty, non-append-safe file" >&2
    exit 1
else
    echo "PASS: close still blocks on a dirty exclusive file outside the append-safe scope"
fi
