#!/bin/bash
# day-close-lock.sh — git-native cross-machine lock against duplicate Day Close runs (WP-484 Ф2).
#
# Инцидент 17.07: сервер (tsekh-1) и пилот вручную закрыли один день независимо друг от друга,
# gap обнаружился только в момент commit+push. Git log сам по себе неатомарен (read-then-act),
# поэтому источник истины — сам факт push: кто раньше запушил лизу, тот и работает, остальные
# видят чужую свежую лизу (или CAS-reject при попытке взять свою) и останавливаются ДО начала
# работы, а не после.
#
# Механизм замка — общий примитив publish-lease.sh (WP-530 Ф25, 06.09, АрхГейт
# decisions/2026-09/2026-09-06-wp530-cross-host-lock-archgate.md: «свести два примитива к
# одному... третий механизм не заводить»). До этой правки замок сам собирал пустой коммит-маркер
# и пушил его в refs/heads/<branch> — рабочая, но отдельная от аренды публикации схема; теперь обе
# используют одну и ту же CAS-аренду на выделенной git-ссылке (refs/notes/*). Рабочее дерево,
# индекс и локальный HEAD по-прежнему не участвуют вообще: publish-lease.sh читает и пишет только
# через origin.
#
# Почему branch-marker версия была снята (инцидент 05.09, WP-484): предыдущая-предыдущая версия
# ради того же результата прятала в stash ВСЁ рабочее дерево, делала `pull --rebase` и возвращала
# stash обратно — три прогона подряд стёрли незакоммиченную работу параллельных сессий по 12-14
# файлам. Версия с пустым коммитом в ветку эту дыру закрыла, но платила отдельным примитивом и
# самоавторизацией под freeze канонического чекаута через доказательство «дерево пустое» — приём,
# который для лизы С СОДЕРЖИМЫМ (owner/epoch/expires_at) физически неприменим. Разбор обеих
# находок: inbox/bugs/bug-2026-09-05-day-close-lock-vs-canonical-freeze.md (resolved).
#
# Freeze канонического чекаута больше не требует самоавторизации для этого замка: push лизы идёт
# в refs/notes/*, а .githooks/pre-push (WP-530 Ф25) пропускает freeze-проверку для push, который
# целиком лежит вне refs/heads/*/refs/tags/* — namespace физически не пересекается с историей
# ветки, которую freeze защищает, и уже CAS-защищён `--force-with-lease` самой аренды.
#
# TZ закреплён в UTC: сервер и Mac иначе могут разойтись в вычислении "today" у полуночи.
#
# Двухуровневая защита: сначала быстрый локальный барьер (gateway-lock.py, для двух процессов на
# ОДНОЙ машине), затем межмашинная аренда (для гонки МЕЖДУ машинами — ровно инцидент 17.07).
# Первый уровень не обязателен (gateway недоступен → просто пропускается), второй — единственный
# источник истины.
#
# Usage: day-close-lock.sh acquire
#   exit 0 — лок взят, можно приступать к закрытию дня
#   exit 1 — день уже закрыт сегодня (найден финальный коммит "day-close: YYYY-MM-DD")
#   exit 3 — кто-то уже закрывает день прямо сейчас (аренда занята, локально или на другой машине)
#   exit 2 — git/gateway-операция не удалась однозначно (сеть/хук/окружение) — ретраить снаружи, не считать "уже закрыто"
# Usage: day-close-lock.sh release
#   Опциональная гигиена: отпустить аренду раньше TTL. Сегодня ни один потребитель не вызывает —
#   финальный коммит "day-close: YYYY-MM-DD" на шаге 15 сам служит завершающей меткой
#   (.claude/skills/day-close/SKILL.md), а TTL (30 мин) освобождает аренду и без явного release.
#   Субкоманда — для полноты примитива и ручной отладки, не часть протокола.

set -euo pipefail
export TZ=UTC

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
GOVERNANCE_REPO="${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
REPO_DIR="$WORKSPACE_DIR/$GOVERNANCE_REPO"
TTL_SECONDS=1800  # та же конвенция, что scripts/session-guard.sh HK_MAX_AGE (30 мин)
PUSH_ATTEMPTS=3   # чужой коммит между fetch и CAS-push — штатная гонка, не отказ; потолок от бесконечного цикла
GATEWAY_LOCK_PY="$REPO_DIR/scripts/lib/gateway-lock.py"
PUBLISH_LEASE_LIB="$REPO_DIR/scripts/lib/publish-lease.sh"
# shellcheck source=/dev/null
source "$PUBLISH_LEASE_LIB" || exit 1
export PUBLISH_LEASE_REF="${DAY_CLOSE_LEASE_REF:-refs/notes/iwe-day-close-lock}"

log() { echo "[day-close-lock] $1"; }

lock_owner() {
  printf '%s@%s' "${IWE_AGENT:-$(whoami)}" "$(hostname -s)"
}

# Быстрый барьер для двух процессов на ОДНОЙ машине — необязательный, gateway недоступен → просто
# продолжаем и полагаемся на межмашинную аренду ниже (она единственная работает между машинами).
local_barrier() {
  [ -x "$GATEWAY_LOCK_PY" ] || { log "gateway-lock.py не найден — пропускаю локальный барьер"; return 0; }
  local rc=0
  python3 "$GATEWAY_LOCK_PY" acquire "day-close-lock" "$TTL_SECONDS" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ]; then
    log "Локальный барьер: день уже закрывается на этой машине (gateway lock занят) — выхожу"
    exit 3
  elif [ "$rc" -eq 2 ]; then
    log "gateway недоступен — пропускаю локальный барьер, дальше решает межмашинная аренда"
  fi
}

# Финальный коммит "day-close: YYYY-MM-DD" несёт реальные файлы дня и никогда не был частью
# лока — отдельный факт, проверяемый напрямую по истории ветки, не через аренду.
final_close_commit() {
  local ref="$1" today; today=$(date +%Y-%m-%d)
  git log "$ref" --since="${today} 00:00" --grep="day-close: ${today}" --format="%cd" \
    --date=format:%H:%M 2>/dev/null | head -1
}

acquire() {
  cd "$REPO_DIR" || { log "не удалось перейти в $REPO_DIR — окружение не настроено, эскалирую"; exit 2; }

  local_barrier

  local branch who today
  branch=$(git rev-parse --abbrev-ref HEAD) || { log "не удалось определить текущую ветку — эскалирую"; exit 2; }
  who=$(lock_owner)
  today=$(date +%Y-%m-%d)
  export PUBLISH_LEASE_OWNER="$who"

  local attempt acq_rc closed_at
  for (( attempt = 1; attempt <= PUSH_ATTEMPTS; attempt++ )); do
    git fetch --quiet origin "$branch" \
      || { log "git fetch origin $branch не удался — не рискуем работать на устаревшей истории"; exit 2; }

    closed_at=$(final_close_commit "origin/$branch")
    if [ -n "$closed_at" ]; then
      log "Механическая часть дня уже закрыта (маркер ${closed_at}) — разговорная часть (рефлексия, приоритеты) отдельно, проверить наличие секции «Итоги дня». Повторный автоматический прогон не нужен."
      exit 1
    fi

    acq_rc=0
    publish_lease_acquire "$REPO_DIR" "day-close-start: ${today} by ${who}" "$TTL_SECONDS" >/dev/null || acq_rc=$?
    case "$acq_rc" in
      0)
        log "Lock acquired: day-close-start: ${today} by ${who}"
        return 0
        ;;
      1)
        # publish-lease.sh: "other error (network/race lost -- caller may
        # retry)" -- чужой push между чтением и записью, штатная гонка, не
        # отказ (тот же класс, что раньше покрывал PUSH_ATTEMPTS у branch-
        # marker версии). Перечитываем origin/$branch и пробуем снова.
        log "гонка на CAS-push (попытка ${attempt} из ${PUSH_ATTEMPTS}) — перечитываю origin/$branch"
        continue
        ;;
      2)
        log "Кто-то уже закрывает день прямо сейчас (межмашинная аренда занята) — выхожу"
        exit 3
        ;;
      *)
        # rc=3 (push отклонён МЕХАНИЗМОМ, не конкуренцией -- например freeze
        # канонического чекаута, см. inbox/bugs/
        # bug-2026-09-05-day-close-lock-vs-canonical-freeze.md, ровно тот
        # инцидент, что заставил publish-lease.sh завести этот код) и любой
        # прочий rc эскалируются немедленно: повтор той же причины не изменит.
        log "Не удалось взять межмашинную аренду (код ${acq_rc}) — origin недоступен или push отклонён не конкуренцией, повтор бесполезен, эскалирую"
        exit 2
        ;;
    esac
  done

  log "гонка на CAS-push не разрешилась за ${PUSH_ATTEMPTS} попыток — origin меняется быстрее, чем мы читаем; эскалирую"
  exit 2
}

release() {
  cd "$REPO_DIR" || { log "не удалось перейти в $REPO_DIR — окружение не настроено, эскалирую"; exit 2; }
  local who epoch
  who=$(lock_owner)
  epoch=$(publish_lease_current_epoch "$REPO_DIR") || { log "не удалось прочитать состояние аренды"; exit 2; }
  if [ -z "$epoch" ]; then
    log "Аренды и так нет"
    return 0
  fi
  if publish_lease_release "$REPO_DIR" "$who" "$epoch"; then
    log "Аренда отпущена (${who})"
  else
    log "Release отклонён — аренда уже не наша"
    exit 1
  fi
}

case "${1:-}" in
  acquire) acquire ;;
  release) release ;;
  *) echo "Usage: $0 acquire|release" >&2; exit 2 ;;
esac
