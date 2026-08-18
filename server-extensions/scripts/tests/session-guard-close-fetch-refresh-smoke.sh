#!/usr/bin/env bash
# session-guard-close-fetch-refresh-smoke.sh — WP-484 (18.08, ArchGate "case Б-1"):
# _untracked_matches_published/validate_orz's published-ref check compares an
# untracked file against refs/remotes/*, which is only as fresh as the last
# fetch. _refresh_remote_refs_for_close() does one best-effort `git fetch`
# (3s timeout, WARN-and-continue on failure) before that comparison runs.
#
# Extracts the two functions by line range rather than sourcing the whole
# script -- session-guard.sh is a CLI entrypoint (argument parsing + exit at
# the bottom), not a function library, so a plain `source` would execute it.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
FUNCS_START=$(grep -n '^_untracked_matches_published()' "$GUARD" | head -1 | cut -d: -f1)
FUNCS_END=$(grep -n '^_refresh_remote_refs_for_close()' "$GUARD" | head -1 | cut -d: -f1)
FUNCS_END=$(awk -v start="$FUNCS_END" 'NR>=start && /^}/{print NR; exit}' "$GUARD")
[ -n "$FUNCS_START" ] && [ -n "$FUNCS_END" ] || { echo "FAIL: could not locate functions in $GUARD" >&2; exit 1; }
FUNCS_SRC=$(sed -n "${FUNCS_START},${FUNCS_END}p" "$GUARD")

TEST_ROOT=$(mktemp -d /private/tmp/session-guard-close-fetch.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

# A real bare origin -- not just a remote-add -- so `git fetch` has something
# genuine to pull, exercising the actual network-shaped code path.
ORIGIN="$TEST_ROOT/origin.git"
git init -q --bare "$ORIGIN"

CLONE_A="$TEST_ROOT/clone-a"   # publishes a file to origin
CLONE_B="$TEST_ROOT/clone-b"   # holds an untracked copy, stale refs/remotes
git clone -q "$ORIGIN" "$CLONE_A"
git -C "$CLONE_A" config user.email a@test
git -C "$CLONE_A" config user.name clone-a
echo seed > "$CLONE_A/README.md"
git -C "$CLONE_A" add README.md
git -C "$CLONE_A" commit -q -m seed
git -C "$CLONE_A" push -q origin main

git clone -q "$ORIGIN" "$CLONE_B"
git -C "$CLONE_B" config user.email b@test
git -C "$CLONE_B" config user.name clone-b

# Scenario 1: origin advances (clone-a pushes a new file) AFTER clone-b's last
# fetch. clone-b independently creates an untracked byte-identical copy of
# that same file -- the exact "content already published elsewhere" case
# _untracked_matches_published exists to recognize. Without a fresh fetch,
# clone-b's refs/remotes/* predates the push and the match must fail.
echo "published content" > "$CLONE_A/report.md"
git -C "$CLONE_A" add report.md
git -C "$CLONE_A" commit -q -m "publish report"
git -C "$CLONE_A" push -q origin main
echo "published content" > "$CLONE_B/report.md"  # untracked in clone-b

bash -c "
  $FUNCS_SRC
  _untracked_matches_published '$CLONE_B' report.md
" && STALE_MATCH_RC=0 || STALE_MATCH_RC=$?
if [ "$STALE_MATCH_RC" -eq 0 ]; then
  echo "FAIL: stale refs/remotes (no fetch yet) unexpectedly matched -- fixture invalid" >&2
  exit 1
fi
echo "OK: stale refs/remotes correctly misses a just-published file (fixture sanity)"

# Scenario 2: after _refresh_remote_refs_for_close does its fetch, the same
# comparison must now succeed -- this is the false-negative case-Б-1 fixes.
REFRESH_OUT=$(bash -c "
  $FUNCS_SRC
  _refresh_remote_refs_for_close '$CLONE_B' 2>&1
  _untracked_matches_published '$CLONE_B' report.md
") && FRESH_MATCH_RC=0 || FRESH_MATCH_RC=$?
if [ "$FRESH_MATCH_RC" -ne 0 ]; then
  echo "FAIL: after refresh, refs/remotes should recognize the published file: $REFRESH_OUT" >&2
  exit 1
fi
echo "OK: after _refresh_remote_refs_for_close, the just-published file is recognized"

# Scenario 3: unreachable origin -- fetch must fail closed on TIME, not on
# the caller: a WARN is printed, no exception propagates, and a SECOND call
# in the same process does not fetch again (REMOTE_REFS_REFRESHED_FOR_CLOSE
# guard) so a slow/offline network only costs one timeout per close, not one
# per refs/remotes reader.
CLONE_C="$TEST_ROOT/clone-c"
git clone -q "$ORIGIN" "$CLONE_C"
git -C "$CLONE_C" remote set-url origin "https://127.0.0.1:1/nonexistent-origin.git"
OFFLINE_OUT=$(bash -c "
  $FUNCS_SRC
  _refresh_remote_refs_for_close '$CLONE_C'
  _refresh_remote_refs_for_close '$CLONE_C'
  echo REFRESH_CALLED_TWICE_OK
" 2>&1) && OFFLINE_RC=0 || OFFLINE_RC=$?
if [ "$OFFLINE_RC" -ne 0 ]; then
  echo "FAIL: unreachable origin must degrade gracefully, not abort the caller: $OFFLINE_OUT" >&2
  exit 1
fi
if ! grep -q 'не удался/не уложился' <<<"$OFFLINE_OUT"; then
  echo "FAIL: unreachable origin must print the fallback WARN: $OFFLINE_OUT" >&2
  exit 1
fi
if ! grep -q 'REFRESH_CALLED_TWICE_OK' <<<"$OFFLINE_OUT"; then
  echo "FAIL: second refresh call in the same process must not re-abort: $OFFLINE_OUT" >&2
  exit 1
fi
WARN_COUNT=$(grep -c 'не удался/не уложился' <<<"$OFFLINE_OUT")
if [ "$WARN_COUNT" -ne 1 ]; then
  echo "FAIL: expected exactly one fetch attempt (once-per-close guard), got $WARN_COUNT WARNs: $OFFLINE_OUT" >&2
  exit 1
fi
echo "OK: unreachable origin warns once, degrades to cache, second call in-process is a no-op"

echo "PASS: session-guard close-time remote-refs refresh"
