# Protocol Open Extensions (sync) — авторские

> Точка переопределения дефолтной логики шага 3 § WP Gate.
> Дефолт описан в `memory/protocol-open.md` § Sync Gate (шаг 3c, ветки A/B/C).
> Этот файл загружается как override через `load-extensions.sh protocol-open sync`.
> Автор: Tseren (author_mode). Слой 3 (extensions). Spawn: WP-294.

## Когда нужен этот файл

Если устраивает дефолт (bundler + Sonnet sub-agent для ≥2 related или drift) — extension **не нужен**, удали этот файл.

Этот файл нужен только для:
- Замены sub-agent'а `wp-sync-actualizer` на свой
- Переопределения порогов веток (например, A до ≤2 related, B от ≥3)
- Подмешивания дополнительной информации в bundle (личные индексы, заметки)
- Логирования всех sync-запусков в свою БД

## Текущие override'ы (Tseren)

Никаких — пользуюсь дефолтом. Файл сохранён как пример структуры для будущих кастомизаций.

## Шаблон override-логики

```markdown
## Override: ветка B → собственный sub-agent

Вместо `wp-sync-actualizer` использовать `my-custom-actualizer`:

Task(
  subagent_type: "my-custom-actualizer",
  description: "Custom sync для WP-N",
  prompt: "Bundle:\n{{BUNDLE}}\n\n... мои инструкции"
)
```

## Анти-паттерны

- **Дублировать дефолтную логику** — извлекай из protocol-open.md шаг 3, не копируй сюда
- **Менять формат bundle** — bundler в `.claude/scripts/wp-sync-bundle.sh`, override должен использовать выход как есть
- **Применять diff без `Read`** — нарушение Edit tool требований
- **Делегировать на Opus** — sync = closed-loop, Sonnet достаточно (см. WP-294 Plan-анализ)
