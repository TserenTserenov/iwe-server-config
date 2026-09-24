#!/usr/bin/env bash
# Regression for WP-484 (21.09, peer-session 2026-09-21-08): `note-file --forget`.
# A path the hook claimed (report-draft.md) was renamed away before its first
# commit; the claim stayed in the semaphore and the close proof refused with
# "path not found in any checkout", with no way to withdraw it.
#
# The withdrawal must be possible ONLY when there is nothing to deliver: the path
# is absent on disk, in HEAD and in the index of both session checkouts, and not
# in the diff of any declared commit. Every other case keeps the claim.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-forget.XXXXXX)
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
mkdir -p "$GOV/inbox/WP-001" "$SES"
printf '%s\n' 'hypothesis_relation: "tests"' > "$GOV/inbox/WP-001/WP-001.md"
for repo in "$GOV" "$SES"; do
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

guard open --wp WP-001 --agent fixture --slug forget --task forget >/dev/null 2>&1
SEM=$(find "$TEST_ROOT/.iwe-runtime/sessions" -name 'fixture-*.open' | head -1)
[ -n "$SEM" ] || { echo "FAIL: fixture session did not open"; exit 1; }
# `open` self-claims its own ORZ scaffold under today's date (now_date() in
# session-guard.sh); a fixed date string here would go stale the day after
# it's written (found live 24.09 -- the fixture was written 21.09). Read the
# actual name `open` recorded instead of guessing it.
ORZ_REL=$(sed -n 's/^orz_file: //p' "$SEM")
[ -n "$ORZ_REL" ] || { echo "FAIL: semaphore has no orz_file: field"; exit 1; }

claims() { grep -c "^file: $1\$" "$SEM" || true; }
REL="2026-09/21/forget"

# --- the live case: claimed draft renamed before the first commit ------------
mkdir -p "$SES/$REL"
echo draft > "$SES/$REL/report-draft.md"
guard note-file "$SES/$REL/report-draft.md" --agent fixture --slug forget >/dev/null 2>&1
check "claim recorded" "1" "$(claims "$REL/report-draft.md")"
mv "$SES/$REL/report-draft.md" "$SES/$REL/report.md"
guard note-file "$SES/$REL/report.md" --agent fixture --slug forget >/dev/null 2>&1

OUT=$(guard note-file --forget "$REL/report-draft.md" --agent fixture --slug forget 2>&1); RC=$?
check "renamed-away draft: forget succeeds" "0" "$RC"
check "renamed-away draft: claim removed" "0" "$(claims "$REL/report-draft.md")"
check "the renamed file's own claim untouched" "1" "$(claims "$REL/report.md")"
check "other claims untouched (ORZ scaffold)" "1" "$(grep -Fxc "file: $ORZ_REL" "$SEM")"
AUDIT="$TEST_ROOT/.iwe-runtime/note-file-forget.log"
check "audit: intent written before the change" "1" "$(grep -c "forget-intent.*$REL/report-draft.md" "$AUDIT" 2>/dev/null || echo 0)"
check "audit: completion written after the change" "1" "$(grep -c "forget-done.*$REL/report-draft.md" "$AUDIT" 2>/dev/null || echo 0)"
check "no temp file left next to the semaphore" "0" "$(find "$(dirname "$SEM")" -name '.forget-*' | wc -l | tr -d ' ')"
check "semaphore still accepts new claims" "0" "$(echo draft2 > "$SES/$REL/x.md"; guard note-file "$SES/$REL/x.md" --agent fixture --slug forget >/dev/null 2>&1; echo $?)"

# --- absolute path form ------------------------------------------------------
echo tmp > "$SES/$REL/gone.md"
guard note-file "$SES/$REL/gone.md" --agent fixture --slug forget >/dev/null 2>&1
rm "$SES/$REL/gone.md"
guard note-file --forget "$SES/$REL/gone.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "absolute path form: forget succeeds" "0" "$RC"
check "absolute path form: claim removed" "0" "$(claims "$REL/gone.md")"

# --- refusals: the claim is legitimate and must stay --------------------------
guard note-file --forget "$REL/report.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "path exists on disk: refused" "1" "$RC"
check "path exists on disk: claim kept" "1" "$(claims "$REL/report.md")"

echo tracked > "$SES/$REL/tracked.md"
guard note-file "$SES/$REL/tracked.md" --agent fixture --slug forget >/dev/null 2>&1
git -C "$SES" add "$REL/tracked.md"
git -C "$SES" commit -q -m tracked -- "$REL/tracked.md"
rm "$SES/$REL/tracked.md"   # deleted on disk, still in HEAD: the deletion is a change to deliver
guard note-file --forget "$REL/tracked.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "path in HEAD (deleted on disk): refused" "1" "$RC"
check "path in HEAD: claim kept" "1" "$(claims "$REL/tracked.md")"
git -C "$SES" checkout -q -- "$REL/tracked.md"

echo staged > "$SES/$REL/staged.md"
guard note-file "$SES/$REL/staged.md" --agent fixture --slug forget >/dev/null 2>&1
git -C "$SES" add "$REL/staged.md"
guard note-file --forget "$REL/staged.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "path in the index: refused" "1" "$RC"
git -C "$SES" reset -q -- "$REL/staged.md"

# path only in a declared commit's diff: absent on disk, in HEAD and index (deleted by a later commit)
echo once > "$SES/$REL/once.md"
guard note-file "$SES/$REL/once.md" --agent fixture --slug forget >/dev/null 2>&1
git -C "$SES" add "$REL/once.md"
git -C "$SES" commit -q -m once -- "$REL/once.md"
ONCE_SHA=$(git -C "$SES" rev-parse HEAD)
guard note-commit "$ONCE_SHA" --repo MC-sessions --agent fixture --slug forget >/dev/null 2>&1
git -C "$SES" rm -q "$REL/once.md"
git -C "$SES" commit -q -m "drop once" -- "$REL/once.md"
guard note-file --forget "$REL/once.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "path in a declared commit: refused" "1" "$RC"
check "path in a declared commit: claim kept" "1" "$(claims "$REL/once.md")"

guard note-file --forget "$REL/never-claimed.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "path without a claim: refused" "1" "$RC"

# `./x` and other spellings never match a recorded claim by accident
guard note-file --forget "./$REL/report.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "dot-prefixed spelling does not match: refused" "1" "$RC"
check "the real claim survives the dot-prefixed attempt" "1" "$(claims "$REL/report.md")"

# --- merge commit: a plain `diff-tree -r` prints nothing for it, `-m` does ------
git -C "$SES" checkout -q -b side
echo merged > "$SES/$REL/merged.md"
guard note-file "$SES/$REL/merged.md" --agent fixture --slug forget >/dev/null 2>&1
git -C "$SES" add "$REL/merged.md"
git -C "$SES" commit -q -m "side change" -- "$REL/merged.md"
git -C "$SES" checkout -q -
echo mainline > "$SES/$REL/mainline.md"
git -C "$SES" add "$REL/mainline.md"
git -C "$SES" commit -q -m "main change" -- "$REL/mainline.md"
git -C "$SES" merge -q --no-ff side -m "merge side" >/dev/null 2>&1
MERGE_SHA=$(git -C "$SES" rev-parse HEAD)
guard note-commit "$MERGE_SHA" --repo MC-sessions --agent fixture --slug forget >/dev/null 2>&1
git -C "$SES" rm -q "$REL/merged.md" "$REL/mainline.md"
git -C "$SES" commit -q -m "drop merged" >/dev/null 2>&1
guard note-file --forget "$REL/merged.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "path in a declared merge commit: refused" "1" "$RC"
check "path in a declared merge commit: claim kept" "1" "$(claims "$REL/merged.md")"

# --- a commit claim the guard cannot parse or find must not be reasoned around ---
echo ghost > "$SES/$REL/ghost.md"
guard note-file "$SES/$REL/ghost.md" --agent fixture --slug forget >/dev/null 2>&1
rm "$SES/$REL/ghost.md"
cp "$SEM" "$TEST_ROOT/sem.backup"
printf '\ncommit: MC-sessions notasha\n' >> "$SEM"
guard note-file --forget "$REL/ghost.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "malformed commit claim: refused" "1" "$RC"
check "malformed commit claim: file claim kept" "1" "$(claims "$REL/ghost.md")"
cp "$TEST_ROOT/sem.backup" "$SEM"
printf '\ncommit: MC-sessions %s\n' "0123456789abcdef0123456789abcdef01234567" >> "$SEM"
guard note-file --forget "$REL/ghost.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "commit claim found in no checkout: refused" "1" "$RC"
check "commit claim found in no checkout: file claim kept" "1" "$(claims "$REL/ghost.md")"
cp "$TEST_ROOT/sem.backup" "$SEM"
guard note-file --forget "$REL/ghost.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "same claim without the bad commit line: forgotten" "0" "$RC"

# --- path spelling and scope: only a lexical repo-relative claim is accepted ---
echo trav > "$SES/$REL/trav.md"
guard note-file "$SES/$REL/trav.md" --agent fixture --slug forget >/dev/null 2>&1
rm "$SES/$REL/trav.md"
guard note-file --forget "$REL/../$REL/trav.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "dot-dot spelling: refused" "1" "$RC"
guard note-file --forget "$TEST_ROOT/elsewhere/$REL/trav.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "absolute path outside both checkouts: refused" "1" "$RC"
check "the claim survives both attempts" "1" "$(claims "$REL/trav.md")"
cp "$SEM" "$TEST_ROOT/sem.backup"
printf '\nfile: ../escape.md\n' >> "$SEM"
guard note-file --forget "../escape.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "recorded dot-dot claim is not something --forget reasons about: refused" "1" "$RC"
cp "$TEST_ROOT/sem.backup" "$SEM"
guard note-file --forget "$REL/trav.md" --agent fixture --slug forget >/dev/null 2>&1

# --- the path now lives in a third repository of the workspace ---------------
mkdir -p "$TEST_ROOT/DS-other/$REL"
echo third > "$SES/$REL/third.md"
guard note-file "$SES/$REL/third.md" --agent fixture --slug forget >/dev/null 2>&1
mv "$SES/$REL/third.md" "$TEST_ROOT/DS-other/$REL/third.md"
guard note-file --forget "$REL/third.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "path exists in another workspace repo: refused" "1" "$RC"
check "path exists in another workspace repo: claim kept" "1" "$(claims "$REL/third.md")"

# --- committed once, then reset away without note-commit: the only copy is in the reflog ---
echo lost > "$SES/$REL/lost.md"
guard note-file "$SES/$REL/lost.md" --agent fixture --slug forget >/dev/null 2>&1
git -C "$SES" add "$REL/lost.md"
git -C "$SES" commit -q -m "committed, never declared" -- "$REL/lost.md"
git -C "$SES" reset -q --hard HEAD~1
guard note-file --forget "$REL/lost.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "committed then reset away (reflog only): refused" "1" "$RC"
check "committed then reset away: claim kept" "1" "$(claims "$REL/lost.md")"

# --- no time window: a back-dated commit (GIT_COMMITTER_DATE / clock skew) still counts ---
echo old > "$SES/$REL/old.md"
git -C "$SES" add "$REL/old.md"
GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" \
  git -C "$SES" commit -q -m "back-dated" -- "$REL/old.md"
git -C "$SES" reset -q --hard HEAD~1
guard note-file "$SES/$REL/old.md" --agent fixture --slug forget >/dev/null 2>&1   # future path: recorded verbatim
guard note-file --forget "$REL/old.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "back-dated commit in the reflog: refused (no committer-date window)" "1" "$RC"
check "back-dated commit in the reflog: claim kept" "1" "$(claims "$REL/old.md")"

# --- a third repository of the workspace still tracks the path in HEAD ---------
git -C "$TEST_ROOT/DS-other" init -q
git -C "$TEST_ROOT/DS-other" config user.email test@test.local
git -C "$TEST_ROOT/DS-other" config user.name test
echo tracked > "$TEST_ROOT/DS-other/$REL/third2.md"
git -C "$TEST_ROOT/DS-other" add "$REL/third2.md"
git -C "$TEST_ROOT/DS-other" commit -q -m third -- "$REL/third2.md"
echo t > "$SES/$REL/third2.md"
guard note-file "$SES/$REL/third2.md" --agent fixture --slug forget >/dev/null 2>&1
rm "$SES/$REL/third2.md" "$TEST_ROOT/DS-other/$REL/third2.md"   # gone from disk, still in HEAD of DS-other
git -C "$TEST_ROOT/DS-other" rm -q --cached "$REL/third2.md"      # ...and out of its index: only HEAD holds it
guard note-file --forget "$REL/third2.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "path tracked in HEAD of another workspace repo: refused" "1" "$RC"
check "path tracked in HEAD of another workspace repo: claim kept" "1" "$(claims "$REL/third2.md")"

# --- a part of a glued claim: the refusal names the exact line to pass ----------
printf 'file: %s/zz1.md %s/zz2.md\n' "$REL" "$REL" >> "$SEM"
OUT=$(guard note-file --forget "$REL/zz1.md" --agent fixture --slug forget 2>&1); RC=$?
check "a part of a glued claim: refused" "1" "$RC"
check "a part of a glued claim: the refusal shows the whole line" "1" "$(printf '%s' "$OUT" | grep -c "целиком: '$REL/zz1.md $REL/zz2.md'")"
guard note-file --forget "$REL/zz1.md $REL/zz2.md" --agent fixture --slug forget >/dev/null 2>&1; RC=$?
check "the whole glued line: forgotten" "0" "$RC"

# --- a claim that is really several paths glued together by an unsplit variable ---
# It never claimed the parts; the parts exist and stay claimed by their own lines.
echo a > "$SES/$REL/pa.md"; echo b > "$SES/$REL/pb.md"
guard note-file "$SES/$REL/pa.md" --agent fixture --slug forget >/dev/null 2>&1
guard note-file "$SES/$REL/pb.md" --agent fixture --slug forget >/dev/null 2>&1
printf 'file: %s/pa.md %s/pb.md\n' "$REL" "$REL" >> "$SEM"
OUT=$(guard note-file --forget "$REL/pa.md $REL/pb.md" --agent fixture --slug forget 2>&1); RC=$?
check "glued multi-path claim: withdrawn as one literal path" "0" "$RC"
check "glued multi-path claim: the command says so" "1" "$(printf '%s' "$OUT" | grep -c 'как ОДИН путь')"
check "glued multi-path claim: the parts keep their own claims (pa)" "1" "$(claims "$REL/pa.md")"
check "glued multi-path claim: the parts keep their own claims (pb)" "1" "$(claims "$REL/pb.md")"

# --- parallel withdrawals never lose each other (check-and-replace under the transition lock) ---
for n in 1 2 3 4 5 6; do
  echo "x$n" > "$SES/$REL/par$n.md"
  guard note-file "$SES/$REL/par$n.md" --agent fixture --slug forget >/dev/null 2>&1
  rm "$SES/$REL/par$n.md"
done
CLAIMS_BEFORE=$(grep -c '^file: ' "$SEM")
for n in 1 2 3 4 5 6; do
  guard note-file --forget "$REL/par$n.md" --agent fixture --slug forget >/dev/null 2>&1 &
done
wait
LEFT=0; for n in 1 2 3 4 5 6; do LEFT=$((LEFT + $(claims "$REL/par$n.md"))); done
check "parallel forgets: every claim withdrawn (no lost update, no stuck lock)" "0" "$LEFT"
check "parallel forgets: nothing else touched" "$((CLAIMS_BEFORE - 6))" "$(grep -c '^file: ' "$SEM")"
check "parallel forgets: no temp file left" "0" "$(find "$(dirname "$SEM")" -name '.forget-*' | wc -l | tr -d ' ')"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: note-file --forget withdraws only claims with nothing left to deliver"
  exit 0
fi
echo "FAIL: $FAILURES check(s) failed"
exit 1
