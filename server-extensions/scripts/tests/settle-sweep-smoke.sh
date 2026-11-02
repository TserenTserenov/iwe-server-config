#!/usr/bin/env bash
# settle-sweep-smoke.sh -- WP-484 Ф275: the wrapper around `process-runner.py settle-sweep`.
# A stub runner stands in for the real one; each check compares the printed line.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$HERE/../settle-sweep.sh"
fail=0

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: expected [$2] got [$3]" >&2; fail=1; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/DS-my-strategy/scripts"
RUNNER="$TMP/DS-my-strategy/scripts/process-runner.py"

# 1: no runner file -> silent success
out=$(IWE_ROOT="$TMP" IWE_GOVERNANCE_REPO=DS-my-strategy bash "$SWEEP"); rc=$?
check "no-runner-silent" "0:" "$rc:$out"

# 2: runner reports an advanced card -> one line, applied mode
cat > "$RUNNER" <<'PY'
import json, sys
print(json.dumps({"status": "swept", "shadow": "--shadow" in sys.argv, "counts": {"advanced": 2, "owner_alive": 1}}))
PY
out=$(IWE_ROOT="$TMP" IWE_GOVERNANCE_REPO=DS-my-strategy bash "$SWEEP")
check "applied-line" "Сведение закрытий (применено): advanced: 2" "$out"

# 3: shadow mode passes --shadow and says so
out=$(IWE_SETTLE_MODE=shadow IWE_ROOT="$TMP" IWE_GOVERNANCE_REPO=DS-my-strategy bash "$SWEEP")
check "shadow-line" "Сведение закрытий (тень): advanced: 2" "$out"

# 4: mode off -> nothing, even with a runner
out=$(IWE_SETTLE_MODE=off IWE_ROOT="$TMP" IWE_GOVERNANCE_REPO=DS-my-strategy bash "$SWEEP")
check "off-silent" "" "$out"

# 5: only uninteresting counts -> silent
cat > "$RUNNER" <<'PY'
import json
print(json.dumps({"status": "swept", "counts": {"owner_alive": 3, "no_permit": 1}}))
PY
out=$(IWE_ROOT="$TMP" IWE_GOVERNANCE_REPO=DS-my-strategy bash "$SWEEP")
check "quiet-when-nothing-to-say" "" "$out"

# 6: runner crashes -> silent success
echo 'raise SystemExit(3)' > "$RUNNER"
out=$(IWE_ROOT="$TMP" IWE_GOVERNANCE_REPO=DS-my-strategy bash "$SWEEP"); rc=$?
check "runner-crash-silent" "0:" "$rc:$out"

# 8: the runner is started from the governance repo (it derives its root from cwd)
cat > "$RUNNER" <<'PY'
import json, os
print(json.dumps({"status": "swept", "counts": {"advanced": 1 if os.getcwd().endswith("DS-my-strategy") else 0}}))
PY
out=$(cd "$TMP" && IWE_ROOT="$TMP" IWE_GOVERNANCE_REPO=DS-my-strategy bash "$SWEEP")
check "runs-from-governance-repo" "Сведение закрытий (применено): advanced: 1" "$out"

# 9: lease_error is surfaced, not swallowed
cat > "$RUNNER" <<'PY'
import json
print(json.dumps({"status": "lease_error", "counts": {}}))
PY
out=$(IWE_ROOT="$TMP" IWE_GOVERNANCE_REPO=DS-my-strategy bash "$SWEEP")
check "lease-error-line" "Сведение закрытий: аренда недоступна (lease_error), обход не выполнен" "$out"

# 7: needs_pilot is surfaced
cat > "$RUNNER" <<'PY'
import json
print(json.dumps({"status": "swept", "counts": {"needs_pilot": 2}}))
PY
out=$(IWE_ROOT="$TMP" IWE_GOVERNANCE_REPO=DS-my-strategy bash "$SWEEP")
check "needs-pilot-line" "Сведение закрытий (применено): needs_pilot: 2" "$out"

exit "$fail"
