#!/usr/bin/env bash
# wp-sync-bundle-last-report-excerpt-smoke.sh -- WP-484 Ф219 (20.10): the new
# function in wp-sync-bundle.sh that quotes §4/§5 of the latest session's
# report.md, instead of letting an agent trust the card's prose summary of
# it. Isolates latest_session_report_excerpt() with a stub scanner and a
# real report.md fixture -- the scanner itself (wp-session-journal-gaps.*)
# already has its own tests and is not re-tested here.
set -uo pipefail

BUNDLE="$(cd "$(dirname "$0")/../.." && pwd)/.claude/scripts/wp-sync-bundle.sh"
[ -f "$BUNDLE" ] || { echo "FAIL: $BUNDLE not found"; exit 1; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
fails=0
assert_contains() {  # <haystack> <needle> <label>
  if [[ "$1" == *"$2"* ]]; then echo "  ok   $3"; else echo "  FAIL $3 (missing: $2)"; fails=$((fails+1)); fi
}
assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then echo "  ok   $3"; else echo "  FAIL $3 (unexpectedly present: $2)"; fails=$((fails+1)); fi
}

# Extract just the function under test (it only reads env + a stub scanner,
# no need to drag in the rest of the script's `main`/git-sync machinery).
FN_FILE="$SANDBOX/fn.sh"
awk '/^latest_session_report_excerpt\(\) \{/{grab=1} grab{print} grab && /^}/{exit}' "$BUNDLE" > "$FN_FILE"
[ -s "$FN_FILE" ] || { echo "FAIL: function not found in $BUNDLE (renamed?)"; exit 1; }

STUB_DIR="$SANDBOX/scripts"; mkdir -p "$STUB_DIR"
SESSIONS="$SANDBOX/sessions"; mkdir -p "$SESSIONS/2026-10/20"
export IWE_SCRIPTS="$STUB_DIR" IWE_SESSIONS_ROOT="$SESSIONS" IWE_WORKSPACE="$SANDBOX"

echo "scenario A: report.md present -> quotes §4 and §5, not §6/§7"
cat > "$STUB_DIR/wp-session-journal-gaps.sh" <<'EOF'
#!/usr/bin/env bash
echo "  [закрыта] 2026-10/20/fixture-with-report (2026-10-20T08:00:00Z) — report.md есть"
EOF
chmod +x "$STUB_DIR/wp-session-journal-gaps.sh"
mkdir -p "$SESSIONS/2026-10/20/fixture-with-report"
cat > "$SESSIONS/2026-10/20/fixture-with-report/report.md" <<'EOF'
## 3. Отвергнутые альтернативы
- should not appear

## 4. Зафиксированное решение
Decision text fixture.

## 5. Открытые вопросы и эскалации
Open question fixture.

## 6. Реализация и проверка
Should not appear.
EOF
OUT=$(bash -c "source '$FN_FILE'; latest_session_report_excerpt 484")
assert_contains "$OUT" "fixture-with-report/report.md" "cites the folder"
assert_contains "$OUT" "Decision text fixture." "quotes §4"
assert_contains "$OUT" "Open question fixture." "quotes §5"
assert_not_contains "$OUT" "should not appear" "does not leak §3"
assert_not_contains "$OUT" "Should not appear." "does not leak §6"

echo "scenario B: last session has no finalized report -> explicit gap, no fabrication"
cat > "$STUB_DIR/wp-session-journal-gaps.sh" <<'EOF'
#!/usr/bin/env bash
echo "  [открыта] 2026-10/20/fixture-no-report (2026-10-20T09:00:00Z) — отчёта НЕТ"
EOF
OUT=$(bash -c "source '$FN_FILE'; latest_session_report_excerpt 484")
assert_contains "$OUT" "fixture-no-report" "names the gap session"
assert_contains "$OUT" "отчёта НЕТ" "surfaces the real status"
assert_not_contains "$OUT" "## 4." "does not fabricate a decision section"

echo "scenario C: scanner has nothing for this WP -> explicit empty line, no crash"
cat > "$STUB_DIR/wp-session-journal-gaps.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
OUT=$(bash -c "source '$FN_FILE'; latest_session_report_excerpt 484")
assert_contains "$OUT" "нет сессий" "explains the empty case"

echo "scenario D: scanner script missing -> best-effort fallback, not a hard failure"
rm -f "$STUB_DIR/wp-session-journal-gaps.sh"
OUT=$(bash -c "source '$FN_FILE'; latest_session_report_excerpt 484")
assert_contains "$OUT" "недоступен" "explains the missing-scanner case"

echo "scenario E: report has §4 but no §5 (report cut short) -> quotes §4, no crash on missing §5"
cat > "$STUB_DIR/wp-session-journal-gaps.sh" <<'EOF'
#!/usr/bin/env bash
echo "  [закрыта] 2026-10/20/fixture-only-4 (2026-10-20T08:00:00Z) — report.md есть"
EOF
chmod +x "$STUB_DIR/wp-session-journal-gaps.sh"
mkdir -p "$SESSIONS/2026-10/20/fixture-only-4"
cat > "$SESSIONS/2026-10/20/fixture-only-4/report.md" <<'EOF'
## 4. Зафиксированное решение
Decision text fixture, no §5 follows.
EOF
OUT=$(bash -c "source '$FN_FILE'; latest_session_report_excerpt 484")
assert_contains "$OUT" "Decision text fixture, no §5 follows." "quotes §4 when §5 is absent"

echo "scenario F: report has §5 but no §4 (short/early-escalation report) -> quotes §5, no crash on missing §4"
cat > "$STUB_DIR/wp-session-journal-gaps.sh" <<'EOF'
#!/usr/bin/env bash
echo "  [закрыта] 2026-10/20/fixture-only-5 (2026-10-20T08:00:00Z) — report.md есть"
EOF
chmod +x "$STUB_DIR/wp-session-journal-gaps.sh"
mkdir -p "$SESSIONS/2026-10/20/fixture-only-5"
cat > "$SESSIONS/2026-10/20/fixture-only-5/report.md" <<'EOF'
## 5. Открытые вопросы и эскалации
Open question fixture, no §4 precedes.
EOF
OUT=$(bash -c "source '$FN_FILE'; latest_session_report_excerpt 484")
assert_contains "$OUT" "Open question fixture, no §4 precedes." "quotes §5 when §4 is absent"

echo "wp-sync-bundle-last-report-excerpt-smoke: $([ "$fails" -eq 0 ] && echo PASS || echo "FAIL ($fails)")"
exit "$fails"
