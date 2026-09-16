#!/usr/bin/env bash
# session-guard-frozen-quarantine-sentinel-task-smoke.sh — WP-484, 14.09: a
# no-WP session (`wp: unknown`/`day-close`) that simply narrates a real WP-N
# in its own free-text `task:` field (e.g. "разбор находки WP-484") was
# misread by `_frozen_quarantine_commit_barrier()` as evidence the sentinel
# is dodging that WP's freeze -- the check already excluded `file:` lines for
# the same reason (0784e0ac1e) but still scanned `task:` verbatim, turning an
# ordinary parallel session into a repo-wide commit barrier for every agent.
#
# Extracts the function by line range rather than sourcing the whole script
# -- session-guard.sh is a CLI entrypoint (argument parsing + exit at the
# bottom), not a function library, so a plain `source` would execute it.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
START=$(grep -n '^_frozen_quarantine_commit_barrier()' "$GUARD" | head -1 | cut -d: -f1)
END=$(awk -v start="$START" 'NR>=start && /^}/{print NR; exit}' "$GUARD")
[ -n "$START" ] && [ -n "$END" ] || { echo "FAIL: could not locate _frozen_quarantine_commit_barrier in $GUARD" >&2; exit 1; }
FUNC_SRC=$(sed -n "${START},${END}p" "$GUARD")

TEST_ROOT=$(mktemp -d /private/tmp/session-guard-frozen-quarantine-sentinel.XXXXXX 2>/dev/null || mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" config user.email t@test
git -C "$REPO" config user.name test
echo seed > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" -c commit.gpgsign=false commit -q -m seed

SEM_DIR="$TEST_ROOT/sessions"
mkdir -p "$SEM_DIR"

run_barrier() { # <active-semaphores-newline-separated> <out-rc-var>
  local active="$1"
  set +e
  ( cd "$REPO" && ACTIVE_SEMAPHORES="$active" SESSION_DIR="$SEM_DIR" bash -c "
    $FUNC_SRC
    _frozen_quarantine_commit_barrier \"\$ACTIVE_SEMAPHORES\"
  " )
  local rc=$?
  set -e
  printf -v "$2" '%s' "$rc"
}

# Scenario 1 (the live false positive): wp: unknown sentinel, no `file:`
# lines at all, but `task:` narrates a real WP-N in ordinary prose. Must be
# classified as a legitimate no-WP session -- exit 0, no exception raised.
SEM_TASK="$SEM_DIR/claude-code-1-task.open"
cat > "$SEM_TASK" <<'EOF'
agent: claude-code
wp: unknown
task: разбор находки WP-484 из вчерашней сессии
slug: some-slug
session_id: 1
EOF
run_barrier "$SEM_TASK" RC_TASK
if [ "$RC_TASK" != "0" ]; then
  echo "FAIL: a task: line merely mentioning a real WP-N must not quarantine the commit, got rc=$RC_TASK" >&2
  exit 1
fi
echo "OK: wp: unknown sentinel with WP-N only in task: text is not misread as freeze evasion"

# Scenario 2 (regression, must stay caught): the same sentinel with a real
# WP-N leaking through any OTHER field (not file:, not task:) is still
# evidence of evasion and must still raise -- this test would fail loudly if
# a future edit widened the exclusion past file:/task:.
SEM_OTHER="$SEM_DIR/claude-code-2-other.open"
cat > "$SEM_OTHER" <<'EOF'
agent: claude-code
wp: day-close
scheduled_owner: WP-484
slug: some-slug
session_id: 2
EOF
run_barrier "$SEM_OTHER" RC_OTHER
if [ "$RC_OTHER" != "2" ]; then
  echo "FAIL: a real WP-N leaking through a non-file/non-task field must still be caught, got rc=$RC_OTHER" >&2
  exit 1
fi
echo "OK: a real WP-N in a structured field other than file:/task: is still classified as evasion"

# Scenario 3 (existing 0784e0ac1e coverage, kept green): file: lines naming a
# real WP's inbox folder are still excluded, same as before this change.
SEM_FILE="$SEM_DIR/claude-code-3-file.open"
cat > "$SEM_FILE" <<'EOF'
agent: claude-code
wp: unknown
task: подать баг-репорт
slug: some-slug
session_id: 3
file: inbox/WP-484/WP-484.md
EOF
run_barrier "$SEM_FILE" RC_FILE
if [ "$RC_FILE" != "0" ]; then
  echo "FAIL: file: lines naming a real WP's folder must stay excluded (0784e0ac1e), got rc=$RC_FILE" >&2
  exit 1
fi
echo "OK: file: exclusion from 0784e0ac1e still holds"

echo "PASS: wp: unknown/day-close sentinel classifier ignores WP-N mentions in file:/task:, still catches every other leak"
