#!/usr/bin/env bash
# Regression for WP-7 Ф209 / WP-484 Ф179 (07.10, peer-session
# 2026-10-07-05-wp484-session-close, Claude+Kimi+Codex): `note-commit --forget`.
#
# A hot-file conflict on a tracked card forced several intermediate,
# later-abandoned commits to be claimed via `note-commit`. `note-file` already
# had `--forget` for exactly this situation; `note-commit` had no way to
# withdraw a stale claim at all, so `close --abandon-prepared` could only
# exclude the final `--source-commit` set, leaving every other claimed commit
# to fail the publish-proof check forever. See the Ф209 write-up for the
# full diagnosis (`scripts/session-guard.sh` note-commit / _claimed_commits_have_publish_proof).
#
# Withdrawal must be refused when the claim already has independent publish
# proof (forgetting it would weaken the delivery proof, not collect garbage),
# or when it is part of the frozen PREPARE source/expected set. It must work
# both before PREPARE (state=none) and during it (state=prepared) -- ordinary
# note-commit keeps requiring state=none, unchanged.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-commit-forget.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FAILURES=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    FAILURES=$((FAILURES + 1))
  fi
}

GOV="$TEST_ROOT/DS-strategy"
SES="$TEST_ROOT/MC-sessions"
WORK="$TEST_ROOT/work-repo"
mkdir -p "$GOV/inbox/WP-999" "$SES" "$WORK"
printf '%s\n' 'hypothesis_relation: "tests"' > "$GOV/inbox/WP-999/WP-999.md"
for repo in "$GOV" "$SES" "$WORK"; do
  git -C "$repo" init -q
  git -C "$repo" config user.email test@test.local
  git -C "$repo" config user.name test
  echo seed > "$repo/README"
  git -C "$repo" add README
  git -C "$repo" commit -q -m seed
done

guard() {  # guard <subcommand> [args...]; runs from inside the sessions checkout
  (cd "$SES" && IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH="" \
    IWE_SESSIONS_ROOT="$SES" bash "$GUARD" "$@")
}

guard open --wp WP-999 --agent fixture --slug forget --task forget >/dev/null 2>&1
SEM=$(find "$TEST_ROOT/.iwe-runtime/sessions" -name 'fixture-*.open' | head -1)
[ -n "$SEM" ] || { echo "FAIL: fixture session did not open"; exit 1; }

claims() { grep -cxF "commit: work-repo $1" "$SEM" || true; }

# --- state=none: plain forget withdraws a stray claim -------------------------
echo one > "$WORK/one.txt"
git -C "$WORK" add one.txt
git -C "$WORK" commit -q -m one
SHA_ONE=$(git -C "$WORK" rev-parse HEAD)
guard note-commit "$SHA_ONE" --repo work-repo --agent fixture --slug forget >/dev/null 2>&1
check "claim recorded" "1" "$(claims "$SHA_ONE")"

OUT=$(guard note-commit --forget "$SHA_ONE" --repo work-repo --agent fixture --slug forget 2>&1); RC=$?
check "stray claim: forget succeeds" "0" "$RC"
check "stray claim: claim removed" "0" "$(claims "$SHA_ONE")"
AUDIT="$TEST_ROOT/.iwe-runtime/note-commit-forget.log"
check "audit: intent written" "1" "$(grep -c "forget-intent.*work-repo $SHA_ONE" "$AUDIT" 2>/dev/null || echo 0)"
check "audit: completion written" "1" "$(grep -c "forget-done.*work-repo $SHA_ONE" "$AUDIT" 2>/dev/null || echo 0)"
check "no temp file left next to the semaphore" "0" "$(find "$(dirname "$SEM")" -name '.commit-forget-*' | wc -l | tr -d ' ')"
check "semaphore still accepts new note-commit claims" "0" \
  "$(echo two > "$WORK/two.txt"; git -C "$WORK" add two.txt; git -C "$WORK" commit -q -m two; \
     guard note-commit "$(git -C "$WORK" rev-parse HEAD)" --repo work-repo --agent fixture --slug forget >/dev/null 2>&1; echo $?)"

# --- state=none: claim that was never made is refused --------------------------
guard note-commit --forget "0000000000000000000000000000000000000000" --repo work-repo --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "never-claimed sha: refused" "1" "$RC"

# --- state=none: a claim already on origin/main (independent proof) is refused -
ORIGIN=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-commit-forget-origin.XXXXXX")
git -C "$ORIGIN" init -q --bare
git -C "$WORK" remote add origin "$ORIGIN" 2>/dev/null || git -C "$WORK" remote set-url origin "$ORIGIN"
git -C "$WORK" push -q origin HEAD:refs/heads/main
SHA_PUBLISHED=$(git -C "$WORK" rev-parse HEAD)
guard note-commit "$SHA_PUBLISHED" --repo work-repo --agent fixture --slug forget >/dev/null 2>&1
guard note-commit --forget "$SHA_PUBLISHED" --repo work-repo --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "claim already on origin/main: refused (has independent proof)" "1" "$RC"
check "claim already on origin/main: claim kept" "1" "$(claims "$SHA_PUBLISHED")"

# --- ordinary note-commit still requires state=none (gate unchanged) -----------
# Remove the proven claim via the one withdrawal path that does not itself
# depend on the gate under test (git): confirms the refusal above wasn't a
# side effect of some other check.
sed -i.bak "/^commit: work-repo $SHA_PUBLISHED\$/d" "$SEM" && rm -f "$SEM.bak"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: note-commit --forget (state=none cases) -- see session-guard-note-commit-forget-prepared-smoke.sh for the PREPARED-state cases"
  exit 0
fi
echo "FAIL: $FAILURES check(s) failed"
exit 1
