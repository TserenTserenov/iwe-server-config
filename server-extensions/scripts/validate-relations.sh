#!/usr/bin/env bash
# validate-relations.sh — проверяет формат related: в WP context files
# Использование: ./scripts/validate-relations.sh [dir]
# По умолчанию: DS-my-strategy/inbox/
# WP-207 Ф7a

set -euo pipefail

DIR="${1:-DS-my-strategy/inbox}"
VALID_KEYS="depends_on|enables|blocked_by|absorbs|references|realizes|uses|extends|specializes"

errors=0
checked=0
with_related=0
without_related=0

for f in "$DIR"/WP-*.md; do
  [ -f "$f" ] || continue
  checked=$((checked + 1))

  # Извлечь frontmatter (между первой и второй ---)
  fm=$(awk '/^---$/{n++; next} n==1{print} n>=2{exit}' "$f")

  # Проверить наличие related:
  if echo "$fm" | grep -q "^related:"; then
    with_related=$((with_related + 1))

    # Проверить: нет ли плоского формата (related: [...)
    if echo "$fm" | grep -qE "^related: \["; then
      echo "ERROR $f: flat related: [...] — convert to typed format"
      errors=$((errors + 1))
    fi

    # Проверить: все ключи внутри related: допустимы
    in_related=false
    while IFS= read -r line; do
      if echo "$line" | grep -q "^related:"; then
        in_related=true
        continue
      fi
      if $in_related; then
        # Строка с отступом = внутри related:
        if echo "$line" | grep -qE "^  [a-z]"; then
          key=$(echo "$line" | sed 's/^  \([a-z_]*\):.*/\1/')
          if ! echo "$key" | grep -qE "^($VALID_KEYS)$"; then
            echo "WARN  $f: unknown relation key '$key'"
          fi
        elif echo "$line" | grep -qE "^[a-z]"; then
          in_related=false
        fi
      fi
    done <<< "$fm"
  else
    # Проверить: нет ли old-style depends_on:/links:/blocked_by: вне related:
    if echo "$fm" | grep -qE "^(depends_on|links|blocked_by):"; then
      echo "ERROR $f: has standalone depends_on/links/blocked_by — merge into related:"
      errors=$((errors + 1))
    else
      without_related=$((without_related + 1))
    fi
  fi
done

echo ""
echo "=== Итого ==="
echo "Проверено: $checked"
echo "С typed related: $with_related"
echo "Без related: $without_related"
echo "Ошибок: $errors"

exit $errors
