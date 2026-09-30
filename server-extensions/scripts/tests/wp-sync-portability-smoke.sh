#!/usr/bin/env bash
# wp-sync-portability-smoke.sh -- WP-561 wave 0: Sync Gate scripts must work on a
# template install that has no DS-my-strategy (governance repo auto-discovery)
# and no scripts/lib/git-sync-status.sh (checker_unavailable is a warning, not
# exit 3). Throwaway sandboxes only.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
fails=0
assert() { if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails+1)); fi; }
contains() { if printf '%s' "$1" | grep -qF -- "$2"; then echo "  ok   $3"; else echo "  FAIL $3 (missing '$2')"; fails=$((fails+1)); fi; }

# Workspace whose governance repo is called DS-strategy (no DS-my-strategy anywhere).
WS="$SANDBOX/ws"; GOV="$WS/DS-strategy"
mkdir -p "$GOV/docs" "$GOV/inbox/WP-9201" "$GOV/archive/wp-contexts"
printf '| WP | P | Название | Статус |\n|---|---|---|---|\n| 9201 | P1 | **Fixture 9201** | 🔄 |\n' > "$GOV/docs/WP-REGISTRY.md"
printf -- '---\nwp: 9201\ntitle: "Fixture WP-9201"\nstatus: in_progress\ncreated: 2026-09-01\n---\n# WP-9201\n\n## Осталось\n\n**Что дальше:**\n- [ ] task\n' > "$GOV/inbox/WP-9201/WP-9201.md"
git -C "$GOV" init -q -b main
git -C "$GOV" add -A && git -C "$GOV" -c user.name=t -c user.email=t@t commit -qm seed
unset IWE_GOVERNANCE_REPO

echo "scenario A: wp-archive-trigger-check finds the governance repo without DS-my-strategy"
out=$(bash "$ROOT/scripts/wp-archive-trigger-check.sh" 9201 "$WS" 2>&1); rc=$?
assert "$rc" "0" "exit 0"
contains "$out" "line_count=" "reads the card from DS-strategy"

echo "scenario B: wp-archive-closed-phases.py finds the governance repo"
out=$(IWE_WORKSPACE="$WS" python3 "$ROOT/scripts/wp-archive-closed-phases.py" 9201 --json 2>&1)
contains "$out" "$GOV/inbox/WP-9201/WP-9201.md" "card path resolved under DS-strategy"

echo "scenario C: wp-reopen-gate resolves the governance repo (actualize reaches the fetch step, past repo and card lookup)"
out=$(cd "$SANDBOX" && IWE_ROOT="$WS" bash "$ROOT/scripts/wp-reopen-gate.sh" actualize --wp 9201 --session-id s1 2>&1); rc=$?
assert "$rc" "1" "exit 1 (no origin in the fixture)"
contains "$out" "git fetch origin main" "failed at fetch, so repo and card were found in DS-strategy"

echo "scenario D: explicit IWE_GOVERNANCE_REPO keeps working (our install)"
mkdir -p "$WS/DS-my-strategy/docs" "$WS/DS-my-strategy/inbox/WP-9201"
cp "$GOV/docs/WP-REGISTRY.md" "$WS/DS-my-strategy/docs/"; cp "$GOV/inbox/WP-9201/WP-9201.md" "$WS/DS-my-strategy/inbox/WP-9201/"
out=$(IWE_GOVERNANCE_REPO=DS-my-strategy bash "$ROOT/scripts/wp-archive-trigger-check.sh" 9201 "$WS" 2>&1); rc=$?
assert "$rc" "0" "exit 0 with explicit repo"
rm -rf "$WS/DS-my-strategy"

echo "scenario E: wp-sync-bundle without scripts/lib/git-sync-status.sh -> warning + explicit status, exit 0"
TREE="$SANDBOX/tree"; mkdir -p "$TREE/.claude/scripts" "$TREE/scripts/lib"
cp "$ROOT"/.claude/scripts/wp-sync-bundle.sh "$ROOT"/.claude/scripts/wp-phase-digest.sh "$TREE/.claude/scripts/"
cp "$ROOT/scripts/lib/find-python3.sh" "$TREE/scripts/lib/"
out=$(IWE_WORKSPACE="$WS" bash "$TREE/.claude/scripts/wp-sync-bundle.sh" WP-9201 2>"$SANDBOX/err.txt"); rc=$?
assert "$rc" "0" "exit 0 (not 3)"
contains "$out" "GIT_SYNC_STATUS: checker_unavailable" "status line names checker_unavailable"
contains "$out" "GIT_SYNC_GATE: degraded" "explicit degraded gate line"
contains "$(cat "$SANDBOX/err.txt")" "Sync Gate пропущен" "warning on stderr"

echo "scenario F: an explicit IWE_GOVERNANCE_REPO without a registry is used as given, never replaced by a guess (DS-strategy)"
out=$(IWE_GOVERNANCE_REPO=custom-gov bash "$ROOT/scripts/wp-archive-trigger-check.sh" 9201 "$WS" 2>&1)
if printf '%s' "$out" | grep -qF "line_count="; then echo "  FAIL trigger-check read a DS-strategy card although the explicit repo has none"; fails=$((fails+1)); else echo "  ok   trigger-check did not fall back to DS-strategy"; fi
out=$(IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO=custom-gov python3 "$ROOT/scripts/wp-archive-closed-phases.py" 9201 --json 2>&1)
if printf '%s' "$out" | grep -qF "$GOV/inbox/WP-9201/WP-9201.md"; then echo "  FAIL archive script read a DS-strategy card although the explicit repo has none"; fails=$((fails+1)); else echo "  ok   archive script did not fall back to DS-strategy"; fi
out=$(cd "$SANDBOX" && IWE_ROOT="$WS" IWE_GOVERNANCE_REPO=custom-gov bash "$ROOT/scripts/wp-reopen-gate.sh" actualize --wp 9201 --session-id s1 2>&1)
if printf '%s' "$out" | grep -qF "git fetch origin main"; then echo "  FAIL reopen gate found a card in DS-strategy although the explicit repo has none"; fails=$((fails+1)); else echo "  ok   reopen gate did not fall back to DS-strategy"; fi

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s)"; exit 1; fi
echo "PASS: all scenarios"
