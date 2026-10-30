#!/usr/bin/env bash
# WP-539 F21 B5: note-publication --claim-source claims the caller-stated source commit and
# records its receipt in one transition-lock section. Checks on a real temporary repository:
#   1. claim + receipt succeed together (the claim line stays, a receipt line appears);
#   2. a failed receipt rolls the claim back (semaphore byte-identical to before);
#   3. a commit already claimed by another session is refused, nothing is written;
#   4. repeating the same claim is idempotent (one claim line);
#   5. without --claim-source an unclaimed commit is still refused (no guessing).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$ROOT/scripts/session-guard.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAIL=0
fail() { echo "FAIL: $1"; FAIL=1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
git init -q --bare "$T/origin.git"
git init -q -b main "$T/myrepo"
git -C "$T/myrepo" remote add origin "$T/origin.git"
echo one > "$T/myrepo/a.txt"
git -C "$T/myrepo" add a.txt
git -C "$T/myrepo" commit -q -m one
git -C "$T/myrepo" push -q origin main
PUBLISHED=$(git -C "$T/myrepo" rev-parse HEAD)
echo two > "$T/myrepo/b.txt"
git -C "$T/myrepo" add b.txt
git -C "$T/myrepo" commit -q -m two
UNPUBLISHED=$(git -C "$T/myrepo" rev-parse HEAD)

mkdir -p "$T/.iwe-runtime/sessions"
SEM="$T/.iwe-runtime/sessions/claude-code-aaaa1111.open"
OTHER="$T/.iwe-runtime/sessions/claude-code-bbbb2222.open"
mk() {  # <file> <guard id> <slug>
  printf -- '---\nagent: claude-code\nwp: WP-1\nslug: %s\nsession_id: %s\nguard_schema: 1\n---\n' "$3" "$2" > "$1"
}
mk "$SEM" aaaa1111 slug-one
mk "$OTHER" bbbb2222 slug-two

run() {  # <published sha> [extra args]; fills OUT and RC
  local sha="$1"; shift
  OUT=$(IWE_ROOT="$T" IWE_AGENT=claude-code bash "$GUARD" note-publication "$sha" \
    --repo myrepo --session-id aaaa1111 "$@" 2>&1)
  RC=$?
}
claims_of() { grep -c "^commit: myrepo $1\$" "$SEM"; }

# 5. no --claim-source: unclaimed commit is refused.
run "$PUBLISHED"
[ "$RC" -ne 0 ] || fail "unclaimed commit without --claim-source must be refused: $OUT"
[ "$(claims_of "$PUBLISHED")" = 0 ] || fail "refusal wrote a claim"

# 2. a failed receipt (source is not on origin/main) rolls the claim back.
cp "$SEM" "$T/before"
run "$UNPUBLISHED" --claim-source "$UNPUBLISHED"
[ "$RC" -ne 0 ] || fail "receipt for a commit not on origin must fail: $OUT"
cmp -s "$SEM" "$T/before" || fail "semaphore changed after a failed receipt: $(diff "$T/before" "$SEM")"
case "$OUT" in *claim_rolled_back*) ;; *) fail "rollback not reported: $OUT" ;; esac

# 3. a commit claimed by another session is refused, nothing written.
echo "commit: myrepo $PUBLISHED" >> "$OTHER"
cp "$SEM" "$T/before"
run "$PUBLISHED" --claim-source "$PUBLISHED"
[ "$RC" -ne 0 ] || fail "commit of another session must be refused: $OUT"
cmp -s "$SEM" "$T/before" || fail "semaphore changed after a foreign-claim refusal"
case "$OUT" in *"другой сессией"*) ;; *) fail "foreign-claim reason missing: $OUT" ;; esac
mk "$OTHER" bbbb2222 slug-two

# 1. claim + receipt together.
run "$PUBLISHED" --claim-source "$PUBLISHED"
[ "$RC" -eq 0 ] || fail "claim + receipt must succeed (rc=$RC): $OUT"
[ "$(claims_of "$PUBLISHED")" = 1 ] || fail "claim line missing after success"
grep -q 'receipt' "$SEM" || fail "no receipt line recorded: $(cat "$SEM")"

# 4. repeating is idempotent.
run "$PUBLISHED" --claim-source "$PUBLISHED"
[ "$(claims_of "$PUBLISHED")" = 1 ] || fail "repeat claim duplicated the line"

# A source that is no commit of the checkout is skipped with a warning, the receipt still lands.
cp "$SEM" "$T/before"
run "$PUBLISHED" --claim-source "$(printf 'c%.0s' $(seq 1 40))"
[ "$RC" -eq 0 ] || fail "unknown source must not block a recordable receipt (rc=$RC): $OUT"
case "$OUT" in *"заявка пропущена"*) ;; *) fail "skipped claim not reported: $OUT" ;; esac
[ "$(grep -c '^commit: myrepo c' "$SEM")" = 0 ] || fail "unknown source was claimed"

# Odd values never reach the claim.
run "$PUBLISHED" --claim-source 'not-a-sha'
[ "$RC" -ne 0 ] || fail "malformed --claim-source must be refused"

[ "$FAIL" = 0 ] && echo "PASS: note-publication-claim-source-smoke"
exit "$FAIL"
