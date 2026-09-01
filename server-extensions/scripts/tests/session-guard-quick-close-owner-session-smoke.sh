#!/usr/bin/env bash
# Regression for WP-484 V(b) (01.09, пир-сессия с Kimi+Codex): close's
# RUN-quick-close-*.md selection globs by SLUG only -- two sessions sharing a
# task name (or the same slug reused after the first session's card wasn't
# cleaned up) let a foreign session's completed card satisfy THIS session's
# close gate. Fix: when this session's own harness_session_id is known,
# RUNNER_CARDS is filtered to cards whose owner_session_id matches it before
# any of the RUNNER_OK-selecting branches see them.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-owner-session.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/DS-strategy"
mkdir -p "$REPO/sessions" "$REPO/inbox/agent/tasks" "$REPO/scripts"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
cat > "$REPO/scripts/process-runner.py" <<'EOF'
#!/usr/bin/env python3
print("{}")
EOF
chmod +x "$REPO/scripts/process-runner.py"
git -C "$REPO" add scripts/process-runner.py
git -C "$REPO" commit -qm init

export IWE_ROOT="$TEST_ROOT"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
export IWE_FROZEN_CANONICAL_PATH=""

write_orz() {
  local orz_path="$1"
  mkdir -p "$(dirname "$orz_path")"
  cat > "$orz_path" <<'EOF'
---
date: 2026-09-01
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

# --- Scenario A: foreign owner_session_id must NOT satisfy the gate --------
CLAUDE_CODE_SESSION_ID="session-A" bash "$GUARD" open --wp WP-484 --task fixture --slug owner-smoke-a --agent fixture >/dev/null
SEM_A=$(find "$TEST_ROOT/.iwe-runtime/sessions" -name 'fixture-*.open' -type f | head -1)
grep -q '^harness_session_id: session-A$' "$SEM_A" || { echo "FAIL: fixture setup — harness_session_id not recorded in semaphore" >&2; exit 1; }
ORZ_BASENAME_A=$(grep '^orz_file: ' "$SEM_A" | cut -d' ' -f2-)
git -C "$REPO" add "sessions/$ORZ_BASENAME_A" 2>/dev/null || true
write_orz "$REPO/sessions/$ORZ_BASENAME_A"
git -C "$REPO" add "sessions/$ORZ_BASENAME_A"
git -C "$REPO" commit -qm "orz A"

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-owner-smoke-a.md" <<'EOF'
---
process_id: quick-close
status: completed
owner_session_id: session-FOREIGN
---
EOF
echo "file: inbox/agent/tasks/RUN-quick-close-owner-smoke-a.md" >> "$SEM_A"

if CLAUDE_CODE_SESSION_ID="session-A" bash "$GUARD" close --wp WP-484 --slug owner-smoke-a --agent fixture 2>/dev/null; then
  echo "FAIL: close accepted a card owned by a foreign session (session-FOREIGN != session-A)" >&2
  exit 1
else
  echo "PASS: foreign owner_session_id card does not satisfy close gate"
fi

# --- Scenario B: matching owner_session_id DOES satisfy the gate -----------
CLAUDE_CODE_SESSION_ID="session-B" bash "$GUARD" open --wp WP-484 --task fixture --slug owner-smoke-b --agent fixture >/dev/null
SEM_B=$(grep -l '^slug: owner-smoke-b$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_BASENAME_B=$(grep '^orz_file: ' "$SEM_B" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_BASENAME_B"
git -C "$REPO" add "sessions/$ORZ_BASENAME_B"
git -C "$REPO" commit -qm "orz B"

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-owner-smoke-b.md" <<'EOF'
---
process_id: quick-close
status: completed
owner_session_id: session-B
---
EOF
echo "file: inbox/agent/tasks/RUN-quick-close-owner-smoke-b.md" >> "$SEM_B"

if CLAUDE_CODE_SESSION_ID="session-B" bash "$GUARD" close --wp WP-484 --slug owner-smoke-b --agent fixture; then
  echo "PASS: matching owner_session_id card satisfies close gate"
else
  echo "FAIL: close rejected a card owned by this same session (session-B)" >&2
  exit 1
fi

# --- Scenario C: card without owner_session_id (legacy) is rejected --------
# when this session's own harness_session_id IS known (narrow fail-closed
# case -- distinct from scenario D, where THIS session's own id is unknown).
CLAUDE_CODE_SESSION_ID="session-C" bash "$GUARD" open --wp WP-484 --task fixture --slug owner-smoke-c --agent fixture >/dev/null
SEM_C=$(grep -l '^slug: owner-smoke-c$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_BASENAME_C=$(grep '^orz_file: ' "$SEM_C" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_BASENAME_C"
git -C "$REPO" add "sessions/$ORZ_BASENAME_C"
git -C "$REPO" commit -qm "orz C"

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-owner-smoke-c.md" <<'EOF'
---
process_id: quick-close
status: completed
---
EOF
echo "file: inbox/agent/tasks/RUN-quick-close-owner-smoke-c.md" >> "$SEM_C"

if CLAUDE_CODE_SESSION_ID="session-C" bash "$GUARD" close --wp WP-484 --slug owner-smoke-c --agent fixture 2>/dev/null; then
  echo "FAIL: close accepted a legacy card without owner_session_id while this session's own id was known" >&2
  exit 1
else
  echo "PASS: legacy card without owner_session_id rejected when this session's own id is known"
fi

# --- Scenario D: this session's own harness_session_id unknown -> fall back
# to unfiltered (pre-fix) behaviour, no regression for the documented Ф118
# race (CLAUDE_CODE_SESSION_ID not yet set at open time).
REPO2="$TEST_ROOT/DS-strategy-noharness"
mkdir -p "$REPO2/sessions" "$REPO2/inbox/agent/tasks" "$REPO2/scripts"
git -C "$REPO2" init -q
git -C "$REPO2" config user.email test@example.com
git -C "$REPO2" config user.name "Test"
cp "$REPO/scripts/process-runner.py" "$REPO2/scripts/process-runner.py"
chmod +x "$REPO2/scripts/process-runner.py"
echo "placeholder" > "$REPO2/sessions/00-index.md"
git -C "$REPO2" add sessions/00-index.md scripts/process-runner.py
git -C "$REPO2" commit -qm init

unset CLAUDE_CODE_SESSION_ID
IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy-noharness" bash "$GUARD" open --wp WP-484 --task fixture --slug owner-smoke-d --agent fixture >/dev/null
SEM_D=$(grep -l '^slug: owner-smoke-d$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
grep -q '^harness_session_id: ' "$SEM_D" && { echo "FAIL: fixture setup — harness_session_id unexpectedly recorded" >&2; exit 1; }
ORZ_BASENAME_D=$(grep '^orz_file: ' "$SEM_D" | cut -d' ' -f2-)
write_orz "$REPO2/sessions/$ORZ_BASENAME_D"
git -C "$REPO2" add "sessions/$ORZ_BASENAME_D"
git -C "$REPO2" commit -qm "orz D"

cat > "$REPO2/inbox/agent/tasks/RUN-quick-close-owner-smoke-d.md" <<'EOF'
---
process_id: quick-close
status: completed
---
EOF
echo "file: inbox/agent/tasks/RUN-quick-close-owner-smoke-d.md" >> "$SEM_D"

if IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy-noharness" bash "$GUARD" close --wp WP-484 --slug owner-smoke-d --agent fixture; then
  echo "PASS: unfiltered (pre-fix) behaviour preserved when this session's own harness_session_id is unknown"
else
  echo "FAIL: close regressed the documented Ф118 no-harness-session-id path" >&2
  exit 1
fi

echo "PASS: session-guard quick-close owner_session_id gate (WP-484 V(b))"
