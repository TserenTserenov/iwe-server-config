#!/usr/bin/env bash
# Regression for WP-537 Ф29 (07.09, decided by the pilot after Fable's review
# of Ф28/Ф28.1): the owner+WP heuristic guessed which completed card
# satisfies a slug with no card of its own. process-runner.py now KNOWS this
# directly -- whenever cmd_start() returns "already_completed" for a slug
# (same-slug reuse, or the cross-slug stale_run_id evacuation path), it writes
# a marker naming the run_id that satisfied THAT slug
# (_write_slug_satisfied_marker(), RUNTIME_DIR/quick-close-slug-satisfied/
# quick-close-<slug>.satisfied_by). session-guard.sh close reads that marker
# BEFORE falling back to the owner+WP heuristic -- no guessing needed when the
# runner already recorded the fact.
#
# Ф29.1 (08.09, final cold review before closing this session, Critical): the
# marker's key is the bare slug, with no owner binding, and the file was never
# deleted -- a slug collision between unrelated conversations (already a
# documented real risk for V(b)/Ф28) let a stranger's marker satisfy this
# close, and a marker outlived its own conversation forever. The read side
# now checks owner_session_id and WP the same way Ф28 does, and deletes the
# marker after a successful match.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-slug-marker.XXXXXX)
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
date: 2026-09-07
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

write_marker() {  # <slug> <run_id>
  local dir="$TEST_ROOT/.iwe-runtime/quick-close-slug-satisfied"
  mkdir -p "$dir"
  printf '%s' "$2" > "$dir/quick-close-$1.satisfied_by"
}

# --- Scenario A: marker names a run_id under a DIFFERENT slug, matching
# owner+WP -- and the marker file is gone after a successful match. ---------
CLAUDE_CODE_SESSION_ID="convo-A" bash "$GUARD" open --wp WP-484 --task fixture --slug marker-a-first --agent fixture >/dev/null
SEM_A1=$(grep -l '^slug: marker-a-first$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_A1=$(grep '^orz_file: ' "$SEM_A1" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_A1"
git -C "$REPO" add "sessions/$ORZ_A1"
git -C "$REPO" commit -qm "orz marker-a first"
cat > "$REPO/inbox/agent/tasks/RUN-quick-close-marker-a-first.md" <<'EOF'
---
process_id: quick-close
status: completed
run_id: quick-close-marker-a-first
requested_slug: marker-a-first
current_step: done
owner_session_id: convo-A
results:
  gather-session-facts:
    wp: WP-484
---
EOF

CLAUDE_CODE_SESSION_ID="convo-A" bash "$GUARD" open --wp WP-484 --task fixture --slug marker-a-second --agent fixture >/dev/null
SEM_A2=$(grep -l '^slug: marker-a-second$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_A2=$(grep '^orz_file: ' "$SEM_A2" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_A2"
git -C "$REPO" add "sessions/$ORZ_A2"
git -C "$REPO" commit -qm "orz marker-a second"
git -C "$REPO" push -q origin HEAD:main
# process-runner.py already recorded that marker-a-second's obligation was
# satisfied by the FIRST slug's run -- no card is ever written for the
# second slug at all.
MARKER_A2="$TEST_ROOT/.iwe-runtime/quick-close-slug-satisfied/quick-close-marker-a-second.satisfied_by"
write_marker "marker-a-second" "quick-close-marker-a-first"

CLOSE_A_ERR="$TEST_ROOT/close-a.err"
if CLAUDE_CODE_SESSION_ID="convo-A" bash "$GUARD" close --wp WP-484 --slug marker-a-second --agent fixture 2>"$CLOSE_A_ERR" \
   && grep -q 'slug-satisfied marker' "$CLOSE_A_ERR"; then
  if [ -f "$MARKER_A2" ]; then
    echo "FAIL: marker file was not deleted after a successful match (would outlive this conversation forever)" >&2
    exit 1
  fi
  echo "PASS: marker naming a differently-slugged run_id with matching owner+WP closes, marker deleted after use"
else
  cat "$CLOSE_A_ERR" >&2
  echo "FAIL: close did not accept the slug-satisfied marker" >&2
  exit 1
fi

# --- Scenario B: marker exists but its run_id's card is not completed ------
CLAUDE_CODE_SESSION_ID="convo-B" bash "$GUARD" open --wp WP-484 --task fixture --slug marker-b-first --agent fixture >/dev/null
SEM_B1=$(grep -l '^slug: marker-b-first$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_B1=$(grep '^orz_file: ' "$SEM_B1" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_B1"
git -C "$REPO" add "sessions/$ORZ_B1"
git -C "$REPO" commit -qm "orz marker-b first"
cat > "$REPO/inbox/agent/tasks/RUN-quick-close-marker-b-first.md" <<'EOF'
---
process_id: quick-close
status: running
run_id: quick-close-marker-b-first
---
EOF

CLAUDE_CODE_SESSION_ID="convo-B" bash "$GUARD" open --wp WP-484 --task fixture --slug marker-b-second --agent fixture >/dev/null
SEM_B2=$(grep -l '^slug: marker-b-second$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_B2=$(grep '^orz_file: ' "$SEM_B2" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_B2"
git -C "$REPO" add "sessions/$ORZ_B2"
git -C "$REPO" commit -qm "orz marker-b second"
write_marker "marker-b-second" "quick-close-marker-b-first"

if CLAUDE_CODE_SESSION_ID="convo-B" bash "$GUARD" close --wp WP-484 --slug marker-b-second --agent fixture 2>/dev/null; then
  echo "FAIL: close accepted a marker pointing at a non-completed card" >&2
  exit 1
else
  echo "PASS: marker pointing at a non-completed card does not satisfy close"
fi

# --- Scenario C: marker names a run_id with no card on disk at all (torn
# write, cleanup race) -- must not crash, falls through to next branch. ----
CLAUDE_CODE_SESSION_ID="convo-C" bash "$GUARD" open --wp WP-484 --task fixture --slug marker-c-second --agent fixture >/dev/null
SEM_C2=$(grep -l '^slug: marker-c-second$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_C2=$(grep '^orz_file: ' "$SEM_C2" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_C2"
git -C "$REPO" add "sessions/$ORZ_C2"
git -C "$REPO" commit -qm "orz marker-c second"
write_marker "marker-c-second" "quick-close-marker-c-nonexistent"

if CLAUDE_CODE_SESSION_ID="convo-C" bash "$GUARD" close --wp WP-484 --slug marker-c-second --agent fixture 2>/dev/null; then
  echo "FAIL: close accepted a marker pointing at a card that does not exist" >&2
  exit 1
else
  echo "PASS: marker pointing at a missing card falls through cleanly (no crash)"
fi

# --- Scenario D (Ф29.1, Critical): marker points at a completed card of a
# FOREIGN owner -- must NOT satisfy (the actual defect: unbound marker key
# lets a stranger's leftover marker close someone else's session). --------
CLAUDE_CODE_SESSION_ID="convo-D-victim" bash "$GUARD" open --wp WP-484 --task fixture --slug marker-d-victim --agent fixture >/dev/null
SEM_D=$(grep -l '^slug: marker-d-victim$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_D=$(grep '^orz_file: ' "$SEM_D" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_D"
git -C "$REPO" add "sessions/$ORZ_D"
git -C "$REPO" commit -qm "orz marker-d victim"
cat > "$REPO/inbox/agent/tasks/RUN-quick-close-marker-d-stranger.md" <<'EOF'
---
process_id: quick-close
status: completed
run_id: quick-close-marker-d-stranger
requested_slug: marker-d-stranger
current_step: done
owner_session_id: convo-D-stranger
results:
  gather-session-facts:
    wp: WP-484
---
EOF
# A stale/leftover marker with the SAME key as this victim session's slug --
# e.g. a slug string reused weeks apart, or a coincidental collision (the
# same class of risk already documented for V(b)/Ф28).
write_marker "marker-d-victim" "quick-close-marker-d-stranger"

if CLAUDE_CODE_SESSION_ID="convo-D-victim" bash "$GUARD" close --wp WP-484 --slug marker-d-victim --agent fixture 2>/dev/null; then
  echo "FAIL: a foreign owner's marker satisfied this session's close (Ф29.1 regression)" >&2
  exit 1
else
  echo "PASS: marker pointing at a foreign owner's completed card does not satisfy close"
fi

# --- Scenario E (Ф29.1): marker points at a completed card of the SAME
# owner but a DIFFERENT WP -- must NOT satisfy (same class as the Ф28.1
# cross-WP Critical, now checked on the marker path too). -------------------
CLAUDE_CODE_SESSION_ID="convo-E" bash "$GUARD" open --wp WP-999 --task fixture --slug marker-e-first --agent fixture >/dev/null
SEM_E1=$(grep -l '^slug: marker-e-first$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_E1=$(grep '^orz_file: ' "$SEM_E1" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_E1"
git -C "$REPO" add "sessions/$ORZ_E1"
git -C "$REPO" commit -qm "orz marker-e first (WP-999)"
cat > "$REPO/inbox/agent/tasks/RUN-quick-close-marker-e-first.md" <<'EOF'
---
process_id: quick-close
status: completed
run_id: quick-close-marker-e-first
requested_slug: marker-e-first
current_step: done
owner_session_id: convo-E
results:
  gather-session-facts:
    wp: WP-999
---
EOF

CLAUDE_CODE_SESSION_ID="convo-E" bash "$GUARD" open --wp WP-484 --task fixture --slug marker-e-second --agent fixture >/dev/null
SEM_E2=$(grep -l '^slug: marker-e-second$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_E2=$(grep '^orz_file: ' "$SEM_E2" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_E2"
git -C "$REPO" add "sessions/$ORZ_E2"
git -C "$REPO" commit -qm "orz marker-e second (WP-484)"
write_marker "marker-e-second" "quick-close-marker-e-first"

if CLAUDE_CODE_SESSION_ID="convo-E" bash "$GUARD" close --wp WP-484 --slug marker-e-second --agent fixture 2>/dev/null; then
  echo "FAIL: close for WP-484 accepted a marker pointing at a completed card issued for WP-999" >&2
  exit 1
else
  echo "PASS: marker pointing at a same-owner card for a different WP does not satisfy this WP's close gate"
fi

echo "PASS: session-guard slug-satisfied marker fallback (WP-537 Ф29/Ф29.1)"
