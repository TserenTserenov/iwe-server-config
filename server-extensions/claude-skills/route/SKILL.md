---
name: route
description: "Маршрутизация материала пользователя по DP.KR.002 — возвращает класс (1-4) + дом + режим + обоснование теста классификации"
type: utility
version: 0.1.0
status: experimental
created: 2026-07-15
layer: L4-Personal
scope: project

agents: single
interaction: multi-step
model_default: sonnet

triggers:
  slash: [/route]
  phrases: ["куда положить", "класс материала", "как класс", "куда сохранить", "как классифицировать материал", "к какому классу отнести", "где это хранить", "куда это положить в IWE"]

realizes: [DP.SC.058]
role: [DP.ROLE.088]
gates_required: [integration]
gates_enforced: [integration]
gates_rationale: "integration — /route реализует DP.SC.058 (обещание) и DP.ROLE.088 (роль); IntegrationGate шаги 1-3 пройдены до реализации кода (WP-449 Ф3.1)"

related:
  uses: [DP.KR.002, DP.D.246, DP.SC.055]
  implements_for: [WP-449]

bundled_resources:
  - scripts/
  - tests/
---

# Скилл `/route` — Маршрутизатор материала пользователя

> **Реализует:** DP.SC.058 (обещание Router)  
> **Роль:** DP.ROLE.088 (Маршрутизатор)  
> **Использует:** DP.KR.002 (карта классов), DP.D.246 (различение индекс ≠ указатель)

## Назначение

Классифицировать материал пользователя (файл, ссылка, заметка, репо, описание) по 4 онтологическим классам (DP.KR.002 §2-5) и вернуть: класс + дом + режим + тест-обоснование. Поддерживает интерактивные запросы, batch-обработку, валидацию существующего материала.

## When to use

- Пользователь спрашивает: «Куда положить эту ссылку?» → `/route https://example.com`
- Агент при захвате нового материала нужна классификация → `/route --batch ~/obsidian-export/`
- Интегратор проверяет консистентность базы → `/route --validate ~/my-pack/`
- Граничный случай, неясный класс → `/route --model opus document.pdf` (LLM deep-inspect)

## Интерфейс

### Синтаксис

```bash
/route <материал> [опции]
```

### Аргументы

- `<материал>`: путь к файлу, URL, или краткое описание
- `--batch [path]`: обработать папку → CSV с результатами
- `--validate`: переклассифицировать существующий материал + проверить
- `--model [opus|sonnet|haiku]`: LLM для deep-inspection (default: sonnet)
- `--output [json|csv|text]`: формат результата (default: text)
- `--confidence-threshold [0.0-1.0]`: return-if-confident-above (default: 0.8)

### Примеры использования

```bash
# 1. Интерактивный запрос
/route ~/Downloads/ski-guide.pdf
# Output:
# Класс: 4 — Субъективная оценка
# Дом: внешний (Notion)
# Режим: pointer (candidate)
# Тест: По форме контента — мнение/оценка, расширяемо
# Уверенность: 0.92

# 2. Batch-обработка папки
/route --batch ~/obsidian-export/ --output report.csv
# Output: CSV с N строками (материал, класс, дом, режим, тест, confidence)

# 3. Валидация существующей разметки
/route --validate ~/Pack/PACK-кибербез/ --output delta.json
# Output: JSON diff {changed: [], unchanged: [], conflicts: []}

# 4. Сомнение → deep-inspect
/route --model opus contracts/mystery-agreement.pdf --confidence-threshold 0.7
```

---

## Algorithm

### Step 1 — Parse input

**1a. Determine input type**

```
if is_file_path(input) and exists(input):
  input_type = FILE
  extract_metadata(file)  # name, ext, size, mtime
  if is_text_file(file):
    read_content(file, max_lines=100)  # first 100 lines for analysis
elif is_url(input):
  input_type = URL
  fetch_title_and_meta(url)
  if accessible and text_content:
    fetch_snippet(url, max_words=500)  # first 500 words
else:
  input_type = DESCRIPTION
  input_text = input  # use as-is
```

**1b. Normalize input** (extract entities, clean whitespace, detect language)

### Step 2 — Apply classification tests (DP.D.246 + DP.KR.002 §2)

For each class, execute test from DP.KR.002 §2:

**Class 1: Активное знание (Active Knowledge)**
- Test: Применимо ли это к другим системам такого же типа? / Is this a pattern / method / concept?
- If YES → Class 1, Home = Pack (personal domain or universal), Mode = index
- Confidence raised by: universal applicability, reusability across contexts, foundational nature

**Class 2: Состояние системы (System State)**
- Test: Про конкретную мою систему или про класс систем вообще? / Is this concrete & particular?
- If THIS-SYSTEM → Class 2, Home = DS-repo, Mode = pointer (sync)
- Confidence raised by: git history, specific commit/branch mention, system-specific config

**Class 3: Факт мира (Fact of World)**
- Test: Могу ли я это изменить? / Is this external & unchangeable?
- If NO (cannot change) → Class 3, Home = Vault/external, Mode = pointer (static) or external
- Confidence raised by: legal document markers, external source attribution, immutable content

**Class 4: Субъективная оценка (Subjective Evaluation)**
- Test: Это моя позиция / оценка / наблюдение? / Is this my opinion & revisable?
- If YES (my position) → Class 4, Home = external (Notion) + card in IWE, Mode = pointer (candidate)
- Confidence raised by: first-person language, evaluation markers, provisional tone

**Classes outside 1-4:** → Quarantine or "Out of map"

### Step 3 — Quarantine check (И5 fail-closed)

If material contains patterns:
- Foreign PII (other people's emails, phone numbers, names)
- Secrets (API keys, tokens, passwords — even encrypted)
- Payment data (credit card numbers, bank account details)

→ **Quarantine.** Block with reason. Do not place.

### Step 4 — Build response

Return structure (JSON / CSV / text):

```json
{
  "input": "ski-guide.pdf",
  "class": 4,
  "class_name": "Субъективная оценка",
  "home": "внешний (Notion) + карточка-указатель",
  "mode": "pointer",
  "mode_detail": "candidate",
  "test_applied": "Это моя позиция о горнолыжных курортах? → ДА (расширяемо, пересматриваемо)",
  "confidence": 0.92,
  "explanation": "Ресёрч о курортах — субъективная оценка, потенциальный upgrade к классу 1 при формализации",
  "alternative": null,
  "quarantine": false,
  "timestamp": "2026-07-15T12:34:56Z"
}
```

### Step 5 — Validate consistency (batch mode only)

When processing N files:
- Track patterns (e.g. all .md files in folder X → mostly class 1)
- Flag inconsistencies (same filename pattern, different classes)
- Suggest class re-check or context clarification

### Step 6 — Return result

Output per `--output` flag: JSON / CSV / text.

---

## Preconditions

- **DP.KR.002 available:** Skill reads `/IWE/PACK-digital-platform/.../DP.KR.002-...md` at runtime (loaded once, cached)
- **No external API required except Claude:** Batch mode works offline (tests only); deep-inspect mode requires Claude API
- **User has read access:** Files passed to `/route` must be readable by CLI process

## Bundled resources

- `route.py` — main classifier engine (classifies single material)
- `models.py` — DP.KR.002 rules + test implementations in code
- `llm_backend.py` — Claude API calls for deep-inspect mode
- `cli.py` — Click-based CLI interface
- `tests/` — pytest suite (6 scenarios from WP-449 01-scenarios.md)
- `scripts/verify-route.sh` — smoke test + schema validation

## Known limitations

- **Phase A (current):** Core classifier only. No LLM deep-inspect yet (Phase B)
- **Batch mode:** Returns CSV, no live feedback during processing
- **Confidence scoring:** Rule-based heuristics, not ML-trained. May vary with content format
- **Quarantine detector is a prototype-grade keyword list** (`api_key`, `token`, `password`, `secret`, `ANTHROPIC_`, card-related phrases) — NOT vendor-format regex, no checksum validation (Luhn, IBAN), no entropy detection. Compare to the production-hardened detector in guide-kit's `structurer/quarantine.py` (DP.SC.055, DP.ROLE.085 Разметчик) which covers known token formats (AWS, Anthropic, GitHub, Slack, Google), PEM keys, Luhn-valid cards, IBAN mod-97 — and went through 3 rounds of adversarial review. Do not rely on `/route`'s quarantine as the sole safety net for material that may contain real secrets or payment data until this gap is closed.

---

**Status:** Phase A implementation ready. See `route.py`, `models.py`, `tests/` for code.
