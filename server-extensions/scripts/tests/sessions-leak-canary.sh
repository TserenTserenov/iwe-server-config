#!/usr/bin/env bash
# sessions-leak-canary.sh <test script>... -- WP-484 Ф274: which tests write into the
# sessions repository they inherited from the shell.
#
# Each test runs with IWE_SESSIONS_ROOT pointing at its own throwaway git repository
# outside any temporary directory, exactly like the live value in an interactive shell.
# Parallel sessions cannot blur the result, unlike watching the real MC-sessions.
# Prints: leaked=<files+commits> blocked=<guard drops> rc=<test exit> <test>.
# The guard writes blocked= through IWE_SESSIONS_SPLIT_LOG: blocked>0 with leaked=0 is the
# positive control that the guard saw the inherited value and refused it.
# Exit: 0 clean, 1 leak, 2 could not measure, 3 no leak but some tests failed.
# Logs stay in the printed directory unless the whole run is clean.
set -uo pipefail

[ "$#" -gt 0 ] || { echo "usage: $0 <test script>..." >&2; exit 2; }
IWE_ROOT_REAL="${IWE_ROOT:-$HOME/IWE}"
RUN_DIR="$IWE_ROOT_REAL/.iwe-runtime/sessions-leak-canary/$$"
mkdir -p "$RUN_DIR" || { echo "cannot create $RUN_DIR" >&2; exit 2; }
export RUN_DIR

run_one() {
  local test_path="$1" name canary log rc=0 changed commits blocked=0
  name="$(basename -- "$test_path").$$"
  canary="$RUN_DIR/$name"
  log="$RUN_DIR/$name.blocked"
  if ! git init -q "$canary"; then
    printf 'unmeasured: git init failed %s\n' "$test_path"
    return 0
  fi
  # perl alarm: macOS has no timeout(1); a hung test must not hold the run.
  IWE_SESSIONS_ROOT="$canary" IWE_SESSIONS_SPLIT_LOG="$log" \
    perl -e 'alarm shift; exec @ARGV' "${CANARY_TEST_TIMEOUT_S:-300}" bash "$test_path" >"$RUN_DIR/$name.out" 2>&1 || rc=$?
  if ! changed=$(git -C "$canary" status --porcelain) || ! commits=$(git -C "$canary" rev-list --all --count); then
    printf 'unmeasured: canary unreadable %s\n' "$test_path"
    return 0
  fi
  [ -f "$log" ] && blocked=$(wc -l <"$log" | tr -d ' ')
  printf 'leaked=%s blocked=%s rc=%s %s\n' "$(( $(printf '%s' "$changed" | grep -c '') + commits ))" "$blocked" "$rc" "$test_path"
}
export -f run_one

RESULTS="$RUN_DIR/results"
printf '%s\0' "$@" | xargs -0 -P "${CANARY_JOBS:-4}" -n 1 bash -c 'run_one "$1"' _ | tee "$RESULTS"

status=0
if [ "$(grep -c '^leaked=' "$RESULTS")" != "$#" ]; then
  echo "UNMEASURED: not every test produced a measurement" >&2
  status=2
fi
if grep '^leaked=' "$RESULTS" | grep -qv '^leaked=0 '; then
  echo "LEAK: tests above wrote into the inherited sessions repository" >&2
  status=1
elif [ "$status" -eq 0 ] && grep -qv ' rc=0 ' "$RESULTS"; then
  echo "FAILED: no leak, but tests above exited non-zero" >&2
  status=3
fi
if [ "$status" -eq 0 ]; then
  rm -rf "$RUN_DIR"
else
  echo "logs: $RUN_DIR" >&2
fi
exit "$status"
