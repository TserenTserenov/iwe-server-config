#!/usr/bin/env bash
# WP-484, bug-2026-11-17-multiline-note-file-claim-blocks-product-receipt.md, fix 3.
#
# _repo_scope_has_publish_proof refused the close when a neighbouring session
# committed into the shared checkout while the proof ran ("HEAD изменился"):
# that is a race, not evidence about our files. The proof now exits 75 for that
# one case and the bash wrapper repeats it once; every other refusal is final.
#
# The real function body is extracted from session-guard.sh; python3 is replaced
# by a stub that returns scripted exit codes, so only the retry contract is tested.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/publish-proof-race.XXXXXX")
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

awk '
  /^_repo_scope_has_publish_proof\(\) \{/ { active = 1 }
  active {
    print
    if (!inpy && $0 ~ /<<.PY./) { inpy = 1; next }
    if (inpy && $0 == "PY") { inpy = 0; next }
    if (!inpy && $0 == "}") { exit }
  }
' "$GUARD" > "$TEST_ROOT/fn.sh"
grep -q '^_repo_scope_has_publish_proof() {' "$TEST_ROOT/fn.sh" \
  || { echo "FAIL: setup -- function not found in session-guard.sh"; exit 1; }
# shellcheck source=/dev/null
source "$TEST_ROOT/fn.sh"

mkdir -p "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/python3" <<'STUB'
#!/usr/bin/env bash
# Scripted proof: exit codes come from $STUB_CODES (space separated), one per call.
cat >/dev/null
n=$(( $(cat "$STUB_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STUB_COUNT"
set -- $STUB_CODES
code=${!n:-0}
exit "$code"
STUB
chmod +x "$TEST_ROOT/bin/python3"
export STUB_COUNT="$TEST_ROOT/count"
export IWE_ROOT="$TEST_ROOT"

run_proof() {  # run_proof "<scripted codes>" -> sets RC, CALLS, ERR
  rm -f "$STUB_COUNT"
  export STUB_CODES="$1"
  ERR=$(PATH="$TEST_ROOT/bin:$PATH" _repo_scope_has_publish_proof repo role sem remote own other 2>&1 >/dev/null)
  RC=$?
  CALLS=$(cat "$STUB_COUNT" 2>/dev/null || echo 0)
}

run_proof "0"
check "clean proof: one call, success" "1/0" "$CALLS/$RC"

run_proof "75 0"
check "HEAD race then clean: two calls, success" "2/0" "$CALLS/$RC"
check "HEAD race: the retry is announced" "1" "$(printf '%s\n' "$ERR" | grep -c 'повторяю проверку один раз')"

run_proof "75 75 0"
check "HEAD race twice: stops after the second call, still refused" "2/75" "$CALLS/$RC"

run_proof "1 0"
check "ordinary refusal: no retry, refused" "1/1" "$CALLS/$RC"
check "ordinary refusal: no retry notice" "0" "$(printf '%s\n' "$ERR" | grep -c 'повторяю проверку')"

# The proof script itself must send the race through exit 75 and nothing else.
check "proof script: HEAD-changed refusal exits 75" "1" \
  "$(grep -c 'raise SystemExit(75)' "$TEST_ROOT/fn.sh")"
check "proof script: HEAD-changed text not behind refuse()" "0" \
  "$(grep -c 'refuse("HEAD изменился' "$TEST_ROOT/fn.sh")"

if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: publish proof repeats once on a HEAD race and refuses everything else at once"
  exit 0
fi
echo "FAILURES: $FAILURES"
exit 1
