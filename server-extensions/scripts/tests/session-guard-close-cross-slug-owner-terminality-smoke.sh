#!/usr/bin/env bash
# Regression for WP-537 Ф25.1 (06.09) / Ф26 (07.09, РП-529): a single harness
# session republishing several times under canon-freeze opens a fresh
# semaphore/slug per `open --isolate` call, but process-runner.py resolves the
# quick-close obligation by owner (harness_session_id), not by slug -- only
# the FIRST slug's `start quick-close` run actually gets a terminal
# RUN-quick-close-<slug>*.md card; later slugs of the same conversation see
# "already_completed" and reuse that first card. Before this fix, session-guard
# close's slug-only glob left those later slugs' semaphores permanently open
# ("осиротевший семафор"). Fix: when no card matches THIS slug, fall back to
# any completed quick-close card owned by the same harness_session_id,
# regardless of its slug (peer-session 2026-09-07-13-parallel-session-close,
# Kimi+Codex consensus: owner-terminality as a defensive second layer on top
# of the existing slug check, not a replacement for it).
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-cross-slug-owner.XXXXXX)
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

publish_head() {
  git -C "$REPO" push -q origin HEAD:main
}

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

# --- Scenario A: second slug of the same conversation, no card of its own,
# but a completed card of an EARLIER slug shares this session's
# owner_session_id -- close must succeed via the new fallback. -------------
CLAUDE_CODE_SESSION_ID="convo-A" bash "$GUARD" open --wp WP-484 --task fixture --slug cross-slug-a-first --agent fixture >/dev/null
SEM_FIRST=$(grep -l '^slug: cross-slug-a-first$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_FIRST=$(grep '^orz_file: ' "$SEM_FIRST" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_FIRST"
git -C "$REPO" add "sessions/$ORZ_FIRST"
git -C "$REPO" commit -qm "orz first slug"
publish_head
cat > "$REPO/inbox/agent/tasks/RUN-quick-close-cross-slug-a-first.md" <<'EOF'
---
process_id: quick-close
run_id: quick-close-cross-slug-a-first
requested_slug: cross-slug-a-first
status: completed
current_step: done
owner_session_id: convo-A
results:
  gather-session-facts:
    wp: WP-484
---
EOF
echo "file: inbox/agent/tasks/RUN-quick-close-cross-slug-a-first.md" >> "$SEM_FIRST"
IWE_AGENT=fixture bash "$GUARD" close --wp WP-484 --slug cross-slug-a-first --agent fixture >/dev/null

CLAUDE_CODE_SESSION_ID="convo-A" bash "$GUARD" open --wp WP-484 --task fixture --slug cross-slug-a-second --agent fixture >/dev/null
SEM_SECOND=$(grep -l '^slug: cross-slug-a-second$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_SECOND=$(grep '^orz_file: ' "$SEM_SECOND" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_SECOND"
git -C "$REPO" add "sessions/$ORZ_SECOND"
git -C "$REPO" commit -qm "orz second slug"
publish_head
# No RUN-quick-close-cross-slug-a-second*.md is ever written -- this is the
# exact recidivism: process-runner already answered "already_completed" and
# reused the first slug's card instead of writing a new one.

CLOSE_A_ERR="$TEST_ROOT/close-a.err"
if CLAUDE_CODE_SESSION_ID="convo-A" bash "$GUARD" close --wp WP-484 --slug cross-slug-a-second --agent fixture 2>"$CLOSE_A_ERR"; then
  # Exit code alone cannot tell this branch from any other accepting branch:
  # the fallback's own stderr line is the observable effect under test.
  if grep -q 'owner-terminality' "$CLOSE_A_ERR"; then
    echo "PASS: second slug of the same conversation closes via cross-slug owner-terminality fallback"
  else
    echo "FAIL: close succeeded, but not through the owner-terminality fallback (no marker on stderr)" >&2
    cat "$CLOSE_A_ERR" >&2
    exit 1
  fi
else
  cat "$CLOSE_A_ERR" >&2
  echo "FAIL: second slug's semaphore stayed orphaned despite a completed card of the same conversation (WP-537 Ф25.1/Ф26 regression)" >&2
  exit 1
fi

# --- Scenario B: second slug, but the only completed card found under a
# different slug belongs to a FOREIGN conversation -- must NOT satisfy. ----
CLAUDE_CODE_SESSION_ID="convo-B" bash "$GUARD" open --wp WP-484 --task fixture --slug cross-slug-b-orphan --agent fixture >/dev/null
SEM_B=$(grep -l '^slug: cross-slug-b-orphan$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_B=$(grep '^orz_file: ' "$SEM_B" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_B"
git -C "$REPO" add "sessions/$ORZ_B"
git -C "$REPO" commit -qm "orz scenario B"
# A completed card exists (from scenario A, convo-A) but none for convo-B.

if CLAUDE_CODE_SESSION_ID="convo-B" bash "$GUARD" close --wp WP-484 --slug cross-slug-b-orphan --agent fixture 2>/dev/null; then
  echo "FAIL: close accepted a completed card owned by a foreign conversation (convo-A != convo-B)" >&2
  exit 1
else
  echo "PASS: completed card of a foreign conversation does not satisfy a different conversation's close gate"
fi

# --- Scenario C: second slug, a card exists for a different slug of the SAME
# owner but its status is not completed -- must NOT satisfy. ---------------
CLAUDE_CODE_SESSION_ID="convo-C" bash "$GUARD" open --wp WP-484 --task fixture --slug cross-slug-c-first --agent fixture >/dev/null
SEM_C1=$(grep -l '^slug: cross-slug-c-first$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_C1=$(grep '^orz_file: ' "$SEM_C1" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_C1"
git -C "$REPO" add "sessions/$ORZ_C1"
git -C "$REPO" commit -qm "orz scenario C first"
cat > "$REPO/inbox/agent/tasks/RUN-quick-close-cross-slug-c-first.md" <<'EOF'
---
process_id: quick-close
status: cancelled
owner_session_id: convo-C
current_step: commit-push
---
EOF

CLAUDE_CODE_SESSION_ID="convo-C" bash "$GUARD" open --wp WP-484 --task fixture --slug cross-slug-c-second --agent fixture >/dev/null
SEM_C2=$(grep -l '^slug: cross-slug-c-second$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_C2=$(grep '^orz_file: ' "$SEM_C2" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_C2"
git -C "$REPO" add "sessions/$ORZ_C2"
git -C "$REPO" commit -qm "orz scenario C second"

if CLAUDE_CODE_SESSION_ID="convo-C" bash "$GUARD" close --wp WP-484 --slug cross-slug-c-second --agent fixture 2>/dev/null; then
  echo "FAIL: close accepted a non-completed (cancelled) card of the same conversation under a different slug" >&2
  exit 1
else
  echo "PASS: a non-completed card of the same conversation under a different slug does not satisfy close"
fi

# --- Scenario D (cold-review, Critical, 07.09): same owner_session_id,
# completed, but for a DIFFERENT WP -- must NOT satisfy. One long harness
# conversation can legitimately quick-close WP-484 and later, in the same
# conversation, open a session for an unrelated WP-999; the WP-484 card must
# not be allowed to vouch for WP-999's close. Card's nested wp field uses the
# bare-number form ('999', no "WP-" prefix) to also exercise the format
# variance found on real cards (results.wp-context-update.wp) alongside the
# "WP-484" form already covered in scenario A. ------------------------------
CLAUDE_CODE_SESSION_ID="convo-D" bash "$GUARD" open --wp WP-484 --task fixture --slug cross-slug-d-first --agent fixture >/dev/null
SEM_D1=$(grep -l '^slug: cross-slug-d-first$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_D1=$(grep '^orz_file: ' "$SEM_D1" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_D1"
git -C "$REPO" add "sessions/$ORZ_D1"
git -C "$REPO" commit -qm "orz scenario D first (WP-999)"
cat > "$REPO/inbox/agent/tasks/RUN-quick-close-cross-slug-d-first.md" <<'EOF'
---
process_id: quick-close
run_id: quick-close-cross-slug-d-first
requested_slug: cross-slug-d-first
status: completed
current_step: done
owner_session_id: convo-D
results:
  wp-context-update:
    wp: '999'
---
EOF

CLAUDE_CODE_SESSION_ID="convo-D" bash "$GUARD" open --wp WP-484 --task fixture --slug cross-slug-d-second --agent fixture >/dev/null
SEM_D2=$(grep -l '^slug: cross-slug-d-second$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_D2=$(grep '^orz_file: ' "$SEM_D2" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_D2"
git -C "$REPO" add "sessions/$ORZ_D2"
git -C "$REPO" commit -qm "orz scenario D second (WP-484)"

if CLAUDE_CODE_SESSION_ID="convo-D" bash "$GUARD" close --wp WP-484 --slug cross-slug-d-second --agent fixture 2>/dev/null; then
  echo "FAIL: close for WP-484 accepted a completed card of the same conversation issued for a DIFFERENT WP (WP-999)" >&2
  exit 1
else
  echo "PASS: a completed card of the same conversation for a different WP does not satisfy this WP's close gate"
fi

# --- Scenario E (Fable review 07.09, High): live card shape -- the runner was
# started without --wp, so results.gather-session-facts.wp is '' and the real
# WP lives only in results.wp-context-update.wp (28% of real completed cards).
# The fallback must read the second key when the first is empty. -----------
CLAUDE_CODE_SESSION_ID="convo-E" bash "$GUARD" open --wp WP-484 --task fixture --slug cross-slug-e-first --agent fixture >/dev/null
SEM_E1=$(grep -l '^slug: cross-slug-e-first$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_E1=$(grep '^orz_file: ' "$SEM_E1" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_E1"
git -C "$REPO" add "sessions/$ORZ_E1"
git -C "$REPO" commit -qm "orz scenario E first"
cat > "$REPO/inbox/agent/tasks/RUN-quick-close-cross-slug-e-first.md" <<'EOF'
---
process_id: quick-close
run_id: quick-close-cross-slug-e-first
requested_slug: cross-slug-e-first
status: completed
current_step: done
owner_session_id: convo-E
results:
  gather-session-facts:
    agent: claude-code
    wp: ''
    slug: cross-slug-e-first
  wp-context-update:
    wp: WP-484
---
EOF

CLAUDE_CODE_SESSION_ID="convo-E" bash "$GUARD" open --wp WP-484 --task fixture --slug cross-slug-e-second --agent fixture >/dev/null
SEM_E2=$(grep -l '^slug: cross-slug-e-second$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_E2=$(grep '^orz_file: ' "$SEM_E2" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_E2"
git -C "$REPO" add "sessions/$ORZ_E2"
git -C "$REPO" commit -qm "orz scenario E second"
publish_head

CLOSE_E_ERR="$TEST_ROOT/close-e.err"
if CLAUDE_CODE_SESSION_ID="convo-E" bash "$GUARD" close --wp WP-484 --slug cross-slug-e-second --agent fixture 2>"$CLOSE_E_ERR" \
   && grep -q 'owner-terminality' "$CLOSE_E_ERR"; then
  echo "PASS: card with empty gather-session-facts.wp is matched through wp-context-update.wp"
else
  cat "$CLOSE_E_ERR" >&2
  echo "FAIL: fallback silently skipped a real-shaped card (gather wp '' + context-update wp WP-484)" >&2
  exit 1
fi

# --- Scenario H (Fable review 07.09, High): THIS slug has its own card, but
# it is cancelled at commit-push (push never happened, tail of the pipeline
# never ran). An older completed card of the same owner+WP must NOT mask it:
# the slug's own diagnostic ("отменена на шаге 'commit-push'") must win. ----
CLAUDE_CODE_SESSION_ID="convo-H" bash "$GUARD" open --wp WP-484 --task fixture --slug cross-slug-h-first --agent fixture >/dev/null
SEM_H1=$(grep -l '^slug: cross-slug-h-first$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_H1=$(grep '^orz_file: ' "$SEM_H1" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_H1"
git -C "$REPO" add "sessions/$ORZ_H1"
git -C "$REPO" commit -qm "orz scenario H first"
cat > "$REPO/inbox/agent/tasks/RUN-quick-close-cross-slug-h-first.md" <<'EOF'
---
process_id: quick-close
run_id: quick-close-cross-slug-h-first
requested_slug: cross-slug-h-first
status: completed
current_step: done
owner_session_id: convo-H
results:
  gather-session-facts:
    wp: WP-484
---
EOF

CLAUDE_CODE_SESSION_ID="convo-H" bash "$GUARD" open --wp WP-484 --task fixture --slug cross-slug-h-second --agent fixture >/dev/null
SEM_H2=$(grep -l '^slug: cross-slug-h-second$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_H2=$(grep '^orz_file: ' "$SEM_H2" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_H2"
git -C "$REPO" add "sessions/$ORZ_H2"
git -C "$REPO" commit -qm "orz scenario H second"
cat > "$REPO/inbox/agent/tasks/RUN-quick-close-cross-slug-h-second.md" <<'EOF'
---
process_id: quick-close
status: cancelled
current_step: commit-push
owner_session_id: convo-H
results:
  gather-session-facts:
    wp: WP-484
---
EOF

CLOSE_H_ERR="$TEST_ROOT/close-h.err"
if CLAUDE_CODE_SESSION_ID="convo-H" bash "$GUARD" close --wp WP-484 --slug cross-slug-h-second --agent fixture 2>"$CLOSE_H_ERR"; then
  echo "FAIL: an older completed card masked this slug's own cancelled@commit-push card" >&2
  exit 1
elif grep -q "отменена на шаге 'commit-push'" "$CLOSE_H_ERR"; then
  echo "PASS: slug's own cancelled card wins over an older completed card of the same owner (no masking)"
else
  cat "$CLOSE_H_ERR" >&2
  echo "FAIL: close refused, but not with the slug's own commit-push diagnostic" >&2
  exit 1
fi

echo "PASS: session-guard cross-slug owner-terminality fallback (WP-537 Ф25.1/Ф26/Ф28)"
