#!/bin/bash
# test-session-refs-debt-report.sh -- session_refs_snapshot / session_refs_debt_report
# (WP-484 Ф210, 17.10.2026, пир-сессия Kimi+Codex+Grok).
# Функции извлекаются из scripts/session-guard.sh и проверяются на
# наблюдаемом поведении: снимок no-clobber, отчёт (новые имена / OID
# изменился / чисто / нет снимка), report-only (всегда exit 0).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO_ROOT/scripts/session-guard.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0
check() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $desc (ожидалось '$want', получено '$got')"; fi
}
check_contains() {
  local desc="$1" needle="$2" hay="$3"
  case "$hay" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); echo "FAIL: $desc (не найдено '$needle' в выводе)" ;;
  esac
}

# --- песочница: git-репо + извлечённые функции ---
REPO="$TMP_DIR/repo"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
echo base > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -qm init
git -C "$REPO" branch base-branch
git -C "$REPO" tag base-tag

SNAPDIR="$TMP_DIR/snaps"
mkdir -p "$SNAPDIR"

LIB="$TMP_DIR/lib.sh"
{
  echo '# извлечено из session-guard.sh для изолированного теста'
  sed -n '/^now_iso() {/,/^}/p' "$GUARD"
  echo "REFS_SNAPSHOT_DIR=\"$SNAPDIR\""
  echo "IWE_ROOT=\"$TMP_DIR\""
  sed -n '/^session_refs_snapshot_file() {/,/^}/p' "$GUARD"
  sed -n '/^session_refs_snapshot() {/,/^}/p' "$GUARD"
  sed -n '/^session_refs_debt_report() {/,/^}/p' "$GUARD"
} > "$LIB"

# 1. снимок создаётся и содержит существующие рефы
bash -c ". '$LIB'; session_refs_snapshot '$REPO' claude-code sess1"
SNAP=$(bash -c ". '$LIB'; session_refs_snapshot_file claude-code sess1")
[ -s "$SNAP" ]; check "снимок создан" "0" "$?"
check_contains "снимок: base-branch" "refs/heads/base-branch" "$(cat "$SNAP")"
check_contains "снимок: base-tag" "refs/tags/base-tag" "$(cat "$SNAP")"

# 2. no-clobber: новая ветка после снимка НЕ попадает в файл при повторном open
git -C "$REPO" branch late-branch
bash -c ". '$LIB'; session_refs_snapshot '$REPO' claude-code sess1"
if grep -q 'late-branch' "$SNAP"; then
  check "no-clobber при повторном open" "unchanged" "changed"
else
  check "no-clobber при повторном open" "unchanged" "unchanged"
fi

# 3. отчёт чистый, когда ничего не появилось (late-branch снят, чтобы
#    снимок соответствовал текущему состоянию... нет: снимок sess2 свежий)
git -C "$REPO" branch -D late-branch >/dev/null 2>&1 || true
bash -c ". '$LIB'; session_refs_snapshot '$REPO' claude-code sess2"
SNAP2=$(bash -c ". '$LIB'; session_refs_snapshot_file claude-code sess2")
OUT=$(bash -c ". '$LIB'; session_refs_debt_report '$REPO' '$SNAP2' ''" 2>&1)
RC=$?
check "чистый отчёт: exit 0" "0" "$RC"
check_contains "чистый отчёт: текст" "не появилось" "$OUT"

# 4. новая ветка и тег попадают в отчёт; штатная ветка сессии исключена
git -C "$REPO" branch backup-pre-reset-test
git -C "$REPO" tag temp-tag
git -C "$REPO" branch session-isolate/test
OUT=$(bash -c ". '$LIB'; session_refs_debt_report '$REPO' '$SNAP2' 'session-isolate/test'" 2>&1)
check_contains "отчёт: новая ветка" "refs/heads/backup-pre-reset-test" "$OUT"
check_contains "отчёт: новый тег" "refs/tags/temp-tag" "$OUT"
case "$OUT" in
  *session-isolate/test*) check "отчёт: штатная ветка исключена" "excluded" "present: session-isolate/test" ;;
  *) check "отчёт: штатная ветка исключена" "excluded" "excluded" ;;
esac
check_contains "отчёт: без атрибуции" "принадлежность не установлена" "$OUT"
check_contains "отчёт: оговорка про branch -d" "git branch -d" "$OUT"

# 5. OID изменился — отдельная секция, не смешивается с новыми именами
git -C "$REPO" checkout -q base-branch
echo change >> "$REPO/file.txt"
git -C "$REPO" commit -qam move
git -C "$REPO" checkout -q master 2>/dev/null || git -C "$REPO" checkout -q main
OUT=$(bash -c ". '$LIB'; session_refs_debt_report '$REPO' '$SNAP2' 'session-isolate/test'" 2>&1)
check_contains "OID-секция: пометка" "OID изменился" "$OUT"
check_contains "OID-секция: base-branch" "refs/heads/base-branch" "$OUT"

# 6. нет снимка — одна строка «неполна», exit 0
OUT=$(bash -c ". '$LIB'; session_refs_debt_report '$REPO' '$TMP_DIR/absent.refs' ''" 2>&1)
RC=$?
check "нет снимка: exit 0" "0" "$RC"
check_contains "нет снимка: текст" "не аттестован" "$OUT"

# 7. битый снимок (не git-репо) — неполная проверка, exit 0
NOTREPO="$TMP_DIR/notrepo"
mkdir -p "$NOTREPO"
OUT=$(bash -c ". '$LIB'; session_refs_debt_report '$NOTREPO' '$SNAP2' ''" 2>&1)
RC=$?
check "не-репо: exit 0" "0" "$RC"
check_contains "не-репо: текст" "не аттестован" "$OUT"

echo ""
echo "session-refs-debt-report: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
