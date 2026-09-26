#!/usr/bin/env bash
# session-guard-supersession-large-blob-smoke.sh -- WP-561 (26.09).
#
# _commit_claim_supersession_has_publish_proof() refused every real governance
# file of DS-my-strategy: its conflict-blob reader RAISED on anything over
# 256 KiB (aborting the whole candidate loop, not just that candidate), and
# anchored_insertions() capped blobs at 256 KiB / 4096 lines while
# current/hypotheses-log.md alone is 707 KB / 4431 lines. Live case: session
# 2026-09-25-07-wp588-wp511-strategic-bets, `close` stopped at "conflict blob
# exceeds proof budget" before ever evaluating the rebased successor claim.
#
# Extracts the real function from session-guard.sh (not a copy) and drives it
# against a hand-built repository:
#   T1  a claimed insertion into a >300 KB / >4096-line file, rebased over a
#       concurrent upstream insertion at the same spot and published, is proven;
#       an earlier-sorting claim whose conflict blob exceeds the budget is only
#       skipped, not fatal.
#   T2  a published successor that drops part of the claimed insertion is
#       refused (proof semantics unchanged).
#   T3  every Python heredoc that diffs blobs uses one identical budget, and no
#       stale literal cap is left behind.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="$ROOT_DIR/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-supersession-large-blob.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail_test() { echo "FAIL: $1" >&2; exit 1; }

# Same extraction state machine as session-guard-abandon-prepared-smoke.sh:
# bare `}` lines inside the <<'PY' heredoc are not the function's end.
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
FIXTURE="$TEST_ROOT/fixture.sh"
extract_fn _commit_claim_supersession_has_publish_proof > "$FIXTURE"
grep -q '^_commit_claim_supersession_has_publish_proof() {' "$FIXTURE" \
  || fail_test "fixture setup -- extraction anchor no longer matches session-guard.sh"
# shellcheck source=/dev/null
source "$FIXTURE"

REPO="$TEST_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" config commit.gpgsign false

commit_big() {  # <message> -- commits $REPO/big.md, prints the new HEAD
  git -C "$REPO" add big.md
  git -C "$REPO" commit -qm "$1"
  git -C "$REPO" rev-parse HEAD
}

# 5000 unique ~72-byte rows: ~360 KB and 5000 lines, above both old caps.
python3 - "$REPO/big.md" <<'PY'
import sys
with open(sys.argv[1], "w") as out:
    for i in range(5000):
        out.write("| %05d | governance row %05d | status | padding padding padding padding |\n" % (i, i))
PY
[ "$(wc -c < "$REPO/big.md")" -gt 300000 ] || fail_test "fixture setup -- big.md is not >300 KB"
[ "$(wc -l < "$REPO/big.md")" -gt 4096 ] || fail_test "fixture setup -- big.md is not >4096 lines"
BASE=$(commit_big base)
MAIN_BRANCH=$(git -C "$REPO" symbolic-ref --short HEAD)

insert_after() {  # <line number> <block file> -- inserts block into big.md
  python3 - "$REPO/big.md" "$1" "$2" <<'PY'
import sys
path, after, block = sys.argv[1], int(sys.argv[2]), open(sys.argv[3]).read()
lines = open(path).read().splitlines(keepends=True)
open(path, "w").write("".join(lines[:after]) + block + "".join(lines[after:]))
PY
}
printf '### claimed session block\n- claimed line one\n- claimed line two\n' > "$TEST_ROOT/own.txt"
printf '### upstream block\n- upstream line\n' > "$TEST_ROOT/upstream.txt"
printf '### claimed session block\n- claimed line one\n' > "$TEST_ROOT/own-truncated.txt"

# Session claim S: inserts its block after row 2500 (the claim frozen before rebase).
git -C "$REPO" checkout -q -b session "$BASE"
insert_after 2500 "$TEST_ROOT/own.txt"
SOURCE=$(commit_big "session claim")

# Upstream U: a concurrent session inserts at the SAME spot, so the rebase conflicts.
git -C "$REPO" checkout -q "$MAIN_BRANCH"
insert_after 2500 "$TEST_ROOT/upstream.txt"
UPSTREAM=$(commit_big "concurrent upstream edit")

# Commit the staged tree on <parent> with a varying message until the new OID's
# first hex digit is in <digits>: each try succeeds with p=1/2, so 256 tries
# make the fixture deterministic without re-hashing multi-MB blobs.
commit_sorted() {  # <parent> <digits glob> <message> -> OID
  local tree oid attempt
  git -C "$REPO" add big.md
  tree=$(git -C "$REPO" write-tree)
  for attempt in $(seq 1 256); do
    oid=$(git -C "$REPO" commit-tree "$tree" -p "$1" -m "$3 $attempt")
    # shellcheck disable=SC2254  # $2 is intentionally a glob
    case "${oid:0:1}" in $2) printf '%s\n' "$oid"; return 0 ;; esac
  done
  return 1
}

# Rebased successor C: conflict resolved keeping both blocks, published on main.
# Its OID sorts in the upper half, the oversized claim below in the lower half.
insert_after 2502 "$TEST_ROOT/own.txt"
GOOD=$(commit_sorted "$UPSTREAM" '[89a-f]' "rebased successor") \
  || fail_test "fixture setup -- no upper-half OID for the good successor"

# An oversized published claim (>4 MiB big.md) whose OID sorts BEFORE the good
# successor: pre-fix, its conflict blob raised and aborted the whole loop.
python3 - "$REPO/big.md" <<'PY'
import sys
with open(sys.argv[1], "a") as out:
    out.write("oversized tail %s\n" % ("x" * 120) * 36000)
PY
OVERSIZED=$(commit_sorted "$GOOD" '[0-7]' "oversized claim") \
  || fail_test "fixture setup -- no lower-half OID for the oversized claim"
[[ "$OVERSIZED" < "$GOOD" ]] || fail_test "fixture setup -- oversized claim does not sort first"
[ "$(git -C "$REPO" cat-file -s "$OVERSIZED:big.md")" -gt $((4 * 1024 * 1024)) ] \
  || fail_test "fixture setup -- oversized claim is not above the 4 MiB budget"

write_semaphore() {  # <path> <claimed OIDs...>
  local path="$1" oid; shift
  printf 'agent: claude-code\nwp: WP-561\nslug: supersession-large-blob-smoke\n---\n' > "$path"
  for oid in "$@"; do printf 'commit: repo %s\n' "$oid" >> "$path"; done
}

# --- T1: rebased successor of a large-file claim is proven.
SEM1="$TEST_ROOT/t1.open"
write_semaphore "$SEM1" "$SOURCE" "$OVERSIZED" "$GOOD"
set +e
out=$(_commit_claim_supersession_has_publish_proof "$REPO" "$SOURCE" "$OVERSIZED" "$SEM1" repo 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail_test "T1: large-file rebased successor refused (rc=$rc): $out"
grep -qF "claimed changes preserved in OID-published claim: repo $SOURCE -> $GOOD" <<< "$out" \
  || fail_test "T1: expected preservation message for $GOOD, got: $out"
echo "PASS T1: $out"

# --- T2: successor that drops part of the claimed insertion stays refused.
git -C "$REPO" checkout -q -f "$UPSTREAM"
insert_after 2502 "$TEST_ROOT/own-truncated.txt"
BAD=$(commit_big "lossy successor")
# Within budget, so a refusal can only come from the lost claimed line.
[ "$(git -C "$REPO" cat-file -s "$BAD:big.md")" -lt 1000000 ] \
  || fail_test "fixture setup -- lossy successor unexpectedly carries the oversized tail"
SEM2="$TEST_ROOT/t2.open"
write_semaphore "$SEM2" "$SOURCE" "$BAD"
set +e
out=$(_commit_claim_supersession_has_publish_proof "$REPO" "$SOURCE" "$BAD" "$SEM2" repo 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail_test "T2: lossy successor was not refused (rc=$rc): $out"
grep -qF "supersession proof refused: no exact published successor preserves the claimed changes" <<< "$out" \
  || fail_test "T2: expected content refusal, got: $out"
echo "PASS T2: $out"

# --- T3: one budget everywhere, no stale literal caps.
defs=$(grep -E '^MAX_BLOB_(BYTES|LINES) = ' "$GUARD" | sort | uniq -c)
[ "$(grep -cE '^MAX_BLOB_BYTES = ' "$GUARD")" -eq "$(grep -c '^def anchored_insertions' "$GUARD")" ] \
  || fail_test "T3: a heredoc with anchored_insertions() lacks its MAX_BLOB_BYTES definition"
[ "$(printf '%s\n' "$defs" | wc -l)" -eq 2 ] \
  || fail_test "T3: MAX_BLOB_* budgets drifted between heredocs: $defs"
! grep -nE '> (262144|4096)\b' "$GUARD" \
  || fail_test "T3: a literal 262144/4096 proof cap is still present"
echo "PASS T3: budgets identical across $(grep -c '^def anchored_insertions' "$GUARD") heredocs"

echo "PASS: session-guard-supersession-large-blob-smoke"
