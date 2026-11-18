#!/bin/bash
# test-protocol-artifact-validate-cd-target.sh — WP-484 F313.
#
# A commit spelled `cd <repo> && git commit` or `(cd <repo> && git commit)`
# from a cwd outside that repo used to resolve to no repository, and the
# hook passed a broken DayPlan unvalidated (found by cold review 18.11).
# Pins the bounded grammar agreed in peer session 2026-11-18-04 (Codex):
# a resolvable `cd` target is validated; an unresolvable one blocks only
# while a plan is staged in the governance repo; a foreign repo stays free.

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/protocol-artifact-validate.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

WS="$TMP/ws"
GOV="$WS/DS-strategy"
OTHER="$WS/other-repo"
for repo in "$GOV" "$OTHER"; do
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@test
  git -C "$repo" config user.name test
done
mkdir -p "$GOV/current"

stage_broken_plan() {
  printf '# DayPlan 2026-09-10\nonly a title, no sections\n' > "$GOV/current/DayPlan 2026-09-10.md"
  git -C "$GOV" add "current/DayPlan 2026-09-10.md"
}
unstage_plan() {
  git -C "$GOV" rm -q --cached "current/DayPlan 2026-09-10.md" 2>/dev/null || true
}

decision() { # <cwd> <command> -> prints "block", "warn" or "pass"
  local out
  out=$(jq -n --arg cwd "$1" --arg cmd "$2" \
      '{session_id:"t", cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$cmd}}' \
    | env -u IWE_SCRIPTS IWE_WORKSPACE="$WS" IWE_ROOT="$WS" IWE_GOVERNANCE_REPO="DS-strategy" HOME="$WS" \
        bash "$HOOK" 2>/dev/null)
  if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    printf 'block'
  elif printf '%s' "$out" | jq -e '(.additionalContext // "") | test("не смог определить")' >/dev/null 2>&1; then
    printf 'warn'
  else
    printf 'pass'
  fi
}

expect() { # <expected> <label> <cwd> <command>
  local got
  got=$(decision "$3" "$4")
  if [ "$got" = "$1" ]; then ok "$2"; else bad "$2 (expected $1, got $got)"; fi
}

stage_broken_plan
# cwd = workspace root, which is not a git repository.
expect block "cd <gov> && git commit validates the plan" "$WS" 'cd DS-strategy && git commit -m x'
expect block "(cd \"<gov>\" && git commit) validates the plan" "$WS" '(cd "DS-strategy" && git commit -m x)'
expect block "git -C <gov> commit still validates the plan" "$WS" 'git -C DS-strategy commit -m x'
expect block "cd -P <gov> (option before the path) validates the plan" "$WS" 'cd -P DS-strategy && git commit -m x'
expect block "cd ~/<gov> (HOME expanded) validates the plan" "$OTHER" 'cd ~/DS-strategy && git commit -m x'
mkdir -p "$WS/dir with space" && git -C "$WS/dir with space" init -q
expect pass "cd with escaped spaces resolves to that foreign repo" "$WS" 'cd dir\ with\ space && git commit -m x'
# Unresolvable target while a plan is staged: a warning, never a block — a
# block falsely stopped commits to other repos (cold review 18.11).
expect warn "unresolvable cd target warns while a plan is staged" "$WS" 'cd "$REPO" && git commit -m x'
expect warn "git -C \"\$R\" commit warns while a plan is staged" "$OTHER" 'git -C "$R" commit -m x'
expect warn "nonexistent cd target warns while a plan is staged" "$WS" 'cd no-such-dir && git commit -m x'
expect pass "cd <foreign repo> && git commit is not this hook's business" "$WS" 'cd other-repo && git commit -m x'
expect pass "cd inside the commit message is ignored" "$OTHER" 'git commit -m "then cd DS-strategy"'
unstage_plan
expect pass "unresolvable cd target passes silently when no plan is staged" "$WS" 'cd "$REPO" && git commit -m x'

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
