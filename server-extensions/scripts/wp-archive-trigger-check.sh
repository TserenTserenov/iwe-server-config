#!/usr/bin/env bash
# routing: helper  called-by=protocol-close(step 5c)  deterministic=true
# wp-archive-trigger-check.sh -- механическая проверка условия РП-541 Ф5 §5c
# (протокол закрытия, "Триггер архива долгоживущей карточки"): created старше
# 14 дней И карточка >400 строк -> предложить пилоту перенос закрытых фаз в
# WP-N-archive.md. Раньше это решение агент принимал "на глаз", перечитывая
# frontmatter каждый раз заново -- WP-561 2026-09-03-19 (Codex,
# placement-reviewer): "size-check лучше оформить отдельным детерминированным
# reflex-шагом", здесь тем же результатом без изменения графа quick-close.yaml
# (см. согласованную границу с check-wp-transfer-completeness.sh -- та про
# архивацию ЦЕЛОГО завершённого РП, эта -- про накопление внутри активного).
#
# Пороги НЕ новые -- те же 14 дней / 400 строк, что уже задокументированы в
# memory/protocol-close.md §5c; этот скрипт не меняет политику, только
# избавляет от ручного подсчёта.
#
# Использование:
#   wp-archive-trigger-check.sh <WP_NUM> [IWE_ROOT]
# Stdout (всегда, exit 0 -- это отчёт, не gate):
#   age_days=<N|unknown>
#   line_count=<N>
#   archive_declined_recent=<true|false>
#   over_threshold=<true|false>
# exit 1 только при ошибке использования/файл не найден.
#
# Совместимость: bash 3.2+ (macOS), bash 4+ (Linux)

set -uo pipefail

WP_NUM="${1:-}"
IWE="${2:-${IWE_ROOT:-$HOME/IWE}}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-my-strategy}"
INBOX="$IWE/$GOV_REPO/inbox"

AGE_THRESHOLD_DAYS=14
LINE_THRESHOLD=400

if [[ -z "$WP_NUM" ]]; then
  echo "Использование: $0 <WP_NUM> [IWE_ROOT]" >&2
  exit 1
fi
WP_NUM="${WP_NUM#WP-}"
WP_NUM="${WP_NUM#wp-}"

# Та же WP-434 папочная конвенция, что archive-done-wp.sh/check-wp-transfer-completeness.sh
WP_FILE="$INBOX/WP-${WP_NUM}/WP-${WP_NUM}.md"
if [[ ! -f "$WP_FILE" ]]; then
  echo "[ERROR] $WP_FILE не найден" >&2
  exit 1
fi

extract_fm_field() {
  local field="$1"
  awk '/^---$/{found++; next} found==1{print} found==2{exit}' "$WP_FILE" 2>/dev/null \
    | grep -E "^${field}:" | head -1 | sed "s/^${field}:[[:space:]]*//" | tr -d '"'
}

created="$(extract_fm_field created)"
archive_declined="$(extract_fm_field archive_declined)"

age_days="unknown"
if [[ "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  today_epoch=$(date -u +%s)
  created_epoch=$(date -u -j -f "%Y-%m-%d" "$created" +%s 2>/dev/null \
    || date -u -d "$created" +%s 2>/dev/null || echo "")
  if [[ -n "$created_epoch" ]]; then
    age_days=$(( (today_epoch - created_epoch) / 86400 ))
  fi
fi

line_count=$(wc -l < "$WP_FILE" | tr -d ' ')

# Уважает cooldown 14 дней от archive_declined (та же формула, что age выше).
archive_declined_recent="false"
if [[ "$archive_declined" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  today_epoch=$(date -u +%s)
  declined_epoch=$(date -u -j -f "%Y-%m-%d" "$archive_declined" +%s 2>/dev/null \
    || date -u -d "$archive_declined" +%s 2>/dev/null || echo "")
  if [[ -n "$declined_epoch" ]]; then
    declined_age_days=$(( (today_epoch - declined_epoch) / 86400 ))
    [[ "$declined_age_days" -lt "$AGE_THRESHOLD_DAYS" ]] && archive_declined_recent="true"
  fi
fi

over_threshold="false"
if [[ "$age_days" != "unknown" ]] \
  && [[ "$age_days" -gt "$AGE_THRESHOLD_DAYS" ]] \
  && [[ "$line_count" -gt "$LINE_THRESHOLD" ]] \
  && [[ "$archive_declined_recent" == "false" ]]; then
  over_threshold="true"
fi

echo "age_days=${age_days}"
echo "line_count=${line_count}"
echo "archive_declined_recent=${archive_declined_recent}"
echo "over_threshold=${over_threshold}"
