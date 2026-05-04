## Авторские проверки Week Close

### Guard: канонический множитель (Ф8.3, WP-139)

> **Цель:** Week Close НЕ завершается при 0x/пустом множителе — силент-фейл парсера невидим.

**Выполнить ДО написания поста:**

```bash
# Запустить dry-run и проверить weekly_multiplier
MULT_JSON=$(bash ~/IWE/DS-IT-systems/DS-ai-systems/synchronizer/scripts/dt-collect.sh --dry-run 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
mult = data.get('weekly_multiplier', 0)
budget = data.get('weekly_budget_closed', 0)
print(f'weekly_multiplier={mult}, weekly_budget_closed={budget}')
")
echo "$MULT_JSON"
```

**Критерий блокировки:** `weekly_multiplier == 0` И `weekly_budget_closed == 0`
- Если оба 0 → **СТОП Week Close.** Парсер мультипликатора не нашёл данные.
  Диагностика: `bash ~/IWE/DS-IT-systems/DS-ai-systems/synchronizer/scripts/dt-collect.sh --dry-run`
  Проверить: DayPlan-ы за неделю существуют? Формат «Бюджет закрыт» совпадает?
  Зафиксировать вручную множитель в WeekPlan и только потом закрыть.
- Если `weekly_multiplier > 0` → продолжать.
- Если только `weekly_budget_closed > 0` но `weekly_multiplier == 0` → WakaTime недоступен, не блокер (записать ∞/N/A).

- [ ] **Guard выполнен** — `weekly_multiplier` не 0 (или задокументировано исключение)

---

### Написание недельного поста из черновика (S-19, тестируется)

> **Источник:** `DS-Knowledge-Index-Tseren/docs/{YYYY}/{NN}-{месяц}/week-draft-w{NN}.md`
> **Цель:** финальный пост в `DS-Knowledge-Index-Tseren/docs/{YYYY}/{NN}-{месяц}/{YYYY-MM-DD}-week-review-w{NN}.md`
> **Правило:** писать пост НЕ с нуля — на основе накопленного черновика (4 уровня × 7 дней + метрики + инсайты).

**Алгоритм:**
1. Прочитать `week-draft-w{NN}.md` целиком
2. Выделить главный инсайт недели (что из 4 уровней повторялось или выделилось)
3. Предложить 3-5 вариантов заголовка → пользователь выбирает
4. Написать пост 400-700 слов: 4 уровня переплетены без явных заголовков (правило §3 `DS-Knowledge-Index-Tseren/CLAUDE.md`)
5. Встроить метрики в текст (не таблицей)
6. Финал: carry-over → W{N+1} из секции черновика
7. Итоговая строка-метрики (коммиты, репо, дни, задачи)
8. Frontmatter: `target: club`, `audience: community`, `tags: [итоги-недели, W{NN}]`, `status: ready`
9. Exit Protocol поста (§5 CLAUDE.md репо): обложка → README.md → commit/push

**После публикации:**
- Черновик не удаляется — остаётся в `docs/{YYYY}/{NN}-{месяц}/` как исходник
- На следующей неделе создаётся новый `week-draft-w{NN+1}.md` на Пн Day Close (первая запись дня)

- [ ] **Черновик прочитан** целиком
- [ ] **Главный инсайт выделен**
- [ ] **3-5 заголовков предложены** → выбран
- [ ] **Пост написан** (400-700 слов, 4 уровня переплетены)
- [ ] **Метрики недели посчитаны** и встроены в текст
- [ ] **Интегральный показатель** (прогресс месяца) записан
- [ ] **Exit Protocol поста** выполнен (обложка, README, commit, push)