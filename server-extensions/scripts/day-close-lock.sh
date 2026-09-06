#!/bin/bash
# day-close-lock.sh — git-native cross-machine lock against duplicate Day Close runs (WP-484 Ф2).
#
# Инцидент 17.07: сервер (tsekh-1) и пилот вручную закрыли один день независимо друг от друга,
# gap обнаружился только в момент commit+push. Git log сам по себе неатомарен (read-then-act),
# поэтому источник истины — сам факт push: кто раньше запушил "day-close-start:", тот и работает,
# остальные видят чужой свежий маркер (или reject при попытке запушить свой) и останавливаются
# ДО начала работы, а не после.
#
# Маркер — ПУСТОЙ коммит, собранный через commit-tree ПОВЕРХ СВЕЖЕГО origin/<branch> и
# запушенный прямо в refs/heads/<branch>. Ключевое следствие: рабочее дерево, индекс и локальный
# HEAD не участвуют вообще. Ни stash, ни rebase, ни checkout — замку нечего в них делать, он
# читает историю из origin и пишет туда же.
#
# Почему так (инцидент 05.09, WP-484): прежняя версия ради того же результата прятала в stash ВСЁ
# рабочее дерево, делала `pull --rebase` и возвращала stash обратно. В общем чекауте с девятью
# живыми сессиями окно между push и apply достаточно, чтобы чужая правка попала в stash и не
# вернулась: три прогона подряд стёрли незакоммиченную работу параллельных сессий по 12-14 файлам
# (восстановлено вручную сверкой блобов). Ни одна из трёх операций замку не была нужна — весь
# класс отказа снят удалением механики, а не её укреплением. Разбор:
# inbox/bugs/bug-2026-09-05-day-close-lock-vs-canonical-freeze.md,
# урок memory/lessons_infra_stash_all_tree_eats_parallel_agents_work.md.
#
# Побочный эффект, снятый сознательно: прежняя версия заодно подтягивала канон к свежему origin.
# Теперь не подтягивает. Под заморозкой канонического чекаута (WP-520/WP-484 Ф104) канон и так
# отстаёт по замыслу — публикация идёт через ds-publish.sh/isolate-push.sh из одноразовой копии,
# а не из общего дерева. Контракт этого скрипта — «замок», не «синхронизация»; проверка «не
# работать на устаревшей истории» осталась на месте, просто читает origin напрямую.
#
# Freeze канонического чекаута: push метки самоавторизован (IWE_CANONICAL_OWNER=day-close-lock).
# Основание не «мы плановый раннер, нам можно», а проверяемое свойство: дерево метки побайтово
# равно дереву origin/<branch>, публиковать ей нечего по построению — ровно от этого заморозка и
# защищает. Равенство деревьев проверяется перед каждым push, а не предполагается.
#
# После push-reject проверка идёт по origin/<branch> НАПРЯМУЮ (git fetch, без rebase) — если
# сначала перебазировать свой маркер поверх новых чужих коммитов и только потом проверять лог,
# собственный только что перебазированный маркер (committer-date обновляется rebase'ом на "сейчас")
# становится самым свежим совпадением и маскирует реальную причину reject'а — ревью нашло это
# эмпирически (reject от ПОСТОРОННЕГО коммита давал ложное "кто-то закрывает день" на каждый раз).
# В нынешней схеме маркер локально не устанавливается вовсе, так что маскировать нечем.
#
# TZ закреплён в UTC: сервер и Mac иначе могут разойтись в вычислении "today" у полуночи.
#
# Двухуровневая защита: сначала быстрый локальный барьер (gateway-lock.py, для двух процессов на
# ОДНОЙ машине), затем git-маркер (для гонки МЕЖДУ машинами — ровно инцидент 17.07). Первый уровень
# не обязателен (gateway недоступен → просто пропускается), второй — единственный источник истины.
#
# Usage: day-close-lock.sh acquire
#   exit 0 — лок взят, можно приступать к закрытию дня
#   exit 1 — день уже закрыт сегодня (найден финальный коммит "day-close: YYYY-MM-DD")
#   exit 3 — кто-то уже закрывает день прямо сейчас (свежий "day-close-start:", локально или на другой машине)
#   exit 2 — git/gateway-операция не удалась однозначно (сеть/хук/окружение) — ретраить снаружи, не считать "уже закрыто"

set -euo pipefail
export TZ=UTC

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
GOVERNANCE_REPO="${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
REPO_DIR="$WORKSPACE_DIR/$GOVERNANCE_REPO"
TTL_SECONDS=1800  # та же конвенция, что scripts/session-guard.sh HK_MAX_AGE (30 мин)
GATEWAY_LOCK_PY="$REPO_DIR/scripts/lib/gateway-lock.py"
PUSH_ATTEMPTS=3   # чужой коммит между fetch и push — штатная гонка, не отказ; потолок от бесконечного цикла

log() { echo "[day-close-lock] $1"; }

# Быстрый барьер для двух процессов на ОДНОЙ машине — необязательный, gateway недоступен → просто
# продолжаем и полагаемся на git-проверку ниже (она единственная работает между машинами).
local_barrier() {
  [ -x "$GATEWAY_LOCK_PY" ] || { log "gateway-lock.py не найден — пропускаю локальный барьер"; return 0; }
  local rc=0
  python3 "$GATEWAY_LOCK_PY" acquire "day-close-lock" "$TTL_SECONDS" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ]; then
    log "Локальный барьер: день уже закрывается на этой машине (gateway lock занят) — выхожу"
    exit 3
  elif [ "$rc" -eq 2 ]; then
    log "gateway недоступен — пропускаю локальный барьер, дальше решает git"
  fi
}

# Возвращает: "closed" | "start:<age_seconds>" | "" (пусто — сегодня ничего не было).
# $1 — git-ref для проверки; вызывается только с origin/<branch>: локальный HEAD в этой схеме
# может отставать от origin на произвольное число коммитов и о чужом закрытии не знает.
check_today_history() {
  local ref="$1"
  local today; today=$(date +%Y-%m-%d)
  local log_lines
  log_lines=$(git log "$ref" --since="${today} 00:00" --format="%ct %s" 2>/dev/null || true)

  if echo "$log_lines" | grep -q "day-close: ${today}"; then
    echo "closed"
    return
  fi

  local start_line
  start_line=$(echo "$log_lines" | grep "day-close-start: ${today}" | head -1 || true)
  if [ -n "$start_line" ]; then
    local ts now
    ts=$(echo "$start_line" | awk '{print $1}')
    now=$(date +%s)
    echo "start:$(( now - ts ))"
    return
  fi

  echo ""
}

# Пустой коммит поверх свежего origin/<branch>; печатает sha, локальные refs не двигает.
# commit-tree, а не `git commit --allow-empty`: последняя не гарантирует пустой diff, если в индексе
# лежат чужие staged-файлы — реальный риск в репо, где параллельно работают несколько агентов.
build_start_marker() {
  local branch="$1" who="$2" today="$3"
  local parent tree
  parent=$(git rev-parse "origin/$branch") || return 1
  tree=$(git rev-parse "origin/$branch^{tree}") || return 1
  git commit-tree -p "$parent" -m "day-close-start: ${today} by ${who}" "$tree" || return 1
}

# Публикует метку. Самоавторизация под freeze — только после доказательства, что коммит пустой.
push_start_marker() {
  local marker="$1" branch="$2"
  local marker_tree origin_tree
  marker_tree=$(git rev-parse "${marker}^{tree}") || return 1
  origin_tree=$(git rev-parse "origin/$branch^{tree}") || return 1
  if [ "$marker_tree" != "$origin_tree" ]; then
    log "метка несёт изменения (дерево $marker_tree != $origin_tree у origin/$branch) — отказ, самоавторизация под freeze недопустима"
    return 1
  fi
  IWE_CANONICAL_OWNER="day-close-lock" git push --quiet origin "${marker}:refs/heads/${branch}"
}

# Возвращает 0, если по состоянию origin можно продолжать; сам выходит с 1/3, если день уже
# закрыт или закрывается кем-то другим.
assert_day_is_free() {
  local branch="$1"
  local state; state=$(check_today_history "origin/$branch")

  if [ "$state" = "closed" ]; then
    local closed_at
    closed_at=$(git log "origin/$branch" --since="$(date +%Y-%m-%d) 00:00" \
      --grep="day-close: $(date +%Y-%m-%d)" --format="%cd" --date=format:%H:%M | head -1)
    log "Механическая часть дня уже закрыта (маркер ${closed_at:-неизвестно}) — разговорная часть (рефлексия, приоритеты) отдельно, проверить наличие секции «Итоги дня». Повторный автоматический прогон не нужен."
    exit 1
  fi

  if [[ "$state" == start:* ]]; then
    local age="${state#start:}"
    if [ "$age" -lt "$TTL_SECONDS" ]; then
      log "Кто-то уже закрывает день прямо сейчас (маркер моложе ${TTL_SECONDS}s, возраст ${age}s) — выхожу"
      exit 3
    fi
    log "Найден протухший day-close-start (возраст ${age}s ≥ ${TTL_SECONDS}s) — считаю осиротевшим, продолжаю"
  fi
}

acquire() {
  cd "$REPO_DIR" || { log "не удалось перейти в $REPO_DIR — окружение не настроено, эскалирую"; exit 2; }

  local_barrier

  local branch who today
  branch=$(git rev-parse --abbrev-ref HEAD) || { log "не удалось определить текущую ветку — эскалирую"; exit 2; }
  who="${IWE_AGENT:-$(whoami)}@$(hostname -s)"
  today=$(date +%Y-%m-%d)

  local attempt marker
  for (( attempt = 1; attempt <= PUSH_ATTEMPTS; attempt++ )); do
    git fetch --quiet origin "$branch" \
      || { log "git fetch origin $branch не удался — не рискуем работать на устаревшей истории"; exit 2; }

    assert_day_is_free "$branch"

    marker=$(build_start_marker "$branch" "$who" "$today") \
      || { log "не удалось собрать маркер-коммит — эскалирую"; exit 2; }

    if push_start_marker "$marker" "$branch"; then
      log "Lock acquired: day-close-start: ${today} by ${who}"
      return 0
    fi

    log "push метки отклонён (попытка ${attempt} из ${PUSH_ATTEMPTS}) — перечитываю origin/$branch"
  done

  log "метку не удалось запушить за ${PUSH_ATTEMPTS} попыток — origin меняется быстрее, чем мы читаем; эскалирую"
  exit 2
}

case "${1:-}" in
  acquire) acquire ;;
  *) echo "Usage: $0 acquire" >&2; exit 2 ;;
esac
