#!/usr/bin/env bash
# PREPARED-state cases for `note-commit --forget-unprovable` (WP-484 Ф198-А,
# 22.10, peer-session 2026-10-22-18-wp484-f198-forget-unprovable-retry).
# Companion to session-guard-note-commit-forget-unprovable-smoke.sh
# (state=none cases) and to session-guard-note-commit-forget-prepared-smoke.sh
# (the single-target --forget this batches).
#
# Same invariant as the single-target PREPARED path: close_delivery_claimed_
# commits/close_delivery_prepare_digest are single-occurrence fields once
# PREPARE has run, and a target that is part of close_delivery_source_commits
# or close_delivery_expected_commits must never be forgotten (it would weaken
# the delivery proof). For the batch command this must fail CLOSED for the
# WHOLE batch if even one of the found-unprovable targets is a source/
# expected commit -- not silently drop the problematic one and remove the
# rest.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-commit-forget-unprovable-prepared.XXXXXX")
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

commit_file() {  # <name> -> prints HEAD sha, one commit on work-repo's current branch
  printf 'content for %s\n' "$1" > "$WORK/$1"
  git -C "$WORK" add "$1"
  git -C "$WORK" commit -q -m "$1"
  git -C "$WORK" rev-parse HEAD
}

build_fixture() {  # <slug> [publish_head=0] -- opens a fresh session, builds a
                    # 4-claim PREPARED snapshot (1 source + 3 additional);
                    # publish_head=1 pushes the source commit to a fresh bare
                    # origin FIRST, so it (unlike the three additional claims)
                    # has independent publish proof, modelling the real
                    # scenario this batch command targets: the source commit
                    # already delivered, stray additional claims were not.
                    # Prints "sem session_id head extra1 extra2 extra3".
  local slug="$1" publish_head="${2:-0}" sem session_id head extra1 extra2 extra3
  guard open --wp WP-999 --agent fixture --slug "$slug" --task "$slug" >/dev/null 2>&1
  sem=$(grep -lxF "slug: $slug" "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open 2>/dev/null | head -1)
  [ -n "$sem" ] || { echo "FAIL: fixture session '$slug' did not open" >&2; exit 1; }
  session_id=$(sed -n 's/^session_id: //p' "$sem" | head -1)
  [ -n "$session_id" ] || { echo "FAIL: semaphore '$sem' has no session_id: field" >&2; exit 1; }

  head=$(commit_file "$slug-head.txt")
  if [ "$publish_head" = "1" ]; then
    local origin="$TEST_ROOT/$slug-origin.git"
    git init -q --bare "$origin"
    git -C "$WORK" remote add origin "$origin" 2>/dev/null || git -C "$WORK" remote set-url origin "$origin"
    git -C "$WORK" push -q origin HEAD:refs/heads/main
  fi
  extra1=$(commit_file "$slug-extra1.txt")
  extra2=$(commit_file "$slug-extra2.txt")
  extra3=$(commit_file "$slug-extra3.txt")
  for sha in "$head" "$extra1" "$extra2" "$extra3"; do
    guard note-commit "$sha" --repo work-repo --agent fixture --slug "$slug" >/dev/null 2>&1
  done

  local terminal_file placeholder_status_sha commits_json claims_json
  terminal_file="$TEST_ROOT/$slug-terminal.txt"
  printf 'terminal-anchor-%s\n' "$slug" > "$terminal_file"
  placeholder_status_sha=$(git -C "$WORK" hash-object -t blob /dev/null)
  commits_json=$(python3 -c "import json,sys; print(json.dumps([sys.argv[1]]))" "$head")
  claims_json=$(python3 -c "
import json, sys
print(json.dumps(sorted('work-repo ' + s for s in sys.argv[1:])))
" "$head" "$extra1" "$extra2" "$extra3")
  _record_close_prepared "$sem" "$session_id" "$WORK" "$WORK/.git" \
    "$head" "$head" "$placeholder_status_sha" \
    "$commits_json" "$claims_json" file "$terminal_file" "$(_terminal_proof_snapshot_sha file "$terminal_file")" \
    "https://example.invalid/work-repo.git" "refs/heads/main" >/dev/null \
    || { echo "FAIL: fixture setup ($slug) -- _record_close_prepared failed" >&2; exit 1; }

  printf '%s %s %s %s %s %s\n' "$sem" "$session_id" "$head" "$extra1" "$extra2" "$extra3"
}

# --- scenario A: all three "additional" claims are unprovable, removed in one batch ---
read -r SEM_A SESSION_A HEAD_A EXTRA_A1 EXTRA_A2 EXTRA_A3 <<<"$(build_fixture forget-unprov-a 1)"
check "scenario A: state is prepared before batch forget" "prepared" "$(_close_delivery_state "$SEM_A" "$SESSION_A")"

guard note-commit --forget-unprovable --repo work-repo --agent fixture --slug forget-unprov-a >/dev/null 2>&1; RC=$?
check "scenario A: batch forget succeeds" "0" "$RC"
check "scenario A: extra1 removed" "0" "$(grep -cxF "commit: work-repo $EXTRA_A1" "$SEM_A")"
check "scenario A: extra2 removed" "0" "$(grep -cxF "commit: work-repo $EXTRA_A2" "$SEM_A")"
check "scenario A: extra3 removed" "0" "$(grep -cxF "commit: work-repo $EXTRA_A3" "$SEM_A")"
check "scenario A: source (head) claim untouched" "1" "$(grep -cxF "commit: work-repo $HEAD_A" "$SEM_A")"
NEW_STATE_A=$(_close_delivery_state "$SEM_A" "$SESSION_A" || echo "INVALID")
check "scenario A: semaphore still validates as prepared" "prepared" "$NEW_STATE_A"
check "scenario A: close_delivery_claimed_commits single occurrence" "1" \
  "$(grep -c '^close_delivery_claimed_commits: ' "$SEM_A")"
check "scenario A: close_delivery_prepare_digest single occurrence" "1" \
  "$(grep -c '^close_delivery_prepare_digest: ' "$SEM_A")"
NEW_CLAIMED_A=$(sed -n 's/^close_delivery_claimed_commits: //p' "$SEM_A" | tail -1)
check "scenario A: claimed_commits is stored sorted" "0" \
  "$(python3 -c "
import json, sys
claimed = json.loads(sys.argv[1])
print(0 if claimed == sorted(set(claimed)) else 1)
" "$NEW_CLAIMED_A")"
check "scenario A: claimed_commits lists only the source claim now" "1" \
  "$(python3 -c "
import json, sys
claimed = json.loads(sys.argv[1])
print(1 if claimed == [sys.argv[2]] else 0)
" "$NEW_CLAIMED_A" "work-repo $HEAD_A")"

# --- scenario B: one of the unprovable targets is the PREPARE source commit;
# whole batch must refuse, nothing removed (fail-closed, not partial) -------
read -r SEM_B SESSION_B HEAD_B EXTRA_B1 EXTRA_B2 EXTRA_B3 <<<"$(build_fixture forget-unprov-b)"
# Make the source commit itself look "unprovable" too (it has no independent
# proof either in this fixture -- same as every other claim): if the batch
# naively removed every unprovable target it would also remove HEAD_B, which
# close_delivery_source_commits forbids.
guard note-commit --forget-unprovable --repo work-repo --agent fixture --slug forget-unprov-b >/dev/null 2>&1; RC=$?
check "scenario B: batch refuses when a source commit is among the unprovable targets" "1" "$RC"
check "scenario B: head (source) claim kept" "1" "$(grep -cxF "commit: work-repo $HEAD_B" "$SEM_B")"
check "scenario B: extra1 kept (fail-closed, no partial removal)" "1" "$(grep -cxF "commit: work-repo $EXTRA_B1" "$SEM_B")"
check "scenario B: extra2 kept (fail-closed, no partial removal)" "1" "$(grep -cxF "commit: work-repo $EXTRA_B2" "$SEM_B")"
check "scenario B: extra3 kept (fail-closed, no partial removal)" "1" "$(grep -cxF "commit: work-repo $EXTRA_B3" "$SEM_B")"
check "scenario B: state still prepared after refusal" "prepared" "$(_close_delivery_state "$SEM_B" "$SESSION_B")"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: note-commit --forget-unprovable (PREPARED-state cases: batch removal keeps source claim, fail-closed on source-commit collision)"
  exit 0
fi
echo "FAIL: $FAILURES check(s) failed"
exit 1
