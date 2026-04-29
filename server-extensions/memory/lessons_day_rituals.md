---
name: lessons_day_rituals
description: Уроки Day Open / Day Close / Session Close — дата, календарь, видео, governance, DayPlan-first
type: feedback
valid_from: 2026-03-29
originSessionId: 9a0e726a-951e-4408-9e02-94d7eeffbf74
---
**Day Open: дата и календарь.** (1) `currentDate` от Anthropic может врать — ПЕРВОЕ действие = `date`. (2) Календарь: ВСЕ calendarId из `gcal_list_calendars`, не только `primary`. 10 календарей, основные — «Служба ПМП» и «Aisystant Консультации». (3) SchedulerReport: за СЕГОДНЯ (`~/logs/strategist/YYYY-MM-DD.log`), не из `current/SchedulerReport*.md`.

**Day Open/Close: видеосканирование.** `video-scan.sh` не существует (WP-7). Сейчас: `ls -lt <dir> | head -10`. НЕ `ls -la | tail`. НЕ `find` с `[ "$var" \> "date" ]`. Транскрипция: `/transcribe` (large-v3 по умолчанию, distil — мусор на конференциях).

**Day Close: governance ДО черновика.** REPOSITORY-REGISTRY, navigation.md, MAP.002 — ДО итогов.

**Day Close: DayPlan-first.** TOP-DOWN: DayPlan → план → факт → незапланированное. НЕ bottom-up по коммитам.

**Day Close: содержание ≠ структура.** Открывать артефакт, проверять СОДЕРЖАНИЕ, не наличие файлов.

**Close: `/run-protocol` обязателен.** Шаги теряются «в голове». Статусы — шаг 2 сразу после commit.

**Day Open: поведенческий конфиг → day-rhythm-config.yaml, не SKILL.md.** SOTA.002: inline правила в SKILL.md = токены контекста. Параметры (бюджеты, пороги, флаги) → day-rhythm-config.yaml (рядом с pomodoro, news, calendar_ids). SKILL.md описывает ЧТО делать, day-rhythm-config.yaml — С КАКИМИ значениями. **How to apply:** при добавлении нового поведения Day Open → сначала проверить, параметр ли это (→ yaml) или правило (→ SKILL.md).

**Day Open: при update.sh личные настройки day-rhythm-config.yaml могут быть перезаписаны шаблонными.** DS-my-strategy/exocortex/memory/day-rhythm-config.yaml — NOT автоматически защищён (не в extensions/). При обновлении через cp → проверить calendar_ids, mandatory_daily_wps, video, news. **How to apply:** после `iwe-update` → сравнить diff `day-rhythm-config.yaml` → восстановить личные значения.

**Day Open шаг 3 (Саморазвитие): формальная отметка ≠ разбор.** Поставить РП саморазвития в план со слотом 0.5h недостаточно. Если РП переносится 3+ раза подряд (WP-211 Чт 23 апр — 4-й перенос), шаг 3 обязан: (а) открыть `drafts/` / руководство, (б) найти конкретную точку возврата (страница, параграф, незавершённый черновик), (в) записать её в DayPlan как «где остановился» — иначе следующим утром РП снова переносится без сопротивления. **Why:** 4 переноса подряд = сигнал, что без точки входа вход не случится. **How to apply:** при каждом Day Open смотреть счётчик переносов РП саморазвития. ≥3 → шаг 3 не завершён, пока точка возврата не найдена и не записана в DayPlan.

**Day Open: опциональные шаги config-driven не проверяются checks.md (24 апр 2026).** Шаги 3 (саморазвитие), 4b (помидорки), 5a2 (видео) включаются через `day-rhythm-config.yaml`, но `extensions/day-open.checks.md` проверял только 11 обязательных секций — не покрывал эти пункты. Косяки 24 апр: (1) секция «Видео» пропущена при `video.enabled: true` + 2 новых Zoom-файла сегодня; (2) блок «Помидорки» не упомянут при заданном `pomodoro.work/break/long`; (3) саморазвитие = «30 мин чтения стилевого эталона» без указания где остановился (глава/страница/draft-ID). **Why:** дыра между алгоритмом SKILL.md и чеклистом — алгоритм предписывает, чеклист не проверяет, агент забывает под нагрузкой. **How to apply:** добавлен блок «Опциональные шаги алгоритма» в `extensions/day-open.checks.md` — при шаге 7b прогонять проверку video/pomodoro/self-dev если соответствующий config активен; пропуск = блокер коммита.
