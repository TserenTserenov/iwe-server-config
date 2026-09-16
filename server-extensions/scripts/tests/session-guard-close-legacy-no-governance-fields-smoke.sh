#!/usr/bin/env bash
# Regression for WP-484 (14.09, peer-session 2026-09-14-09 + pilot-directed
# fix): semaphore_governance_worktree() requires one of governance_worktree/
# isolated_worktree/orz_sessions_dir to be present (added e2d3a2423e, 12.09).
# A semaphore opened by a session-guard.sh copy older than that -- confirmed
# live twice the same day, including on this very peer session's own
# semaphore -- carries none of the three and close() failed closed with
# "governance checkout не доказан" (exit 7) even though the session was
# perfectly ordinary (non-isolated, canonical checkout, fully published).
# Fix: for a non-isolated session (isolated_worktree unset), fall back to the
# canonical checkout, mirroring the fallback session_scope_dirty_paths()
# already applies at the scope-check step.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-legacy-no-governance.XXXXXX)
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

# MC-sessions (WP-526 Ф2): open()'s global $ORZ_DIR resolves here whenever
# this directory exists as a git repo, exactly like the real production
# checkout that produced both live incidents this test reproduces -- writing
# the fixture ORZ into DS-strategy/sessions instead (the pre-WP-526 legacy
# layout) would test a layout that no longer matches what open() itself does.
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

write_orz() {
  local orz_path="$1"
  mkdir -p "$(dirname "$orz_path")"
  cat > "$orz_path" <<'EOF'
---
date: 2026-09-14
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

# --- Scenario A: ordinary open, then strip the three governance fields to
# reproduce a semaphore opened by a pre-e2d3a2423e copy of session-guard.sh.
# Close of an otherwise perfectly ordinary, fully-published session must not
# fail on "governance checkout не доказан".
CLAUDE_CODE_SESSION_ID="session-A" bash "$GUARD" open --wp WP-484 --task fixture --slug legacy-a --agent fixture >/dev/null
SEM_A=$(grep -l '^slug: legacy-a$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
grep -qE '^(governance_worktree|isolated_worktree|orz_sessions_dir): ' "$SEM_A" \
  || { echo "FAIL: fixture setup — current open() did not write any governance field, nothing to strip" >&2; exit 1; }
ORZ_BASENAME_A=$(grep '^orz_file: ' "$SEM_A" | cut -d' ' -f2-)
write_orz "$SESSIONS/$ORZ_BASENAME_A"
git -C "$SESSIONS" add "$ORZ_BASENAME_A"
git -C "$SESSIONS" commit -qm "orz A"
git -C "$SESSIONS" push -q origin HEAD:main

grep -vE '^(governance_worktree|isolated_worktree|orz_sessions_dir): ' "$SEM_A" > "$SEM_A.stripped"
mv "$SEM_A.stripped" "$SEM_A"
grep -qE '^(governance_worktree|isolated_worktree|orz_sessions_dir): ' "$SEM_A" \
  && { echo "FAIL: fixture setup — governance fields still present after stripping" >&2; exit 1; }

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-legacy-a.md" <<'EOF'
---
process_id: quick-close
run_id: quick-close-legacy-a
requested_slug: legacy-a
status: completed
current_step: done
owner_session_id: session-A
results:
  gather-session-facts:
    wp: WP-484
---
EOF
echo "file: inbox/agent/tasks/RUN-quick-close-legacy-a.md" >> "$SEM_A"

if CLOSE_OUT=$(CLAUDE_CODE_SESSION_ID="session-A" bash "$GUARD" close --wp WP-484 --slug legacy-a --agent fixture 2>&1); then
  echo "PASS: close of a legacy semaphore (no governance/isolated/orz_sessions_dir field) falls back to canonical and succeeds"
else
  if grep -q 'governance checkout не доказан' <<<"$CLOSE_OUT"; then
    echo "FAIL: close still rejects a legacy semaphore with 'governance checkout не доказан': $CLOSE_OUT" >&2
  else
    echo "FAIL: close rejected the legacy semaphore for an unrelated reason (fixture may need updating): $CLOSE_OUT" >&2
  fi
  exit 1
fi

# --- Scenario B (regression, must stay caught): a session that DID claim an
# isolated_worktree but the field is stripped away must still fail closed --
# this fallback only ever applies to a session with NO isolation claim at
# all, never as a silent substitute for a missing isolated_worktree.
ISO="$TEST_ROOT/iso-legacy-b"
git clone -q "$REPO" "$ISO"
git -C "$ISO" config user.email iso@test
git -C "$ISO" config user.name iso

CLAUDE_CODE_SESSION_ID="session-B" bash "$GUARD" open --wp WP-484 --task fixture --slug legacy-b --agent fixture >/dev/null
SEM_B=$(grep -l '^slug: legacy-b$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_BASENAME_B=$(grep '^orz_file: ' "$SEM_B" | cut -d' ' -f2-)
write_orz "$SESSIONS/$ORZ_BASENAME_B"
git -C "$SESSIONS" add "$ORZ_BASENAME_B"
git -C "$SESSIONS" commit -qm "orz B"
git -C "$SESSIONS" push -q origin HEAD:main

grep -vE '^(governance_worktree|isolated_worktree|orz_sessions_dir): ' "$SEM_B" > "$SEM_B.stripped"
printf 'isolated_worktree: %s\n' "$ISO" >> "$SEM_B.stripped"
mv "$SEM_B.stripped" "$SEM_B"

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-legacy-b.md" <<'EOF'
---
process_id: quick-close
run_id: quick-close-legacy-b
requested_slug: legacy-b
status: completed
current_step: done
owner_session_id: session-B
results:
  gather-session-facts:
    wp: WP-484
---
EOF
echo "file: inbox/agent/tasks/RUN-quick-close-legacy-b.md" >> "$SEM_B"

if CLOSE_OUT=$(CLAUDE_CODE_SESSION_ID="session-B" bash "$GUARD" close --wp WP-484 --slug legacy-b --agent fixture 2>&1); then
  echo "FAIL: close of a claimed-but-unresolvable isolated_worktree must not silently fall back to canonical: $CLOSE_OUT" >&2
  exit 1
else
  echo "PASS: a claimed isolated_worktree that can't be resolved is never masked by the canonical fallback"
fi

# --- Scenario C (cold-review finding, Codex): a MODERN, non-isolated
# semaphore naming an independent governance_worktree that has since become
# unresolvable (removed) must stay fail-closed -- semaphore_governance_worktree()
# returning empty here is a structural field present with a broken value, not
# a legacy field structurally absent, and must never be papered over by
# substituting canonical: that checkout never actually owned this session's
# scope, so its publish proof would be meaningless for this session.
GONE="$TEST_ROOT/gone-clone-legacy-c"
git clone -q "$REPO" "$GONE"
rm -rf "$GONE"

CLAUDE_CODE_SESSION_ID="session-C" bash "$GUARD" open --wp WP-484 --task fixture --slug legacy-c --agent fixture >/dev/null
SEM_C=$(grep -l '^slug: legacy-c$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_BASENAME_C=$(grep '^orz_file: ' "$SEM_C" | cut -d' ' -f2-)
write_orz "$SESSIONS/$ORZ_BASENAME_C"
git -C "$SESSIONS" add "$ORZ_BASENAME_C"
git -C "$SESSIONS" commit -qm "orz C"
git -C "$SESSIONS" push -q origin HEAD:main

grep -vE '^(governance_worktree|isolated_worktree|orz_sessions_dir): ' "$SEM_C" > "$SEM_C.stripped"
printf 'governance_worktree: %s\n' "$GONE" >> "$SEM_C.stripped"
mv "$SEM_C.stripped" "$SEM_C"

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-legacy-c.md" <<'EOF'
---
process_id: quick-close
run_id: quick-close-legacy-c
requested_slug: legacy-c
status: completed
current_step: done
owner_session_id: session-C
results:
  gather-session-facts:
    wp: WP-484
---
EOF
echo "file: inbox/agent/tasks/RUN-quick-close-legacy-c.md" >> "$SEM_C"

if CLOSE_OUT=$(CLAUDE_CODE_SESSION_ID="session-C" bash "$GUARD" close --wp WP-484 --slug legacy-c --agent fixture 2>&1); then
  echo "FAIL: close must not fall back to canonical when governance_worktree IS present but unresolvable: $CLOSE_OUT" >&2
  exit 1
elif grep -q 'governance checkout не доказан' <<<"$CLOSE_OUT"; then
  echo "PASS: an unresolvable-but-present governance_worktree stays fail-closed, not papered over by the canonical fallback"
else
  echo "FAIL: close rejected for an unexpected reason (fixture may need updating): $CLOSE_OUT" >&2
  exit 1
fi

# --- Scenario D (WP-484, peer-session 2026-09-14-13, Claude+Kimi+Codex): the
# acceptance criterion this phase set out to close.  A legacy semaphore whose
# canonical checkout has genuinely DIVERGED from origin/main (unrelated
# foreign history, the everyday shape of a shared checkout under parallel
# sessions) must still close when this session's own registered file/commit
# was honestly delivered -- even under a different SHA, the isolate-push
# shape (DRR-f102-isolated-push-cherry-pick.md).  Before this phase, scenario
# A above never actually exercised the scope-fallback: its checkout stayed a
# fast-forward of origin, so the strict ancestry check in
# _repo_head_has_publish_proof always passed on its own.
FOREIGN="$TEST_ROOT/foreign-session-d"
git clone -q "$ORIGIN" "$FOREIGN"
git -C "$FOREIGN" config user.email foreign@test
git -C "$FOREIGN" config user.name foreign
echo "unrelated foreign work" > "$FOREIGN/foreign-d.txt"
git -C "$FOREIGN" add foreign-d.txt
git -C "$FOREIGN" commit -qm "foreign session advances origin"
git -C "$FOREIGN" push -q origin HEAD:main

CLAUDE_CODE_SESSION_ID="session-D" bash "$GUARD" open --wp WP-484 --task fixture --slug legacy-d --agent fixture >/dev/null
SEM_D=$(grep -l '^slug: legacy-d$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_BASENAME_D=$(grep '^orz_file: ' "$SEM_D" | cut -d' ' -f2-)
write_orz "$SESSIONS/$ORZ_BASENAME_D"
git -C "$SESSIONS" add "$ORZ_BASENAME_D"
git -C "$SESSIONS" commit -qm "orz D"
git -C "$SESSIONS" push -q origin HEAD:main

# Both our own delivered file AND the RUN-quick-close card go in ONE commit
# -- a scoped-proof check treats an on-disk-but-uncommitted file the same as
# any other dirty path, so the card has to be genuinely committed+published
# here too, not merely written to disk (found live: scenario D first failed
# on exactly this, "собственные файлы не закоммичены", for the card path).
mkdir -p "$REPO/inbox/agent/tasks"
cat > "$REPO/inbox/agent/tasks/RUN-quick-close-legacy-d.md" <<EOF
---
process_id: quick-close
run_id: quick-close-legacy-d
requested_slug: legacy-d
status: completed
current_step: done
owner_session_id: session-D
results:
  gather-session-facts:
    wp: WP-484
---
EOF
echo "owned result" > "$REPO/owned-legacy-d.txt"
git -C "$REPO" add owned-legacy-d.txt inbox/agent/tasks/RUN-quick-close-legacy-d.md
# Our own commit, built on the OLD base (before the foreign push above) --
# never fast-forwarded, so local HEAD is not an ancestor of the now-advanced
# origin/main, and origin/main is not an ancestor of local HEAD either.
git -C "$REPO" commit -qm "own change, not yet fast-forwarded onto foreign history"
OWN_SHA_D=$(git -C "$REPO" rev-parse HEAD)
if git -C "$REPO" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
  echo "FAIL: fixture setup — local HEAD is still an ancestor of origin/main, divergence not achieved" >&2
  exit 1
fi

# Republish the SAME content change onto fresh origin/main under a DIFFERENT
# SHA -- exactly what isolate-push.sh does for a real session working from an
# isolated worktree while the canonical checkout stays behind.
REPUBLISH="$TEST_ROOT/republish-legacy-d"
git clone -q "$ORIGIN" "$REPUBLISH"
git -C "$REPUBLISH" config user.email republish@test
git -C "$REPUBLISH" config user.name republish
mkdir -p "$REPUBLISH/inbox/agent/tasks"
cp "$REPO/inbox/agent/tasks/RUN-quick-close-legacy-d.md" "$REPUBLISH/inbox/agent/tasks/"
echo "owned result" > "$REPUBLISH/owned-legacy-d.txt"
git -C "$REPUBLISH" add owned-legacy-d.txt inbox/agent/tasks/RUN-quick-close-legacy-d.md
git -C "$REPUBLISH" commit -qm "own change, republished onto fresh origin/main"
git -C "$REPUBLISH" push -q origin HEAD:main

grep -vE '^(governance_worktree|isolated_worktree|orz_sessions_dir): ' "$SEM_D" > "$SEM_D.stripped"
mv "$SEM_D.stripped" "$SEM_D"
{
  echo "file: owned-legacy-d.txt"
  echo "file: inbox/agent/tasks/RUN-quick-close-legacy-d.md"
  echo "commit: $(basename "$REPO") $OWN_SHA_D"
} >> "$SEM_D"

if CLOSE_OUT=$(CLAUDE_CODE_SESSION_ID="session-D" bash "$GUARD" close --wp WP-484 --slug legacy-d --agent fixture 2>&1); then
  echo "PASS: legacy semaphore with a diverged canonical closes when its own registered scope was honestly delivered (republished SHA)"
else
  echo "FAIL: close still refuses an honestly-delivered legacy session on a diverged canonical: $CLOSE_OUT" >&2
  exit 1
fi

# --- Scenario E (regression, must stay caught): same divergence as D, but
# this session's claimed file/commit was NEVER actually delivered anywhere.
# The legacy scope-fallback added for D must not turn into a blanket pass for
# every legacy semaphore on a diverged canonical -- undelivered work still
# has to block close.
CLAUDE_CODE_SESSION_ID="session-E" bash "$GUARD" open --wp WP-484 --task fixture --slug legacy-e --agent fixture >/dev/null
SEM_E=$(grep -l '^slug: legacy-e$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_BASENAME_E=$(grep '^orz_file: ' "$SEM_E" | cut -d' ' -f2-)
write_orz "$SESSIONS/$ORZ_BASENAME_E"
git -C "$SESSIONS" add "$ORZ_BASENAME_E"
git -C "$SESSIONS" commit -qm "orz E"
git -C "$SESSIONS" push -q origin HEAD:main

mkdir -p "$REPO/inbox/agent/tasks"
cat > "$REPO/inbox/agent/tasks/RUN-quick-close-legacy-e.md" <<EOF
---
process_id: quick-close
run_id: quick-close-legacy-e
requested_slug: legacy-e
status: completed
current_step: done
owner_session_id: session-E
results:
  gather-session-facts:
    wp: WP-484
---
EOF
echo "never published" > "$REPO/owned-legacy-e.txt"
git -C "$REPO" add owned-legacy-e.txt inbox/agent/tasks/RUN-quick-close-legacy-e.md
git -C "$REPO" commit -qm "own change, never delivered anywhere"
OWN_SHA_E=$(git -C "$REPO" rev-parse HEAD)

grep -vE '^(governance_worktree|isolated_worktree|orz_sessions_dir): ' "$SEM_E" > "$SEM_E.stripped"
mv "$SEM_E.stripped" "$SEM_E"
{
  echo "file: owned-legacy-e.txt"
  echo "file: inbox/agent/tasks/RUN-quick-close-legacy-e.md"
  echo "commit: $(basename "$REPO") $OWN_SHA_E"
} >> "$SEM_E"

if CLOSE_OUT=$(CLAUDE_CODE_SESSION_ID="session-E" bash "$GUARD" close --wp WP-484 --slug legacy-e --agent fixture 2>&1); then
  echo "FAIL: close accepted a legacy session whose registered work was never actually delivered: $CLOSE_OUT" >&2
  exit 1
else
  echo "PASS: on a diverged canonical, a legacy semaphore with genuinely undelivered work still blocks close"
fi

echo "PASS: legacy semaphores without governance fields fall back to canonical; isolated and broken-modern claims stay strict; diverged-but-delivered closes, diverged-and-undelivered still blocks"
