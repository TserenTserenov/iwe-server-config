---
name: week-close.after.registry-catalog-freshness
description: WP-7 D3 — freshness-отчёт каталога реестров (registry-catalog.py --report) в лог Week Close
hook: after
protocol: week-close
valid_from: 2026-07-13
owner: user
---

# Week Close — после основного алгоритма

## Шаг: Freshness каталога реестров

**Когда выполнять:** вместе с шагом 7 (платформенные шаги) — после проверки бэкапов/dirty repos (7a-7c), до записи итогов в WeekReport (шаг 8).

**Зачем:** каталог реестров (WP-419, `DS-ecosystem-development/0.OPS/0.9.Inbox/WP-419-registry-catalog-draft.yaml`) несёт freshness-контур (флаг >90 дней без ре-верификации), но вызов `--report` был только задокументирован в шапке скрипта («stdout for Week Close log») — реально нигде не подключён, freshness ни разу не проверялась (WP-7 D3, 2026-07-13).

```bash
python3 ~/IWE/DS-ecosystem-development/0.OPS/scripts/registry-catalog.py --report
```

Вывод — информативный (non-blocking), в секцию «Платформенные шаги» WeekReport, аналогично 7a-7f. Пока owner/SLA-контур не заведён (WP-476 Ф3), почти все записи будут показывать «никогда не проверялись» — это честное текущее состояние каталога, не повод чинить прямо в этом шаге.

## Что не входит

- Простановка `last_verified` по каждой записи (ре-верификация статусов) — WP-476 Ф3.
- Заполнение недостающих `owner` (`--validate` печатает список W1-предупреждений, non-blocking) — WP-476 Ф3.
- `--validate` сюда не дублируется — уже вызывается отдельно в CI (`.github/workflows/registry-catalog-validate.yml`, на push/PR к каталогу).

## Откат

Удалить или переименовать этот файл — Week Close вернётся к прежнему поведению (freshness-отчёт не запускается).
