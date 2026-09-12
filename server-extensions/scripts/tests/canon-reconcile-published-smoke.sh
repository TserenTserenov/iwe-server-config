#!/usr/bin/env bash
# canon-reconcile-published-smoke.sh -- throwaway-repo scenarios for canon-reconcile-published.sh
# (WP-530 Ф38 / Ф5). Each scenario asserts an observable outcome, not just "did not crash".
set -uo pipefail
SCRIPT="${1:-$(dirname "$0")/../canon-reconcile-published.sh}"
[ -x "$SCRIPT" ] || SCRIPT="$(cd "$(dirname "$0")" && pwd)/../canon-reconcile-published.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export IWE_WORKSPACE="$SANDBOX/no-workspace"   # ledger-append absent -> ledger_note is a no-op
export IWE_RUNTIME="$SANDBOX/runtime"; mkdir -p "$IWE_RUNTIME/sessions"   # no live writers unless a scenario adds one
fails=0
assert() { if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails+1)); fi; }

fresh() {  # <name> -- bare origin + canonical clone with one base commit; sets ORIGIN, CANON
  ORIGIN="$SANDBOX/$1-origin.git"; CANON="$SANDBOX/$1-canon"
  git init -q --bare "$ORIGIN"
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
H=$(git -C "$CANON" rev-parse HEAD); mkdir "$CANON/.git/dirty-guard.lock"; printf 'host=%s\npid=%s\n' "$(hostname)" "$$" > "$CANON/.git/dirty-guard.lock/owner"
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
printf 'agent: claude-code\npid: %s\n' "$$" > "$IWE_RUNTIME/sessions/claude-code-writer.open"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1 with live writer"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
printf 'agent: codex\n' > "$IWE_RUNTIME/sessions/codex-nopid.open"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "semaphore without pid counts as a live writer"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"; rm -f "$IWE_RUNTIME/sessions/codex-nopid.open"
printf 'agent: claude-code\npid: %s\nisolated_worktree: /tmp/x\n' "$$" > "$IWE_RUNTIME/sessions/claude-code-writer.open"
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
git -C "$CANON" fetch -q origin
assert "$rc" "0" "isolated session does not block"; assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "replaced once only isolated sessions are live"
rm -f "$IWE_RUNTIME/sessions/claude-code-writer.open"

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
fresh s12; mkdir "$CANON/.git/dirty-guard.lock"; printf 'host=%s\npid=%s\n' "$(hostname)" "$$" > "$CANON/.git/dirty-guard.lock/owner"
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1
assert "$([ -d "$CANON/.git/dirty-guard.lock" ] && echo present)" "present" "foreign lock still present"; rm -rf "$CANON/.git/dirty-guard.lock"

echo "scenario 13: refusal writes nothing inside the repository (log goes to runtime dir)"
fresh s13; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
echo two > "$CANON/c.txt"; commit_in "$CANON" "unique"; BEFORE=$(git -C "$CANON" status --porcelain | md5); MARK=$(mktemp); sleep 1
LOG_BEFORE=$(grep -c ' refused ' "$IWE_RUNTIME/canon-reconcile-published.log" 2>/dev/null || echo 0)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1
assert "$(git -C "$CANON" status --porcelain | md5)" "$BEFORE" "repo status unchanged by the refusal"
assert "$(find "$CANON" -newer "$MARK" -type f -not -path "$CANON/.git/*" | wc -l | tr -d ' ')" "0" "no working-tree file written by the refusal (git's own fetch bookkeeping under .git is expected)"
assert "$(( $(grep -c ' refused ' "$IWE_RUNTIME/canon-reconcile-published.log") - LOG_BEFORE ))" "1" "refusal logged exactly once in the runtime log"

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

[ "$fails" = 0 ] && echo "PASS: all scenarios" || { echo "FAIL: $fails assertion(s)"; exit 1; }
