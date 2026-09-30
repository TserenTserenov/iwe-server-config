#!/usr/bin/env bash
# Regression (WP-530 Ф72): the orphan sweep's cancel-session for a semaphore
# whose pid was reused by a foreign process must not commit into the frozen
# canonical governance checkout. process-runner auto-commits every terminal
# card unless IWE_CARD_AUTOCOMMIT=0; the sweep must pass that flag, and must
# skip (fail closed) against a runner that does not know the flag.
#
# The runner here is a stub with the same observable contract: cancel-session
# flips running cards of the session to cancelled and, unless
# IWE_CARD_AUTOCOMMIT=0, `git add` + `git commit`s them (write_card ->
# _try_auto_commit_terminal_card).

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-sweep-cancel.XXXXXX")
FOREIGN_PID=""
cleanup() {
  [ -z "$FOREIGN_PID" ] || kill "$FOREIGN_PID" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

GOV="$TEST_ROOT/DS-strategy"
SESSION_DIR="$TEST_ROOT/.iwe-runtime/sessions"
TASKS="$GOV/inbox/agent/tasks"
CARD="$TASKS/RUN-quick-close-fixture.md"
mkdir -p "$GOV/scripts" "$GOV/sessions" "$TASKS" "$SESSION_DIR" "$TEST_ROOT/bin"
export IWE_SESSIONS_ROOT="$GOV/sessions"

git -C "$GOV" init -q
git -C "$GOV" config user.email t@example.invalid
git -C "$GOV" config user.name t
echo seed > "$GOV/README.md"
git -C "$GOV" add README.md
git -C "$GOV" commit -q -m seed

cat > "$TEST_ROOT/bin/iwe-tg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_ROOT/bin/iwe-tg"

write_runner() {  # <yes: honours the flag | no: legacy | comment: flag name only in comment/docstring>
  local flag_line=""
  case "$1" in
    yes) flag_line='AUTOCOMMIT = os.environ.get("IWE_CARD_AUTOCOMMIT", "1")' ;;
    comment) flag_line='# TODO: support IWE_CARD_AUTOCOMMIT one day
"""Docs mention IWE_CARD_AUTOCOMMIT=0 but the code never reads it."""
AUTOCOMMIT = "1"' ;;
    *) flag_line='AUTOCOMMIT = "1"  # legacy runner' ;;
  esac
  cat > "$GOV/scripts/process-runner.py" <<EOF
import os, subprocess, sys, pathlib
$flag_line
open(os.environ["RUNNER_CALLED_MARK"], "a").write(" ".join(sys.argv[1:]) + "\n")
assert sys.argv[1] == "cancel-session"
session = sys.argv[3]
for card in pathlib.Path("inbox/agent/tasks").glob("RUN-*.md"):
    text = card.read_text()
    if "status: running" in text and "owner_session_id: " + session in text:
        card.write_text(text.replace("status: running", "status: cancelled"))
        if AUTOCOMMIT != "0":
            subprocess.run(["git", "add", "--", str(card)], check=True)
            subprocess.run(["git", "commit", "-q", "-m", "chore(quick-close): card", "--", str(card)], check=True)
EOF
}

write_card() {
  printf -- '---\nstatus: running\nowner_session_id: %s\n---\n' "$1" > "$CARD"
}

sleep 300 &
FOREIGN_PID=$!
write_semaphore() {  # <session>
  cat > "$SESSION_DIR/claude-code-$1.open" <<EOF
---
agent: claude-code
wp: WP-530
slug: $1
opened_at: 2000-01-01T00:00:00Z
created_at: 2000-01-01T00:00:00Z
session_id: $1
pid: $FOREIGN_PID
---
file: inbox/WP-530/WP-530.md
EOF
}

run_sweep() {
  IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_ZOMBIE_ESCALATE_SEC=1 \
    RUNNER_CALLED_MARK="$TEST_ROOT/runner-called" PATH="$TEST_ROOT/bin:$PATH" \
    /bin/bash "$GUARD" audit --cleanup-orphans 2>&1
}

# Case 1: flag-aware runner. Card is cancelled in place, canon HEAD and the
# set of dirty paths are exactly what they were before the sweep.
write_semaphore sweep-a
write_card sweep-a
write_runner yes
HEAD_BEFORE=$(git -C "$GOV" rev-parse HEAD)
STATUS_BEFORE=$(git -C "$GOV" status --porcelain -uall)
OUT=$(run_sweep) || fail "sweep failed: $OUT"
[ -s "$TEST_ROOT/runner-called" ] || fail "runner was not invoked; the cancel path did not run: $OUT"
grep -q 'cancel-session quick-close sweep-a' "$TEST_ROOT/runner-called" || fail "wrong runner arguments: $(cat "$TEST_ROOT/runner-called")"
grep -q 'status: cancelled' "$CARD" || fail "card was not cancelled (lost or untouched)"
[ "$(git -C "$GOV" rev-parse HEAD)" = "$HEAD_BEFORE" ] || fail "sweep moved canon HEAD (auto-commit ran)"
STATUS_AFTER=$(git -C "$GOV" status --porcelain -uall)
[ "$STATUS_AFTER" = "$STATUS_BEFORE" ] || fail "sweep changed dirty canon paths: before=[$STATUS_BEFORE] after=[$STATUS_AFTER]"
# Idempotence: a second cancel-session over the terminal card changes nothing.
cp "$CARD" "$TEST_ROOT/card.after1"
(cd "$GOV" && IWE_CARD_AUTOCOMMIT=0 RUNNER_CALLED_MARK="$TEST_ROOT/runner-called" python3 scripts/process-runner.py cancel-session quick-close sweep-a)
cmp -s "$CARD" "$TEST_ROOT/card.after1" || fail "repeated cancel-session altered a terminal card"

# Case 2: runner that does not know the flag would auto-commit -> sweep skips.
rm -f "$SESSION_DIR"/*.open "$TEST_ROOT/runner-called" "$CARD"
write_semaphore sweep-b
write_card sweep-b
HEAD_BEFORE=$(git -C "$GOV" rev-parse HEAD)
write_runner no
OUT=$(run_sweep) || fail "sweep failed: $OUT"
[ ! -e "$TEST_ROOT/runner-called" ] || fail "legacy runner was invoked from the frozen canon"
[ "$(git -C "$GOV" rev-parse HEAD)" = "$HEAD_BEFORE" ] || fail "legacy runner moved canon HEAD"
grep -q 'без IWE_CARD_AUTOCOMMIT' <<<"$OUT" || fail "no skip warning for a runner without the flag: $OUT"
grep -q 'status: running' "$CARD" || fail "skipped cancel still touched the card"

# Case 3: the flag name appears ONLY in a comment and a docstring (no os.environ
# read) and the runner always commits: the mention must not count as support.
rm -f "$SESSION_DIR"/*.open "$TEST_ROOT/runner-called" "$CARD"
write_semaphore sweep-c
write_card sweep-c
write_runner comment
HEAD_BEFORE=$(git -C "$GOV" rev-parse HEAD)
OUT=$(run_sweep) || fail "sweep failed: $OUT"
[ ! -e "$TEST_ROOT/runner-called" ] || fail "runner with a comment-only flag mention was invoked from the frozen canon"
[ "$(git -C "$GOV" rev-parse HEAD)" = "$HEAD_BEFORE" ] || fail "comment-only runner moved canon HEAD"
grep -q 'без IWE_CARD_AUTOCOMMIT' <<<"$OUT" || fail "no skip warning for a comment-only flag mention: $OUT"
grep -q 'status: running' "$CARD" || fail "skipped cancel still touched the card (comment-only case)"

echo "PASS: sweep cancel-session runs with IWE_CARD_AUTOCOMMIT=0 (no canon commit, card kept terminal, idempotent) and skips a runner without the flag"
