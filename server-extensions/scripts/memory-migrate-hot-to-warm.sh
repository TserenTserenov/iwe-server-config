#!/usr/bin/env bash
# routing: migration  one-time=true
# see DP.SC.159, DP.ROLE.059
# memory-migrate-hot-to-warm.sh — автоматическая миграция HOT → WARM (WP-217 Ф10.4)
#
# Цель: понизить HOT с переполнения (<150 строк) на размер WARM
# Сохраняет core HOT: user_*, memory-lifecycle-spec, distinctions
# Остальное feedback_* → WARM (если не в исключениях)
#
# Usage:
#   bash scripts/memory-migrate-hot-to-warm.sh --dry-run   # показать, что изменится
#   bash scripts/memory-migrate-hot-to-warm.sh --execute    # применить
#
# Spec: memory/memory-lifecycle-spec.md

set -eu

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
MEMORY_DIR="$IWE_ROOT/memory"
DRY_RUN=1
CHANGES=0

# Core HOT-файлы, которые оставляем (очень маленькие или критичные для сессии)
CORE_HOT="user_background.md user_identifiers.md user_mission_core.md memory-lifecycle-spec.md distinctions.md navigation.md hard-distinctions.md"

while [ $# -gt 0 ]; do
    case "$1" in
        --execute) DRY_RUN=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            echo "Usage: $0 [--dry-run|--execute]"
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

get_field() {
    local file="$1" field="$2"
    awk '/^---/{f++} f==1 && /^'"$field"':/{gsub(/^[^:]+: */,""); gsub(/^["'"'"']|["'"'"']$/,""); print; exit}' "$file"
}

has_frontmatter() {
    head -1 "$1" | grep -q '^---$'
}

is_core_hot() {
    local name=$(basename "$1")
    for core in $CORE_HOT; do
        [ "$name" = "$core" ] && return 0
    done
    return 1
}

update_horizon() {
    local file="$1" new_horizon="$2"
    # Замена horizon: hot → horizon: warm в frontmatter
    sed -i '' "s/^horizon: hot$/horizon: $new_horizon/" "$file"
}

echo "=== Memory Migrate HOT → WARM (WP-217 Ф10.4) ==="
echo ""
echo "Сохранять core HOT: $CORE_HOT"
echo ""

# Проход по всем файлам
for f in $(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" | sort); do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    [ "$name" = "MEMORY.md" ] && continue

    if ! has_frontmatter "$f"; then
        continue
    fi

    horizon=$(get_field "$f" "horizon")
    [ "$horizon" != "hot" ] && continue

    # Если это core HOT → пропустить
    if is_core_hot "$f"; then
        echo "✓ $name (core HOT, сохраняем)"
        continue
    fi

    # Перевести в WARM
    lines=$(awk '/^---/{f++; next} f>=2{print}' "$f" | wc -l | tr -d ' ')
    echo "→ $name ($lines строк) HOT → WARM"
    CHANGES=$((CHANGES + 1))

    if [ $DRY_RUN -eq 0 ]; then
        update_horizon "$f" "warm"
    fi
done

echo ""
echo "=== Итого ==="
echo "Файлов к переводу: $CHANGES"

if [ $DRY_RUN -eq 1 ]; then
    echo ""
    echo "Это DRY-RUN режим. Для применения запустите:"
    echo "  bash scripts/memory-migrate-hot-to-warm.sh --execute"
else
    echo ""
    echo "✅ Миграция выполнена. Проверить:"
    echo "  bash scripts/memory-health.sh"
fi
