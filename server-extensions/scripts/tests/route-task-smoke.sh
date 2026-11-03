#!/usr/bin/env bash
# Regression for WP-485 (bug 2026-11-03): route-task.sh was delivered from the
# template without scripts/lib/common.sh, so every call died on its first
# `source` line before parsing arguments. Two checks: (1) every library the
# script sources relative to its own directory exists next to it — the defect
# class, not only common.sh; (2) the router actually starts, resolves an
# explicit root and reads a catalog.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/scripts/route-task.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/route-task-smoke.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# (1) Sourced libraries delivered together with the script. The patterns match
# the literal text `$SCRIPT_DIR`, so single quotes are intended.
# shellcheck disable=SC2016
sourced=$(grep -E '^[[:space:]]*(source|\.)[[:space:]]+"\$SCRIPT_DIR/lib/[^"]+"' "$SCRIPT" \
  | sed -E 's/.*"\$SCRIPT_DIR\/(lib\/[^"]+)".*/\1/')
[ -n "$sourced" ] || fail "no sourced lib found in route-task.sh — pattern drifted, test proves nothing"
while IFS= read -r lib; do
  [ -r "$ROOT_DIR/scripts/$lib" ] || fail "route-task.sh sources scripts/$lib but it is not delivered"
done <<< "$sourced"

# (2a) --help starts and exits 0. The root is explicit: automatic root
# detection is the subject of the template's own regression test (#1431).
help_out=$(IWE_DIR="$TMP_DIR" bash "$SCRIPT" --help 2>&1) || fail "--help exited non-zero: $help_out"
case "$help_out" in
  *"Маршрутизатор задач IWE"*) ;;
  *) fail "--help did not print the usage header: $help_out" ;;
esac

# (2b) --list against a fixture catalog with an explicit IWE_DIR.
cat > "$TMP_DIR/catalog.yaml" <<'EOF'
total_entries: 1
generated_at: "2026-11-03"
entries:
  - name: smoke-skill
    routing:
      executor: sonnet
      deterministic: false
EOF
list_out=$(IWE_DIR="$TMP_DIR" IWE_EXECUTOR_CATALOG="$TMP_DIR/catalog.yaml" \
  IWE_ROUTER_AUDIT="$TMP_DIR/audit.tsv" IWE_ROUTER_ERRORS="$TMP_DIR/errors.log" \
  bash "$SCRIPT" --list 2>&1) || fail "--list exited non-zero: $list_out"
case "$list_out" in
  *"smoke-skill"*) ;;
  *) fail "--list did not show the fixture entry: $list_out" ;;
esac

echo "PASS: route-task.sh delivered with its libraries, starts, and reads a catalog"
