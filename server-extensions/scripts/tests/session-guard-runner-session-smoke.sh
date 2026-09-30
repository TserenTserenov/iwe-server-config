#!/usr/bin/env bash
# session-guard-runner-session-smoke.sh -- WP-561 Ф25: the contract the strategist wrapper relies on.
# A scheduled runner (the week-review wrapper) opens a HOUSEKEEPING session with --canonical-owner on
# a frozen checkout, declares a directory scope, and lets ANOTHER agent (the model) commit inside it.
# The guard's scope gate is agent-agnostic: any live semaphore covering a path authorises the commit.
# Regressing any line here breaks the wrapper's "session owned by the script" design.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-runner-session.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

GOV="$TEST_ROOT/DS-strategy"
git init -q -b main "$GOV"
git -C "$GOV" config user.email t@t
git -C "$GOV" config user.name t
mkdir -p "$GOV/current"
echo plan > "$GOV/current/WeekPlan W39 2026-09-21.md"
git -C "$GOV" add -- "current/WeekPlan W39 2026-09-21.md"
git -C "$GOV" -c commit.gpgsign=false commit -q -m seed

# The checkout is frozen, the way the real canonical governance checkout is.
export IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH="$GOV"
RUNNER=strategist-week-review
SEM="$TEST_ROOT/.iwe-runtime/sessions/${RUNNER}-housekeeping-week-review.open"

fail() { echo "FAIL: $*" >&2; exit 1; }
runner() { ( cd "$GOV" && bash "$GUARD" "$@" ) 2>&1; }
open_runner() { runner open --housekeeping week-review --agent "$RUNNER" --canonical-owner week-review --owner-pid $$; }
model_check() { ( cd "$GOV" && IWE_AGENT=claude-code bash "$GUARD" pre-commit-check ) >"$TEST_ROOT/check.out" 2>&1; }

# 1. Without --canonical-owner a housekeeping session is refused on the frozen checkout.
if OUT=$(runner open --housekeeping week-review --agent "$RUNNER" --owner-pid $$); then
    fail "housekeeping open on a frozen checkout must need --canonical-owner, got: $OUT"
fi
printf '%s' "$OUT" | grep -q 'freeze' || fail "the refusal must name the freeze, got: $OUT"
[ ! -e "$SEM" ] || fail "a refused open must leave no semaphore"
echo "OK: plain housekeeping open is refused under freeze and leaves nothing behind"

# 2. As a scheduled runner it opens, and the directory scope is recorded.
open_runner >/dev/null || fail "open --housekeeping --canonical-owner must succeed under freeze"
[ -f "$SEM" ] || fail "the semaphore file was not created"
grep -qx 'canonical_owner: week-review' "$SEM" || fail "canonical owner must survive open"
grep -qx "canonical_repo: $GOV" "$SEM" || fail "owner authority must name the exact checkout"
grep -qx "host: $(hostname)" "$SEM" || fail "owner host must be recorded"
grep -q '^pid_start: .' "$SEM" || fail "PID start identity must be recorded for housekeeping"
runner note-file "current/" --agent "$RUNNER" >/dev/null || fail "note-file of a directory scope must succeed"
grep -qx 'file: current/' "$SEM" || fail "the directory scope must be recorded in the semaphore"
grep -q '^wp:' "$SEM" && fail "a housekeeping semaphore must carry no wp (the commit barrier would have to classify it)"
echo "OK: scheduled-runner open works under freeze; scope current/ recorded; no wp field"

# 3. The model (another agent) commits a NEW and a MODIFIED file inside the scope.
echo report > "$GOV/current/WeekReport W39 2026-09-21.md"
echo "plan v2" >> "$GOV/current/WeekPlan W39 2026-09-21.md"
git -C "$GOV" add -- "current/WeekPlan W39 2026-09-21.md" "current/WeekReport W39 2026-09-21.md"
model_check || fail "another agent's commit inside the declared scope must pass: $(tail -3 "$TEST_ROOT/check.out")"
echo "OK: another agent may commit a new and a modified file inside the runner's scope"

# 4. A file outside the scope is still refused.
echo x > "$GOV/other.txt"
git -C "$GOV" add other.txt
RC=0; model_check || RC=$?
[ "$RC" = "6" ] || fail "a new file outside the scope must be refused with exit 6, got $RC"
grep -q 'other.txt' "$TEST_ROOT/check.out" || fail "the refusal must name the file"
git -C "$GOV" restore --staged other.txt
rm -f "$GOV/other.txt"
echo "OK: a file outside the declared scope is refused"

# 5. A leftover semaphore of a dead run refuses the fixed name until an exact close.
if OUT=$(open_runner); then fail "reopening without close must be refused, got: $OUT"; fi
printf '%s' "$OUT" | grep -q 'уже открыт' || fail "the refusal must say it is already open, got: $OUT"
runner close --housekeeping week-review --agent "$RUNNER" >/dev/null || fail "an exact close of the leftover must succeed"
[ ! -e "$SEM" ] || fail "close must remove the semaphore"
open_runner >/dev/null || fail "open after close must succeed"
echo "OK: a leftover refuses the fixed name; close, then open works"

# 6. After close the authority is gone.
runner close --housekeeping week-review --agent "$RUNNER" >/dev/null
RC=0; model_check || RC=$?
[ "$RC" != "0" ] || fail "after close the same commit must be refused"
echo "OK: after close the commit is refused again"

# 7. Two live sessions of the same runner (a run that overlapped midnight next to a leftover whose
# pid is alive): the agent-only selector is ambiguous and must refuse; the run's own reason, stored
# as the slug, selects exactly its session -- the scope lands there and nowhere else.
SEM2="$TEST_ROOT/.iwe-runtime/sessions/${RUNNER}-housekeeping-week-review-2.open"
open_runner >/dev/null || fail "first of two sessions must open"
runner open --housekeeping week-review-2 --agent "$RUNNER" --canonical-owner week-review --owner-pid $$ >/dev/null \
    || fail "a second session under another reason must open (unique name per run)"
if OUT=$(runner note-file "current/" --agent "$RUNNER"); then
    fail "note-file by agent alone must refuse with two live sessions, got: $OUT"
fi
printf '%s' "$OUT" | grep -q 'несколько открытых семафоров' || fail "the refusal must say several sessions are open, got: $OUT"
runner note-file "current/" --agent "$RUNNER" --slug week-review-2 >/dev/null || fail "note-file selected by slug must succeed"
grep -qx 'file: current/' "$SEM2" || fail "the scope must be recorded in the session selected by slug"
grep -qx 'file: current/' "$SEM" && fail "the other live session must stay untouched"
git -C "$GOV" add -- "current/WeekPlan W39 2026-09-21.md" "current/WeekReport W39 2026-09-21.md"
model_check || fail "the commit inside the slug-selected session's scope must pass: $(tail -3 "$TEST_ROOT/check.out")"
runner close --housekeeping week-review-2 --agent "$RUNNER" >/dev/null || fail "close by reason must pick the right one of two"
[ ! -e "$SEM2" ] || fail "close must remove the slug-selected session"
[ -e "$SEM" ] || fail "close must leave the other live session alone"
runner close --housekeeping week-review --agent "$RUNNER" >/dev/null
echo "OK: with two live sessions the slug selects the run's own one; scope, commit and close land there only"

echo "PASS: a runner-owned housekeeping session authorises another agent's commit inside its scope only"

# Cross-repo integration: pass the candidate DS wrapper explicitly when testing
# an isolated root checkout. The root-only guard suite has no DS checkout in CI.
WRAPPER="${IWE_TEST_GIT_WRAPPER:-$ROOT_DIR/DS-my-strategy/scripts/git-wrapper/git-wrapper.sh}"
if [ ! -f "$WRAPPER" ]; then
  echo "SKIP: wrapper integration needs IWE_TEST_GIT_WRAPPER pointing at the DS candidate"
  exit 0
fi
IWE_REAL_GIT="$(command -v git)"
export IWE_REAL_GIT IWE_GIT_WRAPPER_LOG="$TEST_ROOT/wrapper.jsonl"
wrap() { bash "$WRAPPER" "$@" >"$TEST_ROOT/wrapper.out" 2>&1; }
denied() {
  if wrap "$@"; then fail "wrapper allowed a canonical write without exact runner authority (scenario at line ${BASH_LINENO[0]})"; fi
  grep -q BLOCKED "$TEST_ROOT/wrapper.out" || fail "expected wrapper refusal: $(cat "$TEST_ROOT/wrapper.out")"
}
OTHER="$TEST_ROOT/PACK-other"
ISOLATED="$TEST_ROOT/.iwe-runtime/isolated-worktrees/test-1790782579-abcd"
EXTERNAL="${TEST_ROOT}-external"
trap 'rm -rf "$TEST_ROOT" "$EXTERNAL"' EXIT
git init -q -b main "$TEST_ROOT"
git init -q -b main "$OTHER"
git init -q -b main "$EXTERNAL"
git -C "$GOV" worktree add -q -b wrapper-isolated "$ISOLATED"
echo wrapper > "$GOV/wrapper.txt"
echo isolated > "$ISOLATED/wrapper.txt"
echo other > "$OTHER/wrapper.txt"
echo external > "$EXTERNAL/wrapper.txt"
echo root > "$TEST_ROOT/root.txt"

denied -C "$TEST_ROOT" add root.txt
denied -C "$GOV" add wrapper.txt
denied -C "$GOV" stage wrapper.txt
[ -z "$(git -C "$GOV" diff --cached --name-only -- wrapper.txt)" ] || fail "denied add changed canonical index"
(cd "$ISOLATED" && denied -C "$GOV" add wrapper.txt)
(cd "$GOV" && wrap -C "$ISOLATED" add wrapper.txt) || fail "effective linked checkout must be allowed"
[ "$(git -C "$ISOLATED" diff --cached --name-only)" = wrapper.txt ] || fail "allowed add did not stage linked file"
GIT_INDEX_FILE="$GOV/.git/index" denied -C "$ISOLATED" add wrapper.txt
GIT_INDEX_FILE="$GOV/.git/index" denied -C "$EXTERNAL" add wrapper.txt
GIT_INDEX_FILE="$GOV/.git/index" denied -C "$OTHER" add wrapper.txt
[ -z "$(git -C "$GOV" diff --cached --name-only -- wrapper.txt)" ] || fail "redirected-index attempt changed canonical index"
LINKED_INDEX="$(git -C "$ISOLATED" rev-parse --absolute-git-dir)/index"
mv "$LINKED_INDEX" "$LINKED_INDEX.saved"
ln -s "$GOV/.git/index" "$LINKED_INDEX"
denied -C "$ISOLATED" add wrapper.txt
rm "$LINKED_INDEX"
mv "$LINKED_INDEX.saved" "$LINKED_INDEX"
[ -z "$(git -C "$GOV" diff --cached --name-only -- wrapper.txt)" ] || fail "symlinked-index attempt changed canonical index"
GIT_INDEX_FILE="$EXTERNAL/private.index" wrap -C "$ISOLATED" add wrapper.txt || fail "private index outside IWE should remain usable"
[ -n "$(GIT_INDEX_FILE="$EXTERNAL/private.index" git -C "$ISOLATED" ls-files --stage -- wrapper.txt)" ] || fail "private-index staging did not execute"
denied --git-dir "$GOV/.git" --work-tree "$ISOLATED" add wrapper.txt
denied --git-dir="$GOV/.git" --work-tree="$GOV" add wrapper.txt
denied -C "$GOV" -c "core.worktree=$EXTERNAL" add wrapper.txt
GIT_COMMON_DIR="$OTHER/.git" denied -C "$GOV" add wrapper.txt
wrap -C "$TEST_ROOT" -C PACK-other add wrapper.txt || fail "other IWE product repository acquired an unapproved deny gate"
[ "$(git -C "$OTHER" diff --cached --name-only)" = wrapper.txt ] || fail "other IWE product staging did not execute"
GIT_INDEX_FILE="$OTHER/.git/index" wrap -C "$EXTERNAL" add wrapper.txt || fail "noncanonical product index should retain baseline behaviour"
wrap -C "$GOV" status --porcelain || fail "read-only canonical status must remain available"
denied -C "$GOV" -c alias.stage=add stage wrapper.txt
denied -C "$GOV" -c alias.stg=add stg wrapper.txt
denied -C "$GOV" -c alias.outer=inner -c alias.inner=add outer wrapper.txt
denied -C "$GOV" -c 'alias.peek=!printf private-test-secret' peek
wrap -C "$GOV" -c alias.peek=status peek --porcelain || fail "simple read-only alias must remain available"
wrap -C "$GOV" -c 'alias.status=add' status --porcelain || fail "alias cannot replace a builtin"
wrap -C "$EXTERNAL" add wrapper.txt || fail "outside-IWE repository was blocked"
wrap -C "$EXTERNAL" -c 'alias.readonly=!: ' readonly || fail "external shell alias was blocked"
[ "$(git -C "$EXTERNAL" diff --cached --name-only)" = wrapper.txt ] || fail "outside-IWE add did not run"
denied --bare --git-dir "$GOV/.git" add wrapper.txt
git init -q --bare "$EXTERNAL/external-bare.git"
if wrap --git-dir "$EXTERNAL/external-bare.git" add wrapper.txt; then
  fail "real git must refuse add in a bare repo"
fi
grep -q BLOCKED "$TEST_ROOT/wrapper.out" && fail "wrapper blocked an unrelated external bare repo"

open_runner >/dev/null || fail "owner fixture must open"
wrap -C "$GOV" add wrapper.txt || fail "live ancestor owning exact repo must authorize add: $(cat "$TEST_ROOT/wrapper.out")"
wrap -C "$GOV" -c alias.stage=add stage wrapper.txt || fail "runner-owned write alias must execute"
[ "$(git -C "$GOV" diff --cached --name-only -- wrapper.txt)" = wrapper.txt ] || fail "runner-authorized add did not execute"
denied -C "$TEST_ROOT" add root.txt
cp "$SEM" "$TEST_ROOT/owner.snapshot"
for field in host pid_start pid canonical_owner canonical_repo; do
  python3 - "$TEST_ROOT/owner.snapshot" "$SEM" "$field" <<'PY'
from pathlib import Path
import sys
source, target, field = sys.argv[1:]
values = {"host": "other-host", "pid_start": "wrong-start", "pid": "2147483647",
          "canonical_owner": "", "canonical_repo": "/unrelated/repo"}
text = Path(source).read_text()
Path(target).write_text("\n".join(field + ": " + values[field] if line.startswith(field + ":") else line
                                  for line in text.splitlines()) + "\n")
PY
  denied -C "$GOV" add wrapper.txt
done
cp "$TEST_ROOT/owner.snapshot" "$SEM"
printf 'canonical_owner: forged\n' >> "$SEM"
# Trailing body data does not amend the frontmatter identity.
wrap -C "$GOV" add wrapper.txt || fail "body text must not replace frontmatter owner"
python3 - "$SEM" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace("canonical_owner: week-review", "canonical_owner: week-review\ncanonical_owner: forged"))
PY
denied -C "$GOV" add wrapper.txt
cp "$TEST_ROOT/owner.snapshot" "$SEM"
# A live sibling process is not the runner ancestor of this git invocation.
sleep 30 & SIBLING_PID=$!
python3 - "$SEM" "$SIBLING_PID" <<'PY'
from pathlib import Path
import subprocess, sys
p = Path(sys.argv[1])
pid = sys.argv[2]
start = subprocess.check_output(["ps", "-p", pid, "-o", "lstart="], text=True).strip()
p.write_text("\n".join("pid: " + pid if line.startswith("pid:") else
                      "pid_start: " + start if line.startswith("pid_start:") else line
                      for line in p.read_text().splitlines()) + "\n")
PY
denied -C "$GOV" add wrapper.txt
kill "$SIBLING_PID" 2>/dev/null || true
wait "$SIBLING_PID" 2>/dev/null || true
cp "$TEST_ROOT/owner.snapshot" "$SEM"
wrap -C "$GOV" -c 'user.name=private-test-secret' add wrapper.txt || fail "valid runner lost authority"
runner close --housekeeping week-review --agent "$RUNNER" >/dev/null
denied -C "$GOV" add wrapper.txt
python3 - "$IWE_GIT_WRAPPER_LOG" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
assert "private-test-secret" not in text, "raw config leaked to audit log"
rows = [json.loads(line) for line in text.splitlines()]
owners = [row for row in rows if row["reason_code"] == "CANONICAL_OWNER_ANCESTOR"]
assert owners and all(row["runner"] == "week-review" and row["owner_pid"] for row in owners)
assert any(row["reason_code"] == "OUTSIDE_IWE" for row in rows)
assert any(row["reason_code"] == "ISOLATED_WORKTREE" for row in rows)
assert any(row["reason_code"] == "OTHER_IWE_CHECKOUT" and row["decision"] == "allow_warn" for row in rows)
PY
echo "PASS: git add targets the actual checkout and only an exact live runner ancestor owns canonical writes"
