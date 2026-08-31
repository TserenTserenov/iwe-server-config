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
MIGRATION_TEMP=""

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

has_frontmatter() {
    head -1 "$1" | grep -q '^---$'
}

read_horizon() {
    awk '
        /^---[ \t\r]*$/ {
            frontmatter++
            next
        }
        frontmatter != 1 {
            next
        }
        /^horizon:/ {
            sub(/^[^:]+:[ \t]*/, "")
            gsub(/^[\047"]|[\047"]$/, "")
            gsub(/[ \t\r]+$/, "")
            print
            exit
        }
        /^metadata:[ \t\r]*$/ {
            in_metadata = 1
            next
        }
        in_metadata && /^[^ \t]/ {
            in_metadata = 0
        }
        in_metadata && /^[ \t]+horizon:/ {
            sub(/^[ \t]*[^:]+:[ \t]*/, "")
            gsub(/^[\047"]|[\047"]$/, "")
            gsub(/[ \t\r]+$/, "")
            print
            exit
        }
    ' "$1"
}

is_core_hot() {
    local name
    name="$(basename "$1")"
    for core in $CORE_HOT; do
        [ "$name" = "$core" ] && return 0
    done
    return 1
}

update_horizon() {
    local file="$1" new_horizon="$2"
    local file_dir file_name file_mode

    file_dir="$(dirname "$file")"
    file_name="$(basename "$file")"
    MIGRATION_TEMP="$(mktemp "$file_dir/.${file_name}.horizon.XXXXXX")"

    if file_mode="$(stat -f '%Lp' "$file" 2>/dev/null)"; then
        :
    elif file_mode="$(stat -c '%a' "$file" 2>/dev/null)"; then
        :
    else
        echo "❌ Не удалось прочитать режим файла: $file" >&2
        return 1
    fi
    chmod "$file_mode" "$MIGRATION_TEMP"

    # Меняем ровно то поле, которое видит read_horizon:
    # плоское horizon или horizon в metadata, только в первом frontmatter.
    if ! awk -v new_horizon="$new_horizon" '
        function replace_hot(line, replacement,    colon, raw, normalized, first, last, pos) {
            colon = index(line, ":")
            raw = substr(line, colon + 1)
            normalized = raw
            gsub(/^[ \t]+|[ \t\r]+$/, "", normalized)
            first = substr(normalized, 1, 1)
            last = substr(normalized, length(normalized), 1)
            if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) {
                normalized = substr(normalized, 2, length(normalized) - 2)
            }
            if (normalized != "hot") {
                return line
            }
            pos = index(raw, "hot")
            return substr(line, 1, colon) substr(raw, 1, pos - 1) replacement substr(raw, pos + 3)
        }

        /^---[ \t\r]*$/ {
            frontmatter++
            print
            next
        }

        {
            if (frontmatter == 1 && !updated) {
                if ($0 ~ /^horizon:/) {
                    replaced = replace_hot($0, new_horizon)
                    if (replaced != $0) {
                        $0 = replaced
                        updated = 1
                    }
                } else {
                    if ($0 ~ /^metadata:[ \t\r]*$/) {
                        in_metadata = 1
                    } else if (in_metadata && $0 ~ /^[^ \t]/) {
                        in_metadata = 0
                    }
                    if (in_metadata && $0 ~ /^[ \t]+horizon:/) {
                        replaced = replace_hot($0, new_horizon)
                        if (replaced != $0) {
                            $0 = replaced
                            updated = 1
                        }
                    }
                }
            }
            print
        }
    ' "$file" > "$MIGRATION_TEMP"; then
        echo "❌ Не удалось подготовить обновление: $file" >&2
        return 1
    fi

    if cmp -s "$file" "$MIGRATION_TEMP" || [ "$(read_horizon "$MIGRATION_TEMP")" != "$new_horizon" ]; then
        echo "❌ Не найдено целевое horizon в первом frontmatter: $file" >&2
        return 1
    fi

    mv -f "$MIGRATION_TEMP" "$file"
    MIGRATION_TEMP=""
}

cleanup_temp() {
    [ -z "$MIGRATION_TEMP" ] || rm -f "$MIGRATION_TEMP"
}

trap cleanup_temp EXIT
trap 'exit 130' HUP INT TERM

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

    horizon=$(read_horizon "$f")
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
