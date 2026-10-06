#!/bin/bash
# sync-extensions-auto-partial-gate-smoke.sh — regression coverage for the
# per-file test-gate exclusion in scripts/sync-extensions-auto.sh (WP-530,
# bug-2026-09-16-sync-extensions-test-gate-blocked-by-orphan-dirty-tests.md).
#
# Before this fix, ANY single changed file's failing test cancelled the
# WHOLE tick -- live incidents held 17-28 unrelated files for 2-58+ hours
# behind one flaky test. This test extracts the real gate/revert/commit
# block from the production script (not a reimplementation) and drives it
# against real throwaway git repos, so a future edit that reintroduces the
# all-or-nothing behavior -- or the index-vs-HEAD revert bug found by cold
# review 25.09 -- fails this test instead of shipping.
#
# Usage: bash scripts/tests/sync-extensions-auto-partial-gate-smoke.sh
set -uo pipefail

REPO_ROOT_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_SRC="$REPO_ROOT_SELF/scripts/sync-extensions-auto.sh"
[ -f "$SCRIPT_SRC" ] || { echo "не найден проверяемый скрипт: $SCRIPT_SRC"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ❌ $1 — факт: ${2:-нет данных}"; FAIL=$((FAIL + 1)); }

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/sync-extensions-auto-partial-gate-smoke.XXXXXX")
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Извлекаем РЕАЛЬНЫЙ блок гейта/отката/коммита из продового скрипта (не
# переписываем логику заново — иначе тест проверяет копию, а не код).
GATE_BLOCK="$WORKDIR/gate-block.sh"
awk '/^PUSH_OUT=""/{exit} /^GATE_LOG=\$\(mktemp\)/{p=1} p' "$SCRIPT_SRC" > "$GATE_BLOCK"
[ -s "$GATE_BLOCK" ] || { echo "не удалось извлечь гейт-блок из $SCRIPT_SRC — сдвинулись маркеры-якоря?"; exit 1; }

run_tick() {  # <repo-dir> <source-dir> [gate-failure-log-dir] -> запускает извлечённый блок отдельным процессом
  # Раздельные присваивания, не одной строкой `local a=.. b=$a` -- под set -u
  # более ранняя переменная той же команды local не всегда видна выражению
  # по умолчанию ("${3:-${repo}...}") следующей, живой случай этого же теста.
  local repo="$1"
  local source="$2"
  local gate_log_dir="${3:-${repo}-gate-failures}"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo 'LOG_PREFIX="[test]"'
    echo 'NOTIFY_LIB_AVAILABLE=false'
    echo 'alert() { echo "ALERT[$1]: $2"; }'
    echo 'alert_ok() { echo "ALERT_OK: $1"; }'
    echo 'cleanup_test_env() { :; }'
    echo "REPO_ROOT=\"$repo\""
    echo "SOURCE_SNAPSHOT=\"$source\""
    echo "GATE_FAILURE_LOG_DIR=\"$gate_log_dir\""
    # WP-538 (06.10): gate_detail_text() — реальная функция скрипта, не
    # переписанная заново (тот же принцип, что у GATE_BLOCK выше).
    sed -n '/^gate_detail_text() {/,/^}/p' "$SCRIPT_SRC"
    # cold-review (06.10, High): trap EXIT, не строка после cat "$GATE_BLOCK"
    # -- живой дефект первой версии фикса: GATE_BLOCK содержит собственный
    # "exit 0" на ветке "все файлы исключены" (test-gate), который обходил
    # любую диагностику, дописанную ПОСЛЕ блока, и тест читал протухший след
    # от предыдущего сценария. trap переживает и явный exit, и обычное
    # завершение скрипта.
    echo "trap 'echo \"\${GATE_LOG:-}\" > \"$WORKDIR/last-gate-log-path.txt\"' EXIT"
    echo 'cd "$REPO_ROOT"'
    echo 'CHANGED=$(git status --porcelain server-extensions/)'
    echo 'FILE_COUNT=$(echo "$CHANGED" | wc -l | tr -d " ")'
    echo 'FILE_LIST=$(echo "$CHANGED" | awk "{print \$2}" | head -5 | tr "\n" ", ")'
    cat "$GATE_BLOCK"
  } > "$WORKDIR/tick.sh"
  bash "$WORKDIR/tick.sh" > "$WORKDIR/tick.out" 2>&1
  echo "$?" > "$WORKDIR/tick.exit"
}

make_source_file() {  # <source-dir> <script-name> <exit-code>
  local src="$1" name="$2" rc="$3"
  mkdir -p "$src/scripts/tests"
  printf 'echo "%s content"\n' "$name" > "$src/scripts/$name.sh"
  printf '#!/usr/bin/env bash\nexit %s\n' "$rc" > "$src/scripts/tests/${name}-smoke.sh"
  chmod +x "$src/scripts/tests/${name}-smoke.sh"
}

# --- Сценарий 1: смешанный тик — тест foo проходит, тест bar падает, baz --
#     без теста вообще. Ожидание: foo и baz уезжают одним коммитом, bar
#     откатывается к старому содержимому и НЕ попадает в коммит.
S1_SRC="$WORKDIR/s1-source"; S1_REPO="$WORKDIR/s1-repo"
mkdir -p "$S1_REPO/server-extensions/scripts"
make_source_file "$S1_SRC" foo 0
make_source_file "$S1_SRC" bar 1
printf 'echo "baz content"\n' > "$S1_SRC/scripts/baz.sh"  # no sibling test
git -C "$S1_REPO" init -q
git -C "$S1_REPO" config user.email t@t.local
git -C "$S1_REPO" config user.name t
echo "foo old" > "$S1_REPO/server-extensions/scripts/foo.sh"
echo "bar old" > "$S1_REPO/server-extensions/scripts/bar.sh"
git -C "$S1_REPO" add server-extensions/
git -C "$S1_REPO" commit -q -m baseline
echo "foo content" > "$S1_REPO/server-extensions/scripts/foo.sh"
echo "bar content" > "$S1_REPO/server-extensions/scripts/bar.sh"
echo "baz content" > "$S1_REPO/server-extensions/scripts/baz.sh"

run_tick "$S1_REPO" "$S1_SRC"
[ "$(cat "$S1_REPO/server-extensions/scripts/foo.sh")" = "foo content" ] \
  && ok "смешанный тик: файл с проходящим тестом уехал" \
  || bad "смешанный тик: файл с проходящим тестом уехал" "$(cat "$S1_REPO/server-extensions/scripts/foo.sh")"
[ "$(cat "$S1_REPO/server-extensions/scripts/baz.sh")" = "baz content" ] \
  && ok "смешанный тик: файл без теста уехал как раньше" \
  || bad "смешанный тик: файл без теста уехал" "$(cat "$S1_REPO/server-extensions/scripts/baz.sh" 2>&1)"
[ "$(cat "$S1_REPO/server-extensions/scripts/bar.sh")" = "bar old" ] \
  && ok "смешанный тик: файл с провалившимся тестом откачен к старому" \
  || bad "смешанный тик: файл с провалившимся тестом откачен" "$(cat "$S1_REPO/server-extensions/scripts/bar.sh")"
git -C "$S1_REPO" diff --quiet HEAD -- server-extensions/scripts/bar.sh \
  && ok "смешанный тик: провалившийся файл не в коммите" \
  || bad "смешанный тик: провалившийся файл не в коммите" "$(git -C "$S1_REPO" status --porcelain -- server-extensions/scripts/bar.sh)"
git -C "$S1_REPO" show --stat HEAD | grep -q "foo.sh" \
  && ok "смешанный тик: коммит реально содержит прошедший файл" \
  || bad "смешанный тик: коммит содержит foo.sh" "$(git -C "$S1_REPO" show --stat HEAD)"

# WP-538 (06.10): полный вывод провалившегося теста сохраняется постоянно,
# и алерт test-gate-partial ссылается на тот же файл.
S1_PERSISTED=$(find "${S1_REPO}-gate-failures" -maxdepth 1 -name '*.log' 2>/dev/null | head -1)
[ -n "$S1_PERSISTED" ] && grep -q "GATE FAIL:" "$S1_PERSISTED" \
  && ok "смешанный тик: полный вывод провалившегося теста сохранён в постоянный файл" \
  || bad "смешанный тик: полный вывод сохранён" "${S1_PERSISTED:-(файл не создан)}"
[ -n "$S1_PERSISTED" ] && grep -F "ALERT[test-gate-partial]" "$WORKDIR/tick.out" | grep -qF "$S1_PERSISTED" \
  && ok "смешанный тик: алерт test-gate-partial ссылается на сохранённый файл" \
  || bad "смешанный тик: алерт ссылается на файл" "$(grep -F 'ALERT[test-gate-partial]' "$WORKDIR/tick.out")"

# --- Сценарий 2: провалились ВСЕ изменённые файлы — тик завершается чисто --
#     (exit 0, не ошибка), коммита нет вообще.
S2_SRC="$WORKDIR/s2-source"; S2_REPO="$WORKDIR/s2-repo"
mkdir -p "$S2_REPO/server-extensions/scripts"
make_source_file "$S2_SRC" bar 1
git -C "$S2_REPO" init -q
git -C "$S2_REPO" config user.email t@t.local
git -C "$S2_REPO" config user.name t
echo "bar old" > "$S2_REPO/server-extensions/scripts/bar.sh"
git -C "$S2_REPO" add server-extensions/
git -C "$S2_REPO" commit -q -m baseline
BEFORE_SHA=$(git -C "$S2_REPO" rev-parse HEAD)
echo "bar content" > "$S2_REPO/server-extensions/scripts/bar.sh"

run_tick "$S2_REPO" "$S2_SRC"
[ "$(cat "$WORKDIR/tick.exit")" = "0" ] \
  && ok "все файлы провалились: тик завершается чисто (exit 0), не ошибкой" \
  || bad "все файлы провалились: exit 0" "$(cat "$WORKDIR/tick.exit")"
[ "$(git -C "$S2_REPO" rev-parse HEAD)" = "$BEFORE_SHA" ] \
  && ok "все файлы провалились: коммита нет вообще" \
  || bad "все файлы провалились: HEAD не сдвинулся" "$(git -C "$S2_REPO" log --oneline -1)"

# WP-538 (06.10): то же для ветки "все файлы исключены" (класс алерта test-gate).
S2_PERSISTED=$(find "${S2_REPO}-gate-failures" -maxdepth 1 -name '*.log' 2>/dev/null | head -1)
[ -n "$S2_PERSISTED" ] && grep -q "GATE FAIL:" "$S2_PERSISTED" \
  && ok "все файлы провалились: полный вывод сохранён в постоянный файл" \
  || bad "все файлы провалились: полный вывод сохранён" "${S2_PERSISTED:-(файл не создан)}"
[ -n "$S2_PERSISTED" ] && grep -F "ALERT[test-gate]" "$WORKDIR/tick.out" | grep -qF "$S2_PERSISTED" \
  && ok "все файлы провалились: алерт test-gate ссылается на сохранённый файл" \
  || bad "все файлы провалились: алерт ссылается на файл" "$(grep -F 'ALERT[test-gate]' "$WORKDIR/tick.out")"

# --- Сценарий 6 (WP-538, 06.10, требование Codex peer-review): постоянное
#     сохранение не удалось (директория недоступна для записи) -- временный
#     $GATE_LOG не должен удаляться, алерт должен честно сослаться на него
#     с оговоркой о недолгом сроке жизни, не на несуществующий постоянный путь.
S6_SRC="$WORKDIR/s6-source"; S6_REPO="$WORKDIR/s6-repo"
mkdir -p "$S6_REPO/server-extensions/scripts"
make_source_file "$S6_SRC" bar 1
git -C "$S6_REPO" init -q
git -C "$S6_REPO" config user.email t@t.local
git -C "$S6_REPO" config user.name t
echo "bar old" > "$S6_REPO/server-extensions/scripts/bar.sh"
git -C "$S6_REPO" add server-extensions/
git -C "$S6_REPO" commit -q -m baseline
echo "bar content" > "$S6_REPO/server-extensions/scripts/bar.sh"

S6_GATE_DIR="$WORKDIR/s6-gate-failures-unwritable"
mkdir -p "$S6_GATE_DIR"
chmod 555 "$S6_GATE_DIR"  # read-only: mkdir -p внутри уже существующей директории не поможет, cp должен отказать
run_tick "$S6_REPO" "$S6_SRC" "$S6_GATE_DIR/sub"  # поддиректория не создастся -- именно это и проверяем
chmod 755 "$S6_GATE_DIR"  # вернуть права, чтобы trap cleanup мог удалить WORKDIR
[ -z "$(find "$S6_GATE_DIR/sub" -maxdepth 1 -name '*.log' 2>/dev/null)" ] \
  && ok "сохранение не удалось: постоянный файл не создан (как и ожидалось)" \
  || bad "сохранение не удалось: постоянный файл действительно не создан" "$(find "$S6_GATE_DIR" -type f)"
# cold-review (06.10, High): главная заявленная гарантия этого сценария —
# что временный $GATE_LOG НЕ удаляется при неудачном постоянном сохранении
# (это единственный оставшийся экземпляр полного вывода). Мутационный тест
# ревьюера подтвердил: без этой проверки откат на безусловный rm -f всё
# равно проходит весь suite.
S6_GATE_LOG=$(cat "$WORKDIR/last-gate-log-path.txt" 2>/dev/null)
[ -n "$S6_GATE_LOG" ] && [ -e "$S6_GATE_LOG" ] \
  && ok "сохранение не удалось: временный \$GATE_LOG реально выжил на диске" \
  || bad "сохранение не удалось: временный \$GATE_LOG выжил" "путь='${S6_GATE_LOG:-(пусто)}'"
grep -qF "WARN: не удалось сохранить полный вывод гейта" "$WORKDIR/tick.out" \
  && ok "сохранение не удалось: скрипт честно предупредил в лог" \
  || bad "сохранение не удалось: предупреждение в лог" "$(cat "$WORKDIR/tick.out")"
grep -F "ALERT[test-gate]" "$WORKDIR/tick.out" | grep -qF "полный вывод не сохранён постоянно" \
  && ok "сохранение не удалось: алерт честно говорит про временный путь, не про несуществующий постоянный" \
  || bad "сохранение не удалось: алерт честен" "$(grep -F 'ALERT[test-gate]' "$WORKDIR/tick.out")"

# --- Сценарий 7 (WP-538, 06.10): ротация 14 дней -- старый файл удаляется,
#     свежий (только что сохранённый этим же тиком) остаётся.
S7_SRC="$WORKDIR/s7-source"; S7_REPO="$WORKDIR/s7-repo"
mkdir -p "$S7_REPO/server-extensions/scripts"
make_source_file "$S7_SRC" bar 1
git -C "$S7_REPO" init -q
git -C "$S7_REPO" config user.email t@t.local
git -C "$S7_REPO" config user.name t
echo "bar old" > "$S7_REPO/server-extensions/scripts/bar.sh"
git -C "$S7_REPO" add server-extensions/
git -C "$S7_REPO" commit -q -m baseline
echo "bar content" > "$S7_REPO/server-extensions/scripts/bar.sh"

S7_GATE_DIR="${S7_REPO}-gate-failures"
mkdir -p "$S7_GATE_DIR"
S7_OLD_FILE="$S7_GATE_DIR/20260101T000000Z-99999.log"
echo "old failure, should be rotated away" > "$S7_OLD_FILE"
touch -t 202601010000 "$S7_OLD_FILE"  # 15+ дней в прошлом относительно "сегодня" этого теста

run_tick "$S7_REPO" "$S7_SRC"
[ ! -e "$S7_OLD_FILE" ] \
  && ok "ротация: файл старше 14 дней удалён" \
  || bad "ротация: старый файл удалён" "$(find "$S7_GATE_DIR" -type f -exec ls -la {} \;)"
[ "$(find "$S7_GATE_DIR" -maxdepth 1 -name '*.log' | wc -l | tr -d ' ')" = "1" ] \
  && ok "ротация: свежий файл этого тика остался" \
  || bad "ротация: свежий файл остался" "$(find "$S7_GATE_DIR" -type f)"

# --- Сценарий 3 (cold review 25.09, Critical): предыдущий тик успел сделать
#     `git add`, но упал до `git commit` (крах/сбой диска) -- в индексе
#     остался чужой, никогда не закоммиченный вариант файла. Откат должен
#     вернуть РЕАЛЬНОЕ содержимое HEAD, а не эту "зависшую" версию из
#     индекса, и не должен оставлять файл в индексе.
S3_SRC="$WORKDIR/s3-source"; S3_REPO="$WORKDIR/s3-repo"
mkdir -p "$S3_REPO/server-extensions/scripts"
make_source_file "$S3_SRC" foo 1
git -C "$S3_REPO" init -q
git -C "$S3_REPO" config user.email t@t.local
git -C "$S3_REPO" config user.name t
echo "foo v1 (HEAD)" > "$S3_REPO/server-extensions/scripts/foo.sh"
git -C "$S3_REPO" add server-extensions/
git -C "$S3_REPO" commit -q -m baseline
echo "foo v2 (stale, staged by a crashed prior run, never committed)" > "$S3_REPO/server-extensions/scripts/foo.sh"
git -C "$S3_REPO" add server-extensions/scripts/foo.sh
echo "foo content" > "$S3_REPO/server-extensions/scripts/foo.sh"  # this tick's fresh sync (v3)

run_tick "$S3_REPO" "$S3_SRC"
[ "$(cat "$S3_REPO/server-extensions/scripts/foo.sh")" = "foo v1 (HEAD)" ] \
  && ok "зависший индекс: откат вернул настоящий HEAD, не мусор из индекса" \
  || bad "зависший индекс: откат вернул HEAD" "$(cat "$S3_REPO/server-extensions/scripts/foo.sh")"
[ -z "$(git -C "$S3_REPO" status --porcelain -- server-extensions/scripts/foo.sh)" ] \
  && ok "зависший индекс: файл больше не висит в индексе" \
  || bad "зависший индекс: индекс чист" "$(git -C "$S3_REPO" status --porcelain -- server-extensions/scripts/foo.sh)"

# --- Сценарий 4: то же самое, но файл был НЕ закоммичен вообще ни разу
#     (новый файл), а в индексе всё равно завис мусор от крашнутого тика.
S4_SRC="$WORKDIR/s4-source"; S4_REPO="$WORKDIR/s4-repo"
mkdir -p "$S4_REPO/server-extensions/scripts"
make_source_file "$S4_SRC" newfile 1
git -C "$S4_REPO" init -q
git -C "$S4_REPO" config user.email t@t.local
git -C "$S4_REPO" config user.name t
git -C "$S4_REPO" commit -q -m baseline --allow-empty
echo "stale staged version, never committed" > "$S4_REPO/server-extensions/scripts/newfile.sh"
git -C "$S4_REPO" add server-extensions/scripts/newfile.sh
echo "newfile content" > "$S4_REPO/server-extensions/scripts/newfile.sh"  # this tick's fresh sync

run_tick "$S4_REPO" "$S4_SRC"
[ -z "$(git -C "$S4_REPO" status --porcelain -- server-extensions/scripts/newfile.sh)" ] \
  && ok "зависший индекс, никогда не коммиченный файл: полностью убран" \
  || bad "зависший индекс, никогда не коммиченный файл: убран" "$(git -C "$S4_REPO" status --porcelain -- server-extensions/scripts/newfile.sh)"
[ ! -e "$S4_REPO/server-extensions/scripts/newfile.sh" ] \
  && ok "зависший индекс, никогда не коммиченный файл: не осталось на диске" \
  || bad "зависший индекс, никогда не коммиченный файл: не осталось на диске" "$(cat "$S4_REPO/server-extensions/scripts/newfile.sh")"

# --- Сценарий 5 (cold review 25.09, High): предупреждение о частичном
#     исключении не должно само себя гасить в том же прогоне, если тик всё
#     равно доходит до общего alert_ok() (успешный пуш остальных файлов).
SBXSTATE="$WORKDIR/notify-state"
mkdir -p "$SBXSTATE"
NOTIFY_LIB="$HOME/IWE/DS-my-strategy/scripts/lib/notification-render.sh"
if [ -f "$NOTIFY_LIB" ]; then
  S5_SRC="$WORKDIR/s5-source"; S5_REPO="$WORKDIR/s5-repo"
  mkdir -p "$S5_REPO/server-extensions/scripts"
  make_source_file "$S5_SRC" foo 0
  make_source_file "$S5_SRC" bar 1
  git -C "$S5_REPO" init -q
  git -C "$S5_REPO" config user.email t@t.local
  git -C "$S5_REPO" config user.name t
  echo "foo old" > "$S5_REPO/server-extensions/scripts/foo.sh"
  echo "bar old" > "$S5_REPO/server-extensions/scripts/bar.sh"
  git -C "$S5_REPO" add server-extensions/
  git -C "$S5_REPO" commit -q -m baseline
  echo "foo content" > "$S5_REPO/server-extensions/scripts/foo.sh"
  echo "bar content" > "$S5_REPO/server-extensions/scripts/bar.sh"

  ALERT_CLASSES_LINE=$(grep -m1 "^ALERT_CLASSES=" "$SCRIPT_SRC")
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo 'LOG_PREFIX="[test]"'
    echo "export DS_PUBLISH_ADMISSION_DIR=\"$SBXSTATE\""
    echo ". \"$NOTIFY_LIB\""
    echo 'NOTIFY_LIB_AVAILABLE=true'
    echo "$ALERT_CLASSES_LINE"
    echo 'NOTIFY_ESCALATION_URGENT_AFTER_SEC="${NOTIFY_ESCALATION_URGENT_AFTER_SEC:-21600}"'
    echo 'NOTIFY_ESCALATION_URGENT_REPEAT_MIN="${NOTIFY_ESCALATION_URGENT_REPEAT_MIN:-1440}"'
    echo 'send_telegram() { :; }'
    sed -n '/^alert() {/,/^}/p' "$SCRIPT_SRC"
    sed -n '/^alert_ok() {/,/^}/p' "$SCRIPT_SRC"
    sed -n '/^gate_detail_text() {/,/^}/p' "$SCRIPT_SRC"
    echo "REPO_ROOT=\"$S5_REPO\""
    echo "SOURCE_SNAPSHOT=\"$S5_SRC\""
    echo "GATE_FAILURE_LOG_DIR=\"${S5_REPO}-gate-failures\""
    echo 'cd "$REPO_ROOT"'
    echo 'cleanup_test_env() { :; }'
    echo 'CHANGED=$(git status --porcelain server-extensions/)'
    echo 'FILE_COUNT=$(echo "$CHANGED" | wc -l | tr -d " ")'
    echo 'FILE_LIST=$(echo "$CHANGED" | awk "{print \$2}" | head -5 | tr "\n" ", ")'
    cat "$GATE_BLOCK"
    echo 'alert_ok "success"'
  } > "$WORKDIR/tick5.sh"
  bash "$WORKDIR/tick5.sh" > "$WORKDIR/tick5.out" 2>&1
  [ -f "$SBXSTATE/incidents/sync-extensions-auto-test-gate-partial.state" ] \
    && ok "частичный провал: предупреждение переживает alert_ok() в том же тике" \
    || bad "частичный провал: предупреждение переживает alert_ok()" "$(cat "$WORKDIR/tick5.out")"
else
  echo "  (пропущено: не найдена $NOTIFY_LIB на этой машине)"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
