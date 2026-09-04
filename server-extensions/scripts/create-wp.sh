#!/usr/bin/env bash
# routing: helper  called-by=wp-gate  deterministic=true
# see DP.SC.159, DP.ROLE.059
# create-wp.sh — атомарное создание РП в локальных местах (inbox, REGISTRY, WeekPlan);
# внешний трекер (Linear) — условный пост-шаг, только при подключённом MCP (issue #321)
# see WP-297 Ф6.2 (<governance-repo>/inbox/WP-297-wp-lifecycle-architecture.md)
# see DP.M.010, DP.ROLE.037
#
# Использование:
#   bash create-wp.sh --title "Название" --budget 5h --priority P3 [--slug slug] [--repo "репо"] [--related "WP-150:dependency,WP-167:продукт"]
#   bash create-wp.sh --title "Название" --budget 5h --priority P3 --state "belonging (Оснащённость): из → в" --hypothesis "H-101 | —:infra|techdebt|order|spinoff" [--hypothesis-relation tests]
#   bash create-wp.sh --title "Название" --budget 5h --priority P3 --no-consent-check
#
# --state (WP-505): target state transition (WP-457 State-Transition Gate).
#   REQUIRED when <governance>/docs/state-axes-registry.yaml exists (author install);
#   optional otherwise (typical user install — gate inactive per template contract).
#   Must mention at least one gate_ready axis code from the registry file.
# --hypothesis (WP-496 Ф8): REQUIRED when <governance>/current/hypotheses-log.md exists —
#   H-NNN anchored in the log, or explicit dash with reason code (—:infra|techdebt|order|spinoff).
# --hypothesis-relation: tests|enables|responds|researches|operational|unclassified.
# New work must resolve unclassified before it is started; the default preserves
# older callers while making the missing strategic basis visible in frontmatter.
#
# Предусловие: consent state file должен существовать:
#   touch ${IWE:-$HOME/IWE}/.claude/state/wp-consent-{N}
#
# Совместимость: bash 3.2+ (macOS), bash 4+ (Linux)

set -uo pipefail

IWE="${IWE_ROOT:-$HOME/IWE}"

# --- Определить governance-репо ---
# Приоритет: (1) явная переменная IWE_GOVERNANCE_REPO → (2) DS-strategy (конвенция по умолчанию)
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
if [[ -z "${IWE_GOVERNANCE_REPO:-}" ]] && [[ ! -d "$IWE/$GOV_REPO" ]]; then
  echo "ERROR: IWE_GOVERNANCE_REPO not set and $GOV_REPO not found in $IWE" >&2
  exit 1
fi

STRATEGY="$IWE/$GOV_REPO"
REGISTRY="$STRATEGY/docs/WP-REGISTRY.md"
INBOX="$STRATEGY/inbox"
STATE_DIR="$IWE/.claude/state"

# --- Параметры ---
TITLE=""
BUDGET=""
PRIORITY="P3"
SLUG=""
REPO=""
RELATED=""
RESULT=""
STATE=""
HYPOTHESIS=""
HYPOTHESIS_RELATION="unclassified"
SKIP_CONSENT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)    TITLE="$2";    shift 2 ;;
    --budget)   BUDGET="$2";   shift 2 ;;
    --priority) PRIORITY="$2"; shift 2 ;;
    --slug)     SLUG="$2";     shift 2 ;;
    --repo)     REPO="$2";     shift 2 ;;
    --related)  RELATED="$2";  shift 2 ;;
    --result)   RESULT="$2";   shift 2 ;;
    --state)    STATE="$2";    shift 2 ;;
    --hypothesis) HYPOTHESIS="$2"; shift 2 ;;
    --hypothesis-relation) HYPOTHESIS_RELATION="$2"; shift 2 ;;
    --no-consent-check) SKIP_CONSENT=1; shift ;;
    *) echo "Неизвестный флаг: $1" >&2; exit 1 ;;
  esac
done

# --- Валидация ---
if [[ -z "$TITLE" || -z "$BUDGET" ]]; then
  echo "Использование: $0 --title \"Название\" --budget 5h [--priority P3] [--slug slug] [--repo репо] [--related \"WP-NNN:тип\"] [--result R3] [--state \"ось: из → в\"] [--hypothesis H-NNN] [--hypothesis-relation tests]" >&2
  exit 1
fi

case "$HYPOTHESIS_RELATION" in
  tests|enables|responds)
    [[ "${HYPOTHESIS:-—}" =~ ^H-[0-9]{3}$ ]] || {
      echo "❌ Для связи '$HYPOTHESIS_RELATION' нужен --hypothesis H-NNN" >&2
      exit 1
    }
    ;;
  researches|operational)
    [[ -z "$HYPOTHESIS" || "$HYPOTHESIS" == "—" || "$HYPOTHESIS" =~ ^—:(infra|techdebt|order|spinoff)$ ]] || {
      echo "❌ Для связи '$HYPOTHESIS_RELATION' укажите --hypothesis — или код причины —:<infra|techdebt|order|spinoff>" >&2
      exit 1
    }
    ;;
  unclassified) ;;
  *)
    echo "❌ Неизвестная связь с гипотезой: $HYPOTHESIS_RELATION" >&2
    exit 1
    ;;
esac

# --- State-Transition Gate (WP-457 / WP-505) ---
# When the axes registry exists, --state is mandatory and must reference a
# gate_ready axis; without the registry (typical user install) the gate is off.
AXES_FILE="$STRATEGY/docs/state-axes-registry.yaml"
GATE_READY_AXES=""
if [[ -f "$AXES_FILE" ]]; then
  GATE_READY_AXES=$(python3 - "$AXES_FILE" <<'PYEOF'
import sys, re
codes, code = [], None
for line in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r"\s*-\s*code:\s*(\S+)", line)
    if m:
        code = m.group(1)
    elif re.match(r"\s*gate_ready:\s*true\b", line) and code:
        codes.append(code)
        code = None
print(" ".join(codes))
PYEOF
)
  if [[ -z "$STATE" ]]; then
    echo "🚫 State-Transition Gate (WP-457): --state обязателен — реестр осей найден:" >&2
    echo "   $AXES_FILE" >&2
    echo "   Формат: --state \"<ось> (<русское имя>): <из> → <в>\"" >&2
    echo "   Допустимые оси (gate_ready): $GATE_READY_AXES" >&2
    exit 1
  fi
  STATE_AXES=""
  for ax in $GATE_READY_AXES; do
    if [[ "$STATE" == *"$ax"* ]]; then
      STATE_AXES="$STATE_AXES $ax"
    fi
  done
  if [[ -z "$STATE_AXES" ]]; then
    echo "🚫 State-Transition Gate: в --state не найден ни один gate_ready код оси" >&2
    echo "   Допустимые: $GATE_READY_AXES" >&2
    echo "   Передано: $STATE" >&2
    exit 1
  fi
fi

# --- Hypothesis Gate (WP-496 Ф8) ---
# Mirror of the State-Transition Gate: when the hypotheses log exists (author
# install), --hypothesis is mandatory — either an H-NNN recorded in the log or
# an explicit dash with a reason code. A WP references an EXISTING bet
# (many WPs per hypothesis); new hypotheses enter only via the pilot's entry
# filter, never as a side effect of creating a WP. Installs without the log
# keep the gate off.
HYP_LOG="$STRATEGY/current/hypotheses-log.md"
if [[ -f "$HYP_LOG" ]]; then
  HYP_USAGE="H-NNN (из current/hypotheses-log.md) либо —:infra | —:techdebt | —:order | —:spinoff"
  if [[ -z "$HYPOTHESIS" ]]; then
    echo "🚫 Hypothesis Gate (WP-496): --hypothesis обязателен — журнал гипотез найден:" >&2
    echo "   $HYP_LOG" >&2
    echo "   Формат: $HYP_USAGE" >&2
    exit 1
  fi
  case "$HYPOTHESIS" in
    "—:infra"|"—:techdebt"|"—:order"|"—:spinoff") : ;;
    *)
      HYP_IDS=$(grep -oE '\bH-[0-9]{3}\b' <<<"$HYPOTHESIS" | sort -u)
      if [[ -z "$HYP_IDS" ]]; then
        echo "🚫 Hypothesis Gate: не распознан ни H-NNN, ни код причины" >&2
        echo "   Передано: $HYPOTHESIS" >&2
        echo "   Формат: $HYP_USAGE" >&2
        exit 1
      fi
      for HID in $HYP_IDS; do
        if ! grep -q "id=$HID " "$HYP_LOG"; then
          echo "🚫 Hypothesis Gate: $HID не найден среди якорей журнала ($HYP_LOG)" >&2
          echo "   Новая гипотеза заводится через входной фильтр журнала, не через create-wp" >&2
          exit 1
        fi
      done
      ;;
  esac
fi

# Registry cell «Ставка»: Russian axis names + hypothesis id (WP-505).
axis_ru() {
  case "$1" in
    permission) echo "Доверие" ;;
    belonging)  echo "Оснащённость" ;;
    engagement) echo "Увлечённость" ;;
    mastery)    echo "Компетентность" ;;
    community)  echo "Включённость" ;;
    mentorship) echo "Забота" ;;
    *)          echo "$1" ;;
  esac
}
STAKE_CELL="—"
if [[ -n "$STATE" && -n "${STATE_AXES:-}" ]]; then
  STAKE_CELL=""
  for ax in $STATE_AXES; do
    [[ -n "$STAKE_CELL" ]] && STAKE_CELL="${STAKE_CELL}+"
    STAKE_CELL="${STAKE_CELL}$(axis_ru "$ax")"
  done
  if [[ -n "$HYPOTHESIS" && "$HYPOTHESIS" != "—" ]]; then
    STAKE_CELL="${STAKE_CELL} · ${HYPOTHESIS}"
  fi
fi

# --- Найти следующий номер WP ---
WP_NUM=$(python3 - "$REGISTRY" <<'PYEOF' 2>/dev/null
import sys, re
registry = sys.argv[1]
max_num = 0
try:
    with open(registry, "r", encoding="utf-8") as f:
        for line in f:
            # Ищем строки вида | 297 |, | ~~297~~ | или legacy-формат | WP-297 |
            m = re.match(r"^\|\s*[*~]*(?:WP-)?(\d+)[*~]*\s*\|", line)
            if m:
                n = int(m.group(1))
                if n > max_num:
                    max_num = n
except Exception as e:
    print(0, file=sys.stderr)
print(max_num + 1)
PYEOF
)

if [[ -z "$WP_NUM" || "$WP_NUM" -le 0 ]]; then
  echo "❌ Не удалось определить следующий номер WP из REGISTRY" >&2
  exit 1
fi

echo "📋 Следующий номер WP: $WP_NUM"

# issue #338 п.4: без паддинга "WP-9" в листинге сортируется после "WP-10".
# WP_ID — только для строк с префиксом "WP-" (пути, заголовки); frontmatter
# wp:, consent-файл и колонки "#" REGISTRY/WeekPlan остаются bare-числом.
WP_ID=$(printf '%03d' "$WP_NUM")

# --- Проверка consent ---
CONSENT_FILE="$STATE_DIR/wp-consent-${WP_NUM}"
if [[ "$SKIP_CONSENT" -eq 0 ]]; then
  if [[ ! -f "$CONSENT_FILE" ]]; then
    echo "🚫 WP Gate: нет согласия пользователя на создание WP-${WP_NUM}" >&2
    echo "   Создайте consent file и повторите:" >&2
    echo "   touch $CONSENT_FILE" >&2
    exit 1
  fi
  echo "✅ Consent: $CONSENT_FILE"
fi

# --- Дата ---
TODAY=$(date +%Y-%m-%d)

# --- Slug из title (если не задан) ---
if [[ -z "$SLUG" ]]; then
  SLUG=$(echo "$TITLE" | python3 -c "
import sys, re, unicodedata
s = sys.stdin.read().strip().lower()
# Транслитерация кириллицы
tr = {
  'а':'a','б':'b','в':'v','г':'g','д':'d','е':'e','ё':'yo','ж':'zh',
  'з':'z','и':'i','й':'j','к':'k','л':'l','м':'m','н':'n','о':'o',
  'п':'p','р':'r','с':'s','т':'t','у':'u','ф':'f','х':'kh','ц':'ts',
  'ч':'ch','ш':'sh','щ':'shch','ъ':'','ы':'y','ь':'','э':'e','ю':'yu','я':'ya'
}
result = ''
for c in s:
    result += tr.get(c, c)
result = re.sub(r'[^a-z0-9]+', '-', result)
result = result[:40].strip('-')
print(result)
" 2>/dev/null || echo "wp-$(echo "$TITLE" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-30)")
fi

# Inbox convention (WP-434): every WP is a folder inbox/WP-N/ with main file WP-N.md.
# Slug lives in the title/frontmatter.  Архив появляется только при закрытии:
# предварительный stub конфликтовал с close-wp.sh и мог затереть контекст.
WP_DIR="$INBOX/WP-${WP_ID}"
WP_FILE="$WP_DIR/WP-${WP_ID}.md"
mkdir -p "$WP_DIR"

echo "🚀 Создаю WP-${WP_ID}: $TITLE"
echo "   Папка: inbox/WP-${WP_ID}/WP-${WP_ID}.md"
echo "   Бюджет: $BUDGET | Приоритет: $PRIORITY"

# --- Atomicity (Ф-script-contract-gate, Этап 2): шаги 1-4 пишут в 3 разных
# места (inbox, REGISTRY, WeekPlan) без общей транзакции. Раньше отказ на шаге
# 3/4 оставлял частично созданный WP и не считался ошибкой — падение WeekPlan
# просто печаталось в stderr и скрипт продолжал к «✅ WP создан». Откат ниже
# гарантирует: либо все 4 шага прошли, либо ни один след не остался.
#
# WP-530 (2026-08-20): раньше здесь снимался cp-снимок REGISTRY/WeekPlan для
# восстановления по хэшу при откате -- отброшено (см. _rollback_remove_my_row
# ниже) в пользу удаления вставленной строки по номеру WP, не восстановления
# всего файла: "откатить к снимку" ломается, если сама эта сессия уже успешно
# дописала свою строку на предыдущем шаге -- снимок тогда либо устаревший
# (откатывает чужую параллельную правку), либо равен текущему состоянию
# (cp снимка в себя же не убирает мою строку) -- юнит-тестом подтверждено,
# что оба варианта некорректны для этого класса гонки.
SNAPSHOT_DIR=$(mktemp -d)
trap 'rm -rf "$SNAPSHOT_DIR"' EXIT
WEEKPLAN=$(find "$STRATEGY/current" -maxdepth 1 -name "WeekPlan*.md" 2>/dev/null | sort -r | head -1)

# Определён здесь (не при первом использовании на Шаге 2, как было раньше) --
# _rollback_remove_my_row ниже вызывается из rollback_wp_creation() задолго
# до Шага 2, ей эта переменная нужна уже сейчас, не откладывая присваивание.
SESSION_GUARD="${IWE_SCRIPTS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/session-guard.sh"

# WP-530 (2026-08-20, живой прогон 5 параллельных create-wp.sh + два раунда
# cold-context review): "откатить весь файл к снимку" не работает для файла,
# который сама эта сессия уже успешно дописала на предыдущем шаге -- снимок
# после успеха совпадает с текущим содержимым, cp снимка в файл переписывает
# файл в себя же, строка остаётся (юнит-тестом подтверждено). Правильная
# операция -- убрать именно мою вставленную строку по номеру WP, тем же
# grep-якорем, что уже использует post-write verification (issue #256) выше
# по файлу.
#
# Второй раунд ревью нашёл ещё два дефекта в первой версии этой функции:
# (1) запись шла голым `cp`, в обход wp-context-guarded-edit -- единственное
# место в файле без CAS-защиты, хотя ИМЕННО эта защита была целью всего
# WP-530; параллельный писатель на ДРУГОЙ номер мог гонкой затереть или
# воскресить чужую строку в окне между hash-проверкой отката и его же cp;
# (2) `grep -vE` возвращает exit 1, когда не печатает НИ ОДНОЙ строки (тест:
# файл из двух строк с одним и тем же номером -- grep -v дал пустой вывод) --
# безусловный cp после него обнулял бы весь REGISTRY/WeekPlan вместо удаления
# одной строки. Оба исправлены: явная guarded-edit запись + проверка, что
# результат grep -v непуст и короче исходника ровно на 1 строку, до cp.
_rollback_remove_my_row() {  # _rollback_remove_my_row <target> <wp-num>
  local target="$1" wp_num="$2"
  [[ -f "$target" ]] || return 0
  local pattern="\\| \\*?\\*?(WP-)?${wp_num}\\*?\\*? \\|"
  grep -qE "$pattern" "$target" || return 0

  local hash_before tmp
  hash_before=$({ shasum -a 256 "$target" 2>/dev/null || sha256sum "$target" 2>/dev/null; } | cut -d' ' -f1)
  tmp=$(mktemp)
  grep -vE "$pattern" "$target" > "$tmp"

  # grep -c '', не wc -l: wc -l считает переводы строк, не строки текста --
  # файл без завершающего \n на последней строке (обычное дело для ручной
  # правки REGISTRY/WeekPlan) занижал бы lines_before на 1 и ложно триггерил
  # бы safety-net ниже даже на полностью корректном удалении (найдено
  # cold-context review, раунд 3, живым тестом на файле без финальной \n).
  local lines_before lines_after
  lines_before=$(grep -c '' "$target")
  lines_after=$(grep -c '' "$tmp")
  if [[ ! -s "$tmp" ]] || [[ "$lines_after" -ne $((lines_before - 1)) ]]; then
    echo "⚠️  Откат: unexpected diff убирая строку WP-${wp_num} из $target (было ${lines_before} строк, стало бы ${lines_after}) -- файл не тронут, проверь вручную" >&2
    rm -f "$tmp"
    return 1
  fi

  if [[ -x "$SESSION_GUARD" ]] && [[ -n "$hash_before" ]]; then
    if ! bash "$SESSION_GUARD" wp-context-guarded-edit "$target" --expected-hash "$hash_before" -- cp "$tmp" "$target"; then
      echo "⚠️  Откат: $target изменился с момента чтения -- строка WP-${wp_num} не убрана, проверь вручную" >&2
      rm -f "$tmp"
      return 1
    fi
  else
    cp "$tmp" "$target"
  fi
  rm -f "$tmp"
}

rollback_wp_creation() {
  echo "↩️  Откат: WP-${WP_ID} не создан целиком, отменяю частичные записи" >&2
  rm -rf "$WP_DIR"
  _rollback_remove_my_row "$REGISTRY" "$WP_NUM"
  if [[ -n "$WEEKPLAN" ]]; then
    _rollback_remove_my_row "$WEEKPLAN" "$WP_NUM"
  fi
}

# --- Сформировать строки таблицы связок ---
RELATED_ROWS="| — | — | — | нет связок |"
if [[ -n "$RELATED" ]]; then
  RELATED_ROWS=""
  IFS=',' read -ra REL_ITEMS <<< "$RELATED"
  for rel_item in "${REL_ITEMS[@]}"; do
    rel_item="${rel_item# }"
    rel_wp="${rel_item%%:*}"
    rel_type="${rel_item#*:}"
    [[ "$rel_wp" == "$rel_type" ]] && rel_type="—"
    RELATED_ROWS+="| ${rel_wp} | 🟡 | ${rel_type} | — |
"
  done
fi

# --- Шаг 1: context file ---
echo ""
echo "1/5 context file..."

# state_transition goes into frontmatter only when provided (gate off on
# installs without the axes registry); hypothesis always present, "—" = no bet.
FM_STAKE=""
if [[ -n "$STATE" ]]; then
  FM_STAKE="state_transition: \"${STATE}\"
"
fi
FM_STAKE="${FM_STAKE}hypothesis: \"${HYPOTHESIS:-—}\"
hypothesis_relation: \"${HYPOTHESIS_RELATION}\""

# WP-530 (2026-08-20, peer-session с Codex): два параллельных create-wp.sh
# могут прочитать один и тот же REGISTRY до того, как первый допишет свою
# строку -- оба получат один WP_NUM, оба создали бы файл, второй молча
# перезаписал бы результат первого без единого сигнала. Пишем в temp сначала,
# затем финальную запись пропускаем через wp-context-guarded-edit
# --expected-absent -- та же CAS-семантика, что уже подключена в
# archive-done-wp.sh (--expected-hash) для другого класса гонки. Graceful
# degradation при отсутствии session-guard.sh (урезанная копия шаблона) --
# та же логика, что в archive-done-wp.sh: не блокируем создание тем, чего
# нет, но и не притворяемся, что conflict-проверка сработала.
# В $SNAPSHOT_DIR, не в системный /tmp напрямую: тот каталог уже покрыт
# существующим trap ... EXIT (строка выше) -- переиспользуем готовую очистку
# вместо дублирования её для ещё трёх temp-файлов (WP-530 review, Medium).
WP_FILE_TMP="$SNAPSHOT_DIR/wp-file.tmp"
if ! cat > "$WP_FILE_TMP" <<WPEOF
---
wp: ${WP_NUM}
title: "${TITLE}"
status: pending
priority: ${PRIORITY}
budget: ${BUDGET}
created: ${TODAY}
last_session: ${TODAY}
related: []
${FM_STAKE}
activation: on-demand
---

# WP-${WP_ID}: ${TITLE}

## Проблема

[Описать неудовлетворённость / проблему, которую решает этот РП]

## Артефакт

[Конкретный результат — существительное-артефакт с критериями]

## Связки с РП

| РП | Сила | Тип | Что передаётся |
|----|------|-----|----------------|
${RELATED_ROWS}

## Фазы реализации

### Ф1 — [Название фазы] (~?h)

- [ ] ...

## Что узнали

[Заполняется при сессиях]

## Осталось

**Что пробовали:** не начат
**Что узнали:** —
  → memory: не нужно
**Что дальше:**
- [ ] Открыть сессию, прочитать задачу, составить план
**Следующий шаг:** Открыть сессию — прочитать задачу, составить план
**Контекст для следующей сессии:** РП только создан, нет контекста
WPEOF
then
  echo "❌ Не удалось записать context file: $WP_FILE" >&2
  rm -f "$WP_FILE_TMP"
  rollback_wp_creation
  exit 1
fi

if [[ -x "$SESSION_GUARD" ]]; then
  if ! bash "$SESSION_GUARD" wp-context-guarded-edit "$WP_FILE" --expected-absent -- cp "$WP_FILE_TMP" "$WP_FILE"; then
    echo "❌ WP-${WP_ID}: $WP_FILE уже создан параллельной сессией — эта карточка не записана, номер не занят." >&2
    echo "   Запусти create-wp.sh заново — получишь следующий свободный номер." >&2
    rm -f "$WP_FILE_TMP"
    # Обычный rollback_wp_creation() здесь НЕЛЬЗЯ: guard только что подтвердил,
    # что $WP_DIR содержит УСПЕШНО записанный файл ЧУЖОЙ параллельной сессии
    # (не мой недописанный черновик) -- rm -rf стёр бы чужой результат (живая
    # находка WP-530 2026-08-20: без этой ветки прогон 5 параллельных
    # create-wp.sh на одном номере физически удалял карточку победителя).
    # REGISTRY/WeekPlan на этом шаге ещё не тронуты этим процессом вообще --
    # откатывать нечего, только выйти без победного REGISTRY-шага ниже.
    echo "↩️  WP-${WP_ID}: карточка не моя, откатывать нечего -- REGISTRY/WeekPlan не тронуты" >&2
    exit 1
  fi
else
  # Нет session-guard.sh рядом (напр. урезанная копия шаблона) -- не
  # блокируем создание тем, чего нет, но и не притворяемся, что
  # conflict-проверка сработала.
  cp "$WP_FILE_TMP" "$WP_FILE"
fi
rm -f "$WP_FILE_TMP"

echo "   ✅ $WP_FILE"
if [[ "$HYPOTHESIS_RELATION" == "unclassified" ]]; then
  echo "   ⚠️  Связь с гипотезой не определена: до начала РП выберите tests/enables/responds/researches/operational" >&2
fi

# --- Шаг 2: WP-REGISTRY.md ---
echo "2/5 WP-REGISTRY.md..."

# WP-530 (2026-08-20, peer-session с Codex, п.7 живой находки): защита
# WP_FILE одна не закрывает гонку -- параллельный create-wp.sh мог дописать
# REGISTRY между чтением этого процесса и его собственной записью. Живым
# прогоном 5 параллельных create-wp.sh на одном REGISTRY подтверждено: без
# этой защиты второй писатель тихо перезаписывал строку первого. Тот же
# {sha256, absent}-паттерн, что уже закрыл WP_FILE: снимаем хэш перед
# python-записью, python пишет в temp вместо прямой перезаписи, финальный
# cp идёт под wp-context-guarded-edit.
REGISTRY_HASH_BEFORE=""
if [[ -f "$REGISTRY" ]]; then
  REGISTRY_HASH_BEFORE=$({ shasum -a 256 "$REGISTRY" 2>/dev/null || sha256sum "$REGISTRY" 2>/dev/null; } | cut -d' ' -f1)
fi
REGISTRY_TMP="$SNAPSHOT_DIR/registry.tmp"
cp "$REGISTRY" "$REGISTRY_TMP"

if ! python3 - "$REGISTRY_TMP" "$WP_NUM" "$PRIORITY" "$TITLE" "$REPO" "$BUDGET" "$GOV_REPO" "$STAKE_CELL" "$WP_ID" <<'PYEOF'
import sys
registry_path, wp_num, priority, title, repo, budget, gov_repo, stake, wp_id = sys.argv[1:10]

with open(registry_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

# Найти строку-разделитель после заголовка таблицы (|---|---|...)
insert_at = None
header_line = None
for i, line in enumerate(lines):
    if line.strip().startswith("|---") and i > 0 and lines[i-1].strip().startswith("| #"):
        insert_at = i + 1
        header_line = lines[i-1]
        break

if insert_at is None:
    print("❌ Не найден заголовок таблицы REGISTRY", file=sys.stderr)
    sys.exit(1)

# Схема-гард (issue #263, расширено issue #276): раньше писатель требовал ровно
# 6 колонок в заголовке — REGISTRY с легитимно другим числом/порядком колонок
# (та же семантика, доп. колонка сверху) блокировался целиком, хотя читатель
# (check-wp-format.py::find_column_indices) уже толерантен к такой вариации.
# Вместо счёта колонок — строим {имя: индекс} по фактическому заголовку и
# проверяем наличие 6 канонических имён, не их порядок/количество.
header_cols = [c.strip() for c in header_line.strip().strip("|").split("|")]
CANONICAL_NAMES = ["#", "P", "Название", "Ст", "Репо", "Бюджет"]
# issue #297: вендорский skeleton (templates/strategy-skeleton/docs/WP-REGISTRY.md)
# пишет полные русские имена («Приоритет», «Статус», «Репозитории»), а не короткие
# канонические («P», «Ст», «Репо») — та же семантика, другое написание. Раньше
# сверка требовала буквального совпадения и падала даже на только что созданном
# из вендорского skeleton реестре. Синонимы резолвятся к канонической колонке до
# проверки — те же строки find_column_indices() в check-wp-format.py уже читают
# оба варианта позиционным fallback'ом, здесь та же терпимость явным списком.
COLUMN_SYNONYMS = {
    "Приоритет": "P",
    "Статус": "Ст",
    "Репозитории": "Репо",
    "Репозиторий": "Репо",
}
col_index = {}
for i, name in enumerate(header_cols):
    canonical = COLUMN_SYNONYMS.get(name, name)
    col_index.setdefault(canonical, i)
missing_names = [name for name in CANONICAL_NAMES if name not in col_index]
if missing_names:
    # issue #364: old installs cannot receive seed/template changes through
    # update.sh, so migrate the first writable registry table in place. Existing
    # columns (including the useful legacy «Активация») remain untouched; missing
    # canonical columns are appended and old rows receive an explicit em dash.
    def append_cell(line, value):
        newline = "\n" if line.endswith("\n") else ""
        body = line.rstrip("\n").rstrip()
        if not body.endswith("|"):
            raise ValueError("not a markdown table row")
        return body[:-1].rstrip() + " | " + value + " |" + newline

    header_idx = insert_at - 2
    separator_idx = insert_at - 1
    for name in missing_names:
        lines[header_idx] = append_cell(lines[header_idx], name)
        lines[separator_idx] = append_cell(lines[separator_idx], "---")

    row_idx = insert_at
    while row_idx < len(lines) and lines[row_idx].lstrip().startswith("|"):
        for _ in missing_names:
            lines[row_idx] = append_cell(lines[row_idx], "—")
        row_idx += 1

    header_line = lines[header_idx]
    header_cols = [c.strip() for c in header_line.strip().strip("|").split("|")]
    col_index = {}
    for i, name in enumerate(header_cols):
        canonical = COLUMN_SYNONYMS.get(name, name)
        col_index.setdefault(canonical, i)
    print(
        "   ⚠ REGISTRY: добавлены отсутствовавшие колонки {} (legacy-колонки сохранены)".format(
            ", ".join(missing_names)
        )
    )

repo_cell = repo if repo else "{}/inbox/WP-{}/".format(gov_repo, wp_id)
values_by_name = {
    "#": wp_num,
    "P": priority,
    "Название": "**{}**".format(title),
    "Ст": "⏳",
    "Репо": repo_cell,
    "Бюджет": budget,
    # WP-505: optional column; silently skipped when the header lacks it
    "Ставка": stake,
}
row_cells = ["—"] * len(header_cols)
for name, idx in col_index.items():
    if name in values_by_name:
        row_cells[idx] = values_by_name[name]
new_row = "| " + " | ".join(row_cells) + " |\n"
lines.insert(insert_at, new_row)

with open(registry_path, "w", encoding="utf-8") as f:
    f.writelines(lines)

print("   ✅ REGISTRY: строка {} добавлена".format(wp_num))
PYEOF
then
  rm -f "$REGISTRY_TMP"
  rollback_wp_creation
  exit 1
fi

if [[ -x "$SESSION_GUARD" ]] && [[ -n "$REGISTRY_HASH_BEFORE" ]]; then
  if ! bash "$SESSION_GUARD" wp-context-guarded-edit "$REGISTRY" --expected-hash "$REGISTRY_HASH_BEFORE" -- cp "$REGISTRY_TMP" "$REGISTRY"; then
    echo "❌ REGISTRY изменился с момента чтения — параллельная сессия дописала свою строку первой." >&2
    echo "   WP-${WP_ID} не занял номер в REGISTRY; запусти create-wp.sh заново." >&2
    rm -f "$REGISTRY_TMP"
    rollback_wp_creation
    exit 1
  fi
else
  cp "$REGISTRY_TMP" "$REGISTRY"
fi
rm -f "$REGISTRY_TMP"

# Post-write verification (issue #256): create-wp.sh once reported success here
# without the row actually landing in REGISTRY — the writer above has no retry/lock,
# so confirm the row is really there before moving on.
# issue #263: некоторые репо исторически пишут номер РП с префиксом (| WP-N |),
# не голым числом (| N |) — grep должен принимать оба формата.
if ! grep -qE "\| \*?\*?(WP-)?${WP_NUM}\*?\*? \|" "$REGISTRY"; then
  echo "❌ REGISTRY write verification FAILED: строка WP-${WP_NUM} не найдена после записи" >&2
  rollback_wp_creation
  exit 1
fi

# --- Шаг 3: WeekPlan ---
echo "3/5 WeekPlan..."

# WEEKPLAN уже найден выше (снимок для отката, issue WP-507 про формат имени файла
# применён там же) — здесь используется тот же путь, не ищем повторно.
#
# WP-530 (2026-08-20, cold-context review нашёл High): та же уязвимость, что
# была у REGISTRY до фикса этой же сессии -- python писал напрямую в
# $WEEKPLAN без CAS-проверки, второй параллельный процесс с ДРУГИМ WP_NUM
# (гонка на номер уже разрешена guarded-edit на шаге 2 REGISTRY) мог дойти
# до этого шага одновременно, оба читают один WeekPlan, оба пишут -- второй
# write() тихо стирает строку первого. Тот же temp+guarded-cp паттерн, что
# уже применён к WP_FILE и REGISTRY выше в этом же файле.
if [[ -n "$WEEKPLAN" ]]; then
  WEEKPLAN_HASH_BEFORE=""
  if [[ -f "$WEEKPLAN" ]]; then
    WEEKPLAN_HASH_BEFORE=$({ shasum -a 256 "$WEEKPLAN" 2>/dev/null || sha256sum "$WEEKPLAN" 2>/dev/null; } | cut -d' ' -f1)
  fi
  WEEKPLAN_TMP="$SNAPSHOT_DIR/weekplan.tmp"
  cp "$WEEKPLAN" "$WEEKPLAN_TMP"
  if ! python3 - "$WEEKPLAN_TMP" "$WP_NUM" "$TITLE" "$PRIORITY" "$BUDGET" <<'PYEOF'
import sys, re
weekplan_path, wp_num, title, priority, budget = sys.argv[1:6]

# Маппинг приоритета → светофор
flag_map = {"P1": "🔴", "P2": "🟡", "P3": "🟢", "P4": "⚪", "P5": "⚪"}
flag = flag_map.get(priority, "⚪")
h_val = re.sub(r"[^0-9\-]", "", budget) or "?"

with open(weekplan_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

# issue (2026-07-27, WP-507 registration): the old writer matched a text anchor
# ("**Бюджет недели:**"/"**Бюджет итого:**") and a fixed 7-field column order —
# neither exists in the current WeekPlan format (summary line is now "**Бюджет:**",
# table header is "🚦 | # | РП | h | Источник | P | Статус | Результат"). Locate the table by
# its actual header instead, same name-based technique as the REGISTRY writer, so
# column order/extra columns don't silently corrupt the row.
header_line = None
insert_at = None
for i, line in enumerate(lines):
    if line.strip().startswith("|---") and i > 0 and "РП" in lines[i - 1] and "Статус" in lines[i - 1]:
        header_line = lines[i - 1]
        insert_at = i + 1
        break

if insert_at is None:
    print("   ⚠️  WeekPlan: таблица недели (заголовок РП/Статус) не найдена — добавить вручную", file=sys.stderr)
else:
    header_cols = [c.strip() for c in header_line.strip().strip("|").split("|")]
    values_by_name = {
        "🚦": flag,
        "#": wp_num,
        "РП": "**{}** — [описание]".format(title),
        "h": h_val,
        "Источник": "—",
        "P": priority,
        "Статус": "pending",
        "Результат": "[заполнить]",
    }
    row_cells = ["—"] * len(header_cols)
    for idx, name in enumerate(header_cols):
        if name in values_by_name:
            row_cells[idx] = values_by_name[name]
    new_row = "| " + " | ".join(row_cells) + " |\n"
    lines.insert(insert_at, new_row)
    with open(weekplan_path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    print("   ✅ WeekPlan: строка WP-{} добавлена".format(wp_num))
PYEOF
  then
    rm -f "$WEEKPLAN_TMP"
    echo "❌ WeekPlan write FAILED — WP-${WP_NUM} не создан" >&2
    rollback_wp_creation
    exit 1
  fi

  if [[ -x "$SESSION_GUARD" ]] && [[ -n "$WEEKPLAN_HASH_BEFORE" ]]; then
    if ! bash "$SESSION_GUARD" wp-context-guarded-edit "$WEEKPLAN" --expected-hash "$WEEKPLAN_HASH_BEFORE" -- cp "$WEEKPLAN_TMP" "$WEEKPLAN"; then
      echo "❌ WeekPlan изменился с момента чтения — параллельная сессия дописала свою строку первой." >&2
      echo "   WP-${WP_ID} не попал в WeekPlan; добавь строку вручную." >&2
      rm -f "$WEEKPLAN_TMP"
      rollback_wp_creation
      exit 1
    fi
  else
    cp "$WEEKPLAN_TMP" "$WEEKPLAN"
  fi
  rm -f "$WEEKPLAN_TMP"
else
  echo "   ⚠️  WeekPlan не найден в current/ — добавить вручную" >&2
fi

# --- Шаг 4: Strategy.md (только если --result задан и бюджет ≥3h) ---
echo "4/5 Strategy.md..."

BUDGET_H=$(echo "$BUDGET" | sed 's/[^0-9]//g')
if [[ -n "$RESULT" && "${BUDGET_H:-0}" -ge 3 ]]; then
  STRATEGY_FILE="$STRATEGY/docs/Strategy.md"
  python3 - "$STRATEGY_FILE" "$WP_ID" "$REPO" "$RESULT" <<'PYEOF'
import sys

strategy_path, wp_id, repo, result = sys.argv[1:5]

section_anchor = "### РП → Результаты"

with open(strategy_path, "r", encoding="utf-8") as f:
    content = f.read()

if section_anchor not in content:
    print("   ⚠️  Strategy.md: секция «{}» не найдена — добавить вручную".format(section_anchor))
    sys.exit(0)

section_start = content.index(section_anchor)
table_sep = content.find("|---|", section_start)
if table_sep == -1:
    print("   ⚠️  Strategy.md: разделитель таблицы не найден в секции — добавить вручную")
    sys.exit(0)

insert_at = content.index("\n", table_sep) + 1
repo_cell = repo if repo else "—"
new_row = "| WP-{} | {} | {} | pending |\n".format(wp_id, repo_cell, result)
content = content[:insert_at] + new_row + content[insert_at:]

with open(strategy_path, "w", encoding="utf-8") as f:
    f.write(content)
print("   ✅ Strategy.md: WP-{} → {} добавлен".format(wp_id, result))
PYEOF
elif [[ "${BUDGET_H:-0}" -ge 3 ]]; then
  echo "   ℹ️  РП ≥3h, но --result не задан — добавить маппинг в Strategy.md вручную"
else
  echo "   ℹ️  РП <3h — маппинг в Strategy.md не требуется"
fi

# --- Шаг 5: active-wp.md ---
echo "5/5 active-wp.md..."

BUILD_ACTIVE_WP=""
if [[ -f "$STRATEGY/scripts/build-active-wp.py" ]]; then
  BUILD_ACTIVE_WP="$STRATEGY/scripts/build-active-wp.py"
elif [[ -f "$IWE/FMT-exocortex-template/scripts/build-active-wp.py" ]]; then
  BUILD_ACTIVE_WP="$IWE/FMT-exocortex-template/scripts/build-active-wp.py"
fi

if [[ -n "$BUILD_ACTIVE_WP" ]]; then
  python3 "$BUILD_ACTIVE_WP" \
    && echo "   ✅ active-wp.md пересобран" \
    || echo "   ⚠️  build-active-wp.py завершился с ошибкой — пересобрать вручную" >&2
else
  echo "   ⚠️  scripts/build-active-wp.py не найден (искали в \`$STRATEGY/scripts/\` и \`$IWE/FMT-exocortex-template/scripts/\`) — пересобрать вручную" >&2
fi

# --- decision_made (WP-427 Ф8.14, best-effort, never blocks WP creation) ---
# Deterministic capture point for "согласование Ритуала перед РП" (WP-417 Ф3.6
# decision_load tile): the consent-file precondition above already proves the
# pilot said yes before this script could even reach step 1/5, so a successful
# run to this point IS the decision. Needs three pieces of local config that
# do not exist on a fresh checkout (confirmed live 2026-09-04, no PILOT_ACCOUNT_ID
# convention, no GATEWAY_SHARED_SECRET/TRACE_ACCOUNTANT_URL outside the deployed
# service) — silently no-ops until an operator provisions them, same pattern as
# the external-tracker step above (MCP not connected → skip, don't fail).
if [[ -n "${GATEWAY_SHARED_SECRET:-}" && -n "${TRACE_ACCOUNTANT_URL:-}" && -n "${PILOT_ACCOUNT_ID:-}" ]]; then
  # Secret is read from os.environ inside the process, never passed as argv —
  # argv is visible to other local users via `ps`, a process's own env is not.
  # The three GATEWAY_*/TRACE_*/PILOT_* vars are re-assigned here explicitly
  # (not just relied on from the caller's shell) so a caller who set them as
  # plain, non-exported shell variables still reaches python3's environment —
  # the `if` above only proves they're non-empty in bash, not that they were
  # exported (code review Ф2, this session, 2026-09-04).
  WP_ID="$WP_ID" WP_TITLE="$TITLE" WP_PRIORITY="$PRIORITY" WP_HYPOTHESIS="$HYPOTHESIS" \
  GATEWAY_SHARED_SECRET="$GATEWAY_SHARED_SECRET" TRACE_ACCOUNTANT_URL="$TRACE_ACCOUNTANT_URL" \
  PILOT_ACCOUNT_ID="$PILOT_ACCOUNT_ID" \
    python3 -c '
import json, os, urllib.error, urllib.request

body = {
    "jsonrpc": "2.0", "id": 1, "method": "tools/call",
    "params": {"name": "trace", "arguments": {
        "sensor_id": "wp_ritual", "event_type": "decision_made",
        "user_id": os.environ["PILOT_ACCOUNT_ID"],
        "external_id": "wp-ritual-" + os.environ["WP_ID"],
        "content": {"wp": "WP-" + os.environ["WP_ID"], "title": os.environ["WP_TITLE"],
                    "priority": os.environ["WP_PRIORITY"], "hypothesis": os.environ["WP_HYPOTHESIS"]},
        "prov": {"authorship_version": 1, "actor_type": "human"},
    }},
}
req = urllib.request.Request(
    os.environ["TRACE_ACCOUNTANT_URL"].rstrip("/") + "/mcp",
    data=json.dumps(body).encode(),
    headers={"Authorization": "Bearer " + os.environ["GATEWAY_SHARED_SECRET"], "Content-Type": "application/json"},
)
try:
    resp = urllib.request.urlopen(req, timeout=5)
    result = json.loads(resp.read())
except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"trace-accountant не ответил: {exc}")
# The MCP endpoint returns HTTP 200 for both ok(...) and fail(...) — only 401 is
# a non-2xx status (mcp-handler.ts createMcpHandler). A transport-level success
# here does not mean the write succeeded; the JSON-RPC/tool-level error must be
# checked explicitly, or every real call fails silently-successful while the
# domain_event_allowed_source migration for these sensors is still unapplied
# (found in code review of this same session, 2026-09-04).
if "error" in result or result.get("result", {}).get("isError"):
    raise SystemExit(f"trace-accountant вернул ошибку: {result}")
' \
    && echo "   ✅ decision_made записан (тайл нагрузки, РП417 Ф3.6)" \
    || echo "   ⚠️  decision_made: не удалось записать — тайл нагрузки не увидит эту запись" >&2
else
  echo "ℹ️  decision_made пропущен: не заданы GATEWAY_SHARED_SECRET/TRACE_ACCOUNTANT_URL/PILOT_ACCOUNT_ID (штатно на большинстве машин сегодня)"
fi

# --- Внешний трекер (условный пост-шаг, issue #321) ---
echo ""
echo "ℹ️  Внешний трекер (если подключён): создать issue вручную или через MCP"
echo "   Linear MCP → create_issue title='WP-${WP_ID} ${TITLE}' teamId=TSR"
echo "   MCP не подключён → штатно: отметить «внешний трекер: не подключён», локальная запись полна"

# --- Consent file остаётся в папке WP для аудит-следа ---
# Ранее consent file удалялся здесь; это ломало последующие wp-gate-check
# редактирования в той же сессии. Файл сохраняется; уборка по усмотрению пилота.
if [[ "$SKIP_CONSENT" -eq 0 && -f "$CONSENT_FILE" ]]; then
  echo ""
  echo "ℹ️  Consent file сохранён: $CONSENT_FILE"
fi

echo ""
echo "✅ WP-${WP_ID} создан: $TITLE"
echo "   context: inbox/WP-${WP_ID}/WP-${WP_ID}.md"
echo "   archive: будет создан close-wp.sh при закрытии РП"
echo "   Следующий шаг: заполнить «Проблема», «Артефакт», «Фазы» в context file"
echo "   Не забыть: issue во внешнем трекере (если подключён)"
