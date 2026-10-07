#!/usr/bin/env bash
# PREPARED-state cases for `note-commit --forget` (WP-7 Ф209 / WP-484 Ф179,
# 07.10, peer-session 2026-10-07-05-wp484-session-close, Claude+Kimi+Codex).
# Companion to session-guard-note-commit-forget-smoke.sh (state=none cases).
#
# close_delivery_claimed_commits/close_delivery_prepare_digest are
# single-occurrence fields once PREPARE has run (_close_delivery_state
# requires exactly one of each): forgetting a claim here must REPLACE both
# in place, not append a second copy, and the replacement list must already
# be sorted (_close_delivery_state: claimed != sorted(set(claimed)) ->
# invalid) -- cold review (Codex, same peer-session) caught a real bug here:
# an unsorted leftover list silently broke the very next PREPARE validation.
# This test builds the fixture with the claims in non-alphabetical raw order
# specifically to catch a regression of that bug.
#
# The PREPARE snapshot itself is built through the real _record_close_prepared
# (extracted, not re-implemented -- see session-guard-abandon-prepared-smoke.sh
# for the same technique) so this test fails on a genuine behavior change in
# note-commit --forget, not on a hand-rolled fixture drifting from the real
# field format.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-commit-forget-prepared.XXXXXX")
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

# --- extract the real PREPARE machinery for fixture setup and verification ---
# (same awk state machine as session-guard-abandon-prepared-smoke.sh: a plain
# sed range breaks on the embedded python heredoc's own closing brace).
FIXTURE="$TEST_ROOT/fixture.sh"
: > "$FIXTURE"
extract_fn() {  # <function-name>
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { active = 1 }
    active {
      print
      if (!inpy && $0 ~ /<<.PY./) { inpy = 1; next }
      if (inpy && $0 == "PY") { inpy = 0; next }
      if (!inpy && $0 == "}") { active = 0; exit }
    }
  ' "$GUARD"
}
for fn in _unique_record_field _terminal_proof_snapshot_sha _owned_semaphore_snapshot_sha \
          _append_close_fields_atomic _record_close_prepared _close_delivery_state; do
  extract_fn "$fn" >> "$FIXTURE"
  printf '\n' >> "$FIXTURE"
done
for fn in _unique_record_field _terminal_proof_snapshot_sha _owned_semaphore_snapshot_sha \
          _append_close_fields_atomic _record_close_prepared _close_delivery_state; do
  grep -q "^${fn}() {" "$FIXTURE" \
    || { echo "FAIL: fixture setup -- ${fn}() not found, extraction anchor no longer matches session-guard.sh" >&2; exit 1; }
done
# shellcheck source=/dev/null
source "$FIXTURE"

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

guard open --wp WP-999 --agent fixture --slug prepfgt --task prepfgt >/dev/null 2>&1
SEM=$(find "$TEST_ROOT/.iwe-runtime/sessions" -name 'fixture-*.open' | head -1)
[ -n "$SEM" ] || { echo "FAIL: fixture session did not open"; exit 1; }
SESSION_ID=$(sed -n 's/^session_id: //p' "$SEM" | head -1)
[ -n "$SESSION_ID" ] || { echo "FAIL: semaphore has no session_id: field"; exit 1; }

commit_file() {  # <name> -> prints HEAD sha, one commit on work-repo's current branch
  printf 'content for %s\n' "$1" > "$WORK/$1"
  git -C "$WORK" add "$1"
  git -C "$WORK" commit -q -m "$1"
  git -C "$WORK" rev-parse HEAD
}

# Three claims for work-repo, deliberately checked for non-sorted raw order
# (repo name is constant, so order depends only on the resulting shas, which
# are unpredictable) -- the test is not a silent no-op on a lucky run.
build_three_claims() {
  local a b c
  a=$(commit_file one.txt); b=$(commit_file two.txt); c=$(commit_file three.txt)
  printf '%s\n%s\n%s\n' "work-repo $a" "work-repo $b" "work-repo $c"
}
CLAIM_LINES=$(build_three_claims)
SORTED_LINES=$(printf '%s\n' "$CLAIM_LINES" | sort)
ATTEMPTS=0
while [ "$CLAIM_LINES" = "$SORTED_LINES" ] && [ "$ATTEMPTS" -lt 5 ]; do
  CLAIM_LINES=$(build_three_claims)
  SORTED_LINES=$(printf '%s\n' "$CLAIM_LINES" | sort)
  ATTEMPTS=$((ATTEMPTS + 1))
done
HEAD_SHA=$(printf '%s\n' "$CLAIM_LINES" | tail -1 | cut -d' ' -f2)
EXTRA_SHA_1=$(printf '%s\n' "$CLAIM_LINES" | sed -n 1p | cut -d' ' -f2)
EXTRA_SHA_2=$(printf '%s\n' "$CLAIM_LINES" | sed -n 2p | cut -d' ' -f2)

for sha in "$EXTRA_SHA_1" "$EXTRA_SHA_2" "$HEAD_SHA"; do
  guard note-commit "$sha" --repo work-repo --agent fixture --slug prepfgt >/dev/null 2>&1
done

TERMINAL_FILE="$TEST_ROOT/terminal.txt"
printf 'terminal-anchor\n' > "$TERMINAL_FILE"
TERMINAL_SHA=$(_terminal_proof_snapshot_sha file "$TERMINAL_FILE")
PLACEHOLDER_STATUS_SHA=$(git -C "$WORK" hash-object -t blob /dev/null)
COMMITS_JSON=$(python3 -c "import json,sys; print(json.dumps([sys.argv[1]]))" "$HEAD_SHA")
# claimed_commits must list every current claim, source and "additional"
# alike (_close_delivery_state: sorted(claimed) must equal the raw commit:
# lines) -- not just the source set _record_close_prepared itself tracks
# separately in source_commits/expected_commits.
CLAIMS_JSON=$(printf '%s\n' "$CLAIM_LINES" | python3 -c "import json,sys; print(json.dumps(sorted(l.strip() for l in sys.stdin if l.strip())))")
# Only HEAD_SHA is source/expected; the two extras are "additional" claims --
# exactly the class note-commit --forget exists for.
_record_close_prepared "$SEM" "$SESSION_ID" "$WORK" "$WORK/.git" \
  "$HEAD_SHA" "$HEAD_SHA" "$PLACEHOLDER_STATUS_SHA" \
  "$COMMITS_JSON" "$CLAIMS_JSON" file "$TERMINAL_FILE" "$TERMINAL_SHA" \
  "https://example.invalid/work-repo.git" "refs/heads/main" >/dev/null \
  || { echo "FAIL: fixture setup -- _record_close_prepared failed"; exit 1; }

check "fixture: state is prepared before any forget" "prepared" "$(_close_delivery_state "$SEM" "$SESSION_ID")"
check "fixture: claims built in non-sorted raw order (or exhausted retries)" "0" \
  "$([ "$CLAIM_LINES" != "$SORTED_LINES" ]; echo $?)"

# --- the regression case: forget one additional claim, state must stay valid --
OUT=$(guard note-commit --forget "$EXTRA_SHA_1" --repo work-repo --agent fixture --slug prepfgt 2>&1); RC=$?
check "prepared, additional claim: forget succeeds" "0" "$RC"
check "prepared, additional claim: raw line removed" "0" "$(grep -cxF "commit: work-repo $EXTRA_SHA_1" "$SEM")"
check "prepared, additional claim: other extra claim kept" "1" "$(grep -cxF "commit: work-repo $EXTRA_SHA_2" "$SEM")"
check "prepared, additional claim: source claim untouched" "1" "$(grep -cxF "commit: work-repo $HEAD_SHA" "$SEM")"
NEW_STATE=$(_close_delivery_state "$SEM" "$SESSION_ID" || echo "INVALID")
check "prepared, additional claim: semaphore still validates as prepared (the bug Codex caught)" "prepared" "$NEW_STATE"
NEW_CLAIMED=$(sed -n 's/^close_delivery_claimed_commits: //p' "$SEM" | tail -1)
check "close_delivery_claimed_commits no longer lists the forgotten claim" "0" \
  "$(python3 -c "import json,sys; print(1 if sys.argv[1] in json.loads(sys.argv[2]) else 0)" "work-repo $EXTRA_SHA_1" "$NEW_CLAIMED")"
check "close_delivery_claimed_commits is stored sorted" "0" \
  "$(python3 -c "
import json, sys
claimed = json.loads(sys.argv[1])
print(0 if claimed == sorted(set(claimed)) else 1)
" "$NEW_CLAIMED")"
check "close_delivery_claimed_commits single occurrence (replaced, not appended)" "1" \
  "$(grep -c '^close_delivery_claimed_commits: ' "$SEM")"
check "close_delivery_prepare_digest single occurrence (replaced, not appended)" "1" \
  "$(grep -c '^close_delivery_prepare_digest: ' "$SEM")"
check "audit log recorded the prepared-state forget" "1" \
  "$(grep -c "forget-intent.*work-repo $EXTRA_SHA_1" "$TEST_ROOT/.iwe-runtime/note-commit-forget.log" 2>/dev/null || echo 0)"

# --- refusal: a source/expected commit may not be forgotten --------------------
guard note-commit --forget "$HEAD_SHA" --repo work-repo --agent fixture --slug prepfgt >/dev/null 2>&1; RC=$?
check "prepared, source commit: refused" "1" "$RC"
check "prepared, source commit: claim kept" "1" "$(grep -cxF "commit: work-repo $HEAD_SHA" "$SEM")"
check "prepared, source commit: state still prepared after refusal" "prepared" "$(_close_delivery_state "$SEM" "$SESSION_ID")"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: note-commit --forget (PREPARED-state cases, sorted-claims regression)"
  exit 0
fi
echo "FAIL: $FAILURES check(s) failed"
exit 1
