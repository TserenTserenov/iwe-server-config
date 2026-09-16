#!/usr/bin/env bash
# P1(b), WP-484 п.19: `open` stamps guard_schema: <N> into every semaphore so
# a future version skew between two unsynced session-guard.sh copies on one
# host (the WP-573 incident, 14.09) is greppable from the semaphore itself
# instead of requiring a multi-agent git-archaeology session to even locate
# which copy wrote what. Fixture setup mirrors
# session-guard-close-legacy-no-governance-fields-smoke.sh (real `open`,
# then strip fields to simulate a semaphore written by an older copy).
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-guard-schema.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/DS-strategy"
ORIGIN="$TEST_ROOT/origin.git"
mkdir -p "$REPO/inbox/agent/tasks" "$REPO/scripts"
git init --bare -q "$ORIGIN"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "$ORIGIN"
cat > "$REPO/scripts/process-runner.py" <<'EOF'
#!/usr/bin/env python3
print("{}")
EOF
chmod +x "$REPO/scripts/process-runner.py"
git -C "$REPO" add scripts/process-runner.py
git -C "$REPO" commit -qm init
git -C "$REPO" push -q origin HEAD:main

SESSIONS="$TEST_ROOT/MC-sessions"
SESSIONS_ORIGIN="$TEST_ROOT/sessions-origin.git"
mkdir -p "$SESSIONS"
git init --bare -q "$SESSIONS_ORIGIN"
git -C "$SESSIONS" init -q
git -C "$SESSIONS" config user.email test@example.com
git -C "$SESSIONS" config user.name "Test"
git -C "$SESSIONS" remote add origin "$SESSIONS_ORIGIN"
echo seed > "$SESSIONS/README.md"
git -C "$SESSIONS" add README.md
git -C "$SESSIONS" commit -qm init
git -C "$SESSIONS" push -q origin HEAD:main

export IWE_ROOT="$TEST_ROOT"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
export IWE_FROZEN_CANONICAL_PATH=""

CLAUDE_CODE_SESSION_ID="session-schema" bash "$GUARD" open --wp WP-484 --task fixture --slug guard-schema-smoke --agent fixture >/dev/null
SEM=$(grep -l '^slug: guard-schema-smoke$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)

FIELD=$(grep '^guard_schema: ' "$SEM" | head -1 | cut -d' ' -f2-)
if [ -z "$FIELD" ]; then
    echo "FAIL: semaphore has no guard_schema: field"; cat "$SEM"; exit 1
fi
[[ "$FIELD" =~ ^[0-9]+$ ]] || { echo "FAIL: guard_schema value is not a plain integer: $FIELD"; exit 1; }
echo "PASS: open() stamps guard_schema: $FIELD into the semaphore"

# Simulate a semaphore written by a copy older than this field (and older than
# governance_worktree/isolated_worktree/orz_sessions_dir too -- the same
# structurally-legacy condition the sibling smoke test exercises) by stripping
# all four from an otherwise ordinary, real semaphore.
ORZ_BASENAME=$(grep '^orz_file: ' "$SEM" | cut -d' ' -f2-)
mkdir -p "$(dirname "$SESSIONS/$ORZ_BASENAME")"
cat > "$SESSIONS/$ORZ_BASENAME" <<'EOF'
---
date: 2026-09-15
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
git -C "$SESSIONS" add "$ORZ_BASENAME"
git -C "$SESSIONS" commit -qm "orz"
git -C "$SESSIONS" push -q origin HEAD:main

grep -vE '^(governance_worktree|isolated_worktree|orz_sessions_dir|guard_schema): ' "$SEM" > "$SEM.stripped"
mv "$SEM.stripped" "$SEM"

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-guard-schema-smoke.md" <<'EOF'
---
process_id: quick-close
run_id: quick-close-guard-schema-smoke
requested_slug: guard-schema-smoke
status: completed
current_step: done
owner_session_id: session-schema
results:
  gather-session-facts:
    wp: WP-484
---
EOF
echo "file: inbox/agent/tasks/RUN-quick-close-guard-schema-smoke.md" >> "$SEM"

OUT=$(CLAUDE_CODE_SESSION_ID="session-schema" bash "$GUARD" close --wp WP-484 --slug guard-schema-smoke --agent fixture 2>&1) || true
if ! grep -q "guard_schema=отсутствует" <<<"$OUT"; then
    echo "FAIL: close() did not name the missing guard_schema on a structurally legacy semaphore"
    echo "$OUT"
    exit 1
fi
echo "PASS: close() names guard_schema skew on a legacy semaphore instead of failing silently"
echo "session-guard-guard-schema-smoke: 2/2 PASS"
