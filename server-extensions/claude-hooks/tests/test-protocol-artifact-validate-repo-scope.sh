#!/bin/bash
# test-protocol-artifact-validate-repo-scope.sh — repo-scope regression corpus
# for protocol-artifact-validate.sh (bug-2026-08-26/27, hardened in
# peer-session 2026-08-27-11-wp452-external-developer-access with Codex).
#
# Bug: the hook always validated DayPlan/WeekPlan of the hardcoded governance
# repo, regardless of which repo the intercepted `git commit` actually runs
# in — a commit in an unrelated repo got blocked whenever some other agent
# happened to have a DayPlan/WeekPlan staged in the governance repo at the
# same time. Hardened further after cold-context review found the first
# draft's `-C` extraction wasn't anchored to a specific `git ... commit`
# invocation (see cases 6-8 below).
#
# Feeds synthetic PreToolUse JSON through the hook and checks its stdout: the
# hook always exits 0 (Claude Code hook convention — block/allow is signaled
# through JSON, not the process exit code), emitting `{"decision":"block",...}`
# to block, `{"additionalContext":...}` to warn-without-block, or `{}` to
# pass through silently.
#
# Run: bash .claude/hooks/tests/test-protocol-artifact-validate-repo-scope.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/protocol-artifact-validate.sh"
WORKDIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# --- Fixture repos ---
# "gov": stands in for the governance repo (DS-my-strategy). DayPlan is
# missing a required section ("Разбор заметок" — unrelated to the multiplier
# check) so a block reliably comes from the section check, not incidentally
# from the multiplier one — the multiplier line uses the legitimate mid-day
# placeholder ("считается на закрытии дня"), which this hook now accepts as
# valid (pilot decision 27.08, same session). WeekPlan is otherwise valid so
# a block never comes from an incidental WeekPlan omission.
GOV="$WORKDIR/gov-repo"
mkdir -p "$GOV/current"
git -C "$GOV" init -q
git -C "$GOV" config user.email test@test
git -C "$GOV" config user.name test
cat > "$GOV/current/DayPlan 2026-08-27.md" <<'EOF'
## План на сегодня
- item
## Календарь
| time | event |
|------|-------|
| 10:00 | standup |
## IWE за ночь
nothing
## Итоги вчера
nothing
<details>1</details>
<details>2</details>
<details>3</details>
**Бюджет дня:** ~9h РП / физ 9h / мультипликатор считается на закрытии дня
mandatory check done
EOF
cat > "$GOV/current/WeekPlan W99.md" <<'EOF'
## Повестка
item
## Inbox Triage
item
## План на неделю
item
## Контент-план
item
EOF
git -C "$GOV" add -A
git -C "$GOV" commit -qm init

# "other": stands in for an unrelated repo (FMT-exocortex-template) with its
# own unrelated staged change.
OTHER="$WORKDIR/other-repo"
mkdir -p "$OTHER"
git -C "$OTHER" init -q
git -C "$OTHER" config user.email test@test
git -C "$OTHER" config user.name test
echo "hello" > "$OTHER/readme.md"
git -C "$OTHER" add -A
git -C "$OTHER" commit -qm init

# The hook always exits 0 (Claude Code hook convention) — block vs
# pass-through is signaled through stdout JSON, not the exit code.
run_hook() { # $1 = cwd, $2 = command, $3 = include cwd field (1|0) → prints stdout, stashes stderr in $HOOK_STDERR
  local cwd="$1" cmd="$2" include_cwd="$3" json
  if [ "$include_cwd" = "1" ]; then
    json=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$cmd" "$cwd")
  else
    json=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd")
  fi
  HOOK_STDERR=$(printf '%s' "$json" | IWE_GOVERNANCE_REPO="gov-repo" IWE_WORKSPACE="$WORKDIR" bash "$HOOK" 2>&1 1>/tmp/hook-stdout.$$) || true
  cat /tmp/hook-stdout.$$
  rm -f /tmp/hook-stdout.$$
}

expect() { # $1 = описание, $2 = block|warn|pass, $3 = cwd, $4 = command, $5 = include_cwd
  local out got
  out=$(run_hook "$3" "$4" "${5:-1}")
  if echo "$out" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
    got="block"
  elif echo "$out" | grep -q '"additionalContext"'; then
    got="warn"
  else
    got="pass"
  fi
  if [ "$got" = "$2" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $1 (ожидалось $2, получено $got): $out ${HOOK_STDERR:+| stderr: $HOOK_STDERR}"
  fi
}

# Stage a fresh WeekPlan change in gov so the DayPlan/WeekPlan check is live
# for every scenario below (same as the reported incident: something is
# staged in the governance repo regardless of what's actually being
# committed).
echo "<!-- touch -->" >> "$GOV/current/WeekPlan W99.md"
git -C "$GOV" add current/WeekPlan\ W99.md

# 1. cwd = governance repo, staged WeekPlan there → validate for real
#    (multiplier missing in DayPlan → block).
expect "governance repo, cwd-based" block "$GOV" "git commit -m x"

# 2. Same case, -C form instead of relying on cwd.
expect "governance repo, git -C form" block "$GOV" "git -C $GOV commit -m x"

# 3. THE ORIGINAL BUG: git -C <other repo> commit, cwd = governance repo
#    (which has a staged WeekPlan) → must pass through, not block an
#    unrelated repo.
expect "unrelated repo via -C, gov cwd has staged WeekPlan" pass "$GOV" "git -C $OTHER commit -m x" 1

# 4. Isolated worktree of the governance repo (different path, same
#    git-common-dir) with its own staged WeekPlan → must validate via the
#    actual worktree path, not silently pass through. `git worktree add`
#    already checks out the tracked current/*.md files from the branch —
#    no need to re-copy them.
WORKTREE="$WORKDIR/gov-worktree"
git -C "$GOV" worktree add -q -b test-worktree-branch "$WORKTREE" >/dev/null 2>&1
echo "<!-- touch -->" >> "$WORKTREE/current/WeekPlan W99.md"
git -C "$WORKTREE" add current/
expect "isolated worktree of governance repo" block "$WORKTREE" "git commit -m x"

# 5. No .cwd field at all in the PreToolUse JSON → fail-open, must not block.
expect "missing .cwd field entirely" pass "$GOV" "git commit -m x" 0

# 6. Compound command: first commit targets an unrelated repo, second one
#    (further down the same Bash call) targets the governance repo — must
#    still find and validate the second one, not stop at the first match
#    (cold-context review counter-example).
expect "compound command, second commit targets governance repo" block "$GOV" \
  "git -C $OTHER commit -m first && git -C $GOV commit -m second"

# 7. `-C` value pulled from an UNRELATED earlier `git ... rev-parse` call in
#    the same compound command must not be mistaken for the actual commit's
#    target — the bare `git commit` here has no `-C` of its own and should
#    resolve via cwd (governance repo) instead.
expect "unrelated earlier git -C rev-parse must not leak into commit's target" block "$GOV" \
  "REPO_ROOT=\$(git -C $OTHER rev-parse --show-toplevel); git commit -m x"

# 8. `-m "... -C ..."` inside a commit message must not be parsed as a `-C`
#    flag — the anchored extraction only looks between `git` and `commit`.
expect "-C mentioned only inside the commit message, not as a flag" block "$GOV" \
  "git commit -m 'resolve via git -C form'"

# 9. No space around `&&` must not let the flags regex swallow the command
#    separator into a `-C` value and merge two invocations into one.
expect "no-space && must not merge two invocations via -C value" pass "$GOV" \
  "git -C $OTHER commit -m x&&git -C $OTHER commit -m y" 1

# 10. `-C "$REPO_ROOT"` (unresolvable shell variable in the literal command
#     text) must fall back to .cwd for that invocation, not fail open
#     wholesale when cwd itself is the governance repo. Single-quoted on
#     purpose — the whole point is that `$REPO_ROOT` reaches the hook as
#     literal, unexpanded text.
# shellcheck disable=SC2016
expect "unresolvable -C variable falls back to cwd" block "$GOV" \
  'git -C "$REPO_ROOT" commit -m x'

# 11. Governance repo itself unresolvable (bad IWE_WORKSPACE) → warn via
#     additionalContext, not a silent, permanent fail-open.
BAD_WORKSPACE="$WORKDIR/does-not-exist"
out=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"cwd":sys.argv[1]}))' "$GOV" \
  | IWE_GOVERNANCE_REPO="gov-repo" IWE_WORKSPACE="$BAD_WORKSPACE" bash "$HOOK" 2>/dev/null)
if echo "$out" | grep -q '"additionalContext"'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "FAIL: unresolvable governance repo should warn via additionalContext: $out"
fi

# 12. A fully valid DayPlan (all required sections present) using the
#     mid-day placeholder phrase instead of a computed multiplier must pass
#     (pilot decision 27.08: the phrase is a legitimate value, not a format
#     error, while the day isn't closed yet).
VALID_GOV="$WORKDIR/valid-gov-repo"
mkdir -p "$VALID_GOV/current"
git -C "$VALID_GOV" init -q
git -C "$VALID_GOV" config user.email test@test
git -C "$VALID_GOV" config user.name test
cat > "$VALID_GOV/current/DayPlan 2026-08-27.md" <<'EOF'
## План на сегодня
- item
## Календарь
| time | event |
|------|-------|
| 10:00 | standup |
## IWE за ночь
nothing
## Разбор заметок
nothing
## Итоги вчера
nothing
<details>1</details>
<details>2</details>
<details>3</details>
**Бюджет дня:** ~9h РП / физ 9h / мультипликатор считается на закрытии дня
mandatory check done
EOF
cat > "$VALID_GOV/current/WeekPlan W99.md" <<'EOF'
## Повестка
item
## Inbox Triage
item
## План на неделю
item
## Контент-план
item
EOF
git -C "$VALID_GOV" add -A
git -C "$VALID_GOV" commit -qm init
echo "<!-- touch -->" >> "$VALID_GOV/current/WeekPlan W99.md"
git -C "$VALID_GOV" add current/WeekPlan\ W99.md
out=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"cwd":sys.argv[1]}))' "$VALID_GOV" \
  | IWE_GOVERNANCE_REPO="valid-gov-repo" IWE_WORKSPACE="$WORKDIR" bash "$HOOK" 2>/dev/null)
if echo "$out" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
  FAIL=$((FAIL+1))
  echo "FAIL: mid-day multiplier placeholder should not block a fully valid DayPlan: $out"
else
  PASS=$((PASS+1))
fi

# --- Pathspec scope (WP-7 Ф107) ---------------------------------------------
# Until now the hook read the WHOLE staged index of the governance repo. On the
# shared Mac checkout several agent sessions stage into that index at the same
# time, so a DayPlan/WeekPlan staged by ANOTHER session blocked a commit that
# did not contain it. `$GOV` still has the foreign WeekPlan staged from above;
# these cases add an unrelated file of "our own" and commit only that.
echo "unrelated change" > "$GOV/notes.md"
git -C "$GOV" add notes.md

# 13. THE Ф107 BUG: commit scoped to an unrelated file while a foreign
#     DayPlan/WeekPlan sits in the same shared index → must pass through.
expect "pathspec-scoped commit of an unrelated file, foreign plan in shared index" pass "$GOV" \
  "git commit -m x -- notes.md"

# 14. The multi-line heredoc commit message this repo uses everywhere — the
#     form that made the previous attempt give up, because normalizing
#     newlines to `;` shreds the message into fake separate commands.
expect "heredoc commit message plus unrelated pathspec" pass "$GOV" \
  "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\nfix: multi-line message\n\nsecond paragraph\nEOF\n)" -- notes.md')"

# 15. Legitimate block preserved: the staged plan file IS in this commit's
#     pathspec and fails validation → must still block.
expect "plan file inside the pathspec still validates" block "$GOV" \
  "git commit -m x -- 'current/WeekPlan W99.md'"

# 16. Legitimate block preserved: a directory pathspec that covers the plan
#     file must not be narrowed away.
expect "directory pathspec covering the plan file still validates" block "$GOV" \
  "git commit -m x -- current/"

# 17. Legitimate block preserved: no pathspec at all means the whole index is
#     committed, plan file included.
expect "bare commit still validates the whole index" block "$GOV" \
  "git commit -m x"

# 18. THE TRAP that makes naive text parsing lose a real block: `--` appears
#     only inside the quoted commit message, so the commit has NO pathspec and
#     the whole index — plan file included — is still at stake.
expect "-- inside the commit message is not a pathspec" block "$GOV" \
  "git commit -m 'see -- current/WeekPlan W99.md for details'"

# 19. Compound command where one of the commits has no pathspec → the plan
#     file may still go in, so validation stays.
expect "compound command with one unscoped commit still validates" block "$GOV" \
  "git commit -m a -- notes.md && git commit -m b"

# 20. Narrowing must not resurrect the cross-repo bug: an unrelated repo's
#     commit still passes through regardless of pathspec.
expect "unrelated repo with pathspec still passes through" pass "$GOV" \
  "git -C $OTHER commit -m x -- readme.md"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
