## Авторские проверки Quick Close

### CHANGELOG FMT
Если были коммиты в FMT-exocortex-template: обновить `FMT-exocortex-template/CHANGELOG.md` **сейчас**, пока контекст изменений свежий. На Day Close контекст потерян.

### strategy_day gate (Day Close)
При записи «Завтра начать с:» в DayPlan — проверить: завтра = strategy_day?
```bash
grep 'strategy_day:' ~/.claude/projects/-Users-tserentserenov-IWE/memory/day-rhythm-config.yaml
```
Если завтра strategy_day → **DayPlan НЕ создавать**. Carry-over записать в WeekPlan (секция «План на {день недели}»).

### Верификатор R23: передавать абсолютные пути

При запуске sub-agent Haiku R23 — передавать файлы как **абсолютные пути** (не `git diff --name-only`):
```bash
git -C ~/IWE/DS-my-strategy diff --name-only HEAD~1 | sed 's|^|/Users/tserentserenov/IWE/DS-my-strategy/|'
```
Иначе: субагент не найдёт файлы с пробелами в именах (`WeekPlan W14 *.md`, `DayPlan *.md`) → ложные ❌.

---

### Новый РП, созданный за сессию

Если за сессию создан новый РП (context file в `inbox/WP-{N}-*.md`) → обязательно записать во **все 3 места**:
1. `docs/WP-REGISTRY.md` — добавить строку со статусом ⏳
2. `current/WeekPlan W{N} *.md` — добавить строку в таблицу «План на неделю»
3. `current/DayPlan YYYY-MM-DD.md` — добавить строку в таблицу «План на сегодня»

> Это отдельно от правила «WP-REGISTRY при done». Done-РП зачёркивается. Новый pending-РП добавляется.

### Закрытый за сессию РП — синхронизация агрегатов

Если за сессию закрыт РП (статус → done) → недостаточно зачеркнуть строку в таблице. Подчистить **все производные агрегаты в WeekPlan**:
1. **Сводка приоритетов** — пересчитать счётчики (🔴/🟡/🟢/⚪ N РП).
2. **Сквозные упоминания** в плане недели (секции «План на Сб/Вс», «Carry-over», «🟢/⚪») — зачеркнуть/убрать строку с закрытым РП.
3. **Header `updated:`** WeekPlan — добавить «WP-{N} ✅ закрыт» в текущий день.

> Триггер capture: WP-263 25 апр — статус-строка ✅, но сводка «⚪ 4 РП» и план Сб/Вс «WP-263 после Ф1 ArchGate» остались висеть. Пользователь увидел расхождение → отдельный commit cleanup. Симметрично правилу выше.

### Data flow self-check (при изменениях >1 файла)

> SOTA: Chain-of-Verification (Meta, ACL 2024), Pre-mortem (PROClaim 2026).
> Предотвращает: неполный контекст, разрыв data flow, motivated reasoning.

- [ ] **Full-file read:** каждый изменённый файл прочитан полностью (не фрагмент через offset/limit)?
- [ ] **Downstream consumers:** для каждого изменённого output — найден и прочитан потребитель?
- [ ] **Contract match:** типы/формат output совпадают с ожиданиями потребителя?
- [ ] **Scope honesty:** scope определён анализом кода, а не подогнан под заранее выбранный вывод?

> Если хотя бы один ❌ → запустить `/verify chain` или `/verify adversarial` перед коммитом.

**Чеклист:**
- [ ] **Новый РП:** если создан → WP-REGISTRY + WeekPlan + DayPlan обновлены
- [ ] **CHANGELOG FMT:** коммиты в FMT → CHANGELOG обновлён (пока контекст свежий)
- [ ] **strategy_day gate:** если завтра strategy_day → carry-over в WeekPlan, не в DayPlan
