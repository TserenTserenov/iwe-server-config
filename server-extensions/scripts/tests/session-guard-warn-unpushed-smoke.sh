#!/usr/bin/env bash
# session-guard-warn-unpushed-smoke.sh -- WP-561 Ч2.
#
# close's "unpushed commits" warning used to count HEAD...origin/main over the
# whole checkout, so another agent's local commits in a shared checkout made
# every close warn about work that is not this session's. The warning must now
# cover only commits this session claimed (note-commit claims and the PREPARED
# source set); the rest of the local-only commits is an info line.
#
# The helpers live inside close() as nested functions, so they are extracted
# from the shipped session-guard.sh (not copied) and driven against a sandbox
# repo + a hand-built semaphore. Nothing here touches ~/IWE or real semaphores.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="$ROOT_DIR/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-warn-unpushed.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE="$TEST_ROOT/fixture.sh"
: > "$FIXTURE"
extract_fn() {  # <indent> <function-name> -- top-level (indent "") or nested ("  ")
  awk -v ind="$1" -v fn="$2" '
    index($0, ind fn "() {") == 1 { active = 1 }
    active {
      print
      if (!inpy && $0 ~ /<<.PY./) { inpy = 1; next }
      if (inpy && $0 == "PY") { inpy = 0; next }
      if (!inpy && $0 == ind "}") { active = 0; exit }
    }
  ' "$GUARD"
}
extract_fn "" _unique_record_field >> "$FIXTURE"
for fn in _session_claimed_commits _session_commit_is_delivered _warn_unpushed; do
  extract_fn "  " "$fn" >> "$FIXTURE"
  grep -q "^  ${fn}() {" "$FIXTURE" || { echo "FAIL: fixture setup -- ${fn}() not found in session-guard.sh" >&2; exit 1; }
done
# shellcheck source=/dev/null
source "$FIXTURE"

fail_test() { echo "FAIL: $1" >&2; exit 1; }

ORIGIN="$TEST_ROOT/origin.git"
REPO="$TEST_ROOT/repo"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" remote add origin "$ORIGIN"
commit() {  # <file> -> prints the new HEAD
  echo "$1 $RANDOM" > "$REPO/$1"
  git -C "$REPO" add "$1"
  git -C "$REPO" commit -qm "$1"
  git -C "$REPO" rev-parse HEAD
}
commit base >/dev/null
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin

_sem_read="$TEST_ROOT/sem.closed"
warn_output() { { _warn_unpushed "$REPO" >/dev/null; } 2>&1; }

# --- T1: a foreign local commit only -> no warning about this session, info line.
printf 'wp: WP-561\n' > "$_sem_read"
commit foreign >/dev/null
OUT=$(warn_output)
case "$OUT" in *"коммита этой сессии"*) fail_test "T1: warned about a foreign local commit as if it were ours: $OUT" ;; esac
case "$OUT" in *"ещё 1 чужих локальных коммитов"*) ;; *) fail_test "T1: info line about foreign commits missing: $OUT" ;; esac
echo "PASS: T1 -- foreign local commit gives an info line, not a warning"

# --- T2: our own undelivered claimed commit -> warning, foreign count excludes it.
OWN=$(commit own)
printf 'wp: WP-561\ncommit: repo %s\n' "$OWN" > "$_sem_read"
OUT=$(warn_output)
case "$OUT" in *"1 незапушенных коммита этой сессии"*) ;; *) fail_test "T2: no warning about our own unpushed commit: $OUT" ;; esac
case "$OUT" in *"ещё 1 чужих локальных коммитов"*) ;; *) fail_test "T2: foreign count should stay 1 (own commit excluded): $OUT" ;; esac
echo "PASS: T2 -- own unpushed commit warns; foreign count excludes it"

# --- T3: own commit delivered by cherry-pick (different OID upstream) -> no warning.
git -C "$REPO" clone -q "$ORIGIN" "$TEST_ROOT/other"
git -C "$TEST_ROOT/other" config user.email test@example.com
git -C "$TEST_ROOT/other" config user.name Test
git -C "$TEST_ROOT/other" fetch -q "$REPO" main
git -C "$TEST_ROOT/other" cherry-pick "$OWN" >/dev/null
git -C "$TEST_ROOT/other" push -q origin HEAD:main
git -C "$REPO" fetch -q origin
OUT=$(warn_output)
case "$OUT" in *"коммита этой сессии"*) fail_test "T3: patch-equivalent own commit still warned: $OUT" ;; esac
echo "PASS: T3 -- patch-equivalent (cherry-picked) own commit is delivered"

# --- T4: the PREPARED source set counts as claimed too.
SRC=$(git -C "$REPO" rev-list -n1 --grep=foreign HEAD)
printf 'wp: WP-561\nclose_delivery_source_commits: ["%s"]\n' "$SRC" > "$_sem_read"
OUT=$(warn_output)
case "$OUT" in *"1 незапушенных коммита этой сессии"*) ;; *) fail_test "T4: close_delivery_source_commits not treated as ours: $OUT" ;; esac
echo "PASS: T4 -- close_delivery_source_commits are this session's commits"

echo "ALL PASS: session-guard-warn-unpushed-smoke.sh"
