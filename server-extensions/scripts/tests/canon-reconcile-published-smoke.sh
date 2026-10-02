#!/usr/bin/env bash
# canon-reconcile-published-smoke.sh -- throwaway-repo scenarios for canon-reconcile-published.sh
# (WP-530 Ф38 / Ф5). Each scenario asserts an observable outcome, not just "did not crash".
set -uo pipefail
SCRIPT="${1:-$(dirname "$0")/../canon-reconcile-published.sh}"
[ -x "$SCRIPT" ] || SCRIPT="$(cd "$(dirname "$0")" && pwd)/../canon-reconcile-published.sh"
# shellcheck source=ancestry-hardening-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/ancestry-hardening-lib.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
DGLOCK_LIB_SRC="$(dirname "$SCRIPT")/lib/dirty-guard-lock.sh"; [ -r "$DGLOCK_LIB_SRC" ] || DGLOCK_LIB_SRC="$(cd "$(dirname "$0")" && pwd)/../lib/dirty-guard-lock.sh"
mkdir -p "$SANDBOX/lib" && cp "$DGLOCK_LIB_SRC" "$SANDBOX/lib/dirty-guard-lock.sh"   # the sandbox copies of the script find the lock library next to them (SCRIPT_DIR)
export IWE_WORKSPACE="$SANDBOX/no-workspace"   # ledger-append absent -> ledger_note is a no-op
export IWE_RUNTIME_DIR="$SANDBOX/runtime"; mkdir -p "$IWE_RUNTIME_DIR/sessions"   # no live writers unless a scenario adds one
export IWE_RUNTIME=claude-code   # host NAME (DP.IWE.011 §C) -- must never be read as a directory
fails=0
assert() { if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails+1)); fi; }
# `md5` is macOS-only (BSD coreutils); GitHub's ubuntu-latest runner has neither
# `md5` nor a `md5` alias. shasum ships on both macOS and ubuntu-latest, so it
# is the cross-platform default; sha256sum is the fallback for a bare Linux
# box that lacks shasum.
hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    echo "FAIL: neither shasum nor sha256sum is available" >&2
    return 1
  fi
}
# Fail fast, not silently: without -e, a hash_stdin failure inside "$(git ... |
# hash_stdin)" would leave the caller comparing two empty strings and passing
# the assert -- checking the precondition once, up front, turns a missing tool
# into a loud failure here instead of a quiet false-green at scenario 13.
command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 || {
  echo "FAIL: neither shasum nor sha256sum is available in this environment" >&2
  exit 1
}

fresh() {  # <name> -- bare origin + canonical clone with one base commit; sets ORIGIN, CANON
  ORIGIN="$SANDBOX/$1-origin.git"; CANON="$SANDBOX/$1-canon"
  # -b main: a bare repo's HEAD symref defaults to whatever `init.defaultBranch`
  # resolves to on the host, not necessarily "main" (GitHub's ubuntu-latest
  # runner defaults to master; this Mac's git happens to default to main).
  # Every clone of $ORIGIN below relies on its HEAD resolving to "main" to
  # auto-checkout a local "main" branch -- an unresolvable HEAD symref instead
  # produces "remote HEAD refers to nonexistent ref, unable to checkout" and a
  # clone with no branch checked out at all, so every later `push origin main`
  # from that clone fails with "src refspec main does not match any". Found
  # live on the first real ubuntu-latest CI run (15 failed assertions), not
  # locally on macOS. ancestry-mutation-guards-smoke.sh already does this
  # correctly (`git init -q --template= -b main`) -- this file was the only
  # one of the 7 missing it.
  git init -q --bare -b main "$ORIGIN"
  git init -q "$CANON" && git -C "$CANON" -c user.name=t -c user.email=t@t checkout -q -b main
  echo base > "$CANON/a.txt"; git -C "$CANON" add a.txt; git -C "$CANON" -c user.name=t -c user.email=t@t commit -qm base
  git -C "$CANON" remote add origin "$ORIGIN"; git -C "$CANON" push -q origin main
}
commit_in() { git -C "$1" add -A; git -C "$1" -c user.name=t -c user.email=t@t commit -qm "$2"; }
# origin gets the same patch republished under a new SHA (what isolate-push does)
republish_on_origin() {  # <canon> <commit> -- cherry-pick onto a fresh clone of origin and push
  local pub="$SANDBOX/pub-$RANDOM"; git clone -q "$ORIGIN" "$pub"
  git -C "$pub" fetch -q "$1" "$2"; git -C "$pub" -c user.name=o -c user.email=o@o cherry-pick FETCH_HEAD >/dev/null
  git -C "$pub" push -q origin main
}

echo "scenario 1: diverged, patch-equivalent, clean -> replaced, untracked intact"
fresh s1; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"; echo keep > "$CANON/note.tmp"
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
git -C "$CANON" fetch -q origin
assert "$rc" "0" "exit 0"
assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD == origin/main"
assert "$(cat "$CANON/note.tmp")" "keep" "untracked file kept"
assert "$(git -C "$CANON" status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0" "tracked tree clean"

echo "scenario 2: unique local commit -> fail closed, nothing touched"
fresh s2; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"; echo two > "$CANON/c.txt"; commit_in "$CANON" "unique"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"

echo "scenario 3: tracked dirt -> fail closed"
fresh s3; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"; echo dirty >> "$CANON/a.txt"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"; assert "$(tail -1 "$CANON/a.txt")" "dirty" "dirt preserved"

echo "scenario 4a: untracked collides with target file, different content -> fail closed"
fresh s4a; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-extra"; git clone -q "$ORIGIN" "$pub"; echo origin-version > "$pub/new.txt"; commit_in "$pub" "origin adds new.txt"; git -C "$pub" push -q origin main
echo local-version > "$CANON/new.txt"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$(cat "$CANON/new.txt")" "local-version" "untracked not overwritten"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"

echo "scenario 4b: untracked collides with target file, identical content -> replaced, hash recorded == target blob"
fresh s4b; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-extra2"; git clone -q "$ORIGIN" "$pub"; echo same > "$pub/new.txt"; commit_in "$pub" "origin adds new.txt"; git -C "$pub" push -q origin main
echo same > "$CANON/new.txt"; BEFORE=$(git -C "$CANON" hash-object new.txt)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
git -C "$CANON" fetch -q origin
assert "$rc" "0" "exit 0"; assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD == origin/main"
assert "$(git -C "$CANON" rev-parse HEAD:new.txt)" "$BEFORE" "replaced file identical to the pre-replacement untracked content"

echo "scenario 4c: untracked directory where target has a file -> fail closed"
fresh s4c; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-extra3"; git clone -q "$ORIGIN" "$pub"; echo f > "$pub/thing"; commit_in "$pub" "origin adds file thing"; git -C "$pub" push -q origin main
mkdir -p "$CANON/thing"; echo x > "$CANON/thing/inner"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"; assert "$(cat "$CANON/thing/inner")" "x" "untracked dir intact"

echo "scenario 5: HEAD already ancestor of origin -> exit 0, no action (canon-refresh's job)"
fresh s5; pub="$SANDBOX/pub-ff"; git clone -q "$ORIGIN" "$pub"; echo z > "$pub/z.txt"; commit_in "$pub" "origin ahead"; git -C "$pub" push -q origin main
H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "0" "exit 0"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD untouched"

echo "scenario 6: lock busy -> exit 0, no action"
fresh s6; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
H=$(git -C "$CANON" rev-parse HEAD); mkdir "$CANON/.git/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$(hostname)" "$$" > "$CANON/.git/dirty-guard.lock/owner"
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "0" "exit 0"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD untouched while lock held"

echo "scenario 4d: untracked file where target has paths below it (file vs target directory) -> fail closed"
fresh s4d; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-extra4"; git clone -q "$ORIGIN" "$pub"; mkdir -p "$pub/dir"; echo f > "$pub/dir/inner"; commit_in "$pub" "origin adds dir/inner"; git -C "$pub" push -q origin main
echo plain > "$CANON/dir"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$(cat "$CANON/dir")" "plain" "untracked file intact"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"

echo "scenario 4e: untracked sibling next to a new tracked file in the same dir -> not a collision, replaced"
fresh s4e; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-extra5"; git clone -q "$ORIGIN" "$pub"; mkdir -p "$pub/inbox/WP-573"; echo card > "$pub/inbox/WP-573/WP-573.md"; commit_in "$pub" "origin adds card"; git -C "$pub" push -q origin main
mkdir -p "$CANON/inbox/WP-573"; echo mine > "$CANON/inbox/WP-573/x"
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
git -C "$CANON" fetch -q origin
assert "$rc" "0" "exit 0"; assert "$(cat "$CANON/inbox/WP-573/x")" "mine" "sibling untracked kept"; assert "$(cat "$CANON/inbox/WP-573/WP-573.md")" "card" "tracked file materialised"

echo "scenario 4f: same content but type mismatch (symlink vs regular file) -> fail closed"
fresh s4f; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-extra6"; git clone -q "$ORIGIN" "$pub"; echo a.txt > "$pub/ln"; commit_in "$pub" "origin adds regular file ln"; git -C "$pub" push -q origin main
ln -s a.txt "$CANON/ln"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$([ -L "$CANON/ln" ] && echo link)" "link" "symlink intact"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"

echo "scenario 7: local merge commit (cherry cannot prove it) -> fail closed"
fresh s7; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
git -C "$CANON" checkout -q -b side; echo s > "$CANON/s.txt"; commit_in "$CANON" "side"; git -C "$CANON" checkout -q main
git -C "$CANON" -c user.name=t -c user.email=t@t merge -q --no-ff -m "local merge" side
republish_on_origin "$CANON" "$(git -C "$CANON" rev-parse side)"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"

echo "scenario 8: live canonical writer semaphore -> fail closed (strict barrier)"
fresh s8; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
printf 'agent: claude-code\npid: %s\n' "$$" > "$IWE_RUNTIME_DIR/sessions/claude-code-writer.open"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1 with live writer"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
rm -f "$IWE_RUNTIME_DIR/sessions/claude-code-writer.open"   # only the pid-less semaphore may count from here (otherwise the previous live one would satisfy the check)
printf 'agent: codex\n' > "$IWE_RUNTIME_DIR/sessions/codex-nopid.open"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "semaphore without pid counts as a live writer"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"; rm -f "$IWE_RUNTIME_DIR/sessions/codex-nopid.open"
printf 'agent: claude-code\npid: %s\nisolated_worktree: /tmp/x\n' "$$" > "$IWE_RUNTIME_DIR/sessions/claude-code-writer.open"
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
git -C "$CANON" fetch -q origin
assert "$rc" "0" "isolated session does not block"; assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "replaced once only isolated sessions are live"
rm -f "$IWE_RUNTIME_DIR/sessions/claude-code-writer.open"

echo "scenario 9: origin advanced past the caller's pinned oid -> targets the live tip"
fresh s9; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
P1=$(git -C "$CANON" ls-remote origin refs/heads/main | cut -c1-40)
pub="$SANDBOX/pub-extra7"; git clone -q "$ORIGIN" "$pub"; echo later > "$pub/later.txt"; commit_in "$pub" "origin later"; git -C "$pub" push -q origin main
bash "$SCRIPT" "$CANON" main "$P1" >/dev/null 2>&1; rc=$?
git -C "$CANON" fetch -q origin
assert "$rc" "0" "exit 0"; assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD == live origin tip, not the stale pin"

echo "scenario 10: collision inside a nested directory (not repo root) -> fail closed"
fresh s10; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-nested"; git clone -q "$ORIGIN" "$pub"; mkdir -p "$pub/inbox/WP-9"; echo origin > "$pub/inbox/WP-9/WP-9.md"; commit_in "$pub" "origin adds nested card"; git -C "$pub" push -q origin main
mkdir -p "$CANON/inbox/WP-9"; echo local > "$CANON/inbox/WP-9/WP-9.md"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$(cat "$CANON/inbox/WP-9/WP-9.md")" "local" "nested untracked not overwritten"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"

echo "scenario 11: git-ignored local file where target adds a tracked file with other content -> fail closed"
fresh s11; echo '*.lock' > "$CANON/.gitignore"; commit_in "$CANON" "ignore"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-ignored"; git clone -q "$ORIGIN" "$pub"; echo origin > "$pub/run.lock"; git -C "$pub" add -f run.lock; git -C "$pub" -c user.name=o -c user.email=o@o commit -qm "origin tracks run.lock"; git -C "$pub" push -q origin main
echo local > "$CANON/run.lock"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$(cat "$CANON/run.lock")" "local" "ignored file not overwritten"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"

echo "scenario 12: a foreign live lock is left in place after our no-op exit"
fresh s12; mkdir "$CANON/.git/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$(hostname)" "$$" > "$CANON/.git/dirty-guard.lock/owner"
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1
assert "$([ -d "$CANON/.git/dirty-guard.lock" ] && echo present)" "present" "foreign lock still present"; rm -rf "$CANON/.git/dirty-guard.lock"

echo "scenario 13: refusal writes nothing inside the repository (log goes to runtime dir)"
fresh s13; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
echo two > "$CANON/c.txt"; commit_in "$CANON" "unique"; BEFORE=$(git -C "$CANON" status --porcelain | hash_stdin); MARK=$(mktemp); sleep 1
LOG_BEFORE=$(grep -c ' refused ' "$IWE_RUNTIME_DIR/canon-reconcile-published.log" 2>/dev/null || echo 0)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1
assert "$(git -C "$CANON" status --porcelain | hash_stdin)" "$BEFORE" "repo status unchanged by the refusal"
assert "$(find "$CANON" -newer "$MARK" -type f -not -path "$CANON/.git/*" | wc -l | tr -d ' ')" "0" "no working-tree file written by the refusal (git's own fetch bookkeeping under .git is expected)"
assert "$(( $(grep -c ' refused ' "$IWE_RUNTIME_DIR/canon-reconcile-published.log") - LOG_BEFORE ))" "1" "refusal logged exactly once in the runtime log"

echo "scenario 14 (static): isolate-push.sh defines post_publish_reconcile before its first use"
IP="${ISOLATE_PUSH:-$HOME/IWE/DS-my-strategy/scripts/isolate-push.sh}"
if [ -f "$IP" ]; then
  def=$(grep -n '^post_publish_reconcile()' "$IP" | head -1 | cut -d: -f1); use=$(grep -n '^ *post_publish_reconcile "' "$IP" | head -1 | cut -d: -f1)
  assert "$([ -n "$def" ] && [ -n "$use" ] && [ "$def" -lt "$use" ] && echo ok)" "ok" "definition (line $def) precedes first call (line $use)"
else
  echo "  skip isolate-push.sh not found at $IP"
fi

echo "scenario 15: untracked symlink ancestor where target adds a path below it -> fail closed, symlink intact"
fresh s15; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-symanc"; git clone -q "$ORIGIN" "$pub"; mkdir -p "$pub/lnk"; echo f > "$pub/lnk/inner"; commit_in "$pub" "origin adds lnk/inner"; git -C "$pub" push -q origin main
mkdir -p "$CANON/realdir"; ln -s realdir "$CANON/lnk"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$([ -L "$CANON/lnk" ] && echo link)" "link" "symlink ancestor intact"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"

echo "scenario 16: tracked file -> directory conversion published on origin is not a collision"
fresh s16; echo conv > "$CANON/conv"; commit_in "$CANON" "add conv file"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-conv"; git clone -q "$ORIGIN" "$pub"; git -C "$pub" rm -q conv; mkdir -p "$pub/conv"; echo inner > "$pub/conv/inner"; git -C "$pub" add conv/inner; git -C "$pub" -c user.name=o -c user.email=o@o commit -qm "conv file->dir"; git -C "$pub" push -q origin main
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
git -C "$CANON" fetch -q origin
assert "$rc" "0" "exit 0"; assert "$(cat "$CANON/conv/inner")" "inner" "directory materialised"; assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD == origin/main"

echo "scenario 17: refs/replace forgery makes an undelivered commit look patch-equivalent -> refused by the delivery proof itself"
# Origin holds BASE -> Q -> P. The local commit U is undelivered AND its end state
# differs from origin (x.txt says "different", origin says "pub"). The forgery
# replaces U with F (origin's tree, parent Q = exactly P's patch), so an unguarded
# `git cherry` says "-"; the guarded one says "+". WP-561 Ф24 added a second,
# content-based proof (same tree entries in HEAD and target) -- it must not be
# fooled either: it reads the REAL tree of U (GIT_NO_REPLACE_OBJECTS exported by
# the script), where x.txt differs, and refuses.
fresh s17
pub="$SANDBOX/pub-forge"; git clone -q "$ORIGIN" "$pub"
echo mine > "$pub/y.txt"; commit_in "$pub" "origin publishes y"; Q=$(git -C "$pub" rev-parse HEAD)
echo pub > "$pub/x.txt"; commit_in "$pub" "origin publishes x"; git -C "$pub" push -q origin main
echo mine > "$CANON/y.txt"; echo different > "$CANON/x.txt"; commit_in "$CANON" "undelivered local edit of x"; U=$(git -C "$CANON" rev-parse HEAD)
git -C "$CANON" fetch -q origin
FORGED=$(git -C "$CANON" -c user.name=t -c user.email=t@t commit-tree "$(git -C "$CANON" rev-parse 'origin/main^{tree}')" -p "$Q" -m forged)
git -C "$CANON" replace "$U" "$FORGED"
assert "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$CANON" status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0" "precondition: tracked tree clean in the real world"
assert "$(git -C "$CANON" cherry origin/main "$U" | cut -c1)" "-" "precondition: the forgery fools an unguarded git cherry"
assert "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$CANON" cherry origin/main "$U" | cut -c1)" "+" "precondition: the real commit is not on the target"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1: a forged equivalence is not proof of delivery"
assert "$(git -C "$CANON" rev-parse refs/heads/main)" "$U" "branch still points at the undelivered commit"
assert "$(printf '%s' "$out" | grep -c 'local-only commits not on target')" "1" "refused by the delivery proof, not by another preflight"
assert "$(printf '%s' "$out" | grep -c 'end state differs from the target: x.txt')" "1" "the content proof names the real differing path (forgery ignored)"

echo "scenario 18 (static): exact hardening exports precede the first ancestry-sensitive call"
assert "$(hardening_violations "$SCRIPT" 'is-ancestor|git cherry')" "" "canon-reconcile-published.sh is hardened against refs/replace and grafts"

echo "scenario 19 (WP-561 Ф24): honest squash with the SAME end state as origin -> content-superseded, replaced"
fresh s19
pub="$SANDBOX/pub-s19"; git clone -q "$ORIGIN" "$pub"
echo mine > "$pub/y.txt"; commit_in "$pub" "origin y"; echo pub > "$pub/x.txt"; commit_in "$pub" "origin x"; git -C "$pub" push -q origin main
echo mine > "$CANON/y.txt"; echo pub > "$CANON/x.txt"; commit_in "$CANON" "local squash of y and x"; U=$(git -C "$CANON" rev-parse HEAD)
git -C "$CANON" fetch -q origin
assert "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$CANON" cherry origin/main "$U" | cut -c1)" "+" "precondition: patch-id cannot see the squash"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "0" "exit 0: end state provably on the target"
assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD replaced by origin tip"
assert "$(printf '%s' "$out" | grep -c 'content-superseded=1')" "1" "report counts the superseded commit"
assert "$(git -C "$CANON" status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0" "tree clean afterwards"

echo "scenario 20 (WP-561 Ф24): tracked dirt that already equals the target byte-for-byte (point-installed fix) -> replaced"
fresh s20; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-s20"; git clone -q "$ORIGIN" "$pub"; echo fixed > "$pub/a.txt"; commit_in "$pub" "origin fixes a"; git -C "$pub" push -q origin main
echo fixed > "$CANON/a.txt"                                   # someone copied the published bytes into the frozen canon
assert "$(git -C "$CANON" status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "1" "precondition: canon is dirty in git's eyes"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "0" "exit 0: identical dirt is not a reason to stay frozen"
assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD replaced"
assert "$(cat "$CANON/a.txt")" "fixed" "bytes unchanged on disk"
assert "$(git -C "$CANON" status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0" "tree clean afterwards"
assert "$(printf '%s' "$out" | grep -c 'tolerated identical dirty paths=1')" "1" "report counts the tolerated path"

echo "scenario 21 (WP-561 Ф24): tracked dirt that DIFFERS from the target -> still fail closed, named"
fresh s21; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"; echo mine > "$CANON/a.txt"; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
assert "$(printf '%s' "$out" | grep -c 'tracked changes differ from target: a.txt')" "1" "refusal names the differing path"

echo "scenario 22 (WP-561 Ф24): STAGED change, even if identical to the target -> fail closed (index is intent, not bytes)"
fresh s22; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-s22"; git clone -q "$ORIGIN" "$pub"; echo fixed > "$pub/a.txt"; commit_in "$pub" "origin fixes a"; git -C "$pub" push -q origin main
echo fixed > "$CANON/a.txt"; git -C "$CANON" add a.txt; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
assert "$(printf '%s' "$out" | grep -c 'staged changes present in index: a.txt')" "1" "refusal names the staged path"

echo "scenario 23 (WP-561 Ф24): same blob but executable bit differs from the target -> fail closed (mode is part of the entry)"
fresh s23; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-s23"; git clone -q "$ORIGIN" "$pub"; echo fixed > "$pub/a.txt"; commit_in "$pub" "origin fixes a"; git -C "$pub" push -q origin main
echo fixed > "$CANON/a.txt"; chmod +x "$CANON/a.txt"; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
assert "$(printf '%s' "$out" | grep -c 'tracked changes differ from target: a.txt')" "1" "mode mismatch is a difference"

echo "scenario 24 (WP-561 Ф24): unique local commit only PARTIALLY superseded -> fail closed, first differing path named"
fresh s24
pub="$SANDBOX/pub-s24"; git clone -q "$ORIGIN" "$pub"; echo mine > "$pub/y.txt"; commit_in "$pub" "origin y"; git -C "$pub" push -q origin main
echo mine > "$CANON/y.txt"; echo extra > "$CANON/z.txt"; commit_in "$CANON" "local y plus z"; H=$(git -C "$CANON" rev-parse HEAD)
git -C "$CANON" fetch -q origin
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
assert "$(printf '%s' "$out" | grep -c 'end state differs from the target: z.txt')" "1" "z.txt (not on origin) is the named difference"

echo "scenario 25 (WP-561 Ф24): tracked file deleted on disk and absent on the target -> tolerated, replaced"
fresh s25; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-s25"; git clone -q "$ORIGIN" "$pub"; git -C "$pub" rm -q b.txt; commit_in "$pub" "origin removes b"; git -C "$pub" push -q origin main
rm "$CANON/b.txt"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "0" "exit 0"
assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD replaced"
assert "$(test -e "$CANON/b.txt" && echo present || echo absent)" "absent" "b.txt stays absent"

# --- WP-530 Ф72: ANCESTRAL_PATH criterion -------------------------------------
origin_edit() {  # <tag> <file> <content> -- one commit on origin editing <file> (removing it when content is __RM__)
  local pub="$SANDBOX/pub-$1-$RANDOM"; git clone -q "$ORIGIN" "$pub"
  if [ "$3" = "__RM__" ]; then git -C "$pub" rm -q "$2"; else echo "$3" > "$pub/$2"; fi
  commit_in "$pub" "origin $1 $2"; git -C "$pub" push -q origin main
}
diverged_base() {  # <name> -- canon with one local commit already republished on origin (diverged, otherwise clean)
  fresh "$1"; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; republish_on_origin "$CANON" "$(git -C "$CANON" rev-parse HEAD)"
}

echo "scenario 26 (Ф72): dirty path holds an EARLIER origin version of the same live path -> ANCESTRAL_PATH, replaced"
diverged_base s26; origin_edit s26a a.txt v2; origin_edit s26b a.txt v3
echo v2 > "$CANON/a.txt"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
git -C "$CANON" fetch -q origin
assert "$rc" "0" "exit 0"; assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD replaced by origin tip"
assert "$(cat "$CANON/a.txt")" "v3" "a.txt now carries the origin tip content"
assert "$(printf '%s' "$out" | grep -c 'ancestral-path dirty=1 commit-paths=0')" "1" "report counts the ancestral dirty path"

echo "scenario 27 (Ф72): local-only commit whose path end state is an EARLIER origin version -> ANCESTRAL_PATH, replaced"
diverged_base s27
pub="$SANDBOX/pub-s27"; git clone -q "$ORIGIN" "$pub"; echo v2 > "$pub/a.txt"; echo extra > "$pub/c.txt"; commit_in "$pub" "origin a v2 plus c"; git -C "$pub" push -q origin main
origin_edit s27b a.txt v3
echo v2 > "$CANON/a.txt"; commit_in "$CANON" "local a v2 only"; U=$(git -C "$CANON" rev-parse HEAD); git -C "$CANON" fetch -q origin
assert "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$CANON" cherry origin/main | grep -c "^+ $U")" "1" "precondition: patch-id cannot see it, so only the path proof can"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "0" "exit 0"; assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD replaced by origin tip"
assert "$(printf '%s' "$out" | grep -c 'ancestral-path dirty=0 commit-paths=1')" "1" "report counts the ancestral commit path"

echo "scenario 28 (Ф72): the path was DELETED on origin -> the old version is not ancestral, fail closed (dirty)"
diverged_base s28; origin_edit s28a a.txt v2; origin_edit s28b a.txt __RM__
echo v2 > "$CANON/a.txt"; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"; assert "$(cat "$CANON/a.txt")" "v2" "dirt preserved"
assert "$(printf '%s' "$out" | grep -c 'tracked changes differ from target: a.txt')" "1" "refusal names the dead path"

echo "scenario 28b (Ф72): the path was deleted on origin -> fail closed (local-only commit)"
diverged_base s28b
pub="$SANDBOX/pub-s28b"; git clone -q "$ORIGIN" "$pub"; echo v2 > "$pub/a.txt"; echo extra > "$pub/c.txt"; commit_in "$pub" "origin a v2 plus c"; git -C "$pub" push -q origin main
origin_edit s28bb a.txt __RM__
echo v2 > "$CANON/a.txt"; commit_in "$CANON" "local a v2 only"; U=$(git -C "$CANON" rev-parse HEAD); H=$U; git -C "$CANON" fetch -q origin
assert "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$CANON" cherry origin/main | grep -c "^+ $U")" "1" "precondition: the commit is not patch-equivalent"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
assert "$(printf '%s' "$out" | grep -c 'end state differs from the target: a.txt')" "1" "refusal names the dead path"

echo "scenario 29 (Ф72): canon version never occurred in origin's history of the path -> fail closed (dirty and commit)"
diverged_base s29; origin_edit s29a a.txt v2; origin_edit s29b a.txt v3
echo never > "$CANON/a.txt"; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1 (dirty)"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged (dirty)"
assert "$(printf '%s' "$out" | grep -c 'tracked changes differ from target: a.txt')" "1" "dirty refusal names a.txt"
commit_in "$CANON" "local a never"; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1 (commit)"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged (commit)"
assert "$(printf '%s' "$out" | grep -c 'end state differs from the target: a.txt')" "1" "commit refusal names a.txt"

echo "scenario 30 (Ф72): admissible ancestral path mixed with ONE unique dirty path -> refused as a whole, nothing touched"
diverged_base s30; origin_edit s30a a.txt v2; origin_edit s30b a.txt v3
echo v2 > "$CANON/a.txt"; echo novel >> "$CANON/b.txt"; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
assert "$(cat "$CANON/a.txt")" "v2" "the admissible path was not rewritten either"
assert "$(tail -1 "$CANON/b.txt")" "novel" "the unique dirt is preserved"
assert "$(printf '%s' "$out" | grep -c 'tracked changes differ from target: b.txt')" "1" "refusal names exactly the unique path"

echo "scenario 31 (Ф72): staged change stays a refusal even when its content is an ancestral version"
diverged_base s31; origin_edit s31a a.txt v2; origin_edit s31b a.txt v3
echo v2 > "$CANON/a.txt"; git -C "$CANON" add a.txt; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
assert "$(printf '%s' "$out" | grep -c 'staged changes present in index: a.txt')" "1" "staged refusal wins"

# --- WP-530 Ф72 cold review: gitlinks and pathspec magic never count as ancestral ---
GL1=1111111111111111111111111111111111111111; GL2=2222222222222222222222222222222222222222
origin_gitlink() {  # <tag> <path> <sha> [extra-file] -- one origin commit pointing <path> at gitlink <sha> (replacing whatever was there)
  local pub="$SANDBOX/pub-$1-$RANDOM"; git clone -q "$ORIGIN" "$pub"
  git -C "$pub" rm -q --cached --ignore-unmatch "$2"; rm -rf "${pub:?}/$2"
  git -C "$pub" update-index --add --cacheinfo "160000,$3,$2"
  if [ -n "${4:-}" ]; then echo extra > "$pub/$4"; git -C "$pub" add "$4"; fi
  git -C "$pub" -c user.name=o -c user.email=o@o commit -qm "origin gitlink $2 $1"; git -C "$pub" push -q origin main
}

echo "scenario 32a (Ф72): local commit moves a submodule pointer to a value origin once had -> gitlink is never ancestral, fail closed"
diverged_base s32a; origin_gitlink s32aa sub "$GL1" c.txt; origin_gitlink s32ab sub "$GL2"
mkdir "$CANON/sub"   # an empty directory is how git sees an unpopulated submodule: no dirt
git -C "$CANON" update-index --add --cacheinfo "160000,$GL1,sub"; git -C "$CANON" -c user.name=t -c user.email=t@t commit -qm "local sub -> GL1"
U=$(git -C "$CANON" rev-parse HEAD); git -C "$CANON" fetch -q origin
assert "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$CANON" cherry origin/main | grep -c "^+ $U")" "1" "precondition: not patch-equivalent"
assert "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$CANON" ls-tree origin/main sub | cut -c1-6)" "160000" "precondition: sub is a gitlink on the target"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$U" "HEAD unchanged"
assert "$(printf '%s' "$out" | grep -c 'end state differs from the target: sub')" "1" "refusal names the gitlink path"

echo "scenario 32b (Ф72): path was a file with the canon's content, but is a gitlink on the target now -> fail closed"
diverged_base s32b; origin_edit s32ba a.txt v2; origin_gitlink s32bb a.txt "$GL1"
echo v2 > "$CANON/a.txt"; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"; assert "$(cat "$CANON/a.txt")" "v2" "dirt preserved"
assert "$(printf '%s' "$out" | grep -c 'tracked changes differ from target: a.txt')" "1" "refusal names the path"

echo "scenario 33 (Ф72): path named ':(top)victim' must not be resolved as pathspec magic onto the neighbour 'victim' -> fail closed"
fresh s33; echo v2 > "$CANON/victim"; echo one > "$CANON/b.txt"; commit_in "$CANON" "local victim v2"; republish_on_origin "$CANON" "$(git -C "$CANON" rev-parse HEAD)"
origin_edit s33b victim v3
echo x > "$CANON/:(top)victim"; commit_in "$CANON" "local file literally named :(top)victim"; U=$(git -C "$CANON" rev-parse HEAD); git -C "$CANON" fetch -q origin
assert "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$CANON" ls-tree origin/main -- victim | wc -l | tr -d ' ')" "1" "precondition: the neighbour 'victim' exists on the target"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$U" "HEAD unchanged"
assert "$(printf '%s' "$out" | grep -c 'end state differs from the target')" "1" "refused by the end-state proof"

refusing_canon() {  # <name> -- a canon whose reconcile always refuses with the class "local-only commits not on target"; sets ORIGIN, CANON
  fresh "$1"; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; republish_on_origin "$CANON" "$(git -C "$CANON" rev-parse HEAD)"
  echo two > "$CANON/c.txt"; commit_in "$CANON" "unique"
}
alerts_in() { printf '%s' "$1" | grep -c 'canon-reconcile-published: ALERT'; }   # <output> -> number of ALERT lines
streak_file() { ls "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.streak 2>/dev/null | head -1; }   # only valid right after `rm -f` of all streak files and one run

# --- Codex review of Ф76 rounds 1-2 (peer-session 2026-10-01-20): the refusal streak is an append-only journal ---
FAKEBIN="$SANDBOX/fakebin"; mkdir -p "$FAKEBIN"; REAL_DATE=$(command -v date); REAL_GIT=$(command -v git); REAL_LS=$(command -v ls)
cat > "$FAKEBIN/date" <<EOF
#!/usr/bin/env bash
if [ -n "\${FAKE_DATE_BROKEN:-}" ] && [ "\$*" = "-u +%s" ]; then exit 1; fi
if [ -n "\${FAKE_NOW_FILE:-}" ] && [ "\$*" = "-u +%s" ]; then cat "\$FAKE_NOW_FILE"; exit 0; fi
if [ -n "\${FAKE_NOW:-}" ] && [ "\$*" = "-u +%s" ]; then echo "\$FAKE_NOW"; exit 0; fi
exec "$REAL_DATE" "\$@"
EOF
cat > "$FAKEBIN/git" <<EOF
#!/usr/bin/env bash
if [ -n "\${FAIL_UPDATE_REF:-}" ]; then for a in "\$@"; do [ "\$a" = update-ref ] && exit 1; done; fi
exec "$REAL_GIT" "\$@"
EOF
cat > "$FAKEBIN/ls" <<EOF
#!/usr/bin/env bash
if [ -n "\${FAIL_LS:-}" ]; then exit 1; fi
if [ -n "\${FAIL_LS_E:-}" ]; then case "\$*" in *-lde*) exit 1 ;; esac; fi
if [ -n "\${LS_UNSTABLE_COUNTER:-}" ]; then case "\$*" in *-di*) n=\$(cat "\$LS_UNSTABLE_COUNTER" 2>/dev/null); n=\$((\${n:-0} + 1)); echo "\$n" > "\$LS_UNSTABLE_COUNTER"; echo "\$n \${!#}"; exit 0 ;; esac; fi
exec "$REAL_LS" "\$@"
EOF
REAL_PS=$(command -v ps); REAL_MV=$(command -v mv); REAL_RM=$(command -v rm); REAL_LN=$(command -v ln)
cat > "$FAKEBIN/ps" <<EOF
#!/usr/bin/env bash
# FAIL_PS=1: every call fails. LISTING=fail|empty|only1: the listing of all processes (-A) fails, is empty, or holds nothing but pid 1.
# LISTING=hide:<pid>: the real listing of all processes without that pid.
if [ -n "\${FAIL_PS:-}" ]; then exit 1; fi
case "\$*" in
  *-A*) case "\${LISTING:-}" in
          fail) exit 1 ;;
          empty) exit 0 ;;
          only1) echo 1; exit 0 ;;
          hide:*) "$REAL_PS" "\$@" | awk -v h="\${LISTING#hide:}" '{ x = \$0; gsub(/[ \\t]/, "", x) } x != h'; exit 0 ;;
        esac ;;
esac
exec "$REAL_PS" "\$@"
EOF
cat > "$FAKEBIN/mv" <<EOF
#!/usr/bin/env bash
if [ -n "\${FAIL_MV_OWNER:-}" ]; then case "\$*" in *owner.tmp*) exit 1 ;; esac; fi
exec "$REAL_MV" "\$@"
EOF
cat > "$FAKEBIN/ln" <<EOF
#!/usr/bin/env bash
if [ -n "\${FAIL_MV_OWNER:-}" ]; then case "\$*" in *owner.tmp*) exit 1 ;; esac; fi
exec "$REAL_LN" "\$@"
EOF
cat > "$FAKEBIN/rm" <<EOF
#!/usr/bin/env bash
# FAIL_RM_SERIES=lockbusy|streak: removing a journal of that kind fails
if [ -n "\${FAIL_RM_SERIES:-}" ]; then case "\$*" in *".\${FAIL_RM_SERIES}") exit 1 ;; esac; fi
exec "$REAL_RM" "\$@"
EOF
chmod +x "$FAKEBIN/date" "$FAKEBIN/git" "$FAKEBIN/ls" "$FAKEBIN/ps" "$FAKEBIN/mv" "$FAKEBIN/ln" "$FAKEBIN/rm"
at() { local t="$1"; shift; env PATH="$FAKEBIN:$PATH" FAKE_NOW="$t" "$@"; }   # <epoch> <command...>: the command reads this time from `date -u +%s`
T=2000000000; CLASS_U="local-only commits not on target"
HN="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"   # the name the guard writes into the owner record of its lock
DEAD_PID=$(( $(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 999998) + 1 ))   # a pid that cannot exist: above pid_max (4194304 on Tsekh) and above every pid of macOS
put_journal() {  # <file> <class> <first> <count> [<claim-epoch>...]: <count> refusals of <class> (the first stamped <first>, the others one second apart), then one alert claim per extra argument
  local f="$1" cls="$2" first="$3" n="$4" i=0 c; shift 4
  : > "$f"
  while [ "$i" -lt "$n" ]; do printf 'R\t%s\t%s\tseed.%s\n' $((first + i)) "$cls" "$i" >> "$f"; i=$((i + 1)); done
  for c in "$@"; do printf 'A\t%s\t%s\tseed.claim.%s\n' "$c" "$cls" "$c" >> "$f"; done
}
prime() { refusing_canon "$1"; rm -rf "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.streak*; bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; F=$(streak_file); }   # a refusing canon with exactly one journal F
records() { grep -c "^$2" "$1"; }   # <file> <R|A> -> number of records of that kind
run_limited() {  # <seconds> <command...> -> LIMITED_RC (124 = still running at the limit, killed) and LIMITED_OUT
  local limit="$1" pid i=0; shift
  "$@" > "$SANDBOX/limited.out" 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt $((limit * 10)) ]; then kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; LIMITED_RC=124; LIMITED_OUT=$(cat "$SANDBOX/limited.out"); return 0; fi
    sleep 0.1
  done
  wait "$pid"; LIMITED_RC=$?; LIMITED_OUT=$(cat "$SANDBOX/limited.out")
}
ARITH_ERR='syntax error|invalid arithmetic|value too great|unbound variable|operand expected|bad substitution'

echo "scenario 34 (Ф76): a refusal says how often and for how long this class repeated, and how many tracked paths are dirty; no state file lands in the repository"
refusing_canon s34; H=$(git -C "$CANON" rev-parse HEAD)
out1=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?; out2=$(bash "$SCRIPT" "$CANON" main 2>&1)
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
assert "$(printf '%s' "$out1" | grep -c 'this reason 1 time(s) over 0 min; dirty tracked paths now: 0')" "1" "first refusal: 1 time, 0 min, 0 dirty"
assert "$(printf '%s' "$out2" | grep -c 'this reason 2 time(s) over 0 min')" "1" "second refusal of the same class: 2 times"
assert "$(alerts_in "$out2")" "0" "no ALERT below the defaults (3 times and 60 min)"
assert "$(ls -A "$CANON" | grep -c 'streak')" "0" "no state file inside the repository"
assert "$(git -C "$CANON" status --porcelain | wc -l | tr -d ' ')" "0" "the canon tree stays clean"

echo "scenario 35 (Ф76): the third refusal past both thresholds prints exactly one ALERT with count, class and dirty count; the fourth stays quiet; after the repeat interval it speaks again"
refusing_canon s35; rm -f "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.streak
LOUD="CANON_RECONCILE_ALERT_AFTER_SEC=0 CANON_RECONCILE_ALERT_MIN_COUNT=3 CANON_RECONCILE_ALERT_REPEAT_SEC=3600"
o1=$(env $LOUD bash "$SCRIPT" "$CANON" main 2>&1); o2=$(env $LOUD bash "$SCRIPT" "$CANON" main 2>&1); o3=$(env $LOUD bash "$SCRIPT" "$CANON" main 2>&1); o4=$(env $LOUD bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(alerts_in "$o1")$(alerts_in "$o2")$(alerts_in "$o3")$(alerts_in "$o4")" "0010" "ALERT only on the third refusal"
assert "$(printf '%s' "$o3" | grep -c "ALERT canon .* not reconciled for 0 min: 3 refusals 'local-only commits not on target', 0 dirty tracked path(s)")" "1" "the ALERT carries age, count, class and dirty count"
o5=$(env CANON_RECONCILE_ALERT_AFTER_SEC=0 CANON_RECONCILE_ALERT_MIN_COUNT=3 CANON_RECONCILE_ALERT_REPEAT_SEC=0 bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(alerts_in "$o5")" "1" "once the repeat interval has passed the ALERT comes again"

echo "scenario 36 (Ф76): the age threshold holds the alert back even when the count is reached"
refusing_canon s36; rm -f "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.streak
o1=$(CANON_RECONCILE_ALERT_MIN_COUNT=1 bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(alerts_in "$o1")" "0" "count reached, 60 minutes not -> no ALERT"

echo "scenario 37 (Ф76): a streak that began two hours ago alerts with the real age on the next refusal"
refusing_canon s37; rm -rf "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.streak*
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; f=$(streak_file)
put_journal "$f" "local-only commits not on target" $(( $(date -u +%s) - 7200 )) 5
o1=$(bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(alerts_in "$o1")" "1" "ALERT on the next refusal"
assert "$(printf '%s' "$o1" | grep -c 'not reconciled for 120 min: 6 refusals')" "1" "age 120 min, 6 refusals"

echo "scenario 38 (Ф76): a healthy run clears the streak, the next refusal counts from one"
fresh s38; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; republish_on_origin "$CANON" "$(git -C "$CANON" rev-parse HEAD)"
rm -f "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.streak
echo dirty >> "$CANON/a.txt"; bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; bash "$SCRIPT" "$CANON" main >/dev/null 2>&1
assert "$(streak_file | wc -l | tr -d ' ')" "1" "precondition: a streak exists"
git -C "$CANON" checkout -q -- a.txt
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "0" "exit 0 (replaced)"; assert "$(streak_file | wc -l | tr -d ' ')" "0" "the streak file is gone"
git -C "$CANON" fetch -q origin; echo two > "$CANON/c.txt"; commit_in "$CANON" "unique"
o1=$(bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(printf '%s' "$o1" | grep -c 'this reason 1 time(s)')" "1" "the next refusal counts from one"

echo "scenario 38b (Codex 7, J7/J11 residual): a healthy exit removes the journal only through a trusted chain, and says why when it does not"
fresh s38b; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; republish_on_origin "$CANON" "$(git -C "$CANON" rev-parse HEAD)"
mkdir -p "$SANDBOX/h38-rt" && chmod 755 "$SANDBOX/h38-rt"
echo dirty >> "$CANON/a.txt"; env IWE_RUNTIME_DIR="$SANDBOX/h38-rt" bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; HJ=$(ls "$SANDBOX/h38-rt"/canon-reconcile-published.*.streak | head -1)
git -C "$CANON" checkout -q -- a.txt; chmod 777 "$SANDBOX/h38-rt"
o1=$(env IWE_RUNTIME_DIR="$SANDBOX/h38-rt" bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$([ -f "$HJ" ] && echo kept || echo removed)" "0/kept" "healthy exit (replaced) with a runtime directory others can write to: the journal is NOT removed through the untrusted chain"
assert "$(printf '%s' "$o1" | grep -c 'is left in place on this healthy exit')" "1" "the warning says that the journal was left, and why"
chmod 755 "$SANDBOX/h38-rt"
env IWE_RUNTIME_DIR="$SANDBOX/h38-rt" bash "$SCRIPT" "$CANON" main >/dev/null 2>&1
assert "$([ -f "$HJ" ] && echo kept || echo removed)" "removed" "control: once the directory is private again the next healthy exit removes the journal"

echo "scenario 38c (Codex 7, J7/J11 residual): a healthy exit with a directory ABOVE the runtime directory that others can write to (no sticky bit) leaves the journal alone"
fresh s38c; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; republish_on_origin "$CANON" "$(git -C "$CANON" rev-parse HEAD)"
mkdir -p "$SANDBOX/h38c-up/rt" && chmod 755 "$SANDBOX/h38c-up" "$SANDBOX/h38c-up/rt"
echo dirty >> "$CANON/a.txt"; env IWE_RUNTIME_DIR="$SANDBOX/h38c-up/rt" bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; HJ=$(ls "$SANDBOX/h38c-up/rt"/canon-reconcile-published.*.streak | head -1)
git -C "$CANON" checkout -q -- a.txt; chmod 777 "$SANDBOX/h38c-up"
o1=$(env IWE_RUNTIME_DIR="$SANDBOX/h38c-up/rt" bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$([ -f "$HJ" ] && echo kept || echo removed)" "0/kept" "healthy exit with a directory above the runtime directory that others can write to: the journal is NOT removed"
assert "$(printf '%s' "$o1" | grep -c 'above the runtime directory can be changed by somebody else')" "1" "the warning names the directory above"
chmod 755 "$SANDBOX/h38c-up"
env IWE_RUNTIME_DIR="$SANDBOX/h38c-up/rt" bash "$SCRIPT" "$CANON" main >/dev/null 2>&1
assert "$([ -f "$HJ" ] && echo kept || echo removed)" "removed" "control: the same layout with a private directory above removes the journal"

echo "scenario 39 (Ф76): a refusal of another class starts a new streak"
fresh s39; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; republish_on_origin "$CANON" "$(git -C "$CANON" rev-parse HEAD)"
rm -f "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.streak
echo dirty >> "$CANON/a.txt"; bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; bash "$SCRIPT" "$CANON" main >/dev/null 2>&1
git -C "$CANON" checkout -q -- a.txt; echo two > "$CANON/c.txt"; commit_in "$CANON" "unique"
o1=$(bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(printf '%s' "$o1" | grep -c 'local-only commits not on target')" "1" "precondition: the class is now the unique-commit one"
assert "$(printf '%s' "$o1" | grep -c 'this reason 1 time(s)')" "1" "a new class counts from one"

echo "scenario 40 (Ф76): a damaged journal is a fresh streak: its damaged lines are skipped, never an error"
refusing_canon s40; rm -rf "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.streak*
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; f=$(streak_file); printf 'garbage without tabs\n' > "$f"
o1=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(printf '%s' "$o1" | grep -c 'this reason 1 time(s)')" "1" "counted from one"
assert "$(tail -1 "$f" | awk -F'\t' '{print NF ":" $1}')" "4:R" "the journal ends with the new four-field record"
printf 'local-only commits not on target\t12x\t3\t0\n' > "$f"   # the four-field state of the first draft of this change: not a journal record
o1=$(bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(printf '%s' "$o1" | grep -c 'this reason 1 time(s)')" "1" "a line that is not a journal record is skipped too"

echo "scenario 41 (Ф76): a non-numeric threshold override falls back to the default and does not break the refusal"
refusing_canon s41; rm -f "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.streak
o1=$(CANON_RECONCILE_ALERT_AFTER_SEC=abc CANON_RECONCILE_ALERT_MIN_COUNT=08 bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(printf '%s' "$o1" | grep -c 'this reason 1 time(s)')" "1" "refusal reported"
assert "$(printf '%s' "$o1" | grep -ci 'syntax error\|value too great\|invalid arithmetic')" "0" "no arithmetic error from 'abc' or '08'"

echo "scenario 42 (Ф76): two canons do not share a streak"
refusing_canon s42a; CA="$CANON"; refusing_canon s42b; CB="$CANON"; rm -f "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.streak
bash "$SCRIPT" "$CA" main >/dev/null 2>&1; bash "$SCRIPT" "$CA" main >/dev/null 2>&1; o1=$(bash "$SCRIPT" "$CB" main 2>&1)
assert "$(printf '%s' "$o1" | grep -c 'this reason 1 time(s)')" "1" "the second canon starts from one"
assert "$(ls "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.streak | wc -l | tr -d ' ')" "2" "one state file per canon"

echo "scenario 43 (Ф76): a lock-busy skip is neither a refusal nor a healthy run: the streak is untouched"
refusing_canon s43; rm -f "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.streak
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; f=$(streak_file); before=$(cat "$f")
GD=$(git -C "$CANON" rev-parse --absolute-git-dir)
mkdir "$GD/dirty-guard.lock" && printf 'node=%s\npid=%s\n' "${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}" "$$" > "$GD/dirty-guard.lock/owner"   # a live owner: this shell
o1=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
rm -rf "$GD/dirty-guard.lock"
assert "$(printf '%s' "$o1" | grep -c 'lock busy')" "1" "precondition: the run was skipped because of the lock"
assert "$rc" "0" "exit 0"; assert "$(cat "$f")" "$before" "the streak file is unchanged"


echo "scenario 44 (Codex 1): every damaged shape of a journal record is skipped, never an arithmetic error"
prime s44
for spec in "R|12.3|$CLASS_U|x" "R|-5|$CLASS_U|x" "R|1e3|$CLASS_U|x" "R|1234567890123|$CLASS_U|x" "R|0x10|$CLASS_U|x" "R| 5|$CLASS_U|x" "R||$CLASS_U|x" "R|5 |$CLASS_U|x" "A|12.3|$CLASS_U|x" "R|100||x" "r|100|$CLASS_U|x" "R|100"; do
  printf '%s\n' "$(printf '%s' "$spec" | tr '|' '\t')" > "$F"
  o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
  assert "$rc$(printf '%s' "$o" | grep -c 'this reason 1 time(s)')$(printf '%s' "$o" | grep -Eic "$ARITH_ERR")" "110" "[$spec] exit 1, counted from one, no arithmetic error"
done
printf 'R\t%s\t%s\tx\n' "00$((T - 7200))" "$CLASS_U" > "$F"   # twelve digits with leading zeros: a plain decimal number
o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(printf '%s' "$o" | grep -c 'this reason 2 time(s) over 120 min')" "1" "leading zeros are decimal (no octal error): 2 refusals over 120 min"

echo "scenario 45 (Codex 1): the real boundaries under a fixed clock: 3599/3600 s age, 14399/14400 s repeat, 2/3 refusals; the claim is on disk before the alert"
prime s45
chk() {  # <label> <want-alerts> <first> <count-before> [<claim-epoch>...]
  local label="$1" want="$2"; shift 2; put_journal "$F" "$CLASS_U" "$@"; o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1)
  assert "$(alerts_in "$o")" "$want" "$label"
}
chk "age 3599 s with the count reached: quiet" 0 $((T - 3599)) 2
chk "age 3600 s: ALERT" 1 $((T - 3600)) 2
assert "$(awk -F'\t' '$1=="A"{e=$2} END{print e}' "$F")" "$T" "the claim stamped now is in the journal"
chk "count 2 of 3 at a large age: quiet" 0 $((T - 9000)) 1
chk "count 3 of 3: ALERT" 1 $((T - 9000)) 2
chk "last alert 14399 s ago: quiet" 0 $((T - 20000)) 5 $((T - 14399))
chk "last alert 14400 s ago: ALERT" 1 $((T - 20000)) 5 $((T - 14400))
chk "a claim from the same second: quiet" 0 $((T - 20000)) 5 "$T"
put_journal "$F" "$CLASS_U" $((T - 20000)) 5 "$T" $((T - 100))   # Codex 5, J9: the delayed run claimed LATER in file order but with an EARLIER time
o=$(at $((T + 14399)) bash "$SCRIPT" "$CANON" main 2>&1); assert "$(alerts_in "$o")" "0" "J9: claims at T and (later in the file) T-100: 14399 s after T the alert interval has not passed: quiet"
put_journal "$F" "$CLASS_U" $((T - 20000)) 5 "$T" $((T - 100))
o=$(at $((T + 14400)) bash "$SCRIPT" "$CANON" main 2>&1); assert "$(alerts_in "$o")" "1" "J9: 14400 s after the LATEST claim the ALERT comes"

echo "scenario 46 (Codex 1): a clock set back neither breaks the arithmetic nor mutes the alert"
prime s46
put_journal "$F" "$CLASS_U" $((T + 5000)) 5
o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(printf '%s' "$o" | grep -c 'this reason 6 time(s) over 0 min')" "1" "46a: refusals stamped in the future count as now: 6 refusals, 0 min"
assert "$(printf '%s' "$o" | grep -Eic "$ARITH_ERR")" "0" "46a: no arithmetic error"; assert "$(alerts_in "$o")" "0" "46a: no alert at once: the age restarted"
put_journal "$F" "$CLASS_U" $((T - 7200)) 5 $((T + 9000))
o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(alerts_in "$o")" "1" "46b: a claim stamped far in the future does not mute the alert"
put_journal "$F" "$CLASS_U" $((T - 7200)) 5 $((T + 300))
o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(alerts_in "$o")" "0" "46c: a claim a few minutes ahead (a small step of the clock) counts as just made: quiet"

echo "scenario 47 (Codex 1): a journal that cannot be appended to gives a warning and no alert, however often the refusal repeats"
prime s47
if [ "$(id -u)" != "0" ]; then
  put_journal "$F" "$CLASS_U" $((T - 9000)) 5; chmod 444 "$F"; cp "$F" "$SANDBOX/s47.before"
  res=""; for i in 1 2 3; do
    o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
    res="$res$rc/$(alerts_in "$o")/$(printf '%s' "$o" | grep -c 'warning: cannot append to the refusal streak')/$(printf '%s' "$o" | grep -c 'streak state could not be saved') "
  done
  assert "$res" "1/0/1/1 1/0/1/1 1/0/1/1 " "three runs: exit 1, no ALERT, one warning, the refusal line says why"
  assert "$(cat "$F")" "$(cat "$SANDBOX/s47.before")" "the journal is untouched"
  chmod 644 "$F"; o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1)
  assert "$(alerts_in "$o")" "1" "precondition of the test: with a writable journal the same state raises the ALERT"
  put_journal "$F" "$CLASS_U" $((T - 9000)) 5; chmod 200 "$F"   # write-only: the record can be appended, nothing can be derived
  o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1); chmod 644 "$F"
  assert "$(alerts_in "$o")/$(printf '%s' "$o" | grep -c 'streak state could not be read')/$(printf '%s' "$o" | grep -c 'warning: cannot read the refusal streak')" "0/1/1" "an unreadable journal is reported, never counted silently from one; no alert"
  rm -f "$F"; chmod 555 "$IWE_RUNTIME_DIR"; o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1); chmod 755 "$IWE_RUNTIME_DIR"
  assert "$(alerts_in "$o")/$(printf '%s' "$o" | grep -c 'streak state could not be saved')" "0/1" "a journal that cannot even be created (read-only directory): no ALERT, reported"
fi

echo "scenario 48 (Codex 1): a journal path that is a symlink, a directory or a FIFO is neither read nor replaced; a world-writable runtime directory is not trusted"
prime s48; printf 'precious\n' > "$SANDBOX/victim.txt"
rm -f "$F"; ln -s "$SANDBOX/victim.txt" "$F"
o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "symlink: exit 1"; assert "$(cat "$SANDBOX/victim.txt")" "precious" "symlink: the file it points to is not written"
assert "$([ -L "$F" ] && echo link)" "link" "symlink: still a symlink"
assert "$(printf '%s' "$o" | grep -c 'is not a plain file of this user')" "1" "symlink: the refusal line says the state is unusable"
assert "$(alerts_in "$(env CANON_RECONCILE_ALERT_AFTER_SEC=0 CANON_RECONCILE_ALERT_MIN_COUNT=1 PATH="$FAKEBIN:$PATH" FAKE_NOW=$T bash "$SCRIPT" "$CANON" main 2>&1)")" "0" "symlink: no ALERT even with the thresholds at zero"
rm -f "$F"; mkdir "$F"
o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc$([ -d "$F" ] && echo dir)$(printf '%s' "$o" | grep -c 'is not a plain file of this user')" "1dir1" "directory: exit 1, left in place, reported"
rmdir "$F"
if command -v mkfifo >/dev/null 2>&1; then
  mkfifo "$F"; run_limited 8 env PATH="$FAKEBIN:$PATH" FAKE_NOW="$T" bash "$SCRIPT" "$CANON" main
  assert "$LIMITED_RC$([ -p "$F" ] && echo fifo)" "1fifo" "FIFO: exit 1 (124 would mean the read blocked), left in place"
  rm -f "$F"
fi
put_journal "$F" "$CLASS_U" $((T - 9000)) 5; cp "$F" "$SANDBOX/s48.before"
for mode in 777 775 770 757; do
  chmod "$mode" "$IWE_RUNTIME_DIR"; o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1); chmod 755 "$IWE_RUNTIME_DIR"
  assert "$(printf '%s' "$o" | grep -c 'not a private directory of this user')/$(alerts_in "$o")/$(cmp -s "$F" "$SANDBOX/s48.before" && echo same)" "1/0/same" "runtime directory mode $mode (a group or others may write): not trusted, reported, no ALERT, journal untouched"
done
o=$(at "$T" env FAIL_LS=1 bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(printf '%s' "$o" | grep -c 'not a private directory of this user')/$(alerts_in "$o")/$(cmp -s "$F" "$SANDBOX/s48.before" && echo same)" "1/0/same" "a permission string that cannot be read is no trust either"
o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(alerts_in "$o")" "1" "control: the owner-only mode 755 is trusted and the same journal raises the ALERT"
mkdir "$SANDBOX/rt-open" && chmod 777 "$SANDBOX/rt-open" && ln -s "$SANDBOX/rt-open" "$SANDBOX/rt-link"
o=$(env IWE_RUNTIME_DIR="$SANDBOX/rt-link" PATH="$FAKEBIN:$PATH" FAKE_NOW="$T" bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(printf '%s' "$o" | grep -c 'not a private directory of this user')/$(alerts_in "$o")" "1/0" "a runtime directory that is a SYMLINK to a world-writable directory is judged by its target: not trusted, reported, no ALERT"
for fmode in 666 664 622 620; do
  put_journal "$F" "$CLASS_U" $((T - 9000)) 5; chmod "$fmode" "$F"; cp "$F" "$SANDBOX/s48.file.before"
  o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1)
  assert "$(printf '%s' "$o" | grep -c 'without write for group or others')/$(alerts_in "$o")/$(cmp -s "$F" "$SANDBOX/s48.file.before" && echo same)" "1/0/same" "journal file mode $fmode inside a private directory: not trusted, reported, no ALERT, journal untouched"
done
for fmode in 600 644; do
  put_journal "$F" "$CLASS_U" $((T - 9000)) 5; chmod "$fmode" "$F"
  o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1)
  assert "$(alerts_in "$o")" "1" "control: journal file mode $fmode (nobody else can write) is trusted and raises the ALERT"
done
ANC="$SANDBOX/anc"; mkdir -p "$ANC/rt"; chmod 755 "$ANC" "$ANC/rt"
env IWE_RUNTIME_DIR="$ANC/rt" bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; F2=$(ls "$ANC/rt"/canon-reconcile-published.*.streak | head -1)
run2() { env IWE_RUNTIME_DIR="$ANC/rt" PATH="$FAKEBIN:$PATH" FAKE_NOW="$T" bash "$SCRIPT" "$CANON" main 2>&1; }
put_journal "$F2" "$CLASS_U" $((T - 9000)) 5; o=$(run2)
assert "$(alerts_in "$o")" "1" "control: the directory above the runtime directory is 755: trusted, the ALERT is raised"
put_journal "$F2" "$CLASS_U" $((T - 9000)) 5; chmod 777 "$ANC"; o=$(run2); chmod 755 "$ANC"
assert "$(printf '%s' "$o" | grep -c 'above the runtime directory can be changed by somebody else')/$(alerts_in "$o")" "1/0" "a directory ABOVE the runtime directory that others may write to (777, not sticky): not trusted, reported, no ALERT"
put_journal "$F2" "$CLASS_U" $((T - 9000)) 5; chmod 1777 "$ANC"; o=$(run2); chmod 755 "$ANC"
assert "$(alerts_in "$o")" "1" "the same directory made sticky (like /tmp): others cannot touch our entries there, trusted"
mkdir -p "$SANDBOX/real-top/sub/rt" && chmod 755 "$SANDBOX/real-top/sub" "$SANDBOX/real-top/sub/rt" && chmod 777 "$SANDBOX/real-top" && ln -s "$SANDBOX/real-top/sub" "$SANDBOX/link-top"
o=$(env IWE_RUNTIME_DIR="$SANDBOX/link-top/rt" PATH="$FAKEBIN:$PATH" FAKE_NOW="$T" bash "$SCRIPT" "$CANON" main 2>&1); chmod 755 "$SANDBOX/real-top"
assert "$(printf '%s' "$o" | grep -c 'above the runtime directory can be changed by somebody else')" "1" "the runtime directory is reached through a symlink to real-top/sub whose PARENT real-top is 777: the walk follows the physical path and does not trust it"
# Codex 5, J7: the journal is written to the physical path that was CHECKED, even if a link in the logical path is re-pointed after the check
mkdir -p "$SANDBOX/safe/rt" "$SANDBOX/evil/rt" && chmod 755 "$SANDBOX/safe" "$SANDBOX/safe/rt" "$SANDBOX/evil" "$SANDBOX/evil/rt" && ln -sfn "$SANDBOX/safe/rt" "$SANDBOX/swaplink"
sed 's@^  reason=$(oneline "\$1")$@  ln -sfn "'"$SANDBOX"'/evil/rt" "'"$SANDBOX"'/swaplink"; reason=$(oneline "$1")   # injected: the link is re-pointed after the runtime directory was resolved and before the report writes@' "$SCRIPT" > "$SANDBOX/script-swap.sh"
assert "$(grep -c 'injected: the link is re-pointed' "$SANDBOX/script-swap.sh")" "1" "precondition: the re-pointing of the link is injected into the copy"
o=$(env IWE_RUNTIME_DIR="$SANDBOX/swaplink" PATH="$FAKEBIN:$PATH" FAKE_NOW="$T" bash "$SANDBOX/script-swap.sh" "$CANON" main 2>&1)
assert "$(ls "$SANDBOX/safe/rt" | grep -c 'canon-reconcile-published.*streak')/$(ls "$SANDBOX/evil/rt" | grep -c 'canon-reconcile-published')" "1/0" "the journal and the log went into the CHECKED physical directory; nothing reached the directory the link was re-pointed to"
# Codex 5, J8: an ACL on a directory above is trusted only if it can only deny (macOS: the default of home directories)
if [ "$(uname -s)" = Darwin ]; then
  mkdir -p "$ANC/acl-dir/rt" && chmod 755 "$ANC/acl-dir" "$ANC/acl-dir/rt"; run3() { env IWE_RUNTIME_DIR="$ANC/acl-dir/rt" PATH="$FAKEBIN:$PATH" FAKE_NOW="$T" bash "$SCRIPT" "$CANON" main 2>&1; }
  run3 >/dev/null; F3=$(ls "$ANC/acl-dir/rt"/canon-reconcile-published.*.streak | head -1)
  chmod +a "group:everyone deny delete" "$ANC/acl-dir"; put_journal "$F3" "$CLASS_U" $((T - 9000)) 5; o=$(run3)
  assert "$(alerts_in "$o")" "1" "an ACL with a deny entry only on a directory above (the macOS home default) is trusted: the ALERT is raised"
  chmod +a "user:nobody allow add_file,delete_child" "$ANC/acl-dir"; put_journal "$F3" "$CLASS_U" $((T - 9000)) 5; o=$(run3)
  assert "$(printf '%s' "$o" | grep -c 'above the runtime directory can be changed by somebody else')/$(alerts_in "$o")" "1/0" "an ACL that ALLOWS somebody to add files or delete children of a directory above: not trusted, reported, no ALERT"
  chmod -N "$ANC/acl-dir"
  mkdir -p "$ANC/acl-rt/rt" && chmod 755 "$ANC/acl-rt" "$ANC/acl-rt/rt"; run4() { env IWE_RUNTIME_DIR="$ANC/acl-rt/rt" PATH="$FAKEBIN:$PATH" FAKE_NOW="$T" bash "$SCRIPT" "$CANON" main 2>&1; }
  run4 >/dev/null; F4=$(ls "$ANC/acl-rt/rt"/canon-reconcile-published.*.streak | head -1)
  chmod +a "group:everyone deny delete" "$ANC/acl-rt/rt"; put_journal "$F4" "$CLASS_U" $((T - 9000)) 5; o=$(run4)
  assert "$(printf '%s' "$o" | grep -c 'not a private directory of this user')/$(alerts_in "$o")" "1/0" "the runtime directory itself with ANY ACL entry (even a deny one): not trusted (strict), reported, no ALERT"
  chmod -N "$ANC/acl-rt/rt"
fi
# Codex 6, J11: with an untrusted directory chain nothing is written to the log either (a planted link would redirect the line), and a FIFO in its place does not hang
mkdir -p "$SANDBOX/open-rt" && chmod 777 "$SANDBOX/open-rt"; printf 'victim\n' > "$SANDBOX/victim-log.txt"; ln -s "$SANDBOX/victim-log.txt" "$SANDBOX/open-rt/canon-reconcile-published.log"
o=$(env IWE_RUNTIME_DIR="$SANDBOX/open-rt" PATH="$FAKEBIN:$PATH" FAKE_NOW="$T" bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(cat "$SANDBOX/victim-log.txt")/$(printf '%s' "$o" | grep -c 'not a private directory of this user')" "victim/1" "runtime directory 777 with a planted link as the log: the file behind the link is NOT written, the reason is on stderr"
rm -f "$SANDBOX/open-rt/canon-reconcile-published.log"; mkfifo "$SANDBOX/open-rt/canon-reconcile-published.log"
run_limited 8 env IWE_RUNTIME_DIR="$SANDBOX/open-rt" PATH="$FAKEBIN:$PATH" FAKE_NOW="$T" bash "$SCRIPT" "$CANON" main
assert "$LIMITED_RC" "1" "a FIFO in place of the log in an untrusted directory: no hang (124 would mean the open blocked), exit 1"
mkdir -p "$SANDBOX/priv-rt" && chmod 755 "$SANDBOX/priv-rt"; ln -s "$SANDBOX/victim-log.txt" "$SANDBOX/priv-rt/canon-reconcile-published.log"
o=$(env IWE_RUNTIME_DIR="$SANDBOX/priv-rt" PATH="$FAKEBIN:$PATH" FAKE_NOW="$T" bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(cat "$SANDBOX/victim-log.txt")" "victim" "a private directory but a LINK in place of the log file: not followed, the file behind it is not written"
if [ "$(uname -s)" = Darwin ]; then
  put_journal "$F" "$CLASS_U" $((T - 9000)) 5; cp "$F" "$SANDBOX/s48.acl.before"
  o=$(at "$T" env FAIL_LS_E=1 bash "$SCRIPT" "$CANON" main 2>&1)
  assert "$(printf '%s' "$o" | grep -c 'not a private directory of this user')/$(alerts_in "$o")/$(cmp -s "$F" "$SANDBOX/s48.acl.before" && echo same)" "1/0/same" "Codex 6, J12: only the ACL listing (ls -e) fails: that is no 'no ACL', the directory is not trusted, no ALERT, journal untouched"
fi
if [ "$(id -u)" != "0" ] && [ -d /usr/bin ]; then
  o=$(env IWE_RUNTIME_DIR=/usr/bin PATH="$FAKEBIN:$PATH" FAKE_NOW="$T" bash "$SCRIPT" "$CANON" main 2>&1)
  assert "$(printf '%s' "$o" | grep -c 'not a private directory of this user')/$(alerts_in "$o")" "1/0" "a runtime directory owned by somebody else (/usr/bin: no write for us, mode 755): not trusted by OWNERSHIP, reported, no ALERT"
fi

echo "scenario 49 (Codex 1): ten parallel early refusals (before the repository lock) lose no count and raise exactly one alert"
fresh s49; rm -rf "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.streak*
bash "$SCRIPT" "$CANON" other >/dev/null 2>&1; F=$(streak_file)
assert "$(awk -F'\t' '{print $3}' "$F" | grep -c 'checked-out branch')" "1" "precondition: an early refusal (wrong branch name) made the journal"
put_journal "$F" "$(awk -F'\t' '{print $3}' "$F" | head -1)" $(( $(date -u +%s) - 7200 )) 5
for i in 1 2 3 4 5 6 7 8 9 10; do ( bash "$SCRIPT" "$CANON" other > "$SANDBOX/par-$i.out" 2>&1 ) & done; wait
total=0; for i in 1 2 3 4 5 6 7 8 9 10; do total=$((total + $(alerts_in "$(cat "$SANDBOX/par-$i.out")"))); done
assert "$total" "1" "exactly one ALERT among the ten runs"
assert "$(records "$F" R)" "15" "no refusal lost: 5 + 10 records"
assert "$(cat "$SANDBOX"/par-*.out | grep -c 'warning')" "0" "nobody had to give up"

echo "scenario 50 (Codex 1): of several claims the first in file order prints the alert; a claim that cannot be written or found prints none"
prime s50
put_journal "$F" "$CLASS_U" $((T - 9000)) 5
sed 's/^        id="\$\$.\$RANDOM"$/        printf "A\\t%s\\t%s\\tforeign\\n" "$now" "$class" >> "$STREAK_FILE"; id="$$.$RANDOM"   # injected: another run claims first/' "$SCRIPT" > "$SANDBOX/script-claim-first.sh"
assert "$(grep -c 'injected: another run claims first' "$SANDBOX/script-claim-first.sh")" "1" "precondition: the foreign claim is injected into the copy"
o=$(at "$T" bash "$SANDBOX/script-claim-first.sh" "$CANON" main 2>&1)
assert "$(alerts_in "$o")/$(records "$F" A)" "0/2" "50a: another claim landed first: no alert here, two claims in the journal"
put_journal "$F" "$CLASS_U" $((T - 9000)) 5
o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(alerts_in "$o")/$(records "$F" A)" "1/1" "50a control: without the foreign claim the same journal gives the ALERT and one claim"
put_journal "$F" "$CLASS_U" $((T - 9000)) 5; cp "$F" "$SANDBOX/s50b.seed"
sed 's@^        elif append_streak A "\$c_now" "\$class" "\$id"; then$@        elif append_streak A "$c_now" "$class" "$id"; then cp "'"$SANDBOX"'/s50b.seed" "$STREAK_FILE"   # injected: the journal is restored without our claim (a healthy run and an equally old streak)@' "$SCRIPT" > "$SANDBOX/script-claim-lost.sh"
assert "$(grep -c 'injected: the journal is restored without our claim' "$SANDBOX/script-claim-lost.sh")" "1" "precondition: the restoring of the journal without our claim is injected into the copy"
o=$(at "$T" bash "$SANDBOX/script-claim-lost.sh" "$CANON" main 2>&1)
assert "$(alerts_in "$o")" "0" "50b: the claim is not in the journal after the re-read although the series still looks due: inconclusive, no alert"
put_journal "$F" "$CLASS_U" $((T - 9000)) 5
sed 's/^        id="\$\$.\$RANDOM"$/        printf "R\\t%s\\t%s\\tz\\n" "$now" "another class" >> "$STREAK_FILE"; id="$$.$RANDOM"   # injected: another class begins before the claim/' "$SCRIPT" > "$SANDBOX/script-class-changed.sh"
assert "$(grep -c 'injected: another class begins' "$SANDBOX/script-class-changed.sh")" "1" "precondition: a refusal of another class is injected between the decision and the claim"
o=$(at "$T" bash "$SANDBOX/script-class-changed.sh" "$CANON" main 2>&1)
assert "$(alerts_in "$o")" "0" "50d: another class began between the decision and the claim: the series is over, the claim is not confirmed, no alert"
assert "$(printf '%s' "$o" | grep -c 'this reason 6 time(s) over 150 min')" "1" "50d: the refusal line keeps the numbers of the first reading (6 refusals, 150 min), not the empty state of the claim time"
if [ "$(id -u)" != "0" ]; then
  put_journal "$F" "$CLASS_U" $((T - 9000)) 5
  sed 's/^        id="\$\$.\$RANDOM"$/        chmod 444 "$STREAK_FILE"; id="$$.$RANDOM"   # injected: the journal turns read-only after the refusal was recorded/' "$SCRIPT" > "$SANDBOX/script-claim-unwritable.sh"
  o=$(at "$T" bash "$SANDBOX/script-claim-unwritable.sh" "$CANON" main 2>&1)
  assert "$(alerts_in "$o")/$(printf '%s' "$o" | grep -c 'cannot append the alert claim')" "0/1" "50c: the claim could not be written: no alert, a warning"
  chmod 644 "$F"
fi

echo "scenario 50e (Codex 4, J5): a claim of another class between two refusals does not split the series"
prime s50e
put_journal "$F" "$CLASS_U" $((T - 9000)) 2
printf 'A\t%s\t%s\tforeign.rejected\n' $((T - 100)) "another class" >> "$F"
o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(printf '%s' "$o" | grep -c 'this reason 3 time(s) over 150 min')/$(alerts_in "$o")" "1/1" "2 refusals, a claim of ANOTHER class, 1 more refusal: one series of 3 over 150 min, the ALERT is raised"
assert "$(awk -F'\t' '$1=="A" && $4 !~ /foreign/ {print $4}' "$F" | awk -F. '{print NF}')" "3" "the id of our claim carries the pid, a random number and the second the run started"

echo "scenario 50f (Codex 6, J10): a run whose clock reading is stale (it stalled for 601+ s) must not ignore the claim a faster run wrote meanwhile"
prime s50f
put_journal "$F" "$CLASS_U" $((T - 9000)) 5; printf '%s\n' "$T" > "$SANDBOX/clock.file"
sed 's@^        id="\$\$.\$RANDOM"$@        printf "A\\t%s\\t%s\\tq.first\\n" 2000000601 "$class" >> "$STREAK_FILE"; printf "%s\\n" 2000000700 > "'"$SANDBOX"'/clock.file"; id="$$.$RANDOM"   # injected: a faster run claimed at its time T+601 and our clock has moved on to T+700@' "$SCRIPT" > "$SANDBOX/script-stale-clock.sh"
assert "$(grep -c 'injected: a faster run claimed' "$SANDBOX/script-stale-clock.sh")" "1" "precondition: the faster run and the clock movement are injected into the copy"
o=$(env PATH="$FAKEBIN:$PATH" FAKE_NOW_FILE="$SANDBOX/clock.file" bash "$SANDBOX/script-stale-clock.sh" "$CANON" main 2>&1)
assert "$(alerts_in "$o")/$(records "$F" A)" "0/2" "50f: the faster run's claim (601 s ahead of the stale reading) is not discarded as 'the far future': no second alert, two claims in the journal"

echo "scenario 50g (Codex 7, J10 residual): a run that stalls between writing its claim and reading it back does not print a late alert"
prime s50g
put_journal "$F" "$CLASS_U" $((T - 20000)) 5; printf '%s\n' "$T" > "$SANDBOX/clock.file"
sed 's@^          claim_at=\$c_now$@          claim_at=$c_now; printf "A\\t%s\\t%s\\tq.later\\n" 2000014400 "$class" >> "$STREAK_FILE"; printf "%s\\n" 2000014401 > "'"$SANDBOX"'/clock.file"   # injected: the run stalls 14401 s after its claim; another run claimed at T+14400 and printed@' "$SCRIPT" > "$SANDBOX/script-stalled.sh"
assert "$(grep -c 'injected: the run stalls' "$SANDBOX/script-stalled.sh")" "1" "precondition: the stall and the later claim are injected into the copy"
o=$(env PATH="$FAKEBIN:$PATH" FAKE_NOW_FILE="$SANDBOX/clock.file" bash "$SANDBOX/script-stalled.sh" "$CANON" main 2>&1)
assert "$(alerts_in "$o")/$(printf '%s' "$o" | grep -c 'read back more than 120 s after')" "0/1" "the claim was read back 14401 s late: no alert (the later run owns the next window), a warning says why"

echo "scenario 50h (cold review): a refusal of another class recorded right after ours is no unreadable journal"
prime s50h
put_journal "$F" "$CLASS_U" $((T - 9000)) 5
sed 's/^    read -r _ s_first s_count s_last <<</    printf "R\\t%s\\t%s\\tz\\n" "$now" "another class" >> "$STREAK_FILE"; read -r _ s_first s_count s_last <<</' "$SCRIPT" > "$SANDBOX/script-class-after-ours.sh"
assert "$(grep -c 'another class" >> "$STREAK_FILE"; read -r _ s_first' "$SANDBOX/script-class-after-ours.sh")" "1" "precondition: a refusal of another class is injected right after our own record"
o=$(at "$T" bash "$SANDBOX/script-class-after-ours.sh" "$CANON" main 2>&1); rc=$?
assert "$rc/$(alerts_in "$o")/$(printf '%s' "$o" | grep -c 'cannot read the refusal streak')/$(printf '%s' "$o" | grep -c 'a refusal of another class was recorded in between, counted from one')" "1/0/0/1" "exit 1, no alert, no false warning about an unreadable journal, the refusal says what happened"

echo "scenario 50i (Codex 8, J10 residual): the interval is judged by the time of the claim, not by the time of the re-read"
# A run read the journal before another run claimed, then stalled before its own clock reading: its claim is stamped T+14399 and
# it re-reads one second later. The earlier claim is stamped T; between the two claims 14399 s lie, less than the interval.
prime s50i
put_journal "$F" "$CLASS_U" $((T - 9000)) 5; printf '%s\n' "$T" > "$SANDBOX/clock.file"
sed 's@^        id="\$\$.\$RANDOM"$@        printf "A\\t%s\\t%s\\tq.first\\n" 2000000000 "$class" >> "$STREAK_FILE"; printf "%s\\n" 2000014399 > "'"$SANDBOX"'/clock.file"; id="$$.$RANDOM"   # injected: another run claimed at T and our clock reads T+14399@' "$SCRIPT" > "$SANDBOX/script-late-claim-1.sh"
sed 's@^          claim_at=\$c_now$@          claim_at=$c_now; printf "%s\\n" 2000014400 > "'"$SANDBOX"'/clock.file"   # injected: one second passes after the claim@' "$SANDBOX/script-late-claim-1.sh" > "$SANDBOX/script-late-claim.sh"
assert "$(grep -c 'injected: another run claimed at T' "$SANDBOX/script-late-claim.sh")/$(grep -c 'injected: one second passes' "$SANDBOX/script-late-claim.sh")" "1/1" "precondition: both injections are in the copy"
o=$(env PATH="$FAKEBIN:$PATH" FAKE_NOW_FILE="$SANDBOX/clock.file" bash "$SANDBOX/script-late-claim.sh" "$CANON" main 2>&1)
assert "$(alerts_in "$o")/$(records "$F" A)" "0/2" "our claim stamped T+14399 is 14399 s after the earlier claim (T): no alert, although the re-read came at T+14400"
put_journal "$F" "$CLASS_U" $((T - 9000)) 5; printf '%s\n' "$T" > "$SANDBOX/clock.file"
sed 's@^        id="\$\$.\$RANDOM"$@        printf "A\\t%s\\t%s\\tq.first\\n" 2000000000 "$class" >> "$STREAK_FILE"; printf "%s\\n" 2000014400 > "'"$SANDBOX"'/clock.file"; id="$$.$RANDOM"   # injected: another run claimed at T and our clock reads T+14400@' "$SCRIPT" > "$SANDBOX/script-late-claim-c.sh"
o=$(env PATH="$FAKEBIN:$PATH" FAKE_NOW_FILE="$SANDBOX/clock.file" bash "$SANDBOX/script-late-claim-c.sh" "$CANON" main 2>&1)
assert "$(alerts_in "$o")/$(records "$F" A)" "1/2" "control: a claim stamped exactly T+14400 (the interval after the earlier claim) is confirmed and prints"

echo "scenario 51 (Codex 1, found while checking scenario 44 on the round-1 code): a refusal whose own report dies halfway must still stop before the swap"
# A failed arithmetic expansion discards the whole top-level command, refuse() and its exit 1 included, and the script goes on.
# The fault is injected into a copy; the control copy has no tripwire and shows the hazard is real (it resets the canon).
refusing_canon s51; H=$(git -C "$CANON" rev-parse HEAD)
sed 's/^  REFUSAL_STARTED=1$/  REFUSAL_STARTED=1; : $((10#1.5))   # injected fault/' "$SCRIPT" > "$SANDBOX/script-abort.sh"
assert "$(grep -c 'injected fault' "$SANDBOX/script-abort.sh")" "1" "precondition: the fault is injected into the copy"
o=$(bash "$SANDBOX/script-abort.sh" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged: the canon was not reset"
assert "$(printf '%s' "$o" | grep -Eic 'syntax error|invalid arithmetic')" "1" "the injected fault really fired"
assert "$(printf '%s' "$o" | grep -c 'report was cut short')" "1" "the tripwire says why it stopped"
refusing_canon s51c; H=$(git -C "$CANON" rev-parse HEAD)
grep -v 'tripwire, see refuse()' "$SANDBOX/script-abort.sh" > "$SANDBOX/script-abort-notrip.sh"
o=$(bash "$SANDBOX/script-abort-notrip.sh" "$CANON" main 2>&1); rc=$?
assert "$([ "$(git -C "$CANON" rev-parse HEAD)" != "$H" ] && echo moved || echo same)" "moved" "control: without the tripwire the same fault lets the canon be reset over the unique local commit"

echo "scenario 52 (Codex 2): a LOST swap whose report also dies must not reach the reset (it would discard tolerated dirt under an unchanged HEAD)"
sed 's/^  REFUSAL_STARTED=1$/  REFUSAL_STARTED=1; : $((10#1.5))   # injected fault/' "$SCRIPT" > "$SANDBOX/script-abort-52.sh"   # self-contained: the same injection as in scenario 51
assert "$(grep -c 'injected fault' "$SANDBOX/script-abort-52.sh")" "1" "precondition: the fault is injected into the copy"
fresh s52; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-s52"; git clone -q "$ORIGIN" "$pub"; echo fixed > "$pub/a.txt"; commit_in "$pub" "origin fixes a"; git -C "$pub" push -q origin main
echo fixed > "$CANON/a.txt"; H=$(git -C "$CANON" rev-parse HEAD)   # tolerated dirt: the published bytes; a reset to the OLD head would turn it back into "base"
o=$(at "$T" env FAIL_UPDATE_REF=1 bash "$SANDBOX/script-abort-52.sh" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"; assert "$(cat "$CANON/a.txt")" "fixed" "the tolerated dirt is intact: no reset ran"
assert "$(printf '%s' "$o" | grep -Eic 'syntax error|invalid arithmetic')" "1" "the injected fault really fired in the refusal of the lost swap"
fresh s52c; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-s52c"; git clone -q "$ORIGIN" "$pub"; echo fixed > "$pub/a.txt"; commit_in "$pub" "origin fixes a"; git -C "$pub" push -q origin main
echo fixed > "$CANON/a.txt"
grep -v 'a SEPARATE top-level command' "$SANDBOX/script-abort-52.sh" > "$SANDBOX/script-abort-nocas.sh"
o=$(at "$T" env FAIL_UPDATE_REF=1 bash "$SANDBOX/script-abort-nocas.sh" "$CANON" main 2>&1); rc=$?
assert "$(cat "$CANON/a.txt")" "base" "control: without the re-check the reset runs after the lost swap and turns the tolerated dirt back into the old bytes"


echo "scenario 53 (Codex 4, J4): a big journal is neither cut nor capped: a new class after a long old one is recorded and can alert"
prime s53
awk -v t="$T" 'BEGIN { for (i = 0; i < 12000; i++) printf "R\t%d\tsome other class\tseed.%d.padpadpadpadpadpadpadpadpadpadpadpadpadpadpadpad\n", t - 9000 + (i % 100), i }' > "$F"
for i in 0 1 2 3 4; do printf 'R\t%d\t%s\tseed.u.%d\n' $((T - 9000 + i)) "$CLASS_U" "$i" >> "$F"; done
assert "$([ "$(wc -c < "$F" | tr -d ' ')" -gt 1048576 ] && echo big)" "big" "precondition: the journal is larger than 1 MiB and ends with five refusals of the class the script refuses with"
inode_before=$(ls -i "$F" | awk '{print $1}'); lines_before=$(wc -l < "$F" | tr -d ' ')
o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(wc -l < "$F" | tr -d ' ')" "$((lines_before + 2))" "the refusal AND the alert claim were appended (nothing skipped, nothing cut)"
assert "$(printf '%s' "$o" | grep -c 'this reason 6 time(s)')/$(alerts_in "$o")/$(ls -i "$F" | awk '{print $1}')" "1/1/$inode_before" "the new class counts from its own records (6), the ALERT is raised, the file is the same inode"
assert "$(ls "$IWE_RUNTIME_DIR" | grep -c '\.rot\.\|\.tmp\.')" "0" "no temp file exists"

echo "scenario 51d (Codex 2 / cold review): the whole report runs in a subshell: a fault inside it ends only the report, the refusal still stops the script and says so"
refusing_canon s51d; H=$(git -C "$CANON" rev-parse HEAD)
sed 's/^  class="${reason%%:\*}"; class="${class:0:120}"$/&; : $((10#1.5))   # injected fault in the report/' "$SCRIPT" > "$SANDBOX/script-report-fault.sh"
assert "$(grep -c 'injected fault in the report' "$SANDBOX/script-report-fault.sh")" "1" "precondition: the fault is injected into the report of the copy"
o=$(bash "$SANDBOX/script-report-fault.sh" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
assert "$(printf '%s' "$o" | grep -c 'the report of this refusal failed')/$(printf '%s' "$o" | grep -c 'report was cut short')" "1/0" "the parent says the report failed; the tripwire was not even needed"
refusing_canon s51e; H=$(git -C "$CANON" rev-parse HEAD)
sed 's/^  ( refuse_report "\$1" ) ||/  refuse_report "$1" ||/' "$SANDBOX/script-report-fault.sh" > "$SANDBOX/script-report-fault-nosub.sh"
assert "$(grep -c '^  refuse_report "\$1" ||' "$SANDBOX/script-report-fault-nosub.sh")" "1" "precondition: the subshell is removed from the copy"
o=$(bash "$SANDBOX/script-report-fault-nosub.sh" "$CANON" main 2>&1); rc=$?
assert "$(printf '%s' "$o" | grep -c 'report was cut short')" "1" "control: without the subshell the same fault drops the refusal and only the tripwire at the ref swap stops the run"

echo "scenario 54 (cold review): a path name with a newline cannot forge an ALERT line in the output the forwarder reads"
name=$'notes\ncanon-reconcile-published: ALERT canon FORGED x'
fresh s54; printf 'v1\n' > "$CANON/$name"; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; republish_on_origin "$CANON" "$(git -C "$CANON" rev-parse HEAD)"
echo mine >> "$CANON/$name"
o=$(bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(printf '%s' "$o" | grep -c 'tracked changes differ from target: notes canon-reconcile-published: ALERT canon FORGED x')" "1" "precondition: the refusal names the path, on one line"
assert "$(printf '%s\n' "$o" | sed 's/^/isolate-push: /' | grep -c '^isolate-push: canon-reconcile-published: ALERT')" "0" "no line of the output (after the isolate-push prefix) is an ALERT"
assert "$(grep -c 'FORGED' "$IWE_RUNTIME_DIR/canon-reconcile-published.log" | tr -d ' ')" "$(grep 'FORGED' "$IWE_RUNTIME_DIR/canon-reconcile-published.log" | wc -l | tr -d ' ')" "the log keeps the same text on one line each"
assert "$(grep -c '^canon-reconcile-published: ALERT\|^[0-9TZ:-]* alert ' "$IWE_RUNTIME_DIR/canon-reconcile-published.log" | tr -d ' ')" "$(grep -c ' alert repo=' "$IWE_RUNTIME_DIR/canon-reconcile-published.log" | tr -d ' ')" "no forged ALERT line in the log either"

echo "scenario 55 (cold review): an oversized threshold override falls back to the default instead of wrapping around"
prime s55; put_journal "$F" "$CLASS_U" $((T - 9000)) 5
o=$(at "$T" env CANON_RECONCILE_ALERT_REPEAT_SEC=9223372036854775808 bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(alerts_in "$o")/$(printf '%s' "$o" | grep -c 'next alert in 240 min')" "1/1" "REPEAT_SEC with 19 digits: the default 14400 s is used (next alert in 240 min)"
put_journal "$F" "$CLASS_U" $((T - 9000)) 5
o=$(at "$T" env CANON_RECONCILE_ALERT_AFTER_SEC=0123456789012345 CANON_RECONCILE_ALERT_MIN_COUNT=99999999999999 bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(alerts_in "$o")" "1" "AFTER_SEC and MIN_COUNT with more than 12 digits: the defaults (3600 s, 3 refusals) are used"

echo "scenario 56 (cold review): a clock that cannot be read writes nothing to the journal; a zero-padded time is decimal"
prime s56; put_journal "$F" "$CLASS_U" $((T - 9000)) 5; cp "$F" "$SANDBOX/s56.before"
o=$(env PATH="$FAKEBIN:$PATH" FAKE_DATE_BROKEN=1 bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -c 'streak state skipped: the clock could not be read')/$(alerts_in "$o")/$(cmp -s "$F" "$SANDBOX/s56.before" && echo same)" "1/1/0/same" "exit 1, the refusal says why nothing was counted, no alert, journal untouched"
put_journal "$F" "$CLASS_U" 1799990000 2
o=$(at "01800000009" bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -Eic "$ARITH_ERR")/$(printf '%s' "$o" | grep -c 'this reason 3 time(s) over 166 min')" "1/0/1" "FAKE time 01800000009 (a leading zero and a 9: octal would be an error): no arithmetic error, taken as decimal: 3 refusals over 166 min"

echo "scenario 57 (cold review): a refusal class carries no variable data: two different bogus pinned oids are one streak"
refusing_canon s57; rm -rf "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.streak*
o1=$(bash "$SCRIPT" "$CANON" main deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 2>&1); o2=$(bash "$SCRIPT" "$CANON" main cafebabecafebabecafebabecafebabecafebabe 2>&1)
assert "$(printf '%s' "$o1" | grep -c 'refused -- pinned oid is not a commit here: deadbeef')" "1" "the first refusal names the bogus oid after the colon"
assert "$(printf '%s' "$o2" | grep -c 'this reason 2 time(s)')" "1" "the second refusal, with another oid, continues the same streak: 2 times"

echo "scenario 58 (cold review): nothing is created below a directory that others can write to"
refusing_canon s58
mkdir -p "$SANDBOX/open58" && chmod 777 "$SANDBOX/open58"
o=$(env IWE_RUNTIME_DIR="$SANDBOX/open58/a/b/rt" bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$([ -e "$SANDBOX/open58/a" ] && echo created || echo untouched)" "1/untouched" "the way to the runtime directory is judged before anything is created: below a directory that others can write to nothing appears, the refusal still stops the script"
assert "$(printf '%s' "$o" | grep -c 'above the runtime directory can be changed by somebody else')" "1" "the refusal names the directory"
chmod 755 "$SANDBOX/open58"
env IWE_RUNTIME_DIR="$SANDBOX/open58/a/b/rt" bash "$SCRIPT" "$CANON" main >/dev/null 2>&1
assert "$([ -d "$SANDBOX/open58/a/b/rt" ] && echo made || echo missing)/$(ls -ld "$SANDBOX/open58/a/b/rt" | cut -c1-10)" "made/drwx------" "control: below a private directory the missing chain is created, private (0700)"

echo "scenario 58b (Codex 8, J7/J11 residual): a link that appears where a missing component is about to be made is never followed"
refusing_canon s58b
mkdir -p "$SANDBOX/sticky58" "$SANDBOX/victim58" && chmod 1777 "$SANDBOX/sticky58" && chmod 700 "$SANDBOX/victim58"
sed 's@^    ( umask 077; mkdir "\$cur" ) 2>/dev/null$@    ln -s "'"$SANDBOX"'/victim58" "$cur" 2>/dev/null; ( umask 077; mkdir "$cur" ) 2>/dev/null   # injected: a link appears where the component is about to be made@' "$SCRIPT" > "$SANDBOX/script-planted-link.sh"
assert "$(grep -c 'injected: a link appears' "$SANDBOX/script-planted-link.sh")" "1" "precondition: the planted link is injected into the copy"
o=$(env IWE_RUNTIME_DIR="$SANDBOX/sticky58/new/a/rt" bash "$SANDBOX/script-planted-link.sh" "$CANON" main 2>&1); rc=$?
assert "$rc/$(ls -A "$SANDBOX/victim58" | wc -l | tr -d ' ')/$(printf '%s' "$o" | grep -c 'is not a real directory of this user')" "1/0/1" "below a directory with the sticky bit a link planted at the first missing component is not followed: nothing appears in its target, the refusal says why and still stops the script"
rm -f "$SANDBOX/sticky58/new"
env IWE_RUNTIME_DIR="$SANDBOX/sticky58/new/a/rt" bash "$SCRIPT" "$CANON" main >/dev/null 2>&1
assert "$([ -d "$SANDBOX/sticky58/new/a/rt" ] && [ ! -L "$SANDBOX/sticky58/new" ] && echo made || echo missing)/$(ls -ld "$SANDBOX/sticky58/new/a/rt" | cut -c1-10)" "made/drwx------" "control: without the planted link the missing chain below the sticky directory is made, private (0700)"

echo "scenario 58c (Codex 8, J7/J11 residual): a link that replaces a directory ABOVE the runtime directory after the path was resolved is not trusted"
refusing_canon s58c
mkdir -p "$SANDBOX/anc58/mid/rt" && chmod 700 "$SANDBOX/anc58" "$SANDBOX/anc58/mid" "$SANDBOX/anc58/mid/rt"
sed 's@^LOG_FILE=@mv "'"$SANDBOX"'/anc58/mid" "'"$SANDBOX"'/anc58/mid.real" \&\& ln -s mid.real "'"$SANDBOX"'/anc58/mid"   # injected: a directory above the runtime directory is replaced by a link after the path was resolved\nLOG_FILE=@' "$SCRIPT" > "$SANDBOX/script-ancestor-link.sh"
assert "$(grep -c 'injected: a directory above the runtime directory is replaced' "$SANDBOX/script-ancestor-link.sh")" "1" "precondition: the replacement by a link is injected into the copy"
o=$(env IWE_RUNTIME_DIR="$SANDBOX/anc58/mid/rt" bash "$SANDBOX/script-ancestor-link.sh" "$CANON" main 2>&1); rc=$?
assert "$rc/$(ls -A "$SANDBOX/anc58/mid.real/rt" | wc -l | tr -d ' ')/$(printf '%s' "$o" | grep -c 'above the runtime directory is a link')" "1/0/1" "a directory above the runtime directory turned into a link after the path was resolved: nothing is written through it, the refusal says why and still stops the script"

echo "scenario 58d (Codex 8, J7/J11 residual): the runtime directory ITSELF turned into a link after the path was resolved is not trusted"
refusing_canon s58d
mkdir -p "$SANDBOX/rt58d/rt" && chmod 700 "$SANDBOX/rt58d" "$SANDBOX/rt58d/rt"
sed 's@^LOG_FILE=@mv "'"$SANDBOX"'/rt58d/rt" "'"$SANDBOX"'/rt58d/rt.real" \&\& ln -s rt.real "'"$SANDBOX"'/rt58d/rt"   # injected: the runtime directory is replaced by a link after the path was resolved\nLOG_FILE=@' "$SCRIPT" > "$SANDBOX/script-runtime-link.sh"
assert "$(grep -c 'injected: the runtime directory is replaced by a link' "$SANDBOX/script-runtime-link.sh")" "1" "precondition: the replacement by a link is injected into the copy"
o=$(env IWE_RUNTIME_DIR="$SANDBOX/rt58d/rt" bash "$SANDBOX/script-runtime-link.sh" "$CANON" main 2>&1); rc=$?
assert "$rc/$(ls -A "$SANDBOX/rt58d/rt.real" | wc -l | tr -d ' ')/$(printf '%s' "$o" | grep -c 'is a link')" "1/0/1" "the runtime directory turned into a link after the path was resolved: nothing is written through it, the refusal says why and still stops the script"

echo "scenario 59 (cold review): a record with an epoch before September 2001 is damage, not a time"
refusing_canon s59; rm -rf "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.streak*
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; f=$(streak_file)
printf 'R\t0\t%s\ta\nR\t0\t%s\tb\nR\t999999999\t%s\tc\n' "$CLASS_U" "$CLASS_U" "$CLASS_U" > "$f"
o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$(alerts_in "$o")/$(printf '%s' "$o" | grep -c 'this reason 1 time(s)')" "1/0/1" "records of epoch 0 and 999999999 are skipped: this refusal counts from one, no alert (they would have meant an age of decades)"

echo "scenario 60 (cold review): a new log is private, whatever the umask"
refusing_canon s60; rm -f "$IWE_RUNTIME_DIR/canon-reconcile-published.log"
( umask 022; bash "$SCRIPT" "$CANON" main >/dev/null 2>&1 )
assert "$(ls -l "$IWE_RUNTIME_DIR/canon-reconcile-published.log" | cut -c1-10)" "-rw-------" "a new log is created with mode 0600 although the umask is 022"

echo "scenario 61 (Ф81, H1): a live pid is never taken for a dead owner, whatever its age: the lock stays and the skip says how old the lock is"
fresh s61; GD=$(git -C "$CANON" rev-parse --absolute-git-dir)
sleep 600 & LIVE=$!   # an unrelated live process of this user: a pid handed to another process looks exactly like this
mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$LIVE" > "$GD/dirty-guard.lock/owner"
o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -c "lock busy, skipping this cycle -- owner pid $LIVE is alive\$")/$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)" "0/1/present" "a record without epoch: skipped, the lock stays, no age is claimed"
rm -rf "$GD/dirty-guard.lock"; mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\nepoch=%s\ntoken=x\n' "$HN" "$LIVE" $((T - 7200)) > "$GD/dirty-guard.lock/owner"
o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -c "lock busy, skipping this cycle -- owner pid $LIVE is alive, the lock was taken 120 min ago")/$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)" "0/1/present" "a record with its time: the skip names the age (a lock of two hours whose pid is alive is what a handed-over number looks like)"
rm -rf "$GD/dirty-guard.lock"; mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\nstart_utc=%s\n' "$HN" "$LIVE" "Thu Jan 1 00:00:00 1970" > "$GD/dirty-guard.lock/owner"
o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)" "0/present" "a key an earlier draft wrote (a start time) proves nothing and is not read: the live pid keeps the lock"
kill "$LIVE" 2>/dev/null; rm -rf "$GD/dirty-guard.lock"

echo "scenario 62 (Ф81, H2/H7): a missing, empty or damaged owner file is no proof of anything: the lock stays, however old, and the skip says why"
fresh s62; GD=$(git -C "$CANON" rev-parse --absolute-git-dir)
for shape in "missing" "empty" "pid=12x" "doubled pid" "pid=0"; do
  rm -rf "$GD/dirty-guard.lock"; mkdir "$GD/dirty-guard.lock"
  case "$shape" in
    missing) ;;
    empty) : > "$GD/dirty-guard.lock/owner" ;;
    "pid=12x") printf 'node=%s\npid=12x\n' "$HN" > "$GD/dirty-guard.lock/owner" ;;
    "doubled pid") printf 'node=%s\npid=999999\npid=999998\n' "$HN" > "$GD/dirty-guard.lock/owner" ;;
    "pid=0") printf 'node=%s\npid=0\n' "$HN" > "$GD/dirty-guard.lock/owner" ;;
  esac
  touch -t 202001010000 "$GD/dirty-guard.lock"
  o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
  assert "$rc/$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)/$(printf '%s' "$o" | grep -Ec 'lock busy, skipping this cycle -- the owner file is (missing|damaged)')" "0/present/1" "$shape: skipped, the lock (a year old) is left for a human, the message names the reason"
done
rm -rf "$GD/dirty-guard.lock"

echo "scenario 63 (Ф81, H3): another host name is no proof of death either, however old the lock is"
fresh s63; GD=$(git -C "$CANON" rev-parse --absolute-git-dir)
mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "OtherName.local" 999999 > "$GD/dirty-guard.lock/owner"; touch -t 202001010000 "$GD/dirty-guard.lock"
o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)/$(printf '%s' "$o" | grep -c "lock busy, skipping this cycle -- the owner host 'OtherName.local' is not this host")" "0/present/1" "the owner host differs: skipped, the lock stays, the message names both hosts"
rm -rf "$GD/dirty-guard.lock"; mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$DEAD_PID" > "$GD/dirty-guard.lock/owner"
o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -c "owner pid $DEAD_PID is gone")" "0/1" "control: the same host and a pid that is gone: the lock is taken over (a record without epoch and token works)"

echo "scenario 64 (Ф81, H8/H9): a pid that cannot be signalled is alive, and a ps that cannot tell proves nothing"
fresh s64; GD=$(git -C "$CANON" rev-parse --absolute-git-dir)
mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" 1 > "$GD/dirty-guard.lock/owner"
o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)/$(printf '%s' "$o" | grep -c 'lock busy, skipping this cycle -- owner pid 1 is alive')" "0/present/1" "pid 1: kill -0 is refused for a user process (EPERM), the process exists: the lock stays (the published script took it for a dead owner and removed the lock of a live process)"
rm -rf "$GD/dirty-guard.lock"; mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$DEAD_PID" > "$GD/dirty-guard.lock/owner"
o=$(env PATH="$FAKEBIN:$PATH" FAIL_PS=1 bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)/$(printf '%s' "$o" | grep -c "lock busy, skipping this cycle -- it cannot be established whether owner pid $DEAD_PID is alive")" "0/present/1" "kill says no such process but ps itself fails: not proven, the lock stays"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 65 (Ф81, H4): the release at exit removes only a lock whose owner record is ours"
fresh s65; GD=$(git -C "$CANON" rev-parse --absolute-git-dir)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1
assert "$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)" "gone" "control: a normal run releases its lock"
sed 's@^if \[ -e "\$RUNTIME_PHYS/\$BUSY_NAME" \]@printf "node=x\\npid=1\\ntoken=foreign\\n" > "$DGLOCK_DIR/owner"   # injected: the lock is taken over by somebody else while this run is still going\n&@' "$SCRIPT" > "$SANDBOX/script-foreign-lock.sh"
assert "$(grep -c 'injected: the lock is taken over' "$SANDBOX/script-foreign-lock.sh")" "1" "precondition: the takeover is injected into the copy"
bash "$SANDBOX/script-foreign-lock.sh" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc/$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)/$(awk -F= '$1=="token"{print $2}' "$GD/dirty-guard.lock/owner" 2>/dev/null)" "0/present/foreign" "the owner record is no longer ours at exit: the lock of the other owner is left in place"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 66 (Ф81): an owner record that cannot be published is fatal: the lock is removed and the run refuses before any protected work"
refusing_canon s66; GD=$(git -C "$CANON" rev-parse --absolute-git-dir); H66=$(git -C "$CANON" rev-parse HEAD)
o=$(env PATH="$FAKEBIN:$PATH" FAIL_MV_OWNER=1 bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)/$(printf '%s' "$o" | grep -c 'cannot record the owner of the lock')/$(git -C "$CANON" rev-parse HEAD)" "1/gone/1/$H66" "exit 1, no lock left behind, the reason is named, the canon is untouched"

echo "scenario 67 (Ф81, tier 2): a held lock is named with its owner and goes to the log"
fresh s67; GD=$(git -C "$CANON" rev-parse --absolute-git-dir)
mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$$" > "$GD/dirty-guard.lock/owner"   # this shell is a live owner
: > "$IWE_RUNTIME_DIR/canon-reconcile-published.log"
o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -c "lock busy, skipping this cycle -- owner pid $$ is alive")/$(grep -c 'dirty-guard lock cannot be taken' "$IWE_RUNTIME_DIR/canon-reconcile-published.log")" "0/1/1" "the skip names the owner and is in the log"
assert "$(printf '%s' "$o" | grep -c '^canon-reconcile-published: skipped -- dirty-guard lock cannot be taken')/$(grep -c ' skipped repo=' "$IWE_RUNTIME_DIR/canon-reconcile-published.log")/$(grep -c ' refused repo=' "$IWE_RUNTIME_DIR/canon-reconcile-published.log")" "1/1/0" "a skipped cycle is printed and logged as skipped, never as refused (exit 0, the canon is fine)"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 68 (Ф81, tier 3): a lock that stays held is an ALERT of its own series; taking the lock ends the series; the refusal journal is not touched"
refusing_canon s68; GD=$(git -C "$CANON" rev-parse --absolute-git-dir); rm -rf "$IWE_RUNTIME_DIR"/canon-reconcile-published.*
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; MAINJ=$(streak_file); MAIN_BEFORE=$(cat "$MAINJ")
mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$$" > "$GD/dirty-guard.lock/owner"
o1=$(at $((T - 9000)) bash "$SCRIPT" "$CANON" main 2>&1); o2=$(at $((T - 4500)) bash "$SCRIPT" "$CANON" main 2>&1); o3=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(alerts_in "$o1")/$(alerts_in "$o2")/$(alerts_in "$o3")" "0/0/1" "the third skip in 2.5 hours raises the ALERT"
assert "$(printf '%s' "$o3" | grep -c "ALERT canon .* not reconciled for 150 min: 3 refusals 'dirty-guard lock cannot be taken \[pid $$ dir [0-9]*\]'")" "1" "the ALERT names the class and the duration"
assert "$(cat "$MAINJ")" "$MAIN_BEFORE" "the refusal journal of the canon is unchanged"
BUSYJ=$(ls "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.lockbusy 2>/dev/null | head -1)
assert "$([ -s "$BUSYJ" ] && echo journal)" "journal" "the skips are in the lock journal"
rm -rf "$GD/dirty-guard.lock"
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1
assert "$([ -e "$BUSYJ" ] && echo present || echo gone)" "gone" "taking the lock ends the series: the lock journal is removed"

echo "scenario 69 (Ф81, Codex round 2, Б1): a doubled or empty host in the owner file is damage: the lock stays whether the pid is alive or gone"
fresh s69; GD=$(git -C "$CANON" rev-parse --absolute-git-dir)
sleep 600 & LIVE=$!
for pidcase in alive gone; do
  if [ "$pidcase" = alive ]; then P=$LIVE; else P=$DEAD_PID; fi
  for shape in "doubled host" "empty host"; do
    rm -rf "$GD/dirty-guard.lock"; mkdir "$GD/dirty-guard.lock"
    case "$shape" in
      "doubled host") printf 'node=%s\nnode=%s\npid=%s\n' "$HN" "$HN" "$P" ;;
      "empty host") printf 'node=\npid=%s\n' "$P" ;;
    esac > "$GD/dirty-guard.lock/owner"
    o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
    assert "$rc/$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)/$(printf '%s' "$o" | grep -c 'lock busy, skipping this cycle -- the owner file is damaged')" "0/present/1" "$pidcase pid, $shape: the owner file is damaged, the lock is left for a human and the skip says so"
  done
done
kill "$LIVE" 2>/dev/null; rm -rf "$GD/dirty-guard.lock"

echo "scenario 70 (Ф81, Codex round 3, Б3): a process that cannot be signalled is alive by the kernel's own answer, whatever the listing says; a kill message the script does not know proves nothing; no function of the environment stands in for kill"
if [ "$(id -u)" = 0 ]; then echo "  ok   (skipped: running as root, every process can be signalled)"; else
fresh s70; GD=$(git -C "$CANON" rev-parse --absolute-git-dir)
RP=$(LC_ALL=C ps -A -o pid=,user= | awk '$2 == "root" && $1 > 1 { print $1; exit }')   # a live process of another user, not pid 1
if [ -z "$RP" ]; then echo "  ok   (skipped: no process of root to use)"; else
  mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$RP" > "$GD/dirty-guard.lock/owner"
  o=$(env PATH="$FAKEBIN:$PATH" LISTING="hide:$RP" bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
  assert "$rc/$(printf '%s' "$o" | grep -c "lock busy, skipping this cycle -- owner pid $RP is alive")/$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)" "0/1/present" "the owner is a process of root: kill is refused (not permitted), and the listing, complete in every other respect (this run and pid 1), does not show it: alive, the lock stays"
  rm -rf "$GD/dirty-guard.lock"
fi
mkdir -p "$SANDBOX/s70/lib"; cp "$SCRIPT" "$SANDBOX/s70/script.sh"
sed 's@builtin kill -0 "\$1" 2>&1@{ echo "weird refusal"; false; }@' "$DGLOCK_LIB_SRC" > "$SANDBOX/s70/lib/dirty-guard-lock.sh"
assert "$(grep -c 'echo "weird refusal"' "$SANDBOX/s70/lib/dirty-guard-lock.sh")" "1" "precondition: the unknown message is injected into the copy of the library"
mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$DEAD_PID" > "$GD/dirty-guard.lock/owner"
o=$(bash "$SANDBOX/s70/script.sh" "$CANON" main 2>&1); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -c "lock busy, skipping this cycle -- it cannot be established whether owner pid $DEAD_PID is alive")/$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)" "0/1/present" "a dead pid, but kill says something the script does not know: not proven, the lock stays"
rm -rf "$GD/dirty-guard.lock"
sleep 600 & LIVE=$!
mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$LIVE" > "$GD/dirty-guard.lock/owner"
o=$( kill() { echo "x: No such process" >&2; return 1; }; export -f kill; env PATH="$FAKEBIN:$PATH" LISTING="hide:$LIVE" bash "$SCRIPT" "$CANON" main 2>&1 ); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -c "lock busy, skipping this cycle -- owner pid $LIVE is alive")/$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)" "0/1/present" "a function kill exported by the environment that says no such process, and a listing without the live owner: the builtin is called, the owner is alive, the lock stays"
kill "$LIVE" 2>/dev/null; rm -rf "$GD/dirty-guard.lock"
fi

echo "scenario 71 (Ф81, Codex round 2, Б3): a listing of processes that fails, is empty or is partial proves no death"
fresh s71; GD=$(git -C "$CANON" rev-parse --absolute-git-dir)
for mode in fail empty only1; do
  rm -rf "$GD/dirty-guard.lock"; mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$DEAD_PID" > "$GD/dirty-guard.lock/owner"
  o=$(env PATH="$FAKEBIN:$PATH" LISTING="$mode" bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
  assert "$rc/$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)/$(printf '%s' "$o" | grep -c "lock busy, skipping this cycle -- it cannot be established whether owner pid $DEAD_PID is alive")" "0/present/1" "listing $mode: the pid is not in it but the listing is no witness (it lacks this very run or pid 1): the lock stays"
done
rm -rf "$GD/dirty-guard.lock"; mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$DEAD_PID" > "$GD/dirty-guard.lock/owner"
o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -c "owner pid $DEAD_PID is gone")" "0/1" "control: kill says no such process and the real listing holds this run and pid 1 and not the pid: gone, the lock is taken over"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 72 (Ф81, Codex round 2, Б4): a journal that cannot be removed when its series ends is SAID, and the run goes on"
refusing_canon s72; GD=$(git -C "$CANON" rev-parse --absolute-git-dir); rm -rf "$IWE_RUNTIME_DIR"/canon-reconcile-published.*
mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$$" > "$GD/dirty-guard.lock/owner"
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; BUSYJ=$(ls "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.lockbusy 2>/dev/null | head -1)
assert "$([ -s "$BUSYJ" ] && echo journal)" "journal" "precondition: a skip made a lock journal"
rm -rf "$GD/dirty-guard.lock"
o=$(env PATH="$FAKEBIN:$PATH" FAIL_RM_SERIES=lockbusy bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -c 'warning: the lock journal .*lockbusy is left in place although the lock was taken -- the removal failed')/$([ -e "$BUSYJ" ] && echo present || echo gone)" "1/1/present" "the removal fails: a warning names the journal and the reason, the journal stays, the run itself went on (it refuses as the canon does: exit 1)"
chmod 666 "$BUSYJ"
o=$(bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(printf '%s' "$o" | grep -c 'warning: the lock journal .*lockbusy is left in place although the lock was taken -- .* is not a plain file of this user without write for group or others')/$([ -e "$BUSYJ" ] && echo present || echo gone)" "1/present" "a journal that others can write to (mode 0666) is not trusted: it is left alone and the warning says why"
chmod 600 "$BUSYJ"; bash "$SCRIPT" "$CANON" main >/dev/null 2>&1
assert "$([ -e "$BUSYJ" ] && echo present || echo gone)" "gone" "control: with nothing failing the journal goes when the lock is taken"
fresh s72b; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; republish_on_origin "$CANON" "$(git -C "$CANON" rev-parse HEAD)"
rm -f "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.streak
echo dirty >> "$CANON/a.txt"; bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; MAINJ=$(streak_file)
assert "$([ -s "$MAINJ" ] && echo journal)" "journal" "precondition: a refusal made the refusal journal"
git -C "$CANON" checkout -q -- a.txt
o=$(env PATH="$FAKEBIN:$PATH" FAIL_RM_SERIES=streak bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -c 'warning: the refusal journal .*streak is left in place on this healthy exit -- the removal failed')/$([ -e "$MAINJ" ] && echo present || echo gone)" "0/1/present" "the refusal journal cannot be removed on a healthy exit: the same kind of warning (the helper is shared), exit 0"

echo "scenario 73 (Ф81, Codex round 3, Б4): the skips of one lock INSTANCE form their own series (the same owner pid, or no owner at all, does not make two lock directories one instance); a run that stalled between judging and writing records nothing about an instance that is gone"
refusing_canon s73; GD=$(git -C "$CANON" rev-parse --absolute-git-dir); rm -rf "$IWE_RUNTIME_DIR"/canon-reconcile-published.*
mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$$" > "$GD/dirty-guard.lock/owner"   # instance 1: this shell owns it
o=$(at $((T - 20000)) bash "$SCRIPT" "$CANON" main 2>&1); o=$(at $((T - 19000)) bash "$SCRIPT" "$CANON" main 2>&1)
mv "$GD/dirty-guard.lock" "$GD/dirty-guard.lock.kept"; mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$$" > "$GD/dirty-guard.lock/owner"   # instance 2: the same owner pid in ANOTHER directory (the first is kept, so that its inode cannot be reused)
o=$(at $((T - 100)) bash "$SCRIPT" "$CANON" main 2>&1); o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(alerts_in "$o")/$(printf '%s' "$o" | grep -c 'this reason 2 time(s)')" "0/1" "two skips under the first instance (5 hours earlier) and two under the second, the same pid: the second counts by itself (2), no ALERT"
rm -rf "$GD/dirty-guard.lock" "$GD/dirty-guard.lock.kept" "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.lockbusy
mkdir "$GD/dirty-guard.lock"   # instance 1, no owner file at all
o=$(at $((T - 20000)) bash "$SCRIPT" "$CANON" main 2>&1); o=$(at $((T - 19000)) bash "$SCRIPT" "$CANON" main 2>&1)
mv "$GD/dirty-guard.lock" "$GD/dirty-guard.lock.kept"; mkdir "$GD/dirty-guard.lock"   # instance 2, no owner file either: the same label, another directory
o=$(at $((T - 100)) bash "$SCRIPT" "$CANON" main 2>&1); o=$(at "$T" bash "$SCRIPT" "$CANON" main 2>&1)
assert "$(alerts_in "$o")/$(printf '%s' "$o" | grep -c 'this reason 2 time(s)')" "0/1" "two empty locks in a row: the same label, other directories: the second series counts by itself (2), no ALERT"
rm -rf "$GD/dirty-guard.lock" "$GD/dirty-guard.lock.kept" "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.lockbusy
sed 's@^  if \[ -n "\$DGLOCK_INSTANCE" \] && \[ "\$(dglock_instance)" != "\$DGLOCK_INSTANCE" \]; then$@  mv "$DGLOCK_DIR" "$DGLOCK_DIR.moved"; mkdir "$DGLOCK_DIR"   # injected: the lock became another instance while this skip was being reported\n&@' "$SCRIPT" > "$SANDBOX/script-s73.sh"
assert "$(grep -c 'injected: the lock became another instance' "$SANDBOX/script-s73.sh")" "1" "precondition: the stall is injected into the copy"
mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$$" > "$GD/dirty-guard.lock/owner"
o=$(bash "$SANDBOX/script-s73.sh" "$CANON" main 2>&1)
BJ=$(ls "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.lockbusy 2>/dev/null | head -1)
assert "$(printf '%s' "$o" | grep -c 'the lock changed while this skip was being reported.*: not recorded')/${BJ:-none}" "1/none" "the lock was replaced between the judgement and the write: nothing is written about the old instance"
rm -rf "$GD"/dirty-guard.lock*

echo "scenario 74 (Ф81, writer's review): a lock directory that cannot be created, or the lock of a dead owner that cannot be removed, is named as such, not as a held lock"
if [ "$(id -u)" = 0 ]; then echo "  ok   (skipped: running as root, a directory mode does not stop root)"; else
fresh s74; GD=$(git -C "$CANON" rev-parse --absolute-git-dir); rm -rf "$IWE_RUNTIME_DIR"/canon-reconcile-published.*
chmod 555 "$GD"
o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -c 'lock busy, skipping this cycle -- the lock directory cannot be created')" "0/1" "no write access to the git directory: the skip says the lock directory cannot be created (not that somebody holds it)"
chmod 755 "$GD"; mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$DEAD_PID" > "$GD/dirty-guard.lock/owner"; chmod 555 "$GD/dirty-guard.lock"
o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$([ -f "$GD/dirty-guard.lock/owner" ] && echo whole || echo damaged)/$(printf '%s' "$o" | grep -c "lock busy, skipping this cycle -- the lock could not be taken over (owner pid $DEAD_PID is gone)")" "0/whole/1" "the lock of a dead owner cannot be changed (no write access to the lock directory): the skip says so, and the lock is still whole (its owner record is not deleted piece by piece)"
chmod 755 "$GD" "$GD/dirty-guard.lock"; rm -rf "$GD/dirty-guard.lock"
fi

echo "scenario 75 (Ф81, cold review): after a failed publication only our own empty directory is removed: a lock that another run took and published meanwhile stays"
refusing_canon s75; GD=$(git -C "$CANON" rev-parse --absolute-git-dir)
mkdir -p "$SANDBOX/s75/lib"; cp "$SCRIPT" "$SANDBOX/s75/script.sh"
sed 's@^  if ! rmdir "\$DGLOCK_DIR" 2>/dev/null && \[ -e "\$DGLOCK_DIR" \]; then@  rm -rf "$DGLOCK_DIR"; mkdir "$DGLOCK_DIR"; printf "node=%s\\npid=1\\ntoken=foreign\\n" "$_DGLOCK_HOST" > "$DGLOCK_DIR/owner"   # injected: another run took the lock and published while this publication was failing\n&@' "$DGLOCK_LIB_SRC" > "$SANDBOX/s75/lib/dirty-guard-lock.sh"
assert "$(grep -c 'injected: another run took the lock and published' "$SANDBOX/s75/lib/dirty-guard-lock.sh")" "1" "precondition: the other run is injected into the copy of the library"
o=$(env PATH="$FAKEBIN:$PATH" FAIL_MV_OWNER=1 bash "$SANDBOX/s75/script.sh" "$CANON" main 2>&1); rc=$?
assert "$rc/$(awk -F= '$1=="token"{print $2}' "$GD/dirty-guard.lock/owner" 2>/dev/null)/$(printf '%s' "$o" | grep -c 'cannot record the owner of the lock')" "1/foreign/1" "the run refuses, and the lock of the other run, published meanwhile, is still there with its owner record"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 76 (Ф81, cold review): a lock released between our failed mkdir and the check is taken, not reported as a directory that cannot be created"
fresh s76; GD=$(git -C "$CANON" rev-parse --absolute-git-dir)
mkdir -p "$SANDBOX/s76/lib"; cp "$SCRIPT" "$SANDBOX/s76/script.sh"
awk '{ print } !done && $0 == "    [ \"$rc\" -eq 1 ] || return \"$rc\"" { print "  rm -rf \"$DGLOCK_DIR\"   # injected: the holder released the lock between our failed mkdir and the check"; done = 1 }' "$DGLOCK_LIB_SRC" > "$SANDBOX/s76/lib/dirty-guard-lock.sh"
assert "$(grep -c 'injected: the holder released the lock' "$SANDBOX/s76/lib/dirty-guard-lock.sh")" "1" "precondition: the release is injected into the copy of the library"
mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$$" > "$GD/dirty-guard.lock/owner"   # this shell is a live owner
o=$(bash "$SANDBOX/s76/script.sh" "$CANON" main 2>&1); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -c 'lock busy')/$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)" "0/0/gone" "the lock was free by the time of the check: the run takes it (no skip, no false diagnosis) and releases it at exit"

echo "scenario 77 (Ф81, cold review): a lock directory holds a leftover that cannot be deleted: the stale lock is still taken over (the record is swapped, nothing is deleted), the release takes the lock away at once (renamed) and SAYS where the leftover stays; the next run finds no lock"
if [ "$(id -u)" = 0 ]; then echo "  ok   (skipped: running as root, a directory mode does not stop root)"; else
fresh s77; GD=$(git -C "$CANON" rev-parse --absolute-git-dir)
mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$DEAD_PID" > "$GD/dirty-guard.lock/owner"; mkdir "$GD/dirty-guard.lock/sub"; echo x > "$GD/dirty-guard.lock/sub/f"; chmod 555 "$GD/dirty-guard.lock/sub"
o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
LEFT=0; for d in "$GD"/dirty-guard.lock.released.*; do [ -e "$d" ] && LEFT=$((LEFT + 1)); done
assert "$rc/$(printf '%s' "$o" | grep -c "reclaiming the lock: owner pid $DEAD_PID is gone")/$(printf '%s' "$o" | grep -c 'warning: the released lock was moved to .* could not be deleted there')/$LEFT/$([ -e "$GD/dirty-guard.lock" ] && echo present || echo gone)" "0/1/1/1/gone" "the dead owner's lock is taken over, the leftover that cannot be deleted is named with its path, the lock itself is gone, and the run went on"
o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -c 'reclaiming')" "0/0" "the next run finds no lock and takes a new one without any takeover"
chmod -R u+w "$GD"/dirty-guard.lock.released.* 2>/dev/null; rm -rf "$GD"/dirty-guard.lock.released.*
fi

echo "scenario 78 (Ф81, Codex round 4, Б4): outside the supported scope (directory numbers that wander) a skip is NOT counted, but it is never silent: it is printed and logged, and the run goes on as a skipped cycle"
fresh s78; GD=$(git -C "$CANON" rev-parse --absolute-git-dir); rm -rf "$IWE_RUNTIME_DIR"/canon-reconcile-published.*
mkdir "$GD/dirty-guard.lock"; printf 'node=%s\npid=%s\n' "$HN" "$$" > "$GD/dirty-guard.lock/owner"; : > "$SANDBOX/ls-counter"
o=$(at $((T - 100)) env LS_UNSTABLE_COUNTER="$SANDBOX/ls-counter" bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
BJ=$(ls "$IWE_RUNTIME_DIR"/canon-reconcile-published.*.lockbusy 2>/dev/null | head -1)
assert "$rc/$(printf '%s' "$o" | grep -c 'not stable): not recorded\|keep directory numbers stable): not recorded')/$(grep -c ' skipped repo=.*not counted' "$IWE_RUNTIME_DIR/canon-reconcile-published.log")/${BJ:-none}" "0/1/1/none" "an erratic directory number: the skip says so on stderr and in the log, nothing is written to the series (outside the supported scope), the exit code stays 0"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 79 (Ф81, cold review 2): a file or a dangling link in the place of the lock directory is named as that, not as an owner who died"
fresh s79; GD=$(git -C "$CANON" rev-parse --absolute-git-dir)
echo junk > "$GD/dirty-guard.lock"
o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -c 'lock busy, skipping this cycle -- .*dirty-guard.lock is not a directory')" "0/1" "a file stands in the place of the lock: said so"
rm -f "$GD/dirty-guard.lock"; ln -s "$GD/nowhere" "$GD/dirty-guard.lock"
o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -c 'lock busy, skipping this cycle -- .*dirty-guard.lock is not a directory')" "0/1" "a dangling link stands in the place of the lock: said so"
rm -f "$GD/dirty-guard.lock"

echo "scenario 80 (Ф81 remainder, Codex round 10): a lock whose record is in the OLD format (host=, no node=) and whose owner is dead is NOT taken over by this publisher (an old guard may be taking it over at this very moment): the skip says that the record is in the old format and what to do, and the lock stays"
fresh s80; GD=$(git -C "$CANON" rev-parse --absolute-git-dir)
mkdir "$GD/dirty-guard.lock"; printf 'host=%s\npid=%s\nepoch=%s\ntoken=old\nscript=old-guard\n' "$HN" "$DEAD_PID" "$(date -u +%s)" > "$GD/dirty-guard.lock/owner"
o=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc/$(printf '%s' "$o" | grep -c "lock busy, skipping this cycle -- owner pid $DEAD_PID is gone, but its record is in the old format")/$([ -d "$GD/dirty-guard.lock" ] && echo present || echo gone)/$(grep -c "^pid=$DEAD_PID$" "$GD/dirty-guard.lock/owner")" "0/1/present/1" "the old-format lock of a dead owner is left alone, loudly, and the record is untouched"
rm -rf "$GD/dirty-guard.lock"

[ "$fails" = 0 ] && echo "PASS: all scenarios" || { echo "FAIL: $fails assertion(s)"; exit 1; }
