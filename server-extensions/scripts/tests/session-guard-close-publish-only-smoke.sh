#!/usr/bin/env bash
# Regression for WP-561 F61, pilot decision 1B (16.11): the publish-only bypass
# (WP-537 F30) is retired for agents. `open --close-path publish-only` is
# refused, and a semaphore that still carries the declaration from before the
# ban no longer closes without a terminal card -- it closes like any other
# session. An ordinary session keeps requiring the card as before.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d ${TMPDIR:-/tmp}/session-guard-publish-only.XXXXXX)
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

# Sessions repository of the fixture (WP-526 Ф2): the ORZ file lives there, not in the
# governance repo, and the guard looks for it at the semaphore's orz_sessions_dir.
MC="$TEST_ROOT/MC-sessions"
MC_ORIGIN="$TEST_ROOT/mc-origin.git"
mkdir -p "$MC"
git init --bare -q "$MC_ORIGIN"
git -C "$MC" init -q
git -C "$MC" config user.email test@example.com
git -C "$MC" config user.name "Test"
git -C "$MC" remote add origin "$MC_ORIGIN"
echo fixture > "$MC/README.md"
git -C "$MC" add README.md
git -C "$MC" commit -qm init
git -C "$MC" push -q origin HEAD:main

export IWE_ROOT="$TEST_ROOT"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
export IWE_FROZEN_CANONICAL_PATH=""
export IWE_SESSIONS_ROOT="$MC"

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

# --- Scenario A1: open refuses the retired declaration, no semaphore is left --
OPEN_A_ERR="$TEST_ROOT/open-a.err"
if bash "$GUARD" open --wp WP-484 --task fixture --slug publish-only-a --agent fixture --close-path publish-only 2>"$OPEN_A_ERR" >/dev/null; then
  echo "FAIL: open accepted close_path publish-only" >&2
  exit 1
fi
grep -q 'publish-only запрещён' "$OPEN_A_ERR" || { cat "$OPEN_A_ERR" >&2; echo "FAIL: refusal does not name the ban" >&2; exit 1; }
if grep -lq '^slug: publish-only-a$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open 2>/dev/null; then
  echo "FAIL: refused open still left a semaphore" >&2
  exit 1
fi
echo "PASS: open refuses close_path publish-only and leaves no semaphore"

# --- Scenario A2: a pre-ban publish-only semaphore needs the terminal card ----
bash "$GUARD" open --wp WP-484 --task fixture --slug legacy-a2 --agent fixture >/dev/null
SEM_A2=$(grep -l '^slug: legacy-a2$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
if grep -q '^close_path: ' "$SEM_A2"; then
  sed -i.bak 's/^close_path: .*/close_path: publish-only/' "$SEM_A2" && rm -f "$SEM_A2.bak"
else
  sed -i.bak '1a\
close_path: publish-only' "$SEM_A2" && rm -f "$SEM_A2.bak"
fi
grep -q '^close_path: publish-only$' "$SEM_A2" || { echo "FAIL: fixture setup — legacy close_path not written" >&2; exit 1; }
ORZ_A2=$(grep '^orz_file: ' "$SEM_A2" | cut -d' ' -f2-)
ORZ_DIR_A2=$(sed -n 's/^orz_sessions_dir: //p' "$SEM_A2")
write_orz "$ORZ_DIR_A2/$ORZ_A2"
git -C "$MC" add "$ORZ_A2"
git -C "$MC" commit -qm "orz legacy a2"
git -C "$MC" push -q origin HEAD:main

CLOSE_A2_ERR="$TEST_ROOT/close-a2.err"
if bash "$GUARD" close --wp WP-484 --slug legacy-a2 --agent fixture 2>"$CLOSE_A2_ERR"; then
  echo "FAIL: a pre-ban publish-only semaphore closed without a terminal card" >&2
  exit 1
fi
if ! grep -q 'нет terminal RUN-quick-close' "$CLOSE_A2_ERR"; then
  cat "$CLOSE_A2_ERR" >&2
  echo "FAIL: close refused the pre-ban semaphore for an unexpected reason" >&2
  exit 1
fi
if grep -q 'close_path=publish-only объявлен' "$CLOSE_A2_ERR"; then
  echo "FAIL: close still announced the retired publish-only bypass" >&2
  exit 1
fi
echo "PASS: a pre-ban publish-only semaphore closes like any other session (card required)"

# --- Scenario B: a session with NO close_path (ordinary interactive isolate
# open) still requires the normal terminal card -- the new branch must not
# accidentally widen to sessions that never declared publish-only. ---------
bash "$GUARD" open --wp WP-484 --task fixture --slug ordinary-b --agent fixture >/dev/null
SEM_B=$(grep -l '^slug: ordinary-b$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
grep -qE '^close_path: (publish-only|peer-session)$' "$SEM_B" && { echo "FAIL: fixture setup — ordinary open unexpectedly declared a bypass close_path" >&2; exit 1; }
ORZ_B=$(grep '^orz_file: ' "$SEM_B" | cut -d' ' -f2-)
ORZ_DIR_B=$(sed -n 's/^orz_sessions_dir: //p' "$SEM_B")
write_orz "$ORZ_DIR_B/$ORZ_B"
git -C "$MC" add "$ORZ_B"
git -C "$MC" commit -qm "orz ordinary b"

if bash "$GUARD" close --wp WP-484 --slug ordinary-b --agent fixture 2>/dev/null; then
  echo "FAIL: close accepted a session with no close_path and no terminal card at all" >&2
  exit 1
else
  echo "PASS: an ordinary session without close_path still requires the normal terminal card"
fi

echo "PASS: session-guard publish-only ban (WP-561 Ф61, 1Б)"
