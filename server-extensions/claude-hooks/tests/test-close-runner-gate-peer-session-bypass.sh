#!/bin/bash
# test-close-runner-gate-peer-session-bypass.sh — close_path=peer-session
# обходит требование раннера (WP-484 Ф118, 19.08.2026, пир-сессия с Codex).
#
# Живой симптом до фикса: пир-сессия каждый раз натыкалась на "process-runner
# нужен вместо закрытия пир-сессии" при обычном finalize-коммите (DP.SC.154
# Шаг 4.5.1) и обходилась через close_obligation.py cancel --action
# close-override + git commit --no-verify. Фикс — session-guard open
# --close-path peer-session записывает протокол закрытия в семафор, гейт
# читает его и структурно пропускает такую сессию, не полагаясь на regex.
#
# Сценарии 9-14 (WP-484, пир-сессия 2026-08-31-37 с Codex+Kimi): регрессия на
# bug-2026-08-31 — тот же класс дефекта, что в тот же день чинили в
# close_obligation.py::_is_peer_session_close_path(). Прежняя реализация
# смотрела только *.open и брала первый файл по недетерминированному порядку
# glob() -- session-guard.sh close переименовывает семафор в *.open.closed при
# штатном закрытии, поэтому именно в момент штатного закрытия дочерней
# пир-сессии её признак peer-session становился невидим. Фикс: все кандидаты
# *.open + *.open.closed, точное совпадение harness_session_id, freshest по
# (opened_at, filename).
#
# Запуск: bash .claude/hooks/tests/test-close-runner-gate-peer-session-bypass.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/close-runner-gate.sh"
SID="test-f118-$$"
SENTINEL_DIR="/tmp/iwe-close-intent"
MARKER_DIR="/tmp/iwe-close-runner-started"
IWE_ROOT_TEST=$(mktemp -d)
SEM_DIR="$IWE_ROOT_TEST/.iwe-runtime/sessions"
mkdir -p "$SEM_DIR"
PASS=0
FAIL=0

# Сессии 9-14 используют свои собственные session_id — список для очистки
# сентинелов/маркеров сверх основного $SID при выходе.
EXTRA_SIDS=(sess-only-closed sess-dual1 sess-dual2 sess-tie-break sess-missing-ts sess-abc)

cleanup() {
  rm -f "$SENTINEL_DIR/$SID.flag" "$MARKER_DIR/$SID.flag"
  local s
  for s in "${EXTRA_SIDS[@]}"; do
    rm -f "$SENTINEL_DIR/$s.flag" "$MARKER_DIR/$s.flag"
  done
  rm -rf "$IWE_ROOT_TEST"
}
trap cleanup EXIT

arm() { # $1 = session_id override (default $SID)
  local sid="${1:-$SID}"
  mkdir -p "$SENTINEL_DIR"
  printf '{"session_id":"%s","created_at":"test"}' "$sid" > "$SENTINEL_DIR/$sid.flag"
  rm -f "$MARKER_DIR/$sid.flag"
}

write_semaphore() {
  # $1 = close_path value
  # $2 = имя файла в SEM_DIR (default claude-code-fake.open — как раньше)
  # $3 = session_id, попадает в поле harness_session_id (default $SID)
  # $4 = значение opened_at; "NONE" -- поле опускается вовсе (сценарий 13)
  local close_path="$1"
  local filename="${2:-claude-code-fake.open}"
  local sid="${3:-$SID}"
  local opened_at="${4:-2026-01-01T00:00:00Z}"
  {
    echo "---"
    echo "agent: claude-code"
    echo "harness_session_id: $sid"
    echo "close_path: $close_path"
    if [ "$opened_at" != "NONE" ]; then
      echo "opened_at: $opened_at"
    fi
  } > "$SEM_DIR/$filename"
}

run_gate() { # $1 = command, $2 = session_id override (default $SID) → печатает exit code хука
  local sid="${2:-$SID}"
  local json_cmd
  json_cmd=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"session_id":"%s"}' \
    "$json_cmd" "$sid" | IWE_ROOT="$IWE_ROOT_TEST" bash "$HOOK" >/dev/null 2>&1
  echo $?
}

expect() { # $1 = описание, $2 = ожидаемый код (0|2), $3 = команда, $4 = session_id override (опц.)
  local got
  got=$(run_gate "$3" "${4:-}")
  if [ "$got" = "$2" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $1 (ожидалось $2, получено $got): $3"
  fi
}

# === close_path=peer-session → прямой commit пропускается без раннера ===
arm
write_semaphore "peer-session"
expect "peer-session: direct commit allowed"  0 'git commit -m x'
expect "peer-session: direct push allowed"    0 'git push'
expect "peer-session: -C form allowed"        0 'git -C repo commit -m x'

# === close_path=quick-close (явно объявлен) → прежнее поведение, блок ===
write_semaphore "quick-close"
expect "quick-close: still blocks commit"     2 'git commit -m x'

# === нет семафора вовсе (unknown) → прежнее поведение, блок (regression guard) ===
rm -f "$SEM_DIR"/*.open
expect "no semaphore: still blocks commit"    2 'git commit -m x'

# === close_path=unknown (легаси-вызов open без флага) → прежнее поведение ===
write_semaphore "unknown"
expect "close_path=unknown: still blocks"     2 'git commit -m x'

# === Сценарий 9: только *.open.closed (штатно закрытая дочерняя пир-сессия) ===
# bug-2026-08-31: до фикса гейт смотрел только *.open, этот кейс был red.
arm sess-only-closed
write_semaphore "peer-session" "claude-code-sess-only-closed.open.closed" "sess-only-closed"
expect "only .open.closed, peer-session: bypass still applies" \
  0 'git commit -m x' sess-only-closed

# === Сценарий 10: два *.open одного sid, freshest=quick-close (не bypass) ===
# Имена файлов НАРОЧНО выбраны так, что алфавитно-первый (значит, "head -1"
# после "grep -l ... *.open" у старого кода) -- это СТАРЫЙ peer-session, а
# реально свежий (по opened_at) -- quick-close с алфавитно более поздним
# именем. Проверено вручную: bash-глоббинг возвращает "*.open" отсортированным
# лексикографически, "a-old-peer" раньше "z-new-quick" -- старый код выбрал бы
# именно его и ошибочно бы обошёл раннер. Это то, что red-прогон (без фикса)
# должен ловить -- не совпадение по конструкции, как было бы при .open.closed.
arm sess-dual1
write_semaphore "peer-session" "claude-code-dual1-a-old-peer.open"   "sess-dual1" "2026-01-01T14:00:00Z"
write_semaphore "quick-close"  "claude-code-dual1-z-new-quick.open"  "sess-dual1" "2026-01-01T15:00:00Z"
expect "freshest=quick-close wins over alphabetically-first older peer-session: still blocks" \
  2 'git commit -m x' sess-dual1

# === Сценарий 11: обратный случай, freshest=peer-session (bypass должен сработать) ===
# Тот же приём: алфавитно-первый файл -- старый quick-close; реально свежий --
# peer-session с алфавитно более поздним именем. Старый код взял бы первый
# (quick-close) и ошибочно заблокировал бы штатный коммит пир-сессии.
arm sess-dual2
write_semaphore "quick-close"  "claude-code-dual2-a-old-quick.open" "sess-dual2" "2026-01-01T14:00:00Z"
write_semaphore "peer-session" "claude-code-dual2-z-new-peer.open"  "sess-dual2" "2026-01-01T15:00:00Z"
expect "freshest=peer-session wins over alphabetically-first older quick-close: bypass applies" \
  0 'git commit -m x' sess-dual2

# === Сценарий 12: одинаковый opened_at у двух кандидатов → tie-breaker по filename ===
# codex (раунд 2): алфавитно-первый кандидат — peer-session, алфавитно-поздний
# (и потому побеждающий по tie-break) — quick-close, ожидание exit 2. Так тест
# отличает "правильный tie-break по (ts, filename)" от неверной реализации
# "bypass если среди кандидатов есть ЛЮБОЙ peer-session" — та неверная версия
# тоже дала бы exit 0 на прежней (симметричной) формулировке сценария.
# Проверено вручную (python3): при равном ts выбирается лексикографически
# больший basename ("...-b..." > "...-a...").
arm sess-tie-break
write_semaphore "peer-session" "claude-code-sess-tie-break-a.open" "sess-tie-break" "2026-01-01T15:00:00Z"
write_semaphore "quick-close"  "claude-code-sess-tie-break-b.open" "sess-tie-break" "2026-01-01T15:00:00Z"
expect "tie-break by filename: lexicographically larger name wins (quick-close), not any-peer-session" \
  2 'git commit -m x' sess-tie-break

# === Сценарий 13: кандидат без opened_at/created_at не побеждает (fail-closed) ===
arm sess-missing-ts
write_semaphore "peer-session" "claude-code-sess-missing-ts.open" "sess-missing-ts" "NONE"
expect "candidate without timestamp ignored: still blocks (fail-closed)" \
  2 'git commit -m x' sess-missing-ts

# === Сценарий 14: harness_session_id — точное совпадение, не префикс ===
arm sess-abc
write_semaphore "peer-session" "claude-code-sess-abc-longer.open" "sess-abc-longer"
expect "prefix session_id must not false-match: still blocks" \
  2 'git commit -m x' sess-abc

# === Сценарий 15 (bug-2026-08-31-close-runner-gate-owner-session-id-null-under-
# peer-session, живой прогон в этой же сессии): "process-runner.py start
# quick-close" из сессии с close_path=peer-session ДОЛЖЕН по-прежнему получить
# harness-session mapping -- эта запись раньше делалась в блоке НИЖЕ прежнего
# места exit-on-match, и потому peer-session-сессии, которые реально зовут
# раннер (а не только close_obligation.py cancel --action close-override),
# получали owner_session_id: null на карточке прогона. Живой репрод в
# продакшене: три подряд запуска process-runner.py start quick-close из
# session_id e287e028-c78d-42da-bf47-0525cafae86a (у которой был открыт
# close_path=peer-session семафор) все получили owner_session_id null --
# CLOSE_PATH_MATCH выходил exit 0 до того, как код успевал записать mapping.
# Проверяем НАБЛЮДАЕМЫЙ эффект (файл на диске), не просто "не упало".
arm sess-mapping
write_semaphore "peer-session" "claude-code-sess-mapping.open" "sess-mapping"
MAPPING_SLUG="peer-session-mapping-check"
MAPPING_FILE="$IWE_ROOT_TEST/.iwe-runtime/quick-close-harness-session/quick-close-$MAPPING_SLUG.session_id"
rm -f "$MAPPING_FILE"
expect "peer-session quick-close start: still allowed (not a git commit/push)" \
  0 "python3 scripts/process-runner.py start quick-close --slug $MAPPING_SLUG --input '{}'" sess-mapping
if [ -f "$MAPPING_FILE" ] && [ "$(cat "$MAPPING_FILE")" = "sess-mapping" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "FAIL: peer-session quick-close start writes harness-session mapping (got: $([ -f "$MAPPING_FILE" ] && cat "$MAPPING_FILE" || echo '<file missing>'))"
fi
rm -f "$MAPPING_FILE"

# === Сценарий 16 (Codex review, turn 1 of peer-session
# 2026-08-31-47-close-runner-gate-order): same relocation, but with a
# quick-close start command that carries NO recognizable --slug. The
# bookkeeping block's own `if [ -n "$SLUG" ]` guards both the mapping write
# and the ticket issuance -- neither runs -- so control falls through the
# bookkeeping block's closing `fi` to the relocated CLOSE_PATH_MATCH check
# below it. Two things must both hold: (a) the call is still allowed (exit 0,
# it is not a git commit/push, and even if it were, the peer-session exemption
# now applies at this exact point), and (b) no mapping file gets written for
# ANY slug -- nothing to key it on. This closes the branch Codex asked to see
# covered by an assertion, not just by manual code reading.
arm sess-no-slug
write_semaphore "peer-session" "claude-code-sess-no-slug.open" "sess-no-slug"
HARNESS_MAP_DIR_TEST="$IWE_ROOT_TEST/.iwe-runtime/quick-close-harness-session"
rm -rf "$HARNESS_MAP_DIR_TEST"
expect "peer-session quick-close start without --slug: still allowed" \
  0 'python3 scripts/process-runner.py start quick-close --input "{}"' sess-no-slug
if [ ! -d "$HARNESS_MAP_DIR_TEST" ] || [ -z "$(ls -A "$HARNESS_MAP_DIR_TEST" 2>/dev/null)" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "FAIL: quick-close start without --slug must not write any harness-session mapping (found: $(ls -A "$HARNESS_MAP_DIR_TEST" 2>/dev/null))"
fi
rm -rf "$HARNESS_MAP_DIR_TEST"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
