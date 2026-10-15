#!/usr/bin/env bash
# Regression for WP-484 Ф191 (15.10, peer-session
# 2026-10-15-19-wp484-f191-split-commit-close-fix, Claude+Kimi+Codex):
# _claimed_commits_have_publish_proof gained stderr-only "claim-proof-trace:"
# lines naming which fallback check matched, to diagnose a live bug where
# close and note-commit --forget disagreed on the same claim with no visible
# reason (bug-2026-10-15-session-guard-close-stuck-on-stale-claim-after-mid-session-commit-split.md).
# This smoke test only checks the trace is emitted and names the right
# branch on a full `close` run -- it is not allowed to change pass/fail
# behavior, only add diagnostics on the existing stderr channel.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-claim-trace.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FAILURES=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    FAILURES=$((FAILURES + 1))
  fi
}

GOV="$TEST_ROOT/DS-strategy"
SES="$TEST_ROOT/MC-sessions"
WORK="$TEST_ROOT/work-repo"
mkdir -p "$GOV/inbox/WP-999" "$SES" "$WORK" "$GOV/scripts" "$TEST_ROOT/scripts/lib"
printf '%s\n' 'hypothesis_relation: "tests"' > "$GOV/inbox/WP-999/WP-999.md"
for repo in "$GOV" "$SES" "$WORK"; do
  git -C "$repo" init -q
  git -C "$repo" config user.email test@test.local
  git -C "$repo" config user.name test
  echo seed > "$repo/README"
  git -C "$repo" add README
  git -C "$repo" commit -q -m seed
done

# Fixture stand-ins for external CLIs this close path shells out to --
# same convention the other session-guard tests use (fixture replacement,
# not the real implementation under test).
cat > "$GOV/scripts/close_obligation.py" <<'EOF'
#!/usr/bin/env python3
import json
print(json.dumps({"cancelled": True, "action": "cancel-close", "actor": "fixture"}))
EOF
chmod +x "$GOV/scripts/close_obligation.py"
cat > "$GOV/scripts/process-runner.py" <<'EOF'
#!/usr/bin/env python3
print("{}")
EOF
chmod +x "$GOV/scripts/process-runner.py"
cat > "$TEST_ROOT/scripts/lib/session_receipt_scope.py" <<'EOF'
#!/usr/bin/env python3
print("{}")
EOF
chmod +x "$TEST_ROOT/scripts/lib/session_receipt_scope.py"

for repo_with_origin in "$SES" "$GOV"; do
  bare=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-claim-trace-origin.XXXXXX")
  git -C "$bare" init -q --bare
  git -C "$repo_with_origin" remote add origin "$bare"
  git -C "$repo_with_origin" push -q origin HEAD:refs/heads/main
done

guard() {  # guard <subcommand> [args...]; runs from inside the sessions checkout
  (cd "$SES" && CLAUDE_CODE_SESSION_ID="trace-fixture-e2e" IWE_ROOT="$TEST_ROOT" \
    IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH="" \
    IWE_SESSIONS_ROOT="$SES" bash "$GUARD" "$@")
}

guard open --wp WP-999 --agent fixture --slug trace --task trace >/dev/null 2>&1
SEM=$(find "$TEST_ROOT/.iwe-runtime/sessions" -name 'fixture-*.open' | head -1)
[ -n "$SEM" ] || { echo "FAIL: fixture session did not open"; exit 1; }

ORZ_REL=$(grep '^orz_file: ' "$SEM" | cut -d' ' -f2-)
mkdir -p "$SES/$(dirname "$ORZ_REL")"
cat > "$SES/$ORZ_REL" <<EOF
---
date: 2026-10-15
type: peer-session
wp: WP-999
agent: fixture
duration_h: 0.1
artifacts: []
---

## Главный инсайт
test
## Контекст
test
## Достигнуто
test
## Ключевые решения
test
EOF
git -C "$SES" add "$ORZ_REL"
git -C "$SES" commit -q -m orz
git -C "$SES" push -q origin HEAD:refs/heads/main

# A commit pushed directly to origin/main is an ancestor of origin/main --
# the predicate must match it via the "oid-ancestor" merge-base check (the
# second fallback in the chain, well before supersession/current-tree).
echo one > "$WORK/one.txt"
git -C "$WORK" add one.txt
git -C "$WORK" commit -q -m one
SHA_ONE=$(git -C "$WORK" rev-parse HEAD)
WORK_ORIGIN=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-claim-trace-work-origin.XXXXXX")
git -C "$WORK_ORIGIN" init -q --bare
git -C "$WORK" remote add origin "$WORK_ORIGIN"
git -C "$WORK" push -q origin HEAD:refs/heads/main
guard note-commit "$SHA_ONE" --repo work-repo --agent fixture --slug trace >/dev/null 2>&1

TRACE_OUT=$(guard close --agent fixture --slug trace --wp WP-999 2>&1 1>/dev/null)
check "trace: entry line present" "1" \
  "$(printf '%s\n' "$TRACE_OUT" | grep -cF "claim-proof-trace: work-repo $SHA_ONE excluded=")"
check "trace: names oid-ancestor as the matching check" "1" \
  "$(printf '%s\n' "$TRACE_OUT" | grep -cF "claim-proof-trace: work-repo $SHA_ONE -> OK via oid-ancestor")"
check "trace: does not leak repo_dir path" "0" \
  "$(printf '%s\n' "$TRACE_OUT" | grep -cF "$WORK")"

rm -rf "$WORK_ORIGIN"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: claim-proof-trace smoke (oid-ancestor case)"
  exit 0
fi
echo "FAIL: $FAILURES check(s) failed"
exit 1
