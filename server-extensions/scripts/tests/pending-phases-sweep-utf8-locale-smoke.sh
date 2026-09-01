#!/usr/bin/env bash
# routing: test  deterministic=true
# WP-484 пункт M (01.09, пир-сессия с Kimi+Codex): pending-phases-sweep.sh
# использовал двухбуквенные кириллические bracket-классы ([Вв]/[Зз]/[Оо]/[Нн]),
# байт-небезопасные под LC_ALL=C (типичный дефолт cron/systemd без явного
# LANG) — закрытые пункты ложно оставались "pending". Отдельно: раздельное
# отрицание "не выполнена" ложно засчитывалось как закрытое (независимо от
# локали). Этот тест фиксирует оба случая под всеми доступными на машине
# локалями через checklist-формат (`- [ ] ФN: текст`) — там is_closed()
# напрямую гейтит вывод PENDING, без структурного override пустого чекбокса.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pending-phases-sweep.sh"
fail=0

make_fixture() {
    local tmp dir
    tmp=$(mktemp -d)
    dir="$tmp/inbox"
    mkdir -p "$dir"
    printf 'status: in_progress\n\n- [ ] Ф1: Выполнен полностью\n- [ ] Ф2: Незакрытый остаток\n- [ ] Ф3: сама уборка не выполнена\n' \
        > "$dir/WP-9001.md"
    echo "$tmp"
}

FIXTURE=$(make_fixture)
trap 'rm -rf "$FIXTURE"' EXIT

for locale in C en_US.UTF-8 C.UTF-8; do
    if ! LC_ALL="$locale" awk 'BEGIN{exit 0}' 2>/dev/null; then
        echo "SKIP locale недоступна на этой системе: $locale"
        continue
    fi
    out=$(LC_ALL="$locale" bash "$SCRIPT" --repo "$FIXTURE" --all 2>&1)

    # Ф1 явно закрыт ("Выполнен") — не должен попасть в pending.
    if echo "$out" | grep -q "Ф1 —"; then
        echo "FAIL [$locale]: Ф1 (Выполнен) ложно остался pending"
        echo "$out" | sed 's/^/    /'
        fail=1
    else
        echo "OK [$locale]: Ф1 (Выполнен) корректно исключён из pending"
    fi

    # Ф2 действительно pending ("Незакрытый") — должен остаться, не путаться
    # с "закрыт" по подстроке (issue #458, старая защита).
    if echo "$out" | grep -q "Ф2 — Незакрытый остаток"; then
        echo "OK [$locale]: Ф2 (Незакрытый) корректно остаётся pending"
    else
        echo "FAIL [$locale]: Ф2 (Незакрытый) пропал из pending"
        echo "$out" | sed 's/^/    /'
        fail=1
    fi

    # Ф3 раздельное отрицание "не выполнена" — тоже должен остаться pending
    # (находка Codex этой сессии, независимая от локали).
    if echo "$out" | grep -q "Ф3 — сама уборка не выполнена"; then
        echo "OK [$locale]: Ф3 (не выполнена, раздельно) корректно остаётся pending"
    else
        echo "FAIL [$locale]: Ф3 (не выполнена, раздельно) ложно закрыт"
        echo "$out" | sed 's/^/    /'
        fail=1
    fi
done

exit $fail
