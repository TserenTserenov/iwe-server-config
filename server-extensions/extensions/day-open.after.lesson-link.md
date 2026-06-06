# Day Open Extension (after) — Ссылка на сегодняшнюю lesson

<!-- AUTHOR-ONLY -->

> **Источник:** WP-364 Развилка 1 РЕШЕНО (peer-сессия [2026-05-29-23-wp-364-daily-fork](../DS-my-strategy/sessions/2026-05/2026-05-29-23-wp-364-daily-fork/report.md)).
>
> **Цель:** связать DayPlan и сегодняшнюю учебную сессию из `personal-guide/`. Если Портной сгенерировал lesson на сегодня — DayPlan получает ссылку в начале «Учебная сессия сегодня». Иначе — секция omit (норма для дня без триггера).

## Шаг: добавить ссылку на сегодняшнюю lesson в DayPlan

Выполнить **после** основного pipeline Day Open (commit DayPlan уже сделан), **до** Morning Digest. Идемпотентно: повторный запуск не дублирует секцию.

```bash
DATE=$(date +%Y-%m-%d)
DAYPLAN_PATH="$HOME/IWE/DS-my-strategy/current/DayPlan $DATE.md"
PERSONAL_GUIDE="$HOME/IWE/personal-guide"

# Проверка: DayPlan существует
if [ ! -f "$DAYPLAN_PATH" ]; then
  echo "  Day Open lesson-link: DayPlan не найден ($DAYPLAN_PATH) — пропуск"
  exit 0
fi

# Идемпотентность: если секция уже есть — пропуск
if grep -q "^## Учебная сессия сегодня" "$DAYPLAN_PATH"; then
  echo "  Day Open lesson-link: секция уже добавлена — пропуск"
  exit 0
fi

# Поиск файла: предпочтительно lesson/, fallback daily/ (миграция WP-364 Ф2)
LESSON_FILE=""
LESSON_LABEL=""
if [ -f "$PERSONAL_GUIDE/lesson/$DATE.md" ]; then
  LESSON_FILE="$PERSONAL_GUIDE/lesson/$DATE.md"
  LESSON_LABEL="lesson/$DATE.md"
elif [ -f "$PERSONAL_GUIDE/daily/$DATE.md" ]; then
  LESSON_FILE="$PERSONAL_GUIDE/daily/$DATE.md"
  LESSON_LABEL="daily/$DATE.md (legacy — до миграции WP-364 Ф2)"
fi

if [ -z "$LESSON_FILE" ]; then
  echo "  Day Open lesson-link: сегодня lesson не сгенерирован — пропуск (норма для дня без триггера)"
  exit 0
fi

# Извлечь первую заголовочную строку lesson для preview
LESSON_TITLE=$(grep -m1 "^# " "$LESSON_FILE" 2>/dev/null | sed 's/^# //' | head -c 100)
[ -z "$LESSON_TITLE" ] && LESSON_TITLE="Учебная сессия от Портного"

# Извлечь apply_to (если есть) — для подсказки в DayPlan
APPLY_TO=$(grep -m1 -A2 "^### Применить" "$LESSON_FILE" 2>/dev/null | tail -1 | head -c 150)

# Вставка секции в начало DayPlan (после frontmatter, перед остальным)
LESSON_SECTION="## Учебная сессия сегодня

- **Тема:** $LESSON_TITLE
- **Файл:** [$LESSON_LABEL]($LESSON_FILE)
"
if [ -n "$APPLY_TO" ]; then
  LESSON_SECTION="$LESSON_SECTION- **Применить:** $APPLY_TO
"
fi

# Append в конец DayPlan (простой вариант). Для after-frontmatter insertion — отдельный РП.
{
  echo ""
  echo "$LESSON_SECTION"
} >> "$DAYPLAN_PATH"

echo "  Day Open lesson-link: добавлена секция «Учебная сессия сегодня» → $LESSON_LABEL"

# Дополнительный commit (не блокирует основной pipeline если git упадёт)
cd "$HOME/IWE/DS-my-strategy" 2>/dev/null && \
  git add "$DAYPLAN_PATH" 2>/dev/null && \
  git commit -m "feat(dayplan): add lesson link for $DATE (WP-364 Развилка 1)" 2>/dev/null && \
  git push 2>/dev/null || true
```

## Связь с другими подзадачами WP-364 Ф2

- **Lesson contract (Фаза A, prompt.md):** инструкция для Портного включать секцию `apply_to` в выходной JSON. Этот скрипт читает её из готового `lesson/*.md`.
- **Renaming daily/→lesson/ (Фаза C, render-pilot-guides.py):** до завершения миграции скрипт работает в fallback-режиме на `daily/`. После миграции — primary path `lesson/`.

## Откат

Удалить файл из `extensions/` — следующий Day Open не выполнит этот шаг. Уже добавленные секции в DayPlan-ах остаются (no-op для прошлых дней).

<!-- /AUTHOR-ONLY -->
