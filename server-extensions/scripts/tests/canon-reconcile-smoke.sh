#!/usr/bin/env bash
# canon-reconcile.sh's job is narrower than canon-refresh.sh's: it also
# handles a purely-behind checkout whose tracked files are dirty, but only
# ever discards the dirty content when it's provably superseded (byte-
# identical to what origin already has once fast-forwarded). Real,
# never-published content must survive in the stash untouched. These
# scenarios exercise exactly that boundary — the guard logic (mid-rebase,
# detached HEAD, branch mismatch) is copied from canon-refresh.sh and
# already covered by canon-refresh-fast-forward-smoke.sh, not re-tested here.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/scripts/canon-reconcile.sh"
REAL_GIT=$(command -v git)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/canon-reconcile-smoke.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] || fail "$label — expected '$expected', got '$actual'"
}

assert_contains() {
  local label="$1" text="$2" needle="$3"
  case "$text" in
    *"$needle"*) ;;
    *) fail "$label — missing '$needle' in: $text" ;;
  esac
}

new_origin_and_clone() {
  local name="$1" origin seed clone
  origin="$TEST_ROOT/$name-origin.git"
  seed="$TEST_ROOT/$name-seed"
  clone="$TEST_ROOT/$name-clone"
  "$REAL_GIT" init --bare -q "$origin"
  "$REAL_GIT" init -q "$seed"
  "$REAL_GIT" -C "$seed" config user.name fixture
  "$REAL_GIT" -C "$seed" config user.email fixture@example.invalid
  printf 'initial\n' > "$seed/file.md"
  "$REAL_GIT" -C "$seed" add file.md
  "$REAL_GIT" -C "$seed" commit -qm initial
  "$REAL_GIT" -C "$seed" branch -M main
  "$REAL_GIT" -C "$seed" remote add origin "$origin"
  "$REAL_GIT" -C "$seed" push -q -u origin main
  "$REAL_GIT" -C "$origin" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" clone -q "$origin" "$clone"
  "$REAL_GIT" -C "$clone" config user.name fixture
  "$REAL_GIT" -C "$clone" config user.email fixture@example.invalid
}

advance_seed() {
  local seed="$1" content="$2" msg="$3"
  printf '%s\n' "$content" > "$seed/file.md"
  "$REAL_GIT" -C "$seed" add file.md
  "$REAL_GIT" -C "$seed" commit -qm "$msg"
  "$REAL_GIT" -C "$seed" push -q
}

# --- Scenario 1: clean and purely behind -> fast-forwards -----------------
new_origin_and_clone case1
CLONE1="$TEST_ROOT/case1-clone"
SEED1="$TEST_ROOT/case1-seed"
advance_seed "$SEED1" "second" "second commit"
REMOTE_HEAD1=$("$REAL_GIT" -C "$SEED1" rev-parse HEAD)
out1=$(bash "$SCRIPT" "$CLONE1" main 2>&1)
rc1=$?
assert_eq "case1 exit code" "0" "$rc1"
assert_contains "case1 diagnostic" "$out1" "fast-forwarded"
assert_eq "case1 HEAD advanced" "$REMOTE_HEAD1" "$("$REAL_GIT" -C "$CLONE1" rev-parse HEAD)"

# --- Scenario 2: already at origin -> no-op --------------------------------
out2=$(bash "$SCRIPT" "$CLONE1" main 2>&1)
rc2=$?
assert_eq "case2 exit code" "0" "$rc2"
assert_contains "case2 diagnostic" "$out2" "already at origin"

# --- Scenario 3: dirty tracked file, but content is provably superseded ---
# (equals what origin's next commit turns out to contain) -> auto-resolved,
# stash dropped, no trace left.
new_origin_and_clone case3
CLONE3="$TEST_ROOT/case3-clone"
SEED3="$TEST_ROOT/case3-seed"
printf 'draft never committed here\n' > "$CLONE3/file.md"
advance_seed "$SEED3" "draft never committed here" "someone else published the same draft"
out3=$(bash "$SCRIPT" "$CLONE3" main 2>&1)
rc3=$?
assert_eq "case3 exit code" "0" "$rc3"
assert_contains "case3 diagnostic" "$out3" "already superseded"
assert_eq "case3 disk matches new origin" "draft never committed here" "$(cat "$CLONE3/file.md")"
assert_eq "case3 tree clean" "" "$("$REAL_GIT" -C "$CLONE3" status --porcelain)"
assert_eq "case3 no stash left behind" "" "$("$REAL_GIT" -C "$CLONE3" stash list)"

# --- Scenario 4: dirty tracked file with REAL never-published content ------
# origin moves on to something else entirely -> fast-forwards the tree, but
# the real edit must survive in the stash, not be discarded.
new_origin_and_clone case4
CLONE4="$TEST_ROOT/case4-clone"
SEED4="$TEST_ROOT/case4-seed"
printf 'a real unpublished edit\n' > "$CLONE4/file.md"
advance_seed "$SEED4" "something unrelated entirely" "origin moves on unrelated"
set +e
out4=$(bash "$SCRIPT" "$CLONE4" main 2>&1)
rc4=$?
set -e
assert_eq "case4 exit code" "1" "$rc4"
assert_contains "case4 diagnostic" "$out4" "left in stash for manual review"
assert_eq "case4 disk shows new origin content" "something unrelated entirely" "$(cat "$CLONE4/file.md")"
assert_eq "case4 real edit preserved in stash" "a real unpublished edit" "$("$REAL_GIT" -C "$CLONE4" show stash@{0}:file.md)"
assert_contains "case4 stash present" "$("$REAL_GIT" -C "$CLONE4" stash list)" "canon-reconcile"

# --- Scenario 5: diverged history (local has an unpushed commit) -> refuses,
# nothing touched, no stash created.
new_origin_and_clone case5
CLONE5="$TEST_ROOT/case5-clone"
SEED5="$TEST_ROOT/case5-seed"
printf 'local only\n' > "$CLONE5/local.txt"
"$REAL_GIT" -C "$CLONE5" add local.txt
"$REAL_GIT" -C "$CLONE5" commit -qm "local-only commit"
LOCAL_HEAD5=$("$REAL_GIT" -C "$CLONE5" rev-parse HEAD)
advance_seed "$SEED5" "remote advanced too" "remote advances independently"
set +e
out5=$(bash "$SCRIPT" "$CLONE5" main 2>&1)
rc5=$?
set -e
assert_eq "case5 exit code" "1" "$rc5"
assert_contains "case5 diagnostic" "$out5" "history diverged"
assert_eq "case5 HEAD unchanged" "$LOCAL_HEAD5" "$("$REAL_GIT" -C "$CLONE5" rev-parse HEAD)"
assert_eq "case5 no stash created" "" "$("$REAL_GIT" -C "$CLONE5" stash list)"

# --- Scenario 6: two dirty files blocking the same fast-forward, one
# superseded and one real -> the real one keeps the whole stash alive (git
# stash is all-or-nothing per entry), and the script must report it rather
# than claim a clean resolution. Both paths must actually appear in git's own
# "would be overwritten" list, so origin has to move BOTH of them (a path
# origin leaves untouched never blocks a fast-forward at all, regardless of
# local dirt on it — that's a different, unrelated case, not this one).
new_origin_and_clone case6
CLONE6="$TEST_ROOT/case6-clone"
SEED6="$TEST_ROOT/case6-seed"
mkdir -p "$SEED6/second"
printf 'second file initial\n' > "$SEED6/second/other.md"
"$REAL_GIT" -C "$SEED6" add second/other.md
"$REAL_GIT" -C "$SEED6" commit -qm "add second file"
"$REAL_GIT" -C "$SEED6" push -q
"$REAL_GIT" -C "$CLONE6" pull -q
mkdir -p "$CLONE6/second"
printf 'superseded draft\n' > "$CLONE6/file.md"
printf 'a real edit nobody published\n' > "$CLONE6/second/other.md"
printf 'superseded draft\n' > "$SEED6/file.md"
printf 'second file, published differently\n' > "$SEED6/second/other.md"
"$REAL_GIT" -C "$SEED6" add file.md second/other.md
"$REAL_GIT" -C "$SEED6" commit -qm "publish the draft and advance second file too"
"$REAL_GIT" -C "$SEED6" push -q
set +e
out6=$(bash "$SCRIPT" "$CLONE6" main 2>&1)
rc6=$?
set -e

assert_eq "case6 exit code" "1" "$rc6"
assert_contains "case6 diagnostic" "$out6" "second/other.md"
assert_eq "case6 real edit preserved on disk-equivalent path" \
  "a real edit nobody published" "$("$REAL_GIT" -C "$CLONE6" show stash@{0}:second/other.md)"

# --- Scenario 7: a live lock (own pid, alive) is respected, nothing touched.
# Wired into ds-publish.sh's post-publish step now (WP-530 Ф33) means this
# can run concurrently with canon-refresh.sh/git-dirty-guard.sh on the same
# repo — they share one lock directory precisely so only one of them mutates
# the tree at a time.
new_origin_and_clone case7
CLONE7="$TEST_ROOT/case7-clone"
SEED7="$TEST_ROOT/case7-seed"
advance_seed "$SEED7" "second" "second commit"
LIVE_LOCK_HEAD=$("$REAL_GIT" -C "$CLONE7" rev-parse HEAD)
CLONE7_GIT_DIR=$("$REAL_GIT" -C "$CLONE7" rev-parse --absolute-git-dir)
mkdir -p "$CLONE7_GIT_DIR/dirty-guard.lock"
printf 'node=%s\npid=%s\n' "${HOSTNAME:-$(hostname)}" "$$" > "$CLONE7_GIT_DIR/dirty-guard.lock/owner"
out7=$(bash "$SCRIPT" "$CLONE7" main 2>&1)
rc7=$?
assert_eq "case7 exit code" "0" "$rc7"
assert_contains "case7 diagnostic" "$out7" "lock busy"
assert_eq "case7 HEAD untouched under live lock" "$LIVE_LOCK_HEAD" "$("$REAL_GIT" -C "$CLONE7" rev-parse HEAD)"
[ -d "$CLONE7_GIT_DIR/dirty-guard.lock" ] || fail "case7 live lock directory must survive a losing contender"
rm -rf "$CLONE7_GIT_DIR/dirty-guard.lock"

# --- Scenario 8: a stale lock (dead pid) is reclaimed and reconciliation proceeds
new_origin_and_clone case8
CLONE8="$TEST_ROOT/case8-clone"
SEED8="$TEST_ROOT/case8-seed"
advance_seed "$SEED8" "second" "second commit"
REMOTE_HEAD8=$("$REAL_GIT" -C "$SEED8" rev-parse HEAD)
CLONE8_GIT_DIR=$("$REAL_GIT" -C "$CLONE8" rev-parse --absolute-git-dir)
mkdir -p "$CLONE8_GIT_DIR/dirty-guard.lock"
DEAD_PID8=$(( $(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 999998) + 1 ))   # a pid that cannot exist: above pid_max (4194304 on Tsekh) and above every pid of macOS
printf 'node=%s\npid=%s\n' "${HOSTNAME:-$(hostname)}" "$DEAD_PID8" > "$CLONE8_GIT_DIR/dirty-guard.lock/owner"
out8=$(bash "$SCRIPT" "$CLONE8" main 2>&1)
rc8=$?
assert_eq "case8 exit code" "0" "$rc8"
assert_contains "case8 diagnostic" "$out8" "reclaiming the lock: owner pid $DEAD_PID8 is gone"
assert_eq "case8 fast-forwarded after reclaim" "$REMOTE_HEAD8" "$("$REAL_GIT" -C "$CLONE8" rev-parse HEAD)"
[ ! -d "$CLONE8_GIT_DIR/dirty-guard.lock" ] || fail "case8 lock directory left behind after success"

# --- Scenario 9: an UNTRACKED file blocks the fast-forward (the 02.10.2026
# ledger incident). Origin's next commit adds the same path the clone holds as
# an untracked file with real content. The tool must refuse, leave the file
# byte-for-byte, create NO stash (stash -u would hide it in stash^3, invisible
# to the superseded check), and not move HEAD.
new_origin_and_clone case9
CLONE9="$TEST_ROOT/case9-clone"
SEED9="$TEST_ROOT/case9-seed"
printf 'unpublished ledger events\n' > "$CLONE9/ledger.yaml"
printf 'origin version of the ledger\n' > "$SEED9/ledger.yaml"
"$REAL_GIT" -C "$SEED9" add ledger.yaml
"$REAL_GIT" -C "$SEED9" commit -qm "origin adds the file the clone holds untracked"
"$REAL_GIT" -C "$SEED9" push -q
LOCAL_HEAD9=$("$REAL_GIT" -C "$CLONE9" rev-parse HEAD)
set +e
out9=$(bash "$SCRIPT" "$CLONE9" main 2>&1)
rc9=$?
set -e
assert_eq "case9 exit code" "1" "$rc9"
assert_contains "case9 diagnostic" "$out9" "untracked file(s) would be overwritten"
assert_contains "case9 names the path" "$out9" "ledger.yaml"
assert_eq "case9 untracked file untouched" "unpublished ledger events" "$(cat "$CLONE9/ledger.yaml")"
assert_eq "case9 HEAD unchanged" "$LOCAL_HEAD9" "$("$REAL_GIT" -C "$CLONE9" rev-parse HEAD)"
assert_eq "case9 no stash created" "" "$("$REAL_GIT" -C "$CLONE9" stash list)"

# --- Scenario 10: a tracked dirty file AND an untracked blocker together.
# Refuse as a whole: the tracked edit must not be stashed alone while the
# untracked file blocks, and nothing may move.
new_origin_and_clone case10
CLONE10="$TEST_ROOT/case10-clone"
SEED10="$TEST_ROOT/case10-seed"
printf 'dirty tracked edit\n' > "$CLONE10/file.md"
printf 'untracked real content\n' > "$CLONE10/extra.yaml"
printf 'changed on origin\n' > "$SEED10/file.md"
printf 'origin extra\n' > "$SEED10/extra.yaml"
"$REAL_GIT" -C "$SEED10" add file.md extra.yaml
"$REAL_GIT" -C "$SEED10" commit -qm "origin touches both"
"$REAL_GIT" -C "$SEED10" push -q
LOCAL_HEAD10=$("$REAL_GIT" -C "$CLONE10" rev-parse HEAD)
set +e
out10=$(bash "$SCRIPT" "$CLONE10" main 2>&1)
rc10=$?
set -e
assert_eq "case10 exit code" "1" "$rc10"
assert_eq "case10 tracked edit untouched" "dirty tracked edit" "$(cat "$CLONE10/file.md")"
assert_eq "case10 untracked file untouched" "untracked real content" "$(cat "$CLONE10/extra.yaml")"
assert_eq "case10 HEAD unchanged" "$LOCAL_HEAD10" "$("$REAL_GIT" -C "$CLONE10" rev-parse HEAD)"
assert_eq "case10 no stash created" "" "$("$REAL_GIT" -C "$CLONE10" stash list)"

# --- Scenarios 11-14: the event ledger (WP-484 Ф255). A dirty ledger tail is
# written-but-unpublished events, not a stray edit: the stash route lost 152 of
# them on 26.10.2026. The ledger merge tool lives in DS-my-strategy, so the
# scenarios borrow a copy of it; without one they are skipped loudly.
LEDGER_REL="machine/ledger/day/2026/10/day-2026-10-26.yaml"
LEDGER_TOOL_SRC=""
for candidate in "$ROOT_DIR/DS-my-strategy/scripts/lib/ledger-event-diff.py" \
                 "$HOME/IWE/DS-my-strategy/scripts/lib/ledger-event-diff.py"; do
  if [ -r "$candidate" ]; then LEDGER_TOOL_SRC="$candidate"; break; fi
done

ledger_doc() {
  # ledger_doc <ts>... -> a ledger/v1 day document with one session_closed event per ts
  printf 'schema: ledger/v1\nscale: day\nperiod: '"'"'2026-10-26'"'"'\nevents:\n'
  local ts
  for ts in "$@"; do
    printf -- "- ts: '%s'\n  source: fixture\n  kind: session_closed\n  data:\n    wp: WP-1\n" "$ts"
  done
}

new_ledger_case() {
  # new_ledger_case <name>: seed and clone both hold the ledger with event e1;
  # origin then gains e2 (published by someone else), the clone gains an
  # unpublished local event e-local on disk.
  local name="$1" seed
  new_origin_and_clone "$name"
  seed="$TEST_ROOT/$name-seed"
  mkdir -p "$seed/$(dirname "$LEDGER_REL")" "$TEST_ROOT/$name-clone/$(dirname "$LEDGER_REL")"
  ledger_doc 2026-10-26T01:00:00Z > "$seed/$LEDGER_REL"
  "$REAL_GIT" -C "$seed" add "$LEDGER_REL"
  "$REAL_GIT" -C "$seed" commit -qm "ledger with e1"
  "$REAL_GIT" -C "$seed" push -q
  "$REAL_GIT" -C "$TEST_ROOT/$name-clone" pull -q
  ledger_doc 2026-10-26T01:00:00Z 2026-10-26T05:00:00Z > "$TEST_ROOT/$name-clone/$LEDGER_REL"
  ledger_doc 2026-10-26T01:00:00Z 2026-10-26T03:00:00Z > "$seed/$LEDGER_REL"
  "$REAL_GIT" -C "$seed" add "$LEDGER_REL"
  "$REAL_GIT" -C "$seed" commit -qm "origin publishes e2"
  "$REAL_GIT" -C "$seed" push -q
}

if [ -z "$LEDGER_TOOL_SRC" ] || ! command -v flock >/dev/null 2>&1; then
  echo "SKIP: scenarios 11-19 (need ledger-event-diff.py next to this checkout or in ~/IWE/DS-my-strategy, and flock)"
  echo "PASS: canon-reconcile-smoke.sh (10 scenarios, 9 skipped)"
  exit 0
fi

# 11: unpublished local event survives the fast-forward as a union, no stash left.
new_ledger_case case11
CLONE11="$TEST_ROOT/case11-clone"
REMOTE_HEAD11=$("$REAL_GIT" -C "$TEST_ROOT/case11-seed" rev-parse HEAD)
set +e
out11=$(CANON_RECONCILE_LEDGER_TOOL="$LEDGER_TOOL_SRC" bash "$SCRIPT" "$CLONE11" main 2>&1)
rc11=$?
set -e
assert_eq "case11 exit code" "0" "$rc11"
assert_contains "case11 diagnostic" "$out11" "merged back"
assert_eq "case11 HEAD advanced" "$REMOTE_HEAD11" "$("$REAL_GIT" -C "$CLONE11" rev-parse HEAD)"
assert_eq "case11 no stash left behind" "" "$("$REAL_GIT" -C "$CLONE11" stash list)"
for ts in 2026-10-26T01:00:00Z 2026-10-26T03:00:00Z 2026-10-26T05:00:00Z; do
  assert_contains "case11 event $ts on disk" "$(cat "$CLONE11/$LEDGER_REL")" "ts: '$ts'"
done
assert_eq "case11 each event once" "3" "$(grep -c '^- ts:' "$CLONE11/$LEDGER_REL")"
assert_contains "case11 tail stays a pending diff" "$("$REAL_GIT" -C "$CLONE11" status --porcelain)" "$LEDGER_REL"
rm -f "$CLONE11/$LEDGER_REL.lock"

# 12: the merge tool is unavailable -> refused BEFORE anything moves (dry run), tree untouched.
new_ledger_case case12
CLONE12="$TEST_ROOT/case12-clone"
LOCAL_HEAD12=$("$REAL_GIT" -C "$CLONE12" rev-parse HEAD)
set +e
out12=$(CANON_RECONCILE_LEDGER_TOOL="$TEST_ROOT/no-such-tool.py" bash "$SCRIPT" "$CLONE12" main 2>&1)
rc12=$?
set -e
assert_eq "case12 exit code" "1" "$rc12"
assert_contains "case12 diagnostic" "$out12" "ledger tail NOT safe to reconcile"
assert_eq "case12 HEAD untouched" "$LOCAL_HEAD12" "$("$REAL_GIT" -C "$CLONE12" rev-parse HEAD)"
assert_eq "case12 no stash created" "" "$("$REAL_GIT" -C "$CLONE12" stash list)"
assert_contains "case12 local event still on disk" "$(cat "$CLONE12/$LEDGER_REL")" "ts: '2026-10-26T05:00:00Z'"

# 13: a ledger writer holds the lock -> skip the cycle, nothing touched.
new_ledger_case case13
CLONE13="$TEST_ROOT/case13-clone"
LOCAL_HEAD13=$("$REAL_GIT" -C "$CLONE13" rev-parse HEAD)
LOCAL_CONTENT13=$(cat "$CLONE13/$LEDGER_REL")
: > "$CLONE13/$LEDGER_REL.lock"
flock -x "$CLONE13/$LEDGER_REL.lock" sleep 20 &   # the same flock the script uses (skip guard above)
HOLDER13=$!
sleep 1
set +e
out13=$(CANON_RECONCILE_LEDGER_TOOL="$LEDGER_TOOL_SRC" CANON_RECONCILE_LEDGER_LOCK_WAIT=1 bash "$SCRIPT" "$CLONE13" main 2>&1)
rc13=$?
set -e
kill "$HOLDER13" 2>/dev/null || true
wait "$HOLDER13" 2>/dev/null || true
assert_eq "case13 exit code" "0" "$rc13"
assert_contains "case13 diagnostic" "$out13" "holds the lock"
assert_eq "case13 HEAD untouched" "$LOCAL_HEAD13" "$("$REAL_GIT" -C "$CLONE13" rev-parse HEAD)"
assert_eq "case13 ledger untouched" "$LOCAL_CONTENT13" "$(cat "$CLONE13/$LEDGER_REL")"
assert_eq "case13 no stash created" "" "$("$REAL_GIT" -C "$CLONE13" stash list)"

# 14: no flock on this machine -> a dirty ledger is not touched at all.
new_ledger_case case14
CLONE14="$TEST_ROOT/case14-clone"
LOCAL_HEAD14=$("$REAL_GIT" -C "$CLONE14" rev-parse HEAD)
set +e
out14=$(CANON_RECONCILE_FLOCK=no-such-flock-binary CANON_RECONCILE_LEDGER_TOOL="$LEDGER_TOOL_SRC" bash "$SCRIPT" "$CLONE14" main 2>&1)
rc14=$?
set -e
assert_eq "case14 exit code" "1" "$rc14"
assert_contains "case14 diagnostic" "$out14" "is not available"
assert_eq "case14 HEAD untouched" "$LOCAL_HEAD14" "$("$REAL_GIT" -C "$CLONE14" rev-parse HEAD)"
assert_contains "case14 local event still on disk" "$(cat "$CLONE14/$LEDGER_REL")" "ts: '2026-10-26T05:00:00Z'"
assert_eq "case14 no stash created" "" "$("$REAL_GIT" -C "$CLONE14" stash list)"

# 15: the dirty file does not match the ledger header (another period) -> the dry run
# refuses, tree untouched.
new_ledger_case case15
CLONE15="$TEST_ROOT/case15-clone"
LOCAL_HEAD15=$("$REAL_GIT" -C "$CLONE15" rev-parse HEAD)
sed -i.bak "s/^period: .*/period: '2027-01-01'/" "$CLONE15/$LEDGER_REL" && rm -f "$CLONE15/$LEDGER_REL.bak"
set +e
out15=$(CANON_RECONCILE_LEDGER_TOOL="$LEDGER_TOOL_SRC" bash "$SCRIPT" "$CLONE15" main 2>&1)
rc15=$?
set -e
assert_eq "case15 exit code" "1" "$rc15"
assert_contains "case15 diagnostic" "$out15" "ledger tail NOT safe to reconcile"
assert_eq "case15 HEAD untouched" "$LOCAL_HEAD15" "$("$REAL_GIT" -C "$CLONE15" rev-parse HEAD)"
assert_eq "case15 no stash created" "" "$("$REAL_GIT" -C "$CLONE15" stash list)"

# 16: a ledger path AND another real dirty path together. The ledger tail is merged on
# disk, the stash keeps everything, and the output lists only the other path as the one
# to review, saying the ledger is already merged back.
new_ledger_case case16
CLONE16="$TEST_ROOT/case16-clone"
printf 'a local draft nobody published\n' > "$CLONE16/file.md"
advance_seed "$TEST_ROOT/case16-seed" "origin changed file.md too" "origin changes the other file"
set +e
out16=$(CANON_RECONCILE_LEDGER_TOOL="$LEDGER_TOOL_SRC" bash "$SCRIPT" "$CLONE16" main 2>&1)
rc16=$?
set -e
assert_eq "case16 exit code" "1" "$rc16"
assert_contains "case16 names the other path" "$out16" "file.md"
assert_contains "case16 says the ledger is already merged" "$out16" "ALREADY merged back"
assert_eq "case16 ledger tail merged on disk" "3" "$(grep -c '^- ts:' "$CLONE16/$LEDGER_REL")"
assert_contains "case16 stash keeps the draft" "$("$REAL_GIT" -C "$CLONE16" show 'stash@{0}:file.md')" "a local draft nobody published"
assert_contains "case16 stash keeps the ledger tail" "$("$REAL_GIT" -C "$CLONE16" show "stash@{0}:$LEDGER_REL")" "ts: '2026-10-26T05:00:00Z'"

# 17: origin deliberately deleted an event the dirty copy still has -> not resurrected
# silently: the dry run cannot prove a lossless merge and refuses, tree untouched.
new_origin_and_clone case17
SEED17="$TEST_ROOT/case17-seed"; CLONE17="$TEST_ROOT/case17-clone"
mkdir -p "$SEED17/$(dirname "$LEDGER_REL")"
ledger_doc 2026-10-26T01:00:00Z 2026-10-26T02:00:00Z > "$SEED17/$LEDGER_REL"
"$REAL_GIT" -C "$SEED17" add "$LEDGER_REL"; "$REAL_GIT" -C "$SEED17" commit -qm "ledger e1 e2"; "$REAL_GIT" -C "$SEED17" push -q
"$REAL_GIT" -C "$CLONE17" pull -q
ledger_doc 2026-10-26T01:00:00Z 2026-10-26T02:00:00Z 2026-10-26T05:00:00Z > "$CLONE17/$LEDGER_REL"
ledger_doc 2026-10-26T02:00:00Z > "$SEED17/$LEDGER_REL"
"$REAL_GIT" -C "$SEED17" add "$LEDGER_REL"; "$REAL_GIT" -C "$SEED17" commit -qm "origin deletes e1"; "$REAL_GIT" -C "$SEED17" push -q
LOCAL_HEAD17=$("$REAL_GIT" -C "$CLONE17" rev-parse HEAD)
set +e
out17=$(CANON_RECONCILE_LEDGER_TOOL="$LEDGER_TOOL_SRC" bash "$SCRIPT" "$CLONE17" main 2>&1)
rc17=$?
set -e
assert_eq "case17 exit code" "1" "$rc17"
assert_contains "case17 diagnostic" "$out17" "ledger tail NOT safe to reconcile"
assert_eq "case17 HEAD untouched" "$LOCAL_HEAD17" "$("$REAL_GIT" -C "$CLONE17" rev-parse HEAD)"
assert_eq "case17 no stash created" "" "$("$REAL_GIT" -C "$CLONE17" stash list)"
assert_eq "case17 dirty copy untouched" "3" "$(grep -c '^- ts:' "$CLONE17/$LEDGER_REL")"

# 18: the writer's lock is really held while the work runs: a slow merge tool, and a
# non-blocking lock attempt from outside during it must be refused (exit 75).
new_ledger_case case18
CLONE18="$TEST_ROOT/case18-clone"
SLOW_TOOL="$TEST_ROOT/slow-tool.py"
printf 'import runpy, sys, time\ntime.sleep(2)\nsys.argv[0] = %s\nrunpy.run_path(%s, run_name="__main__")\n' "'$LEDGER_TOOL_SRC'" "'$LEDGER_TOOL_SRC'" > "$SLOW_TOOL"
CANON_RECONCILE_LEDGER_TOOL="$SLOW_TOOL" bash "$SCRIPT" "$CLONE18" main > "$TEST_ROOT/case18.out" 2>&1 &
RECONCILE18=$!
sleep 1
set +e
flock -n -E 75 "$CLONE18/$LEDGER_REL.lock" true
probe18=$?
wait "$RECONCILE18"
rc18=$?
set -e
assert_eq "case18 outside writer is kept out while the work runs" "75" "$probe18"
assert_eq "case18 reconcile itself succeeded" "0" "$rc18"
flock -n -E 75 "$CLONE18/$LEDGER_REL.lock" true || fail "case18 lock must be free after the run"
assert_eq "case18 each event once" "3" "$(grep -c '^- ts:' "$CLONE18/$LEDGER_REL")"

# 19: the merge works in the dry run but fails after the fast-forward (the tool dies on its
# 4th call) -> nothing may be dropped: HEAD moved, disk shows origin, the tail is in the stash.
new_ledger_case case19
CLONE19="$TEST_ROOT/case19-clone"
FLAKY_TOOL="$TEST_ROOT/flaky-tool.py"
COUNTER19="$TEST_ROOT/case19.calls"; : > "$COUNTER19"
printf 'import runpy, sys\nwith open(%s, "a") as f:\n    f.write("x")\nif len(open(%s).read()) > 3:\n    sys.exit(1)\nsys.argv[0] = %s\nrunpy.run_path(%s, run_name="__main__")\n' "'$COUNTER19'" "'$COUNTER19'" "'$LEDGER_TOOL_SRC'" "'$LEDGER_TOOL_SRC'" > "$FLAKY_TOOL"
REMOTE_HEAD19=$("$REAL_GIT" -C "$TEST_ROOT/case19-seed" rev-parse HEAD)
set +e
out19=$(CANON_RECONCILE_LEDGER_TOOL="$FLAKY_TOOL" bash "$SCRIPT" "$CLONE19" main 2>&1)
rc19=$?
set -e
assert_eq "case19 exit code" "1" "$rc19"
assert_contains "case19 diagnostic" "$out19" "left in stash for manual review"
assert_eq "case19 HEAD advanced" "$REMOTE_HEAD19" "$("$REAL_GIT" -C "$CLONE19" rev-parse HEAD)"
assert_eq "case19 disk shows origin's version" "2" "$(grep -c '^- ts:' "$CLONE19/$LEDGER_REL")"
assert_contains "case19 tail preserved in the stash" "$("$REAL_GIT" -C "$CLONE19" show "stash@{0}:$LEDGER_REL")" "ts: '2026-10-26T05:00:00Z'"

echo "PASS: canon-reconcile-smoke.sh (19 scenarios)"
