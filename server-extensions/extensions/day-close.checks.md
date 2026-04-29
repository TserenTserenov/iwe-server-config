## Авторские проверки Day Close

### Сбор данных (шаг 1) — коммиты ПЕРВИЧНЫ

> **Правило (S-12):** идти от коммитов к РП, не от DayPlan к коммитам.
> DayPlan = план, коммиты = факт. Незапланированные РП и ad-hoc появляются только в коммитах.

**Алгоритм сбора (заменяет стандартный шаг 1):**
1. Получить все коммиты за день по всем репо (с временем: `--format="%ai %s"`)
2. Сгруппировать по сессиям (временные кластеры)
3. Для каждой сессии: какой РП? Есть ли коммиты без РП? → ad-hoc
4. ТОЛЬКО ПОСЛЕ — сопоставить с DayPlan (план vs факт)

- [ ] **Коммит-аудит:** все коммиты разобраны по РП/сессиям (не только из DayPlan)
- [ ] **ad-hoc без РП:** выявлены → записаны в итоги → предложить `/wp-new` если >0.5h

### CHANGELOG FMT
~~Перенесён в Quick Close (шаг 1b).~~ На Day Close — только проверить, что не пропущен.

- [ ] **CHANGELOG FMT:** проверить, что обновлён в Quick Close (не пропущен)

### Синхронизация веток бота (pilot vs new-architecture)

```bash
cd ~/IWE/DS-IT-systems/aist_bot_newarchitecture
git fetch origin
DIFF_STAT=$(git diff origin/pilot origin/new-architecture --stat -- ':!.DS_Store')
if [ -z "$DIFF_STAT" ]; then
  echo "pilot и new-architecture: содержимое идентично ✅"
else
  echo "pilot и new-architecture: РАСХОДЯТСЯ по содержимому ⚠️"
  echo "$DIFF_STAT"
fi
```

Сигнализировать ТОЛЬКО если `git diff` показывает разницу в содержимом.

### Smoke-тесты бота (S59, WP-179)

```bash
cd ~/IWE/DS-IT-systems/aist_bot_newarchitecture
if [ -d ".venv" ]; then
  .venv/bin/python -m pytest tests/smoke/ -q --tb=line 2>&1
fi
```

64 теста, <1s. Если FAIL → сигнализировать.

### DS-agent-workspace: коммит автоматический (WP-5 #14b)

> Артефакты агентов (scheduler/reports, feedback-triage, scout, tester, extractor) коммитятся автоматически ночью — см. `DS-ai-systems/synchronizer/scripts/agent-workspace-commit` в scheduler (config.yaml `hour: 5`). Ручной коммит в Day Close — **аварийный режим**, сигнал сбоя auto-commit.

```bash
cd ~/IWE/DS-agent-workspace
if [ -n "$(git status --porcelain)" ]; then
    echo "⚠️  DS-agent-workspace грязный — auto-commit не сработал. Проверь ~/logs/synchronizer/agent-workspace-commit-$(date +%F).log"
    # Аварийный ручной коммит (если auto-commit сбойнул):
    # git add -A && git commit -m "chore: manual sync $(date +%F) — auto-commit fail" && git push
fi
```

- [ ] **DS-agent-workspace чистый:** если грязный — разобрать лог auto-commit, не коммитить вручную по привычке

### Запись в черновик недельного поста (S-19, тестируется)

> **Где живёт черновик:** `DS-Knowledge-Index-Tseren/docs/{YYYY}/{NN}-{месяц}/week-draft-w{NN}.md`
> **Когда:** вместе со спросом «Обещания кому-то?» в шаге 7г (Не забыто?).
> **Зачем:** накопительный сбор материала для недельного поста — чтобы на Week Close писать не с нуля.

**4 вопроса автору (на шаге 7г):**
1. **Мир:** что из сегодняшнего — универсальный принцип/идея для поста?
2. **Сообщество:** что поможет участникам клуба?
3. **Человек:** что один читатель может попробовать прямо сейчас?
4. **Личное:** что я сам понял / что изменилось?

Допустимые ответы: пропустить день, одна-две строки, одна общая мысль на все 4 уровня. Пустое поле = прочерк остаётся.

**Строка метрик (автозаполнение):**

```bash
~/IWE/scripts/week-draft-append.sh
```

Скрипт собирает: WakaTime (`~/.wakatime/wakatime-cli --today`), коммиты за день по всем репо, закрытые РП (по коммитам `close/done WP-NNN`). Обновляет строку текущего дня в таблице черновика. Поля «Бюджет закрыт» и «Прогресс месяца» пока заполняются вручную (счёт сложен, после 2 недель решим, автоматизировать ли).

**На Пн Day Close — сначала инициализация недели:**

```bash
~/IWE/scripts/week-draft-init.sh
```

Создаёт пустой черновик `week-draft-w{NN}.md` (если ещё не существует). Идемпотентен.

- [ ] **Пн:** запущен `week-draft-init.sh` (новая неделя)
- [ ] **4 вопроса заданы:** мир/сообщество/человек/личное
- [ ] **Ответы добавлены в черновик:** строки `[День]` обновлены
- [ ] **Метрики дня записаны:** `week-draft-append.sh` (WakaTime/коммиты/РП) + вручную (бюджет/прогресс месяца)
- [ ] **Черновик закоммичен:** `git -C ~/IWE/DS-Knowledge-Index-Tseren add docs/ && git commit -m "docs: week-draft W{NN} update"`
