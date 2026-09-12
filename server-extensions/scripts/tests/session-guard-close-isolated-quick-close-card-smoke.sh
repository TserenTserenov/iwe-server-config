#!/usr/bin/env bash
# Regression for WP-484 (06.09): close's Quick Close terminal-card search
# derived the isolated worktree path as dirname($ORZ_SESSIONS_DIR). That was
# correct back when an isolated session's ORZ lived inside its own worktree
# ("$ISOLATED_WORKTREE_PATH/sessions/..."), but WP-526 Ф2 moved ORZ content
# out to a separate MC-sessions repo -- $ORZ_SESSIONS_DIR is MC-sessions
# itself now, and dirname(MC-sessions) is just $IWE_ROOT, never the actual
# isolated worktree. Every isolated session's close was silently searching
# the wrong directory for its own completed RUN-quick-close-*.md card and
# reporting "Quick Close не завершён" even though the card existed, was
# committed, and was pushed exactly where `open --isolate` put it.
#
# session_scope_dirty_paths() was already fixed for this exact class (same
# WP-526 Ф2 comment: "use isolated_worktree from the semaphore directly, no
# dirname()") -- this test guards the sibling code path in close() that
# stayed on the stale dirname() heuristic.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-isolated-close.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/scripts"
cat > "$TEST_ROOT/scripts/agent-status-report.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_ROOT/status-calls"
EOF
chmod +x "$TEST_ROOT/scripts/agent-status-report.sh"

# Canonical governance repo -- frozen in spirit (this test never writes to it
# directly, only via the isolated worktree `open --isolate` creates from it).
# --isolate always does its own `git fetch origin main`, so the fixture needs
# a real origin remote, not just a local repo (session-open-close-load-
# simulation.sh's bare-origin pattern, reused here).
ORIGIN="$TEST_ROOT/origin.git"
git init -q --bare -b main "$ORIGIN"
REPO="$TEST_ROOT/DS-strategy"
mkdir -p "$REPO/inbox/agent/tasks" "$REPO/scripts"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "$ORIGIN"
cat > "$REPO/scripts/process-runner.py" <<'EOF'
#!/usr/bin/env python3
print("{}")
EOF
cat > "$REPO/scripts/isolate-push.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${IWE_TEST_ISOLATE_PUSH_FAIL:-0}" != 1 ] || exit 42
[ "${IWE_TEST_ISOLATE_PUSH_NOOP:-0}" != 1 ] || exit 0
git -C "$1" push -q origin HEAD:"$2"
EOF
cat > "$REPO/scripts/ledger-append.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${IWE_TEST_DETACH_LEDGER:-0}" = 1 ]; then
  sleep 3 &
  detached_pid=$!
  printf '%s\n' "$detached_pid" > "$IWE_TEST_DETACH_MARKER"
  disown "$detached_pid" 2>/dev/null || true
fi
EOF
chmod +x "$REPO/scripts/process-runner.py" "$REPO/scripts/isolate-push.sh" \
  "$REPO/scripts/ledger-append.sh"
git -C "$REPO" add scripts/process-runner.py scripts/isolate-push.sh scripts/ledger-append.sh
git -C "$REPO" commit -qm init
git -C "$REPO" push -q origin main

# Separate MC-sessions-shaped repo, the same split WP-526 Ф2 introduced:
# ORZ content lives here, never inside the governance repo's own worktree.
SESSIONS_REPO="$TEST_ROOT/MC-sessions-fixture"
SESSIONS_ORIGIN="$TEST_ROOT/sessions-origin.git"
git init -q --bare -b main "$SESSIONS_ORIGIN"
mkdir -p "$SESSIONS_REPO"
git -C "$SESSIONS_REPO" init -q -b main
git -C "$SESSIONS_REPO" config user.email test@example.com
git -C "$SESSIONS_REPO" config user.name "Test"
git -C "$SESSIONS_REPO" remote add origin "$SESSIONS_ORIGIN"
echo placeholder > "$SESSIONS_REPO/00-index.md"
git -C "$SESSIONS_REPO" add 00-index.md
git -C "$SESSIONS_REPO" commit -qm init
git -C "$SESSIONS_REPO" push -q origin main

export IWE_ROOT="$TEST_ROOT"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
export IWE_SESSIONS_ROOT="$SESSIONS_REPO"
export CLAUDE_CODE_SESSION_ID="isolated-close-smoke"

OPEN_OUTPUT=$(cd "$REPO" && bash "$GUARD" open --wp WP-484 --task fixture --slug isolated-close-smoke --agent fixture --isolate)
WORKTREE_PATH=$(printf '%s\n' "$OPEN_OUTPUT" | grep -o '"worktree_path": "[^"]*"' | cut -d'"' -f4)
[ -n "$WORKTREE_PATH" ] && [ -d "$WORKTREE_PATH" ] || { echo "FAIL: fixture setup — open --isolate did not produce a worktree_path" >&2; exit 1; }

SEM=$(find "$TEST_ROOT/.iwe-runtime/sessions" -name 'fixture-*.open' -type f | head -1)
grep -q '^isolated_worktree: '"$WORKTREE_PATH"'$' "$SEM" || { echo "FAIL: fixture setup — semaphore did not record isolated_worktree=$WORKTREE_PATH" >&2; exit 1; }
grep -q '^orz_sessions_dir: '"$SESSIONS_REPO"'$' "$SEM" || { echo "FAIL: fixture setup — semaphore did not record orz_sessions_dir=$SESSIONS_REPO (expected the MC-sessions-shaped split)" >&2; exit 1; }

ORZ_BASENAME=$(grep '^orz_file: ' "$SEM" | cut -d' ' -f2-)
mkdir -p "$SESSIONS_REPO/$(dirname "$ORZ_BASENAME")"
cat > "$SESSIONS_REPO/$ORZ_BASENAME" <<'EOF'
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
git -C "$SESSIONS_REPO" add "$ORZ_BASENAME"
git -C "$SESSIONS_REPO" commit -qm "orz"
git -C "$SESSIONS_REPO" push -q origin main

# The terminal Quick Close card lives where `open --isolate` actually put the
# session's code work -- the isolated worktree -- not next to the ORZ file.
mkdir -p "$WORKTREE_PATH/inbox/agent/tasks"
cat > "$WORKTREE_PATH/inbox/agent/tasks/RUN-quick-close-isolated-close-smoke.md" <<EOF
---
process_id: quick-close
run_id: quick-close-isolated-close-smoke
requested_slug: isolated-close-smoke
status: completed
current_step: done
owner_session_id: isolated-close-smoke
results:
  gather-session-facts:
    wp: WP-484
---
EOF
echo "file: inbox/agent/tasks/RUN-quick-close-isolated-close-smoke.md" >> "$SEM"
git -C "$WORKTREE_PATH" add inbox/agent/tasks/RUN-quick-close-isolated-close-smoke.md
git -C "$WORKTREE_PATH" commit -qm "terminal card"

if bash "$GUARD" close --wp WP-484 --slug isolated-close-smoke --agent fixture; then
  echo "PASS: close finds an isolated session's own terminal Quick Close card"
else
  echo "FAIL: close did not find the terminal card sitting in the isolated worktree (WP-484, 06.09 regression)" >&2
  exit 1
fi

[ ! -e "$SEM" ] || { echo "FAIL: successful close left .open authoritative" >&2; exit 1; }
[ -f "$SEM.closed" ] || { echo "FAIL: successful close did not create exact .closed receipt" >&2; exit 1; }
[ ! -e "$WORKTREE_PATH" ] || { echo "FAIL: successful close left isolated worktree on disk" >&2; exit 1; }
grep -q '^checklist_status: closed$' "$SEM.closed" || { echo "FAIL: closed receipt lacks terminal checklist" >&2; exit 1; }
grep -q '^checklist_publish_state: clean$' "$SEM.closed" || { echo "FAIL: closed receipt lacks publish proof" >&2; exit 1; }

idle_count() {
  grep -c ' fixture idle ' "$TEST_ROOT/status-calls" 2>/dev/null || true
}

prepare_isolated_session() {  # <slug> <session-id>
  local slug="$1" session_id="$2" output orz_basename card
  export CLAUDE_CODE_SESSION_ID="$session_id"
  export IWE_SESSION_ID="$session_id"
  output=$(cd "$REPO" && /bin/bash "$GUARD" open \
    --wp WP-484 --task fixture --slug "$slug" --agent fixture --isolate)
  CASE_WORKTREE=$(printf '%s\n' "$output" | grep -o '"worktree_path": "[^"]*"' | cut -d'"' -f4)
  CASE_SEM="$TEST_ROOT/.iwe-runtime/sessions/fixture-$session_id.open"
  [ -d "$CASE_WORKTREE" ] && [ -f "$CASE_SEM" ] \
    || { echo "FAIL: fixture setup failed for $slug" >&2; exit 1; }
  cat > "$CASE_SEM.lease" <<EOF
renewed_at: 2026-09-12T00:00:00Z
session_id: $session_id
EOF

  orz_basename=$(grep '^orz_file: ' "$CASE_SEM" | cut -d' ' -f2-)
  mkdir -p "$SESSIONS_REPO/$(dirname "$orz_basename")"
  cat > "$SESSIONS_REPO/$orz_basename" <<EOF
---
date: 2026-09-12
type: work
wp: WP-484
duration_h: 0.1
artifacts: []
agent: fixture
---

# $slug

## Главный инсайт
fixture

## Контекст
fixture

## Достигнуто
fixture

## Ключевые решения
fixture
EOF
  git -C "$SESSIONS_REPO" add "$orz_basename"
  git -C "$SESSIONS_REPO" commit -qm "orz $slug"
  git -C "$SESSIONS_REPO" push -q origin main

  card="$CASE_WORKTREE/inbox/agent/tasks/RUN-quick-close-$slug.md"
  mkdir -p "$(dirname "$card")"
  cat > "$card" <<EOF
---
process_id: quick-close
run_id: quick-close-$slug
requested_slug: $slug
status: completed
current_step: done
owner_session_id: $session_id
results:
  gather-session-facts:
    wp: WP-484
---
EOF
  printf '%s\n' "file: inbox/agent/tasks/RUN-quick-close-$slug.md" >> "$CASE_SEM"
  git -C "$CASE_WORKTREE" add "inbox/agent/tasks/RUN-quick-close-$slug.md"
  git -C "$CASE_WORKTREE" commit -qm "terminal card $slug"
}

assert_failed_close_preserved_projections() {  # <semaphore> <worktree> <idle-before>
  local semaphore="$1" worktree="$2" idle_before="$3"
  [ -f "$semaphore" ] || { echo "FAIL: failed close removed .open" >&2; exit 1; }
  [ ! -e "$semaphore.closed" ] || { echo "FAIL: failed close created .closed" >&2; exit 1; }
  [ -f "$semaphore.lease" ] || { echo "FAIL: failed close removed lease" >&2; exit 1; }
  [ -f "$TEST_ROOT/.iwe-runtime/sessions/current-fixture.ptr" ] || { echo "FAIL: failed close removed pointer" >&2; exit 1; }
  [ -d "$worktree" ] || { echo "FAIL: failed pre-cleanup close removed worktree" >&2; exit 1; }
  [ "$(idle_count)" = "$idle_before" ] || { echo "FAIL: failed close reported agent idle" >&2; exit 1; }
}

# The runner invokes close while its card is still at the release step.  The
# immutable terminal snapshot must read the real nested verify-r23 verdict and
# bind the exact running/current_step/owner/slug/WP shape from the same bytes.
prepare_isolated_session release-step-proof release-step-proof-session
RELEASE_SEM="$CASE_SEM"
RELEASE_WORKTREE="$CASE_WORKTREE"
cat > "$RELEASE_WORKTREE/inbox/agent/tasks/RUN-quick-close-release-step-proof.md" <<'EOF'
---
process_id: quick-close
run_id: quick-close-release-step-proof
requested_slug: release-step-proof
status: running
current_step: session-guard-release
owner_session_id: release-step-proof-session
results:
  gather-session-facts:
    wp: WP-484
  verify-r23:
    verdict: pass
---
EOF
git -C "$RELEASE_WORKTREE" add inbox/agent/tasks/RUN-quick-close-release-step-proof.md
git -C "$RELEASE_WORKTREE" commit -qm "release-step terminal proof"
/bin/bash "$GUARD" close --wp WP-484 --slug release-step-proof --agent fixture >/dev/null
[ ! -e "$RELEASE_SEM" ] && [ -f "$RELEASE_SEM.closed" ] && [ ! -e "$RELEASE_WORKTREE" ] \
  || { echo "FAIL: nested verify-r23 release-step proof did not close exact isolated session" >&2; exit 1; }

# isolate-push failure is non-terminal and preserves every live projection.
prepare_isolated_session push-failure push-failure-session
PUSH_FAIL_SEM="$CASE_SEM"
PUSH_FAIL_WORKTREE="$CASE_WORKTREE"
IDLE_BEFORE=$(idle_count)
if IWE_TEST_ISOLATE_PUSH_FAIL=1 /bin/bash "$GUARD" close \
   --wp WP-484 --slug push-failure --agent fixture >/dev/null 2>&1; then
  echo "FAIL: injected isolate-push failure reported close success" >&2
  exit 1
fi
assert_failed_close_preserved_projections "$PUSH_FAIL_SEM" "$PUSH_FAIL_WORKTREE" "$IDLE_BEFORE"

# Even after a successful push, a dirty worktree makes cleanup fail; `.open`
# remains the authority and close does not advertise terminal state.
prepare_isolated_session cleanup-failure cleanup-failure-session
CLEANUP_FAIL_SEM="$CASE_SEM"
CLEANUP_FAIL_WORKTREE="$CASE_WORKTREE"
printf '%s\n' fixture > "$CLEANUP_FAIL_WORKTREE/untracked-cleanup-blocker"
IDLE_BEFORE=$(idle_count)
if /bin/bash "$GUARD" close --wp WP-484 --slug cleanup-failure --agent fixture \
   >/dev/null 2>&1; then
  echo "FAIL: worktree cleanup failure reported close success" >&2
  exit 1
fi
assert_failed_close_preserved_projections "$CLEANUP_FAIL_SEM" "$CLEANUP_FAIL_WORKTREE" "$IDLE_BEFORE"

# A best-effort ledger publisher may detach a long-lived child.  Renew must
# release FD196 before invoking it; otherwise that child inherits the same
# flock open-description and an immediate exact-session mutator cannot acquire
# the lock even though renew itself has exited.
DETACH_MARKER="$TEST_ROOT/detached-ledger.pid"
IWE_TEST_DETACH_LEDGER=1 IWE_TEST_DETACH_MARKER="$DETACH_MARKER" \
  /bin/bash "$GUARD" renew --agent fixture --session-id cleanup-failure-session \
  --foreign --reason detached-ledger-fixture >/dev/null
DETACHED_LEDGER_PID=$(cat "$DETACH_MARKER")
kill -0 "$DETACHED_LEDGER_PID" 2>/dev/null \
  || { echo "FAIL: detached-ledger fixture did not leave a live child" >&2; exit 1; }
(cd "$CLEANUP_FAIL_WORKTREE" && IWE_SESSION_TRANSITION_WAIT_SEC=0 \
  /bin/bash "$GUARD" note-file untracked-cleanup-blocker --agent fixture \
  --session-id cleanup-failure-session >/dev/null) \
  || { echo "FAIL: detached ledger child inherited and prolonged FD196" >&2; exit 1; }

# An unrelated destination must never be overwritten by the terminal move.
prepare_isolated_session foreign-destination foreign-destination-session
FOREIGN_SEM="$CASE_SEM"
FOREIGN_WORKTREE="$CASE_WORKTREE"
printf '%s\n' foreign-receipt > "$FOREIGN_SEM.closed"
IDLE_BEFORE=$(idle_count)
if /bin/bash "$GUARD" close --wp WP-484 --slug foreign-destination --agent fixture \
   >/dev/null 2>&1; then
  echo "FAIL: unrelated .closed destination reported close success" >&2
  exit 1
fi
[ -f "$FOREIGN_SEM" ] && [ -d "$FOREIGN_WORKTREE" ] \
  || { echo "FAIL: foreign destination failure removed .open/worktree" >&2; exit 1; }
[ -f "$FOREIGN_SEM.lease" ] && [ -f "$TEST_ROOT/.iwe-runtime/sessions/current-fixture.ptr" ] \
  || { echo "FAIL: foreign destination failure removed live projections" >&2; exit 1; }
[ "$(idle_count)" = "$IDLE_BEFORE" ] \
  || { echo "FAIL: foreign destination failure reported idle" >&2; exit 1; }
[ "$(cat "$FOREIGN_SEM.closed")" = foreign-receipt ] || { echo "FAIL: unrelated .closed receipt was overwritten" >&2; exit 1; }

# Crash after the worktree was removed must be retryable from the durable
# PUBLISHED receipt.  The first call is non-terminal and preserves every live
# projection; the retry records CLEANED and completes the exact link/unlink.
prepare_isolated_session post-cleanup-retry post-cleanup-retry-session
BOUNDARY_SEM="$CASE_SEM"
BOUNDARY_WORKTREE="$CASE_WORKTREE"
IDLE_BEFORE=$(idle_count)
if IWE_SESSION_GUARD_FAULT_POINT=after-worktree-remove /bin/bash "$GUARD" close \
   --wp WP-484 --slug post-cleanup-retry --agent fixture >/dev/null 2>&1; then
  echo "FAIL: injected post-cleanup crash reported close success" >&2
  exit 1
fi
[ -f "$BOUNDARY_SEM" ] && [ ! -e "$BOUNDARY_SEM.closed" ] \
  || { echo "FAIL: post-cleanup fault removed .open or created .closed" >&2; exit 1; }
[ ! -e "$BOUNDARY_WORKTREE" ] || { echo "FAIL: boundary fixture did not reach successful cleanup" >&2; exit 1; }
[ -f "$BOUNDARY_SEM.lease" ] && [ -f "$TEST_ROOT/.iwe-runtime/sessions/current-fixture.ptr" ] \
  || { echo "FAIL: post-cleanup fault removed projections" >&2; exit 1; }
[ "$(idle_count)" = "$IDLE_BEFORE" ] || { echo "FAIL: post-cleanup fault reported idle" >&2; exit 1; }
grep -q '^close_publish_proof: isolate-push-exit0/v1$' "$BOUNDARY_SEM" \
  || { echo "FAIL: post-cleanup fault lacks durable PUBLISHED receipt" >&2; exit 1; }
/bin/bash "$GUARD" close --wp WP-484 --slug post-cleanup-retry --agent fixture >/dev/null
[ ! -e "$BOUNDARY_SEM" ] && [ -f "$BOUNDARY_SEM.closed" ] \
  || { echo "FAIL: retry did not complete terminal transition from PUBLISHED" >&2; exit 1; }
grep -q '^close_cleanup_proof: worktree-absent/v1$' "$BOUNDARY_SEM.closed" \
  || { echo "FAIL: retry did not persist CLEANED proof" >&2; exit 1; }

prepare_machine_session() {  # <session UUID> <slug> <close-path>
  local machine_session="$1" machine_slug="$2" machine_close_path="$3" output
  unset CLAUDE_CODE_SESSION_ID
  output=$(cd "$REPO" && IWE_SESSION_ID="$machine_session" /bin/bash "$GUARD" open \
    --wp WP-539 --task fixture --slug "$machine_slug" --agent night-cycle \
    --isolate --owner-pid "$$" --close-path "$machine_close_path")
  MACHINE_WORKTREE=$(printf '%s\n' "$output" | grep -o '"worktree_path": "[^"]*"' | cut -d'"' -f4)
  MACHINE_SEM="$TEST_ROOT/.iwe-runtime/sessions/night-cycle-$machine_session.open"
  [ -d "$MACHINE_WORKTREE" ] && [ -f "$MACHINE_SEM" ] \
    || { echo "FAIL: machine fixture setup failed for $machine_slug" >&2; exit 1; }
}

# Only the explicit machine-publish-only schema may bypass the mutable ORZ
# dependency.  The guard itself produces PREPARED/PUBLISHED/CLEANED and removes
# the worktree before terminal state.
MACHINE_SID=$(python3 -c 'import uuid; print(uuid.uuid4())')
prepare_machine_session "$MACHINE_SID" machine-success machine-publish-only
printf '%s\n' machine > "$MACHINE_WORKTREE/machine-owned.txt"
git -C "$MACHINE_WORKTREE" add machine-owned.txt
git -C "$MACHINE_WORKTREE" commit -qm "machine-owned change"
/bin/bash "$GUARD" machine-close --agent night-cycle --session-id "$MACHINE_SID" >/dev/null
[ ! -e "$MACHINE_SEM" ] && [ -f "$MACHINE_SEM.closed" ] && [ ! -e "$MACHINE_WORKTREE" ] \
  || { echo "FAIL: machine-close did not publish, clean and terminate exact session" >&2; exit 1; }
grep -q '^close_delivery_version: isolate-push/v2$' "$MACHINE_SEM.closed" \
  && grep -q '^close_publish_proof: isolate-push-exit0/v1$' "$MACHINE_SEM.closed" \
  && grep -q '^close_cleanup_proof: worktree-absent/v1$' "$MACHINE_SEM.closed" \
  || { echo "FAIL: machine-close terminal receipt lacks durable delivery stages" >&2; exit 1; }
[ ! -e "$TEST_ROOT/.iwe-runtime/sessions/current-night-cycle.ptr" ] \
  || { echo "FAIL: machine-close left its exact current pointer" >&2; exit 1; }

# PREPARED binds the destination identity.  A retry after origin changes may
# neither publish to the replacement remote nor consume the original receipt.
REMOTE_BOUND_SID=$(python3 -c 'import uuid; print(uuid.uuid4())')
prepare_machine_session "$REMOTE_BOUND_SID" machine-remote-bound machine-publish-only
REMOTE_BOUND_SEM="$MACHINE_SEM"
REMOTE_BOUND_WORKTREE="$MACHINE_WORKTREE"
printf '%s\n' remote-bound > "$REMOTE_BOUND_WORKTREE/remote-bound.txt"
git -C "$REMOTE_BOUND_WORKTREE" add remote-bound.txt
git -C "$REMOTE_BOUND_WORKTREE" commit -qm "remote-bound change"
set +e
IWE_SESSION_GUARD_FAULT_POINT=after-prepared /bin/bash "$GUARD" machine-close \
  --agent night-cycle --session-id "$REMOTE_BOUND_SID" >/dev/null 2>&1
REMOTE_PREPARE_RC=$?
set -e
[ "$REMOTE_PREPARE_RC" -eq 99 ] || { echo "FAIL: remote-bound fixture did not stop after PREPARED" >&2; exit 1; }
REPLACEMENT_ORIGIN="$TEST_ROOT/replacement-origin.git"
git init -q --bare -b main "$REPLACEMENT_ORIGIN"
git -C "$REPO" remote set-url origin "$REPLACEMENT_ORIGIN"
if /bin/bash "$GUARD" machine-close --agent night-cycle --session-id "$REMOTE_BOUND_SID" \
   >/dev/null 2>&1; then
  echo "FAIL: PREPARED retry accepted a replacement destination remote" >&2
  exit 1
fi
[ -f "$REMOTE_BOUND_SEM" ] && [ -d "$REMOTE_BOUND_WORKTREE" ] \
  || { echo "FAIL: destination mismatch consumed PREPARED/worktree" >&2; exit 1; }
git --git-dir="$REPLACEMENT_ORIGIN" show-ref --verify refs/heads/main >/dev/null 2>&1 \
  && { echo "FAIL: destination mismatch published into replacement origin" >&2; exit 1; }
git -C "$REPO" remote set-url origin "$ORIGIN"
/bin/bash "$GUARD" machine-close --agent night-cycle --session-id "$REMOTE_BOUND_SID" >/dev/null

# isolate-push exit 0 is not sufficient delivery proof.  If a retry helper
# returns success without publishing the PREPARED source set, PUBLISHED and
# cleanup remain forbidden until fresh origin proves every source commit.
SOURCE_PROOF_SID=$(python3 -c 'import uuid; print(uuid.uuid4())')
prepare_machine_session "$SOURCE_PROOF_SID" machine-source-proof machine-publish-only
SOURCE_PROOF_SEM="$MACHINE_SEM"
SOURCE_PROOF_WORKTREE="$MACHINE_WORKTREE"
printf '%s\n' source-proof > "$SOURCE_PROOF_WORKTREE/source-proof.txt"
git -C "$SOURCE_PROOF_WORKTREE" add source-proof.txt
git -C "$SOURCE_PROOF_WORKTREE" commit -qm "source proof change"
set +e
IWE_SESSION_GUARD_FAULT_POINT=after-prepared /bin/bash "$GUARD" machine-close \
  --agent night-cycle --session-id "$SOURCE_PROOF_SID" >/dev/null 2>&1
SOURCE_PREPARE_RC=$?
set -e
[ "$SOURCE_PREPARE_RC" -eq 99 ] || { echo "FAIL: source-proof fixture did not stop after PREPARED" >&2; exit 1; }
if IWE_TEST_ISOLATE_PUSH_NOOP=1 /bin/bash "$GUARD" machine-close \
   --agent night-cycle --session-id "$SOURCE_PROOF_SID" >/dev/null 2>&1; then
  echo "FAIL: helper exit 0 replaced fresh PREPARED source-set proof" >&2
  exit 1
fi
[ -f "$SOURCE_PROOF_SEM" ] && [ -d "$SOURCE_PROOF_WORKTREE" ] \
  || { echo "FAIL: missing source proof consumed PREPARED/worktree" >&2; exit 1; }
grep -q '^close_publish_proof: ' "$SOURCE_PROOF_SEM" \
  && { echo "FAIL: missing source proof recorded PUBLISHED" >&2; exit 1; }
/bin/bash "$GUARD" machine-close --agent night-cycle --session-id "$SOURCE_PROOF_SID" >/dev/null

# An empty PREPARED source set means the exact source HEAD is already on the
# bound remote.  It must never invoke moving isolate-push on retry.
EMPTY_SET_SID=$(python3 -c 'import uuid; print(uuid.uuid4())')
prepare_machine_session "$EMPTY_SET_SID" machine-empty-set machine-publish-only
EMPTY_SET_SEM="$MACHINE_SEM"
set +e
IWE_SESSION_GUARD_FAULT_POINT=after-prepared /bin/bash "$GUARD" machine-close \
  --agent night-cycle --session-id "$EMPTY_SET_SID" >/dev/null 2>&1
EMPTY_PREPARE_RC=$?
set -e
[ "$EMPTY_PREPARE_RC" -eq 99 ] || { echo "FAIL: empty-set fixture did not stop after PREPARED" >&2; exit 1; }
grep -q '^close_delivery_source_commits: \[\]$' "$EMPTY_SET_SEM" \
  || { echo "FAIL: empty-set fixture recorded a non-empty source set" >&2; exit 1; }
IWE_TEST_ISOLATE_PUSH_FAIL=1 /bin/bash "$GUARD" machine-close \
  --agent night-cycle --session-id "$EMPTY_SET_SID" >/dev/null
[ ! -e "$EMPTY_SET_SEM" ] && [ -f "$EMPTY_SET_SEM.closed" ] \
  || { echo "FAIL: empty PREPARED set did not finish without moving isolate-push" >&2; exit 1; }

# A crash after the durable no-clobber terminal link may be retried.  Projection
# cleanup is exact compare-and-swap and must preserve a newer generation's
# pointer written after that terminal boundary.
POINTER_CAS_SID=$(python3 -c 'import uuid; print(uuid.uuid4())')
prepare_machine_session "$POINTER_CAS_SID" machine-pointer-cas machine-publish-only
POINTER_CAS_SEM="$MACHINE_SEM"
printf '%s\n' pointer-cas > "$MACHINE_WORKTREE/pointer-cas.txt"
git -C "$MACHINE_WORKTREE" add pointer-cas.txt
git -C "$MACHINE_WORKTREE" commit -qm "pointer CAS change"
if IWE_SESSION_GUARD_FAULT_POINT=after-terminal-link /bin/bash "$GUARD" machine-close \
   --agent night-cycle --session-id "$POINTER_CAS_SID" >/dev/null 2>&1; then
  echo "FAIL: terminal-link fault reported machine-close success" >&2
  exit 1
fi
[ -f "$POINTER_CAS_SEM" ] && [ -f "$POINTER_CAS_SEM.closed" ] \
  && [ "$POINTER_CAS_SEM" -ef "$POINTER_CAS_SEM.closed" ] \
  || { echo "FAIL: terminal-link fault did not retain exact two-name inode" >&2; exit 1; }
NEW_POINTER_TARGET="$TEST_ROOT/.iwe-runtime/sessions/night-cycle-new-generation.open"
printf '%s\n' "$NEW_POINTER_TARGET" > "$TEST_ROOT/.iwe-runtime/sessions/current-night-cycle.ptr"
/bin/bash "$GUARD" machine-close --agent night-cycle --session-id "$POINTER_CAS_SID" >/dev/null
[ ! -e "$POINTER_CAS_SEM" ] && [ -f "$POINTER_CAS_SEM.closed" ] \
  || { echo "FAIL: terminal-link retry did not finish exact unlink" >&2; exit 1; }
[ "$(cat "$TEST_ROOT/.iwe-runtime/sessions/current-night-cycle.ptr")" = "$NEW_POINTER_TARGET" ] \
  || { echo "FAIL: machine-close projection cleanup removed a newer pointer" >&2; exit 1; }
rm -f "$TEST_ROOT/.iwe-runtime/sessions/current-night-cycle.ptr"

# A legacy publish-only semaphore is not machine authority.
LEGACY_MACHINE_SID=$(python3 -c 'import uuid; print(uuid.uuid4())')
prepare_machine_session "$LEGACY_MACHINE_SID" machine-spoof publish-only
if /bin/bash "$GUARD" machine-close --agent night-cycle --session-id "$LEGACY_MACHINE_SID" \
   >/dev/null 2>&1; then
  echo "FAIL: machine-close accepted a legacy publish-only semaphore" >&2
  exit 1
fi
[ -f "$MACHINE_SEM" ] && [ -d "$MACHINE_WORKTREE" ] \
  || { echo "FAIL: rejected machine spoof mutated live state" >&2; exit 1; }

# Initial machine close may not bless an externally removed worktree.
ABSENT_MACHINE_SID=$(python3 -c 'import uuid; print(uuid.uuid4())')
prepare_machine_session "$ABSENT_MACHINE_SID" machine-absent machine-publish-only
git -C "$REPO" worktree remove --force "$MACHINE_WORKTREE"
if /bin/bash "$GUARD" machine-close --agent night-cycle --session-id "$ABSENT_MACHINE_SID" \
   >/dev/null 2>&1; then
  echo "FAIL: initial machine-close accepted an externally removed worktree" >&2
  exit 1
fi
[ -f "$MACHINE_SEM" ] && [ ! -e "$MACHINE_SEM.closed" ] \
  || { echo "FAIL: absent-worktree rejection removed the operational barrier" >&2; exit 1; }

# Once PREPARED/PUBLISHED is durable, retry is monotonic and no longer depends
# on the original wrapper PID being alive.
RETRY_MACHINE_SID=$(python3 -c 'import uuid; print(uuid.uuid4())')
IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_SESSIONS_ROOT="$SESSIONS_REPO" \
  /bin/bash -c '
set -euo pipefail
repo=$1
guard=$2
session=$3
worktree=$4
cd "$repo"
IWE_SESSION_ID=$session /bin/bash "$guard" open --wp WP-539 --task fixture \
  --slug machine-dead-owner --agent night-cycle --isolate --owner-pid "$$" \
  --close-path machine-publish-only >/dev/null
printf "%s\n" retry > "$worktree/retry-owned.txt"
git -C "$worktree" add retry-owned.txt
git -C "$worktree" commit -qm "machine retry change"
set +e
IWE_SESSION_GUARD_FAULT_POINT=after-published /bin/bash "$guard" machine-close \
  --agent night-cycle --session-id "$session" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 99 ]
' _ "$REPO" "$GUARD" "$RETRY_MACHINE_SID" \
  "$TEST_ROOT/.iwe-runtime/isolated-worktrees/night-cycle-$RETRY_MACHINE_SID"
RETRY_MACHINE_SEM="$TEST_ROOT/.iwe-runtime/sessions/night-cycle-$RETRY_MACHINE_SID.open"
grep -q '^close_publish_proof: isolate-push-exit0/v1$' "$RETRY_MACHINE_SEM" \
  || { echo "FAIL: machine fault did not preserve PUBLISHED stage" >&2; exit 1; }
/bin/bash "$GUARD" machine-close --agent night-cycle --session-id "$RETRY_MACHINE_SID" >/dev/null
[ ! -e "$RETRY_MACHINE_SEM" ] && [ -f "$RETRY_MACHINE_SEM.closed" ] \
  || { echo "FAIL: dead-owner retry did not complete exact staged transition" >&2; exit 1; }

# isolate-push commits through the repository's normal pre-commit hook.  Once
# PREPARED is durable the source semaphore is intentionally no longer ACTIVE,
# so the hook gets a narrowly reconstructed authority: exact attempt passport,
# exact prepared commit/index tree and exact literal scope, all from an inode+
# hash snapshot that is rechecked after the decision.  A filename containing
# pathspec magic exercises the literal lookup; an extra staged path must not be
# admitted by that scope or by the prepared receipt.
HOOK_MACHINE_SID=$(python3 -c 'import uuid; print(uuid.uuid4())')
prepare_machine_session "$HOOK_MACHINE_SID" machine-recursive-hook machine-publish-only
printf '%s\n' literal > "$MACHINE_WORKTREE/a*"
(cd "$MACHINE_WORKTREE" && /bin/bash "$GUARD" note-file 'a*' \
  --agent night-cycle --session-id "$HOOK_MACHINE_SID" >/dev/null)
git -C "$MACHINE_WORKTREE" add -- 'a*'
git -C "$MACHINE_WORKTREE" commit -qm "machine recursive hook change"
HOOK_SOURCE_COMMIT=$(git -C "$MACHINE_WORKTREE" rev-parse HEAD)
set +e
IWE_SESSION_GUARD_FAULT_POINT=after-prepared /bin/bash "$GUARD" machine-close \
  --agent night-cycle --session-id "$HOOK_MACHINE_SID" >/dev/null 2>&1
HOOK_PREPARE_RC=$?
set -e
[ "$HOOK_PREPARE_RC" -eq 99 ] \
  || { echo "FAIL: recursive-hook fixture did not stop at durable PREPARED" >&2; exit 1; }

HOOK_ATTEMPT_ID="attempt-1-4242-deadbeef"
HOOK_TEMP_STORE="$TEST_ROOT/.iwe-runtime/isolated-worktrees/.isolate-push-tmp"
HOOK_TEMP_WORKTREE="$HOOK_TEMP_STORE/$HOOK_ATTEMPT_ID"
HOOK_REGISTRY="$TEST_ROOT/.iwe-runtime/isolate-push-attempts"
mkdir -p "$HOOK_TEMP_STORE" "$HOOK_REGISTRY"
git -C "$REPO" worktree add --detach "$HOOK_TEMP_WORKTREE" refs/remotes/origin/main -q
git -C "$HOOK_TEMP_WORKTREE" cherry-pick --no-commit "$HOOK_SOURCE_COMMIT"
HOOK_CHERRY_PICK_HEAD=$(git -C "$HOOK_TEMP_WORKTREE" rev-parse --git-path CHERRY_PICK_HEAD)
printf '%s\n' "$HOOK_SOURCE_COMMIT" > "$HOOK_CHERRY_PICK_HEAD"
python3 - "$HOOK_REGISTRY/$HOOK_ATTEMPT_ID.json" "$HOOK_ATTEMPT_ID" \
  "$MACHINE_WORKTREE" "$HOOK_TEMP_WORKTREE" "$HOOK_SOURCE_COMMIT" <<'PY'
import json
import sys

path, attempt, source, worktree, commit = sys.argv[1:]
with open(path, "w", encoding="utf-8") as target:
    json.dump({
        "attempt_id": attempt,
        "owner": "isolate-push",
        "source_commits": [commit],
        "source_worktree": source,
        "status": "active",
        "target_branch": "main",
        "worktree_path": worktree,
    }, target)
PY
HOOK_OUTPUT=$(cd "$HOOK_TEMP_WORKTREE" && /bin/bash "$GUARD" pre-commit-check)
printf '%s\n' "$HOOK_OUTPUT" | grep -q 'exact PREPARED isolate-push commit подтверждён' \
  || { echo "FAIL: exact PREPARED recursive pre-commit was not authorized" >&2; exit 1; }

printf '%s\n' foreign > "$HOOK_TEMP_WORKTREE/abc"
git -C "$HOOK_TEMP_WORKTREE" add -- abc
if (cd "$HOOK_TEMP_WORKTREE" && /bin/bash "$GUARD" pre-commit-check >/dev/null 2>&1); then
  echo "FAIL: PREPARED recursive pre-commit accepted an extra staged path" >&2
  exit 1
fi
git -C "$REPO" worktree remove --force "$HOOK_TEMP_WORKTREE"
/bin/bash "$GUARD" machine-close --agent night-cycle --session-id "$HOOK_MACHINE_SID" >/dev/null
[ ! -e "$MACHINE_SEM" ] && [ -f "$MACHINE_SEM.closed" ] \
  || { echo "FAIL: recursive-hook machine session did not finish after PREPARED test" >&2; exit 1; }

echo "PASS: machine-close is exact, proof-staged, spoof-safe and crash-retryable"
echo "PASS: PREPARED isolate-push pre-commit authority is snapshot-bound and literal"

echo "PASS: session-guard close resolves the isolated worktree from the semaphore, not from dirname(orz_sessions_dir)"
