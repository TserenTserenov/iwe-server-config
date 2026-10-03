#!/usr/bin/env bash
# Regression: an interactive wp-sync-bundle.sh run leaves a wp_sync_run event in
# the shared day ledger (so a session on another host is visible), while the
# nightly batch -- which exports GIT_SYNC_PRECOMPUTED_STATUS -- writes none per card.
# The ledger writer and the card fixtures come from the governance repo checkout
# given in IWE_GOV_CHECKOUT (defaults to the canonical DS-my-strategy).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
GOV="${IWE_GOV_CHECKOUT:-$HOME/IWE/DS-my-strategy}"
BUNDLE="$ROOT/.claude/scripts/wp-sync-bundle.sh"
FIXTURES="$GOV/scripts/tests/wp-pipeline-fixtures/DS-my-strategy"
[ -x "$GOV/scripts/ledger-append.sh" ] && [ -d "$FIXTURES" ] || { echo "SKIP: нет $GOV/scripts/ledger-append.sh или фикстур карточек"; exit 0; }

T=$(mktemp -d)
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "  ✅ $1"; else echo "  ❌ $1 — ожидалось '$2', получено '$3'"; FAIL=$((FAIL + 1)); fi; }

mkdir -p "$T/ws/.claude/state" "$T/interactive" "$T/batch" "$T/bin"
cp -r "$FIXTURES" "$T/ws/"
mkdir -p "$T/ws/DS-my-strategy/scripts"
cp "$GOV/scripts/ledger-append.sh" "$T/ws/DS-my-strategy/scripts/"
cp -r "$GOV/scripts/lib" "$T/ws/DS-my-strategy/scripts/"
# The ledger writer must never start the real publisher.
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"

run_bundle() { # <ledger dir> [env assignments...]
  local ledger="$1"; shift
  env PATH="$T/bin:$PATH" IWE_LEDGER_DIR="$ledger" IWE_WORKSPACE="$T/ws" IWE_GOVERNANCE_REPO=DS-my-strategy "$@" \
    bash "$BUNDLE" WP-9006 >/dev/null 2>&1
}

echo "== interactive run writes wp_sync_run =="
run_bundle "$T/interactive"
check "bundle exit 0" "0" "$?"
EVENTS=$(grep -rh "kind: wp_sync_run" "$T/interactive" 2>/dev/null | wc -l | tr -d ' ')
check "one wp_sync_run event" "1" "$EVENTS"
check "event carries the result" "1" "$(grep -rh "result: SUCCESS" "$T/interactive" 2>/dev/null | wc -l | tr -d ' ')"

echo "== nightly batch (precomputed status) writes none =="
run_bundle "$T/batch" GIT_SYNC_PRECOMPUTED_STATUS=OK
check "bundle exit 0" "0" "$?"
check "no ledger file" "0" "$(find "$T/batch" -type f | wc -l | tr -d ' ')"

echo ""
[[ "$FAIL" -eq 0 ]] && echo "PASS" || echo "FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
