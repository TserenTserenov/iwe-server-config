#!/bin/bash
# Regression test for month-close-scaffold.sh (WP-561, nights 30.09 and 01.10 on tsekh-1).
#
# archive/week-plans holds WeekReport names without a YYYY-MM-DD date ("WeekReport 2026-W31.md").
# Before the fix, `fdate="$(echo "$fname" | grep -oE ...)"` returned 1 for such a name and, under
# `set -euo pipefail`, killed the script silently in section 1c: the facts file was left truncated
# (sections 1d-1g missing) and the month tact recorded `month_close: degraded`.
#
# Run against another copy of the script (e.g. the unfixed one) with
#   MONTH_CLOSE_SCAFFOLD_UNDER_TEST=/path/to/month-close-scaffold.sh bash scripts/test-month-close-scaffold-undated-week-reports.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAFFOLD="${MONTH_CLOSE_SCAFFOLD_UNDER_TEST:-$HERE/month-close-scaffold.sh}"
REAL_GREP="$(command -v grep)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILURES=0
assert() { # assert <description> <command...>: the command must succeed
  local description="$1"; shift
  if "$@"; then
    echo "ok   - $description"
  else
    echo "FAIL - $description"
    FAILURES=$((FAILURES + 1))
  fi
}

# new_workspace <name> <file...>: workspace with a governance repo whose archive/week-plans holds the given files.
new_workspace() {
  local name="$1"; shift
  local dir="$TMP/$name/DS-fixture/archive/week-plans"
  mkdir -p "$dir"
  local file
  for file in "$@"; do : > "$dir/$file"; done
  echo "$TMP/$name"
}

run_scaffold() { # run_scaffold <workspace> [env assignments...]: prints exit code, output lands in $TMP/stdout and $TMP/stderr
  local workspace="$1"; shift
  env "$@" WORKSPACE_DIR="$workspace" IWE_GOVERNANCE_REPO=DS-fixture \
    bash "$SCAFFOLD" --as-of 2026-09 > "$TMP/stdout" 2> "$TMP/stderr"
  echo $?
}

facts_of() { echo "$1/DS-fixture/archive/MonthClose-facts-2026-09.md"; }

# Case 1: dated and undated names mixed, one dated name outside the month.
WS="$(new_workspace mixed "WeekReport 2026-W31.md" "WeekReport 2026-W38.md" "WeekReport W38 2026-09-14.md" "WeekReport W35 2026-08-31.md")"
RC="$(run_scaffold "$WS")"
FACTS="$(facts_of "$WS")"
assert "mixed names: the script exits 0 (got $RC)" test "$RC" -eq 0
assert "mixed names: the last section 1g is written (facts file not truncated)" "$REAL_GREP" -q '^## 1g\.' "$FACTS"
assert "mixed names: the dated in-month report is listed" "$REAL_GREP" -qF -- '- WeekReport W38 2026-09-14.md' "$FACTS"
assert "mixed names: the dated report of another month is not listed" bash -c "! '$REAL_GREP' -qF 'WeekReport W35 2026-08-31.md' '$FACTS'"
assert "mixed names: the two skipped undated names are reported explicitly" "$REAL_GREP" -qF 'без даты YYYY-MM-DD в имени: 2' "$FACTS"

# Case 2: only undated names.
WS="$(new_workspace undated-only "WeekReport 2026-W31.md" "WeekReport 2026-W32.md")"
RC="$(run_scaffold "$WS")"
FACTS="$(facts_of "$WS")"
assert "undated only: the script exits 0 (got $RC)" test "$RC" -eq 0
assert "undated only: section 1g is written" "$REAL_GREP" -q '^## 1g\.' "$FACTS"
assert "undated only: 'no data' is stated for section 1c" "$REAL_GREP" -qF 'PENDING: нет данных (ни один WeekReport' "$FACTS"
assert "undated only: the skipped count is reported" "$REAL_GREP" -qF 'без даты YYYY-MM-DD в имени: 2' "$FACTS"

# Case 3: dated names only (one in the month, one in the next month, one in the previous month): the names of other
# months are not "undated", so there must be no skipped-names line.
WS="$(new_workspace dated-only "WeekReport W38 2026-09-14.md" "WeekReport W40 2026-10-01.md" "WeekReport W35 2026-08-31.md")"
RC="$(run_scaffold "$WS")"
FACTS="$(facts_of "$WS")"
assert "dated only: the script exits 0 (got $RC)" test "$RC" -eq 0
assert "dated only: the in-month report is listed" "$REAL_GREP" -qF -- '- WeekReport W38 2026-09-14.md' "$FACTS"
assert "dated only: reports of the next and previous month are not listed" bash -c "! '$REAL_GREP' -qE 'WeekReport W(40|35) ' '$FACTS'"
assert "dated only: no skipped-names line" bash -c "! '$REAL_GREP' -qF 'без даты YYYY-MM-DD в имени' '$FACTS'"

# Case 3b: extra spaces inside the name: still one file, listed once.
WS="$(new_workspace extra-spaces "WeekReport  W36  2026-09-07 extra.md")"
RC="$(run_scaffold "$WS")"
FACTS="$(facts_of "$WS")"
assert "extra spaces: the script exits 0 (got $RC)" test "$RC" -eq 0
assert "extra spaces: the file is listed exactly once" test "$("$REAL_GREP" -cF 'WeekReport  W36  2026-09-07 extra.md' "$FACTS")" -eq 1

# Case 3c: empty archive/week-plans directory: only the "no data" marker, nothing skipped, file complete.
WS="$(new_workspace empty)"
RC="$(run_scaffold "$WS")"
FACTS="$(facts_of "$WS")"
assert "empty directory: the script exits 0 (got $RC)" test "$RC" -eq 0
assert "empty directory: section 1g is written" "$REAL_GREP" -q '^## 1g\.' "$FACTS"
assert "empty directory: 'no data' is stated for section 1c" "$REAL_GREP" -qF 'PENDING: нет данных (ни один WeekReport' "$FACTS"
assert "empty directory: no skipped-names line" bash -c "! '$REAL_GREP' -qF 'без даты YYYY-MM-DD в имени' '$FACTS'"

# Case 4: a real grep failure (exit code 2) on the date pattern must still abort the script, not be swallowed.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/grep" <<EOF
#!/bin/bash
for arg in "\$@"; do
  [ "\$arg" = '[0-9]{4}-[0-9]{2}-[0-9]{2}' ] && exit 2
done
exec "$REAL_GREP" "\$@"
EOF
chmod +x "$TMP/bin/grep"
WS="$(new_workspace grep-broken "WeekReport W38 2026-09-14.md")"
RC="$(run_scaffold "$WS" "PATH=$TMP/bin:$PATH")"
assert "grep failure (rc 2): the script aborts with a non-zero code (got $RC)" test "$RC" -ne 0

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: month-close-scaffold undated WeekReport names"
else
  echo "FAILED: $FAILURES assertion(s)"
  exit 1
fi
