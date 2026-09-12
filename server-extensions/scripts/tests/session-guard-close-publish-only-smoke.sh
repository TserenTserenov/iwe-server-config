#!/usr/bin/env bash
# Regression for WP-537 Ф30 (08.09, ArchGate decision after Fable's review of
# Ф28/Ф28.1, advice from Kimi+Codex): `open --close-path publish-only` lets a
# short, service-only isolated session (opened SOLELY to push one commit out
# from under canon freeze) close without a quick-close RUN card -- the same
# pattern already proven for `close_path: peer-session` (WP-484 Ф118). This
# prevents the Ф25.1/Ф26 orphaned-semaphore class at its source (no full
# session is ever created for a pure publish) rather than only curing it
# after the fact (Ф28/Ф29's marker/heuristic fallbacks, which stay as a
# defensive layer for callers that forget to pass the new flag).
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-publish-only.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/DS-strategy"
ORIGIN="$TEST_ROOT/origin.git"
mkdir -p "$REPO/sessions" "$REPO/inbox/agent/tasks" "$REPO/scripts"
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

export IWE_ROOT="$TEST_ROOT"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
export IWE_FROZEN_CANONICAL_PATH=""

write_orz() {
  local orz_path="$1"
  mkdir -p "$(dirname "$orz_path")"
  cat > "$orz_path" <<'EOF'
---
date: 2026-09-08
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

# --- Scenario A: publish-only session closes with no RUN card at all ------
bash "$GUARD" open --wp WP-484 --task fixture --slug publish-only-a --agent fixture --close-path publish-only >/dev/null
SEM_A=$(grep -l '^slug: publish-only-a$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
grep -q '^close_path: publish-only$' "$SEM_A" || { echo "FAIL: fixture setup — close_path not recorded in semaphore" >&2; exit 1; }
ORZ_A=$(grep '^orz_file: ' "$SEM_A" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_A"
git -C "$REPO" add "sessions/$ORZ_A"
git -C "$REPO" commit -qm "orz publish-only a"
git -C "$REPO" push -q origin HEAD:main

CLOSE_A_ERR="$TEST_ROOT/close-a.err"
if bash "$GUARD" close --wp WP-484 --slug publish-only-a --agent fixture 2>"$CLOSE_A_ERR" \
   && grep -q 'close_path=publish-only' "$CLOSE_A_ERR"; then
  echo "PASS: publish-only session closes with no quick-close RUN card at all"
else
  cat "$CLOSE_A_ERR" >&2
  echo "FAIL: publish-only close_path did not bypass the runner requirement" >&2
  exit 1
fi

# --- Scenario B: a session with NO close_path (ordinary interactive isolate
# open) still requires the normal terminal card -- the new branch must not
# accidentally widen to sessions that never declared publish-only. ---------
bash "$GUARD" open --wp WP-484 --task fixture --slug ordinary-b --agent fixture >/dev/null
SEM_B=$(grep -l '^slug: ordinary-b$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
grep -qE '^close_path: (publish-only|peer-session)$' "$SEM_B" && { echo "FAIL: fixture setup — ordinary open unexpectedly declared a bypass close_path" >&2; exit 1; }
ORZ_B=$(grep '^orz_file: ' "$SEM_B" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_B"
git -C "$REPO" add "sessions/$ORZ_B"
git -C "$REPO" commit -qm "orz ordinary b"

if bash "$GUARD" close --wp WP-484 --slug ordinary-b --agent fixture 2>/dev/null; then
  echo "FAIL: close accepted a session with no close_path and no terminal card at all" >&2
  exit 1
else
  echo "PASS: an ordinary session without close_path still requires the normal terminal card"
fi

echo "PASS: session-guard close_path=publish-only bypass (WP-537 Ф30)"
