#!/usr/bin/env bash
#
# semaphore-watchdog.sh
# Alert-only guard against .open-семафоры, зависшие после того как работа
# внутри них уже логически завершена или живёт подозрительно долго.
# WP-484 Ф90 (12.08) — найден живым инцидентом: два claude-code процесса на
# tsekh-1 (WP-496, WP-522) отработали report.md/deploy, но host-процесс не
# отдал .open-семафор — iwe-tsekh1-sync.service честно отказывался
# синхронизировать дерево 13+ раз, ночной пайплайн читал устаревший
# priorities.yaml. Решение пилота (Ф90): alert-only, НЕ auto-release — риск
# нарушить саму защиту git-dirty-guard, которую этот сторож обслуживает.
#
# Модель (peer-session 2026-08-12-06-wp484-watchdog-lang-check, consensus
# ход 10): семафор session-guard.sh НЕ хранит completed_at/status — close
# переименовывает файл .open → .closed на последнем шаге (session-guard.sh:768),
# так что сам факт "файл ещё .open" уже значит "close не дошёл до конца".
# Единственная надёжная метка внутри семафора — opened_at (пишется один раз
# при open, session-guard.sh:415). Правило А использует внешнее подтверждение
# из meta.yaml СОСЕДНЕЙ пир-сессии; join — по полю slug (не session_id: в
# семафоре это unix-эпоха момента open, в meta.yaml пир-сессии — формат
# YYYY-MM-DD-NN-slug, эти два идентификатора устроены независимо).
#
# Правило А (высокая уверенность, короткий порог): slug семафора указывает на
#   sessions/*/*/{slug}/meta.yaml со status: completed — работа выше по стеку
#   завершена, но семафор не снят.
# Правило Б (низкая уверенность, универсальный таймаут): семафор живёт дольше
#   ABSOLUTE_THRESHOLD_S независимо от meta.yaml — страховка от настоящего
#   краша (OOM/сеть/закрытая крышка), который никогда не дойдёт до status:
#   completed ни в каком файле.
#
# Правило Б проверяется только если Правило А не сработало — одна причина
# зависания даёт один алерт с точным сообщением, не два про один и тот же факт.
#
# Оба правила: alert-only. Никогда не трогают файлы или процессы.
#
# Run manually:
#   bash scripts/semaphore-watchdog.sh
# Или через cron/launchd на сервере, где физически живут семафоры (не
# обязательно Mac — .marker в kimi-standalone-preflight.sh это ДРУГОЙ,
# более узкий механизм, вне области этого сторожа).

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-my-strategy}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
PEER_SESSIONS_DIR="$IWE_ROOT/$GOV_REPO/sessions"
LOG_FILE="$IWE_ROOT/.iwe-runtime/logs/semaphore-watchdog.log"

# Правило А: предварительное число (peer-session ход 4), требует одного цикла
# живого наблюдения перед калибровкой — session-guard close в норме почти
# мгновенно освобождает семафор после проверок (ORZ, scope-dirty, RUN-карточка).
RULE_A_THRESHOLD_S="${SEMAPHORE_WATCHDOG_RULE_A_THRESHOLD_S:-2700}"   # 45 мин
# Правило Б: рабочая гипотеза (peer-session ход 5), требует сверки с
# фактическим временем ночного цикла и распределением времени открытия
# сессий вечером — скользящий порог от opened_at не гарантирует срабатывание
# до фиксированного часа пайплайна для семафоров, открытых поздно вечером.
RULE_B_THRESHOLD_S="${SEMAPHORE_WATCHDOG_RULE_B_THRESHOLD_S:-21600}"  # 6 ч

now_epoch() { date -u +%s; }

parse_iso_epoch() {
  local iso="$1"
  [ -n "$iso" ] || { echo ""; return; }
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null \
    || date -u -d "$iso" +%s 2>/dev/null || echo ""
}

log_alert() {
  local rule="$1" sem_file="$2" wp="$3" slug="$4" age_s="$5" detail="$6"
  local line
  line="$(date -u +"%Y-%m-%dT%H:%M:%SZ") | $rule | wp=$wp slug=$slug age=${age_s}s | $detail | $sem_file"
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "$line" >> "$LOG_FILE"
  echo "$line" >&2
}

notify_telegram() {
  local msg="$1"
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0
  curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$msg" > /dev/null || true
}

# Найти meta.yaml пир-сессии по slug семафора. Свежая пир-сессия без единого
# write может ещё не существовать в файловой системе — отсутствие файла это
# валидный статус "нет meta ещё", не ошибка (peer-session ход 10, замечание
# напарника).
find_peer_meta() {
  local slug="$1"
  [ -n "$slug" ] || return 1
  find "$PEER_SESSIONS_DIR" -maxdepth 3 -type d -name "$slug" 2>/dev/null \
    | head -1 \
    | while read -r dir; do
        [ -n "$dir" ] && [ -f "$dir/meta.yaml" ] && echo "$dir/meta.yaml"
      done
}

check_semaphore() {
  local sem_file="$1"
  [ -f "$sem_file" ] || return 0

  local wp slug opened_at opened_epoch age_s
  wp="$(grep "^wp: " "$sem_file" | cut -d' ' -f2- || echo "unknown")"
  slug="$(grep "^slug: " "$sem_file" | cut -d' ' -f2- || true)"
  opened_at="$(grep "^opened_at: " "$sem_file" | cut -d' ' -f2- || true)"
  opened_epoch="$(parse_iso_epoch "$opened_at")"

  if [ -z "$opened_epoch" ]; then
    log_alert "SKIP" "$sem_file" "$wp" "${slug:-unknown}" "0" "no opened_at, cannot age"
    return 0
  fi
  age_s=$(( $(now_epoch) - opened_epoch ))

  # Правило А: внешнее подтверждение из meta.yaml соседней пир-сессии.
  local peer_meta status
  peer_meta="$(find_peer_meta "${slug:-}" || true)"
  if [ -n "$peer_meta" ] && [ -f "$peer_meta" ]; then
    status="$(grep "^status: " "$peer_meta" | head -1 | sed -E 's/^status: *"?([^"]*)"?$/\1/' || true)"
    if [ "$status" = "completed" ] && [ "$age_s" -gt "$RULE_A_THRESHOLD_S" ]; then
      local msg="Семафор не снят: сессия WP:${wp} (${slug:-unknown}) завершена (${peer_meta}), но .open висит ${age_s}s"
      log_alert "RULE_A" "$sem_file" "$wp" "${slug:-unknown}" "$age_s" "peer meta status=completed at $peer_meta"
      notify_telegram "$msg"
      # RULE_A уже объяснило зависание конкретной причиной (работа выше по
      # стеку завершена, семафор не снят) — RULE_B на том же семафоре добавил
      # бы второй алерт с менее точным сообщением про тот же факт. Early
      # return намеренный: одна причина зависания → один алерт (найдено
      # review, ход verify-01).
      return 0
    fi
  fi

  # Правило Б: универсальный таймаут для семафоров, где RULE_A не сработало —
  # либо нет внешнего подтверждения, либо работа ещё не завершена. Страховка
  # от краша, который никогда не запишет status: completed никуда.
  if [ "$age_s" -gt "$RULE_B_THRESHOLD_S" ]; then
    local msg="Семафор живёт подозрительно долго: WP:${wp} (${slug:-unknown}), .open висит ${age_s}s без Close"
    log_alert "RULE_B" "$sem_file" "$wp" "${slug:-unknown}" "$age_s" "no completion signal, absolute age threshold"
    notify_telegram "$msg"
  fi
}

for sem in "$SESSION_DIR"/*.open; do
  [ -f "$sem" ] || continue
  check_semaphore "$sem"
done
