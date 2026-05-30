# Runbook — Watchdog dirty alert

> **Триггер:** TG-сообщение `⚠️ IWE pull-repos warnings (tsekh-1, YYYY-MM-DD HH:MM): <repo> (dirty: ...) ...`
> **Источник:** systemd timer `iwe-scheduler.service` → `ExecStartPre` → `iwe-pull-repos` script ([modules/systemd-timers.nix](../../modules/systemd-timers.nix)).
> **SLA:** discharge ≤2h при не первом случае. Первый — диагноз 30-60 мин.
> **Контекст рождения:** WP-7 фаза WD, 2026-05-30 (третий заход на повторяющуюся проблему — см. [lessons_infra_fix_coverage_smoke.md](../../../memory/lessons_infra_fix_coverage_smoke.md)).

---

## Шаг 1 — Прочитать TG-сообщение

С версии 2026-05-30 watchdog включает в алерт первые 5 dirty-путей через `|`:

```
DS-agent-workspace (dirty: ?? auditor/2026-05-30/|?? scheduler/feedback-triage/2026-05-30.md)
```

Это даёт **немедленный диагноз** — никаких SSH-проверок не нужно для классификации.

Если в сообщении только `(dirty)` без путей — версия скрипта старая (deployment drift). Перейти к Шагу 5.

## Шаг 2 — Классифицировать каждый dirty-путь

Для каждого пути из (1) определить класс по двум вопросам:

| Вопрос | Ответ → Класс |
|---|---|
| Кто writer этого пути? | агент (auditor/scheduler/scout/...) → derived. Пилот руками → SoT. |
| Должен ли этот путь когда-либо коммититься? | да → A (regression in writer). нет → B (missing gitignore). |

### Класс A — Regression in writer (агент должен коммитить, но не коммитит)

Симптом: путь tracked в `git ls-files`, но новые версии не попадают в коммиты.

Причины:
- Auto-commit threshold не достигается (concurrent writer резетит таймер) — пример: `f70e466` 2026-05-29.
- Auto-commit упал (cron не запускается, exception в скрипте).
- Auto-commit pattern не покрывает новую папку.

Fix: починить writer (см. Шаг 3).

### Класс B — New derived writer без gitignore

Симптом: путь untracked в `git ls-files | grep <path>`, но **никогда не должен попадать в SoT** (это operational log агента).

Причины:
- Новый агент создал output-путь без обновления `.gitignore`.
- Старый агент сменил output-формат на новый путь.

Fix: добавить путь в `.gitignore` целевого репо + коммит (см. Шаг 4).

## Шаг 3 — Fix Класса A (regression in writer)

1. **Найти источник writer'а:** `git log -- <dirty-path>` → автор последнего коммита → имя скрипта/агента.
2. **Найти изменения в скрипте:** `git log -p <writer-script> --since='2 weeks ago'` → искать threshold/глобу/exclude-list изменения.
3. **Применить smoke-тест coverage:** см. [lessons_infra_fix_coverage_smoke.md](../../../memory/lessons_infra_fix_coverage_smoke.md). Конкретные команды:
   ```bash
   cd <target-repo>
   # Tracked файлы
   git log --name-only --since="14 days ago" --pretty=format: | sort -u | head -50
   git log --since="14 days ago" --pretty=format:"%an %s" | sort -u | head -20
   # Untracked / modified СЕЙЧАС (важно: ловит class B writers)
   git status --porcelain | head -20
   ```

   **Ограничение:** `git log --name-only` находит только **tracked** writer'ов. Class B (gitignored-untracked) выпадают — для них нужен парный `git status --porcelain`.
4. **Починить writer:** изменение должно учитывать всех concurrent writer'ов (если их больше одного).
5. **Коммит + push** в target-repo.
6. **Verify:** запустить writer вручную (`bash <writer-script>`) → проверить что target-paths коммитятся.

## Шаг 4 — Fix Класса B (missing gitignore)

1. **Verify untracked:** `cd <target-repo> && git ls-files | grep <path>` → должен быть пустой вывод.
2. **Если есть hits** — путь already tracked. Это **НЕ Класс B**. Перейти к Шагу 3 (regression).
3. **Добавить в .gitignore:**
   ```
   # === Operational derived state (WP-<N> <symptom>) ===
   # <writer-name> output — <description>
   <path>/
   ```
4. **Коммит + push** в target-repo. Никаких дополнительных действий — `.gitignore` начнёт работать с первого git status.

## Шаг 5 — Deployment drift (старая версия watchdog'а на сервере)

Симптом: TG-сообщение в формате старой версии (`(dirty)` без путей) при том что git HEAD `iwe-server-config` имеет новую версию.

**Verify drift:**
```bash
ssh tseren@95.216.75.148 'systemctl cat iwe-scheduler.service' | grep ExecStartPre
# Извлечь /nix/store/<hash>-iwe-pull-repos путь
ssh root@95.216.75.148 'cat <тот же /nix/store path>'
# Сравнить с modules/systemd-timers.nix → pullScript блок
```

Если расхождение — нужно `nixos-rebuild switch`:

```bash
cd ~/IWE/iwe-server-config
nixos-rebuild switch --flake .#tsekh-1 --target-host root@95.216.75.148
ssh root@95.216.75.148 'nix-env --list-generations --profile /nix/var/nix/profiles/system | tail -3'
# Verify: новая generation = current; timestamp > git commit time
```

**Critical rule:** коммит в `iwe-server-config` без `nixos-rebuild switch` = **не fix**. Просто git-история.

## Шаг 6 — Verify

После всех fix'ов:

1. **Через 1 час** проверить TG — не должно быть новых dirty-алертов для починенных путей.
2. **Если warning повторился** — Класс был определён неправильно, либо есть ещё writer, не покрытый fix'ом. Вернуться к Шагу 2.
3. **Записать lesson** в `memory/lessons_*.md` если найден новый класс или паттерн.

## Шаг 7 — Запись в STAGING.md

Если runbook сработал — добавить запись:

```
S-NN | Watchdog dirty <repo>/<path> | <class A|B> fix | <commit-sha> | done
```

При второй итерации того же класса — поднять scope в WP-7 как «класс <X> регулярно повторяется».

---

## Anti-pattern: «попробую auto-stash в watchdog'е»

Auto-stash в watchdog (как `ad245e4` 28 мая) — **плохой fix**:
- Накапливает `stash@{0..N}` без выгрузки (N+1 каждый тик).
- Скрывает истинную проблему — writer должен коммитить или путь должен быть в gitignore.
- Не лечит причину, только маскирует симптом.

Если возникает соблазн добавить auto-stash в watchdog — это сигнал что Шаг 2 классификация не сделана корректно.

## История применения

| Дата | РП | Класс | Fix | Outcome |
|---|---|---|---|---|
| 2026-05-30 | WP-7 WD | A (DS-agent-workspace `f70e466` regression) | LAST_COMMIT_TS grep по своим коммитам | (verify pending) |
| 2026-05-30 | WP-7 WD | B (DS-ecosystem-development backup-reports/) | .gitignore | (verify pending) |
