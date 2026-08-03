#!/bin/bash
# Проверка дедупликации events в reflection-events журнале
# Ищет дублирующиеся feedback-source за одну сессию
# Использование: verify-reflection-dedup.sh [путь]

set -euo pipefail

LEDGER_DIR="${1:-.}/machine/ledger"

if [[ ! -d "$LEDGER_DIR" ]]; then
  echo "❌ Директория $LEDGER_DIR не найдена"
  exit 1
fi

# Ищем все reflection-events файлы
if ! ls "$LEDGER_DIR"/reflection-events-*.json >/dev/null 2>&1; then
  echo "⚠️  Нет reflection-events файлов в $LEDGER_DIR"
  exit 0
fi

echo "🔍 Проверка дедупликации reflection-events..."
DUPES_FOUND=0

for file in "$LEDGER_DIR"/reflection-events-*.json; do
  if [[ ! -f "$file" ]]; then continue; fi

  # Ищем дублирующиеся feedback_source в одном файле
  # Формат: {"source": "hermes", "channel": "memory", ...}
  DUPES=$(jq -r '.[] | "\(.source)_\(.channel)_\(.type // "unknown")"' "$file" 2>/dev/null | sort | uniq -d || true)

  if [[ -n "$DUPES" ]]; then
    echo "⚠️  Дубли найдены в $file:"
    echo "$DUPES" | while read -r dup; do
      COUNT=$(jq -r ".[] | select(.source + \"_\" + .channel + \"_\" + (.type // \"unknown\") == \"$dup\") | .source" "$file" 2>/dev/null | wc -l)
      echo "  - $dup: $COUNT записей"
    done
    DUPES_FOUND=1
  fi
done

if [[ $DUPES_FOUND -eq 0 ]]; then
  echo "✅ Дублей не найдено — reflection-events чисты"
  exit 0
else
  echo "❌ Найдены дублирующиеся события — нужна диагностика Hermes"
  exit 1
fi
