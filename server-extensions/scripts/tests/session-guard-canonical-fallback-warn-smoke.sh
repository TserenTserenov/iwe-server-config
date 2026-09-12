#!/usr/bin/env bash
# session-guard-canonical-fallback-warn-smoke.sh — WP-484 "Шестой случай" (08.09,
# peer-session with Kimi+Codex): session_scope_dirty_paths() falls back to the
# canonical checkout when a legacy semaphore has neither the explicit
# `governance_worktree` field nor `isolated_worktree` (a session that isolated
# its working copy by hand leaves both empty, like an ordinary old session).
# The fallback itself is correct and stays; what was missing is any signal
# that close() may be checking a copy the session never touched. The warning
# must fire exactly once, and only when the fallback actually finds a
# registered path that diverges -- not on every ordinary close (alert
# fatigue, live-caught in this same peer session's first review pass), and
# only when the divergence is in the canonical checkout itself, not the
# separate sessions_repo_dir fallback (WP-526 Ф2, MC-sessions content) --
# cold-review, same session: the first cut named the canonical path
# unconditionally and would have pointed the pilot at a clean directory
# while the real divergence sat in sessions_repo_dir.
#
# Extracts the scope functions and their checkout-resolver dependencies by
# line range rather than sourcing the whole script -- session-guard.sh is a
# CLI entrypoint (argument parsing + exit at the bottom), not a function
# library, so a plain `source` would execute it.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
extract_function() { # <function-name>
  local start end
  start=$(grep -n "^$1()" "$GUARD" | head -1 | cut -d: -f1)
  end=$(awk -v start="$start" 'NR>=start && /^}/{print NR; exit}' "$GUARD")
  [ -n "$start" ] && [ -n "$end" ] || return 1
  sed -n "${start},${end}p" "$GUARD"
}
FUNCS_START=$(grep -n '^_untracked_matches_published()' "$GUARD" | head -1 | cut -d: -f1)
FUNCS_END_MARK=$(grep -n '^session_scope_dirty_paths()' "$GUARD" | head -1 | cut -d: -f1)
FUNCS_END=$(awk -v start="$FUNCS_END_MARK" 'NR>=start && /^}/{print NR; exit}' "$GUARD")
[ -n "$FUNCS_START" ] && [ -n "$FUNCS_END" ] || { echo "FAIL: could not locate functions in $GUARD" >&2; exit 1; }
FUNCS_SRC="$(extract_function normalize_remote_url)
$(extract_function semaphore_governance_worktree)
$(sed -n "${FUNCS_START},${FUNCS_END}p" "$GUARD")"

TEST_ROOT=$(mktemp -d /private/tmp/session-guard-canonical-fallback.XXXXXX 2>/dev/null || mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

# "Canonical" governance checkout -- shared, no isolated_worktree registered.
CANON="$TEST_ROOT/canon"
git init -q "$CANON"
git -C "$CANON" config user.email c@test
git -C "$CANON" config user.name canon
echo seed > "$CANON/README.md"
git -C "$CANON" add README.md
git -C "$CANON" commit -q -m seed

# run_scope_check writes stdout and stderr to two SEPARATE files -- a
# combined 2>&1 capture (the first cut of this test used one) can prove a
# string appeared somewhere, but not that the warning is genuinely on stderr
# and never mixed into the dirty-path list callers parse from stdout.
run_scope_check() { # <semaphore-file> <out-var-name> <err-var-name>
  local sem="$1" out_file err_file
  out_file=$(mktemp) err_file=$(mktemp)
  bash -c "
    $FUNCS_SRC
    IWE_ROOT='$TEST_ROOT' GOV_REPO='canon' ORZ_DIR='$TEST_ROOT/canon'
    session_scope_dirty_paths '$sem'
  " >"$out_file" 2>"$err_file"
  printf -v "$2" '%s' "$(cat "$out_file")"
  printf -v "$3" '%s' "$(cat "$err_file")"
  rm -f "$out_file" "$err_file"
}

# Scenario 1: no isolated_worktree, canonical is CLEAN for every registered
# path -- this is the common case (a session that never isolated). No warning.
SEM_CLEAN="$TEST_ROOT/sem-clean"
cat > "$SEM_CLEAN" <<EOF
file: README.md
EOF
run_scope_check "$SEM_CLEAN" CLEAN_OUT CLEAN_ERR
if [ -n "$CLEAN_OUT" ] || grep -q 'семафор без isolated_worktree' <<<"$CLEAN_ERR"; then
  echo "FAIL: ordinary clean close must stay silent, got stdout=[$CLEAN_OUT] stderr=[$CLEAN_ERR]" >&2
  exit 1
fi
echo "OK: ordinary non-isolated close with nothing dirty prints no warning"

# Scenario 2: no isolated_worktree, canonical has a REAL divergence on a
# registered path -- the live "Шестой случай" shape. Warning must fire on
# stderr (not stdout, which callers parse as the dirty-path list), and fire
# exactly once even with two dirty registered paths.
echo "dirty a" > "$CANON/a.md"
echo "dirty b" > "$CANON/b.md"
SEM_DIRTY="$TEST_ROOT/sem-dirty"
cat > "$SEM_DIRTY" <<EOF
file: a.md
file: b.md
EOF
run_scope_check "$SEM_DIRTY" DIRTY_OUT DIRTY_ERR
WARN_COUNT=$(grep -c 'семафор без isolated_worktree' <<<"$DIRTY_ERR" || true)
if [ "$WARN_COUNT" -ne 1 ]; then
  echo "FAIL: expected exactly one warning on stderr, got $WARN_COUNT: stderr=[$DIRTY_ERR]" >&2
  exit 1
fi
if grep -q 'семафор без isolated_worktree' <<<"$DIRTY_OUT"; then
  echo "FAIL: warning leaked onto stdout, which callers parse as the dirty-path list: $DIRTY_OUT" >&2
  exit 1
fi
if ! grep -q '  a.md: ' <<<"$DIRTY_OUT" || ! grep -q '  b.md: ' <<<"$DIRTY_OUT"; then
  echo "FAIL: both dirty registered paths must still be reported on stdout: $DIRTY_OUT" >&2
  exit 1
fi
echo "OK: canonical fallback with real divergence warns exactly once on stderr, still reports both paths on stdout"

# Scenario 3: a pre-governance_worktree semaphore whose ORZ still lives under
# the governance checkout can recover that checkout identity safely. It must
# report the dirt without claiming that it fell back ambiguously.
mkdir -p "$CANON/sessions"
SEM_LEGACY_ORZ="$TEST_ROOT/sem-legacy-orz"
cat > "$SEM_LEGACY_ORZ" <<EOF
orz_sessions_dir: $CANON/sessions
file: a.md
EOF
run_scope_check "$SEM_LEGACY_ORZ" LEGACY_OUT LEGACY_ERR
if grep -q 'семафор без isolated_worktree' <<<"$LEGACY_ERR"; then
  echo "FAIL: legacy ORZ inside the governance repo should resolve that checkout without fallback warning: $LEGACY_ERR" >&2
  exit 1
fi
if ! grep -q '  a.md: ' <<<"$LEGACY_OUT"; then
  echo "FAIL: legacy ORZ checkout resolution must still report dirty governance paths: $LEGACY_OUT" >&2
  exit 1
fi
echo "OK: legacy ORZ path recovers a provably matching governance checkout"

# Scenario 4: isolated_worktree IS registered and valid -- close is checking
# the session's own copy, never the shared canonical one. No warning, ever,
# regardless of what canonical looks like (it is still dirty from scenario 2).
ISO="$TEST_ROOT/iso"
git clone -q "$CANON" "$ISO"
git -C "$ISO" config user.email i@test
git -C "$ISO" config user.name iso
SEM_ISO="$TEST_ROOT/sem-iso"
cat > "$SEM_ISO" <<EOF
isolated_worktree: $ISO
file: a.md
EOF
run_scope_check "$SEM_ISO" ISO_OUT ISO_ERR
if grep -q 'семафор без isolated_worktree' <<<"$ISO_ERR"; then
  echo "FAIL: a registered isolated_worktree must never trigger the canonical-fallback warning: $ISO_ERR" >&2
  exit 1
fi
echo "OK: a real isolated_worktree never triggers the canonical-fallback warning"

# Scenario 5 (cold-review finding, this session): no isolated_worktree, but
# the divergence is in the SEPARATE sessions_repo_dir fallback (WP-526 Ф2,
# MC-sessions content), not in canonical itself -- canonical stays clean for
# this registered path. The warning must NOT fire (it would name canonical,
# which is not where the divergence actually is), but the dirty line from
# sessions_repo_dir must still be reported.
SESSIONS="$TEST_ROOT/sessions-repo"
git init -q "$SESSIONS"
git -C "$SESSIONS" config user.email s@test
git -C "$SESSIONS" config user.name sessions
echo seed > "$SESSIONS/seed.md"
git -C "$SESSIONS" add seed.md
git -C "$SESSIONS" commit -q -m seed
echo "dirty s" > "$SESSIONS/s.md"  # untracked in sessions-repo, absent from canon
SEM_SESSIONS="$TEST_ROOT/sem-sessions"
cat > "$SEM_SESSIONS" <<EOF
orz_sessions_dir: $SESSIONS
file: s.md
EOF
run_scope_check "$SEM_SESSIONS" SESSIONS_OUT SESSIONS_ERR
if grep -q 'семафор без isolated_worktree' <<<"$SESSIONS_ERR"; then
  echo "FAIL: divergence in sessions_repo_dir must not trigger the canonical-fallback warning (canonical itself is clean): stderr=[$SESSIONS_ERR]" >&2
  exit 1
fi
if ! grep -q '  s.md: ' <<<"$SESSIONS_OUT"; then
  echo "FAIL: the sessions_repo_dir divergence must still be reported on stdout: $SESSIONS_OUT" >&2
  exit 1
fi
echo "OK: divergence found via sessions_repo_dir fallback is reported without a misleading canonical warning"

echo "PASS: governance checkout resolution preserves safe legacy fallbacks and warns only on ambiguous canonical divergence"
