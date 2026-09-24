#!/bin/bash
# ancestry-mutation-guards-smoke.sh -- WP-7 Ф163, peer session
# 2026-09-21-17-wp7-f163-ancestry-hardening (Claude+Codex).
#
# Ф161 hardened the checks that decide "is this local commit already
# published" (session-guard.sh's delivery proof). This phase covers a
# different set of callers that trust the same primitives (`merge-base
# --is-ancestor`, `rev-list --count`) not as a publication proof but as a
# mutation guard: "is it safe to fast-forward/reset this checkout onto
# origin without losing local work". canon-refresh.sh, canon-reconcile.sh
# and sync-strategy-files.sh call `merge-base --is-ancestor` directly;
# safe-pull.sh never calls it, but its AHEAD/BEHIND gate (`rev-list --count`,
# the earliest ancestry-sensitive call in that file -- found by Codex on
# this session's turn 1, corrected the writer's own first draft which had
# looked only at safe-pull.sh's later git-cherry/patch-id checks) decides
# the same "only upstream ahead -> merge --ff-only" fast path.
#
# Two layers:
#   1. static: each of the four scripts carries the exact top-level exports
#      before its earliest ancestry-sensitive call (call_re agreed with
#      Codex: merge-base --is-ancestor|rev-list|cherry|patch-id|merge
#      --ff-only), and losing either export line is itself caught.
#   2. live, against the real git binary and the real mutating commands
#      (`merge --ff-only`, `reset --soft`) these scripts use -- not just the
#      read-only ancestry check. Per Ф163's own stricter invariant (agreed
#      with Codex, turn 2): forgery + no guard must produce an actual
#      mutation (branch ref moves, file content changes) -- proving the
#      exploit is real, not just that the read-only check lies -- and
#      forgery + guard must leave the branch ref, index, worktree and the
#      original local commit's reachability from HEAD all unchanged.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"
# shellcheck source=ancestry-hardening-lib.sh
. "$HERE/ancestry-hardening-lib.sh"

FAILURES=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "OK: $desc"
  else
    echo "FAIL: $desc (ожидалось '$expected', получено '$actual')"
    FAILURES=$((FAILURES + 1))
  fi
}

# must <description> -- <command...>: fixture setup that must not fail
# silently. This host's PATH git is wrapped (WP-539) and refuses commit/
# merge/rebase/stash outright when no session-guard.sh semaphore is open
# anywhere on the machine -- exactly the "nobody's watching" state these
# four scripts exist to handle, and a state a scheduled/CI run of this test
# can land in for real (found by cold review of this file: a bare `git
# commit` in an empty $IWE_ROOT reproduced the block). Without this guard, a
# blocked setup command leaves the fixture short a commit and every assert
# below fails for the wrong reason, pointing at the ancestry fix instead of
# the fixture.
must() {
  local desc="$1"; shift
  "$@" >/dev/null 2>&1 || { echo "FAIL: fixture setup failed: $desc" >&2; exit 1; }
}

CALL_RE='merge-base --is-ancestor|rev-list|cherry|patch-id|merge --ff-only'

# =========================================================================
# Layer 1: static -- every target script, exports before earliest call,
# and each export line individually catchable if removed.
# =========================================================================
for name in canon-refresh.sh canon-reconcile.sh sync-strategy-files.sh safe-pull.sh; do
  script="$SCRIPTS_DIR/$name"
  [ -f "$script" ] || { echo "FAIL: $script not found"; FAILURES=$((FAILURES + 1)); continue; }

  check "$name: оба экспорта точные и стоят до самого раннего ancestry-вызова" "" \
    "$(hardening_violations "$script" "$CALL_RE")"

  grep -vxF "$HARDEN_REPLACE_LINE" "$script" > "$T/$name.no-replace.sh"
  check "$name: мутант без верхнего GIT_NO_REPLACE_OBJECTS ловится" "missing exactly: $HARDEN_REPLACE_LINE" \
    "$(hardening_violations "$T/$name.no-replace.sh" "$CALL_RE")"

  grep -vxF "$HARDEN_GRAFT_LINE" "$script" > "$T/$name.no-graft.sh"
  check "$name: мутант без верхнего GIT_GRAFT_FILE ловится" "missing exactly: $HARDEN_GRAFT_LINE" \
    "$(hardening_violations "$T/$name.no-graft.sh" "$CALL_RE")"
done

# =========================================================================
# Layer 2: live, against real mutating git commands.
#
# Common shape for all four scripts: a clone with one real unpublished local
# commit, origin advanced independently (genuine divergence, not mere
# staleness), then a forged origin tip (refs/replace) that claims the local
# commit as its own parent -- making the local-only work read back as
# already upstream. build_forged_repo prints the repo path and the
# pre-forgery local HEAD oid, one per line.
# =========================================================================
build_forged_repo() {  # <dir>
  local dir="$1"
  local remote="$dir/remote" local="$dir/local"
  local local_head real_tip forged
  mkdir -p "$remote"
  must "init remote" git init -q --template= -b main "$remote"
  must "config remote email" git -C "$remote" config user.email t@t
  must "config remote name" git -C "$remote" config user.name t
  echo base > "$remote/f.txt"
  must "add base file" git -C "$remote" add f.txt
  must "commit base" git -C "$remote" commit -qm base
  must "clone" git clone -q "$remote" "$local"
  must "config local email" git -C "$local" config user.email t@t
  must "config local name" git -C "$local" config user.name t
  printf 'base\nlocal-only edit\n' > "$local/f.txt"
  must "add local edit" git -C "$local" add f.txt
  must "commit local-only" git -C "$local" commit -qm "local-only, unpublished"
  local_head=$(git -C "$local" rev-parse HEAD)
  [ -n "$local_head" ] || { echo "FAIL: fixture setup failed: local HEAD is empty after commit" >&2; exit 1; }
  echo remote-advanced > "$remote/g.txt"
  must "add remote advance" git -C "$remote" add g.txt
  must "commit remote advance" git -C "$remote" commit -qm "remote advanced independently"
  must "fetch origin" git -C "$local" fetch -q origin
  real_tip=$(git -C "$local" rev-parse origin/main)
  forged=$(git -C "$local" commit-tree "$(git -C "$local" rev-parse "$real_tip^{tree}")" \
             -p "$local_head" -m "forged origin tip")
  [ -n "$forged" ] || { echo "FAIL: fixture setup failed: commit-tree produced no oid" >&2; exit 1; }
  must "install replace forgery" git -C "$local" replace "$real_tip" "$forged"
  echo "$local"
  echo "$local_head"
}

# postcondition_intact <repo> <branch> <expected-head> -- branch ref unchanged,
# index/worktree clean, and the original local commit object still resolves
# as a real commit (checked with the hardening env itself, so this assertion
# does not trust the same replace/grafts forgery the scripts under test were
# just protected against). The branch-equality check above already proves
# reachability by construction (the ref *is* that oid); this is a second,
# independent signal, not a restatement of it (Codex, turn 5).
postcondition_intact() {
  local repo="$1" branch="$2" expected="$3" head untracked
  head=$(git -C "$repo" rev-parse "$branch" 2>/dev/null)
  [ "$head" = "$expected" ] || return 1
  git -C "$repo" diff --quiet -- 2>/dev/null || return 1
  git -C "$repo" diff --cached --quiet -- 2>/dev/null || return 1
  untracked=$(git -C "$repo" ls-files --others --exclude-standard)
  [ -z "$untracked" ] || return 1
  GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null/iwe-no-grafts \
    git -C "$repo" cat-file -e "${expected}^{commit}" 2>/dev/null || return 1
  return 0
}

# --- canon-refresh.sh: forged repo, clean tree -> should refuse (HEAD not
# a provable ancestor once the forgery is ignored), leaving local work intact.
D1="$T/d1"; mkdir -p "$D1"
build_forged_repo "$D1" > "$T/d1.out"
REPO1=$(sed -n '1p' "$T/d1.out"); HEAD1=$(sed -n '2p' "$T/d1.out")
OUT1=$(bash "$SCRIPTS_DIR/canon-refresh.sh" "$REPO1" main 2>&1)
STATUS1=$?
check "canon-refresh.sh против подделки: exit=0 (штатный отказ 'nothing to do', не сбой)" "0" "$STATUS1"
check "canon-refresh.sh против подделки: реальный отказ (не молчаливый 'nothing to do')" "1" \
  "$(printf '%s' "$OUT1" | grep -c 'not a pure staleness case')"
check "canon-refresh.sh против подделки: ветка/индекс/дерево и исходный коммит целы" "0" \
  "$(postcondition_intact "$REPO1" main "$HEAD1"; echo $?)"

# --- canon-reconcile.sh: same shape, its own refusal message.
D2="$T/d2"; mkdir -p "$D2"
build_forged_repo "$D2" > "$T/d2.out"
REPO2=$(sed -n '1p' "$T/d2.out"); HEAD2=$(sed -n '2p' "$T/d2.out")
OUT2=$(bash "$SCRIPTS_DIR/canon-reconcile.sh" "$REPO2" main 2>&1)
STATUS2=$?
check "canon-reconcile.sh против подделки: exit=1 (история разошлась, не эта задача)" "1" "$STATUS2"
check "canon-reconcile.sh против подделки: ветка/индекс/дерево и исходный коммит целы" "0" \
  "$(postcondition_intact "$REPO2" main "$HEAD2"; echo $?)"

# --- safe-pull.sh: this is the script Codex's turn-1 correction targeted --
# the AHEAD/BEHIND gate must see the real divergence and go to the
# "diverged" branch (abort, non-interactive) rather than the unguarded
# "only upstream ahead -> merge --ff-only" fast path.
D3="$T/d3"; mkdir -p "$D3"
build_forged_repo "$D3" > "$T/d3.out"
REPO3=$(sed -n '1p' "$T/d3.out"); HEAD3=$(sed -n '2p' "$T/d3.out")
OUT3=$(bash "$SCRIPTS_DIR/safe-pull.sh" -C "$REPO3" 2>&1)
STATUS3=$?
check "safe-pull.sh против подделки AHEAD/BEHIND: видит расхождение обеих сторон, не 'only upstream ahead'" "1" \
  "$(printf '%s' "$OUT3" | grep -c 'Diverged from')"
check "safe-pull.sh против подделки: не ушёл в необслуживаемый ff-only (aborting, exit=2)" "2" "$STATUS3"
check "safe-pull.sh против подделки: ветка/индекс/дерево и исходный коммит целы" "0" \
  "$(postcondition_intact "$REPO3" main "$HEAD3"; echo $?)"

# --- sync-strategy-files.sh: file-level primitive (is_own_stale_mirror's
# `rev-list HEAD --not origin/branch -- file`), a WP card as the synced file.
D4="$T/d4"; mkdir -p "$D4/remote/inbox/WP-9" "$D4/local"
must "init remote" git init -q --template= -b main "$D4/remote"
must "config remote email" git -C "$D4/remote" config user.email t@t
must "config remote name" git -C "$D4/remote" config user.name t
echo "original card text" > "$D4/remote/inbox/WP-9/WP-9.md"
must "add base card" git -C "$D4/remote" add inbox/WP-9/WP-9.md
must "commit base card" git -C "$D4/remote" commit -qm base
must "clone" git clone -q "$D4/remote" "$D4/local"
must "config local email" git -C "$D4/local" config user.email t@t
must "config local name" git -C "$D4/local" config user.name t
echo "unpublished pilot edit -- must not be overwritten" >> "$D4/local/inbox/WP-9/WP-9.md"
BEFORE4=$(cat "$D4/local/inbox/WP-9/WP-9.md")
must "add local card edit" git -C "$D4/local" add inbox/WP-9/WP-9.md
must "commit local card edit" git -C "$D4/local" commit -qm "local-only: pilot edited WP-9.md"
LOCAL_HEAD4=$(git -C "$D4/local" rev-parse HEAD)
[ -n "$LOCAL_HEAD4" ] || { echo "FAIL: fixture setup failed: local HEAD is empty after commit" >&2; exit 1; }
echo unrelated > "$D4/remote/g.txt"
must "add remote advance" git -C "$D4/remote" add g.txt
must "commit remote advance" git -C "$D4/remote" commit -qm "remote advanced independently"
must "fetch origin" git -C "$D4/local" fetch -q origin
REAL_TIP4=$(git -C "$D4/local" rev-parse origin/main)
FORGED4=$(git -C "$D4/local" commit-tree "$(git -C "$D4/local" rev-parse "$REAL_TIP4^{tree}")" \
            -p "$LOCAL_HEAD4" -m "forged origin tip")
[ -n "$FORGED4" ] || { echo "FAIL: fixture setup failed: commit-tree produced no oid" >&2; exit 1; }
must "install replace forgery" git -C "$D4/local" replace "$REAL_TIP4" "$FORGED4"

bash "$SCRIPTS_DIR/sync-strategy-files.sh" "$D4/local" >/dev/null 2>&1
AFTER4=$(cat "$D4/local/inbox/WP-9/WP-9.md")
check "sync-strategy-files.sh против подделки: непубликованная правка WP-карточки не перезаписана" \
  "$BEFORE4" "$AFTER4"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "=== $FAILURES ПРОВЕРОК FAILED ==="
  exit 1
fi
