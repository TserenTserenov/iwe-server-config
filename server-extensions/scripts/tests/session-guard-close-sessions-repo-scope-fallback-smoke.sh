#!/usr/bin/env bash
# Regression for WP-484 "находка 1" (session
# 2026-09-16-18-wp484-fmt-orz-sessions-dir-patch §5-6; fixed 16.09,
# peer-session 2026-09-16-22-wp484-close-mechanism-hard-snapshot,
# Claude+Kimi): _repo_head_has_publish_proof("$sessions_repo", "sessions
# checkout") used to be called with no semaphore/field arguments at all, so
# its scoped fallback (_repo_scope_has_publish_proof) never engaged for
# MC-sessions -- only the bare `merge-base --is-ancestor HEAD origin/main`
# check ran. Every session writes its own ORZ scaffold file into MC-sessions
# at `open` time (a footprint-skip mirroring the governance-checkout gate
# would therefore never actually skip anything here, unlike governance where
# most sessions have zero footprint), so this is the common case, not an
# edge case: a shared MC-sessions checkout drifts constantly under real
# concurrency (15-20 sessions committing daily), and the bare ancestry check
# fails for any session whose own work was honestly delivered under a
# different SHA (isolate-push republish) once foreign history has advanced
# origin/main past the point this session's checkout knows about.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-sessions-scope.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/DS-strategy"
ORIGIN="$TEST_ROOT/origin.git"
mkdir -p "$REPO/inbox/agent/tasks" "$REPO/scripts"
git init --bare -q -b main "$ORIGIN"
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
git init --bare -q -b main "$SESSIONS_ORIGIN"
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
date: 2026-09-16
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

# --- Scenario F (находка 1, acceptance criterion): MC-sessions has genuinely
# diverged from origin (unrelated foreign history, the everyday shape of a
# shared checkout under 15-20 parallel sessions) while this is a fully
# MODERN, non-isolated semaphore (orz_sessions_dir: present, `open` writes it
# unconditionally -- no legacy-field stripping in this test, unlike the
# governance-side D/E scenarios). This session's own registered ORZ file must
# still close when it was honestly delivered, even under a different SHA
# (isolate-push republish shape, DRR-f102-isolated-push-cherry-pick.md).
CLAUDE_CODE_SESSION_ID="session-F" bash "$GUARD" open --wp WP-484 --task fixture --slug sessions-scope-f --agent fixture >/dev/null
SEM_F=$(grep -l '^slug: sessions-scope-f$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
grep -q '^orz_sessions_dir: ' "$SEM_F" \
  || { echo "FAIL: fixture setup -- modern open() did not write orz_sessions_dir" >&2; exit 1; }
ORZ_BASENAME_F=$(grep '^orz_file: ' "$SEM_F" | cut -d' ' -f2-)

FOREIGN="$TEST_ROOT/foreign-session-f"
git clone -q "$SESSIONS_ORIGIN" "$FOREIGN"
git -C "$FOREIGN" config user.email foreign@test
git -C "$FOREIGN" config user.name foreign
echo "unrelated foreign work" > "$FOREIGN/foreign-f.txt"
git -C "$FOREIGN" add foreign-f.txt
git -C "$FOREIGN" commit -qm "foreign session advances sessions origin"
git -C "$FOREIGN" push -q origin HEAD:main

# Our own ORZ content, committed on the OLD base (before the foreign push
# above) -- never fast-forwarded, so local HEAD is not an ancestor of the
# now-advanced sessions origin/main, and vice versa.
write_orz "$SESSIONS/$ORZ_BASENAME_F"
git -C "$SESSIONS" add "$ORZ_BASENAME_F"
git -C "$SESSIONS" commit -qm "own ORZ content, not yet fast-forwarded onto foreign history"
if git -C "$SESSIONS" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
  echo "FAIL: fixture setup -- local HEAD is still an ancestor of origin/main, divergence not achieved" >&2
  exit 1
fi

# Republish the SAME content onto fresh sessions origin/main under a
# DIFFERENT SHA -- exactly what isolate-push.sh does from an isolated
# worktree while the shared checkout stays behind.
REPUBLISH="$TEST_ROOT/republish-sessions-f"
git clone -q "$SESSIONS_ORIGIN" "$REPUBLISH"
git -C "$REPUBLISH" config user.email republish@test
git -C "$REPUBLISH" config user.name republish
write_orz "$REPUBLISH/$ORZ_BASENAME_F"
git -C "$REPUBLISH" add "$ORZ_BASENAME_F"
git -C "$REPUBLISH" commit -qm "own ORZ content, republished onto fresh sessions origin/main"
git -C "$REPUBLISH" push -q origin HEAD:main

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-sessions-scope-f.md" <<EOF
---
process_id: quick-close
run_id: quick-close-sessions-scope-f
requested_slug: sessions-scope-f
status: completed
current_step: done
owner_session_id: session-F
results:
  gather-session-facts:
    wp: WP-484
---
EOF
{
  echo "file: inbox/agent/tasks/RUN-quick-close-sessions-scope-f.md"
  echo "file: $ORZ_BASENAME_F"
  echo "commit: $(basename "$SESSIONS") $(git -C "$SESSIONS" rev-parse HEAD)"
} >> "$SEM_F"

if CLOSE_OUT=$(CLAUDE_CODE_SESSION_ID="session-F" bash "$GUARD" close --wp WP-484 --slug sessions-scope-f --agent fixture 2>&1); then
  echo "PASS: modern semaphore closes when MC-sessions diverged but this session's own registered scope was honestly delivered (republished SHA)"
else
  echo "FAIL: close still refuses an honestly-delivered session on a diverged MC-sessions checkout: $CLOSE_OUT" >&2
  exit 1
fi

# --- Scenario G (regression, must stay caught): same MC-sessions divergence
# as F, but this session's claimed ORZ content was NEVER actually delivered
# anywhere. The scoped fallback added for F must not turn into a blanket
# pass for every session on a diverged MC-sessions checkout -- undelivered
# work still has to block close.
CLAUDE_CODE_SESSION_ID="session-G" bash "$GUARD" open --wp WP-484 --task fixture --slug sessions-scope-g --agent fixture >/dev/null
SEM_G=$(grep -l '^slug: sessions-scope-g$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_BASENAME_G=$(grep '^orz_file: ' "$SEM_G" | cut -d' ' -f2-)

write_orz "$SESSIONS/$ORZ_BASENAME_G"
git -C "$SESSIONS" add "$ORZ_BASENAME_G"
git -C "$SESSIONS" commit -qm "own ORZ content, never delivered anywhere"
OWN_SHA_G=$(git -C "$SESSIONS" rev-parse HEAD)

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-sessions-scope-g.md" <<EOF
---
process_id: quick-close
run_id: quick-close-sessions-scope-g
requested_slug: sessions-scope-g
status: completed
current_step: done
owner_session_id: session-G
results:
  gather-session-facts:
    wp: WP-484
---
EOF
{
  echo "file: inbox/agent/tasks/RUN-quick-close-sessions-scope-g.md"
  echo "file: $ORZ_BASENAME_G"
  echo "commit: $(basename "$SESSIONS") $OWN_SHA_G"
} >> "$SEM_G"

if CLOSE_OUT=$(CLAUDE_CODE_SESSION_ID="session-G" bash "$GUARD" close --wp WP-484 --slug sessions-scope-g --agent fixture 2>&1); then
  echo "FAIL: close accepted a session whose registered MC-sessions work was never actually delivered: $CLOSE_OUT" >&2
  exit 1
else
  echo "PASS: on a diverged MC-sessions checkout, genuinely undelivered work still blocks close"
fi

echo "PASS: sessions-checkout scope fallback (находка 1) closes honestly-delivered diverged sessions, still blocks undelivered ones"
