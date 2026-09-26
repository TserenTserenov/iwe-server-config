#!/bin/bash
# shellcheck disable=SC2016
# Fixture strings below are literal shell-script text for the files under
# test, never expanded by this shell.
# test-hook-selfcheck.sh — regression corpus for hook-selfcheck.sh (WP-544 Ф12
# measure 1). Fixtures are files under a scratch dir, not literal command
# text, so this test cannot itself trip the guards it is testing near.
#
# Run: bash .claude/hooks/tests/test-hook-selfcheck.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hook-selfcheck.sh"
TMP_DIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# fixture <relative-project-path> <content> → creates the file under $TMP_DIR
fixture() {
  local rel="$1" content="$2" path
  path="$TMP_DIR/$rel"
  mkdir -p "$(dirname "$path")"
  printf '%s' "$content" > "$path"
  echo "$path"
}

# payload <cwd> <file_path> → prints a PostToolUse Edit JSON on stdout
payload() {
  python3 -c 'import json,sys; print(json.dumps({
      "hook_event_name": "PostToolUse", "session_id": "self-test-session",
      "tool_name": "Edit", "cwd": sys.argv[1],
      "tool_input": {"file_path": sys.argv[2]}}))' "$1" "$2"
}

# expect_contains <desc> <needle> <cwd> <file_path>
expect_contains() {
  local desc="$1" needle="$2" cwd="$3" file_path="$4" out
  out=$(payload "$cwd" "$file_path" | bash "$HOOK" 2>&1)
  if printf '%s' "$out" | grep -qF -- "$needle"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидали подстроку '$needle', получили: $out)"
  fi
}

# expect_silent <desc> <cwd> <file_path>
expect_silent() {
  local desc="$1" cwd="$2" file_path="$3" out
  out=$(payload "$cwd" "$file_path" | bash "$HOOK" 2>&1)
  if [ -z "$out" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидали тишину, получили: $out)"
  fi
}

VALID_NO_SELFTEST='#!/bin/bash
echo "no self-test here"
'
VALID_WITH_SELFTEST_PASS='#!/bin/bash
if [ "${1:-}" = "--self-test" ]; then
  echo "PASS all"
  exit 0
fi
'
VALID_WITH_SELFTEST_FAIL='#!/bin/bash
if [ "${1:-}" = "--self-test" ]; then
  echo "FAIL case_x: expected deny, got allow" >&2
  exit 1
fi
'
BROKEN_SYNTAX='#!/bin/bash
if [ "x" = "x" ; then
  echo "unterminated if"
'

### (а) битый синтаксис -> FAIL напечатан с путём ###
f=$(fixture ".claude/hooks/broken.sh" "$BROKEN_SYNTAX")
expect_contains "битый синтаксис -> FAIL с путём" \
  "FAIL (syntax): .claude/hooks/broken.sh" "$TMP_DIR" "$f"

### (б) валидный без --self-test -> явное "нет самопроверки" ###
f=$(fixture ".claude/hooks/no-selftest.sh" "$VALID_NO_SELFTEST")
expect_contains "валидный без self-test -> явный пробел" \
  "no --self-test found" "$TMP_DIR" "$f"

### (в) валидный с --self-test, который сам PASS -> отчёт PASS ###
f=$(fixture ".claude/hooks/with-selftest.sh" "$VALID_WITH_SELFTEST_PASS")
chmod +x "$f"
expect_contains "валидный с self-test PASS -> отчёт PASS" \
  "self-test PASS" "$TMP_DIR" "$f"

### (г) путь вне .claude/hooks/ -> тишина ###
f=$(fixture "src/unrelated.sh" "$VALID_NO_SELFTEST")
expect_silent "путь вне .claude/hooks/ -> тишина" "$TMP_DIR" "$f"

### (д) абсолютный путь $CWD/.claude/hooks/x.sh ###
f=$(fixture ".claude/hooks/abs-path.sh" "$VALID_NO_SELFTEST")
expect_contains "абсолютный путь матчит" \
  "no --self-test found" "$TMP_DIR" "$f"

### (е) относительный путь ".claude/hooks/x.sh" (без cwd-префикса) ###
rel_f=".claude/hooks/rel-path.sh"
mkdir -p "$TMP_DIR/.claude/hooks"
printf '%s' "$VALID_NO_SELFTEST" > "$TMP_DIR/$rel_f"
rel_out=$(cd "$TMP_DIR" && payload "$TMP_DIR" "$rel_f" | bash "$HOOK" 2>&1)
if printf '%s' "$rel_out" | grep -qF "no --self-test found"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "FAIL: относительный путь не матчит (получили: $rel_out)"
fi

### (ё) путь с пробелом в имени файла ###
f=$(fixture ".claude/hooks/with space.sh" "$VALID_NO_SELFTEST")
expect_contains "путь с пробелом -> матчит и работает" \
  "no --self-test found" "$TMP_DIR" "$f"

### (ж) ложноположительный: backup/.claude/hooks/x.sh -> тишина ###
f=$(fixture "backup/.claude/hooks/x.sh" "$VALID_NO_SELFTEST")
expect_silent "backup/.claude/hooks/x.sh -> НЕ матчит (ложноположительный тест)" "$TMP_DIR" "$f"

### (з) вложенный путь .claude/hooks/tests/x.sh -> тишина (не прямой файл хуков) ###
f=$(fixture ".claude/hooks/tests/x.sh" "$VALID_NO_SELFTEST")
expect_silent ".claude/hooks/tests/x.sh -> тишина (вложенный путь)" "$TMP_DIR" "$f"

### (и) валидный синтаксис, --self-test сам падает -> FAIL (self-test) с телом ###
f=$(fixture ".claude/hooks/with-failing-selftest.sh" "$VALID_WITH_SELFTEST_FAIL")
chmod +x "$f"
expect_contains "падающий self-test -> отчёт FAIL (self-test)" \
  "FAIL (self-test): .claude/hooks/with-failing-selftest.sh" "$TMP_DIR" "$f"
expect_contains "падающий self-test -> тело ошибки видно в отчёте" \
  "expected deny, got allow" "$TMP_DIR" "$f"

### (й) невалидный (не-JSON) stdin -> хук не падает, молчит (fail-open) ###
out=$(printf 'not json at all' | bash "$HOOK" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "FAIL: невалидный JSON на stdin не дал тихий fail-open (rc=$rc, out=$out)"
fi

### (к) пустой stdin -> хук не падает, молчит (fail-open) ###
out=$(printf '' | bash "$HOOK" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "FAIL: пустой stdin не дал тихий fail-open (rc=$rc, out=$out)"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
