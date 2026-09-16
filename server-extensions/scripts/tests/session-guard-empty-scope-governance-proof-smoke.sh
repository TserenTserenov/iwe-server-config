#!/usr/bin/env bash
# session-guard-empty-scope-governance-proof-smoke.sh -- WP-484 п.16-continuation
# (16.09, peer session 2026-09-16-13-wp484-close-drift-fix, Claude+Kimi).
#
# `close` used to demand the WHOLE shared governance checkout's HEAD be an
# ancestor of origin/main for EVERY non-isolated session, even one that never
# touched it. In a checkout shared by many concurrent sessions (the common
# case here), that HEAD drifts constantly from sibling sessions' local,
# not-yet-pushed commits -- a session with zero footprint in that repo failed
# for a divergence it had no part in.
#
# First fix attempt gated the check on a `commit:` claim alone -- cold review
# caught that this silently drops an existing (accidental) safety net: a
# session that edited a file here (auto-tracked as `file:` by
# post-tool-use-scope-track.sh) and committed it directly, forgetting
# `note-commit`, used to fail closed on this same check. Fixed by requiring
# EITHER a `commit:` claim for this repo OR a `file:` claim that resolves to
# a path actually present under the repo -- see cases 2/3 below, which is
# exactly the gap the first version left open.
#
# Second cold review then caught that a bare existence check alone is itself
# unsound: `file:` claims are not repo-qualified, and confirmed live data
# (CLAUDE.md/AGENTS.md/.claude/settings.json/several scripts/* exist verbatim
# in both $IWE_ROOT and the governance checkout) showed a root-repo edit of
# one of those routinely-touched files would be miscounted as governance-repo
# footprint and reopen the exact false block this fix removes -- not a rare
# edge case. Fixed again: a `file:` claim only counts as footprint when it
# resolves under the governance repo AND does NOT also exist at the same
# relative path under $IWE_ROOT -- see case 2.5 below for the collision this
# closes.
#
# The guard block itself is extracted verbatim from `_close_delivery_and_
# transition` (by marker lines, since it is not a standalone function), and
# `_repo_head_has_publish_proof`/`_repo_scope_has_publish_proof` are extracted
# as functions -- both so the test cannot drift from the code it guards.
set -euo pipefail

IWE_ROOT_REAL="${IWE_ROOT:-$HOME/IWE}"
GUARD="$IWE_ROOT_REAL/scripts/session-guard.sh"
[ -f "$GUARD" ] || { echo "SKIP: не найден $GUARD"; exit 0; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
# _repo_scope_has_publish_proof (called internally when the ancestor check
# fails and a semaphore is given) references $IWE_ROOT unguarded -- unrelated
# to this repo's IWE_ROOT, just needs to be set under `set -u`.
export IWE_ROOT="$SANDBOX/iwe-root-placeholder"

# --- extract the two proof functions, plus the guard block that decides
# whether to call them, from the live script ---
python3 - "$GUARD" "$SANDBOX/proof_fns.sh" "$SANDBOX/guard_block.sh" <<'PY'
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text(encoding="utf-8").split("\n")

def extract_fn(name):
    start = next(i for i, line in enumerate(lines) if line.startswith(name + "() {"))
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == "}")
    return lines[start:end + 1]

fns = extract_fn("_repo_scope_has_publish_proof") + [""] + extract_fn("_repo_head_has_publish_proof")
Path(sys.argv[2]).write_text("\n".join(fns), encoding="utf-8")

start = next(i for i, line in enumerate(lines)
             if line.strip().startswith('GOVERNANCE_REPO_BASENAME=$(basename "$governance_repo")'))
end = next(i for i in range(start + 1, len(lines)) if lines[i] == "  fi")
Path(sys.argv[3]).write_text("\n".join(lines[start:end + 1]), encoding="utf-8")
PY
# shellcheck source=/dev/null
. "$SANDBOX/proof_fns.sh"
# The guard block calls `fail "..." 7` on a failed proof, which in the real
# script exits the process -- stub it once, globally, so a "checked -> fails"
# case (expected for an unpushed commit) doesn't kill this test. Its return
# value is never asserted on; only $GOVERNANCE_REPO_HAS_FOOTPRINT is.
fail() { :; }

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); echo "  ok: $1"
  else
    FAIL=$((FAIL + 1)); echo "  ПРОВАЛ: $1 (ожидал '$3', получил '$2')"
  fi
}

# --- fixture: bare "origin" + a local clone that will diverge from it,
# simulating a canonical checkout other sessions have committed into without
# pushing yet ---
git init --quiet --bare "$SANDBOX/origin.git"
git -c init.defaultBranch=main clone --quiet "$SANDBOX/origin.git" "$SANDBOX/work" 2>/dev/null
cd "$SANDBOX/work"
git config user.email test@example.com
git config user.name Test
echo one > tracked.txt && git add tracked.txt && git commit --quiet -m one
git push --quiet origin HEAD:main
# A sibling session's local, not-yet-pushed commit -- this is the drift that
# makes the unconditional ancestry check fail for everyone sharing this repo.
echo two > tracked.txt && git add tracked.txt && git commit --quiet -m "sibling session, not pushed"
cd - >/dev/null

REPO_NAME=$(basename "$SANDBOX/work")
UNPUSHED_SHA=$(git -C "$SANDBOX/work" rev-parse HEAD)

# run_guard <semaphore> -> "checked" | "skipped", via the extracted block
# (sets governance_repo/isolated_worktree/SEM_FILE it reads; `_repo_head_has_
# publish_proof` runs for real -- it's a cheap, local, deterministic git call
# against the fixture repo, and case 4 below needs the real one anyway, which
# a bash function redefinition inside this function would otherwise clobber
# globally for the rest of the script).
run_guard() {
  # shellcheck disable=SC2034  # read inside the dynamically sourced guard_block.sh below
  local governance_repo="$SANDBOX/work" isolated_worktree="" SEM_FILE="$1"
  # shellcheck source=/dev/null
  . "$SANDBOX/guard_block.sh" >/dev/null 2>&1
  if [ "$GOVERNANCE_REPO_HAS_FOOTPRINT" -eq 1 ]; then echo checked; else echo skipped; fi
}

# 1. No commit: claim, no file: claim resolving inside this repo (this
#    session's real shape: only session-transcript paths registered) -> skip.
SEM_NONE="$SANDBOX/sem-none"
{
  echo "wp: WP-484"
  echo "governance_worktree: $SANDBOX/work"
  echo "file: MC-sessions/2026-09/16/some-session/00-writer.md"
} > "$SEM_NONE"
check "ни commit:, ни file: внутри репо -> пропуск (нечего доказывать)" \
  "$(run_guard "$SEM_NONE")" "skipped"

# 2. No commit: claim, but a file: claim that DOES resolve to a real path
#    inside this repo (the "edited + committed directly, forgot note-commit"
#    gap the cold review found in the first version of this fix) -> checked.
SEM_FILE_NO_COMMIT="$SANDBOX/sem-file-no-commit"
{
  echo "wp: WP-484"
  echo "governance_worktree: $SANDBOX/work"
  echo "file: tracked.txt"
} > "$SEM_FILE_NO_COMMIT"
check "file:-заявка внутри репо без commit: -> проверка запускается (закрывает найденную дыру)" \
  "$(run_guard "$SEM_FILE_NO_COMMIT")" "checked"

# 2.5. A file: claim whose relative path exists in BOTH the governance repo
#      AND $IWE_ROOT (the exact CLAUDE.md/AGENTS.md-style collision the
#      second cold review found live) -> ambiguous, no footprint from this
#      claim -> skip (this is what closes the false-block the second review
#      caught: a root-repo edit of a routinely-shared filename must not
#      re-trigger the check for a session that never touched THIS repo).
mkdir -p "$IWE_ROOT"
echo shared-in-root > "$IWE_ROOT/shared.md"
echo shared-in-governance > "$SANDBOX/work/shared.md"
SEM_COLLISION="$SANDBOX/sem-collision"
{
  echo "wp: WP-484"
  echo "governance_worktree: $SANDBOX/work"
  echo "file: shared.md"
} > "$SEM_COLLISION"
check "file:-путь существует и там, и там -> неоднозначность -> пропуск" \
  "$(run_guard "$SEM_COLLISION")" "skipped"

# 3. A commit: claim for this repo -> checked (unchanged from the original
#    design).
SEM_WITH_COMMIT="$SANDBOX/sem-with-commit"
{
  echo "wp: WP-484"
  echo "governance_worktree: $SANDBOX/work"
  echo "commit: ${REPO_NAME} ${UNPUSHED_SHA}"
} > "$SEM_WITH_COMMIT"
check "commit:-заявка -> проверка запускается" \
  "$(run_guard "$SEM_WITH_COMMIT")" "checked"

# 4. And when the real (unstubbed) proof function runs, it still fails closed
#    for a genuinely unpushed commit -- the fix must not weaken protection
#    for a session that actually changed something here.
if _repo_head_has_publish_proof "$SANDBOX/work" "governance checkout" "$SEM_WITH_COMMIT" "" "" 2>/dev/null; then
  PROOF_RESULT="passed"
else
  PROOF_RESULT="failed"
fi
check "непроверенный непушенный коммит -> строгая проверка по-прежнему отказывает" "$PROOF_RESULT" "failed"

echo "session-guard-empty-scope-governance-proof-smoke: прошло $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ]
