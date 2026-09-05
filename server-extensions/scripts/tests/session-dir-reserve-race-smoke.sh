#!/usr/bin/env bash
# Smoke test for session-dir-reserve.sh (WP-530, peer session 2026-09-05-24).
#
# Baseline for comparison: the inline bash both writer skills used before this
# script existed gave 6 unique numbers for 12 concurrent writers (numbers 01,
# 05 and 06 each handed to two sessions, which then shared one directory).

set -uo pipefail

# Same resolution order as the writer skills: the configured scripts directory
# first, the root checkout as fallback. On this host IWE_SCRIPTS points at the
# template copy, which lags behind the root one (reported to the pilot, S-33).
SCRIPT="${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-dir-reserve.sh"
[ -x "$SCRIPT" ] || SCRIPT="$HOME/IWE/scripts/session-dir-reserve.sh"
DAY="2026-09-05"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS $name"
    else
        echo "  FAIL $name: ожидал '$expected', получил '$actual'"
        failures=$((failures + 1))
    fi
}

echo "1. Гонка: 12 одновременных писателей на пустом дне"
d="$WORK/race"; mkdir -p "$d"; out="$WORK/race.out"; : > "$out"
for i in $(seq 1 12); do ( "$SCRIPT" "$d" "$DAY" "race-$i" >> "$out" 2>/dev/null ) & done
wait
check "выдано идентификаторов" "12" "$(wc -l < "$out" | tr -d ' ')"
check "уникальных номеров" "12" "$(sed -E "s/^$DAY-([0-9]{2})-.*/\1/" "$out" | sort -u | wc -l | tr -d ' ')"
check "создано каталогов" "12" "$(find "$d" -maxdepth 1 -type d -name "$DAY-*" | wc -l | tr -d ' ')"

echo "2. Уборка не освобождает номер (max+1, не count+1)"
d="$WORK/cleanup"; mkdir -p "$d"
for n in 01 02 03 04 05; do mkdir -p "$d/$DAY-$n-old"; done
rm -rf "$d/$DAY-03-old"
check "номер после удаления одного из пяти" "$DAY-06-after" "$("$SCRIPT" "$d" "$DAY" "after" 2>/dev/null)"

echo "3. Архивация каталога сессии не приводит к перевыдаче номера"
d="$WORK/archive"; mkdir -p "$d"
first=$("$SCRIPT" "$d" "$DAY" "first" 2>/dev/null)
rm -rf "${d:?}/$first"
check "следующий номер после архивации" "$DAY-02-second" "$("$SCRIPT" "$d" "$DAY" "second" 2>/dev/null)"

echo "4. Мусор на входе отклоняется с диагностикой"
d="$WORK/reject"; mkdir -p "$d"
"$SCRIPT" "$d" "05.09.2026" "ok" >/dev/null 2>&1; check "дата не ISO" "2" "$?"
"$SCRIPT" "$d" "$DAY" "Плохой Слаг" >/dev/null 2>&1; check "слаг с пробелами и кириллицей" "2" "$?"
"$SCRIPT" "$d" "$DAY" >/dev/null 2>&1; check "не хватает аргументов" "2" "$?"

echo
if [ "$failures" -eq 0 ]; then
    echo "session-dir-reserve: все проверки прошли"
    exit 0
fi
echo "session-dir-reserve: провалов — $failures"
exit 1
