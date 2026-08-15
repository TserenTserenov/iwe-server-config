#!/usr/bin/env bash
# session-guard-card-audit-smoke.sh -- WP-7 Ф76.
# Проверяет контракт fail-closed между session-guard и process-runner audit-cards
# без открытия настоящей сессии и без изменения RUN-карточек.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-card-audit.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/DS-strategy/scripts"

extract_audit_function() {
    sed -n '/^audit_runner_cards() {/,/^}/p' "$GUARD"
}

run_audit() {
    local expected="$1"
    local output rc=0
    output=$(IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy" bash -c '
        GOV_REPO="DS-strategy"
        fail() { echo "FAIL:$1" >&2; exit "${2:-1}"; }
        '"$(extract_audit_function)"$'\n        audit_runner_cards
    ' 2>&1) || rc=$?
    if [ "$rc" -ne "$expected" ]; then
        echo "FAIL: audit returned $rc, expected $expected: $output" >&2
        exit 1
    fi
    printf '%s' "$output"
}

cat > "$TEST_ROOT/DS-strategy/scripts/process-runner.py" <<'PYEOF'
#!/usr/bin/env python3
import os
import sys

assert sys.argv[1:] == ["audit-cards"], sys.argv
if os.environ["AUDIT_MODE"] == "clean":
    print('{"clean": true}')
    raise SystemExit(0)
print('{"clean": false, "findings": [{"problem": "missing_without_retirement"}]}')
raise SystemExit(1)
PYEOF
chmod +x "$TEST_ROOT/DS-strategy/scripts/process-runner.py"

AUDIT_MODE=clean run_audit 0 >/dev/null
OUT=$(AUDIT_MODE=missing run_audit 7)
grep -q 'missing_without_retirement' <<<"$OUT" || { echo "FAIL: finding is hidden: $OUT" >&2; exit 1; }
grep -q 'close остановлен' <<<"$OUT" || { echo "FAIL: close refusal is missing: $OUT" >&2; exit 1; }

echo "PASS: session-guard card audit"
